--[[
mexpru.lua - wraps the raw vc.mexpr_* creators (math_expr_composer.h) so every node made through
this layer has a Lua table captured into its `u` field. That is the only behavioural difference:
calling vc.mexpr_* directly still works, the node just has no table in `u` yet.
]]

local vc = require("virt_composer")
local char = require("char")

local mexpru = {}

-- #char.lua's m_font_sizes. The canonical copy - four other files used to keep their own.
mexpru.MAX_SIZE_INDEX = 18
-- The LOGICAL level a brand-new formula is built at, whatever the current zoom. Callers building a
-- fresh formula must pass this, never content.lua's live state.font_size - that double-counts zoom.
mexpru.DEFAULT_SIZE = 12

local current_zoom = 0

-- Ctrl+MouseWheel zoom, one offset for the whole app rather than a parameter threaded through
-- draw/measure/input/hit_test everywhere. content.lua sets it before any of those run.
function mexpru.set_zoom(z)
    current_zoom = z
end

function mexpru.get_zoom()
    return current_zoom
end

--[[ LOGICAL level (u(_).sz - relative, e.g. a sup is its base + SUB_SIZE_DELTA, never touched by
zoom) -> the PHYSICAL char.lua index used to build or measure real glyph geometry.

Why a mapping and not just mutating u(_).sz: applying a relative delta to an already-physical value
drifts once any step clamps, so zooming out and back in stops being reversible. Re-deriving from the
untouched logical value keeps it exact. ]]
function mexpru.physical_sz(logical)
    return math.max(1, math.min(mexpru.MAX_SIZE_INDEX, logical + current_zoom))
end

-- The per-node scratch table, without spelling out ref.u:push() every time.
function mexpru.u(ref)
    return ref.u:push()
end

-- Every raw vc.mexpr_* creator that returns a fresh mexpr_p, wrapped identically: call through,
-- capture a new {} into its u, return it. (mexpr_draw/mexpr_get_bb aren't creators, not wrapped;
-- wref_mexpr/rref_mexpr wrap an EXISTING mexpr_t rather than making a new one and aren't mexpr_t
-- themselves - no u field on those at all.)
local WRAPPED = {
    "mexpr_empty", "mexpr_symbol", "mexpr_bigop", "mexpr_frac", "mexpr_supsub",
    "mexpr_bracket_left", "mexpr_bracket_right",
    "mexpr_unarexpr", "mexpr_binexpr", "mexpr_merge_h", "mexpr_merge_v",
    "mexpr_accent", "mexpr_dress",
}

for _, name in ipairs(WRAPPED) do
    local raw = vc[name]
    mexpru[name] = function(...)
        local ret = raw(...)
        ret.u:capture({})
        return ret
    end
end

--[[ THE bracket model. A bracket atom carries u(_).bracket = {is_open, type, peer}; `peer` is the
OTHER atom's u TABLE, not its mexpr_p. lua_object_t::push() always hands back the same table for the
same node, so `==` between two u tables is a real identity check - resolve_bracket_pairs() below
finds a pair's match with it directly, no depth walk.

Nothing but a bracket atom carries .bracket; bracket_kind() returns nil for ordinary content. `peer`
is nil while PENDING (typed, not yet closed - mformula_new.lua's container.pending_bracket) and is
always set on BOTH atoms at once, by whoever sets either. ]]
local function bracket_kind(node)
    local u = mexpru.u(node)
    return u and u.bracket
end

--[[ THE atom carrying a row slot's bracket meaning: the node itself, or, when the slot is a supsub
or a dress that is not a bracket in its own right, whatever it wraps.

"(a)^{2}" is [ "(", a, supsub(base=")") ] - the closing half of that pair is a BASE, invisible to any
walk that reads children directly. That one blind spot produced four separate live bugs (cascade
delete taking the wrong partner, scan_bracket reporting an unrelated boundary, the wrap counter
mis-balancing, the sprint skipping a bracket carrying an exponent), so every walk over a row goes
through here. A dress needs the same look-through for the same reason, and recursively: a hatted,
squared ")" still has to resolve.

NOT the same question as mformula_new.lua's target_is_supsub_base, which asks about the cursor's own
node rather than what a slot carries. They look alike; don't merge them. ]]
function mexpru.slot_atom(node)
    local u = mexpru.u(node)
    if not u.bracket and u.kind == "supsub" and u.base then
        return mexpru.slot_atom(u.base)
    end
    if not u.bracket and u.kind == "dress" and u.target then
        return mexpru.slot_atom(u.target)
    end
    return node
end

-- What one slot contributes to a running bracket count in reading order: +1 open, -1 close, else 0.
function mexpru.bracket_delta(node)
    local br = mexpru.u(mexpru.slot_atom(node)).bracket
    if not br then
        return 0
    end
    return br.is_open and 1 or -1
end

--[[ THE counter rule: over children[from..to] in reading order, a bracket may close only where the
count of still-open brackets is back to ZERO, and the count may never go below zero on the way.

Returns the count at `to`, or nil the moment it would go negative - that step IS the close of the
ENCLOSING pair, so `to` and beyond are out of bounds for anything opened inside it. Stated as a
count rather than a walk looking for a specific atom because a count is checkable over any range
without knowing which atom is whose partner. ]]
function mexpru.bracket_count(children, from, to)
    local count = 0
    for i = from, to do
        local child = children[i]
        if not child then
            break
        end
        local delta = mexpru.bracket_delta(child)
        if delta < 0 and count == 0 then
            return nil          -- this is the ENCLOSING close - never step over it
        end
        count = count + delta
    end
    return count
end

--[[ The counter rule over a whole horiz. Returns (ok, count): ok is false once the count would go
NEGATIVE - a close with nothing open, which no edit may ever produce. count > 0 with ok true is an
ordinary mid-edit state (a pending bracket); count == 0 is balanced. Only ok == false is corruption. ]]
function mexpru.brackets_balanced(children)
    local count = 0
    for i = 1, #children do
        local delta = mexpru.bracket_delta(children[i])
        if delta < 0 and count == 0 then
            return false, count
        end
        count = count + delta
    end
    return true, count
end

--[[ Where `node`'s OWN peer sits in `children` - a direct .peer identity read, NOT a depth walk.
Use this for a bracket's partner and scan_bracket() only for what encloses an ORDINARY position: a
blind depth walk cannot see a peer parked in a supsub base, and rather than failing it returns the
next unmatched bracket it meets, silently pairing two atoms that were never partners ("((A)^{N})"
lost a bracket on backspace exactly this way).

Returns (index, is_base) - is_base true when the peer is that slot's base rather than the slot
itself, which is how a caller knows whether removal means splicing the row or rebuilding a supsub.
nil when node isn't a bracket, is still pending, or its peer isn't in this list at all. ]]
function mexpru.peer_slot(children, node)
    local br = mexpru.u(node).bracket
    if not br or not br.peer then
        return nil
    end
    for i, child in ipairs(children) do
        local carrier = mexpru.slot_atom(child)
        if mexpru.u(carrier) == br.peer then
            return i, mexpru.u(carrier) ~= mexpru.u(child)
        end
    end
    return nil
end

--[[ Walks `children` from idx+direction, matching nested brackets by depth, and returns the first
bracket not already claimed by a nested pair passed on the way - nil if there is none.

Used with idx naming an ORDINARY position and direction=-1 it finds the pair ENCLOSING it. A bracket
atom's own match is never found this way (see peer_slot()); this is for the case with nothing to
look up, an ordinary node having no .bracket of its own. Checks only is_open, never type:
mformula_new.lua's single-slot pending discipline means every closed pair is already type-matched. ]]
function mexpru.scan_bracket(children, idx, direction)
    local depth = 0
    local i = idx + direction
    while children[i] do
        local br = bracket_kind(children[i])
        if br then
            -- An open met while walking right, or a close met while walking left, starts (or
            -- continues) a nested/earlier-unrelated pair that has to be skipped past whole before
            -- our own search can resolve.
            local starts_nested = (direction == 1 and br.is_open) or (direction == -1 and not br.is_open)
            if starts_nested then
                depth = depth + 1
            elseif depth > 0 then
                depth = depth - 1
            else
                return i
            end
        end
        i = i + direction
    end
    return nil
end

--[[ Copies the open/close pairing of `old_children` onto `new_children`, slot by slot.

For a rebuild that constructs brand-new bracket atoms - mformula_new.lua's rescale_node() on a zoom
change - the peers cannot simply be carried across: they name u tables of the tree being discarded.
resolve_bracket_pairs() below finds a pair's close by reading the open atom's own .peer, so without
this every pair reads as still-pending and stays at the small plain glyph it was rebuilt as. That is
the "brackets go small when I zoom" bug; re-pasting appeared to cure it only because
paste rebuilds through try_close_bracket(), which sets peers the ordinary way.

Transfers rather than re-derives, and that distinction is the whole design: pairing is NOT a function
of position. "(_1 (_2 a )_1" - outer pair resolved, inner one still pending - is an ordinary mid-edit
state (test_bracket_no_crossing.lua), and any depth-stack scan matches its "(_2" to ")_1", inventing
a pair the user never closed. A rescale is a 1:1 structural mirror, so old slot i IS new slot i and
the old links map over exactly.

Reads each slot through slot_atom(), so a ")" sitting in a supsub's BASE ("(a)^{N}") is found at the
position its compound occupies - same convention peer_slot()/bracket_delta() use. ]]
function mexpru.transfer_bracket_peers(old_children, new_children)
    for i = 1, #old_children do
        local old_atom = mexpru.slot_atom(old_children[i])
        local ob = old_atom and mexpru.u(old_atom).bracket
        if ob and ob.is_open and ob.peer then
            local j = mexpru.peer_slot(old_children, old_atom)
            local new_open = j and mexpru.slot_atom(new_children[i])
            local new_close = j and mexpru.slot_atom(new_children[j])
            if new_open and new_close and mexpru.u(new_open).bracket and mexpru.u(new_close).bracket then
                mexpru.u(new_open).bracket.peer = mexpru.u(new_close)
                mexpru.u(new_close).bracket.peer = mexpru.u(new_open)
            end
        end
    end
end

--[[ slot_atom()'s inverse: puts `new_atom` back where slot_atom() found the old one, rebuilding
whatever wrapped it so the wrapper survives the swap.

"(a)^{2}" is [ "(", a, supsub(base=")") ]. Growing that pair means replacing the ")" INSIDE the
supsub - assigning over children[close_idx] wholesale would throw the exponent away with it.

Mirrors slot_atom() case for case, and must keep doing so: any node shape that can hide a bracket
has to be un-hideable again, or a pair that can be found is one that cannot be resized. ]]
local function replace_slot_atom(fs, node, new_atom)
    local u = mexpru.u(node)
    if not u.bracket and u.kind == "supsub" and u.base then
        return mexpru.supsub(fs, replace_slot_atom(fs, u.base, new_atom), u.sup, u.sub)
    end
    if not u.bracket and u.kind == "dress" and u.target then
        return mexpru.redress(fs, replace_slot_atom(fs, u.target, new_atom), u, u.sz)
    end
    return new_atom
end

--[[ Resolves every entangled bracket pair currently found in children[lo..hi] (the WHOLE list by
default - lo/hi are only ever passed explicitly by this function's OWN recursion below), innermost
first, before `children` is handed to mexpr_merge_h - see mformula_new.lua's own PENDING_BRACKET
comment for why a horiz's rebuild can't just be "merge whatever's here" anymore once brackets are
involved: each pair's own glyphs depend on everything CURRENTLY between them.

For an open bracket at `i`, finding where its own close currently sits is a plain forward walk
comparing each element's own u table against `br.peer` (this file's own top comment on why that's a
real, reliable check) - not wasted work: this function's actual job per pair is gathering everything
strictly BETWEEN the two into `inner` for sizing, which requires visiting every element in the span
regardless of how the boundary gets found, so the search costs nothing beyond what the job already
needs. It does NOT need depth-tracking (a stack, or scan_bracket()'s own counter) to stay correct
despite however many OTHER open/close brackets (nested pairs) sit in between - unlike interpreting
brackets generically, checking against one SPECIFIC known target (`br.peer`) doesn't care what it
passes over on the way to it.
Innermost-first: on finding an open bracket's own close this way, it first recurses into the range
strictly BETWEEN them (whatever nests inside gets fully resolved first, its own atoms' identities
possibly replaced) before gathering `inner` and rebuilding this pair's own two glyphs against that
now-settled content. ]]
local function resolve_bracket_pairs(fs, children, lo, hi)
    lo = lo or 1
    hi = hi or #children
    local i = lo
    while i <= hi do
        --[[ Through slot_atom, not children[i] directly. A bracket carrying an exponent is a supsub
        BASE ("(a)^{2}", which is also every \sqrt now that from_latex rewrites roots into powers),
        and reading the slot directly finds the supsub, whose u never equals br.peer - so the close
        was never located, the pair never grew, and "(a/b)^{2}" drew letter-height parentheses
        around a two-line fraction. Reported live 2026-09-06; the same blind spot slot_atom() was
        written for, at the one call site that still read around it. ]]
        local open_atom = mexpru.slot_atom(children[i])
        local br = bracket_kind(open_atom)
        if br and br.is_open and br.peer then
            local close_idx = i + 1
            while close_idx <= hi
                    and mexpru.u(mexpru.slot_atom(children[close_idx])) ~= br.peer do
                close_idx = close_idx + 1
            end

            if close_idx <= hi then
                local close_atom = mexpru.slot_atom(children[close_idx])
                resolve_bracket_pairs(fs, children, i + 1, close_idx - 1)

                local inner = {}
                for k = i + 1, close_idx - 1 do
                    table.insert(inner, children[k])
                end
                if #inner == 0 then
                    error("resolve_bracket_pairs: bracket pair's own span is empty - " ..
                            "mformula_new.lua is supposed to keep a bracket pair's span non-empty " ..
                            "(a fresh empty atom, same as an emptied-out horiz falls back to) " ..
                            "whenever backspace/delete would otherwise remove its last remaining child")
                end

                -- sz is LOGICAL (u(_).sz's own meaning, untouched by zoom - mexpru.physical_sz()'s
                -- own comment) - mapped to PHYSICAL below for the real bracket construction/height
                -- check, same as every other leaf this file's own callers build. Missing this
                -- mapping here specifically (found live, alongside the sizing issue
                -- below: "behaves quite differently with different zoom levels") meant a resolved
                -- bracket pair kept rendering at whatever size it was AT WHEN LAST RESOLVED,
                -- ignoring the current zoom entirely, while everything around it correctly rescaled.
                local sz = mexpru.u(open_atom).sz
                local phys_sz = mexpru.physical_sz(sz)
                local opts = char.bracket_opts(br.type, phys_sz)
                local assembled = (#inner == 1) and inner[1] or mexpru.mexpr_merge_h(fs, inner)

                -- Short content keeps the PLAIN typed glyphs, untouched. Do not "fix" this by
                -- forcing a minimum height into the tiered system instead (tried twice): its
                -- smallest tier ("\\bigl(", FONT_MATH_EX) is not a same-size stand-in for a typed
                -- "(" (FONT_NORMAL) but a deliberately larger glyph, so any threshold still lands
                -- on it. "(a" -> "(a)" has to change nothing but the ")" appearing.
                local plain_paren = char.find_by_ascii("(")
                local paren_sz = fs:char_get_sz({size = phys_sz, code = plain_paren.ncod})
                local plain_h = math.abs(paren_sz.tr.y - paren_sz.bl.y)
                local content_bb = vc.mexpr_get_bb(assembled)
                local content_h = content_bb.br.y - content_bb.tl.y

                --[[ `inner` is what sits strictly BETWEEN the brackets, so an exponent riding on
                the closing one is correctly NOT counted - "(a/b)^{2}" sizes its parentheses to the
                fraction, not to the fraction plus the 2, which is what TeX does too. ]]
                local grew = content_h > plain_h
                local new_left, new_right
                if not grew then
                    new_left = open_atom
                    new_right = close_atom
                else
                    new_left = mexpru.mexpr_bracket_left(fs, assembled, opts)
                    new_right = mexpru.mexpr_bracket_right(fs, assembled, opts)
                    mexpru.u(new_left).sz = sz
                    mexpru.u(new_right).sz = mexpru.u(close_atom).sz
                end
                mexpru.u(new_left).bracket = {is_open = true, type = br.type, peer = mexpru.u(new_right)}
                mexpru.u(new_right).bracket = {is_open = false, type = br.type, peer = mexpru.u(new_left)}

                --[[ Only when the glyphs actually CHANGED. Short content keeps the atoms it already
                had, and rebuilding a wrapper around an identical base would hand back a new node for
                no reason - a fresh identity that peer transfer and any live cursor ref would then
                have to chase. The untouched case stays exactly the no-op it always was. ]]
                if grew then
                    children[i] = replace_slot_atom(fs, children[i], new_left)
                    children[close_idx] = replace_slot_atom(fs, children[close_idx], new_right)
                end

                i = close_idx + 1
            else
                -- Still pending (no peer, or peer not found within this range) - an ordinary glyph
                -- as far as this pass is concerned, nothing to resolve.
                i = i + 1
            end
        else
            i = i + 1
        end
    end
end

--[[ Caches u(node).pos into every node of the tree, walking it the way mexpr_draw does. mexpr_t
stores tl/br relative to its OWN origin only, so this is where anything wanting a position reads it.

RELATIVE to (0, 0), not screen coordinates: the cache survives the box being drawn anywhere else
(scrolled, a box above it resized) - add wherever the root is drawn this frame. Only a TREE EDIT
invalidates it; recompute by calling again.

The `if u then` guard is for the raw subobjs a few vc.mexpr_* constructors build in C++ without
going through this layer (mexpr_frac's divider line, mexpr_bigop's operator symbol): those never had
a table captured, so mexpru.u() returns nil. They are always leaves, and nothing else in this file
ever reaches one - this anchor walk is the only exception. ]]
function mexpru.update_positions(node, pos)
    pos = pos or {x = 0, y = 0}
    local u = mexpru.u(node)
    if u then
        u.pos = pos
    end

    for i = 1, node:anchor_len() do
        local a = node:anchor_at(i)
        local child, child_pos = a[1], a[2]
        mexpru.update_positions(child, {x = pos.x + child_pos.x, y = pos.y + child_pos.y})
    end
end

--[[ A left-to-right sequence of atoms (mexpr_merge_h), remembering kind/children/sz so
propagate_rebuild() can redo this exact construction later from a changed children list.
`children` is kept BY REFERENCE - propagate_rebuild() splices it in place. ]]
function mexpru.horiz(fs, children, sz)
    resolve_bracket_pairs(fs, children)
    local ret = mexpru.mexpr_merge_h(fs, children)
    mexpru.u(ret).kind = "horiz"
    mexpru.u(ret).children = children
    mexpru.u(ret).sz = sz
    return ret
end

--[[ A big operator carrying its limits - a sum, an integral, or "lim" - stored with a supsub's
OWN field names on purpose.

It IS a supsub as far as anything but drawing is concerned: base is the operator, sup is what sits
above it, sub what sits below. Naming them base/sup/sub rather than op/above/bellow is what lets
is_supsub() cover both kinds in mformula_new, so navigation, the cascade and every other walk needs
no bigop case at all - only the two places that REBUILD a node dispatch on kind to pick a builder.

`metrics` is a char passed purely for its size (mexpr_bigop's own comment): it scales the gap
between the operator and its limits, and its code is never read. ]]
function mexpru.bigop(fs, base, sup, sub, sz)
    local ret = mexpru.mexpr_bigop(fs, base, sup, sub,
            char.hline_basic(mexpru.physical_sz(sz)))
    mexpru.u(ret).kind = "bigop"
    mexpru.u(ret).base = base
    mexpru.u(ret).sup = sup
    mexpru.u(ret).sub = sub
    mexpru.u(ret).sz = sz
    return ret
end

-- base required, sup/sub each a node or nil. Three NAMED slots rather than horiz's ordered list,
-- so propagate_rebuild() finds which one changed by name.
function mexpru.supsub(fs, base, sup, sub)
    local ret = mexpru.mexpr_supsub(fs, base, sup, sub)
    mexpru.u(ret).kind = "supsub"
    mexpru.u(ret).base = base
    mexpru.u(ret).sup = sup
    mexpru.u(ret).sub = sub
    return ret
end

--[[ The floor a vert cell never shrinks below - "the size the cell started with". H's advance wide,
G's top to g's baseline tall, i.e. exactly the box an EMPTY slot has (mformula_new.lua's
min_extent()/cursor_metrics() compute the same pair; mexpru is the lower layer, so it recomputes
rather than imports). Derived here from sz rather than passed in by vert()'s four callers, one of
which would eventually forget it. PHYSICAL size - these are real font metrics. ]]
local function empty_cell_extent(fs, sz)
    local physical = mexpru.physical_sz(sz)
    local G, g, H = char.find_by_ascii("G"), char.find_by_ascii("g"), char.find_by_ascii("H")
    local G_sz = fs:char_get_sz({size = physical, code = G.ncod})
    local g_sz = fs:char_get_sz({size = physical, code = g.ncod})
    local H_sz = fs:char_get_sz({size = physical, code = H.ncod})
    return {x = H_sz.adv, y = g_sz.bl.y - G_sz.tr.y}
end

--[[ N slots stacked vertically, each a horiz, no divider - mexpr_merge_v, the same primitive a
frac stacks with minus the line. `slots` is kept by reference, as horiz's children are. Every slot
is one uniform size; a stack doesn't shrink its rows the way an exponent does. ]]
function mexpru.vert(fs, slots, sz)
    local ret = mexpru.mexpr_merge_v(fs, slots, empty_cell_extent(fs, sz))
    mexpru.u(ret).kind = "vert"
    mexpru.u(ret).slots = slots
    mexpru.u(ret).sz = sz
    return ret
end

--[[ Dresses `target` with an accent above and/or below - a hat, a bar, dots, a boot.

A dressed node IS an atom: it takes the target's place in its row, it is never entered, and the
decoration cannot be selected. That makes it the same shape as a supsub's base, which is exactly
the shape this codebase has repeatedly got wrong - so slot_atom()/peer_slot() look THROUGH a dress
to its target, and anything asking "what atom is in this slot" gets the target, not the wrapper.

`above`/`bellow` are whatever the caller built: mexpru.accent() for a hat/tilde/bar, or
mexpru.dots() for one to three dots. mexpr_dress itself knows nothing about which is which - it
only places them (TEXbook Appendix G Rule 12; see the C++ for the placement rules). ]]
function mexpru.dress(fs, target, above, bellow, sz)
    --[[ mexpr_dress measures this char's HEIGHT and uses it as the clearance between the target's
    ink and the decoration - its own comment calls for "the pen width, which is font-derived and
    already the thickness a drawn accent is stroked at". hline_basic is that: the rule glyph a
    fraction's divider is drawn from, 1 unit tall here.

    It used to pass code = 0, which is not a pen width but char.lua's first table entry, 26 units
    tall at size 12 - so every accent floated a letter and a half above its own letter and a dressed
    "a" measured 48 units against the bare glyph's 17. ]]
    local ret = mexpru.mexpr_dress(fs, target, above, bellow,
            char.hline_basic(mexpru.physical_sz(sz)))
    mexpru.u(ret).kind = "dress"
    mexpru.u(ret).target = target
    mexpru.u(ret).sz = sz
    return ret
end

--[[ The accent glyph (or drawn shape) that fits `target`. Width comes from the target's own box,
which is what Rule 12's successor search compares against. ]]
function mexpru.accent(fs, recipe_fn, target, sz)
    local bb = vc.mexpr_get_bb(target)
    return mexpru.mexpr_accent(fs, recipe_fn(mexpru.physical_sz(sz)), bb.br.x - bb.tl.x)
end

--[[ n dots side by side, for the one/two/three-dot accents. Built by merging, not by a wider
glyph: there is no ddot in these fonts (see char.lua's own accent block). ]]
function mexpru.dots(fs, n, sz)
    local one = char.dot_accent_char(mexpru.physical_sz(sz))
    if n <= 1 then
        return mexpru.mexpr_symbol(fs, one, false)
    end
    local parts = {}
    for _ = 1, n do
        parts[#parts + 1] = mexpru.mexpr_symbol(fs, one, false)
    end
    return mexpru.mexpr_merge_h(fs, parts)
end

--[[ num/den are both REQUIRED (mexpr_frac throws without them, unlike supsub's optional sup/sub)
and each is always a HORIZ, never a bare atom the way a base is. Both render at the fraction's OWN
sz - typesetting doesn't shrink them the way an exponent shrinks - so unlike supsub a frac carries
its own sz directly, and nothing reading it needs a base-fallback. ]]
function mexpru.frac(fs, num, den, sz)
    -- sz is LOGICAL (u(ret).sz below) - the divider LINE's own real geometry (char.hline_basic)
    -- needs the current PHYSICAL size instead (mexpru.physical_sz()'s own comment).
    local ret = mexpru.mexpr_frac(fs, num, den, char.hline_basic(mexpru.physical_sz(sz)))
    mexpru.u(ret).kind = "frac"
    mexpru.u(ret).num = num
    mexpru.u(ret).den = den
    mexpru.u(ret).sz = sz
    return ret
end

--[[ Rebuilds a dress carrying `u`'s bookkeeping around a (possibly new, possibly resized) target.

THE single place a dress is reconstructed, because there are two callers - propagate_rebuild() below
when the target is edited, rescale_node() (mformula_new.lua) on a zoom - and they had drifted: only
one of them checked u.dots, so editing the letter under a dot accent silently dropped the dots while
zooming kept them. Order matters: a dotted dress has no above_recipe, so testing the recipe first
finds nothing and produces a bare target.

The decoration is rebuilt, never carried across, because the accent is chosen by the target's WIDTH
(Rule 12's successor search) - a letter edited into a wider one needs a wider hat. ]]
function mexpru.redress(fs, target, u, sz)
    local above
    if u.dots and u.dots > 0 then
        above = mexpru.dots(fs, u.dots, sz)
    elseif u.above_recipe then
        above = mexpru.accent(fs, u.above_recipe, target, sz)
    end
    local bellow = u.bellow_recipe and mexpru.accent(fs, u.bellow_recipe, target, sz) or nil

    local ret = mexpru.dress(fs, target, above, bellow, sz)
    local ru = mexpru.u(ret)
    ru.above_kind = u.above_kind
    ru.above_recipe = u.above_recipe
    ru.bellow_kind = u.bellow_kind
    ru.bellow_recipe = u.bellow_recipe
    ru.dots = u.dots
    return ret
end

--[[ "these two handles name the same node" - one pointer comparison, via the __eq handler mexpr_t
registers (math_expr_composer.h's mexpr_lua_eq). This used to compare tostring() output instead,
because no handler was registered and `==` threw; peer-linking then got built on top of that
workaround, which is the case CLAUDE.md's Law 1 is written from.

The nil guard is explicit because an absent operand is a real case (sup/sub are legitimately nil)
and "both absent" means the same absence - Lua would answer false rather than reach __eq. ]]
local function same(a, b)
    if a == nil or b == nil then
        return a == nil and b == nil
    end
    return a == b
end
mexpru.same = same

--[[ `child`'s own index within `children`, by identity (same() above). nil if not found. ]]
local function index_of(children, child)
    for i, c in ipairs(children) do
        if same(c, child) then
            return i
        end
    end
    return nil
end
mexpru.index_of = index_of

--[[ `old_node` was just rebuilt as `new_node` - same slot, new identity, since a composite can only
be rebuilt from its remembered construction arguments, never mutated in place. Splices new_node into
whichever slot of its parent old_node held (dispatched on u(parent).kind), rebuilds that parent, and
recurses upward: "the node and all its parents redo the operation they did at creation". Returns the
new root; the caller reassigns container.root to it.

Cuts old_node loose at EVERY level, not only the root. That was reverted once as a crash, but the
real cause was a bug in vc.force_release() (virt_composer.cpp) - fixed there, and test_lazy_supsub
covers the multi-level chain that used to crash.

`known_parent` is for a WRAP: new_node was built AROUND old_node (dressing an atom, giving one a
sup/sub), so the constructor already reparented old_node to new_node and old_node:get_parent() no
longer answers where it used to sit - it answers new_node, and rebuilding "its parent" then wraps
the wrapper, forever. The caller must capture the parent BEFORE building new_node and pass it here.
Two things change when it is given: the slot is found by index_of() rather than get_parent_idx()
(which scans old_node's CURRENT parent, i.e. the wrong one), and old_node is NOT cut, because
new_node owns it now - see mformula_new.lua's swap_atom()/make_supsub(). ]]
function mexpru.propagate_rebuild(fs, old_node, new_node, known_parent)
    local parent = known_parent or old_node:get_parent()
    if not parent then
        mexpru.update_positions(new_node)
        mexpru.cut(old_node)
        return new_node
    end

    local kind = mexpru.u(parent).kind
    local rebuilt
    if kind == "horiz" then
        local children = mexpru.u(parent).children
        -- get_parent_idx() (a C++ scan of parent's subobjs) rather than index_of(): valid only
        -- because `children` was just read fresh and nothing has spliced it since. After any
        -- table.insert/remove the two lists are out of step - see the vert branch below.
        children[known_parent and mexpru.index_of(children, old_node)
                or old_node:get_parent_idx()] = new_node
        rebuilt = mexpru.horiz(fs, children, mexpru.u(parent).sz)
    elseif kind == "supsub" or kind == "bigop" then
        local u = mexpru.u(parent)
        local base, sup, sub = u.base, u.sup, u.sub
        if same(base, old_node) then
            base = new_node
        elseif same(sup, old_node) then
            sup = new_node
        elseif same(sub, old_node) then
            sub = new_node
        else
            error("propagate_rebuild: old_node not found among parent " .. kind ..
                    "'s base/sup/sub")
        end
        --[[ A bigop rebuilds through its own constructor but finds its changed slot exactly as a
        supsub does - they carry the same base/sup/sub fields, which is the whole point. ]]
        if u.kind == "bigop" then
            rebuilt = mexpru.bigop(fs, base, sup, sub, u.sz)
        else
            rebuilt = mexpru.supsub(fs, base, sup, sub)
        end
    elseif kind == "frac" then
        local u = mexpru.u(parent)
        local num, den = u.num, u.den
        if same(num, old_node) then
            num = new_node
        elseif same(den, old_node) then
            den = new_node
        else
            error("propagate_rebuild: old_node not found among parent frac's num/den")
        end
        rebuilt = mexpru.frac(fs, num, den, u.sz)
    elseif kind == "vert" then
        local u = mexpru.u(parent)
        local slots = u.slots
        -- index_of(), not get_parent_idx(): a vert's own slot list is the same Lua table the
        -- caller may have just spliced (grow/shrink), so the C++ subobjs and this list can be out
        -- of step - the same reason handle_input()'s cascade stopped trusting get_parent_idx()
        -- after a table.remove().
        local idx = mexpru.index_of(slots, old_node)
        if not idx then
            error("propagate_rebuild: old_node not found among parent vert's own slots")
        end
        slots[idx] = new_node
        rebuilt = mexpru.vert(fs, slots, u.sz)
    elseif kind == "dress" then
        -- Only the target is ever replaced - the decoration is not content and takes no cursor.
        local u = mexpru.u(parent)
        rebuilt = mexpru.redress(fs, new_node, u, u.sz)
    else
        error("propagate_rebuild: don't know how to rebuild a '" .. tostring(kind) .. "' node")
    end

    if not known_parent then
        mexpru.cut(old_node)   -- a wrap's old node is a live child of new_node; never cut that
    end
    return mexpru.propagate_rebuild(fs, parent, rebuilt)
end

--[[ Makes a node the caller has ALREADY cut loose - spliced out of its old parent, with
propagate_rebuild() done and container.root reassigned - let go right now.

Needed because Lua's collector is TRACING, not refcounted: an unreferenced node only becomes
eligible, and stays alive-but-orphaned until a trace reaches it (one survived two forced
collectgarbage("collect") passes and died only at state teardown). Any WEAK ref still pointing at it
- container.pending_bracket, say - reads back as alive that whole time, correctly but uselessly.
That is what bit the bracket-pending path.

One node is enough, no subtree walk: mexpr_t owns its children by shared_ptr and points at its
parent raw, so cascading destruction handles everything beneath the moment the cut node's last
reference goes - which it is, provided the caller kept no stray local (see mformula_new.lua's
"don't touch this local again" discipline).

vc.force_release() is the real primitive; it is global rather than a method because virt_composer's
`:` dispatch never sees a bare lua_setfield onto the shared metatable. ]]
function mexpru.cut(node)
    vc.force_release(node)
end

--[[ Profiler instrumentation (prof.lua), applied at the bottom so it lifts out in one go and no
call site knows about it. All no-ops while the profiler is off.

u() is deliberately NOT wrapped despite being the most-called function here: it is a single registry
push, so the wrapper costs several times the callee and the figure describes the profiler rather
than the code (it read 27us per call when tried). Count the cpp.* boundary crossings instead.

same()/index_of() are also held as file-locals, and every caller inside this file uses those - so
rebinding the table field instruments EXTERNAL callers only. Deliberate, to keep the pcall out of
this file's tight loops, but it means the counts are "calls from outside mexpru", not "calls". ]]
local prof = require("prof")
mexpru.same              = prof.wrap("lua.same", mexpru.same)
mexpru.index_of          = prof.wrap("lua.index_of", mexpru.index_of)
mexpru.propagate_rebuild = prof.wrap("lua.propagate_rebuild", mexpru.propagate_rebuild)
mexpru.update_positions  = prof.wrap("lua.update_positions", mexpru.update_positions)

return mexpru

--[[
mexpru.lua - thin wrapper over the raw vc.mexpr_* creator functions (math_expr_composer.h) that
guarantees every mexpr_t made through it has its own, already-captured Lua table sitting in that
node's `u` field - no mexpr exists through this layer without one. Nothing here changes what the
underlying vc.mexpr_* call actually builds - it just captures a fresh {} into ret.u right after.

Bypassing this layer (calling vc.mexpr_* directly) still works exactly as before - mexpr_t::create()
(math_expr_composer.h) already pre-populates u with an empty, valid receiver either way - the only
difference is whether a *table* has actually been captured into it yet.
]]

local vc = require("virt_composer")
local char = require("char")

local mexpru = {}

-- char.lua's own m_font_sizes table length - the single canonical copy (2026-09-04's Ctrl+
-- MouseWheel zoom levels). Used to be duplicated separately across mformula_new.lua/mformula.lua/
-- mformula_latex.lua/editor.lua; char.lua's own reindexing that same day needed all four
-- hand-updated in lockstep, which is exactly the kind of drift a single shared constant avoids.
mexpru.MAX_SIZE_INDEX = 18
-- The LOGICAL size level every brand-new formula's root/first atom is built at, regardless of
-- content.lua's current zoom (mexpru.set_zoom() below) - matches char.lua's own "12 shall be the
-- default one" (36pt) exactly, so a fresh formula's root always maps back to that same physical
-- size at zoom 0. Callers that construct a brand-new formula (editor.lua's Ctrl+M/paste) pass this,
-- never content.lua's own live, possibly-already-zoomed state.font_size - see mexpru.physical_sz()
-- and mformula_new.rescale()'s own comments for why mixing those up double-counts the zoom.
mexpru.DEFAULT_SIZE = 12

local current_zoom = 0

--[[ content.lua's own global Ctrl+MouseWheel zoom offset (2026-09-04) - one value for the whole
app (content.lua's own design choice: "globally"), not threaded as an explicit parameter through
every function that ends up needing it (draw/measure/handle_input/cursor_rect/hit_test/construction,
across mformula_new.lua AND mformula_latex.lua) - Lua's single-frame, single-threaded execution here
makes a module-level global safe: content.lua calls this once, before any drawing/input-handling
runs, whenever the zoom level actually changes (not every frame). ]]
function mexpru.set_zoom(z)
    current_zoom = z
end

function mexpru.get_zoom()
    return current_zoom
end

--[[ Maps a node's own LOGICAL size level (u(_).sz's own meaning - relative, e.g. a sup/sub's own
level is its base's plus SUB_SIZE_DELTA, NEVER itself touched by zoom) to the PHYSICAL char.lua
table index actually used wherever real glyph geometry gets constructed or measured (mexpr_symbol/
mexpr_empty/mexpr_frac's own divider-line construction, char_get_sz-based font metrics). Every
LOGICAL value stored anywhere stays stable across repeated zooming - re-deriving PHYSICAL fresh from
the untouched logical value and the CURRENT zoom every time, rather than repeatedly applying a
RELATIVE delta to an already-physical value, is what keeps zooming out then back in exactly
reversible even after an intermediate step got clamped (a relative-delta scheme would silently drift
in that case - the whole reason this exists as a separate mapping instead of just mutating u(_).sz
directly, 2026-09-04 design discussion). ]]
function mexpru.physical_sz(logical)
    return math.max(1, math.min(mexpru.MAX_SIZE_INDEX, logical + current_zoom))
end

--[[ ref.u is itself a lua_object_t ref (capture/push/release) - u(ref) is just the "give me the
table" half of that, for anyone holding a mexpr ref who wants its per-node scratch table without
spelling out ref.u:push() every time. ]]
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
}

for _, name in ipairs(WRAPPED) do
    local raw = vc[name]
    mexpru[name] = function(...)
        local ret = raw(...)
        ret.u:capture({})
        return ret
    end
end

--[[ Entangled bracket pairs (2026-09-04 design discussion, revised twice same day): a bracket atom
built by mexpru.mexpr_bracket_left()/mexpru.mexpr_bracket_right() carries u(_).bracket = {is_open,
type, peer} - `peer` a reference to the OTHER atom's own u TABLE (mexpru.u(other_atom), NOT the raw
mexpr_p node itself). Originally that distinction was forced: comparing two mexpr_p handles with
`==` used to THROW, since mexpr_t had registered no __eq (fixed 2026-09-05 - see same() below). It
still holds up on its own terms now that `==` works, because
lua_object_t::push() (../utils/virt_composer.h) always hands back the SAME table for the same node
(a plain lua_rawgeti against the registry slot it was captured into, never a fresh copy) - so plain
`==` between two mexpru.u(...) results IS a real, reliable identity check, with nothing invented or
worked around: this is just an ordinary Lua table comparison, on data that was always a plain Lua
table to begin with. resolve_bracket_pairs() below leans on exactly this to find a bracket atom's own
match directly, without same()/index_of() or any depth-tracking.
Nothing but a bracket atom itself ever carries a .bracket field - an ordinary content node (the "a"
in "(a)", the "+" between two brackets, ...) has none, full stop; bracket_kind() below returns nil
for it. peer is nil while still PENDING (typed, not yet closed - mformula_new.lua's own
container.pending_bracket) and set together on BOTH atoms the moment a pair is created or rebuilt
(mformula_new.lua's try_close_bracket() at first pairing; resolve_bracket_pairs() below on every
later rebuild) - always kept in sync, never left dangling, since whoever sets one side always sets
the other in the same breath. ]]
local function bracket_kind(node)
    local u = mexpru.u(node)
    return u and u.bracket
end

--[[ Walks `children` from `idx + direction` onward (direction = 1 rightward, -1 leftward), matching
nested brackets by depth as it goes, and returns the index of the first bracket found that ISN'T
already claimed by some nested pair passed along the way - nil if the walk reaches the end without
ever finding one. Used with idx naming an ORDINARY (non-bracket) position and direction=-1: finds
the nearest bracket ENCLOSING it ("walk the horiz out in a direction... if you fail to find any
bracket on the way, then it is not bracketed at this level" - any close bracket passed along the way
belongs to an earlier, already-fully-closed group with nothing to do with idx, skipped past whole).
Returns nil when idx isn't inside any bracket pair AT THIS HORIZ's own level at all.
(A bracket atom's own match is NOT found this way - see this file's own top comment - it's a direct
.peer read. This function is kept for the one case that still needs a real walk: an ordinary node
has no .bracket field of its own to read, so there's nothing to look up directly.)
Correct without needing to check bracket TYPE while walking (only is_open) - mformula_new.lua's own
single-slot pending discipline (only one unpaired open bracket can ever exist at a time) guarantees
every closed pair in the tree is already same-type matched, so a mismatched-type crossing can never
actually arise to trip this up. Never needs identity comparison either - purely a plain-index walk
over whatever mexpru.u(_).bracket each child carries, or doesn't. ]]
--[[ What one slot of a horiz's children contributes to a running bracket count, in READING order:
+1 for an open bracket, -1 for a close, 0 for everything else.

A supsub counts as whatever its own BASE is. That is the whole reason this exists rather than each
caller testing u(_).bracket itself: a base sits in document order exactly where its compound does,
and it can BE a bracket - "(a)^{N}" is [ "(", a, supsub(base=")") ], where the closing half of that
pair is a base and not a sibling at all. Every walk that looked only at siblings was blind to it,
which is how mispaired and unbalanced states kept getting built while both the rendering and the
LaTeX looked perfectly fine. ]]
--[[ THE atom that carries a row slot's bracket meaning: the node itself, or - when that slot is a
supsub which is not a bracket in its own right - its BASE.

This exists because "(a)^{2}" is [ "(", a, supsub(base=")") ]: the closing half of that pair is a
BASE, not a sibling, so any code that walks a horiz looking at its children directly cannot see it.
That single blind spot produced four separate live bugs before it was named - cascade-delete taking
down the wrong partner, scan_bracket reporting an unrelated bracket as a boundary, the wrap counter
mis-balancing, and the sprint skipping straight over a bracket carrying an exponent. Stated once
here so the next walk over a row gets it right by construction instead of rediscovering it.

Deliberately NOT the same question as "is the cursor sitting on a base" (mformula_new.lua's own
target_is_supsub_base), which is about the cursor's own node rather than what a row slot carries -
those look alike and must not be merged. ]]
function mexpru.slot_atom(node)
    local u = mexpru.u(node)
    if not u.bracket and u.kind == "supsub" and u.base then
        return u.base
    end
    return node
end

function mexpru.bracket_delta(node)
    local br = mexpru.u(mexpru.slot_atom(node)).bracket
    if not br then
        return 0
    end
    return br.is_open and 1 or -1
end

--[[ THE counter rule, stated once: walking `children` from `from` to `to` (inclusive) in reading
order, a bracket may close only where the running count of still-open brackets is back to ZERO, and
that count may never go below zero on the way.

Returns the count at `to` when the walk stayed legal, or nil the moment it would go negative - that
negative step IS the close of the pair ENCLOSING this range, so `to` and everything past it are out
of bounds for anything opened inside it.

Requested in exactly these terms, 2026-09-05: "do the contor trick, a paranthesis can close only on
zero opened paranthesis and it can never decrease". It replaces a depth-tracked scan that answered
the same question by walking outward looking for a specific atom - which was both easy to fool (it
could not see a bracket serving as a base, so it sailed past and reported an unrelated one) and
impossible to state as a single invariant. A count is checkable at any point, over any range,
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

--[[ The same counter rule applied to a whole horiz, as a checkable invariant rather than a
question about one position. Returns (ok, count): `ok` is false the moment the running count would
go NEGATIVE - a close with nothing open, which no editing operation may ever produce - and `count`
is what is left open at the end.

count > 0 with ok true is a perfectly good mid-edit state (that's a bracket typed and not yet
closed, mformula_new.lua's own container.pending_bracket); count == 0 is fully balanced. Only
`ok == false` is corruption. Kept here beside the rule itself so tests and any future caller assert
the model's own invariant rather than restating it. ]]
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

--[[ The index of `node`'s OWN peer within `children` - a direct .peer identity read (this file's own
top comment on why plain `==` between two u tables is a real, reliable check), NOT a depth walk.
Returns nil when node isn't a bracket, has no peer yet (still pending), or - importantly - when its
peer is real but simply ISN'T in this flat list.

That last case is not hypothetical: a resolved pair's ")" can be a supsub's own BASE ("(a)^{N}" is
[ "(", a, supsub(base=")", sup=N) ] - mformula_new.lua's own close-onto-a-base path, and the shape
"(a+b)^2" needs), and a base is not a sibling in `children` at all. scan_bracket() cannot see it
there, and being a blind depth walk it doesn't fail cleanly either - it just keeps going and returns
whatever OTHER unmatched bracket it meets next, silently pairing two atoms that were never partners.
That is exactly how "((A)^{N})" lost a bracket on backspace and became the unbalanced "((A)"
(reported live 2026-09-05, "reached an invalid state"): deleting the outer ")" walked left, skipped
straight over the supsub, met the INNER "(" first and cascaded that one away instead of its own.

So: use this to find a bracket's own partner, and scan_bracket() below only for what it's actually
documented for - finding the pair that ENCLOSES an ordinary, non-bracket position.

Returns (index, is_base): `index` is the row slot holding the peer; `is_base` is true when the peer
sits in that slot's supsub BASE rather than being the slot itself - which is how a caller knows
whether removing it means splicing the row or rebuilding that supsub. Those used to be two separate
lookups (one for siblings, one for bases) that every caller had to try in turn and keep straight;
slot_atom() makes them the same search.

A BOOLEAN rather than handing back the carrying node. That began as a guard against a real trap -
a caller given two nodes would naturally compare them with `==`, which THREW before mexpr_t
registered an __eq handler (2026-09-05, see same() below). The trap is gone, but answering the
question directly is still the better shape: the caller wants "is it the base?", not a node to
re-derive that from. ]]
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
        local br = bracket_kind(children[i])
        if br and br.is_open and br.peer then
            local close_idx = i + 1
            while close_idx <= hi and mexpru.u(children[close_idx]) ~= br.peer do
                close_idx = close_idx + 1
            end

            if close_idx <= hi then
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
                -- mapping here specifically (found live 2026-09-05, alongside the sizing issue
                -- below: "behaves quite differently with different zoom levels") meant a resolved
                -- bracket pair kept rendering at whatever size it was AT WHEN LAST RESOLVED,
                -- ignoring the current zoom entirely, while everything around it correctly rescaled.
                local sz = mexpru.u(children[i]).sz
                local phys_sz = mexpru.physical_sz(sz)
                local opts = char.bracket_opts(br.type, phys_sz)
                local assembled = (#inner == 1) and inner[1] or mexpru.mexpr_merge_h(fs, inner)

                -- Two FIRST attempts at "don't let a short pair (a lone letter) shrink below a
                -- plain typed paren" (2026-09-05) forced a MINIMUM height into the tiered bracket
                -- system (mexpr_bracket_side, math_expr_composer.h) - wrong in a different way each
                -- time, but both wrong for the same underlying reason: that system's own smallest
                -- tier (char.lua's "\\bigl("/"\\bigl)", FONT_MATH_EX) isn't a same-size stand-in for
                -- an ordinary typed "(" (FONT_NORMAL) at all - it's a DIFFERENT, deliberately
                -- LARGER glyph, meant for genuinely tall content, not for matching plain text. So
                -- forcing content up to "at least as tall as a plain paren" doesn't land ON a
                -- plain-sized result - it still picks that same bigger tier, just from the other
                -- side of its own threshold. Reported live 2026-09-05: "nothing should change from
                -- '(a' to '(a)', besides the ')' appearing" - pixel-identical, not "close enough".
                --
                -- The actual fix: don't invoke the tiered system AT ALL when content is short
                -- enough that an ordinary paren already suffices - keep reusing the SAME plain
                -- glyphs (children[i]/children[close_idx], already built by open_bracket()/
                -- insert_glyph_at_cursor() at this exact phys_sz) completely untouched, exactly the
                -- pixel-identical result asked for. Only content taller than a plain paren's own
                -- real height (a fraction, a nested exponent, ...) actually needs a bigger bracket,
                -- and only THEN does the tiered system get a chance to do its own real job.
                local plain_paren = char.find_by_ascii("(")
                local paren_sz = fs:char_get_sz({size = phys_sz, code = plain_paren.ncod})
                local plain_h = math.abs(paren_sz.tr.y - paren_sz.bl.y)
                local content_bb = vc.mexpr_get_bb(assembled)
                local content_h = content_bb.br.y - content_bb.tl.y

                local new_left, new_right
                if content_h <= plain_h then
                    new_left = children[i]
                    new_right = children[close_idx]
                else
                    new_left = mexpru.mexpr_bracket_left(fs, assembled, opts)
                    new_right = mexpru.mexpr_bracket_right(fs, assembled, opts)
                    mexpru.u(new_left).sz = sz
                    mexpru.u(new_right).sz = mexpru.u(children[close_idx]).sz
                end
                mexpru.u(new_left).bracket = {is_open = true, type = br.type, peer = mexpru.u(new_right)}
                mexpru.u(new_right).bracket = {is_open = false, type = br.type, peer = mexpru.u(new_left)}

                children[i] = new_left
                children[close_idx] = new_right

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

--[[ Recursively caches a position into every node in the tree rooted at `node`, walking it exactly
the way mexpr_draw does (math_expr_composer.h's mexpr_draw_rec: pos + anch.pos at each level, via
anchor_at/anchor_len) - but writing u(node).pos instead of actually drawing anything. mexpr_t itself
only ever stores tl/br relative to its OWN local origin (see mexpr_t's own doc comment in
math_expr_composer.h) - nothing in the tree carries a position on its own, so anything that wants
one reads it here (u(node).pos) once this has been called on the tree's root.

RELATIVE to (0, 0), not absolute screen coordinates - `pos` defaults to {x=0, y=0} when omitted
(always how a root call should be made), so the whole cache stays valid across the box being
drawn somewhere else on screen (scrolled, another box above it grew/shrank, ...) without needing to
be recomputed - just add wherever the root is actually being drawn THIS frame to any cached value
to get its real screen position. Only an actual TREE EDIT (a node added/removed/moved within it)
invalidates the cache; recompute by calling this again, same as after any such edit.

Every mexpr_t reaching here already has its own u table captured - no guard, no exception (see
mexpru's own top comment: nothing here ever creates a node without one) - EXCEPT the raw, internal-
only subobjs a few of the vc.mexpr_* constructors build directly in C++ rather than through any
mexpru wrapper (mexpr_frac's own divider line, mexpr_bigop's own operator symbol - math_expr_
composer.h): those never had capture({}) called on their `u` at all, so mexpru.u() on one of them
returns nil (found 2026-09-04, adding frac support - the first kind() this file builds whose own
raw subobjs include one of these; supsub/horiz never did). Guarded here rather than made resilient
in mexpru.u() itself - nothing else in this file ever reaches one of these nodes (mformula_new.lua's
own tree walking is all done through u(_).children/.base/.sup/.sub/.num/.den, bookkeeping fields
only ever set on properly-wrapped nodes - a raw divider line is never stored in any of them), this
recursive anchor walk is the one exception. Recursion still continues into such a node's own
children (there are none - a LINE_STRIP has no subobjs of its own, so this is always the leaf), just
without writing anything into its (nonexistent) table. ]]
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

--[[ Builds (or rebuilds) a "horiz" - a plain left-to-right sequence of atoms, mexpr_merge_h under
the hood. Unlike a bare mexpru.mexpr_merge_h() call, this remembers its own exact children list
(u(ret).children) and font-size level (u(ret).sz - the level EVERY child in this horiz renders at;
mformula_new.lua's own job to keep that actually true, this is just where it's remembered) and tags
itself u(ret).kind = "horiz" - all needed by propagate_rebuild() below to redo this exact
construction later from a possibly-DIFFERENT children list, without the caller having to know how a
horiz in particular gets built (mexpr_supsub/mexpr_frac/etc. will need their own u(ret).kind and
their own rebuild recipe in propagate_rebuild() when they show up; horiz is the only one that exists
so far). `children` is kept BY REFERENCE (not copied) - propagate_rebuild() relies on being able to
splice it in place. ]]
function mexpru.horiz(fs, children, sz)
    resolve_bracket_pairs(fs, children)
    local ret = mexpru.mexpr_merge_h(fs, children)
    mexpru.u(ret).kind = "horiz"
    mexpru.u(ret).children = children
    mexpru.u(ret).sz = sz
    return ret
end

--[[ Builds (or rebuilds) a supsub node - mexpr_supsub under the hood (base required, sup/sub each
either a mexpr_p or nil). Same bookkeeping pattern as horiz() above: tags u(ret).kind = "supsub" and
remembers u(ret).base/.sup/.sub individually (a supsub has three NAMED slots, not one ordered list
the way a horiz's children are) - propagate_rebuild() below uses these to find which one changed
and redo this exact construction later. ]]
function mexpru.supsub(fs, base, sup, sub)
    local ret = mexpru.mexpr_supsub(fs, base, sup, sub)
    mexpru.u(ret).kind = "supsub"
    mexpru.u(ret).base = base
    mexpru.u(ret).sup = sup
    mexpru.u(ret).sub = sub
    return ret
end

--[[ Builds (or rebuilds) a frac node - mexpr_frac under the hood (num/den each REQUIRED, unlike
supsub's optional sup/sub - mexpr_frac itself throws without both, math_expr_composer.h). Same
bookkeeping pattern as supsub(): tags u(ret).kind = "frac" and remembers u(ret).num/.den - each
always a HORIZ (never a bare atom the way supsub's base is), both built/rebuilt together. Unlike
supsub, num/den render at ONE uniform size (u(ret).sz, same level as the fraction itself - standard
typesetting doesn't shrink them the way an exponent shrinks) - so, unlike supsub, a frac node DOES
carry its own u(_).sz directly, no base-fallback needed anywhere that reads it (cursor_target() and
cursor_rect() both already special-case reading a supsub's own sz off its base; a frac never needs
that path at all). ]]
--[[ A "vert" - N slots stacked vertically, each one a horiz, with no divider between them.
mexpr_merge_v (math_expr_composer.h) under the hood, which is the same primitive a frac's own
stacking uses minus the line.

Same bookkeeping pattern as horiz()/supsub()/frac(): tags u(ret).kind = "vert" and remembers its own
slot list (u(ret).slots, BY REFERENCE - propagate_rebuild() splices it in place, exactly as it does
with a horiz's children) plus the level everything in it renders at. Unlike supsub, and like frac,
every slot is one uniform size - a stack doesn't shrink its rows the way an exponent does. ]]
--[[ The min_cell floor (mexpr_merge_v's third argument) is derived HERE, from sz, rather than being
passed in by callers: mexpru.vert() is reached from four places (mformula_new's make_vert()/
shrink_vert(), rescale_node(), and propagate_rebuild() below), and a floor that each of them had to
remember to pass is a floor that eventually gets forgotten at one of them. Deriving it once, from
the one thing they all already supply, makes that impossible.

The two numbers are exactly mformula_new.lua's own min_extent()/cursor_metrics() pair - H's advance
for the width, G's top to g's baseline for the height - i.e. the box a still-EMPTY slot has, which
is precisely "the size the cell started with". Recomputed here rather than imported because mexpru
is the lower layer of the two (mformula_new requires mexpru, not the other way round); if a third
caller ever needs them, they should move down here and mformula_new should read them from mexpru,
not the reverse. PHYSICAL size, not logical - these are real font metrics (physical_sz()'s own
comment). ]]
local function empty_cell_extent(fs, sz)
    local physical = mexpru.physical_sz(sz)
    local G, g, H = char.find_by_ascii("G"), char.find_by_ascii("g"), char.find_by_ascii("H")
    local G_sz = fs:char_get_sz({size = physical, code = G.ncod})
    local g_sz = fs:char_get_sz({size = physical, code = g.ncod})
    local H_sz = fs:char_get_sz({size = physical, code = H.ncod})
    return {x = H_sz.adv, y = g_sz.bl.y - G_sz.tr.y}
end

function mexpru.vert(fs, slots, sz)
    local ret = mexpru.mexpr_merge_v(fs, slots, empty_cell_extent(fs, sz))
    mexpru.u(ret).kind = "vert"
    mexpru.u(ret).slots = slots
    mexpru.u(ret).sz = sz
    return ret
end

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

--[[ Identity comparison: "these two handles name the same node". Plain `==`, which mexpr_t now
registers a real handler for (math_expr_composer.h's mexpr_lua_eq, 2026-09-05) - one pointer
comparison.

It did NOT used to be. virt_composer's __eq dispatches to a per-class handler and raises "attempt to
perform operation on incompatible vc objects" when neither operand's class has registered one, and
mexpr_t hadn't - so this compared tostring() output instead, which contains the node's own pointer
and was therefore correct, but reached it by running to_string()'s std::format over that pointer and
interning the result as a Lua string, twice per call, on the path index_of() below walks in an O(n)
loop. Kept working, so nothing forced the question again, and bracket peer-linking got built on top
of it - the exact shape CLAUDE.md's Law 1 warns about, and the case it is written from.

The nil guard stays explicit: an absent operand is a real case here (a supsub's sup/sub is
legitimately nil), and "both absent" counts as the same absence. Lua never reaches __eq unless both
sides are full userdata, so it would answer false rather than error - but false is the wrong answer
for nil vs nil. ]]
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

--[[ `old_node` has just been rebuilt/replaced by `new_node` - same conceptual slot, new identity,
since a composite (a horiz or a supsub, so far) can't be mutated in place, only rebuilt from its own
remembered construction arguments (see horiz()/supsub() above). Propagates that change upward: if
old_node had no parent, new_node WAS already the tree's root - cache positions over the final tree
and return it. Otherwise, find where old_node sits in its parent's own remembered construction
(dispatched on u(parent).kind), splice new_node into that same spot, rebuild the parent from it, and
recurse the same way one level further up - this is "that node and all its parents redo the
operation they did at creation, up to the root". Works identically whether old_node/new_node are a
single ATOM being replaced (empty -> glyph), a HORIZ rebuilt from an insert/remove within its own
children list, or a horiz that just became someone's base/sup/sub (make_supsub() in
mformula_new.lua) - either way, "does old_node have a parent, and where does it sit in that parent's
own construction" is all that matters. Caller's job to reassign container.root to the returned
value.

Cuts old_node loose at EVERY level, not just the final root - each superseded intermediate ancestor
along the way lets go immediately too, same reasoning as the final root (mexpru.cut()'s own comment).
2026-09-04: this was tried and reverted once already, after it appeared to crash a test exercising
multi-level recursive rebuilds - root cause turned out to be a real bug in vc.force_release() itself
(virt_composer.cpp's force_release_ref(): it dropped self_obj without also erasing the object's own
entry in push_vc_object()'s raw-pointer-keyed weak_cache_ref, so a later object reallocated at the
same now-freed address could get handed back the old, empty-self_obj wrapper instead of a fresh one -
see that function's own comment). Fixed there; cutting every level here is safe again with that fix
in place, verified by re-running the full suite (test_lazy_supsub.lua specifically exercises the
multi-level chain that used to crash). ]]
function mexpru.propagate_rebuild(fs, old_node, new_node)
    local parent = old_node:get_parent()
    if not parent then
        mexpru.update_positions(new_node)
        mexpru.cut(old_node)
        return new_node
    end

    local kind = mexpru.u(parent).kind
    local rebuilt
    if kind == "horiz" then
        local children = mexpru.u(parent).children
        -- old_node:get_parent_idx() (math_expr_composer.h) instead of index_of() - a real C++
        -- pointer-identity scan against parent's own subobjs, valid here since `children` was JUST
        -- read fresh above and nothing's mutated it since (parent hasn't been rebuilt, so its own
        -- subobjs and this Lua list are still in exact sync - see this function's own use of
        -- get_parent_idx() elsewhere for why that stops being true after any table.insert/remove).
        children[old_node:get_parent_idx()] = new_node
        rebuilt = mexpru.horiz(fs, children, mexpru.u(parent).sz)
    elseif kind == "supsub" then
        local u = mexpru.u(parent)
        local base, sup, sub = u.base, u.sup, u.sub
        if same(base, old_node) then
            base = new_node
        elseif same(sup, old_node) then
            sup = new_node
        elseif same(sub, old_node) then
            sub = new_node
        else
            error("propagate_rebuild: old_node not found among parent supsub's base/sup/sub")
        end
        rebuilt = mexpru.supsub(fs, base, sup, sub)
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
    else
        error("propagate_rebuild: don't know how to rebuild a '" .. tostring(kind) .. "' node")
    end

    mexpru.cut(old_node)
    return mexpru.propagate_rebuild(fs, parent, rebuilt)
end

--[[ Call this on a node the CALLER has already fully cut loose - spliced out of its former
parent's own children/base/sup/sub/num/den, with propagate_rebuild() already run and
container.root already reassigned to the new tree - to make it actually let go, right now, instead
of leaving it to Lua's collector's own schedule (2026-09-04 design discussion).

Why this is needed at all: Lua's collector is a TRACING gc, not a refcounted one - an object with
zero references doesn't get destroyed the instant the last one disappears, it just becomes
eligible, and stays alive-but-orphaned until the collector's next trace happens to reach it.
Measured directly: a node survived two full forced collectgarbage("collect") passes and only died
at final Lua-state teardown. In the meantime, any WEAK ref elsewhere that still happens to point at
it (container.pending_bracket, say) reads back as "still alive" - correctly, since it genuinely
still is, just not reachable from anywhere that matters - which is exactly the shape of bug that
bit the bracket-pending path this same day.

Why calling it on just the ONE node is enough, not a whole-subtree walk: mexpr_t's own ownership
graph is a tree with no cycles (children: owning shared_ptr down, math_expr_composer.h; parent: a
raw, non-owning pointer back up) - shared_ptr's own cascading destruction already handles
everything still owned beneath whatever gets cut loose, the moment THAT node's own last reference
goes. Verified empirically the same day: releasing a single already-cut leaf node destroyed it
immediately, zero GC forcing needed, once it was genuinely its own last owner - which it always is,
right after propagate_rebuild() has already finished replacing every ancestor up to root and
nothing else has been keeping a stray reference around (the caller's own job - see
mformula_new.lua's own cascade-delete comment for the "don't touch this local again" discipline
that guarantees it).

vc.force_release(node) (virt_composer.cpp) is the actual primitive - a plain global function, not a
`node:force_release()` method (virt_composer's own per-class `:` dispatch never sees a bare
lua_setfield() onto the shared metatable - see force_release_ref()'s own comment). This is just the
documented, single, discoverable name for "yes, right here, is a safe point to call it" within this
file's own vocabulary, not a Lua wrapper doing any real work of its own. ]]
function mexpru.cut(node)
    vc.force_release(node)
end

--[[ Profiler instrumentation (prof.lua / perf_composer.h), applied here at the bottom rather than
at each definition so the whole block can be lifted out in one go, and so no call site anywhere has
to know about it. All no-ops while the profiler is off - see prof.wrap()'s own comment.

These five are the ones worth watching: same()/index_of() are the hottest small functions in the
codebase (index_of calls same() in an O(n) loop), u() is the most-CALLED of any - every tree walk
hits it once per node, and each call is a Lua -> C++ -> Lua round trip - and propagate_rebuild/
update_positions are the two that do real work per edit.

u() is deliberately NOT wrapped. It is the most-called function here, and it is also one of the
smallest - a single registry push - so the wrapper (two boundary crossings and a hash lookup) costs
several times the callee and the reported figure describes the profiler rather than the code. It was
wrapped once, reported 27us per call, and was removed on noticing that. Anything that needs to know
how often u() runs should count the boundary crossings in cpp.* instead, which are real.

NOTE the local aliases: same() and index_of() are ALSO held as file-locals (`local function same`,
`local function index_of`) and every internal caller in this file goes through those, not through
the mexpru table. Rebinding the table field therefore only instruments EXTERNAL callers. That is
deliberate - it keeps the wrapper off this file's own tight internal loops, where the pcall would
cost more than the thing being measured - but it does mean the reported counts are "calls from
outside mexpru", not "calls in total". ]]
local prof = require("prof")
mexpru.same              = prof.wrap("lua.same", mexpru.same)
mexpru.index_of          = prof.wrap("lua.index_of", mexpru.index_of)
mexpru.propagate_rebuild = prof.wrap("lua.propagate_rebuild", mexpru.propagate_rebuild)
mexpru.update_positions  = prof.wrap("lua.update_positions", mexpru.update_positions)

return mexpru

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
mexpr_p node itself). That distinction matters: mexpr_t never registered a real `__eq` with
virt_composer (see same() below, and its own comment) - comparing two mexpr_p handles with plain `==`
throws. A u table, by contrast, is an ordinary Lua table with no such wrapping at all, and
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
local function scan_bracket(children, idx, direction)
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

                local assembled = (#inner == 1) and inner[1] or mexpru.mexpr_merge_h(fs, inner)
                local sz = mexpru.u(children[i]).sz
                local opts = char.bracket_opts(br.type, sz)

                local new_left = mexpru.mexpr_bracket_left(fs, assembled, opts)
                local new_right = mexpru.mexpr_bracket_right(fs, assembled, opts)
                mexpru.u(new_left).sz = sz
                mexpru.u(new_right).sz = mexpru.u(children[close_idx]).sz
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
function mexpru.frac(fs, num, den, sz)
    local ret = mexpru.mexpr_frac(fs, num, den, char.hline_basic(sz))
    mexpru.u(ret).kind = "frac"
    mexpru.u(ret).num = num
    mexpru.u(ret).den = den
    mexpru.u(ret).sz = sz
    return ret
end

--[[ Identity comparison. NOT `==` - mexpr_t never registered an __eq handler (math_expr_composer.h),
and virt_composer's generic __eq dispatcher requires one to exist for BOTH operands' class id or it
throws ("attempt to perform operation on incompatible vc objects") rather than falling back to any
kind of default comparison - confirmed the hard way, this doesn't "just work" the way earlier
comments here assumed. mexpr_t's own to_string() override DOES embed the real underlying C++
pointer ("mexpr::mexpr_t[{ptr}] type: {}"), so comparing tostring() output is a legitimate,
no-C++-changes-needed identity check instead. Also tolerates either side being nil (a supsub's own
sup/sub can legitimately be absent). ]]
local function same(a, b)
    if a == nil or b == nil then
        return a == nil and b == nil
    end
    return tostring(a) == tostring(b)
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
value. ]]
function mexpru.propagate_rebuild(fs, old_node, new_node)
    local parent = old_node:get_parent()
    if not parent then
        mexpru.update_positions(new_node)
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
    else
        error("propagate_rebuild: don't know how to rebuild a '" .. tostring(kind) .. "' node")
    end

    return mexpru.propagate_rebuild(fs, parent, rebuilt)
end

return mexpru

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
    "mexpr_bracket", "mexpr_unarexpr", "mexpr_binexpr", "mexpr_merge_h", "mexpr_merge_v",
}

for _, name in ipairs(WRAPPED) do
    local raw = vc[name]
    mexpru[name] = function(...)
        local ret = raw(...)
        ret.u:capture({})
        return ret
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
        children[index_of(children, old_node)] = new_node
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

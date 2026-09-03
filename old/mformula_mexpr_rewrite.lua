--[[
mformula_mexpr_rewrite.lua - ARCHIVED ATTEMPT, not in use. Reconstructed from a session transcript
after the attempt was reverted (see the session's own writeup for why: scope crept past what was
asked for, and it replaced a working, tuned editor with a partial reimplementation that still had
real gaps - to_latex/from_latex, hit_test precision, cursor `side` fidelity - even in its "tested"
state). Kept here in case the approach is worth revisiting later. The live scripts/mformula.lua is
back to its original row/item-tree design; this file is inert (not required by anything).

New model this explored: mexpr_t itself as the live, edited tree - no separate row/item Lua
structure to keep in sync with it. Every node that matters for editing/navigation carries a `u`
payload (a plain Lua table, written via mexpr_t.u:capture() and read back via mexpr_t.u:push() -
see math_expr_composer.h's mexpr_t::create(), which pre-populates every node's `u` with an empty
lua_object_t so capture()/push() always have something to call) of the shape:

  {type = <string>, parent = <wref_t<mexpr_t>>, role = <string>}

`type` is set on a node that IS a compound composition ("merge_h"/"supsub"/"frac"). `parent`/`role`
are set on a node that IS a child of one, saying who its parent is and which slot it occupies
("left"/"right" for merge_h; "base"/"sup"/"sub" for supsub; "num"/"den" for frac). A node can be
both at once (a merge_h node nested inside a bigger merge_h chain has its own `type` AND its own
`parent`/`role`). EVERY node that's part of editable content is tagged this way, including plain
glyph leaves - typing a run of glyphs still builds a chain of mexpr_merge_h pairs (rows are NOT
flattened into one n-ary anchor list), and `u` is what lets Left/Right/Up/Down walk that chain
without a separate flat item list.

Edits never patch bounding boxes/positions by hand - a structural change rebuilds the spine from the
edit point up to the root by calling the base mexpr_* functions again (see wrap_pair() below),
reusing every untouched sibling subtree as-is. This happens once per edit, not once per frame/draw.

STATUS AT THE TIME OF REVERT: construction (wrap_pair/wrap_supsub/wrap_frac), mid-sequence
insert/backspace (with both-slots-empty collapse for supsub/frac), move_left/move_right,
make_supsub, make_frac, move_vertical (Up/Down), handle_input, draw, measure, hit_test,
slot_markers, and reachable_graph were implemented and tested (headlessly, and live through the
real app via debug_input_pipe). to_latex()/from_latex() were still stubbed. Known gap: entering an
ALREADY-POPULATED sup/sub/num/den slot lands the cursor after its first leaf rather than truly
before it - `side` was never fully integrated into step_left/step_right.
]]

local vc = require("virt_composer")
local char = require("char")

local mformula = {}

local SPACE_NCOD = char.find_by_ascii(" ").ncod
local CURSOR_COLOR = 0xff00ffff

-- #################################################################################################
-- Metrics - ported as-is from mformula.lua.bak, pure font-size math with no dependency on the old
-- row/item model, so nothing about this rewrite changes their behavior.
-- #################################################################################################

--[[ mexpr_symbol(is_char=true) re-centers every glyph it draws on the vertical middle of 'a' at its
own size - the one-time-per-size correction needed to add to a true baseline y before handing it to
mexpr_draw, so formula content lands exactly where plain text at the same pos would. ]]
local baseline_correction_cache = {}
local function baseline_correction(fs, sz)
    local c = baseline_correction_cache[sz]
    if c then
        return c
    end
    local a = char.find_by_ascii("a")
    local a_sz = fs:char_get_sz({size = sz, code = a.ncod})
    c = (a_sz.tr.y + a_sz.bl.y) / 2
    baseline_correction_cache[sz] = c
    return c
end

--[[ Line-height/baseline metrics at font size `sz`, from G/g's own real glyph metrics - needed so
the caret is sized from the actual font, not a flat guess. ]]
local metrics_cache = {}
local function get_metrics(fs, sz)
    local m = metrics_cache[sz]
    if m then
        return m
    end
    local G, g = char.find_by_ascii("G"), char.find_by_ascii("g")
    local G_sz = fs:char_get_sz({size = sz, code = G.ncod})
    local g_sz = fs:char_get_sz({size = sz, code = g.ncod})
    m = {line_height = g_sz.bl.y - G_sz.tr.y, baseline_shift = G_sz.tr.y}
    metrics_cache[sz] = m
    return m
end

-- #################################################################################################
-- u-payload helpers
-- #################################################################################################

local function set_meta(node, tbl)
    node.u:capture(tbl)
end

--[[ Always returns a FRESH table, never a live alias into whatever node.u currently holds -
push() hands back the exact table object it has captured, not a copy, so a caller relying on
get_meta()'s result as a snapshot (several places in this file capture "the old parent/role" before
a wrap_pair()/update_meta() call retags the same node) would otherwise see it silently change
underneath them the moment that later call mutates the very table this already returned. ]]
local function get_meta(node)
    local m = node.u:push()
    if not m then
        return {}
    end
    local copy = {}
    for k, v in pairs(m) do
        copy[k] = v
    end
    return copy
end

--[[ Merges `patch` into whatever `node.u` already holds, instead of replacing it wholesale -
needed because a single node can carry BOTH its own `type` (it's a compound itself) AND a
`parent`/`role` (it's also someone else's child) at once, set at two different times (its own
`type` when it's first built; `parent`/`role` only later, once/if something wraps it). A plain
set_meta() for the second write would silently wipe out the first. ]]
local function update_meta(node, patch)
    local meta = get_meta(node)
    for k, v in pairs(patch) do
        meta[k] = v
    end
    set_meta(node, meta)
end

local function kind_of(node)
    return get_meta(node).type
end

--[[ Per parent-kind: which child roles form a Left/Right-walkable sequence, in order, and which
roles are Up/Down-only destinations. Walking through a node's `sequence` roles (rather than hopping
over the whole node) is what lets Left/Right step through a supsub's base like normal row content -
see old mformula.lua.bak's move_left() comment. A role NOT listed in `sequence` (sup/sub, num/den)
is an Up/Down-only destination: Left/Right never descends into it - frac's `sequence` is empty
(opaque from outside, matching "a whole frac node is ONE opaque stop"), supsub's is just {"base"}. ]]
local NODE_KIND = {
    merge_h = { sequence = {"left", "right"} },
    supsub  = { sequence = {"base"}, up = "sup", down = "sub" },
    frac    = { sequence = {}, up = "num", down = "den" },
}

local function sequence_of(node)
    local k = kind_of(node)
    return k and NODE_KIND[k] and NODE_KIND[k].sequence or nil
end

--[[ Scans `node`'s own anchors for the one whose u.role is `role` - a linear scan (always ≤3
children for the kinds above) rather than a precomputed role->index table, since mexpr_supsub's own
anchor ordering depends on whether sup is present. Reading the role back off each child directly
sidesteps that entirely - this file never needs to know mexpr's own anchor-index convention for any
node kind. anchor_at(i) comes back from Lua as a single {obj, pos} table, not two return values. ]]
local function child_by_role(node, role)
    for i = 1, node:anchor_len() do
        local a = node:anchor_at(i)
        if get_meta(a[1]).role == role then
            return a[1], a[2]
        end
    end
    return nil
end

--[[ Descends into `node`'s own last (rightmost) / first (leftmost) sequence-walkable child,
repeatedly, until hitting a leaf or an opaque compound (frac) - i.e. what a cursor stepping ONTO
`node` from outside should actually land on. ]]
local function rightmost(node)
    local seq = sequence_of(node)
    if not seq or #seq == 0 then
        return node
    end
    return rightmost(child_by_role(node, seq[#seq]))
end

local function leftmost(node)
    local seq = sequence_of(node)
    if not seq or #seq == 0 then
        return node
    end
    return leftmost(child_by_role(node, seq[1]))
end

--[[ In-order successor: the leaf Right should land on, starting from `x` (already a leaf-for-
traversal-purposes). Walks up via u.parent/u.role as long as `x` is the LAST sequence role of its
parent; nil at the absolute end (no parent left to climb into). ]]
local function step_right(x)
    local cur = x
    while true do
        local meta = get_meta(cur)
        local parent = meta.parent and meta.parent:get_obj()
        if not parent then
            return nil
        end
        local seq = sequence_of(parent) or {}
        local idx = nil
        for i, r in ipairs(seq) do
            if r == meta.role then idx = i end
        end
        if idx and seq[idx + 1] then
            return leftmost(child_by_role(parent, seq[idx + 1]))
        end
        cur = parent
    end
end

--[[ Mirror of step_right(): the leaf Left should land on. ]]
local function step_left(x)
    local cur = x
    while true do
        local meta = get_meta(cur)
        local parent = meta.parent and meta.parent:get_obj()
        if not parent then
            return nil
        end
        local seq = sequence_of(parent) or {}
        local idx = nil
        for i, r in ipairs(seq) do
            if r == meta.role then idx = i end
        end
        if idx and idx > 1 then
            return rightmost(child_by_role(parent, seq[idx - 1]))
        end
        cur = parent
    end
end

--[[ Walks up from `node` through merge_h ancestors (the "row" `node` sits in) to that row's own
topmost node - the one whose parent (if any) is NOT a merge_h, i.e. the actual base/sup/sub node
itself, or the whole formula's root if there's no such parent at all. There's no separate row
object in this model - this recovers the same information ("what slot is the cursor's current row
actually IN") by walking, and is what make_supsub()/move_vertical() use for their redirect rule. ]]
local function row_root(node)
    local cur = node
    while true do
        local meta = get_meta(cur)
        local parent = meta.parent and meta.parent:get_obj()
        if not parent or kind_of(parent) ~= "merge_h" then
            return cur
        end
        cur = parent
    end
end

--[[ The absolute {x, y} offset of `node`'s own local origin (its own baseline at (0,0)), in the
same coordinate space state.root itself draws in. Walks up via u.parent, and at each level reads
back the REAL anchor position mexpr_supsub/mexpr_frac/mexpr_merge_h actually placed that child at
(via child_by_role's own anchor_at() call) rather than re-deriving any layout formula by hand. ]]
local function absolute_origin(node)
    local x, y = 0, 0
    local cur = node
    while true do
        local meta = get_meta(cur)
        local parent = meta.parent and meta.parent:get_obj()
        if not parent then
            return x, y
        end
        local _, pos = child_by_role(parent, meta.role)
        x, y = x + pos.x, y + pos.y
        cur = parent
    end
end

-- #################################################################################################
-- Construction
-- #################################################################################################

--[[ Wraps two already-built nodes `l`/`r` into one merge_h node, tagging the result with its own
kind and tagging both children with their parent + role. This is the ONLY place mexpr_merge_h ever
gets called in this file, so every merge_h node this editor builds is guaranteed tagged. ]]
local function wrap_pair(fs, l, r)
    local merged = vc.mexpr_merge_h(fs, l, r)
    update_meta(merged, {type = "merge_h"})
    local mw = vc.wref_mexpr(merged)
    update_meta(l, {parent = mw, role = "left"})
    update_meta(r, {parent = mw, role = "right"})
    return merged
end

--[[ A reasonable pixel size for an empty-formula placeholder box at font size `sz`, based on 'a's
own advance width/height at that size. ]]
local function placeholder_size(fs, sz)
    local a = char.find_by_ascii("a")
    local a_sz = fs:char_get_sz({size = sz, code = a.ncod})
    return {w = math.max(a_sz.adv, 4), h = math.max(a_sz.bl.y - a_sz.tr.y, 4)}
end

--[[ An empty placeholder box - used both as the whole formula's own empty root AND as a fresh,
not-yet-typed-into sup/sub/num/den slot. Tagged with the size it was built at (`sz`) so node_sz()
below can read it straight back off the node itself, the same way it reads a plain glyph's own
.symb.size - no separate cursor.sz bookkeeping needed anywhere in this file. ]]
local function new_empty(fs, sz)
    local ph = placeholder_size(fs, sz)
    local node = vc.mexpr_empty(fs, ph.w, ph.h, ph.h / 2)
    set_meta(node, {type = "empty", sz = sz})
    return node
end

--[[ The effective font size for wherever `node` sits - a plain glyph's own .symb.size, or an
"empty" placeholder's own tagged sz - read directly off the node itself rather than tracked
separately on the cursor. `node` is always a leaf/placeholder here, never a compound. ]]
local function node_sz(node)
    if kind_of(node) == "empty" then
        return get_meta(node).sz
    end
    return node.symb.size
end

-- How much smaller (in font-size-table steps) a sup/sub renders than its base.
local SUB_SIZE_DELTA = 1
local MAX_SIZE_INDEX = 16

local function sub_size(sz)
    return math.min(sz + SUB_SIZE_DELTA, MAX_SIZE_INDEX)
end

--[[ Wraps `base` (built at `sz`) with `sup`/`sub` (built at sub_size(sz)) into one supsub node,
tagging the result and all three children with their role - mirrors wrap_pair(). Both sup and sub
are always real (possibly-empty) subtrees, never omitted - matches old make_supsub()'s "the opposite
slot gets an empty placeholder too, right away" rule. ]]
local function wrap_supsub(fs, sz, base, sup, sub)
    local merged = vc.mexpr_supsub(fs, base, sup, sub)
    update_meta(merged, {type = "supsub"})
    local mw = vc.wref_mexpr(merged)
    update_meta(base, {parent = mw, role = "base"})
    update_meta(sup, {parent = mw, role = "sup"})
    update_meta(sub, {parent = mw, role = "sub"})
    return merged
end

--[[ Wraps `num`/`den` (both built at `sz` - unlike supsub, a fraction's num/den DON'T shrink) into
one frac node, tagging the result and both children with their role. num/den are never optional the
way a not-yet-visited sup/sub can be - mexpr_frac requires both to render at all. ]]
local function wrap_frac(fs, sz, num, den)
    local merged = vc.mexpr_frac(fs, num, den, char.hline_basic(sz))
    update_meta(merged, {type = "frac"})
    local mw = vc.wref_mexpr(merged)
    update_meta(num, {parent = mw, role = "num"})
    update_meta(den, {parent = mw, role = "den"})
    return merged
end

--[[ Where the cursor should land right after entering `target` (a sup/sub/num/den slot, fresh or
already-populated) - the start of it, matching old make_supsub()/move_vertical()'s "always land at
position 0" rule. For an empty slot this is unambiguous. For an already-populated one this lands
AFTER its first leaf rather than truly before it (this file's `side` isn't fully wired into
step_left/step_right - see this file's own header comment) - rare in practice since a freshly-
created slot always starts empty. ]]
local function enter_start(target)
    if kind_of(target) == "empty" then
        return {node = target, side = "after"}
    end
    return {node = leftmost(target), side = "after"}
end

--[[ state = {root=<mexpr_p>, cursor={node=<mexpr_p>, side="before"|"after"}, fs=, sz=}. `fs`/`sz`
are part of the state itself - every edit builds real, concretely-sized mexpr_t nodes immediately,
there's no separate draw-time layout pass left to defer sizing to. ]]
function mformula.new(fontset, sz)
    local root = new_empty(fontset, sz)
    return {
        root = root,
        cursor = {node = root, side = "after"},
        fs = fontset,
        sz = sz,
    }
end

local function sibling_role(role)
    return role == "left" and "right" or "left"
end

--[[ Clears a stale parent/role tag - e.g. once splice_replace() below bottoms out and `new_node`
becomes the new root, any parent/role left over from when it used to be someone's child would
otherwise stay stuck on it forever. NOT the same as update_meta(node, {parent=nil, role=nil}) -
Lua's pairs() never iterates a table's nil-valued entries, so patching in explicit nils through
update_meta() would be a silent no-op; this instead removes the keys from a real snapshot copy
before writing it back. ]]
local function clear_parent(node)
    local meta = get_meta(node)
    meta.parent = nil
    meta.role = nil
    set_meta(node, meta)
end

--[[ Replaces the child at `role` within `parent` with `new_node`, rebuilds `parent` (via the same
base function that originally built it - merge_h/supsub/frac), and recursively does the same one
level further up, using `parent`'s OWN parent/role - climbing the whole spine from the edit point to
the root, never patching an existing node's bounding box/position by hand. Every level's rebuild is
a real wrap_pair()/wrap_supsub()/wrap_frac() call, which is also what keeps parent/role tags correct
on every untouched sibling it reuses - no separate "reindex" pass needed. `parent = nil` is the base
case: `new_node` IS the new root. ]]
local function splice_replace(state, parent, role, new_node)
    if not parent then
        clear_parent(new_node)
        return new_node
    end
    local parent_meta = get_meta(parent)
    local pk = kind_of(parent)
    local rebuilt
    if pk == "merge_h" then
        local l = child_by_role(parent, "left")
        local r = child_by_role(parent, "right")
        if role == "left" then l = new_node else r = new_node end
        rebuilt = wrap_pair(state.fs, l, r)
    elseif pk == "supsub" then
        local base = child_by_role(parent, "base")
        local sup = child_by_role(parent, "sup")
        local sub = child_by_role(parent, "sub")
        local sz = node_sz(base) -- read BEFORE any of the three below get replaced
        if role == "base" then base = new_node
        elseif role == "sup" then sup = new_node
        else sub = new_node end
        rebuilt = wrap_supsub(state.fs, sz, base, sup, sub)
    elseif pk == "frac" then
        local num = child_by_role(parent, "num")
        local den = child_by_role(parent, "den")
        local sz = node_sz(role == "num" and den or num) -- read from whichever side ISN'T being replaced
        if role == "num" then num = new_node else den = new_node end
        rebuilt = wrap_frac(state.fs, sz, num, den)
    else
        error("splice_replace: parent kind '" .. tostring(pk) .. "' not supported yet")
    end
    local gp = parent_meta.parent and parent_meta.parent:get_obj()
    return splice_replace(state, gp, parent_meta.role, rebuilt)
end

--[[ NODE_KIND[kind].up/.down are supsub/frac's only two non-base/non-sequence roles ("sup"/"sub",
"num"/"den") - given one of them, this is the other. Used by backspace()'s both-slots-empty collapse
check to find the sibling slot without hardcoding which kind it's asking about. ]]
local function other_up_down_role(parent, role)
    local ki = NODE_KIND[kind_of(parent)]
    if not ki then
        return nil
    end
    if role == ki.up then return ki.down end
    if role == ki.down then return ki.up end
    return nil
end

--[[ Removes `node` entirely from the tree, promoting/collapsing whatever's left in its place, and
returns the node the cursor should land on afterward:
- no parent (node WAS the whole root) - the formula becomes empty; returns the fresh empty root.
- parent is merge_h - node's sibling takes its place; returns that sibling.
- parent is supsub/frac - can't remove a mandatory slot outright, only empty it; returns the fresh
  empty placeholder. (Used by backspace()'s frac-collapse, where `node` is the frac node itself.) ]]
local function delete_node(state, node)
    local meta = get_meta(node)
    local parent = meta.parent and meta.parent:get_obj()

    if not parent then
        state.root = new_empty(state.fs, state.sz)
        return state.root
    end

    local pk = kind_of(parent)
    if pk == "supsub" or pk == "frac" then
        local empty = new_empty(state.fs, node_sz(node))
        state.root = splice_replace(state, parent, meta.role, empty)
        return empty
    end

    local sibling = child_by_role(parent, sibling_role(meta.role))
    local parent_meta = get_meta(parent)
    local grandparent = parent_meta.parent and parent_meta.parent:get_obj()
    state.root = splice_replace(state, grandparent, parent_meta.role, sibling)
    return sibling
end

--[[ Inserts glyph `ncod` right after the cursor - anywhere in the formula, not just at the end, at
whatever size the cursor's current position calls for (node_sz(cur), not a flat state.sz - typing
inside a sup/sub needs the smaller size). `cur_meta` is captured BEFORE wrap_pair()/splice_replace()
below, since those immediately re-tag `cur`'s own parent/role.

If `cur` is itself an empty placeholder (a brand new formula, or an untyped-into sup/sub slot), the
glyph replaces it directly rather than wrap_pair()-ing alongside it. ]]
function mformula.insert_glyph(state, ncod, size_off)
    local cur = state.cursor.node
    local base_sz = node_sz(cur)
    local sz = size_off and math.max(1, base_sz + size_off) or base_sz
    local glyph = vc.mexpr_symbol(state.fs, {size = sz, code = ncod}, true)
    local cur_meta = get_meta(cur)
    local parent = cur_meta.parent and cur_meta.parent:get_obj()

    if kind_of(cur) == "empty" then
        state.root = splice_replace(state, parent, cur_meta.role, glyph)
        state.cursor = {node = glyph, side = "after"}
        return
    end

    local new_pair = wrap_pair(state.fs, cur, glyph)
    state.root = splice_replace(state, parent, cur_meta.role, new_pair)
    state.cursor = {node = glyph, side = "after"}
end

--[[ Removes the glyph the cursor is right after - anywhere in the formula.

If `cur`'s parent is a supsub/frac directly (cur is the sole leaf occupying a base/sup/sub/num/den):
- if `cur` has real content, this empties that slot (first backspace on a populated slot).
- if `cur` is ALREADY an empty placeholder AND the sibling slot is ALSO empty, the whole node
  collapses away (ported from old collapse_if_both_empty()/collapse_frac_if_both_empty()). A supsub
  collapses into just its base; a frac has no base to fall back to, so it's deleted outright via
  delete_node().
- if `cur` is already empty but the sibling isn't, there's nothing to delete - just navigate left. ]]
function mformula.backspace(state)
    if kind_of(state.root) == "empty" then
        return
    end

    local cur = state.cursor.node
    local cur_meta = get_meta(cur)
    local parent = cur_meta.parent and cur_meta.parent:get_obj()

    if not parent then
        state.root = new_empty(state.fs, state.sz)
        state.cursor = {node = state.root, side = "after"}
        return
    end

    local pk = kind_of(parent)
    if pk == "supsub" or pk == "frac" then
        if kind_of(cur) ~= "empty" then
            local empty = new_empty(state.fs, node_sz(cur))
            state.root = splice_replace(state, parent, cur_meta.role, empty)
            state.cursor = {node = empty, side = "after"}
            return
        end

        local sib_role = other_up_down_role(parent, cur_meta.role)
        local sibling = sib_role and child_by_role(parent, sib_role)
        if not sibling or kind_of(sibling) ~= "empty" then
            mformula.move_left(state)
            return
        end

        if pk == "supsub" then
            local base = child_by_role(parent, "base")
            local parent_meta = get_meta(parent)
            local grandparent = parent_meta.parent and parent_meta.parent:get_obj()
            state.root = splice_replace(state, grandparent, parent_meta.role, base)
            state.cursor = {node = rightmost(base), side = "after"}
        else
            local landed = delete_node(state, parent)
            state.cursor = {node = landed, side = "after"}
        end
        return
    end

    local new_cursor = step_left(cur)
    delete_node(state, cur)
    if new_cursor then
        state.cursor = {node = new_cursor, side = "after"}
    else
        state.cursor = {node = leftmost(state.root), side = "before"}
    end
end

--[[ Delete key: removes the glyph right AFTER the cursor. Implemented in terms of backspace()
itself - move the cursor onto the next node, let backspace() splice, then restore the cursor to
where it started. ]]
function mformula.delete_fwd(state)
    local nxt = step_right(state.cursor.node)
    if not nxt then
        return
    end
    local saved = state.cursor
    state.cursor = {node = nxt, side = "after"}
    mformula.backspace(state)
    state.cursor = saved
end

function mformula.move_left(state)
    local nxt = step_left(state.cursor.node)
    if nxt then
        state.cursor = {node = nxt, side = "after"}
    end
end

function mformula.move_right(state)
    local nxt = step_right(state.cursor.node)
    if nxt then
        state.cursor = {node = nxt, side = "after"}
    end
end

--[[ Ctrl+Shift+'-'/'+' (slot="sub"/"sup"): wraps the glyph immediately before the cursor into a
new supsub node's base, and jumps the cursor into `slot`.

Redirect rule: if the cursor's current row IS ALREADY a supsub's base/sup/sub, and `slot` isn't the
one it's already in, this adds `slot` directly to THAT SAME node instead of nesting a new node
around whatever's before the cursor. Only asking for the SAME slot falls through to nesting further
- an exponent tower ("A^(N^N)").

Only the cursor.side=="after" case is implemented - old make_supsub()'s "cursor at the very start of
a row -> empty base" case isn't ported. ]]
function mformula.make_supsub(state, slot)
    local root = row_root(state.cursor.node)
    local root_meta = get_meta(root)
    local enclosing = root_meta.parent and root_meta.parent:get_obj()

    if enclosing and kind_of(enclosing) == "supsub" and root_meta.role ~= slot then
        state.cursor = enter_start(child_by_role(enclosing, slot))
        return
    end

    if state.cursor.side ~= "after" then
        error("mformula.make_supsub: cursor not positioned after a glyph - not implemented yet")
    end

    local base = state.cursor.node
    local base_meta = get_meta(base)
    local sz = node_sz(base)
    local sup = new_empty(state.fs, sub_size(sz))
    local sub = new_empty(state.fs, sub_size(sz))
    local node = wrap_supsub(state.fs, sz, base, sup, sub)

    local parent = base_meta.parent and base_meta.parent:get_obj()
    state.root = splice_replace(state, parent, base_meta.role, node)
    state.cursor = enter_start(slot == "sup" and sup or sub)
end

--[[ Ctrl+/: inserts a new, empty fraction at the cursor and jumps into its numerator. Never wraps
anything already there and never redirects into an enclosing node - a fraction has no single
preceding glyph that obviously belongs in either half, and there's no "already in a fraction, add
the other half to THIS one" rule.

If the cursor sits on an empty placeholder, the fraction replaces it directly. Otherwise the
fraction is inserted right after the cursor, alongside whatever's already there, like insert_glyph()
does for a plain glyph. ]]
function mformula.make_frac(state)
    local cur = state.cursor.node
    local sz = node_sz(cur)
    local num = new_empty(state.fs, sz)
    local den = new_empty(state.fs, sz)
    local frac = wrap_frac(state.fs, sz, num, den)

    local cur_meta = get_meta(cur)
    local parent = cur_meta.parent and cur_meta.parent:get_obj()

    if kind_of(cur) == "empty" then
        state.root = splice_replace(state, parent, cur_meta.role, frac)
    else
        local new_pair = wrap_pair(state.fs, cur, frac)
        state.root = splice_replace(state, parent, cur_meta.role, new_pair)
    end

    state.cursor = enter_start(num)
end

--[[ Up (want_up=true) / Down (want_up=false). Enters the up/down slot (NODE_KIND[kind].up/.down)
of whatever supsub/frac node the cursor's current row is a slot of - same row_root()-based rule
make_supsub() uses for its OWN redirect, generalized across both kinds here the way old
move_vertical()'s UP_SLOT/DOWN_SLOT tables did. Silently does nothing if there's no node to enter
from here. ]]
function mformula.move_vertical(state, want_up)
    local root = row_root(state.cursor.node)
    local root_meta = get_meta(root)
    local enclosing = root_meta.parent and root_meta.parent:get_obj()
    if not enclosing then
        return
    end

    local kind_info = NODE_KIND[kind_of(enclosing)]
    local slot = kind_info and (want_up and kind_info.up or kind_info.down)
    if slot and root_meta.role ~= slot then
        state.cursor = enter_start(child_by_role(enclosing, slot))
    end
end

--[[ Ctrl+/ pressed in PLAIN TEXT (editor.lua), before any formula exists yet - mirrors Ctrl+M's
plain mformula.new(fontset, sz), just starting with an empty fraction already in it. ]]
function mformula.new_with_frac(fontset, sz)
    local state = mformula.new(fontset, sz)
    mformula.make_frac(state)
    return state
end

--[[ Ctrl+Shift+'-'/'+' pressed in PLAIN TEXT (editor.lua) - lets that pull the character the
cursor's sitting after straight into a brand new formula. `base_item` is one of editor.lua's own
plain-text glyph items ({code=, size_off=}), or nil (base left empty). ]]
function mformula.new_from_base(base_item, slot, fontset, sz)
    local state = mformula.new(fontset, sz)
    if base_item then
        local base_sz = base_item.size_off and math.max(1, sz + base_item.size_off) or sz
        local glyph = vc.mexpr_symbol(fontset, {size = base_sz, code = base_item.code}, true)
        state.root = glyph
        state.cursor = {node = glyph, side = "after"}
    end
    mformula.make_supsub(state, slot)
    return state
end

--[[ Reads and dispatches this frame's keyboard input, the same key bindings as
mformula.lua.bak's own handle_input() had.

A no-op on a still-stubbed from_latex() result (state.cursor == nil) - every editing function this
dispatches to assumes a real state.cursor.node exists, and this is the ONLY path anything ever
reaches them through, so one guard here is enough to make clicking into a formula loaded from saved
content harmless instead of a crash. ]]
function mformula.handle_input(state)
    if not state.cursor then
        return
    end

    local is_ctrl = vc.ImGui_IsKeyDown("ImGuiKey_LeftCtrl") or vc.ImGui_IsKeyDown("ImGuiKey_RightCtrl")
    local is_shift = vc.ImGui_IsKeyDown("ImGuiKey_LeftShift") or vc.ImGui_IsKeyDown("ImGuiKey_RightShift")
    local is_alt = vc.ImGui_IsKeyDown("ImGuiKey_LeftAlt") or vc.ImGui_IsKeyDown("ImGuiKey_RightAlt")

    if is_ctrl and is_shift and vc.ImGui_IsKeyPressed("ImGuiKey_Minus", false) then
        mformula.make_supsub(state, "sub")
        return
    end
    if is_ctrl and is_shift and vc.ImGui_IsKeyPressed("ImGuiKey_Equal", false) then
        mformula.make_supsub(state, "sup")
        return
    end
    if is_ctrl and not is_shift and vc.ImGui_IsKeyPressed("ImGuiKey_Slash", false) then
        mformula.make_frac(state)
        return
    end

    if not is_ctrl and vc.ImGui_IsKeyPressed("ImGuiKey_Space", true) then
        mformula.insert_glyph(state, SPACE_NCOD)
        return
    end

    if is_alt then
        for key_name, letter in pairs(char.greek_keys) do
            if vc.ImGui_IsKeyPressed(key_name, true) then
                local desc = is_shift and char.greek_alt_shift[letter] or char.greek_alt[letter]
                local entry = desc and char.find_by_desc(desc)
                if not entry then
                    entry = char.find_by_ascii(is_shift and letter:upper() or letter)
                end
                if entry then
                    mformula.insert_glyph(state, entry.ncod, char.size_delta_by_desc[entry.desc])
                end
            end
        end
    elseif not is_ctrl then
        local codepoints = vc.ImGui_input_queue_chars()
        for _, cp in ipairs(codepoints) do
            if cp > 32 and cp < 256 then
                local entry = char.find_by_ascii(string.char(cp))
                if entry then
                    mformula.insert_glyph(state, entry.ncod)
                end
            end
        end
    end

    if vc.ImGui_IsKeyPressed("ImGuiKey_Backspace", true) then mformula.backspace(state) end
    if vc.ImGui_IsKeyPressed("ImGuiKey_Delete", true) then mformula.delete_fwd(state) end
    if vc.ImGui_IsKeyPressed("ImGuiKey_LeftArrow", true) then mformula.move_left(state) end
    if vc.ImGui_IsKeyPressed("ImGuiKey_RightArrow", true) then mformula.move_right(state) end
    if vc.ImGui_IsKeyPressed("ImGuiKey_UpArrow", true) then mformula.move_vertical(state, true) end
    if vc.ImGui_IsKeyPressed("ImGuiKey_DownArrow", true) then mformula.move_vertical(state, false) end
end

-- #################################################################################################
-- Layout / render
-- #################################################################################################

--[[ Collects every valid cursor position reachable in `node`'s own subtree - every plain glyph and
every "empty" placeholder, at ANY depth (base/sup/sub/num/den included, not just what Left/Right can
reach) - into `out` as {node=, x=, y=, sz=} entries. Used by hit_test()/reachable_graph(). ]]
local function collect_positions(node, ox, oy, out)
    if not node then
        return
    end
    local k = kind_of(node)
    if k == "merge_h" or k == "supsub" or k == "frac" then
        for i = 1, node:anchor_len() do
            local a = node:anchor_at(i)
            collect_positions(a[1], ox + a[2].x, oy + a[2].y, out)
        end
    else
        out[#out + 1] = {node = node, x = ox + vc.mexpr_get_bb(node).br.x, y = oy, sz = node_sz(node)}
    end
end

--[[ {width=, top=, bottom=} for `state`'s current tree at font size `sz`. state.root already IS
the fully-built, concretely-sized mexpr tree, so this is just reading its bounding box back. ]]
function mformula.measure(state, fontset, sz)
    local correction = baseline_correction(fontset, sz)
    local bb = vc.mexpr_get_bb(state.root)
    return {
        width = bb.br.x - bb.tl.x,
        top = correction + bb.tl.y,
        bottom = correction + bb.br.y,
    }
end

--[[ Draws state.root at `pos` (its baseline origin) using base font size `sz`. The blinking caret
is only drawn when `show_cursor` is true. ]]
function mformula.draw(state, fontset, pos, sz, show_cursor)
    if show_cursor == nil then
        show_cursor = true
    end

    local correction = baseline_correction(fontset, sz)
    local draw_pos = {x = pos.x, y = pos.y + correction}
    -- mexpr_draw() (unlike mexpr_get_bb()/mexpr_draw_rec()) does NOT null-check its own mexpr_p
    -- argument - state.root can be nil for a still-stubbed from_latex() result.
    if state.root then
        vc.mexpr_draw(fontset, draw_pos, state.root, false)
    end

    state.frame = (state.frame or 0) + 1
    local cursor_top, cursor_h = nil, nil
    if show_cursor and state.cursor and state.cursor.node then
        local ox, oy = absolute_origin(state.cursor.node)
        local caret_sz = node_sz(state.cursor.node)
        local cx = draw_pos.x + ox + vc.mexpr_get_bb(state.cursor.node).br.x
        local cy = draw_pos.y + oy - baseline_correction(fontset, caret_sz)
        local cm = get_metrics(fontset, caret_sz)
        local caret_top = cy + cm.baseline_shift
        cursor_top, cursor_h = caret_top - pos.y, cm.line_height
        if math.floor(state.frame / 30) % 2 == 0 then
            vc.ImGui_AddLine({x = cx, y = caret_top}, {x = cx, y = caret_top + cm.line_height},
                    CURSOR_COLOR, 2)
        end
    end

    local bb = vc.mexpr_get_bb(state.root)
    return {
        width = bb.br.x - bb.tl.x,
        top = correction + bb.tl.y,
        bottom = correction + bb.br.y,
        cursor_top = cursor_top,
        cursor_h = cursor_h,
    }
end

--[[ Where a click at `click` should place the cursor - the nearest of every reachable position by
straight Euclidean distance. Simpler than old mformula.lua.bak's own hit_test() (which preferred
depth and x-span containment before falling back to nearest). @return {node=, side="after"} ]]
function mformula.hit_test(state, fontset, sz, click)
    local correction = baseline_correction(fontset, sz)
    local positions = {}
    collect_positions(state.root, 0, 0, positions)

    local best, best_dist = nil, math.huge
    for _, p in ipairs(positions) do
        local cm = get_metrics(fontset, p.sz)
        local dy = correction + p.y - baseline_correction(fontset, p.sz)
        local mid = dy + cm.baseline_shift + cm.line_height / 2
        local dx, dyc = click.x - p.x, click.y - mid
        local dist = dx * dx + dyc * dyc
        if dist < best_dist then
            best_dist = dist
            best = p.node
        end
    end

    if not best then
        return state.cursor
    end
    return {node = best, side = "after"}
end

--[[ Debug aid: every cursor position reachable in the tree, as {x, y} pixel offsets from the
formula's own draw origin. Simpler than old reachable_graph() - no reciprocal-edge graph, just the
dots; `edges` is always empty. ]]
function mformula.reachable_graph(state, fontset, sz)
    local correction = baseline_correction(fontset, sz)
    local positions = {}
    collect_positions(state.root, 0, 0, positions)

    local nodes = {}
    for _, p in ipairs(positions) do
        local cm = get_metrics(fontset, p.sz)
        local dy = correction + p.y - baseline_correction(fontset, p.sz)
                + cm.baseline_shift + cm.line_height / 2
        nodes[#nodes + 1] = {x = p.x, y = dy}
    end
    return {nodes = nodes, edges = {}}
end

--[[ A marker rect for every "empty" placeholder in the tree. Simpler than old slot_markers() (which
also placed a trailing marker after every FILLED row, and a marker at every space glyph) - this only
covers empty slots. ]]
function mformula.slot_markers(state, fontset, sz)
    local correction = baseline_correction(fontset, sz)
    local positions = {}
    collect_positions(state.root, 0, 0, positions)

    local markers = {}
    for _, p in ipairs(positions) do
        if kind_of(p.node) == "empty" then
            local ph = placeholder_size(fontset, p.sz)
            local cm = get_metrics(fontset, p.sz)
            local dy = correction + p.y - baseline_correction(fontset, p.sz)
            markers[#markers + 1] = {
                x = p.x - ph.w, y = dy + cm.baseline_shift, w = ph.w, h = cm.line_height,
            }
        end
    end
    return markers
end

-- #################################################################################################
-- Stubs - never implemented for real. to_latex() always returns "", from_latex() ignores its
-- input and produces an inert empty-ish state.
-- #################################################################################################

function mformula.to_latex(state)
    return ""
end

function mformula.from_latex(s)
    return {root = nil, cursor = nil, fs = nil, sz = nil, is_stub = true}
end

-- Exposed for testing only - not part of the stable public API.
mformula._internal = {
    set_meta = set_meta,
    get_meta = get_meta,
    kind_of = kind_of,
    child_by_role = child_by_role,
    wrap_pair = wrap_pair,
    wrap_supsub = wrap_supsub,
    wrap_frac = wrap_frac,
    step_left = step_left,
    step_right = step_right,
    row_root = row_root,
    node_sz = node_sz,
    sub_size = sub_size,
    absolute_origin = absolute_origin,
    collect_positions = collect_positions,
    delete_node = delete_node,
    other_up_down_role = other_up_down_role,
}

return mformula

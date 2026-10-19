--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | layout(fontset: fontset, container: mexpru.container, sz: size, wrap_width: number,
-- |        decls_of: function, draw_x: number, draw_y: number) -> record | nil
-- |     Lays out where every term selector of a formula sits this frame,
-- |     in screen space; nil when the formula does not parse or holds no
-- |     sum whose terms lie in its own row.
-- |
-- | current(record: record | nil, container: mexpru.container) -> boolean
-- |     Answers whether a record still describes the container's tree.
-- |
-- | draw(record: record, held: id | false | nil) -> nothing
-- | draw_icon(rect: {x,y,w,h}, on: boolean) -> nothing
-- |     Draw the selectors under the formula, and the toggle button's
-- |     picture of one. Only a selector lights up, never a term's glyphs.
-- |
-- | selector_at(record: record | nil, point: {x,y} | nil) -> selector | nil
-- | drop_at(record: record | nil, fontset: fontset, add: id, term: id, point: {x,y} | nil)
-- |      -> drop | nil, reason
-- | draw_drag(record: record, drag: table, point: {x,y} | nil) -> nothing
-- |     selector_at finds the selector a press is on; drop_at finds the
-- |     gap among the term's own siblings a point lands it in, with the
-- |     reorder option that puts it there; draw_drag draws the ghost and
-- |     the gap's marker on top of the page.
-- |
-- | --- internal, not on the module table ---------------------------------------------------------
-- |     the term runs, the per-row segments, the gap marks and the per-container cache
-- |
-- | @date 19-10-2026-21:18
-- | ===============================================================================================
--]]

--[[
term_selectors.lua draws the term selectors - a small ring and an underline under every term of a
locked formula's sums - and works out what a drag of one means: a move of the term to another
place among its siblings.

The selectors are meta-information about the formula's structure and handles for that one drag
(the author, 19-10-2026: "the right click is for now for symbols and those selectors are meta-info
regarding the structure of the formula and also handles for this dragging operation"). The drop
becomes the "reorder" transformation, run like a menu pick, so its result is a new locked box.

GLYPHS DRAW, TRANSFORMS WALK (DESIGN.md, 2026-09-15): the parse records nothing new for this file.
A term's glyphs are found after the parse, from the tags it already writes and the ast above them.
Every tagged slot of the root row belongs to the terms its node sits in, a term is one contiguous
run of slots in one row (the parse splits a row at its signs), and the brackets that belong to a
term join its run. So do the glyphs the parse reads into a term without tagging them - an
operator's name, \infty, a declared name's primes, a quoted name - since what follows a term up to
the next sign is still that term; before the first term they belong to the first.

Only sums whose terms lie in the formula's own row get selectors for now - bracketed sums, call
arguments and bigop bodies in that row included. A sum inside an exponent, a subscript, a
fraction, a limit or a stack lies in another row and gets none.

The lines are level by depth (the author, 19-10-2026: "level when on the same level, I think that
is for the best"): sums at one nesting depth share one line, the innermost nearest the glyphs and
the outermost lowest. A term crossing a row break of a wrapped formula gets one underline per row,
the ring on the first ("no, make the selectors wrap too"). Rows touch and their pitch is the
wrap's own, so the lines under a row overlap the top of the next row - accepted for now, and a
drop on those lines reads as on the row they underline.

@date 19-10-2026-22:23
]]

local vc = require("virt_composer")
local char = require("char")
local mexpru = require("mexpru")
local mexpr_ast = require("mexpr_ast")
local mformula = require("mformula_new")
local ast = require("ast")
local ast_gestures = require("ast_gestures")
local transforms = require("transforms")

local term_selectors = {}

--[[ These are the selector's measures, in pixels: the ring's radius and its gap to the line, the
first line's distance below a row's bottom and the pitch between levels, how near a press must
come, how far outside the formula a release still finds a gap, and how far outside its sum an end
gap's marker stands when nothing is drawn beside it. LINE_PITCH stays above twice HIT_SLOP, so a
press between two levels' lines lands on at most one of them. LINE_GAP clears the locked field's
contour, which editor_formula draws 3 px below the formula's measured bottom: at 4 the first line
sat on it (seen live 19-10-2026). ROW_GAP is the first line's distance below the ink of a wrapped
row that another row follows: rows touch, so those lines cross into the next row's band, and the
nearer they stay to their own ink the less of the next row's letters they strike.
@date 19-10-2026-21:22 ]]
local RING_R      = 2.5
local RING_GAP    = 1.5
local LINE_GAP    = 7
local ROW_GAP     = 3
local LINE_PITCH  = 8
local HIT_SLOP    = 3
local DROP_SLOP   = 12
local MARKER_PAD  = 3

--[[ A selector is idle gray and lit white, because orange, blue and green already mean globals,
bound variables and structural marks (DESIGN.md's palette, 2026-09-16). 0xAABBGGRR. The idle gray
is lighter than the chrome row's 0xff888888 because the box's translucent fill is drawn over the
selectors and dims them; at that gray they were barely visible (seen live 19-10-2026).
@date 19-10-2026-21:18 ]]
local IDLE_COLOR  = 0xffb4b4b4
local LIT_COLOR   = 0xffffffff
local GHOST_COLOR = 0x88ffffff

-- #################################################################################################
-- Which slots a term draws with
-- #################################################################################################

--[[ Collects every ast id the parse wrote anywhere inside one row slot - the slot's own tag and its
leaves'. @date 19-10-2026-21:02 ]]
local function slot_ids(node, out)
    local u = mexpru.u(node)
    if not u then
        return out
    end
    if u.ast_id then
        out[#out + 1] = u.ast_id
    end
    if u.ast_draws then
        out[#out + 1] = u.ast_draws
    end
    for _, child in ipairs(mexpru.child_links(node)) do
        slot_ids(child, out)
    end
    return out
end

--[[ Lists every sum the ast node `id` sits in, innermost first, as {add, index}: the sum, and the
place among its terms of the term holding the node. @date 19-10-2026-21:02 ]]
local function memberships(id, parents)
    local out = {}
    local child, parent = id, parents[id]
    while parent do
        if parent.type == ast.ADD then
            for k = 1, #parent do
                if parent[k].id == child then
                    out[#out + 1] = {add = parent, index = k}
                    break
                end
            end
        end
        child, parent = parent.id, parents[parent.id]
    end
    return out
end

--[[ Gives the memberships of every slot of the row, from its tags; an untagged slot has none.

A SLOT WHOSE IDS ALL NAME NODES OUTSIDE THE TREE belongs where the slot before it does. That is the
digit of a folded unit: the parse reads `+1` by minting a new numeral that carries the sign, tags
the sign glyph with it, and leaves the digit naming the numeral it replaced.
@date 19-10-2026-21:02 ]]
local function slot_memberships(kids, ast_root, parents)
    local out, last = {}, {}
    for k, slot in ipairs(kids) do
        local ids, found, in_tree = slot_ids(slot, {}), {}, false
        for _, id in ipairs(ids) do
            if parents[id] or id == ast_root.id then
                in_tree = true
                for _, m in ipairs(memberships(id, parents)) do
                    found[#found + 1] = m
                end
            end
        end
        if in_tree then
            last = found
        elseif #ids > 0 then
            found = last
        end
        out[k] = found
    end
    return out
end

--[[ Gathers each sum met in the row, with the run of slots each of its terms was found in:
{add, spans = {[index] = {lo, hi}}, owner = {[slot] = index}}. A slot two terms of one sum claim
marks the sum `mixed` - every term of a sum inside a fraction or an exponent sits in that one slot.
@date 19-10-2026-21:02 ]]
local function sums_of(slots)
    local by_add, list = {}, {}
    for k, found in ipairs(slots) do
        for _, m in ipairs(found) do
            local s = by_add[m.add]
            if not s then
                s = {add = m.add, spans = {}, owner = {}}
                by_add[m.add] = s
                list[#list + 1] = s
            end
            local span = s.spans[m.index]
            if span then
                span.lo, span.hi = math.min(span.lo, k), math.max(span.hi, k)
            else
                s.spans[m.index] = {lo = k, hi = k}
            end
            if s.owner[k] and s.owner[k] ~= m.index then
                s.mixed = true
            end
            s.owner[k] = m.index
        end
    end
    return list
end

--[[ Lists every closed bracket pair of the row, as the slots of its two halves: {o, c}. An
integral's sign and its d are a pair too. @date 19-10-2026-21:02 ]]
local function bracket_pairs(kids)
    local out = {}
    for k, slot in ipairs(kids) do
        local atom = mexpru.slot_atom(slot)
        local br = mexpru.u(atom).bracket
        local c = br and br.is_open and mexpru.peer_slot(kids, atom)
        if c then
            out[#out + 1] = {o = k, c = c}
        end
    end
    return out
end

local function claimed_by_sibling(owner, index, lo, hi)
    for k = lo, hi do
        if owner[k] and owner[k] ~= index then
            return true
        end
    end
    return false
end

--[[ Widens a term's run over the bracket pairs that belong to it: a pair meeting the run that
holds no slot of a sibling term. That takes in both brackets around `(a+b)` in `(a+b)+c`, the `(`
of `(abc+ab^2)d` and an integral's sign. A pair holding a sibling's slots encloses the whole sum
and belongs to the term around it. @date 19-10-2026-20:44 ]]
local function close_brackets(span, pairs_, owner, index)
    local grew = true
    while grew do
        grew = false
        for _, p in ipairs(pairs_) do
            local inside = p.o >= span.lo and p.c <= span.hi
            local meets = p.o <= span.hi and p.c >= span.lo
            if meets and not inside and not claimed_by_sibling(owner, index, p.o, p.c) then
                span.lo, span.hi = math.min(span.lo, p.o), math.max(span.hi, p.c)
                grew = true
            end
        end
    end
end

--[[ COMMA holds the comma glyph's code. The parse reads a comma between a call's arguments as
punctuation, the way it reads a bracket, and tags neither. @date 19-10-2026-22:23 ]]
local COMMA = char.find_by_desc(",").ncod

--[[ Answers whether slot k holds a glyph the parse read into a term without tagging it, which is a
slot with no tag at all that is neither a bracket, a sign nor a comma. A sign is left out although
the parse may leave it untagged: in `a--b` only the second minus carries a tag, and the first
opens the term after it. A k outside the row answers false. @date 19-10-2026-22:23 ]]
local function untagged_part(kids, k)
    local slot = kids[k]
    if not slot or #slot_ids(slot, {}) > 0 then
        return false
    end
    local atom = mexpru.slot_atom(slot)
    local comma = atom.type == vc.MEXPR_TYPE_SYMBOL and atom.symb.code == COMMA
    return not comma and not mexpru.u(atom).bracket and not mexpr_ast.is_sign_atom(atom)
end

--[[ Steps from slot k by `step` over the untagged parts of a term and gives the last slot it
reaches, k itself when the next slot is not one. @date 19-10-2026-22:23 ]]
local function over_untagged(kids, k, step)
    while untagged_part(kids, k + step) do
        k = k + step
    end
    return k
end

--[[ Finds the stretch of untagged parts that a term with no tagged slot of its own stands on: the
one right after the run before it, or, for a first term, the one right before the run after it.
Gives {lo, hi}, or nil when that gap holds none. @date 19-10-2026-22:23 ]]
local function own_gap(kids, prev, nxt)
    if prev then
        local hi = over_untagged(kids, prev.hi, 1)
        return hi > prev.hi and {lo = prev.hi + 1, hi = hi} or nil
    elseif nxt then
        local lo = over_untagged(kids, nxt.lo, -1)
        return lo < nxt.lo and {lo = lo, hi = nxt.lo - 1} or nil
    end
    return nil
end

--[[ Widens a sum's runs over the untagged parts of its terms. What follows a term up to the next
sign is still that term, so such a stretch joins the run on its left, and the first run also
reaches back over the stretch before it. A term with no tagged slot at all - the \infty of
`\infty+1` - takes the stretch in its own gap, and the run on its left stops short of it.
@date 19-10-2026-22:23 ]]
local function take_untagged(s, kids)
    local n = #s.add
    for index = 1, n do
        local span, prev, nxt = s.spans[index], s.spans[index - 1], s.spans[index + 1]
        if not span then
            s.spans[index] = own_gap(kids, prev, nxt)
        else
            if index == 1 then
                span.lo = over_untagged(kids, span.lo, -1)
            end
            if nxt or index == n then
                span.hi = over_untagged(kids, span.hi, 1)
            end
        end
    end
end

--[[ Widens every run of a sum to its whole term: over the brackets that belong to the term first,
then over its untagged parts. @date 19-10-2026-22:23 ]]
local function widen_runs(s, kids, pairs_)
    for index = 1, #s.add do
        local span = s.spans[index]
        if span then
            close_brackets(span, pairs_, s.owner, index)
        end
    end
    take_untagged(s, kids)
end

--[[ Answers whether every term of a sum has a run of its own in this row, the runs in the sum's
order. A sum failing it gets no selectors rather than wrong ones. @date 19-10-2026-22:23 ]]
local function in_row(s)
    if s.mixed then
        return false
    end
    local prev_hi = 0
    for index = 1, #s.add do
        local span = s.spans[index]
        if not span or span.lo <= prev_hi then
            return false
        end
        prev_hi = span.hi
    end
    return true
end

--[[ Answers whether a slot has no height of ink, as a space has none. @date 19-10-2026-21:02 ]]
local function inkless(slot)
    local bb = vc.mexpr_get_bb(slot)
    return bb.br.y - bb.tl.y <= 0
end

--[[ Steps from slot k by `step` past the slots with no ink, and stops at slot `stop` whatever it
holds; `stop` may lie just outside the row. @date 19-10-2026-22:23 ]]
local function past_inkless(kids, k, step, stop)
    while k ~= stop and inkless(kids[k]) do
        k = k + step
    end
    return k
end

--[[ Gives a term's body: its run without the leading sign glyph and without spaces at either end.
@date 19-10-2026-22:23 ]]
local function body_of(kids, span)
    local lo = past_inkless(kids, span.lo, 1, span.hi)
    if lo < span.hi and mexpr_ast.is_sign_atom(mexpru.slot_atom(kids[lo])) then
        lo = past_inkless(kids, lo + 1, 1, span.hi)
    end
    return lo, past_inkless(kids, span.hi, -1, lo)
end

--[[ Describes term `index` of a sum by its run: {id, lo, hi, body_lo, body_hi, pairs}, `pairs`
holding the bracket pairs that lie inside the run. @date 19-10-2026-22:23 ]]
local function term_of(kids, s, index, pairs_)
    local span = s.spans[index]
    local body_lo, body_hi = body_of(kids, span)
    local inside = {}
    for _, p in ipairs(pairs_) do
        if p.o >= span.lo and p.c <= span.hi then
            inside[#inside + 1] = p
        end
    end
    return {id = s.add[index].id, lo = span.lo, hi = span.hi, body_lo = body_lo,
            body_hi = body_hi, pairs = inside}
end

--[[ Lists the sums whose terms lie in the formula's own row: {add = id, depth, terms}, `depth`
counting the sums it sits in and `terms` holding term_of's records, in slot indices into the root
row. @date 19-10-2026-22:23 ]]
local function row_sums(container, ast_root)
    local kids = mexpru.u(container.root).children
    local parents = ast.parent_map(ast_root)
    local pairs_ = bracket_pairs(kids)
    local out = {}
    for _, s in ipairs(sums_of(slot_memberships(kids, ast_root, parents))) do
        widen_runs(s, kids, pairs_)
        if in_row(s) then
            local terms = {}
            for index = 1, #s.add do
                terms[index] = term_of(kids, s, index, pairs_)
            end
            out[#out + 1] = {add = s.add.id, depth = #memberships(s.add.id, parents),
                    terms = terms}
        end
    end
    return out
end

-- #################################################################################################
-- Where the selectors sit
-- #################################################################################################

--[[ Groups the leaves of slots lo..hi into one segment per row, in row order: {row, x0, x1}, x in
the drawn frame. @date 19-10-2026-21:02 ]]
local function row_segments(kids, lo, hi, wrap_width, root)
    local by_row, rows = {}, {}
    for k = lo, hi do
        for _, leaf in ipairs(mformula.wrapped_leaves(kids[k], wrap_width, root)) do
            local seg = by_row[leaf.row]
            if seg then
                seg.x0, seg.x1 = math.min(seg.x0, leaf.x0), math.max(seg.x1, leaf.x1)
            else
                seg = {row = leaf.row, x0 = leaf.x0, x1 = leaf.x1}
                by_row[leaf.row] = seg
                rows[#rows + 1] = seg
            end
        end
    end
    table.sort(rows, function(a, b) return a.row < b.row end)
    return rows
end

--[[ Gives the unwrapped x extent of slots lo..hi, in the frame node_bbox and tree_point share.
@date 19-10-2026-21:02 ]]
local function unwrapped_span(fontset, kids, lo, hi)
    local left, right = math.huge, -math.huge
    for k = lo, hi do
        local bb = mformula.node_bbox(fontset, kids[k])
        left, right = math.min(left, bb.left), math.max(right, bb.right)
    end
    return left, right
end

--[[ Gives the unwrapped middle of slot k. @date 19-10-2026-22:23 ]]
local function slot_mid(ctx, k)
    local left, right = unwrapped_span(ctx.fontset, ctx.kids, k, k)
    return (left + right) / 2
end

--[[ Lists the inside of each bracket pair in a term's run as an unwrapped x range {lo, hi}, from
the middle of its opening half to the middle of its closing one. @date 19-10-2026-22:23 ]]
local function bracket_holes(ctx, term)
    local holes = {}
    for _, p in ipairs(term.pairs) do
        holes[#holes + 1] = {lo = slot_mid(ctx, p.o), hi = slot_mid(ctx, p.c)}
    end
    return holes
end

--[[ Places one term's selector: a segment per row, each at its level's line, and the ring at the
start of the first. `head` is where the term's ink begins, sign included, and `tail` where its body
ends - the two ends a gap mark sits between - `mid` is the body's unwrapped middle, which a drop
is measured against, and `holes` are the insides of its brackets, where a sibling's drop is
refused. @date 19-10-2026-22:23 ]]
local function place_term(ctx, term, level)
    local segs = row_segments(ctx.kids, term.body_lo, term.body_hi, ctx.wrap_width, ctx.root)
    for _, seg in ipairs(segs) do
        seg.y = ctx.line_y(seg.row, level)
    end
    local ink_lo = past_inkless(ctx.kids, term.lo, 1, term.hi)
    local head = row_segments(ctx.kids, ink_lo, ink_lo, ctx.wrap_width, ctx.root)[1]
    local first, last = segs[1], segs[#segs]
    local left, right = unwrapped_span(ctx.fontset, ctx.kids, term.body_lo, term.body_hi)
    return {term = term.id, segments = segs, ring = {x = first.x0 + RING_R, y = first.y},
            head = {row = head.row, x = head.x0}, tail = {row = last.row, x = last.x1},
            mid = (left + right) / 2, body = {lo = term.body_lo, hi = term.body_hi},
            holes = bracket_holes(ctx, term)}
end

--[[ Gives the segment slot k draws on `row`, {row, x0, x1}, or nil when the row holds no slot k
or slot k draws nothing on that row. @date 19-10-2026-22:23 ]]
local function beside(ctx, k, row)
    if k < 1 or k > #ctx.kids then
        return nil
    end
    for _, seg in ipairs(row_segments(ctx.kids, k, k, ctx.wrap_width, ctx.root)) do
        if seg.row == row then
            return seg
        end
    end
    return nil
end

--[[ Places the marker of each gap of a sum, {row, x} for gaps 0 .. #terms: midway between two
terms sharing a row, and at the sum's ends midway to what is drawn beside it on that row, slot
`before` or slot `after` - a bracket's stroke or a relation, which a fixed offset landed on (seen
live 19-10-2026). With nothing beside it, an end marker stands just outside the sum, and across a
row break just before the term. Every distance runs from the terms' ink, never from a space.
@date 19-10-2026-22:23 ]]
local function gap_marks(ctx, terms, before, after)
    local marks = {}
    for g = 0, #terms do
        local prev, nxt = terms[g], terms[g + 1]
        if prev and nxt and prev.tail.row == nxt.head.row then
            marks[g + 1] = {row = prev.tail.row, x = (prev.tail.x + nxt.head.x) / 2}
        elseif nxt then
            local b = g == 0 and beside(ctx, before, nxt.head.row)
            marks[g + 1] = {row = nxt.head.row,
                    x = b and (b.x1 + nxt.head.x) / 2 or nxt.head.x - MARKER_PAD}
        else
            local b = beside(ctx, after, prev.tail.row)
            marks[g + 1] = {row = prev.tail.row,
                    x = b and (prev.tail.x + b.x0) / 2 or prev.tail.x + MARKER_PAD}
        end
    end
    return marks
end

--[[ Gives the unwrapped middle of slot k, which is an edge of a sum's drop zone, or `outside` when
the row holds no slot k because the sum reaches the row's end there. @date 19-10-2026-22:23 ]]
local function bound_at(ctx, k, outside)
    if k < 1 or k > #ctx.kids then
        return outside
    end
    return slot_mid(ctx, k)
end

--[[ Places one sum's selectors, its gap marks and its drop zone; the zone runs from the middle of
the inked slot before the sum to the middle of the inked slot after it, since a space beside a sum
is part of the gap a drop aims at. @date 19-10-2026-22:23 ]]
local function place_sum(ctx, s, level)
    local sum = {add = s.add, terms = {}}
    for index, term in ipairs(s.terms) do
        local sel = place_term(ctx, term, level)
        sel.sum, sel.add, sel.index = sum, s.add, index
        sum.terms[index] = sel
    end
    local before = past_inkless(ctx.kids, s.terms[1].lo - 1, -1, 0)
    local after = past_inkless(ctx.kids, s.terms[#s.terms].hi + 1, 1, #ctx.kids + 1)
    sum.marks = gap_marks(ctx, sum.terms, before, after)
    sum.lo_bound = bound_at(ctx, before, -math.huge)
    sum.hi_bound = bound_at(ctx, after, math.huge)
    return sum
end

--[[ Records the formula's own drawn extent, which a drop has to land in: its leftmost and
rightmost ink, its last row and that row's bottom. @date 19-10-2026-21:22 ]]
local function formula_extent(geom, root, wrap_width)
    local left, right, last_row = math.huge, -math.huge, 0
    for _, leaf in ipairs(mformula.wrapped_leaves(root, wrap_width, root)) do
        left, right = math.min(left, leaf.x0), math.max(right, leaf.x1)
        last_row = math.max(last_row, leaf.row)
    end
    geom.left, geom.right, geom.last_row = left, right, last_row
    geom.rows_bottom = geom.top + (last_row + 1) * geom.row_h
end

--[[ Records a placed sum in the geometry: its selectors, the lowest point they reach and the
deepest line under each row. @date 19-10-2026-22:23 ]]
local function add_sum(geom, sum)
    geom.sums[#geom.sums + 1] = sum
    for _, sel in ipairs(sum.terms) do
        geom.selectors[#geom.selectors + 1] = sel
        for _, seg in ipairs(sel.segments) do
            geom.bottom = math.max(geom.bottom, seg.y + RING_R + 1)
            geom.row_lines[seg.row] = math.max(geom.row_lines[seg.row] or seg.y, seg.y)
        end
    end
end

--[[ Builds the geometry of every selector, relative to the formula's draw origin with y from its
baseline, or nil when there is none: {sums, selectors, row_lines, top, row_h, bottom, rows_bottom,
last_row, left, right}. `bottom` is the lowest point the selectors reach, which the box grows to,
and `row_lines` holds the y of the deepest line under each row that has one.
@date 19-10-2026-22:23 ]]
local function build(fontset, container, sz, wrap_width, decls_of)
    local ast_root = ast_gestures.ast_for(fontset, container, decls_of())
    local sums = ast_root and row_sums(container, ast_root) or {}
    if #sums == 0 then
        return nil
    end
    local root = container.root
    local rbb = vc.mexpr_get_bb(root)
    local bc = mformula.baseline_correction(fontset, sz)
    local row_h = rbb.br.y - rbb.tl.y
    local geom = {sums = {}, selectors = {}, row_lines = {}, top = bc + rbb.tl.y, row_h = row_h,
            bottom = -math.huge}
    formula_extent(geom, root, wrap_width)
    --[[ The last row's lines start from measure's bottom, which never comes out shallower than an
    empty slot, because editor_formula draws the field's contour from it: measured from the ink
    alone, the line of a shallow formula like a+b=c+d sat on that contour (seen live 19-10-2026).
    A row another row follows has no contour under it, and its lines keep close to its ink.
    @date 19-10-2026-21:22 ]]
    local ink, base = bc + rbb.br.y, mformula.measure(container, fontset, sz, nil).bottom
    local deepest = 0
    for _, s in ipairs(sums) do
        deepest = math.max(deepest, s.depth)
    end
    local ctx = {fontset = fontset, kids = mexpru.u(root).children, root = root,
            wrap_width = wrap_width,
            line_y = function(row, level)
                local first = (row == geom.last_row) and base + LINE_GAP or ink + ROW_GAP
                return first + row * row_h + level * LINE_PITCH
            end}
    for _, s in ipairs(sums) do
        add_sum(geom, place_sum(ctx, s, deepest - s.depth))
    end
    return geom
end

--[[ Gives the container's cached geometry entry, rebuilt when the tree, the size or the wrap width
moved. The root is part of the key because a zoom replaces the tree without bumping the version;
it is held weakly, so the cache keeps no zoomed-away tree alive. @date 19-10-2026-21:02 ]]
local function cached(fontset, container, sz, wrap_width, decls_of)
    local c = container._selector_cache
    local version = container.version or 0
    if c and c.version == version and mexpru.same(c.root:get_obj(), container.root)
            and c.sz == sz and c.wrap_width == wrap_width then
        return c
    end
    c = {version = version, root = vc.wref_mexpr(container.root), sz = sz,
            wrap_width = wrap_width, geom = build(fontset, container, sz, wrap_width, decls_of)}
    container._selector_cache = c
    return c
end

--[[ @brief Lays out the term selectors of a formula drawn at (draw_x, draw_y) this frame.
-- |
-- | THE DRAW AND THE NEXT FRAME'S INPUT SHARE ONE RECORD: it places the cached geometry at this
-- | frame's origin, so a press tested against it lands where the selectors were drawn. A sum gets
-- | selectors when its terms lie in the formula's own row; each term's selector covers its body,
-- | every glyph of the term but its leading sign, its own brackets included.
-- |
-- | @details The geometry is cached on the container, keyed on its version, its root, `sz` and
-- |          `wrap_width`. Only a rebuild calls `decls_of`, and the parse it feeds runs only when
-- |          ast_gestures.ast_for has none cached, so a steady frame works out no declarations.
-- |
-- | @param fontset     fontset
-- | @param container   mexpru.container - checked; a laid-out formula
-- | @param sz          size - as drawn
-- | @param wrap_width  number | nil - the wrap column as a width from draw_x; nil never wraps
-- | @param decls_of    function() -> {decl} - gives the declarations in scope, in
-- |                    content.declarations_before's order
-- | @param draw_x      number - the screen x the formula is drawn at
-- | @param draw_y      number - the screen y of its baseline
-- | @return record | nil - nil when the formula does not parse or no sum of it lies in its own
-- |         row
-- |
-- | @date 19-10-2026-22:23
--]]
function term_selectors.layout(fontset, container, sz, wrap_width, decls_of, draw_x, draw_y)
    mexpru.check_container(container)
    local c = cached(fontset, container, sz, wrap_width, decls_of)
    if not c.geom then
        return nil
    end
    return {geom = c.geom, version = c.version, root = c.root, container = container, sz = sz,
            wrap_width = wrap_width, x = draw_x, y = draw_y}
end

--[[ @brief Answers whether a record still describes the tree `container` holds.
-- |
-- | A RECORD NAMES TERMS BY AST ID, and those ids mean something only for the parse of the tree
-- | the record was laid out from. An edit or a zoom replaces that tree.
-- |
-- | @param record     record | nil - as layout returned it; nil or false answers false
-- | @param container  mexpru.container | nil
-- | @return boolean
-- |
-- | @date 19-10-2026-20:44
--]]
function term_selectors.current(record, container)
    if not record or not container then
        return false
    end
    return rawequal(record.container, container) and record.version == (container.version or 0)
            and mexpru.same(record.root:get_obj(), container.root)
end

-- #################################################################################################
-- Drawing
-- #################################################################################################

--[[ Draws a ring at `center`, filled or hollow, and the line that leaves it rightwards as far as
x1. The ImGui calls copy content.lua's chrome-row calls, which run live: AddCircle and AddLine with
a thickness, AddCircleFilled without. @date 19-10-2026-22:23 ]]
local function draw_handle(center, x1, filled, color, thickness)
    if filled then
        vc.ImGui_AddCircleFilled(center, RING_R, color)
    else
        vc.ImGui_AddCircle(center, RING_R, color, 1)
    end
    local x0 = center.x + RING_R + RING_GAP
    if x1 > x0 then
        vc.ImGui_AddLine({x = x0, y = center.y}, {x = x1, y = center.y}, color, thickness)
    end
end

--[[ Draws one selector at the origin (ox, oy): a hollow gray ring and line, or a filled white ring
and a heavier white line when lit. The first row's line leaves the ring; a wrapped term's later
rows get a line each. @date 19-10-2026-22:23 ]]
local function draw_selector(ox, oy, sel, lit)
    local color, thickness = lit and LIT_COLOR or IDLE_COLOR, lit and 2 or 1
    draw_handle({x = ox + sel.ring.x, y = oy + sel.ring.y}, ox + sel.segments[1].x1, lit, color,
            thickness)
    for k = 2, #sel.segments do
        local seg = sel.segments[k]
        if seg.x1 > seg.x0 then
            vc.ImGui_AddLine({x = ox + seg.x0, y = oy + seg.y}, {x = ox + seg.x1, y = oy + seg.y},
                    color, thickness)
        end
    end
end

--[[ @brief Draws the selectors of a record, under the formula's glyphs.
-- |
-- | ONE SELECTOR AT MOST IS LIT, and only the selector: the term's glyphs are never touched, since
-- | their colour belongs to the parse.
-- |
-- | @param record  record - as layout returned it this frame
-- | @param held    id | false | nil - the term whose selector a drag holds, lit whatever the
-- |                pointer does; false lights none, while a drag runs on another box; nil
-- |                lights the selector under the pointer
-- |
-- | @date 19-10-2026-20:44
--]]
function term_selectors.draw(record, held)
    local lit = held
    if lit == nil then
        local sel = term_selectors.selector_at(record, vc.ImGui_GetMousePos())
        lit = sel and sel.term
    end
    for _, sel in ipairs(record.geom.selectors) do
        draw_selector(record.x, record.y, sel, sel.term == lit)
    end
end

--[[ @brief Draws the toggle button's picture: a selector, lit when the box shows them.
-- |
-- | IT FOLLOWS THE ROW'S CONVENTION, lit when on and outlined gray when off: a filled white ring
-- | and a white line, or a hollow gray ring and a gray line.
-- |
-- | @param rect  {x, y, w, h} - the button, screen space
-- | @param on    boolean - the box shows its selectors
-- |
-- | @date 19-10-2026-21:02
--]]
function term_selectors.draw_icon(rect, on)
    local ring = {x = rect.x + 3 + RING_R, y = rect.y + rect.h / 2 + 2}
    draw_handle(ring, rect.x + rect.w - 3, on, on and LIT_COLOR or IDLE_COLOR, 1)
end

-- #################################################################################################
-- Pointing and dropping
-- #################################################################################################

--[[ Measures how near the point (px, py) is to the selector's ring or to one of its lines, and
answers nil when it is on neither. @date 19-10-2026-21:02 ]]
local function nearness(sel, px, py)
    local best
    local dx, dy = px - sel.ring.x, py - sel.ring.y
    local d = math.sqrt(dx * dx + dy * dy)
    if d <= RING_R + HIT_SLOP then
        best = d
    end
    for _, seg in ipairs(sel.segments) do
        local off = math.abs(py - seg.y)
        if off <= HIT_SLOP and px >= seg.x0 - HIT_SLOP and px <= seg.x1 + HIT_SLOP
                and (not best or off < best) then
            best = off
        end
    end
    return best
end

--[[ @brief Finds the selector a screen point is on.
-- |
-- | THE NEAREST WINS where two are within reach of the point, so the lines of two levels never
-- | both answer.
-- |
-- | @param record  record | nil - nil answers nil
-- | @param point   {x, y} | nil - screen space; nil answers nil
-- | @return selector | nil - carries `term` and `add`, the ast ids of the term and its sum,
-- |         `index`, the term's place among the sum's terms, and `body`, {lo, hi}, the slots of
-- |         the root row its underline covers
-- |
-- | @date 19-10-2026-20:44
--]]
function term_selectors.selector_at(record, point)
    if not record or not point then
        return nil
    end
    local px, py = point.x - record.x, point.y - record.y
    local best, best_d
    for _, sel in ipairs(record.geom.selectors) do
        local d = nearness(sel, px, py)
        if d and (not best_d or d < best_d) then
            best, best_d = sel, d
        end
    end
    return best
end

local function find_selector(geom, add, term)
    for _, sel in ipairs(geom.selectors) do
        if sel.add == add and sel.term == term then
            return sel
        end
    end
    return nil
end

--[[ Builds the reorder option that lands `sel` in gap `gap` of its sum, or answers nil when the
term already stands there - its own two gaps change nothing. `before` is the term it lands in front
of, or the sum itself to land last, as the reorder plugin's contract has it.
@date 19-10-2026-21:02 ]]
local function reorder_option(sum, sel, gap)
    if gap == sel.index - 1 or gap == sel.index then
        return nil
    end
    local before = sum.terms[gap + 1]
    return transforms.option("reorder", "Reorder terms",
            {term = sel.term, before = before and before.term or sum.add})
end

--[[ Gives the y a release at `y` is read on, so that a release on a row's selectors lands on that
row: the lines of a row that another row follows sit inside the next row's band, and a point
from that row's ink down to its deepest line, within reach, moves up into it; a point below the
last row reads as on the last row. @date 19-10-2026-22:23 ]]
local function drop_row_y(g, y)
    for r = 0, g.last_row - 1 do
        local ink_bottom = g.top + (r + 1) * g.row_h
        local deepest = g.row_lines[r]
        if deepest and y >= ink_bottom and y <= deepest + HIT_SLOP then
            return ink_bottom - 1e-3
        end
    end
    return math.max(g.top, math.min(y, g.rows_bottom - 1e-3))
end

--[[ Answers whether the unwrapped x lies inside the brackets of a term of the sum other than
`sel`. @date 19-10-2026-22:23 ]]
local function in_sibling_bracket(sum, sel, x)
    for _, t in ipairs(sum.terms) do
        if t ~= sel then
            for _, hole in ipairs(t.holes) do
                if x > hole.lo and x < hole.hi then
                    return true
                end
            end
        end
    end
    return false
end

--[[ @brief Finds the gap among a term's own siblings that a release at `point` lands in.
-- |
-- | GAPS ARE IN READING ORDER, rows included, so a wrapped sum works: the point is carried back
-- | to the unwrapped row through mformula_new.tree_point, the click's own conversion, and lands
-- | after every sibling whose body's middle it has passed. A point on the selectors' own lines
-- | reads as on the row they underline, the last row's or a wrapped row's, so a release along
-- | them still finds its gap.
-- |
-- | IT ANSWERS ONLY AMONG THE SIBLINGS: a release outside the formula, outside the term's own
-- | sum - past the middle of the bracket or the relation bounding it - or between a sibling's
-- | brackets, which would move the term into that sibling, finds no gap, and the reason says
-- | which.
-- |
-- | @param record   record | nil - the box's record from the last frame; nil finds nothing
-- | @param fontset  fontset
-- | @param add      id - the dragged term's sum
-- | @param term     id - the dragged term
-- | @param point    {x, y} | nil - screen space
-- | @return {sum, gap, option} | nil, string - `gap` counts from 0, before the first term;
-- |         `option` is the transforms.option that puts the term there, nil when that is where
-- |         it already stands
-- |
-- | @date 19-10-2026-22:23
--]]
function term_selectors.drop_at(record, fontset, add, term, point)
    local sel = record and find_selector(record.geom, add, term)
    if not sel or not point then
        return nil, "the term is not drawn"
    end
    local g = record.geom
    local x, y = point.x - record.x, point.y - record.y
    if x < g.left - DROP_SLOP or x > g.right + DROP_SLOP or y < g.top - DROP_SLOP
            or y > math.max(g.bottom, g.rows_bottom) + DROP_SLOP then
        return nil, "the drop is outside the formula"
    end
    local p = mformula.tree_point(record.container, fontset, record.sz,
            {x = x, y = drop_row_y(g, y)}, record.wrap_width)
    local sum = sel.sum
    if p.x < sum.lo_bound or p.x > sum.hi_bound then
        return nil, "the drop is outside the term's own sum"
    end
    if in_sibling_bracket(sum, sel, p.x) then
        return nil, "the drop is inside a bracket"
    end
    local gap = 0
    for _, t in ipairs(sum.terms) do
        if t.mid < p.x then
            gap = gap + 1
        end
    end
    return {sum = sum, gap = gap, option = reorder_option(sum, sel, gap)}
end

--[[ Draws the vertical marker on a drop's gap, the height of its row: white where the drop changes
the order, gray where it would leave the order as it is. @date 19-10-2026-21:02 ]]
local function draw_marker(record, drop)
    local g = record.geom
    local mark = drop.sum.marks[drop.gap + 1]
    local top = record.y + g.top + mark.row * g.row_h
    local x = record.x + mark.x
    vc.ImGui_AddLine({x = x, y = top}, {x = x, y = top + g.row_h},
            drop.option and LIT_COLOR or IDLE_COLOR, 2)
end

--[[ Draws the dragged selector as a translucent ghost, moved from where it stands by the pointer's
travel since the press. @date 19-10-2026-21:02 ]]
local function draw_ghost(record, sel, press, point)
    local ring = {x = record.x + sel.ring.x + point.x - press.x,
            y = record.y + sel.ring.y + point.y - press.y}
    draw_handle(ring, ring.x + sel.segments[1].x1 - sel.ring.x, true, GHOST_COLOR, 2)
end

--[[ @brief Draws a drag in progress: the dragged selector's ghost and the marker of its drop.
-- |
-- | IT DRAWS ON TOP, after the page, so the ghost is never under a box. The marker shows only
-- | while the point is on a gap among the term's siblings.
-- |
-- | @param record  record - the dragged term's box, as layout returned it this frame
-- | @param drag    table - {add, term, press, drop}: the dragged term's ids, the press point,
-- |                and drop_at's answer for the pointer, nil when it found no gap
-- | @param point   {x, y} | nil - the pointer, screen space; nil draws nothing
-- |
-- | @date 19-10-2026-21:02
--]]
function term_selectors.draw_drag(record, drag, point)
    local sel = find_selector(record.geom, drag.add, drag.term)
    if not sel or not point then
        return
    end
    if drag.drop then
        draw_marker(record, drag.drop)
    end
    draw_ghost(record, sel, drag.press, point)
end

return term_selectors

--[[
mformula.lua - a mini structured expression editor, rendered through math_expr_composer.h's
mexpr_* functions (not the flat char-stream approach editor.lua uses for plain text).

Model: a "row" is {items={...}, parent_row=, parent_index=, parent_slot=}. Each item is either a
plain glyph {code=<ncod>}, a superscript/subscript node:
  {supsub=true, base=<row>, sup=<row or nil>, sub=<row or nil>}
or a fraction node:
  {frac=true, num=<row>, den=<row>}
`base` is itself a row (an empty one renders as a placeholder box) - matching how the feature is
triggered: Ctrl+Shift+'_' wraps the ONE character just before the cursor into a new subscript
node's base (and jumps the cursor into the subscript itself); Ctrl+Shift+'+' does the same for a
superscript. Being a row rather than a fixed glyph is what lets the base be extended afterward:
navigating left out of a sup/sub lands at the END of the base row (not past the whole node) - so
for "A_N", left-arrowing out of the subscript puts you right after "A", and typing "B" there reads
"AB_N", the base having grown to "AB" - not a stray "B" stuck in front of the whole node. From a
node's position, Up/Down jump into its sup/sub (creating an empty one if it doesn't exist yet - so
they always work once a node exists, from anywhere in the base including). Left/Right both walk
THROUGH a node's base like normal row content (not as one atomic hop over the whole node) - see
move_left()/move_right()'s comments for why that needs care: "before a node" and "start of its
base" are the same on-screen spot, so naively stopping at both wastes a keypress on nothing.

A fraction (Ctrl+/) has no base - num/den are stacked, not in reading-order sequence with each
other or with anything before/after the node, so unlike sup/sub there's no natural "primary" child
for Left/Right to walk through. Left/Right therefore treat a whole frac node as ONE opaque stop
(needs no special-casing in move_left()/move_right() at all - it just falls through their existing
"not a supsub" branch); Up/Down are the only way in, jumping into num/den exactly the way they
already jump into sup/sub (move_vertical() handles both node kinds together - see its own comment).
Both num and den always exist together from the moment the node is created (make_frac()) - never
optional the way an unvisited sup/sub can be - since mexpr_frac (math_expr_composer.h) requires
both to render at all.

cursor = {row=<row ref>, pos=0..#row.items}, same convention as editor.lua.
]]

local vc = require("virt_composer")
local char = require("char")

local mformula = {}

-- A typed space is otherwise entirely invisible ink in a formula - no glyph, no marker, nothing
-- to show it's even there (unlike plain text, where surrounding words make a gap read as
-- intentional). slot_markers() below draws a small box at every one so it doesn't look identical
-- to just not having typed anything.
local SPACE_NCOD = char.find_by_ascii(" ").ncod

-- How much smaller (in font-size-table steps) a sup/sub row's glyphs render at. The table in
-- char.lua's load_font_set is sorted BIGGEST to smallest, so a larger index = a smaller glyph -
-- this must ADD to sz, not scale it (sz is a discrete 1..16 index, not a pixel size). +1 is the
-- very next size down in that table (e.g. 36pt -> 24pt, a ~67% typographic ratio); +2 skips a
-- whole step (36pt -> 18pt, 50%) and reads as too small.
local SUB_SIZE_DELTA = 1
local MAX_SIZE_INDEX = 16

local CURSOR_COLOR = 0xff00ffff

-- #################################################################################################
-- Metrics
-- #################################################################################################

--[[ mexpr_symbol(is_char=true) (math_expr_composer.h) re-centers every glyph it draws on the
vertical middle of 'a' at its own size - a convention mexpr's own composition relies on (e.g. for
lining up fractions/big-ops), but NOT the same baseline fontset:char_draw uses directly, which is
what editor.lua's plain text already sits on. Left uncorrected, mexpr-drawn content floats above
where plain text of the same size sits (small/rounded glyphs like the 'x' in "x^2" hide this;
flat-topped ones like 'A'/'B' show it clearly). This is the one-time-per-size correction needed to
add to a true baseline y before handing it to mexpr_draw, so formula content lands exactly where
plain text at the same pos would - the exact negation of mexpr_symbol's own symb_off.y formula. ]]
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

--[[ A reasonable pixel size for an empty-slot placeholder box at font size `sz` (mexpr_empty
takes real pixel dimensions, not a size-table index - so `sz` itself can't be passed straight
through). Based on 'a's own advance width/height at that size. ]]
local placeholder_size_cache = {}
local function placeholder_size(fs, sz)
    local s = placeholder_size_cache[sz]
    if s then
        return s
    end
    local a = char.find_by_ascii("a")
    local a_sz = fs:char_get_sz({size = sz, code = a.ncod})
    s = {w = math.max(a_sz.adv, 4), h = math.max(a_sz.bl.y - a_sz.tr.y, 4)}
    placeholder_size_cache[sz] = s
    return s
end

--[[ Line-height/baseline metrics at font size `sz`, same G/g-measuring trick editor.lua's own
get_metrics() uses - needed so the caret is sized from real glyph metrics (matching whatever size
the cursor's own row is actually rendered at) rather than a flat guess. ]]
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
-- Model
-- #################################################################################################

local function new_row(parent_row, parent_index, parent_slot)
    return {items = {}, parent_row = parent_row, parent_index = parent_index, parent_slot = parent_slot}
end

function mformula.new()
    local root = new_row(nil, nil, nil)
    return {
        root = root,
        cursor = {row = root, pos = 0},
        frame = 0,
        version = 0, -- bumped on every tree edit - see reachable_graph()'s cache
    }
end

--[[ Returns item[slot] (a row), creating an empty one (linked back to item's position in `row`)
if it doesn't exist yet - so Up/Down always have somewhere to go once a supsub node exists. This
is itself a tree edit (Up/Down can be the FIRST thing that creates an empty sup/sub, same as
typing into one does), so it bumps `state.version` too - not just insert_glyph()/backspace()/etc. ]]
local function ensure_slot(state, item, slot, row, index)
    if not item[slot] then
        item[slot] = new_row(row, index, slot)
        state.version = (state.version or 0) + 1
    end
    return item[slot]
end

--[[ Like mformula.new(), but the root row starts with a single supsub node whose base already
contains `base_item` (a plain glyph item, or nil for an empty base), with the cursor already
inside its `slot` ("sup"/"sub"). This is the "continuation" entry point: editor.lua uses it so
that Ctrl+Shift+-/+ pressed in plain text can pull the character the cursor's sitting after
straight into a brand new formula, instead of requiring Ctrl+M first. ]]
function mformula.new_from_base(base_item, slot)
    local root = new_row(nil, nil, nil)
    local item = {supsub = true}
    table.insert(root.items, item)
    local base_row = new_row(root, 1, "base")
    if base_item then
        base_row.items[1] = base_item
    end
    item.base = base_row
    local formula = {
        root = root,
        cursor = {row = root, pos = 0},
        frame = 0,
        version = 0,
    }
    formula.cursor = {row = ensure_slot(formula, item, slot, root, 1), pos = 0}
    -- Same reasoning as make_supsub(): the opposite slot gets an empty placeholder too, right
    -- away, so there's somewhere for a click to land on the side nothing was typed into yet.
    ensure_slot(formula, item, slot == "sup" and "sub" or "sup", root, 1)
    return formula
end

--[[ Like mformula.new(), but the root row starts with a single, empty fraction node, cursor
already in its numerator - editor.lua's entry point for Ctrl+/ pressed in plain text (mirrors
Ctrl+M's plain mformula.new(), and Ctrl+Shift+-/+'s new_from_base() above), so a fraction can be
started without Ctrl+M first. Unlike new_from_base(), never pulls in a preceding character - see
this file's own model comment for why a fraction has nothing obvious to wrap. Builds the node
inline rather than calling make_frac() (defined later, in Input handling) - same reason
new_from_base() above doesn't call make_supsub() either. ]]
function mformula.new_with_frac()
    local root = new_row(nil, nil, nil)
    local item = {frac = true}
    table.insert(root.items, item)
    item.num = new_row(root, 1, "num")
    item.den = new_row(root, 1, "den")
    return {
        root = root,
        cursor = {row = item.num, pos = 0},
        frame = 0,
        version = 0,
    }
end

-- #################################################################################################
-- Input handling
-- #################################################################################################

--[[ Wraps the glyph immediately before the cursor into a new supsub node's base (or, if the
cursor is at the start of the row, a node with an empty base), and jumps the cursor into `slot`
("sup"/"sub"). The base is a full row (not just that one glyph) - see move_left()'s comment for
why - so it can be extended later by navigating back into it.

If the cursor is already inside an existing node's base, or its OTHER slot (asking for a
superscript while sitting in that node's subscript, or vice versa), this adds `slot` directly to
THAT node (or just jumps into it, if it already has one - same rule move_vertical()/Up/Down uses)
instead of nesting a new node around whatever's before the cursor: typed straight through, "A",
subscript, "B", superscript, "C" should give one node "A^C_B" (base "A", sup "C", sub "B"), not a
nested "A_(B^C)" - and from the base specifically, either slot redirects this way, since the base
has no "current slot" of its own to be asking for the same one again. Only asking for the SAME
slot you're already in falls through to nesting further (e.g. superscript-of-superscript builds
"A^(N^N)", an exponent tower) - there'd be no other way to reach that otherwise.

Sitting just past an existing node (not inside it - that's the case above) does nothing: for
"A_B", the cursor at the very end (past the whole node) has nothing sensible for +/- to attach
to - there's no glyph there to pull into a fresh base, and gluing on a second, empty node right
after the first would just be visual clutter with no way to tell it's even there. ]]
local function make_supsub(state, slot)
    local row, pos = state.cursor.row, state.cursor.pos

    -- The redirect-into-the-enclosing-node's-other-slot rule only makes sense when that node IS a
    -- supsub (base/sup/sub are its only slots, and ensure_slot()'s "sup"/"sub" only mean anything
    -- there) - a frac's num/den have no "sup"/"sub" field to redirect into at all. Without the
    -- item.supsub check, asking for +/- while inside a fraction's numerator/denominator used to
    -- silently grief ensure_slot() into bolting a dead item.sub/item.sup onto the FRAC item -
    -- reachable by nothing, rendered by nothing, so the keypress looked like it did nothing. Not
    -- a supsub parent falls through to the normal wrap-the-preceding-character path below instead,
    -- same as it would for a top-level row.
    if row.parent_row and row.parent_slot then
        local item = row.parent_row.items[row.parent_index]
        if item.supsub and row.parent_slot ~= slot then
            state.cursor = {row = ensure_slot(state, item, slot, row.parent_row, row.parent_index), pos = 0}
            return
        end
    end

    if pos > 0 and row.items[pos].supsub then
        return
    end

    local base_item = nil
    if pos > 0 then
        base_item = row.items[pos]
        table.remove(row.items, pos)
        pos = pos - 1
    end
    local item = {supsub = true}
    table.insert(row.items, pos + 1, item)
    local base_row = new_row(row, pos + 1, "base")
    if base_item then
        base_row.items[1] = base_item
    end
    item.base = base_row
    state.version = (state.version or 0) + 1
    local target = ensure_slot(state, item, slot, row, pos + 1)
    -- The opposite slot gets an empty placeholder too, right away - not just the one asked for.
    -- Otherwise a node with only a superscript has nowhere for a click to land "below" it (there's
    -- no row there at all yet), and the reverse for a subscript-only node above it. Up/Down already
    -- lazily create the slot they're asked for (ensure_slot(), called from move_vertical()) - this
    -- is the same idea, just eager on BOTH slots at creation instead of lazy on one at a time.
    ensure_slot(state, item, slot == "sup" and "sub" or "sup", row, pos + 1)
    state.cursor = {row = target, pos = 0}
end

--[[ Ctrl+/: inserts a new, empty fraction node at the cursor and jumps into its numerator. Unlike
make_supsub(), never wraps anything already there - see this file's own model comment for why a
fraction has no single preceding glyph that obviously belongs in either half. Both slots are
created together (mformula.new_with_frac() mirrors this inline for the plain-text entry point - see
its own comment for why it doesn't just call this). ]]
local function make_frac(state)
    local row, pos = state.cursor.row, state.cursor.pos
    local item = {frac = true}
    table.insert(row.items, pos + 1, item)
    item.num = new_row(row, pos + 1, "num")
    item.den = new_row(row, pos + 1, "den")
    state.version = (state.version or 0) + 1
    state.cursor = {row = item.num, pos = 0}
end

--[[ Step left one glyph, walking THROUGH a supsub node's base like normal content instead of
hopping over the whole node - so for "AB_{C}D" (base "B" pulled into a subscript node sitting
between "A" and "D"), Left visits |A|B|_{C}|D| as four separate stops, not |A|[B_{C}]|D|.

Two things make this fiddlier than a plain pos-1:
1. Stepping back OVER a node (pos > 0, the item just before the cursor IS one) must land at the
   END of ITS base, not just pos-1 - "after the node" (past its sub/sup extension) and "end of its
   base" (just past the base glyphs) are genuinely different on-screen spots; landing on the wrong
   one is exactly the bug this replaced (skipping the "after B" stop above).
2. Exiting a base row to the left AT ITS OWN START (pos == 0) is different: "before this node" (in
   whatever row contains it) and "the start of its base" are the SAME on-screen spot by
   construction (the base is drawn starting exactly where the node starts) - so that exit can't be
   a resting state, or the very next Left would move nothing. It has to keep resolving further
   left from there until it actually lands somewhere new - hence the loop below instead of a
   single reassignment. ]]
local function move_left(state)
    local row, pos = state.cursor.row, state.cursor.pos
    while true do
        if pos > 0 and row.items[pos].supsub then
            local item = row.items[pos]
            row, pos = item.base, #item.base.items
            break
        elseif pos > 0 then
            pos = pos - 1
            break
        elseif row.parent_row then
            if row.parent_slot == "base" then
                -- Redundant landing spot (see point 2 above) - loop again from here instead of
                -- treating it as done.
                row, pos = row.parent_row, row.parent_index - 1
            elseif row.parent_slot == "num" or row.parent_slot == "den" then
                -- A frac's num/den have no base to dive into (Left/Right treat the whole node as
                -- one opaque stop - see this file's model comment) - and unlike a base, "start of
                -- num/den" is NOT the same on-screen spot as "before the frac" (mexpr_frac centers
                -- them, doesn't left-align them), so this IS a stable landing spot - break, don't
                -- loop again.
                row, pos = row.parent_row, row.parent_index - 1
                break
            else
                local item = row.parent_row.items[row.parent_index]
                row, pos = item.base, #item.base.items
                break
            end
        else
            return -- absolute start of the formula - Ctrl+Left/Right leave it, see editor.lua
        end
    end
    state.cursor = {row = row, pos = pos}
end

--[[ Mirror of move_left(): step right one glyph, walking through a base instead of hopping the
whole node. Moving INTO a node from the left is where the "same on-screen spot" issue (point 2 in
move_left()'s comment) shows up here - stepping onto a node lands at the START of its base (the
same spot as "before the node") rather than past the whole thing, and if that base itself starts
with ANOTHER node (adjacent nodes, nothing between them), the while loop below keeps descending
until it reaches an actual glyph or an empty base - otherwise the cursor would rest on a spot
that's pixel-identical to where a later Right press would try to land anyway, wasting a keypress
the way move_left() avoids on its own side (there, that showed up on EXIT instead of entry, which
is why move_left() needs the loop up front instead of after - the two sides of a node aren't
symmetric: leaving it to the right, "past the node" and "end of its base" are genuinely different
on-screen spots, so no such loop is needed exiting a base at its end). ]]
local function move_right(state)
    local row, pos = state.cursor.row, state.cursor.pos
    if pos < #row.items and row.items[pos + 1].supsub then
        row, pos = row.items[pos + 1].base, 0
    elseif pos < #row.items then
        pos = pos + 1
    elseif row.parent_row then
        row, pos = row.parent_row, row.parent_index
    else
        return
    end
    while row.items[pos + 1] and row.items[pos + 1].supsub do
        row, pos = row.items[pos + 1].base, 0
    end
    state.cursor = {row = row, pos = pos}
end

-- Up/Down field-name lookup, per node kind - "up" is the visually-higher slot (superscript /
-- numerator), "down" the lower one (subscript / denominator). Shared by move_vertical() below and
-- mformula.handle_input()'s own Up/Down calls (and reachable_graph()'s movers table), so a future
-- third node kind only needs an entry here, not a change to any of them. ensure_slot() itself
-- already generalizes across kinds for free - it just returns item[slot] if already there (always
-- true for a frac's num/den - see this file's model comment), only actually CREATING anything for
-- an unvisited sup/sub.
local UP_SLOT = {supsub = "sup", frac = "num"}
local DOWN_SLOT = {supsub = "sub", frac = "den"}
local function node_kind(item)
    if item.supsub then return "supsub" end
    if item.frac then return "frac" end
    return nil
end

--[[ Up (want_up=true) / Down (want_up=false). Already inside a sup/sub or frac row: jump to the
sibling slot of the same node. Otherwise: enter the up/down slot of the supsub/frac node
immediately before the cursor, if there is one. ]]
local function move_vertical(state, want_up)
    local row, pos = state.cursor.row, state.cursor.pos
    if row.parent_row and row.parent_slot then
        local item = row.parent_row.items[row.parent_index]
        local kind = node_kind(item)
        local want_slot = kind and (want_up and UP_SLOT[kind] or DOWN_SLOT[kind])
        if want_slot and row.parent_slot ~= want_slot then
            state.cursor = {row = ensure_slot(state, item, want_slot, row.parent_row, row.parent_index), pos = 0}
            return
        end
    end
    if pos > 0 then
        local kind = node_kind(row.items[pos])
        if kind then
            local item = row.items[pos]
            local want_slot = want_up and UP_SLOT[kind] or DOWN_SLOT[kind]
            state.cursor = {row = ensure_slot(state, item, want_slot, row, pos), pos = 0}
        end
    end
end

--[[ Fixes up parent_row/parent_index on every supsub/frac item's own child row(s), for every item
in `parent_row` from `from_index` onward - needed after a splice that changes how many items sit
before them (the only two places that ever do, both below: collapse_if_both_empty()'s base-splice,
and collapse_frac_if_both_empty()'s plain removal), since each item's own children only know their
position via that parent_index, recorded once at creation time and otherwise never touched. ]]
local function reindex_children(parent_row, from_index)
    for i = from_index, #parent_row.items do
        local it = parent_row.items[i]
        if it.supsub then
            it.base.parent_row, it.base.parent_index = parent_row, i
            if it.sup then it.sup.parent_row, it.sup.parent_index = parent_row, i end
            if it.sub then it.sub.parent_row, it.sub.parent_index = parent_row, i end
        elseif it.frac then
            it.num.parent_row, it.num.parent_index = parent_row, i
            it.den.parent_row, it.den.parent_index = parent_row, i
        end
    end
end

--[[ Called after removing an item leaves `row` empty: if `row` is a sup or sub whose SIBLING
slot is also empty (e.g. backspacing the "B" out of "A^B" - the sub that make_supsub()/
new_from_base() eagerly created alongside it never had anything typed into it either), the whole
node is now two empty boxes hanging off "A" for no reason - collapse it back into just its base's
own content, spliced into `row`'s grandparent at the node's old position, exactly undoing what
make_supsub() built. Moves the cursor to right after the spliced-in content. No-op (returns false)
unless both slots are actually empty. ]]
local function collapse_if_both_empty(state, row)
    if row.parent_slot ~= "sup" and row.parent_slot ~= "sub" then
        return false
    end
    if #row.items > 0 then
        return false
    end
    local item = row.parent_row.items[row.parent_index]
    if not item or not item.supsub then
        return false
    end
    local other = item[row.parent_slot == "sup" and "sub" or "sup"]
    if not other or #other.items > 0 then
        return false
    end

    local parent_row = row.parent_row
    local index = row.parent_index
    local base_items = item.base.items
    table.remove(parent_row.items, index)
    for i, base_item in ipairs(base_items) do
        table.insert(parent_row.items, index - 1 + i, base_item)
    end
    reindex_children(parent_row, index)
    state.version = (state.version or 0) + 1
    state.cursor = {row = parent_row, pos = index - 1 + #base_items}
    return true
end

--[[ Frac counterpart to collapse_if_both_empty(): a fraction has no base to splice in (Ctrl+/
never wraps anything - see this file's model comment), so undoing an empty num/den pair is just
deleting the whole frac item outright, same trigger condition as collapse_if_both_empty() (only
when BOTH slots are empty, so backspacing into content actually typed on the other side never
loses it) and the same "land right before where the node was" landing spot as backspace()'s own
non-collapsing num/den exit below. ]]
local function collapse_frac_if_both_empty(state, row)
    if row.parent_slot ~= "num" and row.parent_slot ~= "den" then
        return false
    end
    if #row.items > 0 then
        return false
    end
    local item = row.parent_row.items[row.parent_index]
    if not item or not item.frac then
        return false
    end
    local other = (row.parent_slot == "num") and item.den or item.num
    if #other.items > 0 then
        return false
    end

    local parent_row = row.parent_row
    local index = row.parent_index
    table.remove(parent_row.items, index)
    reindex_children(parent_row, index)
    state.version = (state.version or 0) + 1
    state.cursor = {row = parent_row, pos = index - 1}
    return true
end

local function backspace(state)
    local row, pos = state.cursor.row, state.cursor.pos
    if pos > 0 then
        -- Deliberately NOT collapse_if_both_empty() here, even though removing the last glyph
        -- can leave both slots empty - the cell must ALREADY be empty at the moment Backspace is
        -- pressed (handled below) for it to be undone, not merely become empty as a result of
        -- THIS press. Otherwise typing "B" into a fresh superscript and immediately backspacing
        -- it out would silently delete the whole sup/sub structure in one keystroke instead of
        -- just clearing what was typed - a second, separate Backspace (on the now-empty cell) is
        -- what actually dismisses it.
        table.remove(row.items, pos)
        state.version = (state.version or 0) + 1
        state.cursor.pos = pos - 1
    elseif row.parent_row then
        -- Backspace is the ONLY key that undoes a sup/sub/frac spawn - not Delete, only when both
        -- slots are ALREADY empty when it's pressed (see the comments above). Right after spawning
        -- one (cursor lands in the new, empty slot - see make_supsub()/new_from_base()/
        -- make_frac()/new_with_frac()), pos is already 0 with nothing to remove, so this is the
        -- only place that check happens.
        if collapse_if_both_empty(state, row) or collapse_frac_if_both_empty(state, row) then
            return
        end
        -- Same rule as move_left(): nothing to delete here, just navigate the same way leaving
        -- this row to the left would. A frac's num/den have no base to fall into (Left/Right treat
        -- the whole node as one opaque stop - see this file's model comment), so they land right
        -- before the node instead, same as exiting a base does.
        if row.parent_slot == "base" or row.parent_slot == "num" or row.parent_slot == "den" then
            state.cursor = {row = row.parent_row, pos = row.parent_index - 1}
        else
            local item = row.parent_row.items[row.parent_index]
            state.cursor = {row = item.base, pos = #item.base.items}
        end
    end
end

local function delete_fwd(state)
    local row, pos = state.cursor.row, state.cursor.pos
    if pos < #row.items then
        table.remove(row.items, pos + 1)
        state.version = (state.version or 0) + 1
    end
end

-- size_off (see editor.lua's insert_ncod() comment) renders this ONE glyph bigger/smaller than
-- the row it's in - "\\int" is the only glyph that currently sets it. Omitted from the item
-- entirely when nil, so a normal glyph is just {code=}.
local function insert_glyph(state, ncod, size_off)
    local row, pos = state.cursor.row, state.cursor.pos
    table.insert(row.items, pos + 1, {code = ncod, size_off = size_off})
    state.version = (state.version or 0) + 1
    state.cursor.pos = pos + 1
end

function mformula.handle_input(state)
    local is_ctrl = vc.ImGui_IsKeyDown("ImGuiKey_LeftCtrl") or vc.ImGui_IsKeyDown("ImGuiKey_RightCtrl")
    local is_shift = vc.ImGui_IsKeyDown("ImGuiKey_LeftShift") or vc.ImGui_IsKeyDown("ImGuiKey_RightShift")
    local is_alt = vc.ImGui_IsKeyDown("ImGuiKey_LeftAlt") or vc.ImGui_IsKeyDown("ImGuiKey_RightAlt")

    -- Ctrl+Shift+'-' is Ctrl+Shift+'_' on the keyboard - "_" reads as a subscript.
    if is_ctrl and is_shift and vc.ImGui_IsKeyPressed("ImGuiKey_Minus", false) then
        make_supsub(state, "sub")
        return
    end
    -- Ctrl+Shift+'=' is Ctrl+Shift+'+' - reads as "up", superscript.
    if is_ctrl and is_shift and vc.ImGui_IsKeyPressed("ImGuiKey_Equal", false) then
        make_supsub(state, "sup")
        return
    end
    -- Ctrl+/: a new, empty fraction at the cursor - see make_frac()'s own comment.
    if is_ctrl and not is_shift and vc.ImGui_IsKeyPressed("ImGuiKey_Slash", false) then
        make_frac(state)
        return
    end

    -- Space, handled explicitly rather than trusting it to show up via
    -- vc.ImGui_input_queue_chars() below (it doesn't always) - see slot_markers() for how a
    -- typed space stays visible despite being otherwise blank ink.
    if not is_ctrl and vc.ImGui_IsKeyPressed("ImGuiKey_Space", true) then
        insert_glyph(state, SPACE_NCOD)
        return
    end

    -- Alt+letter Greek shortcuts - same mapping and fallback rule as editor.lua's plain text
    -- (char.greek_keys/greek_alt/greek_alt_shift), so a formula reads Alt+g as gamma the same way
    -- the surrounding text does, not just plain 'g'.
    if is_alt then
        for key_name, letter in pairs(char.greek_keys) do
            if vc.ImGui_IsKeyPressed(key_name, true) then
                local desc = is_shift and char.greek_alt_shift[letter] or char.greek_alt[letter]
                local entry = desc and char.find_by_desc(desc)
                if not entry then
                    entry = char.find_by_ascii(is_shift and letter:upper() or letter)
                end
                if entry then
                    insert_glyph(state, entry.ncod, char.size_delta_by_desc[entry.desc])
                end
            end
        end
    elseif not is_ctrl then
        local codepoints = vc.ImGui_input_queue_chars()
        for _, cp in ipairs(codepoints) do
            -- > 32, not >= : space is handled explicitly above (the char queue doesn't always
            -- carry it), so skip it here to avoid inserting it twice on a frame where it does.
            if cp > 32 and cp < 256 then
                local entry = char.find_by_ascii(string.char(cp))
                if entry then
                    insert_glyph(state, entry.ncod)
                end
            end
        end
    end

    if vc.ImGui_IsKeyPressed("ImGuiKey_Backspace", true) then backspace(state) end
    if vc.ImGui_IsKeyPressed("ImGuiKey_Delete", true) then delete_fwd(state) end
    if vc.ImGui_IsKeyPressed("ImGuiKey_LeftArrow", true) then move_left(state) end
    if vc.ImGui_IsKeyPressed("ImGuiKey_RightArrow", true) then move_right(state) end
    if vc.ImGui_IsKeyPressed("ImGuiKey_UpArrow", true) then move_vertical(state, true) end
    if vc.ImGui_IsKeyPressed("ImGuiKey_DownArrow", true) then move_vertical(state, false) end
end

-- #################################################################################################
-- Layout / render
-- #################################################################################################

--[[ Every row that currently EXISTS in the tree (state.root, plus every base and every already-
created sup/sub/frac, at any depth), paired with its nesting depth. Doesn't create anything (unlike
move_vertical()'s ensure_slot()) - a sup/sub nobody has typed into yet just isn't a candidate for
a click to land in, since there's nothing drawn there to click on (a frac's num/den, by contrast,
always both exist the moment the node does - see this file's model comment - so there's no
"nobody's visited it yet" case to skip for those). ]]
local function collect_rows(row, depth, out)
    out[#out + 1] = {row = row, depth = depth}
    for _, item in ipairs(row.items) do
        if item.supsub then
            collect_rows(item.base, depth + 1, out)
            if item.sup then
                collect_rows(item.sup, depth + 1, out)
            end
            if item.sub then
                collect_rows(item.sub, depth + 1, out)
            end
        elseif item.frac then
            collect_rows(item.num, depth + 1, out)
            collect_rows(item.den, depth + 1, out)
        end
    end
end

--[[ build_row() always computes a row's positions relative to THAT row's own local origin (0,0) -
it has no way to know in advance where mexpr_supsub will actually place it (that's only knowable
AFTER the merge, via anchor_at - see build_row's supsub branch). So once it IS known, every
position recorded anywhere in `row`'s own subtree (not just `row` itself - anything nested inside
it inherited that same "relative to row's origin" frame from being built the exact same way) needs
shifting by the same (dx, dy) in one pass, converting it from "relative to row" to "relative to
row's own parent". This is the multi-position generalization of what the old, single cursor_offset
version of this did inline with a plain `x + base_cursor.x`. ]]
local function shift_positions(positions, row, dx, dy)
    local subrows = {}
    collect_rows(row, 0, subrows)
    for _, entry in ipairs(subrows) do
        for _, off in pairs(positions[entry.row]) do
            off.x = off.x + dx
            off.y = off.y + dy
        end
    end
end

--[[ Recursively builds `row` into a single merged mexpr_p (via mexpr_merge_h), recording EVERY
valid cursor position's offset - not just wherever the cursor currently happens to be - into
positions[row2][pos] = {x=, y=, sz=} for every row2 in row's own subtree (row itself, plus every
base/sup/sub nested inside it). Positions come back in ABSOLUTE terms relative to the very
top-level row build_row was originally called on (state.root) - see shift_positions()'s comment for
how a nested row's own naturally-local-origin positions get there.

This used to thread `state` through instead, snapshotting only the ONE position that happened to
match state.cursor.row/pos - callers needing a DIFFERENT position (hit_test() checking every row's
every position, slot_markers() checking every row's trailing marker, reachable_graph() checking
every BFS-discovered node) had to fake-move state.cursor there and rebuild the ENTIRE tree from
scratch just to read off that one value. Recording all of them in a single pass, and caching that
pass on state (see get_layout()), turns those into simple table lookups against one shared build -
the actual expensive work (real mexpr_* calls) only happens when something changed since the last
one, not once per lookup regardless. ]]
local function build_row(fs, sz, row, positions)
    local x = 0
    local merged = nil
    positions[row] = positions[row] or {}
    positions[row][0] = {x = 0, y = 0, sz = sz}

    local function emit(item_mexpr)
        merged = merged and vc.mexpr_merge_h(fs, merged, item_mexpr) or item_mexpr
        -- x is the real merged tree's own outer br.x, read back from mexpr_get_bb(merged) AFTER
        -- building it - not predicted by hand from item_mexpr's own bounding box (mexpr_merge_h's
        -- right-hand anchor position alone, l->br.x, is only where item_mexpr STARTS, not where
        -- the merged tree now ENDS - using that instead of this would silently stop x advancing
        -- past the very first item). This can't independently drift from what the tree actually
        -- did the way a hand-rolled formula can - which is exactly what caused the cursor to cut
        -- through "e" in "a(Be" before this asked the tree directly instead.
        x = vc.mexpr_get_bb(merged).br.x
    end

    for i = 1, #row.items do
        local item = row.items[i]

        if item.supsub then
            -- The base is a full row (like sup/sub), not a fixed single glyph - built at the
            -- same size as this row, so it reads as a normal continuation of it. An empty base
            -- row falls back to build_row's own empty-row placeholder further down.
            local base_mexpr = build_row(fs, sz, item.base, positions)
            local sub_sz = math.min(sz + SUB_SIZE_DELTA, MAX_SIZE_INDEX)

            local sup_mexpr
            if item.sup then
                sup_mexpr = build_row(fs, sub_sz, item.sup, positions)
            end
            local sub_mexpr
            if item.sub then
                sub_mexpr = build_row(fs, sub_sz, item.sub, positions)
            end

            local supsub_mexpr = vc.mexpr_supsub(fs, base_mexpr, sup_mexpr, sub_mexpr)

            -- base sits at this compound's own local origin - matches mexpr_supsub's own
            -- placement (math_expr_composer.h) exactly, since that's where it puts it too.
            shift_positions(positions, item.base, x, 0)
            if item.sup then
                -- sup, when present, is always anchor 2 (mexpr_supsub pushes base, then sup if
                -- present, then sub if present) - read its REAL position back off the node that
                -- was actually built and drawn, instead of re-deriving mexpr_supsub's yoff
                -- formula by hand here (previously duplicated in this exact spot, with a comment
                -- warning it'd silently go stale if that formula ever changed - now it can't).
                local sup_pos = supsub_mexpr:anchor_at(2)[2]
                shift_positions(positions, item.sup, x + sup_pos.x, sup_pos.y)
            end
            if item.sub then
                -- sub's anchor index depends on whether sup is ALSO present, since mexpr_supsub
                -- only pushes an anchor for a slot that actually exists: anchor 3 if sup is there
                -- too, else anchor 2.
                local sub_pos = supsub_mexpr:anchor_at(item.sup and 3 or 2)[2]
                shift_positions(positions, item.sub, x + sub_pos.x, sub_pos.y)
            end

            emit(supsub_mexpr)
        elseif item.frac then
            -- Unlike sup/sub, num/den build at the SAME size as this row - standard fraction
            -- typesetting doesn't shrink them the way an exponent shrinks (mexpr_frac itself takes
            -- no size hint either way, it just lays out whatever mexpr_p it's handed). Both always
            -- exist (see this file's model comment), so no optional-slot branching is needed here
            -- the way sup/sub's item.sup/item.sub checks need.
            local num_mexpr = build_row(fs, sz, item.num, positions)
            local den_mexpr = build_row(fs, sz, item.den, positions)
            local frac_mexpr = vc.mexpr_frac(fs, num_mexpr, den_mexpr, char.hline_basic(sz))

            -- anchor 1 = num ("above"), anchor 2 = den ("bellow") - see mexpr_frac's own subobjs
            -- order (math_expr_composer.h); read back the same way supsub's sup/sub positions are,
            -- rather than re-deriving mexpr_frac's own centering formula by hand here.
            local num_pos = frac_mexpr:anchor_at(1)[2]
            local den_pos = frac_mexpr:anchor_at(2)[2]
            shift_positions(positions, item.num, x + num_pos.x, num_pos.y)
            shift_positions(positions, item.den, x + den_pos.x, den_pos.y)

            emit(frac_mexpr)
        elseif item.code == SPACE_NCOD then
            -- mexpr_symbol's own bounding box is the glyph's INK extent (char_get_bb's X0..X1),
            -- not its advance width - true for a space too, whose ink is nothing at all (X0==X1),
            -- even though its advance is a real, nonzero width. emit() (and mexpr_merge_h itself)
            -- position the NEXT item using THIS item's own br.x, so a space built via mexpr_symbol
            -- would contribute ~0 there regardless of how wide it's supposed to read, and whatever
            -- comes after it would land right on top of it instead of past it. mexpr_empty() gives
            -- a box whose br.x IS exactly the width handed to it, sidestepping the whole ink-vs-
            -- advance distinction - built at the item's own effective size like any other glyph
            -- here, but with no height, since a space has no visual extent to grow the line for.
            local item_sz = item.size_off and math.max(1, math.min(MAX_SIZE_INDEX, sz + item.size_off)) or sz
            local space_sz = fs:char_get_sz({size = item_sz, code = item.code})
            emit(vc.mexpr_empty(fs, space_sz.adv, 0, 0))
        else
            -- item.size_off (see insert_glyph()'s comment) renders this ONE glyph bigger/smaller
            -- than the row's own sz - "\\int" is the only glyph that currently sets it.
            -- mexpr_symbol's own symb_off already centers any glyph on ITS OWN size's 'a'-middle,
            -- so mixing sizes here still lines up on that shared reference without needing any
            -- extra per-item baseline reconciliation (unlike the cursor, which does need one -
            -- see draw()'s comment on cy - because it's positioned independently of a real
            -- mexpr_symbol call).
            local item_sz = item.size_off and math.max(1, math.min(MAX_SIZE_INDEX, sz + item.size_off)) or sz
            emit(vc.mexpr_symbol(fs, {size = item_sz, code = item.code}, true))
        end

        positions[row][i] = {x = x, y = 0, sz = sz}
    end

    if not merged then
        local ph = placeholder_size(fs, sz)
        merged = vc.mexpr_empty(fs, ph.w, ph.h, ph.h / 2)
    end

    return merged, x
end

--[[ Builds (but does not draw) state's mexpr tree, along with the pixel offset of EVERY valid
cursor position in it (see build_row()'s comment) - shared by draw()/measure()/hit_test()/
slot_markers()/reachable_graph() so none of them has to rebuild the tree themselves. Cached on
`state`, keyed by (state.version, sz) the same way reachable_graph()'s own cache already was - only
rebuilds when a tree edit (state.version) or the requested size actually changed since the last
call, so a click or a debug-overlay redraw that happens between edits reads straight from this
instead of re-running real mexpr_* calls for something that hasn't moved. ]]
local function get_layout(state, fontset, sz)
    local cache = state._layout_cache
    if cache and cache.version == (state.version or 0) and cache.sz == sz then
        return cache.layout
    end

    local positions = {}
    local merged = build_row(fontset, sz, state.root, positions)
    local correction = baseline_correction(fontset, sz)
    local bb = vc.mexpr_get_bb(merged)
    local layout = {
        merged = merged,
        positions = positions,
        correction = correction,
        -- top/bottom relative to the baseline y a caller would pass to draw()/measure() - see
        -- baseline_correction()'s comment for why `correction` folds in here.
        width = bb.br.x - bb.tl.x,
        top = correction + bb.tl.y,
        bottom = correction + bb.br.y,
    }
    state._layout_cache = {version = state.version or 0, sz = sz, layout = layout}
    return layout
end

--[[ compute()-shaped view of get_layout() for whatever state.cursor currently is - kept as its own
small function since draw()/measure() only ever care about THE cursor, not the full position table
get_layout() computes (once) to serve everyone else. ]]
local function compute(state, fontset, sz)
    local layout = get_layout(state, fontset, sz)
    local row_positions = layout.positions[state.cursor.row]
    return {
        merged = layout.merged,
        cursor_offset = row_positions and row_positions[state.cursor.pos],
        correction = layout.correction,
        width = layout.width,
        top = layout.top,
        bottom = layout.bottom,
    }
end

--[[ Debug aid: every cursor position reachable from the very start - Left/Right within a row,
Up/Down into a node's sup/sub - as a graph: `nodes` is a list of {x, y} pixel offsets from the
formula's own draw origin, `edges` is a list of {a, b} node-index pairs for every RECIPROCAL
one-keypress hop between them, where reciprocal means specifically Left-then-Right (or
Right-then-Left), or Up-then-Down (or Down-then-Up), landing back exactly where it started - not
"any key returns you," which the tree's redirect/collapse rules (move_left()/move_right()'s own
comments cover several cases) make true FAR more often than it's a useful thing to draw, turning
the graph into a dense tangle for even a small formula. A move that isn't reciprocal by that
narrower definition is still a real, correct keypress - it's just left off the picture.

BFS over the real move_left()/move_right()/move_vertical() functions (not a re-derivation of what
they do) discovers every reachable NODE regardless of reciprocity (a sup/sub nobody has navigated
into yet still shows - ensure_slot() creates it on the fly, same as a real keypress would), so
nothing is missing even if the specific hop that reached it doesn't get drawn as an edge.

A node's (x, y) matches EXACTLY what draw()'s blinker computes for that same position, including
the extra per-size baseline_correction() undo a nested (smaller-sized, sup/sub) cursor needs on
top of the outer correction - see draw()'s comment on cy - so the dot always sits where that
position's own blinker would, not just correct at the outer size.

Cached on `state` and only rebuilt when `state.version` (bumped by every tree edit - see
insert_glyph()/backspace()/delete_fwd()/make_supsub()/ensure_slot()) or `sz` has changed since -
this runs a full BFS plus one compute() (a real mexpr build) per node, so redoing it every single
frame regardless of whether anything changed would be wasteful for what's just a debug overlay. ]]
function mformula.reachable_graph(state, fontset, sz)
    local cache = state._graph_cache
    if cache and cache.version == (state.version or 0) and cache.sz == sz then
        return cache.graph
    end

    local saved_cursor = state.cursor
    local correction = baseline_correction(fontset, sz)

    local function screen_offset(off)
        local caret_sz = off.sz or sz
        local cm = get_metrics(fontset, caret_sz)
        local dy = correction + off.y - baseline_correction(fontset, caret_sz)
                + cm.baseline_shift + cm.line_height / 2
        return off.x, dy
    end

    local nodes, index_of = {}, {}
    local function get_or_add(row, pos)
        local k = tostring(row) .. ":" .. pos
        local idx = index_of[k]
        if idx then
            return idx, false
        end
        -- Reads straight off get_layout()'s cached position table instead of fake-moving
        -- state.cursor there and rebuilding the whole tree just for this one lookup - called
        -- fresh (not hoisted above the BFS loop) since ensure_slot() below can bump state.version
        -- mid-BFS when it lazily creates a sup/sub nobody has visited yet, which this needs to see
        -- on the next call; get_layout() itself is a no-op rebuild when nothing actually changed.
        local layout = get_layout(state, fontset, sz)
        local row_positions = layout.positions[row]
        local off = row_positions and row_positions[pos]
        local dx, dy = 0, 0
        if off then
            dx, dy = screen_offset(off)
        end
        nodes[#nodes + 1] = {x = dx, y = dy}
        idx = #nodes
        index_of[k] = idx
        return idx, true
    end

    local movers = {
        {name = "left", fn = move_left},
        {name = "right", fn = move_right},
        {name = "up", fn = function(s) move_vertical(s, true) end},
        {name = "down", fn = function(s) move_vertical(s, false) end},
    }
    local opposite_name = {left = "right", right = "left", up = "down", down = "up"}

    -- trans[idx][name] = the node index that key reaches from idx - the full directed transition
    -- table, filled in as the BFS visits every reachable node exactly once (trying all 4 movers
    -- each time), then used afterward to test reciprocity without a second traversal: by the time
    -- BFS finishes, every node's own 4 transitions are already recorded, including any node that
    -- was reached by a non-reciprocal hop.
    local trans = {}

    local start_idx = get_or_add(state.root, 0)
    local queue, qi = {{row = state.root, pos = 0, idx = start_idx}}, 1
    while qi <= #queue do
        local cur = queue[qi]
        qi = qi + 1
        trans[cur.idx] = trans[cur.idx] or {}
        for _, m in ipairs(movers) do
            state.cursor = {row = cur.row, pos = cur.pos}
            m.fn(state)
            local nrow, npos = state.cursor.row, state.cursor.pos
            if nrow ~= cur.row or npos ~= cur.pos then
                local idx, is_new = get_or_add(nrow, npos)
                trans[cur.idx][m.name] = idx
                if is_new then
                    queue[#queue + 1] = {row = nrow, pos = npos, idx = idx}
                end
            end
        end
    end

    local edges, seen = {}, {}
    for a, by_name in pairs(trans) do
        for name, b in pairs(by_name) do
            if trans[b] and trans[b][opposite_name[name]] == a then
                local lo, hi = math.min(a, b), math.max(a, b)
                local key = lo .. ">" .. hi
                if not seen[key] then
                    seen[key] = true
                    edges[#edges + 1] = {a = lo, b = hi}
                end
            end
        end
    end

    state.cursor = saved_cursor
    local graph = {nodes = nodes, edges = edges}
    state._graph_cache = {version = state.version or 0, sz = sz, graph = graph}
    return graph
end

--[[ Where a click at `click` (={x,y}, in the same space as draw()'s own `pos` - i.e. already
offset by the formula's on-screen draw origin) should place the cursor: among the existing rows
whose own vertical band (get_metrics() line-height, centered the same way its blinker/track dot
would be) contains click.y, prefer one whose own horizontal span (leftmost to rightmost reachable
x - which its trailing marker, see slot_markers(), pokes out a bit past on the right) ALSO
contains click.x, deepest wins ties; if none of them span that far (root's own trailing marker,
"after A^B", necessarily sticks out past every row nested inside it - base's own span stops at
"after A", far short of it) fall back to whichever row reaches furthest right, since that's whose
marker is actually being clicked. Without the x-span check, root and a plain base sharing the
exact same y-band (both sit right on the formula's main baseline) would always resolve to base
(deeper), so clicking anywhere on root's own trailing marker landed one node to the left of it
instead. Finally, within the chosen row, whichever position (0..#row.items) has the nearest x -
the same per-position x get_layout() already gives every blinker and every reachable_graph() node,
so a click lands exactly between the same two glyphs the graph shows a node between.
@return {row=, pos=} ]]
function mformula.hit_test(state, fontset, sz, click)
    local layout = get_layout(state, fontset, sz)
    local correction = layout.correction

    local function row_pos_x(row, pos)
        local off = layout.positions[row] and layout.positions[row][pos]
        return off and off.x or nil
    end

    local function row_anchor(row)
        local off = layout.positions[row] and layout.positions[row][0]
        if not off then
            return nil
        end
        local caret_sz = off.sz or sz
        local cm = get_metrics(fontset, caret_sz)
        local dy = correction + off.y - baseline_correction(fontset, caret_sz)
        return dy + cm.baseline_shift, dy + cm.baseline_shift + cm.line_height
    end

    local rows = {}
    collect_rows(state.root, 0, rows)

    local containing, fallback, fallback_dist = {}, nil, math.huge
    for _, entry in ipairs(rows) do
        local top, bottom = row_anchor(entry.row)
        if top then
            entry.center_dist = math.abs(click.y - (top + bottom) / 2)
            entry.min_x = row_pos_x(entry.row, 0) or 0
            entry.max_x = row_pos_x(entry.row, #entry.row.items) or entry.min_x
            if click.y >= top and click.y <= bottom then
                containing[#containing + 1] = entry
            else
                local d = math.min(math.abs(click.y - top), math.abs(click.y - bottom))
                if d < fallback_dist then
                    fallback_dist = d
                    fallback = entry
                end
            end
        end
    end

    local target = state.root
    if #containing > 0 then
        local x_containing = {}
        for _, entry in ipairs(containing) do
            if click.x >= entry.min_x and click.x <= entry.max_x then
                x_containing[#x_containing + 1] = entry
            end
        end

        if #x_containing > 0 then
            -- Depth wins first (the deepest box that intersects the click); a same-depth tie
            -- (e.g. a small formula where a sup's and the base's own bands overlap near their
            -- edges) goes to whichever row's band CENTER the click sits nearest, not just
            -- whichever was checked first - a plain first-wins tie-break would silently favor
            -- base/sup/sub in that fixed order regardless of which one the click actually reads
            -- as closer to.
            local deepest = x_containing[1]
            for _, entry in ipairs(x_containing) do
                if entry.depth > deepest.depth
                        or (entry.depth == deepest.depth and entry.center_dist < deepest.center_dist) then
                    deepest = entry
                end
            end
            target = deepest.row
        else
            -- The click is past every candidate's own content (only their trailing markers
            -- reach out this far) - whichever reaches furthest right is the one whose marker
            -- this actually is.
            local rightmost = containing[1]
            for _, entry in ipairs(containing) do
                if entry.max_x > rightmost.max_x then
                    rightmost = entry
                end
            end
            target = rightmost.row
        end
    elseif fallback then
        target = fallback.row
    end

    local best_pos, best_dist = 0, math.huge
    local target_positions = layout.positions[target]
    for p = 0, #target.items do
        local off = target_positions and target_positions[p]
        if off then
            local d = math.abs(off.x - click.x)
            if d < best_dist then
                best_dist = d
                best_pos = p
            end
        end
    end

    return {row = target, pos = best_pos}
end

--[[ A trailing marker for every row INCLUDING root - "after A_B" (the very end of the formula)
needs one too, or that position is only reachable by arrow keys, never by clicking - positioned
right after that row's own content: at its only position if it's empty (a sup/sub created
alongside its typed-into sibling, see make_supsub()/new_from_base(), that nobody has put anything
in yet), or right after its last glyph if it isn't. A FILLED row's own glyphs already show what's
clickable there; an EMPTY row has nothing else to show at all - either way, without this there's
no visible sign that clicking just past a row's content still lands in that row (hit_test()'s row
band isn't limited by x), so a filled slot's "room to keep typing" read as different from an empty
slot's "click here to start" - this makes them look the same. Each marker's height/vertical
position exactly matches what draw()'s blinker would occupy AT that position (cm.line_height
tall, starting at cm.baseline_shift below the row's own baseline) - not a fixed/placeholder size -
so the box reads as "this is where the cursor can be," not as an unrelated decoration.

Returns a list of {x, y, w, h} rects (relative to the formula's draw origin, top-left convention
like the rest of ImGui's draw calls). mexpr_empty() only actually PAINTS anything when
mexpr_draw() is called with draw_bb=true (a whole-tree debug overlay, wrong tool here - it'd also
mark every internal anchor, not just row ends) - draw() always passes false, so these positions
are otherwise real (hit_test() can land there, Left/Right/Up/Down can walk there) but entirely
invisible without this. ]]
function mformula.slot_markers(state, fontset, sz)
    local layout = get_layout(state, fontset, sz)
    local correction = layout.correction

    local rows = {}
    collect_rows(state.root, 0, rows)

    local markers = {}
    for _, entry in ipairs(rows) do
        do
            local off = layout.positions[entry.row] and layout.positions[entry.row][#entry.row.items]
            if off then
                local caret_sz = off.sz or sz
                local ph = placeholder_size(fontset, caret_sz)
                local cm = get_metrics(fontset, caret_sz)
                local dy = correction + off.y - baseline_correction(fontset, caret_sz)
                markers[#markers + 1] = {
                    x = off.x, y = dy + cm.baseline_shift, w = ph.w, h = cm.line_height,
                }
            end
        end

        -- Every space glyph in this row, marked at its own position (right before it, i.e. the
        -- position a click there would resolve to) and sized to its own advance width - not
        -- placeholder_size()'s 'a'-based width, since a space's own advance is what it actually
        -- occupies.
        for p = 1, #entry.row.items do
            if entry.row.items[p].code == SPACE_NCOD then
                local off = layout.positions[entry.row] and layout.positions[entry.row][p - 1]
                if off then
                    local caret_sz = off.sz or sz
                    local cm = get_metrics(fontset, caret_sz)
                    local space_sz = fontset:char_get_sz({size = caret_sz, code = SPACE_NCOD})
                    local dy = correction + off.y - baseline_correction(fontset, caret_sz)
                    markers[#markers + 1] = {
                        x = off.x, y = dy + cm.baseline_shift,
                        w = space_sz.adv, h = cm.line_height,
                    }
                end
            end
        end
    end

    return markers
end

--[[ Measures state at font size `sz` WITHOUT drawing it.
@return {width=, top=, bottom=} - top/bottom relative to whatever baseline y a draw() call would
use. Lets a caller (editor.lua, laying out a line) find out how much vertical room a formula needs
before it has committed to a y position for that line - so the line can grow to fit instead of the
formula clipping out of it. ]]
function mformula.measure(state, fontset, sz)
    local c = compute(state, fontset, sz)
    return {width = c.width, top = c.top, bottom = c.bottom}
end

--[[ Draws state at `pos` (its baseline origin) using base font size `sz`. The blinking caret is
only drawn when `show_cursor` is true.
@return {width=, top=, bottom=, cursor_top=, cursor_h=} - the drawn bounding box (top/bottom
relative to pos.y) - lets a caller (editor.lua's inline embed) size a "made to fit" box around it.
cursor_top/cursor_h (also relative to pos.y - same convention as top/bottom) locate the caret
itself, when show_cursor and the formula actually has one right now - editor.lua uses this to keep
the caret on screen (auto-scrolling content.lua's box stack) the same way it already tracks its own
plain-text caret, since neither the formula's box bounds nor its OUTER cursor_pos move while a
formula owns input (see this file's own model comment) - only this does. nil/nil when there's
nothing to report (show_cursor false, or no cursor_offset - e.g. an empty root row has nowhere for
a caret to sit relative to). ]]
function mformula.draw(state, fontset, pos, sz, show_cursor)
    if show_cursor == nil then
        show_cursor = true
    end

    local c = compute(state, fontset, sz)
    local draw_pos = {x = pos.x, y = pos.y + c.correction}
    vc.mexpr_draw(fontset, draw_pos, c.merged, false)

    state.frame = state.frame + 1
    local cursor_top, cursor_h = nil, nil
    if show_cursor and c.cursor_offset then
        -- cy is meant to be the TRUE baseline of whichever row the cursor is actually in, i.e.
        -- exactly where a glyph typed there would land. draw_pos.y is the top-level baseline,
        -- and cursor_offset.y carries every nested sup/sub yoff needed to reach that row's own
        -- local anchor from there - but a glyph actually drawn at that anchor gets ONE MORE
        -- offset on top at draw time: mexpr_symbol's own symb_off (math_expr_composer.h), which
        -- re-centers it on ITS OWN size's 'a' - the same thing baseline_correction() already
        -- undoes once for the formula's outer size (see that comment). A nested cursor is at a
        -- DIFFERENT (smaller) size than the outer correction was computed for, so it needs that
        -- same undo applied again, at ITS OWN size - which is exactly -baseline_correction at
        -- cursor_offset.sz (symb_off.y and baseline_correction() are negations of each other by
        -- construction). Without this, the cursor was calibrated differently than the glyphs
        -- actually landing there, and drifted further off the more nested it was.
        local caret_sz = c.cursor_offset.sz or sz
        local cx = draw_pos.x + c.cursor_offset.x
        local cy = draw_pos.y + c.cursor_offset.y - baseline_correction(fontset, caret_sz)
        local cm = get_metrics(fontset, caret_sz)
        local caret_top = cy + cm.baseline_shift
        cursor_top, cursor_h = caret_top - pos.y, cm.line_height
        -- Position computed unconditionally above (so a caller tracking it, e.g. for
        -- auto-scrolling, sees a stable value rather than one that disappears every other blink
        -- half-period) - only the actual drawn line itself is blink-gated.
        -- (~30 frames/half-period, roughly a 0.5s blink at 60fps - matches editor.lua's own caret.)
        if math.floor(state.frame / 30) % 2 == 0 then
            vc.ImGui_AddLine({x = cx, y = caret_top}, {x = cx, y = caret_top + cm.line_height},
                    CURSOR_COLOR, 2)
        end
    end

    return {width = c.width, top = c.top, bottom = c.bottom,
            cursor_top = cursor_top, cursor_h = cursor_h}
end

-- #################################################################################################
-- LaTeX serialization (for the clipboard - editor.lua wraps/strips the surrounding $$)
-- #################################################################################################

-- Characters that mean something special in our LaTeX subset (group/sup/sub syntax, or the
-- backslash-escape itself) - a literal occurrence of one of these as TYPED content gets
-- backslash-escaped on the way out, so from_latex() can always tell "a typed \ or $ or { etc.
-- character" apart from real syntax on the way back in.
local LATEX_ESCAPE_CHARS = {["$"]=true, ["\\"]=true, ["{"]=true, ["}"]=true, ["^"]=true, ["_"]=true}

local function latex_escape_char(c)
    if LATEX_ESCAPE_CHARS[c] then
        return "\\" .. c
    end
    return c
end

local function row_to_latex(row)
    local parts = {}
    for _, item in ipairs(row.items) do
        if item.supsub then
            parts[#parts+1] = row_to_latex(item.base)
            -- An empty sup/sub (never typed into - see make_supsub()'s eager opposite-slot
            -- creation) carries no content worth round-tripping, so it's simply omitted rather
            -- than emitted as e.g. "^{}" - from_latex() building the node without that slot at
            -- all is equivalent to how a fresh node looks before Up/Down ever visits that side.
            if item.sup and #item.sup.items > 0 then
                parts[#parts+1] = "^{" .. row_to_latex(item.sup) .. "}"
            end
            if item.sub and #item.sub.items > 0 then
                parts[#parts+1] = "_{" .. row_to_latex(item.sub) .. "}"
            end
        elseif item.frac then
            -- Unlike an empty sup/sub, num/den are never "unvisited" (both always exist - see
            -- this file's model comment), so there's no equivalent omit-if-empty case here: even
            -- a freshly Ctrl+/'d, still-empty fraction round-trips as "\frac{}{}".
            parts[#parts+1] = "\\frac{" .. row_to_latex(item.num) .. "}{" .. row_to_latex(item.den) .. "}"
        elseif item.code == SPACE_NCOD then
            parts[#parts+1] = " "
        else
            local entry = char.find_by_ncod(item.code)
            if entry then
                if entry.acod ~= '\0' then
                    parts[#parts+1] = latex_escape_char(entry.acod)
                else
                    -- No plain-ASCII form (greek/symbols) - char.lua's own `desc` for these IS
                    -- their LaTeX macro name (e.g. "\\alpha"); the trailing space keeps it from
                    -- running into whatever glyph comes right after, same as editor.lua's own
                    -- plain-text selection_to_text() already does for these.
                    parts[#parts+1] = entry.desc .. " "
                end
            end
        end
    end
    return table.concat(parts)
end

--[[ Renders `state`'s tree as a LaTeX-subset string - NOT wrapped in $$ (editor.lua's own
selection_to_text() does that, the same place it decides a formula embed needs $$ at all). Only
covers what this editor itself can produce: plain glyphs, the greek/symbol shortcuts in char.lua
(by their own `desc`), spaces, ^{...}/_{...} for sup/sub, and \frac{...}{...} - nothing fancier
(big-ops, brackets) since nothing in this editor builds those yet either. ]]
function mformula.to_latex(state)
    return row_to_latex(state.root)
end

--[[ Parses the LaTeX-subset content of a $$...$$ span into a bare {items=...} row (no
parent_row/parent_index/parent_slot yet - see fixup_parents()) starting at 1-based `pos`. Stops at
a matching "}" (left for the caller to consume) or end of string. Returns row, next_pos.

Deliberately lenient, not a general LaTeX parser: an unrecognized "\\foo" macro is silently
dropped (same spirit as editor.lua's insert_text() skipping unmapped bytes on plain paste) rather
than erroring - pasted LaTeX may well use commands this editor has no glyph for. ]]
local function parse_latex_row(s, pos)
    local row = {items = {}}
    while pos <= #s do
        local c = s:sub(pos, pos)
        if c == "}" then
            break
        elseif c == "^" or c == "_" then
            local slot = (c == "^") and "sup" or "sub"
            pos = pos + 1
            local content
            if s:sub(pos, pos) == "{" then
                content, pos = parse_latex_row(s, pos + 1)
                if s:sub(pos, pos) == "}" then
                    pos = pos + 1
                end
            else
                -- Bare single-token shorthand (x^2, no braces) - accepted here for compatibility
                -- with hand-written LaTeX, even though to_latex() never emits it.
                content = {items = {}}
                local one = s:sub(pos, pos)
                local entry = one ~= "" and char.find_by_ascii(one)
                if entry then
                    content.items[1] = {code = entry.ncod}
                    pos = pos + 1
                end
            end
            local last = row.items[#row.items]
            local target
            if last and last.supsub then
                -- The SAME node getting its other slot (x^{2}_{3}) - attach, don't nest again.
                target = last
            else
                target = {supsub = true, base = {items = last and {last} or {}}}
                if last then
                    row.items[#row.items] = target
                else
                    row.items[#row.items + 1] = target
                end
            end
            target[slot] = content
        elseif c == "\\" then
            pos = pos + 1
            local nc = s:sub(pos, pos)
            if nc:match("%a") then
                local start = pos
                while s:sub(pos, pos):match("%a") do
                    pos = pos + 1
                end
                local name = s:sub(start, pos - 1)
                if name == "frac" then
                    -- \frac{num}{den} - the one macro name that isn't a glyph lookup. A missing
                    -- brace group (malformed/truncated input) is just treated as empty, same
                    -- leniency the rest of this parser already has for anything it can't make
                    -- sense of, rather than erroring.
                    local function brace_group()
                        if s:sub(pos, pos) == "{" then
                            local content
                            content, pos = parse_latex_row(s, pos + 1)
                            if s:sub(pos, pos) == "}" then
                                pos = pos + 1
                            end
                            return content
                        end
                        return {items = {}}
                    end
                    local num_row = brace_group()
                    local den_row = brace_group()
                    row.items[#row.items + 1] = {frac = true, num = num_row, den = den_row}
                else
                    local entry = char.find_by_desc("\\" .. name)
                    if entry then
                        row.items[#row.items + 1] =
                                {code = entry.ncod, size_off = char.size_delta_by_desc[entry.desc]}
                    end
                    -- to_latex() always emits one trailing space after a macro name - consume it
                    -- so round-tripping our own output doesn't leave a stray space glyph behind.
                    if s:sub(pos, pos) == " " then
                        pos = pos + 1
                    end
                end
            else
                -- Escaped literal (\$, \\, \{, \}, \^, \_).
                local entry = nc ~= "" and char.find_by_ascii(nc)
                if entry then
                    row.items[#row.items + 1] = {code = entry.ncod}
                end
                pos = pos + 1
            end
        else
            local entry = char.find_by_ascii(c)
            if entry then
                row.items[#row.items + 1] = {code = entry.ncod}
            end
            pos = pos + 1
        end
    end
    return row, pos
end

--[[ Fills in parent_row/parent_index/parent_slot on every row parse_latex_row() built (it can't
know these until a row's been placed into its own parent's item, which only happens after both
already exist) - the same fields new_row() sets up for a row created interactively. ]]
local function fixup_parents(row, parent_row, parent_index, parent_slot)
    row.parent_row, row.parent_index, row.parent_slot = parent_row, parent_index, parent_slot
    for i, item in ipairs(row.items) do
        if item.supsub then
            fixup_parents(item.base, row, i, "base")
            if item.sup then
                fixup_parents(item.sup, row, i, "sup")
            end
            if item.sub then
                fixup_parents(item.sub, row, i, "sub")
            end
        elseif item.frac then
            fixup_parents(item.num, row, i, "num")
            fixup_parents(item.den, row, i, "den")
        end
    end
end

--[[ parse_latex_row() only ever creates the slot(s) a "^"/"_" actually showed up for - a node
built from "x^{2}" alone has sup set but sub left nil. A node built interactively never looks like
that: make_supsub()/new_from_base() always create BOTH slots together, empty or not, specifically
so mexpr_supsub() reserves layout space for both sides symmetrically (see the comment in
build_row()'s supsub branch on how a missing slot vs. a present-but-empty one differ there) - a
nil sub renders at a slightly different height than an empty-but-real one. Filling in whichever
slot is still nil, after the fact, makes a pasted node's geometry match what typing the same thing
would have produced, not just its visible glyphs. ]]
local function ensure_both_slots(row)
    for _, item in ipairs(row.items) do
        if item.supsub then
            item.sup = item.sup or {items = {}}
            item.sub = item.sub or {items = {}}
            ensure_both_slots(item.base)
            ensure_both_slots(item.sup)
            ensure_both_slots(item.sub)
        elseif item.frac then
            -- num/den are never optional to begin with - parse_latex_row()'s \frac handling
            -- always builds both (defaulting to an empty row if a brace group is missing) - so
            -- this only needs to recurse into them, not fill anything in.
            ensure_both_slots(item.num)
            ensure_both_slots(item.den)
        end
    end
end

--[[ Inverse of to_latex(): parses a LaTeX-subset string (again, NOT expecting the surrounding $$
- editor.lua strips those before calling this) into a fresh formula state, same shape as
mformula.new(). Never errors - unparseable/unsupported bits are just dropped, matching
insert_text()'s own leniency for plain-text paste. ]]
function mformula.from_latex(s)
    local root = parse_latex_row(s, 1)
    ensure_both_slots(root)
    fixup_parents(root, nil, nil, nil)
    return {
        root = root,
        cursor = {row = root, pos = #root.items},
        frame = 0,
        version = 0,
    }
end

return mformula

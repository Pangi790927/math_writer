--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | new(id: id | nil)                       -> editor_formula.state_formula
-- |     A fresh, empty box.
-- |
-- | draw(state_formula: editor_formula.state_formula, fontset: fontset, pos: {x,y}, sz: size,
-- |      width_limit: number, show_cursor: boolean, show_wireframe: boolean, show_graph: boolean)
-- |      -> height
-- |     Draws the box and returns the height it filled, so the caller can
-- |     lay out whatever follows without measuring it again.
-- |
-- | formula_at(state_formula: editor_formula.state_formula, pos: {x,y}) -> {container, hb} | nil
-- |     The formula under a screen point. This box holds exactly one, so
-- |     the search is the containment test alone - same answer
-- |     editor_text.formula_at gives for a box that holds many.
-- |
-- | handle_input(state_formula: editor_formula.state_formula, fontset: fontset, sz: size)
-- |      -> changed
-- |     One frame of input. True when the box's CONTENT changed, which
-- |     only a paste can do.
-- |
-- | rescale(state_formula: editor_formula.state_formula, fontset: fontset) -> nothing
-- |     Re-lays-out after a zoom.
-- |
-- | to_text(state_formula: editor_formula.state_formula) -> text
-- | from_text(state_formula: editor_formula.state_formula, text: string, fontset: fontset)
-- |      -> nothing
-- |     The save format, length-prefixed like editor_definition's.
-- |
-- | --- internal, not on the module table ---------------------------------------------------------
-- |     ensure, clipboard_latex, STATE_FIELDS, STATE_SHAPE, and the field's padding and colours
-- |
-- | @date 2026-09-13 19:10
-- | ===============================================================================================
--]]

--[[
editor_formula.lua - the editor inside a FORMULA box (the blue one). One step of a derivation.

THE WHOLE INTERACTION, stated 2026-09-07: "the box allows you to do: copy-paste a new formula when
empty, do one of the transformations and that's kinda it, after a transformation a new box will
appear with the transformation".

So a formula box has exactly two states and there is no third:

  EMPTY     nothing in it yet. A paste fills it. That is the ONLY way content gets in - you do not
            type a formula here, you type it in a text box and bring it over.
  FILLED    not editable. You may select and copy; you may apply a transformation. A transformation
            does not change this box - it emits a NEW one holding the result.

A PASTE ALWAYS WORKS, in either state_formula,
        and pasting into a filled box **makes it a root**: its
content no longer came from the box it used to point at, so the parent link goes with the old
content. Stated 2026-09-07: "not refused, just makes it a root". That is the one thing that can
replace a formula box's content, and it is not an edit of the derivation - it is the box leaving
the derivation and starting a new one.

WHY IMMUTABLE, since it is the part that looks like a restriction and is actually the point:
docs/phase2_design.md section 1. A cell's descendants can never be invalidated, because nothing
upstream can change. Editing is not forbidden so much as RELOCATED - copy out as LaTeX, edit in a
text box, paste back as a new box. That is what makes a chain of these a proof rather than a
document, and it is why this file has no insert path at all.

WHAT IS NOT HERE YET: the transformations, and with them the AST. Applying one means resolving a
selection to a set of AST ids through the ast<->mexpr mapping (section 12), running a transform from
transforms.lua, and recording the justification (transform, source ids, rule set). None of that
exists: there is no `mexpr_ast` expression parser yet, so a formula box has no AST to select into.
Being able to hold a formula, show it, and let it be copied is everything that can honestly be built
before that parser.

The immutability is enforced the same way the definition box's derived rows enforce theirs: input
goes to the formula so that selection, navigation and copy work, and an EDIT is discarded by
rebuilding from the text that was last committed. Enumerating "which keys are edits" would be a
list to forget an entry from; asking "did the tree change" cannot be.

@date 2026-09-08 08:06
]]

local vc = require("virt_composer")
local mformula = require("mformula_new")
local mexpru = require("mexpru")
local keymap = require("keymap")
local editor = require("editor")  -- the shared formula host; see its header
local sealed = require("sealed")

local editor_formula = {}

local FIELD_PAD = 3
local SLOT_BG_COLOR   = 0x22ffffff
local SLOT_EDGE_COLOR = 0x66ffffff

--[[ THE `state_formula` CONTAINER for a formula box. Declared through sealed.lua; see that file for the
rule. `formula` is built lazily by ensure() below, which is why it and `latex` are both here and
either may be nil.
@date 2026-09-12 06:05 ]]
local STATE_FIELDS = {
    id       = "the box's id, as content.lua assigns it",
    parent   = "the box this one was derived from, or nil",
    latex    = "the committed text; the source of truth when `formula` has not been built yet",
    formula  = "the live mformula container, built from `latex` on first use",
    hit      = "the click box the last draw left behind",
    dragging = "true while a click-drag selection is in progress",
}
local STATE_SHAPE = sealed.declare("editor_formula", "state_formula", STATE_FIELDS)

--[[ @brief A fresh, empty formula box.
-- |
-- | THE STRING IS THE TRUTH, NOT THE TREE. `latex` is the committed content and the formula is
-- | rebuilt from it, which is what makes discarding an edit a rebuild rather than an undo.
-- |
-- | `id` AND `parent` ARE THE DERIVATION LINK - the proof DAG of docs/phase2_design.md section 1
-- | written down: a root has no parent, and a box produced by transforming another records that
-- | other's id. content.lua writes `parent` when it emits a transformed box.
-- |
-- | @details The ids live inside the box's own saved body (to_text) rather than in the box header,
-- |          so the document format above this file does not have to learn about them.
-- |
-- | @param id  id | nil - as content.lua assigns it; nil for a box whose id comes from from_text
-- | @return editor_formula.state_formula - sealed; no latex, no formula, no parent
-- |
-- | @date 2026-09-13 19:10
--]]
function editor_formula.new(id)
    return STATE_SHAPE.wrap{latex = nil, formula = nil, id = id, parent = nil}
end

--[[ Builds the live formula from the committed text, if it is missing. Needs a fontset, which
new() does not have - same lazy arrangement editor_definition.lua uses and for the same reason.
@date 2026-09-08 08:06 ]]
local function ensure(state_formula, fontset)
    if state_formula.latex and not state_formula.formula then
        state_formula.formula = mformula.from_latex(fontset, mexpru.DEFAULT_SIZE,
                state_formula.latex)
    end
    return state_formula.formula
end

--[[ The clipboard's content as LaTeX, or nil if there is nothing usable in it.

The app's own interchange format is "$$...$$" - what mformula's own copy produces and what a text
box writes for an embedded formula - so that wrapper is stripped when present. Bare LaTeX is
accepted too: pasting from somewhere else should work, and the worst case is that from_latex()
makes little of it, which is visible immediately rather than silent.
@date 2026-09-08 08:06 ]]
local function clipboard_latex()
    local text = vc.ImGui_GetClipboardText()
    if not text or text == "" then
        return nil
    end
    local inner = text:match("^%s*%$%$(.*)%$%$%s*$")
    return inner or text
end

--[[ @brief Draws the box, and returns the height it filled so the caller can lay out what follows.
-- |
-- | AN EMPTY BOX STILL DRAWS A FIELD, so it reads as somewhere a formula can go rather than as
-- | blank space in a coloured rectangle.
-- |
-- | IT RECORDS `hit` - the rect a click must land in, plus the origin and wrap edge it was drawn
-- | at - because handle_input() runs in a different call and cannot re-derive any of them. An
-- | empty box records none.
-- |
-- | @param state_formula   editor_formula.state_formula - checked; builds the formula if missing
-- | @param fontset         fontset
-- | @param pos             {x, y} - top-left of the content; the BASELINE is worked out from
-- |                        measure()'s own `top`
-- | @param sz              size - the logical size to draw at
-- | @param width_limit     number - how far right content may reach, as a width from pos.x
-- | @param show_cursor     boolean - this is the active box: the field's edge and the caret
-- | @param show_wireframe  boolean - passed through: mexpr's debug boxes
-- | @param show_graph      boolean - passed through: the reachable-position graph
-- | @return number - the height filled, padding included
-- |
-- | @date 2026-09-13 19:10
--]]
function editor_formula.draw(state_formula, fontset, pos, sz, width_limit, show_cursor,
        show_wireframe,
        show_graph)
    STATE_SHAPE.check(state_formula)
    ensure(state_formula, fontset)
    local pad = FIELD_PAD

    if not state_formula.formula then
        local h = 24
        vc.ImGui_AddRectFilled({x = pos.x - pad, y = pos.y - pad}, {x = pos.x + 60 + pad,
                y = pos.y + h + pad}, SLOT_BG_COLOR, 3)
        if show_cursor then
            vc.ImGui_AddRect({x = pos.x - pad, y = pos.y - pad}, {x = pos.x + 60 + pad,
                    y = pos.y + h + pad}, SLOT_EDGE_COLOR, 3, 1)
        end
        state_formula.hit = nil
        return h + 2 * pad
    end

    local m = mformula.measure(state_formula.formula, fontset, sz, width_limit)
    local baseline = pos.y + pad - m.top
    vc.ImGui_AddRectFilled({x = pos.x - pad, y = baseline + m.top - pad},
            {x = pos.x + math.max(m.width, 6) + pad, y = baseline + m.bottom + pad},
            SLOT_BG_COLOR, 3)
    if show_cursor then
        vc.ImGui_AddRect({x = pos.x - pad, y = baseline + m.top - pad},
                {x = pos.x + math.max(m.width, 6) + pad, y = baseline + m.bottom + pad},
                SLOT_EDGE_COLOR, 3, 1)
    end

    local r = editor.draw_formula(state_formula.formula, fontset, sz, {x = pos.x, y = baseline}, {
        active = show_cursor,
        show_wireframe = show_wireframe,
        show_graph = show_graph,
        wrap_edge = pos.x + width_limit,
    })
    local l, rr, t, b = editor.formula_click_rect(r.box, r.markers)
    state_formula.hit = {
        x = pos.x + l - pad, y = baseline + t - pad,
        w = (rr - l) + 2 * pad, h = (b - t) + 2 * pad,
        draw_x = pos.x, draw_y = baseline, wrap_edge = pos.x + width_limit,
    }
    return (m.bottom - m.top) + 2 * pad
end

--[[ @brief This box's formula, when a screen point is over it.
-- |
-- | THE SAME ANSWER editor_text.formula_at gives for a box that can hold many formulas, so a
-- | gesture asking "what is under the pointer" does not have to know which kind of box it is on.
-- | This one holds exactly one, so the search is the containment test alone.
-- |
-- | @param state_formula  editor_formula.state_formula - checked
-- | @param pos            {x, y} | nil - a screen point
-- | @return {container, hb} | nil - nil for an empty box, one not drawn yet, or a point outside
-- |
-- | @date 2026-09-13 19:10
--]]
function editor_formula.formula_at(state_formula, pos)
    STATE_SHAPE.check(state_formula)
    if state_formula.formula and editor.point_in_box(pos, state_formula.hit) then
        return {container = state_formula.formula, hb = state_formula.hit}
    end
    return nil
end

--[[ @brief One frame of input: paste, click, drag, selection and navigation - and no edits.
-- |
-- | ONLY A PASTE CHANGES CONTENT, empty or filled. Into a filled box it REPLACES the content and
-- | drops the parent link: what is in the box no longer came from the box it pointed at, so it is
-- | a root now.
-- |
-- | AN EDIT IS DISCARDED by rebuilding from the committed text, so selection, navigation and Ctrl+C
-- | still work through mformula while the content stays a fixed step of a derivation.
-- |
-- | @param state_formula  editor_formula.state_formula - checked
-- | @param fontset        fontset
-- | @param sz             size
-- | @return boolean - true when a paste replaced the content
-- |
-- | @note from_latex never fails, so any non-empty clipboard replaces the content - unreadable text
-- |       arrives as an empty atom. Only an empty clipboard leaves the box as it was.
-- |
-- | @date 2026-09-13 19:10
--]]
function editor_formula.handle_input(state_formula, fontset, sz)
    STATE_SHAPE.check(state_formula)
    --[[ PASTE, empty box or filled. Into an empty box it is how content arrives; into a filled one it
    REPLACES the content and drops the parent link, because what is in the box no longer came from
    the box it pointed at - it is a root now (see this file's header).

    The `if built` guard below never fails today: from_latex always returns a container. ]]
    if keymap.pressed("edit.paste") then
        local latex = clipboard_latex()
        if latex then
            local built = mformula.from_latex(fontset, mexpru.DEFAULT_SIZE, latex)
            if built then
                state_formula.latex = latex
                state_formula.formula = built
                state_formula.parent = nil      -- pasted content is nobody's consequence
                return true
            end
        end
        return false
    end

    if not state_formula.formula then
        return false
    end

    -- Click and drag place the caret and select, exactly as in any other box.
    local down = vc.ImGui_IsMouseDown("ImGuiMouseButton_Left")
    if not down then
        state_formula.dragging = false
    end
    local clicked = vc.ImGui_IsMouseClicked("ImGuiMouseButton_Left", false)
    if state_formula.hit and (clicked or (down and state_formula.dragging)) then
        local mp = vc.ImGui_GetMousePos()
        local hb = state_formula.hit
        if state_formula.dragging or editor.point_in_box(mp, hb) then
            editor.formula_hit_test(state_formula.formula, fontset, sz, mp, hb.draw_x, hb.draw_y,
                    hb.wrap_edge, state_formula.dragging and not clicked)
            state_formula.dragging = true
        end
    end

    --[[ Selection, navigation and Ctrl+C work because mformula handles them. An EDIT is UNDONE by
    rebuilding from the committed text: this box is a step in a derivation and its content is not
    the user's to change in place (see this file's header). Rebuilding rather than blocking keys
    means no list of "editing keys" to fall out of date. ]]
    if editor.edit_bracket(state_formula.formula, fontset, sz) then
        state_formula.formula = mformula.from_latex(fontset, mexpru.DEFAULT_SIZE,
                state_formula.latex)
    end
    return false
end

--[[ @brief Re-lays-out the formula after a zoom.
-- |
-- | `hit` IS DROPPED rather than adjusted: it holds positions measured at the OLD size, and a click
-- | tested against them would land somewhere other than where the glyph now is. draw() rebuilds it
-- | on the next frame.
-- |
-- | @param state_formula  editor_formula.state_formula - checked
-- | @param fontset        fontset
-- |
-- | @date 2026-09-13 19:10
--]]
function editor_formula.rescale(state_formula, fontset)
    STATE_SHAPE.check(state_formula)
    if state_formula.formula then
        mformula.rescale(state_formula.formula, fontset)
    end
    state_formula.hit = nil
end

--[[ @brief The box as its saved body.
-- |
-- | A LENGTH-PREFIXED LIST, the same shape editor_definition.lua uses, so that the justification a
-- | transformed box will carry (which transform, from which source ids, under which rules - section
-- | 12) joins it without another migration of the format.
-- |
-- | @param state_formula  editor_formula.state_formula - checked
-- | @return string - "3\n" then latex, id and parent, each as "<length>\n<text>"; a missing value
-- |         is written as ""
-- |
-- | @date 2026-09-13 19:10
--]]
function editor_formula.to_text(state_formula)
    STATE_SHAPE.check(state_formula)
    local parts = {}
    local function put(v)
        v = v == nil and "" or tostring(v)
        parts[#parts + 1] = tostring(#v) .. "\n" .. v
    end
    put(state_formula.latex)
    put(state_formula.id)
    put(state_formula.parent)
    return tostring(#parts) .. "\n" .. table.concat(parts)
end

--[[ @brief Reads back what to_text() wrote, into this box.
-- |
-- | THE COUNT IS HONOURED rather than assumed, so a file written before the derivation link existed
-- | (one entry: just the formula) still loads - it simply has no id and no parent, which is what a
-- | box with no recorded lineage should be.
-- |
-- | @details An unreadable count leaves the box untouched; a truncated entry stops the read. An
-- |          empty latex keeps whatever the box held. `id` and `parent` are always overwritten -
-- |          with nil when absent or not a number.
-- |
-- | @param state_formula  editor_formula.state_formula - checked
-- | @param text           string - a saved body
-- | @param fontset        fontset - the formula is rebuilt immediately
-- |
-- | @date 2026-09-13 19:10
--]]
function editor_formula.from_text(state_formula, text, fontset)
    STATE_SHAPE.check(state_formula)
    local at = text:find("\n", 1, true)
    local count = at and tonumber(text:sub(1, at - 1))
    if not count or count < 1 then
        return
    end
    at = at + 1

    local fields = {}
    for _ = 1, count do
        local nl = text:find("\n", at, true)
        local len = nl and tonumber(text:sub(at, nl - 1))
        if not len then
            break
        end
        fields[#fields + 1] = text:sub(nl + 1, nl + len)
        at = nl + 1 + len
    end

    local latex = fields[1]
    if latex and latex ~= "" then
        state_formula.latex = latex
        state_formula.formula = mformula.from_latex(fontset, mexpru.DEFAULT_SIZE, latex)
    end
    state_formula.id = tonumber(fields[2] or "")
    state_formula.parent = tonumber(fields[3] or "")
end

return editor_formula

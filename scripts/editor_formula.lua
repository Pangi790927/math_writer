--[[ ==================================== WHAT THIS FILE OFFERS ====================================
new(id: id)                             -> state_formula
    A fresh, empty box.

draw(state_formula: editor_formula.state_formula, fontset: fontset, pos: {x,y}, sz: size,
     width_limit: number, show_cursor: boolean, show_wireframe: boolean, show_graph: boolean)
     -> height
    Draws the box and returns the height it filled, so the caller can
    lay out whatever follows without measuring it again.

formula_at(state_formula: editor_formula.state_formula, pos: {x,y}) -> {container, hb} | nil
    The formula under a screen point. This box holds exactly one, so
    the search is the containment test alone - same answer
    editor_text.formula_at gives for a box that holds many.

handle_input(state_formula: editor_formula.state_formula, fontset: fontset, sz: size) -> changed
    One frame of input. True when the box's CONTENT changed, which
    only a paste can do.

rescale(state_formula: editor_formula.state_formula, fontset: fontset) -> nothing
    Re-lays-out after a zoom.

to_text(state_formula: editor_formula.state_formula) -> text
from_text(state_formula: editor_formula.state_formula, text: string, fontset: fontset) -> ok
    The save format, length-prefixed like editor_definition's.

--- internal, not on the module table --------------------------------------------------------------
    the draw helpers and the box's own hit rectangle
@date 2026-09-12 03:20
================================================================================================= ]]

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

--[[ A fresh, empty box. `latex` is the committed content and the formula is rebuilt from it - the
string is the truth, not the tree, which is what makes discarding an edit a rebuild rather than an
undo.

`id` and `parent` are the DERIVATION LINK. Each formula box has an id of its own, and a box
produced by transforming another records that other's id - which is the proof DAG of
docs/phase2_design.md section 1 written down: a root has no parent, everything else has exactly one.

The ids live inside the box's own saved body rather than in the box header, so the document format
above this file does not have to learn about them. Nothing creates a parent yet: that happens when a
transformation emits a box, and transformations wait on the expression parser. The link is built now
so it is not retrofitted through the drawing, the format and the loader later.
@date 2026-09-08 08:06 ]]
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

--[[ Draws the box, and returns the height it filled so the caller can lay out what follows.

An EMPTY box still draws a field, so it reads as somewhere a formula can go rather than as blank
space in a coloured rectangle. Either way this records `state_formula.hit` - the rect a click must land in,
plus the origin and wrap edge it was drawn at - because handle_input() runs in a different call and
cannot re-derive any of them.

  pos             top-left of the content; the BASELINE is worked out from measure()'s own `top`
  sz              the logical size to draw at
  width_limit     how far right content may reach, as a width from pos.x
  show_cursor     this is the active box: draws the field's edge and the caret
  show_wireframe  passed through to the shared host (mexpr's debug boxes)
  show_graph      passed through: the reachable-position graph
@date 2026-09-08 08:06 ]]
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

--[[ This box's formula, as {container, hb}, when a screen point is over it. Nil otherwise.

The same answer editor_text.formula_at gives for a box that can hold many formulas - this one holds
exactly one, so the search is the containment test alone. Both exist so a gesture asking "what is
under the pointer" does not have to know which kind of box it is pointing at.
@date 2026-09-11 21:40 ]]
function editor_formula.formula_at(state_formula, pos)
    STATE_SHAPE.check(state_formula)
    if state_formula.formula and editor.point_in_box(pos, state_formula.hit) then
        return {container = state_formula.formula, hb = state_formula.hit}
    end
    return nil
end

--[[ One frame of input. Returns true when the box's CONTENT changed, which only a paste can do -
in either state_formula, and nothing else may change it at all.
@date 2026-09-08 08:06 ]]
function editor_formula.handle_input(state_formula, fontset, sz)
    STATE_SHAPE.check(state_formula)
    --[[ PASTE, in either state_formula. Into an empty box it is how content arrives; into a filled one it
    REPLACES the content and drops the parent link, because what is in the box no longer came from
    the box it pointed at - it is a root now (see this file's header).

    A paste that does not parse changes nothing at all: the old content and the old link both stay,
    rather than the box being emptied by a bad clipboard. ]]
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

--[[ Re-lays-out the formula after a zoom. `state_formula.hit` is dropped rather than adjusted: it holds
positions measured at the OLD size, and a click tested against them would land somewhere else than
where the glyph now is - draw() rebuilds it on the next frame anyway.
@date 2026-09-08 08:06 ]]
function editor_formula.rescale(state_formula, fontset)
    STATE_SHAPE.check(state_formula)
    if state_formula.formula then
        mformula.rescale(state_formula.formula, fontset)
    end
    state_formula.hit = nil
end

--[[ Saved as a length-prefixed list, the same shape editor_definition.lua uses - one entry today
(the formula), so that the justification a transformed box will carry (which transform, from which
source ids, under which rules - section 12) joins it without a second migration of the format.
@date 2026-09-08 08:06 ]]
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

--[[ Reads back what to_text() wrote. The COUNT is honoured rather than assumed, so a file written
before the derivation link existed (one entry: just the formula) still loads - it simply has no id
and no parent, which is what a box with no recorded lineage should be.
@date 2026-09-08 08:06 ]]
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

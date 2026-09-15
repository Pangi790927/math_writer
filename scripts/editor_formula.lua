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
-- | lock(state_formula: editor_formula.state_formula, fontset: fontset, decls: {decl} | nil)
-- |      -> boolean
-- |     Toggles the box's mode. Locking has one restriction: the formula
-- |     must parse into an ast, so a locked box always has a live tree to
-- |     transform. Answers whether the box is locked now.
-- |
-- | undo(state_formula: editor_formula.state_formula, fontset: fontset) -> boolean
-- | redo(state_formula: editor_formula.state_formula, fontset: fontset) -> boolean
-- |     Steps the box back to its previous committed text, and forward
-- |     again. EDIT mode only - a locked box is frozen and has nothing to
-- |     step over.
-- |
-- | handle_input(state_formula: editor_formula.state_formula, fontset: fontset, sz: size,
-- |      decls: {decl} | nil) -> changed
-- |     One frame of input. Unlocked, the formula is fully editable, the
-- |     mathbox from editor_text and nothing else, and every edit commits
-- |     back to the saved text. Locked, the content is frozen and an edit
-- |     is discarded by rebuilding from it. The paste is content.lua's to
-- |     route, not this file's.
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
-- |     ensure, push_undo, restore, STATE_FIELDS, STATE_SHAPE, and the field's padding and colours
-- |
-- | @date 2026-09-15 12:00
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

SINCE 2026-09-15 the FILLED state has TWO MODES, toggled by the lock button in the box's chrome
row (content.lua draws it, leftmost of the graph/wireframe/close buttons, as a small red
padlock), and locking carries the one restriction the author set: the mexpr tree must parse
into an ast, so a transformable box always has a live tree under it.

  EDIT        unlocked. The formula is a mathbox - the editor_text component and nothing else - so
              it is typed and edited right here, and every edit commits to the saved text.
  TRANSFORM   locked. The content is frozen and the box is a cell: right-click gestures offer
              transformations, and applying one derives a linked child box holding the result,
              which becomes the active one. Deleting the last box in the chain is the ctrl+z path -
              later, cheap.

A PASTE IS A CELL TRANSACTION, content.lua's to run (2026-09-15): verified against the ast,
enabled only where trust survives it - into an empty box, where content is arriving, or into a
locked one, whose lock a verified paste lets it keep. The paste drops ALL chains: the parent link
breaks and the children go, because a pasted formula is not a derivation ("a just copied in
function is not a derivation", the author) - trusted is not the same claim as proven.

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
local mexpr_ast = require("mexpr_ast")
local mformula_latex = require("mformula_latex")

local editor_formula = {}

local FIELD_PAD = 3
local SLOT_BG_COLOR   = 0x22ffffff
local SLOT_EDGE_COLOR = 0x66ffffff

--[[ THE `state_formula` CONTAINER for a formula box. Declared through sealed.lua; see that file
for the rule. `formula` is built lazily by ensure() below, which is why it and `latex` are both
here and either may be nil.
@date 2026-09-12 06:05 ]]
local STATE_FIELDS = {
    id       = "the box's id, as content.lua assigns it",
    parent   = "the box this one was derived from, or nil",
    latex    = "the committed text; the source of truth when `formula` has not been built yet",
    formula  = "the live mformula container, built from `latex` on first use",
    hit      = "the click box the last draw left behind",
    dragging = "true while a click-drag selection is in progress",
    locked   = "true in TRANSFORM mode: content frozen, gestures live. nil is EDIT mode",
    undo_stack = "the committed text before each change, oldest first; EDIT mode's Ctrl+Z",
    redo_stack = "what undo stepped back over, for Ctrl+Shift+Z",
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
    return STATE_SHAPE.wrap{latex = nil, formula = nil, id = id, parent = nil,
            undo_stack = {}, redo_stack = {}}
end

--[[ Snapshots the committed text as it stands, before a change overwrites it. A new change also
discards the redo side - the usual discipline, so redo only ever replays what undo stepped over.
An absent latex is stored as "", so the array never grows a hole. ]]
local function push_undo(state_formula)
    local stack = state_formula.undo_stack or {}
    stack[#stack + 1] = state_formula.latex or ""
    state_formula.undo_stack = stack
    state_formula.redo_stack = {}
end

--[[ Steps one snapshot back into the box: the current text goes onto `to`, the snapshot becomes
the committed text, and the formula is rebuilt from it. An empty snapshot restores an empty box. ]]
local function restore(state_formula, fontset, from, to)
    local latex = from[#from]
    if latex == nil then
        return false
    end
    from[#from] = nil
    to[#to + 1] = state_formula.latex or ""
    state_formula.latex = (latex ~= "") and latex or nil
    state_formula.formula = state_formula.latex
            and mformula.from_latex(fontset, mexpru.DEFAULT_SIZE, state_formula.latex)
            or nil
    return true
end

--[[ @brief Steps the box back to its previous committed text (Ctrl+Z).
-- |
-- | EDIT MODE ONLY (the author, 2026-09-15: "you should have ctrl+z working when in edit mode"):
-- | a locked box is frozen and has nothing to undo. The stack is one snapshot per CHANGE - an
-- | edit's commit, a paste - never per frame, the same discipline editor_definition's undo uses.
-- |
-- | @param state_formula  editor_formula.state_formula - checked
-- | @param fontset        fontset - the formula is rebuilt on restore
-- | @return boolean - whether anything was restored
-- |
-- | @date 2026-09-15 13:00
--]]
function editor_formula.undo(state_formula, fontset)
    STATE_SHAPE.check(state_formula)
    return restore(state_formula, fontset, state_formula.undo_stack or {},
            state_formula.redo_stack or {})
end

--[[ @brief Steps forward again over an undo (Ctrl+Shift+Z), with the same shape as undo itself.
-- |
-- | @param state_formula  editor_formula.state_formula - checked
-- | @param fontset        fontset
-- | @return boolean - whether anything was restored
-- |
-- | @date 2026-09-15 13:00
--]]
function editor_formula.redo(state_formula, fontset)
    STATE_SHAPE.check(state_formula)
    return restore(state_formula, fontset, state_formula.redo_stack or {},
            state_formula.undo_stack or {})
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

--[[ @brief Toggles the box's mode: EDIT, or TRANSFORM.
-- |
-- | LOCKING HAS ONE RESTRICTION, the author's (2026-09-15): the mexpr tree must parse into an
-- | ast - "you are not allowed to lock in a mexpr tree that can't be parsed into an ast". A box
-- | being transformed always has a live tree underneath, so the gesture layer never meets a
-- | formula it cannot resolve. An unparseable tree simply stays unlocked.
-- |
-- | UNLOCKING returns the box to a mathbox AND TO ROOT: the parent goes here and the children go
-- | with the caller's prune (content.lua's lock button), because an untrusted node can claim a
-- | lineage in neither direction. Found live 2026-09-15: the parent survived the unlock, leaving
-- | a dirty box still claiming to follow from a trusted one.
-- |
-- | @param state_formula  editor_formula.state_formula - checked; builds the formula if missing
-- | @param fontset        fontset
-- | @param decls          {mexpr_ast.decl} | nil - what the document declares above this box;
-- |                       nil parses with the built-ins alone
-- | @return boolean - whether the box is locked after the call
-- |
-- | @date 2026-09-15 14:15
--]]
function editor_formula.lock(state_formula, fontset, decls)
    STATE_SHAPE.check(state_formula)
    if state_formula.locked then
        state_formula.locked = nil
        state_formula.parent = nil
        return false
    end
    local formula = ensure(state_formula, fontset)
    if not formula then
        return false
    end
    local ok = mexpr_ast.build(fontset, formula, decls or {})
    if not ok then
        return false
    end
    state_formula.locked = true
    return true
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
    --[[ A LOCKED CELL DROPS ITS BACKGROUND (the author, 2026-09-15): only the contour remains, so
    locked cells read at a glance across the page - a filled field is a mathbox being worked in, a
    bare outline is a frozen step of a derivation. The contour stays up whenever locked, not just
    on the active box, because being a cell is a standing fact rather than focus. ]]
    if not state_formula.locked then
        vc.ImGui_AddRectFilled({x = pos.x - pad, y = baseline + m.top - pad},
                {x = pos.x + math.max(m.width, 6) + pad, y = baseline + m.bottom + pad},
                SLOT_BG_COLOR, 3)
    end
    if show_cursor or state_formula.locked then
        vc.ImGui_AddRect({x = pos.x - pad, y = baseline + m.top - pad},
                {x = pos.x + math.max(m.width, 6) + pad, y = baseline + m.bottom + pad},
                SLOT_EDGE_COLOR, 3, 1)
    end

    --[[ THE LOCK BUTTON IS NOT DRAWN HERE: it lives in content.lua's chrome row, leftmost of the
    graph/wireframe/close buttons over the box's top-right corner, and its click is routed there
    too - only content knows the document's declarations for the lock's parse check, and locking
    prunes the box's children, which is content's to do. This file supplies the toggle itself
    (lock() below) and the mode flag the button reads. ]]

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

--[[ @brief One frame of input, in whichever mode the box is in.
-- |
-- | EDIT (unlocked): the formula is a mathbox - the editor_text component and nothing else - so
-- | typing, brackets, accents and the rest all work, and every edit commits back to the saved
-- | text as it happens.
-- |
-- | TRANSFORM (locked): the content is frozen. An edit is discarded by rebuilding from the
-- | committed text - selection, navigation and Ctrl+C still work through mformula, because the
-- | gesture layer needs the pointer in the tree.
-- |
-- | @param state_formula  editor_formula.state_formula - checked
-- | @param fontset        fontset
-- | @param sz             size
-- | @param decls          {mexpr_ast.decl} | nil - reserved for this file's future needs; the
-- |                       paste verification moved to content.lua with the paste itself
-- | @return boolean - true when what the box WAS is gone and its descendants should be pruned.
-- |                  With the paste gone to content.lua, nothing here answers true today; the
-- |                  contract stays, because the caller's prune is the right response to
-- |                  whoever earns it next
-- |
-- | @note from_latex never fails, so any non-empty clipboard replaces the content - unreadable text
-- |       arrives as an empty atom. Only an empty clipboard leaves the box as it was.
-- |
-- | @date 2026-09-15 12:00
--]]
function editor_formula.handle_input(state_formula, fontset, sz, decls)
    STATE_SHAPE.check(state_formula)

    --[[ UNDO AND REDO live in EDIT mode only: a locked box is frozen and has nothing to step
    back. They come before the paste and the editing so a held key cannot also edit the frame it
    restores. ]]
    if not state_formula.locked then
        if keymap.pressed("edit.undo") then
            editor_formula.undo(state_formula, fontset)
            return false
        end
        if keymap.pressed("edit.redo") then
            editor_formula.redo(state_formula, fontset)
            return false
        end
    end

    --[[ THE PASTE IS NOT THIS FILE'S (2026-09-15): it is a cell-level transaction - verified
    against the ast, enabled only where trust survives it (empty box, or a locked one), and it
    swaps the box out of its derivation chain, keeping the previous shape in it. content.lua owns
    all of that (paste_into_formula's own comment); an unlocked filled box simply has no paste. ]]

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

    if state_formula.locked then
        --[[ TRANSFORM: an edit is UNDONE by rebuilding from the committed text - the box is a step
        in a derivation while locked, and its content is not the user's to change in place.
        Rebuilding rather than blocking keys means no list of "editing keys" to fall out of date. ]]
        if editor.edit_bracket(state_formula.formula, fontset, sz) then
            state_formula.formula = mformula.from_latex(fontset, mexpru.DEFAULT_SIZE,
                    state_formula.latex)
        end
        return false
    end

    --[[ EDIT: the mathbox from editor_text, whole. An edit commits back to the saved text as it
    happens, so the box's truth never drifts from its tree - and what the text was a moment
    before rides the undo stack. The return stays FALSE: content.lua reads true as "content
    replaced, prune what was derived from it" (the paste contract), and an ordinary edit is not
    that - the commit above is all it needs. ]]
    if editor.edit_bracket(state_formula.formula, fontset, sz) then
        push_undo(state_formula)
        state_formula.latex = mformula_latex.to_latex(state_formula.formula)
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
    put(state_formula.locked and "1" or "")
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
    state_formula.locked = (fields[4] == "1") or nil
end

return editor_formula

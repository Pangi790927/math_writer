--[[ @file tests/lua/test_term_selectors_drag.lua
-- | @brief Checks the term selectors in the document: the toggle above a locked box, the per-box
-- |        flag it flips and which new boxes start with it on, and the drag - the press, the
-- |        travel that arms it, and the release that commits a reorder, does nothing, or is
-- |        refused - driven frame by frame through content.handle_input and content.draw with
-- |        ImGui stubbed.
-- |
-- | THE STUBS CHECK EVERY DRAW CALL'S ARITY AND TYPES against the signatures imgui_composer.h
-- | binds. A wrong-arity call passes a plain no-op stub and then throws live, taking the layout,
-- | the rail and every click with it - the AddRect that shipped that way (test_formula_lock).
-- |
-- | THE TRANSFORMATION IS THE CONTRACT'S. The routing cases stub transforms.apply and check the
-- | option it is handed - id "reorder", params {term, before} - and the last cases run the reorder
-- | and distribute plugins themselves, when the folder scan found them, end to end, including a
-- | result the writer cannot draw faithfully, which must make no box.
-- |
-- | @date 19-10-2026-22:30
--]]

package.path = package.path .. ";./scripts/?.lua"

local char = require("char")
local vc = require("virt_composer")
local mexpru = require("mexpru")
local mformula = require("mformula_new")
local mformula_latex = require("mformula_latex")
local keymap = require("keymap")
local transforms = require("transforms")
local ast_gestures = require("ast_gestures")
local editor_formula = require("editor_formula")
local input_recorder = require("input_recorder")
local content = require("content")

local SKETCH = "(abc+ab^{2})d+ac+2\\pi"
local POS = {x = 20, y = 30}

local checks_run, checks_failed = 0, 0
local function check(name, cond, got)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name .. (got ~= nil and ("  (got: " .. tostring(got) .. ")") or ""))
    end
end

-- ------------------------------------------------------------------ the stubbed frame
--[[ @brief Holds the Lua signature of every draw call the document makes, as imgui_composer.h
-- |        binds it: `vec` a {x, y}, `num` a float, `col` an integral colour, `str` a text.
-- |        @date 19-10-2026-20:55
--]]
local SIGNATURES = {
    ImGui_AddLine         = {"vec", "vec", "col", "num"},
    ImGui_AddRect         = {"vec", "vec", "col", "num", "num"},
    ImGui_AddRectFilled   = {"vec", "vec", "col", "num"},
    ImGui_AddCircle       = {"vec", "num", "col", "num"},
    ImGui_AddCircleFilled = {"vec", "num", "col"},
    ImGui_AddArc          = {"vec", "num", "col", "num", "num", "num"},
    ImGui_AddQuadFilled   = {"vec", "vec", "vec", "vec", "col"},
    ImGui_AddText         = {"vec", "col", "str"},
}
local KIND = {
    vec = function(v) return type(v) == "table" and type(v.x) == "number"
            and type(v.y) == "number" end,
    num = function(v) return type(v) == "number" end,
    col = function(v) return type(v) == "number" and math.floor(v) == v end,
    str = function(v) return type(v) == "string" end,
}

local bad_calls, mouse, pressed, logged = {}, {x = 0, y = 0}, {}, {}
local formula_inputs, applied, drawn = 0, {}, {}

--[[ @brief Replaces every ImGui binding the document reaches, the keymap's queries, the formula
-- |        box's own input, the recorder and the C++ draw with stubs that record what they see;
-- |        each draw call lands in `drawn` as {name, args}. @date 19-10-2026-20:55
--]]
local function stub_everything()
    for name, kinds in pairs(SIGNATURES) do
        vc[name] = function(...)
            local args, ok = {...}, select("#", ...) == #kinds
            for i, kind in ipairs(kinds) do
                ok = ok and KIND[kind](args[i])
            end
            if not ok then
                bad_calls[#bad_calls + 1] = name .. " with " .. select("#", ...) .. " arguments"
            end
            drawn[#drawn + 1] = {name = name, args = args}
        end
    end
    local function button(btn)
        if btn ~= "ImGuiMouseButton_Left" then
            bad_calls[#bad_calls + 1] = "a mouse query for " .. tostring(btn)
        end
    end
    vc.ImGui_GetMousePos = function() return {x = mouse.x, y = mouse.y} end
    vc.ImGui_IsMouseDown = function(btn) button(btn) return mouse.down == true end
    vc.ImGui_IsMouseClicked = function(btn, rep)
        button(btn)
        return mouse.clicked == true and rep == false
    end
    vc.ImGui_IsMouseReleased = function(btn) button(btn) return false end
    vc.ImGui_GetMouseWheel = function() return 0 end
    vc.ImGui_GetDisplaySize = function() return {x = 1920, y = 1080} end
    vc.ImGui_CalcTextSize = function() return {x = 40, y = 16} end
    vc.ImGui_input_queue_chars = function() return {} end
    vc.mexpr_draw = function() return 24 end

    local known = {}
    keymap.each(function(id) known[id] = true end)
    keymap.pressed = function(id)
        if not known[id] then
            bad_calls[#bad_calls + 1] = "an unknown action " .. tostring(id)
        end
        return pressed[id] == true
    end
    keymap.mods = function() return false, false, false end
    keymap.fired = function() return {} end
    editor_formula.handle_input = function()
        formula_inputs = formula_inputs + 1
        return false
    end
    input_recorder.log_event = function(msg) logged[#logged + 1] = msg end
end

local function frame(doc, fs)
    drawn = {}
    content.handle_input(doc, fs, POS)
    content.draw(doc, fs, POS, nil)
    mouse.clicked = false
end

local function press(doc, fs, p)
    mouse.x, mouse.y, mouse.down, mouse.clicked = p.x, p.y, true, true
    frame(doc, fs)
end

local function move(doc, fs, p)
    mouse.x, mouse.y = p.x, p.y
    frame(doc, fs)
end

local function release(doc, fs)
    mouse.down = false
    frame(doc, fs)
end

--[[ @brief Presses at `from`, travels to `to` over two frames and releases there.
-- |        @date 19-10-2026-20:55
--]]
local function drag(doc, fs, from, to)
    press(doc, fs, from)
    move(doc, fs, {x = (from.x + to.x) / 2, y = (from.y + to.y) / 2})
    move(doc, fs, to)
    release(doc, fs)
end

-- ------------------------------------------------------------------ documents
local function formula_box(doc, fs, index, latex, locked)
    content.insert_box(doc, index, "formula")
    local fml = doc.boxes[index].fml
    fml.latex = latex
    fml.formula = mformula_latex.from_latex(fs, mexpru.DEFAULT_SIZE, latex)
    if locked then
        fml.locked = true
        ast_gestures.ast_for(fs, fml.formula, {})
    end
    return fml
end

--[[ @brief Builds the sketch's document - the empty text box every document starts with, then
-- |        the sketch locked with its selectors on - nothing active, and draws it once.
-- |        @date 19-10-2026-20:55
--]]
local function sketch_doc(fs)
    local doc = content.new()
    local fml = formula_box(doc, fs, 2, SKETCH, true)
    fml.selectors = true
    doc.active_index = nil
    frame(doc, fs)
    return doc, fml
end

--[[ @brief Finds a selector of the box on screen: the `index`-th term of the sum with `n` terms,
-- |        and the screen point of its ring. @date 19-10-2026-20:55
--]]
local function selector(fml, n, index)
    local rec = fml.selector_hit
    for _, sum in ipairs(rec and rec.geom.sums or {}) do
        if #sum.terms == n then
            local sel = sum.terms[index]
            return {x = rec.x + sel.ring.x, y = rec.y + sel.ring.y}, sel, sum, rec
        end
    end
end

local function center(r)
    return {x = r.x + r.w / 2, y = r.y + r.h / 2}
end

--[[ @brief Finds the screen point at the middle of the first glyph of `fml`'s root row whose
-- |        catalog desc is `desc`, where the last frame drew it - node_bbox's frame shifted by
-- |        the draw origin and the baseline correction, the conversion a click goes through
-- |        backwards. @date 19-10-2026-22:30
--]]
local function glyph_point(doc, fs, fml, desc)
    local bc = mformula.baseline_correction(fs, doc.font_size)
    for _, kid in ipairs(mexpru.u(fml.formula.root).children) do
        local entry = kid.type == vc.MEXPR_TYPE_SYMBOL and char.find_by_ncod(kid.symb.code)
        if entry and entry.desc == desc then
            local bb = mformula.node_bbox(fs, kid)
            return {x = fml.hit.draw_x + (bb.left + bb.right) / 2,
                    y = fml.hit.draw_y + bc + (bb.top + bb.bottom) / 2}
        end
    end
end

--[[ @brief Right-clicks the glyph `desc` of `fml` and clicks the first row of the menu that
-- |        opens; answers the menu, or nil when none opened. @date 19-10-2026-22:30
--]]
local function menu_pick(doc, fs, fml, desc)
    move(doc, fs, glyph_point(doc, fs, fml, desc))
    pressed["math.transform_menu"] = true
    frame(doc, fs)
    pressed["math.transform_menu"] = nil
    local menu = doc.transform_menu
    if menu then
        press(doc, fs, {x = menu.x + 4, y = menu.y + 1})
        release(doc, fs)
    end
    return menu
end

local function logged_with(text)
    for _, line in ipairs(logged) do
        if line:find(text, 1, true) then
            return true
        end
    end
    return false
end

--[[ @brief Counts the last frame's draw calls of `name` in colour `col` starting at `at`: the
-- |        point is a call's first argument and the colour its third, for a circle and a line
-- |        alike. @date 19-10-2026-20:55
--]]
local function count_drawn(name, col, at)
    local n = 0
    for _, call in ipairs(drawn) do
        local p = call.args[1]
        if call.name == name and call.args[3] == col and math.abs(p.x - at.x) < 0.01
                and math.abs(p.y - at.y) < 0.01 then
            n = n + 1
        end
    end
    return n
end

--[[ @brief Counts the last frame's vertical lines in colour `col` - the shape of a drop's marker.
-- |        @date 19-10-2026-20:55
--]]
local function count_markers(col)
    local n = 0
    for _, call in ipairs(drawn) do
        local a, b = call.args[1], call.args[2]
        if call.name == "ImGui_AddLine" and call.args[3] == col and math.abs(a.x - b.x) < 0.01
                and b.y > a.y then
            n = n + 1
        end
    end
    return n
end

-- ------------------------------------------------------------------ the toggle
local function the_toggle(fs)
    local doc = content.new()
    local a = formula_box(doc, fs, 2, SKETCH, true)
    formula_box(doc, fs, 3, "a+b", false)
    local b = formula_box(doc, fs, 4, "x+y", true)
    doc.active_index = nil
    frame(doc, fs)
    local L = doc.last_layout
    check("a locked formula box carries the selectors' toggle", L[2].selectors_btn ~= nil)
    check("...an unlocked one does not", L[3].selectors_btn == nil)
    check("...nor a text box", L[1].selectors_btn == nil)
    check("...and it sits left of the bounds star", L[2].selectors_btn
            and L[2].selectors_btn.x + L[2].selectors_btn.w < L[2].bounds_btn.x)
    check("the flag starts off", not a.selectors and not b.selectors)
    local closed_h, saved = L[2].h, editor_formula.to_text(a)

    press(doc, fs, center(L[2].selectors_btn))
    release(doc, fs)
    check("a click turns that box's selectors on", a.selectors == true)
    check("...and no other box's", not b.selectors)
    check("...without making it the active box", doc.active_index == nil)
    check("the box draws its selectors", a.selector_hit ~= nil and b.selector_hit == nil)
    check("...and grows to hold them", doc.last_layout[2].h > closed_h,
            doc.last_layout[2].h .. " / " .. closed_h)
    check("the flag is not saved", editor_formula.to_text(a) == saved)
    local back = editor_formula.new()
    editor_formula.from_text(back, editor_formula.to_text(a), fs)
    check("...so a reloaded box starts with it off", not back.selectors)

    press(doc, fs, center(doc.last_layout[2].selectors_btn))
    release(doc, fs)
    check("a second click turns it off", a.selectors == false)
    check("...and the selectors go", a.selector_hit == nil)
end

-- ------------------------------------------------------------------ what lights up
--[[ @brief Checks that only a selector lights: the one under the pointer, or the held one through
-- |        a drag, whose ghost follows the pointer while a marker stands on its gap.
-- |
-- | The lit and ghost colours are term_selectors' white and translucent white; the page draws no
-- | other filled circle in either at a selector's ring.
-- |
-- | @date 19-10-2026-20:55
--]]
local function the_lighting(fs)
    local LIT, GHOST = 0xffffffff, 0x88ffffff
    local doc, fml = sketch_doc(fs)
    local at, _, _, rec = selector(fml, 3, 3)
    local function lit_rings()
        local n = 0
        for _, sel in ipairs(fml.selector_hit.geom.selectors) do
            n = n + count_drawn("ImGui_AddCircleFilled", LIT,
                    {x = rec.x + sel.ring.x, y = rec.y + sel.ring.y})
        end
        return n
    end
    move(doc, fs, at)
    check("the selector under the pointer lights up",
            count_drawn("ImGui_AddCircleFilled", LIT, at) == 1)
    check("...and it alone", lit_rings() == 1, lit_rings())
    move(doc, fs, {x = at.x, y = at.y + 300})
    check("away from them, none is lit", lit_rings() == 0, lit_rings())

    local to = {x = rec.x - 2, y = at.y}
    press(doc, fs, at)
    move(doc, fs, to)
    check("the held selector stays lit", count_drawn("ImGui_AddCircleFilled", LIT, at) == 1)
    check("...a ghost of it follows the pointer",
            count_drawn("ImGui_AddCircleFilled", GHOST, to) == 1)
    check("...and a marker stands on the gap", count_markers(LIT) == 1, count_markers(LIT))
    local ac = selector(fml, 3, 2)
    move(doc, fs, ac)
    check("passing over another selector does not light it",
            count_drawn("ImGui_AddCircleFilled", LIT, ac) == 0 and lit_rings() == 1)
    pressed["radial.cancel"] = true
    frame(doc, fs)
    pressed["radial.cancel"] = nil
    release(doc, fs)
    check("...and nothing was committed on the way", #doc.boxes == 2, #doc.boxes)
end

-- ------------------------------------------------------------------ the press and the click
local function the_press(fs)
    local doc, fml = sketch_doc(fs)
    local kids = mexpru.u(fml.formula.root).children
    doc.active_index = 2
    fml.formula.cursor_pos = vc.wref_mexpr(kids[3])
    fml.formula.sel_anchor = vc.wref_mexpr(kids[1])
    frame(doc, fs)
    local inputs, boxes, logs = formula_inputs, #doc.boxes, #logged

    local at = selector(fml, 3, 3)
    press(doc, fs, at)
    check("a press on a selector holds its term", doc.term_drag ~= nil)
    check("...and the formula's own input never sees it", formula_inputs == inputs,
            formula_inputs - inputs)
    release(doc, fs)
    check("a release without travel lets go", doc.term_drag == nil)
    check("...and that click did nothing", #doc.boxes == boxes and #logged == logs)
    check("...the formula's input saw neither frame", formula_inputs == inputs)
    check("the caret stayed where it was",
            mexpru.same(fml.formula.cursor_pos:get_obj(), kids[3]))
    check("...and the selection too", fml.formula.sel_anchor ~= nil
            and mexpru.same(fml.formula.sel_anchor:get_obj(), kids[1]))
    check("...and the active box", doc.active_index == 2)

    local idle = sketch_doc(fs)
    local p = selector(idle.boxes[2].fml, 3, 1)
    press(idle, fs, p)
    release(idle, fs)
    check("a press on an inactive box's selector does not activate it",
            idle.active_index == nil)
end

-- ------------------------------------------------------------------ the drop
local function the_commit(fs)
    local doc, fml = sketch_doc(fs)
    local real_apply = transforms.apply
    applied = {}
    transforms.apply = function(id, ns, root, params)
        applied[#applied + 1] = {id = id, term = params.term, before = params.before}
        return root
    end
    local at, pi, sum, rec = selector(fml, 3, 3)
    local first = sum.terms[1]
    drag(doc, fs, at, {x = rec.x - 2, y = at.y})
    transforms.apply = real_apply

    check("a drop before the first term runs one transformation", #applied == 1, #applied)
    if applied[1] then
        check("...the reorder", applied[1].id == "reorder", applied[1].id)
        check("...moving the dragged term", applied[1].term == pi.term)
        check("...in front of the first", applied[1].before == first.term)
    end
    check("...and lands a new box below its source", #doc.boxes == 3, #doc.boxes)
    local child = doc.boxes[3] and doc.boxes[3].fml
    check("...a locked one", child ~= nil and child.locked == true)
    check("...derived from the source", child ~= nil and child.parent == fml.id)
    check("...showing its selectors, as the box a drag creates does",
            child ~= nil and child.selectors == true)
    check("...and focus moves there", doc.active_index == 3)
    check("...while a stack that still fits the view does not scroll", doc.scroll_y == 0,
            doc.scroll_y)
    check("the drag is over", doc.term_drag == nil)
    frame(doc, fs)
    check("the child draws its own selectors", child ~= nil and child.selector_hit ~= nil)
end

-- ------------------------------------------------------------------ the camera
--[[ @brief Checks that a transformation's new box stands on screen where its source stood, for a
-- |        drop and for a menu pick: the view scrolls down by the source's height and one gap (the
-- |        author, 19-10-2026: "the camera shuld scroll down the same distance such that it
-- |        focuses the newly created one").
-- |
-- | A 200 px display makes each stack taller than the view, and two boxes below the source give
-- | the scroll room to go.
-- |
-- | @date 19-10-2026-22:51
--]]
local function the_camera(fs)
    local real_size, real_apply = vc.ImGui_GetDisplaySize, transforms.apply
    vc.ImGui_GetDisplaySize = function() return {x = 1920, y = 200} end
    local function tall_doc(latex)
        local doc = content.new()
        local fml = formula_box(doc, fs, 2, latex, true)
        fml.selectors = true
        formula_box(doc, fs, 3, "a+b", true)
        formula_box(doc, fs, 4, "x+y", true)
        doc.active_index = nil
        frame(doc, fs)
        return doc, fml, doc.last_layout[2].y
    end

    transforms.apply = function(id, ns, root, params) return root end
    local doc, fml, source_y = tall_doc(SKETCH)
    local at, _, _, rec = selector(fml, 3, 3)
    drag(doc, fs, at, {x = rec.x - 2, y = at.y})
    transforms.apply = real_apply
    local child = doc.last_layout[3]
    check("a drop's new box stands where its source stood", #doc.boxes == 5 and child ~= nil
            and math.abs(child.y - source_y) < 0.5, child and (child.y .. " / " .. source_y))
    check("...because the view scrolled down", doc.scroll_y > 0, doc.scroll_y)

    doc, fml, source_y = tall_doc("a(b+c)")
    menu_pick(doc, fs, fml, "+")
    child = doc.last_layout[3]
    check("a menu pick's new box stands where its source stood", #doc.boxes == 5
            and child ~= nil and math.abs(child.y - source_y) < 0.5,
            child and (child.y .. " / " .. source_y))
    vc.ImGui_GetDisplaySize = real_size
end

local function the_misses(fs)
    local real_apply = transforms.apply
    applied = {}
    transforms.apply = function(id, ns, root, params)
        applied[#applied + 1] = {id = id}
        return root
    end

    local doc, fml = sketch_doc(fs)
    local at, pi = selector(fml, 3, 3)
    local logs = #logged
    drag(doc, fs, at, {x = at.x + pi.segments[1].x1 - pi.ring.x + 4, y = at.y})
    check("a drop that changes nothing makes no box", #doc.boxes == 2, #doc.boxes)
    check("...runs nothing", #applied == 0)
    check("...and says nothing", #logged == logs, logged[#logged])

    press(doc, fs, at)
    move(doc, fs, {x = at.x - 60, y = at.y})
    pressed["radial.cancel"] = true
    frame(doc, fs)
    pressed["radial.cancel"] = nil
    check("Escape lets go of the term", doc.term_drag == nil)
    release(doc, fs)
    check("...and the release after it does nothing", #doc.boxes == 2 and #applied == 0)

    drag(doc, fs, at, {x = at.x, y = at.y + 400})
    check("a drop outside the formula makes no box", #doc.boxes == 2 and #applied == 0)
    check("...and is refused in the recorder",
            logged_with("reorder: refused - the drop is outside the formula"), logged[#logged])

    local inner_at = selector(fml, 2, 2)
    local d_x = at.x - 70
    drag(doc, fs, inner_at, {x = d_x, y = inner_at.y})
    check("a drop out of the brackets is refused",
            logged_with("reorder: refused - the drop is outside the term's own sum"),
            logged[#logged])

    press(doc, fs, at)
    move(doc, fs, {x = at.x - 60, y = at.y})
    fml.formula.version = (fml.formula.version or 0) + 1
    frame(doc, fs)
    check("a tree changing under the drag lets go", doc.term_drag == nil)
    check("...and says why", logged_with("reorder: cancelled - the formula changed"))
    release(doc, fs)
    check("...committing nothing", #doc.boxes == 2 and #applied == 0)
    transforms.apply = real_apply
end

-- ------------------------------------------------------------------ end to end
--[[ @brief Drags 2\pi to the front with the real reorder plugin, when the folder scan found one,
-- |        and checks the child box's latex against the writer's form of the reordered sum.
-- |        @date 19-10-2026-20:55
--]]
local function end_to_end(fs)
    if not transforms.get("reorder") then
        print("NOTE: no reorder plugin registered - the end-to-end case did not run")
        return
    end
    local doc, fml = sketch_doc(fs)
    local at, _, _, rec = selector(fml, 3, 3)
    drag(doc, fs, at, {x = rec.x - 2, y = at.y})
    local child = doc.boxes[3] and doc.boxes[3].fml
    check("the real reorder lands a child box", child ~= nil, logged[#logged])
    if child then
        local want = mformula_latex.to_latex(mformula_latex.from_latex(fs, mexpru.DEFAULT_SIZE,
                "2\\pi+(abc+ab^{2})d+ac"))
        print("end to end: " .. tostring(child.latex))
        check("...holding 2\\pi + (abc+ab^2)d + ac", child.latex == want,
                tostring(child.latex) .. " / want " .. tostring(want))
    end
end

--[[ @brief Drags y before x in \sin(x+y)+1 with the real reorder plugin. The writer spells the
-- |        call's name as letters, which read back as a product, so the drop must make no box
-- |        and say why.
-- |
-- | The inner sum is told from the outer one by its line: of two sums the deeper one's line sits
-- | nearer the glyphs (the author, 19-10-2026: "level when on the same level").
-- |
-- | @date 19-10-2026-22:30
--]]
local function the_unfaithful_drop(fs)
    if not transforms.get("reorder") then
        print("NOTE: no reorder plugin registered - the unfaithful drop case did not run")
        return
    end
    local doc = content.new()
    local fml = formula_box(doc, fs, 2, "\\sin(x+y)+1", true)
    fml.selectors = true
    doc.active_index = nil
    frame(doc, fs)
    local rec, inner = fml.selector_hit, nil
    for _, sum in ipairs(rec and rec.geom.sums or {}) do
        if #sum.terms == 2 and (not inner or sum.terms[1].ring.y < inner.terms[1].ring.y) then
            inner = sum
        end
    end
    check("setup: \\sin(x+y)+1 shows the selectors of x+y", inner ~= nil)
    if not inner then
        return
    end
    local x_sel, y_sel = inner.terms[1], inner.terms[2]
    local at = {x = rec.x + y_sel.ring.x, y = rec.y + y_sel.ring.y}
    drag(doc, fs, at, {x = rec.x + x_sel.segments[1].x0, y = at.y})
    check("a drop whose result cannot be drawn faithfully makes no box", #doc.boxes == 2,
            #doc.boxes)
    check("...and says why in the recorder",
            logged_with("transform: reorder cannot be drawn yet: the drawing reads back as"),
            logged[#logged])
end

--[[ @brief Picks distribute from the right-click menu on the + of a(b+c), which lands its box with
-- |        the selectors off although its source shows them - only a drag's box starts with them
-- |        on - and picks it on x(\sin(y)+1), whose result the writer cannot draw faithfully: no
-- |        box, the reason in the recorder, and F6 opened on the pick instead.
-- |        @date 19-10-2026-22:30
--]]
local function the_menu_pick(fs)
    local doc = content.new()
    local fml = formula_box(doc, fs, 2, "a(b+c)", true)
    fml.selectors = true
    doc.active_index = nil
    frame(doc, fs)
    local menu = menu_pick(doc, fs, fml, "+")
    local first = menu and menu.options[1]
    check("a right-click on the + of a(b+c) offers distribute first",
            first ~= nil and first.id == "distribute", first and first.id)
    local child = doc.boxes[3] and doc.boxes[3].fml
    check("the pick lands a locked box derived from its source",
            child ~= nil and child.locked == true and child.parent == fml.id, #doc.boxes)
    local want = mformula_latex.to_latex(mformula_latex.from_latex(fs, mexpru.DEFAULT_SIZE,
            "ab+ac"))
    check("...holding ab+ac", child ~= nil and child.latex == want,
            child and (tostring(child.latex) .. " / want " .. want))
    check("...with its selectors off, though its source shows them",
            child ~= nil and not child.selectors)

    local bad = content.new()
    local src = formula_box(bad, fs, 2, "x(\\sin(y)+1)", true)
    bad.active_index = nil
    frame(bad, fs)
    menu = menu_pick(bad, fs, src, "+")
    first = menu and menu.options[1]
    check("a right-click on the + of x(\\sin(y)+1) offers distribute first",
            first ~= nil and first.id == "distribute", first and first.id)
    check("a pick whose result cannot be drawn faithfully makes no box", #bad.boxes == 2,
            #bad.boxes)
    check("...says why in the recorder",
            logged_with("transform: distribute cannot be drawn yet: the drawing reads back as"),
            logged[#logged])
    check("...and opens F6 on the pick", bad.show_ast_result == true)
end

function run_test()
    local fs = char.load_font_set()
    stub_everything()
    the_toggle(fs)
    the_lighting(fs)
    the_press(fs)
    the_commit(fs)
    the_camera(fs)
    the_misses(fs)
    end_to_end(fs)
    the_unfaithful_drop(fs)
    the_menu_pick(fs)
    check("every draw and mouse call matched its binding", #bad_calls == 0,
            table.concat(bad_calls, "; "))
    if checks_failed == 0 then
        print("PASS: the selectors' toggle and drag route as specified (" .. checks_run
                .. " checks)")
    end
    return checks_failed == 0
end

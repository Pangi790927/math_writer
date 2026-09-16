--[[
test_content_draw.lua - the document's draw, run once with no window.

WHY THIS FILE EXISTS: the draw path was the one corridor no test could enter - "nothing runs the
draw path" is this project's own standing caveat, and it shipped a broken app twice in one day
(2026-09-16): first an arc export the old binary lacked, then a chrome button that wrote
`layout[i].bounds_btn` before `layout[i]` existed - every frame's draw threw from the first box
onward, the document never laid out, and the report from the outside was only "I can't scroll".

WHAT THE HARNESS CAN HONESTLY DO: no ImGui composer is registered (the harness cpp registers
charc/mexpr/pathc only), so every vc.ImGui_* is stubbed to a no-op here; and the REAL
vc.mexpr_draw is stubbed too, because it pushes into ImGui's draw list and the harness opens no
ImGui frame - a call into it outside a frame is an access violation pcall cannot catch, found as
a silent process death mid-draw. With those stubs, one FULL draw runs in Lua: this is NOT a test
of what anything looks like. What it proves is that the draw RUNS TO THE END over a document of
every box kind, and that the layout it leaves is shaped the way the input routing assumes (a
formula box carries its chrome buttons). A draw that throws, this catches; a draw that paints the
wrong colour, nothing catches - that stays a looking.

@date 2026-09-16
]]

package.path = package.path .. ";./scripts/?.lua"

local char = require("char")
local mexpru = require("mexpru")
local mformula_latex = require("mformula_latex")
local mexpr_ast = require("mexpr_ast")
local content = require("content")

local checks_run, checks_failed = 0, 0
local function check(name, cond, got)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name .. (got ~= nil and ("  (got: " .. tostring(got) .. ")") or ""))
    end
end

function run_test()
    local fs = char.load_font_set()

    local vc = require("virt_composer")
    for _, name in ipairs({"ImGui_AddRect", "ImGui_AddRectFilled", "ImGui_AddLine",
            "ImGui_AddCircle", "ImGui_AddCircleFilled", "ImGui_AddArc", "ImGui_AddText",
            "ImGui_AddTriangle", "ImGui_AddTriangleFilled", "ImGui_AddQuad",
            "ImGui_PushClipRect", "ImGui_PopClipRect"}) do
        if vc[name] == nil then
            vc[name] = function() end
        end
    end
    if vc.ImGui_GetDisplaySize == nil then
        vc.ImGui_GetDisplaySize = function() return {x = 1920, y = 1080} end
    end
    if vc.ImGui_CalcTextSize == nil then
        vc.ImGui_CalcTextSize = function() return {x = 40, y = 16} end
    end
    if vc.ImGui_GetMousePos == nil then
        vc.ImGui_GetMousePos = function() return {x = 0, y = 0} end
    end
    vc.mexpr_draw = function() return 24 end

    -- A document of every kind: the empty text box every document starts with, a locked formula
    -- carrying links (an integral), an unlocked one, and a definition. The formula boxes
    -- exercise the chrome row the input routing reads.
    local doc = content.new()
    content.insert_box(doc, 2, "formula")
    local fml = doc.boxes[2].fml
    fml.latex = "\\int x \\,d x"
    fml.formula = mformula_latex.from_latex(fs, mexpru.DEFAULT_SIZE, fml.latex)
    fml.locked = true
    mexpr_ast.build(fs, fml.formula, {})   -- tags and links, as any validated box carries
    local ok1, err1 = pcall(content.draw, doc, fs, {x = 100, y = 100}, nil)
    check("draws with a locked, linked formula box", ok1, err1)

    content.insert_box(doc, 3, "formula")
    doc.boxes[3].fml.latex = "a+b"
    local ok2, err2 = pcall(content.draw, doc, fs, {x = 100, y = 100}, nil)
    check("...and with an unlocked formula box", ok2, err2)

    --[[ NO DEFINITION BOX HERE, and that is a limit, not a choice: its signature separator draws
    through fontset:char_draw, a C++ method on the fontset userdata that no Lua stub can stand in
    for, and outside an ImGui frame it is the access violation again. Covering it needs the
    harness to open a real frame - a C++ change for another day. ]]
    local ok, err = ok1 and ok2, err1 or err2
    check("one full draw of the document runs", ok, err)
    if not ok then
        return checks_failed == 0
    end
    check("...and lays out every box", #doc.last_layout == 3, #doc.last_layout)
    check("a formula box carries its padlock", doc.last_layout[2].lock_btn ~= nil)
    check("...and its bounds-toggle star", doc.last_layout[2].bounds_btn ~= nil)
    check("an unlocked formula carries both too", doc.last_layout[3].lock_btn ~= nil
            and doc.last_layout[3].bounds_btn ~= nil)

    -- Second run with the bounds on: the arcs' drawing is part of the same frame.
    doc.show_bounds = true
    local ok2, err2 = pcall(content.draw, doc, fs, {x = 100, y = 100}, nil)
    check("...and again with the bounds drawing on", ok2, err2)

    if checks_failed == 0 then
        print("PASS: the document draws end to end headlessly (" .. checks_run .. " checks)")
    end
    return checks_failed == 0
end

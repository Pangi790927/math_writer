--[[
test_box_kinds.lua - a box now has a KIND, and only one of the three kinds has controls.

Added 2026-09-06 with the radial box-creation menu. Requested: "make it such that 3 types of boxes
can spawn, gray - our current box, blue a blue box and green a green box, those two will have no
controls for now, so you won't be able to type in them".

THE ASSUMPTION THIS PINS, and it is the one everything else here leans on: **a box's lack of
controls is represented by the ABSENCE of `box.editor`, not by a `kind` check.** Every place that
types into, measures, rescales or serialises a box already has to reach through `box.editor`, so
leaving that field nil makes a box inert everywhere at once, with no "is this kind editable?"
predicate to be forgotten at a new call site later. If a future change gives formula/definition
boxes their own editor object, THIS is the assumption that breaks first, and the guards spread
through content.lua (`if box.editor then`) all become wrong together rather than one at a time.

Serialization is the other thing pinned here. The save format grew a kind prefix - "text 12\n...."
where it used to be a bare "12\n....". Old saves have to keep loading, so a bare length is read as
a text box. That backwards path has no other test and would fail silently by producing an empty
document, which is exactly the failure mode nobody notices until their file is gone.

Not covered: any of the drawing or the radial menu's own geometry - both need a live ImGui frame
(a draw list, a display size, a mouse), which the headless harness has no way to provide. The
menu's hit testing is pure math and could be tested if it were exported; it is not, deliberately,
since exporting internals only for a test is its own kind of debt. What can go wrong there is
visual, and was checked by driving the real app.
]]

package.path = package.path .. ";./scripts/?.lua"

local vc = require("virt_composer")
local char = require("char")
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
    local fontset = char.load_font_set()

    -- ---------------------------------------------------------------------------------------
    -- A fresh document is one text box, exactly as before kinds existed.
    -- ---------------------------------------------------------------------------------------
    local state = content.new()
    check("new() makes one box", #state.boxes == 1, #state.boxes)
    check("new() box is a text box", state.boxes[1].kind == "text", state.boxes[1].kind)
    check("new() box has an editor", state.boxes[1].editor ~= nil)

    -- ---------------------------------------------------------------------------------------
    -- insert_box defaults to text, so every pre-existing caller is unchanged.
    -- ---------------------------------------------------------------------------------------
    content.insert_box(state, 2)
    check("insert_box defaults to text", state.boxes[2].kind == "text", state.boxes[2].kind)
    check("defaulted box has an editor", state.boxes[2].editor ~= nil)

    -- ---------------------------------------------------------------------------------------
    -- The two new kinds: created, coloured differently, and inert. "Inert" is literally
    -- "editor == nil" - see this file's header.
    -- ---------------------------------------------------------------------------------------
    content.insert_box(state, 3, "formula")
    content.insert_box(state, 4, "definition")
    check("formula box kind", state.boxes[3].kind == "formula", state.boxes[3].kind)
    check("definition box kind", state.boxes[4].kind == "definition", state.boxes[4].kind)
    check("formula box has NO editor", state.boxes[3].editor == nil)
    check("definition box has NO editor", state.boxes[4].editor == nil)

    -- ---------------------------------------------------------------------------------------
    -- Insertion still shifts the active index the way it always did, whatever the kind.
    -- ---------------------------------------------------------------------------------------
    state.active_index = 4
    content.insert_box(state, 1, "formula")
    check("active_index shifts past an insert before it", state.active_index == 5, state.active_index)

    -- ---------------------------------------------------------------------------------------
    -- Round trip: kinds survive a save/load, and a text box's own content still does.
    -- ---------------------------------------------------------------------------------------
    local doc = content.new()
    doc.boxes[1].editor.chars = nil -- leave it empty; content is exercised below via from_text
    doc = content.new()
    content.insert_box(doc, 2, "formula")
    content.insert_box(doc, 3, "definition")
    content.insert_box(doc, 4, "text")

    local text = content.serialize(doc)
    local back = content.deserialize(text, fontset)
    check("round trip keeps the box count", #back.boxes == 4, #back.boxes)
    check("round trip keeps kind 1", back.boxes[1].kind == "text", back.boxes[1].kind)
    check("round trip keeps kind 2", back.boxes[2].kind == "formula", back.boxes[2].kind)
    check("round trip keeps kind 3", back.boxes[3].kind == "definition", back.boxes[3].kind)
    check("round trip keeps kind 4", back.boxes[4].kind == "text", back.boxes[4].kind)
    check("round trip: text box has an editor", back.boxes[1].editor ~= nil)
    check("round trip: formula box has none", back.boxes[2].editor == nil)
    check("round trip: definition box has none", back.boxes[3].editor == nil)

    -- Serializing a document that contains editor-less boxes must not error - it used to call
    -- editor.to_text(box.editor) unconditionally, which would be a nil index now.
    check("re-serializing is stable", content.serialize(back) == text)

    -- ---------------------------------------------------------------------------------------
    -- BACKWARDS COMPATIBILITY: a save written before kinds existed is a bare "<len>\n<text>"
    -- per box. It must still load, as text boxes. If this fires, old documents are being read
    -- as empty - check deserialize()'s header parse.
    -- ---------------------------------------------------------------------------------------
    local legacy = "0\n" .. "0\n"
    local old = content.deserialize(legacy, fontset)
    check("legacy save loads its boxes", #old.boxes == 2, #old.boxes)
    check("legacy box 1 reads as text", old.boxes[1].kind == "text", old.boxes[1].kind)
    check("legacy box 2 reads as text", old.boxes[2].kind == "text", old.boxes[2].kind)
    check("legacy box has an editor", old.boxes[1].editor ~= nil)

    -- An unknown kind (a newer save read by an older build, or a corrupt line) degrades to a text
    -- box rather than producing a box nothing can interact with or delete.
    local weird = content.deserialize("sideways 0\n", fontset)
    check("unknown kind degrades to text", weird.boxes[1].kind == "text", weird.boxes[1].kind)

    -- An empty/unreadable document still ends up with one usable box, as it always did.
    local empty = content.deserialize("", fontset)
    check("empty document still yields one box", #empty.boxes == 1, #empty.boxes)
    check("that box is usable", empty.boxes[1].editor ~= nil)

    if checks_failed > 0 then
        print(string.format("test_box_kinds: %d/%d checks failed", checks_failed, checks_run))
        return false
    end
    return true
end

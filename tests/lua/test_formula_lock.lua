--[[
test_formula_lock.lua - the formula box's two modes and the one restriction on locking.

THE ASSUMPTION: a locked box is a transform cell, and a transform cell always has a live ast under
it - the author, 2026-09-15: "you are not allowed to lock in a mexpr tree that can't be parsed into
an ast". Everything else about the lock is a mode switch: unlocked, the box is a mathbox; locked,
its content is frozen.

WHAT IS NOT TESTED HERE: the transform menu and the derived child box - those are content.lua's
half, fed by ast_gestures, and get their own test when that wiring exists. And the EDIT-mode commit
of typing needs real input events, which the headless harness does not synthesize.

@date 2026-09-15 12:00
]]

package.path = package.path .. ";./scripts/?.lua"

local char = require("char")
local editor_formula = require("editor_formula")

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

    -- ------------------------------------------------------------------ the restriction
    do
        local box = editor_formula.new(1)
        editor_formula.from_text(box, "8\n" .. "6\na(b+c)" .. "1\n1" .. "1\n", fs)
        check("setup: the box has content", box.latex == "a(b+c)", box.latex)
        check("locking a parseable formula succeeds",
                editor_formula.lock(box, fs, {}) == true)
        check("...and the box reports locked", box.locked == true)
        check("unlocking returns to EDIT", editor_formula.lock(box, fs, {}) == false)
        check("...and reports it", box.locked == nil)
    end

    do
        --[[ AN UNPARSEABLE TREE STAYS UNLOCKED - the whole point of the restriction. A lone `@`
        atom reads as nothing in the grammar, so the parse refuses and so must the lock. ]]
        local box = editor_formula.new(2)
        editor_formula.from_text(box, "8\n" .. "2\n@@" .. "1\n2" .. "1\n", fs)
        check("setup: the bad box has content", box.latex == "@@", box.latex)
        check("locking an unparseable formula is refused",
                editor_formula.lock(box, fs, {}) == false)
        check("...and the box stays in EDIT", box.locked == nil)
    end

    do
        -- An empty box has nothing to transform, so it cannot lock either.
        local box = editor_formula.new(3)
        check("an empty box cannot lock", editor_formula.lock(box, fs, {}) == false)
    end

    -- ------------------------------------------------------------------ persistence
    do
        --[[ THE LOCK RIDES THE SAVE. The body's count is honoured, so a three-entry body - every
        file written before the lock existed - loads as EDIT, which is what a box with no recorded
        mode should be. ]]
        local box = editor_formula.new(4)
        editor_formula.from_text(box, "8\n" .. "6\na(b+c)" .. "1\n4" .. "1\n", fs)
        editor_formula.lock(box, fs, {})
        local saved = editor_formula.to_text(box)
        check("a locked box saves four entries", saved:sub(1, 2) == "4\n", saved:sub(1, 20))

        local back = editor_formula.new()
        editor_formula.from_text(back, saved, fs)
        check("...and reloads locked", back.locked == true)

        local old = editor_formula.new()
        editor_formula.from_text(old, "7\n" .. "6\na(b+c)" .. "1\n7" .. "1\n", fs)
        check("a pre-lock save (three entries) loads as EDIT", old.locked == nil)
    end

    -- ------------------------------------------------------------------ undo and redo
    do
        --[[ ONE SNAPSHOT PER CHANGE, oldest first. The stack is driven by real edits, which the
        harness cannot synthesize - so the test seeds a stack by hand and steps it, which is all
        of undo's own logic. ]]
        local box = editor_formula.new(6)
        editor_formula.from_text(box, "8\n" .. "4\nx+y " .. "1\n6" .. "1\n", fs)
        box.undo_stack = {"a(b+c)", "x"}
        check("undo steps back to the previous committed text",
                editor_formula.undo(box, fs) and box.latex == "x", box.latex)
        check("...and again to the one before", editor_formula.undo(box, fs)
                and box.latex == "a(b+c)", box.latex)
        check("...and refuses when the stack is empty",
                editor_formula.undo(box, fs) == false, box.latex)
        check("redo steps forward over what undo left",
                editor_formula.redo(box, fs) and box.latex == "x", box.latex)
        check("...and back once more",
                editor_formula.redo(box, fs) and box.latex == "x+y ", box.latex)
    end

    --[[ NOT TESTED HERE, CANNOT BE: the draw path. The harness has no draw context - a bare
    vc.ImGui_AddRectFilled with correct arguments fails headlessly (probed 2026-09-15) - so no
    test can run editor_formula.draw. That is how a wrong-arity AddRect shipped green through the
    whole suite and killed the live app's layout pass for a session (no thickness argument: the
    binding requires five, and the throw took out rail, scroll and click-routing together, since
    content.lua records its layout only after the draw completes). The discipline that stands in
    for a test: every ImGui call this file makes must match the arity and types of a sibling call
    in the same file, and a new KIND of call is copied from where it already works. ]]

    if checks_failed == 0 then
        print("PASS: the lock and its restriction (" .. checks_run .. " checks)")
    end
    return checks_failed == 0
end

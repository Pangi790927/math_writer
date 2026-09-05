--[[
test_dangling_cursor.lua - a cursor_pos whose node has been released must not kill the editor.

container.cursor_pos is a WEAK ref (vc.wref_mexpr), and mexpru.cut() force-releases a node even
while other references to it remain, so a rebuild that fails to move the cursor leaves it dangling
rather than merely stale. Every per-frame reader used to dereference it blind.

What that cost, in a real session on 2026-09-05: after Ctrl+Shift+Left x3, Ctrl+C, Right x6, Ctrl+V,
slot_markers() threw "attempt to index a nil value (local 'node')". main.lua's pcall caught it, so
the process stayed alive and responsive - and threw again on the very next frame, and every frame
after, 1140 times until the session ended. Nothing redrew. It was indistinguishable from a freeze,
and the flight recorder was so full of copies that the six keystrokes which caused it were the only
useful lines in the file.

The underlying missed reassignment has NOT been reproduced (three targeted attempts - brackets, a
superscript, a text-mode select-all - all came back clean), so this pins the RECOVERY, not the
cause: whatever leaves the cursor dangling, the editor must stay usable and say so once. If the real
trigger is found later, it deserves its own test; this one should keep passing either way.
]]

package.path = package.path .. ";./scripts/?.lua"

local vc = require("virt_composer")
local char = require("char")
local mexpru = require("mexpru")
local mformula_new = require("mformula_new")

local checks_run, checks_failed = 0, 0
local function check(name, cond, got)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name .. (got ~= nil and ("  (got: " .. tostring(got) .. ")") or ""))
    end
end

local SZ = 12

--[[ A node attached to nothing: releasing a node that a parent still holds does not actually
destroy it, so an orphan is the only way to produce a genuinely dead weak ref on purpose. ]]
local function dangle(container, fs)
    local orphan = mexpru.mexpr_symbol(fs, {size = SZ, code = char.find_by_ascii("q").ncod}, true)
    mexpru.u(orphan).sz = SZ
    container.cursor_pos = vc.wref_mexpr(orphan)
    mexpru.cut(orphan)
    orphan = nil
    collectgarbage("collect")
end

function run_test()
    local fs = char.load_font_set()

    do
        local c = mformula_new.new(fs, SZ)
        dangle(c, fs)
        check("the setup really does produce a dead weak ref", c.cursor_pos:get_obj() == nil)

        local ok = pcall(function() return mformula_new.slot_markers(c, fs, SZ) end)
        check("slot_markers survives a dangling cursor instead of throwing", ok)
        check("...and the cursor is put back on the root",
                mexpru.same(c.cursor_pos:get_obj(), c.root))
    end

    --[[ handle_input() reads the cursor through cursor_state(), which is the other per-frame path
    into it. It cannot be called without a live ImGui context, so this checks the same guard the
    same way slot_markers does - via the recovery being idempotent and leaving a usable cursor. ]]
    do
        local c = mformula_new.new(fs, SZ)
        dangle(c, fs)
        mformula_new.slot_markers(c, fs, SZ)
        local first = c.cursor_pos:get_obj()
        mformula_new.slot_markers(c, fs, SZ)
        check("a second pass leaves the recovered cursor alone",
                mexpru.same(c.cursor_pos:get_obj(), first))
        check("the recovered cursor is usable - selection_range does not throw",
                pcall(function() return mformula_new.selection_range(c) end))
    end

    print("checks: " .. checks_run .. ", failed: " .. checks_failed)
    if checks_failed > 0 then
        return false
    end
    print("PASS: dangling cursor - recovers to the root instead of erroring every frame")
    return true
end

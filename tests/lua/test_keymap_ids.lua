--[[
test_keymap_ids.lua - every action id the editors ASK FOR must exist in the registry.

THE ASSUMPTION: `keymap.pressed("edit.undo")` and the `{id = "edit.undo"}` entry in keymap.lua's
DEFAULTS refer to the same thing. Nothing in the language enforces that - they are two string
literals in two files.

WHY IT NEEDS AN ALARM, and why this test exists at all. When the 92 hand-rolled ImGui polls were
converted to keymap calls (2026-09-07), a mistyped id would not crash and would not look wrong: it
would mean that one shortcut silently stops working, forever, and the only way to find out is for
somebody to reach for that key and notice nothing happened. keymap.pressed() raises on an unknown
id precisely so that it CANNOT fail quietly - but a raise only helps if the line actually runs, and
these lines run on a key press, which no test performs.

This is the same shape as test_no_use_before_define.lua's own finding: a nil call on the draw path
was invisible because nothing ran the draw path. Here nothing runs the INPUT path -
mformula_new.handle_input() is not callable headless (several tests say so in their own comments,
and mirror its logic instead), so the entire keymap refactor is invisible to the other 54 tests.
They pass whether or not every binding in the app is broken. This file is the only thing standing
between a typo and a dead shortcut.

It reads the scripts as TEXT rather than running them, which is the whole point: no key has to be
pressed, and no editor state has to exist, for a mismatch to be caught.

The file list is spelled out below rather than globbed - Lua has no directory listing without an
external library. A NEW script that calls keymap and is not added here is simply not checked, so
add it when you add the file. The count assertion at the end is a weak guard against exactly that:
if it ever drops sharply, the scan has stopped finding what it used to.
]]

package.path = package.path .. ";./scripts/?.lua"

local keymap = require("keymap")

-- Every script that calls into keymap. See the header on why this is a literal list.
local SCRIPTS = {
    "scripts/main.lua",
    "scripts/content.lua",
    "scripts/editor_text.lua",
    "scripts/editor_formula.lua",
    "scripts/editor_definition.lua",
    "scripts/mformula_new.lua",
}

-- The keymap entry points that take an action id as their first argument.
local ID_TAKING = {"pressed", "label", "describe", "binds_of"}

function run_test()
    local ok = true
    local known = {}
    keymap.each(function(id) known[id] = true end)

    local checked, missing = 0, {}
    for _, path in ipairs(SCRIPTS) do
        local f = io.open(path, "r")
        if not f then
            print("FAIL: cannot open " .. path)
            ok = false
        else
            local src = f:read("*a")
            f:close()
            for _, fname in ipairs(ID_TAKING) do
                -- keymap.pressed("some.id") - only the literal-string form is checkable, which is
                -- also the only form any call site uses.
                for id in src:gmatch('keymap%.' .. fname .. '%("([^"]+)"%)') do
                    checked = checked + 1
                    if not known[id] then
                        missing[#missing + 1] = path .. " -> keymap." .. fname
                                .. '("' .. id .. '")'
                    end
                end
            end
        end
    end

    for _, m in ipairs(missing) do
        print("FAIL: unknown action id: " .. m)
        ok = false
    end

    -- The scan must actually be finding call sites. If this number collapses, either the refactor
    -- was reverted or the pattern above stopped matching how the calls are written - both of which
    -- would make every check above vacuously pass.
    if checked < 40 then
        print("FAIL: only " .. checked .. " keymap call sites found; the scan looks broken")
        ok = false
    else
        print("checked " .. checked .. " keymap call sites across "
                .. #SCRIPTS .. " scripts, all ids known")
    end

    --[[ The reverse direction is deliberately NOT asserted. An action with no call site yet is
    legitimate - it is how a binding gets added to the customiser and the help before the editor
    code that uses it exists - so "unused action" is not an error, and asserting it would make
    the registry hostage to the order the work happens in. ]]

    return ok
end

--[[
bar_crash.lua - the Ctrl+Shift+\ crash, minimally, in the test harness.

NOT A TEST, and not in tests/lua/ for that reason: it is supposed to die, and everything in that
folder is picked up by the suite glob. Run it by path:

    python tests/run_tests.py tests/repro/bar_crash.lua
    python tests/run_tests.py --asan tests/repro/bar_crash.lua      (with the sanitizer)

WHAT IT REPRODUCES. `try_close_bracket` closes the pair and rebuilds the whole tree through
propagate_rebuild. Before the fix it returned nothing, so the bar key - the one shortcut that both
opens and closes - read a successful close as a refusal and went on to open a bracket, handing
`open_bracket` the `target`/`target_parent` it had captured BEFORE the rebuild. Those name nodes of
the tree that has just been replaced.

This file does that sequence directly. It needs no app, no debug pipe, no debugger and no admin,
which is the whole point: the same thing took a running instance driven over TCP and a second-chance
exception stepped over in cdb to see once.

IT CRASHES EVEN WITH THE FIX IN PLACE, deliberately - it calls open_bracket with stale handles
itself rather than relying on the missing return value to get there. So it reproduces the
UNDERLYING fault, not the Lua slip that used to reach it, and stays useful for deciding whether the
C++ side should be able to survive this at all.

Expected: the trace file stops at "about to open_bracket with the STALE handles" and the harness
exits with 0xC0000005. Under --asan it should instead report a heap-use-after-free, and the "freed
by" stack is the thing worth reading - it says WHO destroyed the node, which the access violation
alone never did.
]]

package.path = package.path .. ";./scripts/?.lua"

local vc = require("virt_composer")
local char = require("char")
local mexpru = require("mexpru")
local mformula = require("mformula_new")

local SZ = 12

function run_test()
    -- Written and flushed per line: a segfault must not take the trace with it.
    local f = io.open("test_run/bar_crash_trace.txt", "w")
    local function say(t) f:write(t .. string.char(10)); f:flush() end

    if not vc.MEXPR_BRACKET_BAR then
        say("SKIP: MEXPR_BRACKET_BAR is not registered in this build")
        f:close()
        return true
    end

    local fs = char.load_font_set()
    local c = mformula.new(fs, SZ)

    local t0 = c.cursor_pos:get_obj()
    mformula.open_bracket(c, fs, t0, t0:get_parent(), false, true, false, SZ,
            vc.MEXPR_BRACKET_BAR)
    say("opened the bar")

    -- The six values handle_input reads ONCE, up front (cursor_state), before dispatching a key.
    local target = c.cursor_pos:get_obj()
    local target_parent = target:get_parent()
    local target_is_horiz = (mexpru.u(target).kind == "horiz")
    local target_is_empty = (target.type == vc.MEXPR_TYPE_EMPTY_BOX)
    local target_sz = mexpru.u(target).sz
    say("captured target=" .. tostring(target))
    say("captured parent=" .. tostring(target_parent))

    -- The close. It succeeds, and propagate_rebuild replaces the tree the two handles point into.
    say("closing -> " .. tostring(mformula.try_close_bracket(c, fs, vc.MEXPR_BRACKET_BAR)))

    say("about to open_bracket with the STALE handles")
    mformula.open_bracket(c, fs, target, target_parent, target_is_horiz, target_is_empty,
            false, target_sz, vc.MEXPR_BRACKET_BAR)

    say("SURVIVED - the stale handles did not fault")
    f:close()
    return true
end

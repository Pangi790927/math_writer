--[[
input_recorder.lua - a "flight recorder" for real input, requested live 2026-09-05: "I crashed, make
something to record the motions I do, such that on a crash (not a segfault one, but a normal
exception) those will be all available for you to inspect".

Every frame, polls the exact same ImGui key/mouse state the rest of this app already reads (nothing
new exposed from C++ - vc.ImGui_IsKeyPressed/IsKeyDown/GetMousePos/IsMouseClicked/GetMouseWheel are
all already bound) and appends one line per DISTINCT event (a key just pressed, a click, a non-zero
wheel tick) to a plain text log.

WRITTEN BY ANOTHER THREAD (async_log_composer.h). This frame does an enqueue and nothing else - no
write, no flush, no file handle. It took two wrong turns to get here, both worth recording so
neither gets re-proposed:

  - Originally it flushed every line, from the render thread. A syscall per keystroke.
  - Then the flush was dropped outright. That lost the ENTIRE log on a kill, not the "last few
    lines" it was described as - an unflushed buffer holds several KB, which at these line lengths
    is a whole session. Verified by killing the app and finding the file empty.
  - A 1s periodic flush patched that, but it was only a compromise between the two.

Moving the writing off the frame dissolves the trade instead of splitting it: because the flush now
happens somewhere that is not the frame, it goes back to being per-line, so every event is durable
the moment the writer picks it up and the app pays nothing at all. A kill loses only what was still
in flight; a normal exit waits for the queue to drain (see close()) - verified 2026-09-05 by sending
the debug pipe's `quit` milliseconds after the last keystroke and finding every line present.

main.lua's own test_draw() additionally wraps the real per-frame logic in a pcall and, on failure,
appends the Lua error string here too - virt_composer's own call_on_stack already catches an
uncaught Lua error at the C++ boundary either way (DBG-logged, the app itself doesn't hard-crash from
one - confirmed via the test harness's own error output), so THIS specifically is for capturing the
error message and the events that led to it in ONE place, not for preventing whatever the process
does about it. If content_state is left corrupted by a failed operation, the SAME error will likely
keep recurring every subsequent frame (visually indistinguishable from a real freeze, even though the
process is technically still alive and responsive) - a real, separate limitation this doesn't solve
(that's a state-recovery/rollback feature, well beyond "record what happened").

Monitored keys are every ImGuiKey name this app's own scripts check ANYWHERE (grepped, not guessed -
re-check this list if a new keybinding gets added elsewhere and stops showing up here) plus all 26
letters (char.lua's own greek_keys table already enumerates those). Modifier keys are tracked as
DOWN state, not edge-triggered, so an event like "Ctrl+Shift+Equal" can be reported as one line
instead of three separate "Control down"/"Shift down"/"Equal pressed" ones.
]]

local vc = require("virt_composer")
local prof = require("prof")
local char = require("char")

local input_recorder = {}

local LOG_PATH = "input_history.log"
local OLD_LOG_PATH = "input_history.old.log"

local log_open = false
local frame = 0

-- Every non-letter key any script in this app actually checks (2026-09-05 - see this file's own
-- top comment on keeping this list honest via grep, not assumption).
local WATCHED_KEY_NAMES = {
    "ImGuiKey_Backspace", "ImGuiKey_Delete", "ImGuiKey_LeftArrow", "ImGuiKey_RightArrow",
    "ImGuiKey_UpArrow", "ImGuiKey_DownArrow", "ImGuiKey_Enter", "ImGuiKey_KeypadEnter",
    "ImGuiKey_Escape", "ImGuiKey_Home", "ImGuiKey_End", "ImGuiKey_Space",
    "ImGuiKey_Equal", "ImGuiKey_Minus", "ImGuiKey_Slash", "ImGuiKey_F1", "ImGuiKey_F2",
}
for key_name in pairs(char.greek_keys) do
    WATCHED_KEY_NAMES[#WATCHED_KEY_NAMES + 1] = key_name
end

--[[ Resolved to INTEGERS once, here, instead of passing the name string on every poll.

virt_composer's bm_t<ImGuiKey> parameter accepts either, and the two are not remotely equivalent:
the string path builds an fkyaml::node per call just to look the enum up, the integer path is a
lua_tointegerx. Measured in the real app 2026-09-05, 20000 calls each:

    "ImGuiKey_Backspace"    180.83us per call
    vc.ImGuiKey_Backspace     0.22us per call      (822x)

This loop polls 43 keys EVERY frame, so the string form cost ~6.4ms of a 16.7ms frame budget - by
itself about a third of why the app was running at 30fps instead of 60. The integer values were
already sitting on the vc table (add_lua_flag_mapping puts every ImGuiKey_* there as a plain
number); nothing needed adding to C++, the fast path was simply never being taken.

Resolved at load rather than per call because the mapping never changes. A name that is somehow
absent is kept as its string, so it still works - just slowly - rather than silently never firing. ]]
local WATCHED_KEYS = {}
for _, name in ipairs(WATCHED_KEY_NAMES) do
    WATCHED_KEYS[#WATCHED_KEYS + 1] = vc[name] or name
end

-- Hands the line to the writer thread and returns immediately (async_log_composer.h). No file
-- handle here at all any more - no write, no flush, nothing that can block a frame.
local function write_line(line)
    if not log_open then
        return
    end
    vc.alog_write(line)
end

--[[ Rotates the previous session's log to input_history.old.log (overwriting whatever was there
before - same one-deep rotation ../utils's own DBG()/logfile.log convention uses) and opens a fresh
one for this session. Called once, from main.lua's test_init(). ]]
function input_recorder.init()
    local prev = io.open(LOG_PATH, "rb")
    if prev then
        local text = prev:read("*a")
        prev:close()
        local dst = io.open(OLD_LOG_PATH, "wb")
        if dst then
            dst:write(text)
            dst:close()
        end
    end
    --[[ Truncate here, in Lua, then hand the path to the writer thread, which opens it for APPEND.
    Two steps rather than one because the rotation above has to finish reading the old file before
    anything reopens it, and because "start a fresh log" is this module's decision, not the writer's
    - alog_open() appending is what lets it be reopened later without losing what came before. ]]
    local truncate = io.open(LOG_PATH, "wb")
    if truncate then
        truncate:close()
    end
    --[[ async_log_composer.h is registered by main.cpp but not by the test harness, which registers
    only charc/mexpr - so vc.alog_open is nil there and calling it would be an error rather than a
    quiet no-op. Nothing under the harness loads this module today; the guard is so that stays a
    non-event if something ever does. Same reasoning as prof.lua's own stub block. ]]
    log_open = (vc.alog_open ~= nil) and vc.alog_open(LOG_PATH) or false
    frame = 0
    write_line("=== session start ===")
end

--[[ Stops the writer. Called from main.lua's test_shutdown(), with main.cpp calling it again as a
backstop. alog_close() pushes its stop marker BEHIND everything already queued and then joins, so
this blocks until the last line is on disk - which is the intent: a normal exit waits for the log to
finish rather than cutting the writer off mid-queue. ]]
function input_recorder.close()
    if log_open then
        vc.alog_close()   -- drains the queue and joins the writer before returning
        log_open = false
    end
end

--[[ Call once per frame, BEFORE any real per-frame logic runs - so an event is on disk even if
whatever it triggers goes on to error out later in the SAME frame. ]]
function input_recorder.poll()
    frame = frame + 1
    if not log_open then
        return
    end

    local ctrl = vc.ImGui_IsKeyDown("ImGuiKey_LeftCtrl") or vc.ImGui_IsKeyDown("ImGuiKey_RightCtrl")
    local shift = vc.ImGui_IsKeyDown("ImGuiKey_LeftShift") or vc.ImGui_IsKeyDown("ImGuiKey_RightShift")
    local alt = vc.ImGui_IsKeyDown("ImGuiKey_LeftAlt") or vc.ImGui_IsKeyDown("ImGuiKey_RightAlt")
    local mods = (ctrl and "Ctrl+" or "") .. (shift and "Shift+" or "") .. (alt and "Alt+" or "")

    prof.begin("lua.recorder.key_scan")
    for i, key in ipairs(WATCHED_KEYS) do
        if vc.ImGui_IsKeyPressed(key, false) then
            -- The NAME for the log comes from the parallel list, since `key` is now an integer.
            write_line(frame .. " key " .. mods .. WATCHED_KEY_NAMES[i]:gsub("^ImGuiKey_", ""))
        end
    end

    prof.stop("lua.recorder.key_scan")

    for _, cp in ipairs(vc.ImGui_input_queue_chars()) do
        if cp >= 32 and cp < 256 then
            write_line(frame .. " char " .. mods .. string.char(cp))
        end
    end

    if vc.ImGui_IsMouseClicked("ImGuiMouseButton_Left", false) then
        local p = vc.ImGui_GetMousePos()
        write_line(frame .. " click left " .. mods .. string.format("(%.0f,%.0f)", p.x, p.y))
    end
    if vc.ImGui_IsMouseClicked("ImGuiMouseButton_Right", false) then
        local p = vc.ImGui_GetMousePos()
        write_line(frame .. " click right " .. mods .. string.format("(%.0f,%.0f)", p.x, p.y))
    end

    local wheel = vc.ImGui_GetMouseWheel()
    if wheel and wheel ~= 0 then
        write_line(frame .. " wheel " .. mods .. string.format("%.2f", wheel))
    end
end

--[[ Call from main.lua's own pcall wrapper around the real per-frame logic, with the error value
pcall itself returned, whenever that call fails. ]]
--[[ No special flush handling any more: the writer thread flushes every line it writes, so an error
is durable as soon as the writer reaches it, the same as any other line. ]]
function input_recorder.log_error(err)
    write_line(frame .. " *** ERROR *** " .. tostring(err))
end

return input_recorder

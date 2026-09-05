--[[
input_recorder.lua - a "flight recorder" for real input, requested live 2026-09-05: "I crashed, make
something to record the motions I do, such that on a crash (not a segfault one, but a normal
exception) those will be all available for you to inspect".

Every frame, polls the exact same ImGui key/mouse state the rest of this app already reads (nothing
new exposed from C++ - vc.ImGui_IsKeyPressed/IsKeyDown/GetMousePos/IsMouseClicked/GetMouseWheel are
all already bound) and appends one line per DISTINCT event (a key just pressed, a click, a non-zero
wheel tick) to a plain text log, flushed to disk immediately after every write - not buffered until
some "on crash" moment, since a real segfault gives no chance to flush anything after the fact (the
user's own "not a segfault one" caveat - this recorder can't do anything for THAT case beyond
whatever was already durably on disk from frames before it, which immediate-flush already covers).

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
local char = require("char")

local input_recorder = {}

local LOG_PATH = "input_history.log"
local OLD_LOG_PATH = "input_history.old.log"

local log_file = nil
local frame = 0

-- Every non-letter key any script in this app actually checks (2026-09-05 - see this file's own
-- top comment on keeping this list honest via grep, not assumption).
local WATCHED_KEYS = {
    "ImGuiKey_Backspace", "ImGuiKey_Delete", "ImGuiKey_LeftArrow", "ImGuiKey_RightArrow",
    "ImGuiKey_UpArrow", "ImGuiKey_DownArrow", "ImGuiKey_Enter", "ImGuiKey_KeypadEnter",
    "ImGuiKey_Escape", "ImGuiKey_Home", "ImGuiKey_End", "ImGuiKey_Space",
    "ImGuiKey_Equal", "ImGuiKey_Minus", "ImGuiKey_Slash", "ImGuiKey_F1", "ImGuiKey_F2",
}
for key_name in pairs(char.greek_keys) do
    WATCHED_KEYS[#WATCHED_KEYS + 1] = key_name
end

local function write_line(line)
    if not log_file then
        return
    end
    log_file:write(line, "\n")
    log_file:flush()
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
    log_file = io.open(LOG_PATH, "wb")
    frame = 0
    write_line("=== session start ===")
end

--[[ Call once per frame, BEFORE any real per-frame logic runs - so an event is on disk even if
whatever it triggers goes on to error out later in the SAME frame. ]]
function input_recorder.poll()
    frame = frame + 1
    if not log_file then
        return
    end

    local ctrl = vc.ImGui_IsKeyDown("ImGuiKey_LeftCtrl") or vc.ImGui_IsKeyDown("ImGuiKey_RightCtrl")
    local shift = vc.ImGui_IsKeyDown("ImGuiKey_LeftShift") or vc.ImGui_IsKeyDown("ImGuiKey_RightShift")
    local alt = vc.ImGui_IsKeyDown("ImGuiKey_LeftAlt") or vc.ImGui_IsKeyDown("ImGuiKey_RightAlt")
    local mods = (ctrl and "Ctrl+" or "") .. (shift and "Shift+" or "") .. (alt and "Alt+" or "")

    for _, key_name in ipairs(WATCHED_KEYS) do
        if vc.ImGui_IsKeyPressed(key_name, false) then
            write_line(frame .. " key " .. mods .. key_name:gsub("^ImGuiKey_", ""))
        end
    end

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
function input_recorder.log_error(err)
    write_line(frame .. " *** ERROR *** " .. tostring(err))
end

return input_recorder

--[[
prof.lua - Lua front end for perf_composer.h's profiler.

Built 2026-09-05 to answer "the thing starts to lag" with a frame number and a cause rather than a
guess. See perf_composer.h's own header comment for the model (per-frame totals, a worst-frame
snapshot, event tags, inclusive timing).

Two ways in:

  prof.wrap(name, fn)      -> an instrumented copy of fn
  prof.begin/stop(name)    -> for a phase that isn't a single function

wrap() is the one that matters. It instruments a hot helper WITHOUT touching any of its call sites -
`mexpru.same = prof.wrap("lua.same", mexpru.same)` is the whole edit, and deleting that one line
removes the instrumentation completely. Scattering begin/stop pairs through the callers would mean
touching dozens of lines in mformula_new.lua and remembering to take them all back out.

DISABLED COSTS ONE LOCAL READ. `enabled` is a file-local boolean, checked before anything else, so a
wrapped function that isn't being profiled does not cross into C++ at all - it is a comparison and a
tail call. That matters because these wrap the hottest functions in the codebase; a profiler that
made the app slower while switched off would be measuring itself.

wrap() forwards through select('#', ...) rather than a plain `return fn(...)` because it has to run
prof_stop AFTER the call and still return every value the wrapped function returned - and several of
these are multi-return (peer_slot returns two, propagate_rebuild's callers rely on exact arity).
table.pack/unpack is the only spelling that preserves both arity and embedded nils.
]]

local vc = require("virt_composer")

local prof = {}

--[[ perf_composer.h is registered by main.cpp but NOT by the test harness (tests/harness), which
only registers charc/mexpr - so under the harness every vc.prof_* is nil. The instrumentation in
mexpru/mformula_new/editor is loaded there regardless, and while it is all gated behind `enabled`
(false by default) that gate is the only thing standing between a test and a nil call. Stubbing the
missing half here makes the whole module a no-op instead, so a test that turns profiling on gets
nothing rather than a crash. ]]
local HAVE_PROF = (vc.prof_enable ~= nil)
if not HAVE_PROF then
    local noop = function() end
    prof.wrap = function(_, fn) return fn end
    prof.begin, prof.stop, prof.event = noop, noop, noop
    prof.set_enabled, prof.reset, prof.record_stop = noop, noop, noop
    prof.record_start = noop
    prof.enabled = function() return false end
    prof.overlay_visible = function() return false end
    prof.recording = function() return false end
    prof.spike_count = function() return 0 end
    prof.report = function() return "profiler not registered" end
    prof.now_ms = function() return 0 end
    return prof
end

--[[ TWO independent flags, not one. `enabled` is whether timing runs; `overlay` is whether the
panel is drawn. Collapsing them (which this did at first) means switching recording on also draws
the panel, and the panel then shows up inside the very spike reports it was supposed to stay out of
- caught 2026-09-05 by finding lua.prof_overlay in a log recorded without ever pressing F3. Timing
is on whenever EITHER the panel or a recording wants it. ]]
local enabled = false
local overlay = false

--[[ No pcall around fn. An error would skip prof_end and leave that name stuck at depth > 0, which
in perf_composer.h suppresses it until the depth returns to zero - but prof_frame() clears the whole
entry table every frame, so the damage is bounded to the frame that threw, and a frame that threw is
already broken. Wrapping every call in a pcall to protect against that cost more than the functions
being measured: these wrap the hottest, smallest functions in the codebase, where a pcall plus its
extra table is several times the work of the callee.

table.pack/unpack, though, is not optional: prof_end has to run AFTER the call and the result still
has to come back intact, and several of these are multi-return (peer_slot returns two; a caller
relying on exact arity would break under `return (fn(...))`). It preserves both arity and embedded
nils, which is the only spelling that does. ]]
local function call_traced(name, fn, ...)
    vc.prof_begin(name)
    local r = table.pack(fn(...))
    vc.prof_end(name)
    return table.unpack(r, 1, r.n)
end

function prof.wrap(name, fn)
    return function(...)
        if not enabled then
            return fn(...)
        end
        return call_traced(name, fn, ...)
    end
end

function prof.begin(name)
    if enabled then
        vc.prof_begin(name)
    end
end

function prof.stop(name)
    if enabled then
        vc.prof_end(name)
    end
end

--[[ Tags the current frame with something that happened in it. This is the half that turns a timing
report into a diagnosis: "frame took 38ms" plus "events: key:Backspace undo" says what to go and
look at, where the timings alone only say where the time went. ]]
function prof.event(name)
    if enabled then
        vc.prof_event(name)
    end
end

-- Timing is on if anything wants it: the panel, or a running recording.
local function refresh()
    enabled = overlay or vc.prof_recording()
    vc.prof_enable(enabled)
end

--[[ Shows/hides the PANEL. Turning it off must not stop a recording that is running - the whole
point of the recording mode is to leave it on with the panel hidden. ]]
function prof.set_enabled(on)
    overlay = on and true or false
    refresh()
end

function prof.enabled()
    return enabled
end

-- Whether the PANEL should be drawn - what content.lua asks. Not the same as enabled(): a recording
-- runs with this false, which is the whole point.
function prof.overlay_visible()
    return overlay
end

function prof.reset()
    vc.prof_reset()
end

function prof.report()
    return vc.prof_report()
end

-- Raw clock, milliseconds, for a one-off measurement that doesn't deserve a named scope.
function prof.now_ms()
    return vc.prof_now_ms()
end

--[[ Spike recording (perf_composer.h). Writes every frame slower than `threshold_ms` to `path`,
with its full breakdown and event tags, appending across runs.

Independent of the overlay ON PURPOSE. The overlay costs real milliseconds and has itself been the
biggest single item in a spike frame, so watching for spikes with it on measures the watching. This
is the mode to actually hunt a lag in: recording on, overlay off, use the app normally, read the
file afterwards. prof_record_start() turns profiling on by itself, since recording with it off would
silently write nothing. ]]
function prof.record_start(path, threshold_ms)
    vc.prof_record_start(path or "perf_spikes.log", threshold_ms or 25.0)
    refresh()
end

function prof.record_stop()
    vc.prof_record_stop()
    refresh()
end

function prof.recording()
    return vc.prof_recording()
end

function prof.spike_count()
    return vc.prof_spike_count()
end

return prof

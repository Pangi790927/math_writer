--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | TIMING
-- | wrap(name: string, fn: function)        -> function
-- |     An instrumented copy of `fn`, reporting its own inclusive time.
-- | begin(name: string) / stop(name: string) -> nothing
-- |     A named scope for a PHASE that is not one function. Every begin
-- |     needs its stop.
-- | event(name: string)                     -> nothing
-- |     Tags the current frame with something that happened in it.
-- | now_ms()                                -> number
-- |     The profiler's own clock, so hand timing reads the same one.
-- |
-- | THE PANEL
-- | set_enabled(on: boolean) / enabled()    -> nothing / boolean
-- | overlay_visible()                       -> boolean
-- |     set_enabled shows or hides the PANEL; `enabled` is "timing is
-- |     being collected", which a spike recording does with the panel
-- |     hidden - these are not the same question.
-- | reset()                                 -> nothing
-- | report()                                -> text
-- |
-- | SPIKE RECORDING
-- | record_start(path: string, threshold_ms: number) -> nothing
-- | record_stop() / recording()             -> nothing / boolean
-- | spike_count()                           -> integer
-- |     Every frame slower than the threshold, with its breakdown, to a
-- |     file. INDEPENDENT OF THE OVERLAY on purpose: the overlay costs
-- |     real milliseconds and has itself been the largest item in a spike.
-- |
-- | Every entry is a NO-OP STUB when perf_composer.h is not registered (the test harness): wrap
-- | hands `fn` back, the queries answer false / 0 / "profiler not registered".
-- |
-- | --- internal, not on the module table ---------------------------------------------------------
-- |     call_traced, refresh; everything else is a thin pass to perf_composer.h
-- |
-- | @date 2026-09-13 18:15
-- | ===============================================================================================
--]]

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
@date 2026-09-08 08:45
]]

local vc = require("virt_composer")

local prof = {}

--[[ perf_composer.h is registered by main.cpp but NOT by the test harness (tests/harness), which
only registers charc/mexpr - so under the harness every vc.prof_* is nil. The instrumentation in
mexpru/mformula_new/editor is loaded there regardless, and while it is all gated behind `enabled`
(false by default) that gate is the only thing standing between a test and a nil call. Stubbing the
missing half here makes the whole module a no-op instead, so a test that turns profiling on gets
nothing rather than a crash.
@date 2026-09-08 08:45 ]]
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
is on whenever EITHER the panel or a recording wants it.
@date 2026-09-08 08:45 ]]
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
nils, which is the only spelling that does.
@date 2026-09-08 08:45 ]]
local function call_traced(name, fn, ...)
    vc.prof_begin(name)
    local r = table.pack(fn(...))
    vc.prof_end(name)
    return table.unpack(r, 1, r.n)
end

--[[ @brief An instrumented copy of `fn`, reporting its own inclusive time under `name`.
-- |
-- | THE WRAPPER IS THE WHOLE EDIT - `mexpru.same = prof.wrap("lua.same", mexpru.same)` - so no
-- | call site changes, and deleting that line removes the instrumentation.
-- |
-- | COSTS ONE LOCAL READ WHILE PROFILING IS OFF: a comparison and a tail call, no C++ crossing,
-- | which is why it can sit on the hottest functions.
-- |
-- | @details While on, every return value comes back with its arity and embedded nils intact
-- |          (call_traced). There is no pcall: an error skips the scope's end, and
-- |          perf_composer.h bounds that damage to the frame that threw.
-- |
-- | @param name  string - the scope's name in the report, "lua.<function>" by convention
-- | @param fn    function - left untouched
-- | @return function - the wrapper; `fn` itself when the profiler is not registered
-- |
-- | @date 2026-09-13 18:15
--]]
function prof.wrap(name, fn)
    return function(...)
        if not enabled then
            return fn(...)
        end
        return call_traced(name, fn, ...)
    end
end

--[[ @brief Opens a named scope for a PHASE that is not a single function.
-- |
-- | EVERY BEGIN NEEDS ITS STOP on every path out, which is why wrap() is preferred wherever a
-- | function boundary exists. Nothing is recorded while timing is off.
-- |
-- | @param name  string - the scope's name; stop(name) must pass the same one
-- |
-- | @date 2026-09-13 18:15
--]]
function prof.begin(name)
    if enabled then
        vc.prof_begin(name)
    end
end

--[[ @brief Closes the scope prof.begin(name) opened.
-- |
-- | @param name  string - the same name begin was given
-- |
-- | @note Checks `enabled` again rather than remembering begin's answer: switching timing on
-- |       between a begin and its stop sends a stop with no begin to perf_composer.h.
-- |
-- | @date 2026-09-13 18:15
--]]
function prof.stop(name)
    if enabled then
        vc.prof_end(name)
    end
end

--[[ @brief Tags the current frame with something that happened in it.
-- |
-- | THE HALF THAT TURNS A TIMING REPORT INTO A DIAGNOSIS: "frame took 38ms" plus "events:
-- | key:Backspace undo" says what to go and look at, where the timings alone only say where the
-- | time went. Nothing is recorded while timing is off.
-- |
-- | @param name  string - the tag, e.g. "key:Backspace"
-- |
-- | @date 2026-09-13 18:15
--]]
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

--[[ @brief Shows or hides the profiler PANEL, despite the name.
-- |
-- | TURNING IT OFF DOES NOT STOP A RUNNING RECORDING - the whole point of the recording mode is to
-- | leave it on with the panel hidden. Timing is recomputed as "panel OR recording".
-- |
-- | @param on  boolean - any truthy value shows it
-- |
-- | @date 2026-09-13 18:15
--]]
function prof.set_enabled(on)
    overlay = on and true or false
    refresh()
end

--[[ @brief Whether timing is being collected right now - for the panel OR a recording.
-- |
-- | @return boolean - NOT whether the panel is shown; that is overlay_visible
-- |
-- | @date 2026-09-13 18:15
--]]
function prof.enabled()
    return enabled
end

--[[ @brief Whether the profiler PANEL should be drawn - what content.lua asks.
-- |
-- | DISTINCT FROM enabled(), which is true while timing is collected for any reason: a spike
-- | recording collects with this false, which is the whole point.
-- |
-- | @return boolean - what set_enabled last set
-- |
-- | @date 2026-09-13 18:15
--]]
function prof.overlay_visible()
    return overlay
end

--[[ @brief Clears the worst-frame record.
-- |
-- | So the next spike is measured against a fresh high-water mark rather than against something
-- | that already happened.
-- |
-- | @date 2026-09-13 18:15
--]]
function prof.reset()
    vc.prof_reset()
end

--[[ @brief The formatted report, already sorted and laid out in C++.
-- |
-- | THE OVERLAY ONLY SPLITS IT ON NEWLINES, so "what a millisecond means" is decided in exactly one
-- | place.
-- |
-- | @return string - multi-line text
-- |
-- | @date 2026-09-13 18:15
--]]
function prof.report()
    return vc.prof_report()
end

--[[ @brief The profiler's own clock, in milliseconds.
-- |
-- | FOR A ONE-OFF MEASUREMENT that does not deserve a named scope: a caller timing something by
-- | hand reads the same clock the frame breakdown does, rather than a second one that drifts
-- | against it. Works whether or not timing is on.
-- |
-- | @return number - milliseconds, from an arbitrary origin; only differences mean anything
-- |
-- | @date 2026-09-13 18:15
--]]
function prof.now_ms()
    return vc.prof_now_ms()
end

--[[ @brief Starts a spike recording: every frame slower than `threshold_ms` goes to `path`.
-- |
-- | INDEPENDENT OF THE OVERLAY ON PURPOSE. The overlay costs real milliseconds and has itself been
-- | the biggest single item in a spike frame, so watching for spikes with it on measures the
-- | watching. This is the mode to hunt a lag in: recording on, overlay off, use the app normally,
-- | read the file afterwards.
-- |
-- | TIMING TURNS ON BY ITSELF, since recording with it off would silently write nothing.
-- |
-- | @details Each frame is written with its full breakdown and event tags, appending across runs
-- |          (perf_composer.h).
-- |
-- | @param path          string | nil - defaults to "perf_spikes.log". The data prefix is the
-- |                      caller's to add, as content.lua does, so --test writes under test_run/
-- | @param threshold_ms  number | nil - defaults to 25
-- |
-- | @date 2026-09-13 18:15
--]]
function prof.record_start(path, threshold_ms)
    vc.prof_record_start(path or "perf_spikes.log", threshold_ms or 25.0)
    refresh()
end

--[[ @brief Ends a spike recording and closes its file.
-- |
-- | Timing goes back to following the panel alone.
-- |
-- | @date 2026-09-13 18:15
--]]
function prof.record_stop()
    vc.prof_record_stop()
    refresh()
end

--[[ @brief Whether a spike recording is running.
-- |
-- | The overlay says so, since the mode is deliberately invisible otherwise.
-- |
-- | @return boolean
-- |
-- | @date 2026-09-13 18:15
--]]
function prof.recording()
    return vc.prof_recording()
end

--[[ @brief How many frames the spike recording has written so far.
-- |
-- | WHAT THE OVERLAY SHOWS TO SAY A RECORDING IS DOING SOMETHING: a threshold set too high records
-- | nothing, and without a count that is indistinguishable from a recording that never started.
-- |
-- | @return integer
-- |
-- | @date 2026-09-13 18:15
--]]
function prof.spike_count()
    return vc.prof_spike_count()
end

return prof

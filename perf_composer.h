#ifndef PERF_COMPOSER_H
#define PERF_COMPOSER_H

/*!
 * perf_composer.h - a frame-scoped, name-keyed wall-clock profiler for both the C++ layout/draw
 * code and the Lua editor on top of it.
 *
 * Built 2026-09-05 for one specific question: "the thing starts to lag" - which frame, and what was
 * happening in it. The lag is OBSERVABLE, i.e. milliseconds, so ms is the unit everything is
 * reported in; timing is taken in nanoseconds internally purely so that a 0.05ms call made 400
 * times still adds up to a visible 20ms rather than rounding away to nothing.
 *
 * Three things it does that a plain timer doesn't:
 *
 *   - Per-FRAME accounting. Totals reset at each prof_frame(), so a report is "what this frame
 *     cost", not an average smeared across a session in which the lag happened twice.
 *   - A WORST-frame snapshot. The whole point is a spike, and a spike is gone by the time anyone
 *     can read a live overlay. prof_frame() keeps a full copy of the breakdown for the slowest
 *     frame seen since the last prof_reset(), so the spike can be read at leisure afterwards.
 *   - EVENT tags. prof_event("key:backspace") marks the frame it happened in, and those tags are
 *     kept with the worst-frame snapshot - which is what actually links a spike to the thing that
 *     caused it, rather than leaving it to be guessed from the timings alone.
 *
 * COST OF MEASURING. The scope names cross the Lua boundary as `const char *`, pointing straight at
 * Lua's own interned string - taking them as `std::string` by value cost a string construction per
 * call, twice per wrapped call, which was enough to dominate any small function being measured (an
 * instrumented mexpru.u() reported 27us per call for what is a registry lookup). Even so, a scope
 * is two boundary crossings plus a hash lookup: do NOT wrap anything called thousands of times per
 * frame, or the report will mostly describe the profiler.
 *
 * Disabled by default: prof_enabled() is a plain bool read, and every entry point returns
 * immediately when off. The Lua wrapper (scripts/prof.lua) additionally checks a Lua-side flag
 * first, so a disabled profiler does not even cross the C++ boundary.
 *
 * Totals are INCLUSIVE of nested scopes. A name-keyed profiler cannot honestly report exclusive
 * time, so it does not pretend to: reading "editor.draw 14ms" and "mexpr_draw 9ms" means the second
 * is part of the first. Recursion is handled by a depth counter per name - only the OUTERMOST
 * interval is counted, so a self-recursive tree walk reports its real wall time once instead of
 * once per node.
 */

#include "virt_composer.h"

#include <chrono>
#include <string>
#include <unordered_map>
#include <vector>
#include <algorithm>
#include <cstdio>

namespace perf_composer {

namespace vc = virt_composer;
namespace perfc = perf_composer;

struct prof_entry_t {
    uint64_t total_ns = 0;
    uint64_t max_ns   = 0;   /* the worst SINGLE call, not the worst frame */
    uint32_t count    = 0;
    /* >0 while inside a call. Only a 0 -> 1 transition starts the clock and only 1 -> 0 stops it,
    which is what keeps a recursive walk from counting its own nested frames. */
    uint32_t depth    = 0;
    uint64_t started_ns = 0;
};

struct prof_frame_t {
    std::unordered_map<std::string, prof_entry_t> entries;
    std::vector<std::string> events;
    uint64_t wall_ns = 0;   /*!< the whole frame, INCLUDING the vsync wait */
    uint64_t work_ns = 0;   /*!< wall minus the idle scope - see PROF_IDLE_SCOPE */
};

/*! The scope that BLOCKS on vsync. Its time is the frame waiting, not the app working, so it is
subtracted out of work_ns and everything that judges a frame is judged on work.

This is not a detail. Wall time on a vsync-locked app is ~16.7ms (or a multiple) almost regardless
of what the code does, so "frames over 25ms" mostly counts frames that MISSED a vsync and then sat
idle waiting for the next one - and a spike log keyed on it reads as though the app were busy when
it was asleep. Caught 2026-09-05 by the observation that the real window holds a steady 60fps while
this was reporting every frame as a 33ms "spike". */
#define PROF_IDLE_SCOPE "cpp.imgui_render"

/*! Spike recording. A worst-frame snapshot in memory answers "how bad does it get", but not "how
often, and doing what" - and it dies with the process, so a spike noticed while using the app is
gone before it can be looked at. Every frame whose WORK time (see PROF_IDLE_SCOPE - not wall time,
which on a vsync-locked app is mostly the display's opinion) exceeds the threshold is appended here
instead, with its full breakdown and its event tags, and flushed immediately so a crash or a kill
still leaves the evidence on disk.

Deliberately independent of the overlay: the overlay costs real milliseconds (it formats a few dozen
lines and issues an AddText per line) and has itself been the largest thing in a spike frame, so
hunting spikes with it on measures the wrong thing. Recording needs no overlay at all. */
inline FILE       *g_rec = nullptr;
inline double      g_rec_threshold_ms = 25.0;
inline uint64_t    g_rec_spikes = 0;

inline bool         g_prof_on = false;
inline prof_frame_t g_cur;               /* accumulating, this frame */
inline prof_frame_t g_last;              /* the frame that just ended */
inline prof_frame_t g_worst;             /* the slowest frame since the last reset */
inline uint64_t     g_frame_start_ns = 0;
inline uint64_t     g_frame_count = 0;

inline uint64_t prof_now_ns() {
    using namespace std::chrono;
    return (uint64_t)duration_cast<nanoseconds>(steady_clock::now().time_since_epoch()).count();
}

/*! Milliseconds as a double, straight off the same clock everything else here uses. Exposed to Lua
 * on its own so ad-hoc "how long did this take" measurements don't need a named scope. */
inline double prof_now_ms() {
    return (double)prof_now_ns() / 1e6;
}

inline void prof_enable(bool on) {
    g_prof_on = on;
    if (on)
        g_frame_start_ns = prof_now_ns();
}

inline bool prof_enabled() { return g_prof_on; }

inline void prof_begin(const char *name) {
    if (!g_prof_on)
        return;
    auto &e = g_cur.entries[name];
    if (e.depth++ == 0)
        e.started_ns = prof_now_ns();
}

inline void prof_end(const char *name) {
    if (!g_prof_on)
        return;
    auto it = g_cur.entries.find(name);
    if (it == g_cur.entries.end() || it->second.depth == 0)
        return; /* end without a matching begin - ignored rather than made fatal */
    auto &e = it->second;
    if (--e.depth == 0) {
        uint64_t dt = prof_now_ns() - e.started_ns;
        e.total_ns += dt;
        e.max_ns = std::max(e.max_ns, dt);
        e.count++;
    }
}

/*! Tags the CURRENT frame with something that happened in it - a keystroke, an undo, a rebuild.
 * Kept with the worst-frame snapshot, which is what turns "frame 812 took 40ms" into "frame 812
 * took 40ms and it was a paste". */
inline void prof_event(const char *name) {
    if (!g_prof_on)
        return;
    g_cur.events.push_back(name);
}

inline std::string prof_format_frame(const prof_frame_t &f, const char *title);

/*! Starts appending every frame slower than `threshold_ms` to `path`. Append, not truncate, so a
 * session's spikes accumulate across restarts rather than the last run erasing the run that
 * actually showed the problem. Turns profiling on by itself - recording with the profiler off would
 * silently write nothing. */
inline void prof_record_start(const char *path, float threshold_ms) {
    if (g_rec)
        fclose(g_rec);
    g_rec = fopen(path, "a");
    g_rec_threshold_ms = threshold_ms > 0 ? threshold_ms : 25.0;
    g_rec_spikes = 0;
    if (g_rec) {
        fprintf(g_rec, "\n==== recording started, threshold %.1fms ====\n", g_rec_threshold_ms);
        fflush(g_rec);
        g_prof_on = true;
        g_frame_start_ns = prof_now_ns();
    }
}

inline void prof_record_stop() {
    if (g_rec) {
        fprintf(g_rec, "==== recording stopped, %llu spikes ====\n", (unsigned long long)g_rec_spikes);
        fclose(g_rec);
        g_rec = nullptr;
    }
}

inline bool prof_recording() { return g_rec != nullptr; }
inline int  prof_spike_count() { return (int)g_rec_spikes; }

/*! Frame boundary: rolls current -> last, keeps it as the new worst if it is, and clears. Also
 * measures the wall time since the previous call, which IS the frame time. */
inline void prof_frame() {
    if (!g_prof_on)
        return;
    uint64_t now = prof_now_ns();
    g_cur.wall_ns = (g_frame_start_ns != 0) ? (now - g_frame_start_ns) : 0;
    /* Work = everything except the block on vsync (PROF_IDLE_SCOPE). This is what a threshold
    should look at; wall time on a vsync-locked app says more about the display than the code. */
    uint64_t idle_ns = 0;
    if (auto it = g_cur.entries.find(PROF_IDLE_SCOPE); it != g_cur.entries.end())
        idle_ns = it->second.total_ns;
    g_cur.work_ns = (g_cur.wall_ns > idle_ns) ? (g_cur.wall_ns - idle_ns) : 0;
    g_frame_start_ns = now;
    g_frame_count++;

    /* Frame 1 spans everything before profiling was switched on - never a real spike. */
    if (g_rec && g_frame_count > 1 && (double)g_cur.work_ns / 1e6 > g_rec_threshold_ms) {
        g_rec_spikes++;
        std::string title = std::format("SPIKE #{} (frame {})", g_rec_spikes, g_frame_count);
        std::string body = prof_format_frame(g_cur, title.c_str());
        fwrite(body.data(), 1, body.size(), g_rec);
        fputc('\n', g_rec);
        fflush(g_rec); /* immediately - a spike is worth nothing if a crash eats it */
    }

    g_last = g_cur;
    /* Frame 1's wall time spans everything before profiling was switched on, so it is always the
    "worst" and would permanently mask the real spike. Skipped. */
    if (g_frame_count > 1 && g_cur.work_ns > g_worst.work_ns)
        g_worst = g_cur;

    g_cur.entries.clear();
    g_cur.events.clear();
}

inline void prof_reset() {
    g_worst = prof_frame_t{};
    g_last = prof_frame_t{};
    g_cur = prof_frame_t{};
    g_frame_count = 0;
    g_frame_start_ns = prof_now_ns();
}

inline std::string prof_format_frame(const prof_frame_t &f, const char *title) {
    std::string out = std::format("{}  frame {:.2f}ms\n", title, (double)f.wall_ns / 1e6);
    if (!f.events.empty()) {
        out += "  events:";
        for (auto &ev : f.events)
            out += " " + ev;
        out += "\n";
    }
    std::vector<std::pair<std::string, prof_entry_t>> rows(f.entries.begin(), f.entries.end());
    std::sort(rows.begin(), rows.end(), [](auto &a, auto &b) {
        return a.second.total_ns > b.second.total_ns;
    });
    for (auto &[name, e] : rows) {
        out += std::format("  {:<28} {:>8.2f}ms  n={:<6} max={:.2f}ms\n", name,
                (double)e.total_ns / 1e6, e.count, (double)e.max_ns / 1e6);
    }
    return out;
}

/*! The whole report as text, sorted by total time descending. A string rather than a table of
 * records purely to stay inside what luaw_function_wrapper already marshals cleanly - the only
 * consumer is an overlay that draws it line by line. */
inline std::string prof_report() {
    if (!g_prof_on)
        return "profiler off (F2)";
    return prof_format_frame(g_last, "LAST") + "\n" + prof_format_frame(g_worst, "WORST");
}

inline int register_meta(vc::virt_state_t *vs) {
    DBG_SCOPE();

    std::vector<luaL_Reg> perf_tab_funcs = {
        {"prof_enable",  vc::luaw_function_wrapper<prof_enable, bool>},
        {"prof_enabled", vc::luaw_function_wrapper<prof_enabled>},
        {"prof_begin",   vc::luaw_function_wrapper<prof_begin, const char *>},
        {"prof_end",     vc::luaw_function_wrapper<prof_end, const char *>},
        {"prof_event",   vc::luaw_function_wrapper<prof_event, const char *>},
        {"prof_frame",   vc::luaw_function_wrapper<prof_frame>},
        {"prof_reset",   vc::luaw_function_wrapper<prof_reset>},
        {"prof_report",  vc::luaw_function_wrapper<prof_report>},
        {"prof_now_ms",  vc::luaw_function_wrapper<prof_now_ms>},
        {"prof_record_start", vc::luaw_function_wrapper<prof_record_start, const char *, float>},
        {"prof_record_stop",  vc::luaw_function_wrapper<prof_record_stop>},
        {"prof_recording",    vc::luaw_function_wrapper<prof_recording>},
        {"prof_spike_count",  vc::luaw_function_wrapper<prof_spike_count>},
    };

    ASSERT_FN(add_lua_tab_funcs(vs, perf_tab_funcs));

    return vc::VC_ERROR_OK;
}

/*! RAII scope for C++ call sites: PROF_SCOPE("mexpr_draw"). Compiles down to a bool read when the
 * profiler is off. */
struct prof_scope_t {
    const char *name;
    bool active;
    prof_scope_t(const char *n) : name(n), active(g_prof_on) {
        if (active)
            prof_begin(name);
    }
    ~prof_scope_t() {
        if (active)
            prof_end(name);
    }
};

} /* namespace perf_composer */

#define PROF_CONCAT_(a, b) a##b
#define PROF_CONCAT(a, b) PROF_CONCAT_(a, b)
#define PROF_SCOPE(name) perf_composer::prof_scope_t PROF_CONCAT(prof_scope_, __LINE__)(name)

#endif /* PERF_COMPOSER_H */

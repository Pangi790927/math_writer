#ifndef ASYNC_LOG_COMPOSER_H
#define ASYNC_LOG_COMPOSER_H

/*!
 * async_log_composer.h - a line log written by a background thread, so the frame never waits on IO.
 *
 * Built 2026-09-05 for input_recorder.lua (the flight recorder). That log had been flushed once per
 * written line, straight from the render thread; dropping the flush lost the whole buffer whenever
 * the process was killed, and a 1s periodic flush was only a compromise between the two. Writing
 * from another thread removes the trade entirely: the frame does an enqueue and nothing else, and
 * because the flush now happens somewhere that isn't the frame, it can go back to being per-line -
 * every event is durable the moment the writer picks it up, at no cost to the app at all.
 *
 * Ordering and shutdown. The queue is FIFO and there is exactly one writer, so lines land in the
 * order they were produced. alog_close() pushes a stop marker LAST and then joins: everything
 * already queued is written before the thread returns, so a normal exit waits for the log to finish
 * rather than truncating it ("keep the app for a bit until it finishes to write it's queue").
 *
 * force_push, never push. sync_queue_t::push() BLOCKS once the queue hits max_size - which would
 * put the render thread back to waiting on the log, the one thing this exists to prevent. Log lines
 * are short and rare (a keystroke, a click), so an unbounded queue costs nothing realistic, and
 * unbounded is strictly better than a frame stall.
 */

#include "virt_composer.h"
#include "sync_queue.h"

#include <atomic>
#include <cstdio>
#include <string>
#include <thread>

namespace async_log_composer {

namespace vc = virt_composer;
namespace alogc = async_log_composer;

struct alog_msg_t {
    bool stop = false;      /*!< the sentinel: drain what came before, then end the thread */
    std::string line;
};

inline sync_queue_t<alog_msg_t> *g_queue = nullptr;
inline std::thread              *g_thread = nullptr;
inline std::atomic<uint64_t>     g_written{0};

inline void alog_writer_main(FILE *f, sync_queue_t<alog_msg_t> *q) {
    while (true) {
        alog_msg_t msg;
        q->pop(msg); /* blocks until something arrives - no spinning, no polling interval */
        if (msg.stop)
            break;
        fwrite(msg.line.data(), 1, msg.line.size(), f);
        fputc('\n', f);
        /* Per line, deliberately. On this thread it costs the app nothing, and it means a kill
        loses at most whatever was still in flight rather than a whole file buffer. */
        fflush(f);
        g_written.fetch_add(1, std::memory_order_relaxed);
    }
    fclose(f);
}

/*! Opens `path` for append and starts the writer. Returns false if the file could not be opened, in
 * which case alog_write() is a no-op and the caller can fall back to whatever it likes. */
inline bool alog_open(const char *path) {
    if (g_thread)
        return true; /* already running - opening twice is a caller bug, not worth a second file */
    FILE *f = fopen(path, "a");
    if (!f)
        return false;
    g_queue = new sync_queue_t<alog_msg_t>();
    g_queue->max_size = SYNC_QUEUE_NOLIMIT_MAX_SZ; /* see this file's own force_push note */
    g_written.store(0, std::memory_order_relaxed);
    g_thread = new std::thread(alog_writer_main, f, g_queue);
    return true;
}

/*! Enqueue one line. Never blocks, never touches the file, never syscalls - the whole point. */
inline void alog_write(const char *line) {
    if (!g_queue || !line)
        return;
    g_queue->force_push(alog_msg_t{.stop = false, .line = std::string(line)});
}

/*! How many lines are still waiting to be written. Only meaningful as a debugging read - by the
 * time a caller acts on it the writer has probably moved on. */
inline int alog_pending() {
    return g_queue ? (int)g_queue->size() : 0;
}

inline int alog_written() {
    return (int)g_written.load(std::memory_order_relaxed);
}

/*! Drains and stops: pushes the stop marker behind everything already queued, then JOINS. Blocking
 * here is intentional and is the one place this file is allowed to block - it is what makes a
 * normal exit wait for the log to be complete instead of killing the writer mid-queue. Safe to call
 * twice; safe to call having never opened. */
inline void alog_close() {
    if (!g_thread)
        return;
    g_queue->force_push(alog_msg_t{.stop = true, .line = {}});
    g_thread->join();
    delete g_thread;
    g_thread = nullptr;
    delete g_queue;
    g_queue = nullptr;
}

inline int register_meta(vc::virt_state_t *vs) {
    DBG_SCOPE();

    std::vector<luaL_Reg> alog_tab_funcs = {
        {"alog_open",    vc::luaw_function_wrapper<alog_open, const char *>},
        {"alog_write",   vc::luaw_function_wrapper<alog_write, const char *>},
        {"alog_pending", vc::luaw_function_wrapper<alog_pending>},
        {"alog_written", vc::luaw_function_wrapper<alog_written>},
        {"alog_close",   vc::luaw_function_wrapper<alog_close>},
    };

    ASSERT_FN(add_lua_tab_funcs(vs, alog_tab_funcs));

    return vc::VC_ERROR_OK;
}

} /* namespace async_log_composer */

#endif /* ASYNC_LOG_COMPOSER_H */

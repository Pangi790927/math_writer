#ifndef DEBUG_INPUT_PIPE_H
#define DEBUG_INPUT_PIPE_H

/*! DEBUG-ONLY, explicitly not for production use.
 *
 * Simulates ImGui input (keyboard, text, mouse) fed from a local TCP socket, instead of the real
 * OS mouse/keyboard - so an external controller (an AI agent, a test script, whatever) can drive
 * this app's UI without touching the developer's actual input devices or stealing window focus.
 *
 * Listens on 127.0.0.1 only, plaintext line protocol, no auth. See debug_input_pipe.cpp for the
 * command list.
 *
 * NOTE: this is 3 functions, not 2 - init()/uninit() alone turned out not to be enough.
 * ImGui::GetIO() (and the various io.AddXxxEvent calls) asserts "No current context" when called
 * from any thread other than the one that owns the ImGui context (GImGui is a plain, non-atomic
 * global - writing io state from a second thread while the main thread may be mid-NewFrame() is a
 * real, reproducible crash, not a theoretical one). So the background thread here only reads the
 * socket and queues parsed commands; pump() - called once per frame from the main loop - is what
 * actually applies them to ImGui, on the main thread.
 */
namespace debug_input_pipe {

/*! Starts listening on a background thread. Call once, after the ImGui context exists.
 * @return 0 on success. */
int init();

/*! Applies any commands received since the last call, by calling into ImGui. Must be called once
 * per frame, from the main thread, before ImGui::NewFrame() (e.g. right after
 * glfwPollEvents()). */
void pump();

/*! Stops the listener/background thread and closes any open sockets. Call once, before ImGui
 * context teardown. */
void uninit();

/*! DEBUG-ONLY, opt-in via VC_WINDOW_START_HIDDEN. Hides the console window (this is a
 * console-subsystem build, so one always gets allocated) - same "keep it off the developer's
 * screen during automated driving" reason this whole module exists for. No-op unless the env var
 * is set (and a no-op on non-Windows, where there's no console window to hide).
 *
 * Call once, as early as possible in main() - before imgui_init(), so nothing has a chance to
 * flash on screen first. */
void hide_console();

/*! DEBUG-ONLY, opt-in via VC_WINDOW_START_HIDDEN (see imgui_helpers.h's own comment on that env
 * var - it's what makes imgui_init() create the window hidden in the first place). Moves the
 * window to MATH_WRITER_DEV_WINDOW_POS ("X,Y") if given, then reveals it. This is the only place
 * the window becomes visible in that mode, so there's no flash at the default position first.
 * No-op unless VC_WINDOW_START_HIDDEN is set.
 *
 * Call once, right after imgui_init(). */
void reveal_window();

} /* namespace debug_input_pipe */

#endif

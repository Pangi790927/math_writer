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

/*! The two ports this module can listen on, and why there are two.
 *
 * TEST_PORT is the automated one: a --test instance binds it at startup and a session's tooling
 * connects to it. USER_PORT is the one a PRESENTATION instance opens when its owner arms it by
 * hand (Ctrl+Shift+D).
 *
 * They are deliberately different, added 2026-09-07 after the single shared port caused exactly
 * the collision it invites: a session's --test instance held 47821, so the developer's own
 * instance could not bind when they armed it, and - because the arming path ignored init()'s
 * result at the time - it reported the pipe open when nothing was listening. Two ports means the
 * two never compete for the same resource, and a test run can no longer take the developer's
 * link away from them. */
constexpr unsigned short TEST_PORT = 47821;
constexpr unsigned short USER_PORT = 47822;

/*! Starts listening on a background thread. Call once, after the ImGui context exists.
 * @param port which port to bind - TEST_PORT for an automated run, USER_PORT for a hand-armed
 *        presentation instance.
 * @return 0 on success. */
int init(unsigned short port = TEST_PORT);

/*! The port currently being listened on, or 0 when not listening. */
unsigned short listening_port();

/*! Applies any commands received since the last call, by calling into ImGui. Must be called once
 * per frame, from the main thread, before ImGui::NewFrame() (e.g. right after
 * glfwPollEvents()). */
void pump();

/*! Stops the listener/background thread and closes any open sockets. Call once, before ImGui
 * context teardown.
 *
 * Also the "disarm" half of the on-demand model below: init()/uninit() are symmetric and may be
 * called repeatedly, so the pipe can be opened and closed again during one run. */
void uninit();

/*! Whether the listener is currently accepting connections.
 *
 * ON-DEMAND ARMING, added 2026-09-07 on request. The presentation instance deliberately does NOT
 * listen at startup - main.cpp only calls init() under --test, because a person's own editor
 * should not be sitting on an open port while they work, and an agent connected to it could
 * interfere with what they are doing. But when something breaks, being able to hand that same
 * instance over for inspection is worth a great deal: the broken state is right there, and
 * reproducing it in a separate --test run is often the hard part.
 *
 * So the presentation instance can be ARMED by hand (see main.cpp's Ctrl+Shift+D). Nothing is
 * listening until the person at the keyboard asks for it, and the same key closes the socket
 * again. This function exists so the app can show whether it is armed - an open port that nobody
 * can see is exactly the thing not to build. */
bool is_listening();

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
 * window to MATH_WRITER_DEV_WINDOW_POS ("X,Y") if given, then reveals it (via the native Win32
 * API with SW_SHOWNOACTIVATE, not glfwShowWindow() - so revealing it never steals focus either).
 * This is the only place the window becomes visible in that mode, so there's no flash at the
 * default position first. No-op unless VC_WINDOW_START_HIDDEN is set.
 *
 * If VC_WINDOW_STAY_HIDDEN is ALSO set, the window is never revealed at all - stays hidden for
 * the app's whole lifetime (it still renders every frame regardless, glfwSwapBuffers() doesn't
 * care about visibility). Use the "screenshot <path>" debug_input_pipe command (see .cpp) to see
 * what's on screen instead - fully headless automated driving, nothing ever touches the
 * developer's screen or focus at all.
 *
 * Call once, right after imgui_init(). */
void reveal_window();

} /* namespace debug_input_pipe */

#endif

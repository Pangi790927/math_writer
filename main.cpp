#define NOMINMAX
#define IMGUI_DEFINE_MATH_OPERATORS

#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <filesystem>

#include "imgui_helpers.h"
#include "imgui_internal.h"

/* composer plugins: */
#include "char_draw_composer.h"
#include "math_expr_composer.h"
#include "imgui_composer.h"
#include "app_mode.h"
#include "perf_composer.h"
#include "async_log_composer.h"
#include "virt_composer_end.h"

#include "debug.h"
#include "debug_input_pipe.h"

/*! TODO: rework this:
 * 
 * - Mathematical objects or objects in general will have mathematical object files that will again
 * give them namespaces and names. Those will also have a small drawing rules description, maybe a
 * lua script that will explain how to draw them. Most importantly, those description will contain
 * diverse rules of composition: number of parameters and things like asociativness with other
 * objects. ---- in LUA
 * 
 * As such, all the hardcoded behaviours should be scripted from now on. */

/*!
 * TAKE 3
 * 
 * Ok, so the first two attempts are not good, they are overly complicated and hard to
 * serialize, hard to transform, etc.
 * 
 * I want to have a third try in which:
 * 1. All actions must be made clear, ie the structure must be made such that ctrl+z, ctrl+shift+z
 * will work
 * 2. The ast node will be much simpler, encoded as tuples: (type, args...) where args can be
 * anything, depending on the type
 * 
 * tuples:
 * _ID:(...)                    -- tuple with it's id, each tupple will have such an ID 
 * (=, a1, a2)                  -- equality
 * (<, a1, a2)                  -- inequality (and all others <, <=. >=, >, !=)
 * (+, a1, a2, a3, ...)         -- sum of elements
 * (*, a1, a2, a3, ...)         -- product of elements
 * (/, a1, a2)                  -- division
 * (^, a1, a2)                  -- exponentiation
 * (N, m, n, sign)              -- rational/natural number m/n
 * (@, f, a1, a2, a3, ...)      -- function call
 * (#, name)                    -- named variable
 * (V, a1, a2, a3, ...)         -- vector
 * (M, m, n, a1, ... a[m+n])    -- matrix
 * (_, a1)                      -- paranthesis
 * ...                          -- other custom ones to be thought about later?
 * 
 * -- bigops are special forms of functions, example sum (@, sum, k, 0, N, expr)
 * -- there are a lot of implicit functions
 * -- functions decide how the thing is drawn, for example a_n is a function of integer parameter n
 * -- = is used to corelate var, functions and other with other expressions (sure?)
 * 
 * 
 * !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!! SOOOOOO:
 * Steps are:
 * 1. write those above in lua, ie the AST moves to lua, with operators =, <, +, ... defined inside
 * lua
 * 2. render those operators moving the rendering stuff inside lua partially, ie, I want mathd to
 * have a lua counterpart
 * 3. implement two main operations: move around sumation elements, product elements
 * 4. see what else can be implemented for each operator type
 * 5. 3 and 4 operations should be remembered in a queue and be reversible
 * 6. figure out gestures and such to do those operations
 * 7. finally implement the final product, with all the content boxes and save/load options
 *  
 */

namespace vc = virt_composer;
namespace charc = char_draw_composer;
namespace mexpr = math_expr_composer;
namespace imgc = imgui_composer;
namespace perfc = perf_composer;
namespace appm = app_mode;
namespace alogc = async_log_composer;

int main(int argc, char const *argv[])
{
    /*  PRESENTATION (no arguments) vs TESTING ("--test") - see app_mode.h for what each is and why
    they are kept apart. This block runs before ANYTHING else in main(): logger_init() only takes
    effect if nothing has logged yet (logger_log_autoinit() auto-inits on first use and then keeps
    that path forever), and hide_console() below is already a DBG-ing call. */
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--test") == 0)
            appm::set_testing(true);
        else
            printf("ignoring unknown argument: %s\n", argv[i]);
    }

    std::string ini_path = "imgui.ini";
    if (appm::app_is_testing()) {
        std::error_code ec;
        std::filesystem::create_directories(appm::TESTING_PREFIX, ec);
        logger_init((std::string(appm::TESTING_PREFIX) + "logfile").c_str());
        ini_path = std::string(appm::TESTING_PREFIX) + "imgui.ini";

        /*  --test implies a window that is never shown. The env vars remain the mechanism (they are
        read inside utils, by imgui_helpers.h and debug_input_pipe.cpp), but defaulting them here
        means a test instance cannot appear on screen just because a launcher forgot to set them -
        which is the one failure mode that actually costs the developer something. Set only if
        absent, so an explicit env var still wins. */
#if defined(_WIN32)
        if (!getenv("VC_WINDOW_START_HIDDEN")) _putenv_s("VC_WINDOW_START_HIDDEN", "1");
        if (!getenv("VC_WINDOW_STAY_HIDDEN"))  _putenv_s("VC_WINDOW_STAY_HIDDEN", "1");
#else
        setenv("VC_WINDOW_START_HIDDEN", "1", 0);
        setenv("VC_WINDOW_STAY_HIDDEN", "1", 0);
#endif
    }

    debug_input_pipe::hide_console();

    imgui_init();
    /*  Per-mode ImGui state, so a hidden test window cannot rewrite the layout of the real one.
    ImGui keeps the pointer rather than a copy, hence the long-lived std::string above. */
    ImGui::GetIO().IniFilename = ini_path.c_str();
    debug_input_pipe::reveal_window();

    ImVec4 clear_color = ImVec4(0.45f, 0.55f, 0.60f, 1.00f);

    ImGuiIO& io = ImGui::GetIO();
    io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
    io.WantTextInput = true;
    ImFont* font_default = io.Fonts->AddFontDefault();
    
    ImFontConfig config;
    config.MergeMode = true;

    /*  Building a Lua state happens TWICE - once here and once per Ctrl+R - so it is written
    once. A reload that registered a different set of composers than startup did would produce an
    app that behaves differently after the first reload than it did when launched, which is the
    worst possible thing for a key whose whole purpose is "try the change".

    Registering onto a fresh state is safe to repeat: set_lua_class_member() assigns into
    vs->lua_class_members (per-state, and empty in a new one) and add_internal_func() assigns into
    the one process-wide table there is (c_function_t::internal_funcs, see virt_composer.h) - both
    are map assignments, so a second call overwrites with the same thing rather than duplicating or
    refusing. Checked 2026-09-10 before the reload key was written. */
    /*  Returns int, not vc::err_e, because ASSERT_FN expands to `return -1` and err_e is an
    unscoped enum - int does not implicitly convert back to it, so an err_e return type would not
    compile. 0 is success here, as everywhere else ASSERT_FN is used. */
    auto build_lua_state = [&](std::shared_ptr<vc::virt_state_t>& out) -> int {
        out = vc::create_state();
        ASSERT_FN(CHK_PTR(out));
        ASSERT_FN(charc::register_meta(out.get()));
        ASSERT_FN(mexpr::register_meta(out.get()));
        ASSERT_FN(imgc::register_meta(out.get()));
        ASSERT_FN(perfc::register_meta(out.get()));
        ASSERT_FN(appm::register_meta(out.get()));
        ASSERT_FN(alogc::register_meta(out.get()));
        ASSERT_FN(vc::parse_config(out.get(), "math_writer.yaml"));
        return 0;
    };

    std::shared_ptr<vc::virt_state_t> vs;
    ASSERT_FN(build_lua_state(vs));
    ASSERT_FN(CHK_PTR(vs));

    imgui_prepare_render();
    imgui_render(clear_color);

    auto [ret, err] = vc::call_lua<int>(vs.get(), "test_init");
    ASSERT_FN(ret);
    ASSERT_FN(err);

    /* DEBUG-ONLY: lets an external controller drive keyboard/mouse via a local socket instead of
     * the real OS input devices - see debug_input_pipe.h. TESTING MODE ONLY: the presentation
     * instance must not listen at all. Two reasons, both real - its fixed port (47821) can only be
     * bound once, so whichever instance starts first silently disables the other's pipe; and a
     * person's own editor should not be accepting remote input in the first place. */
    if (appm::app_is_testing())
        debug_input_pipe::init(debug_input_pipe::TEST_PORT);

    while (!glfwWindowShouldClose(imgui_window)) {
        /* The four things the frame is made of besides Lua. Added 2026-09-05 after the spike log
        showed every frame at ~33ms while all the Lua scopes together accounted for only ~10 - i.e.
        two thirds of the frame was time no scope could see. Without these, "the app lags" and "the
        editor is slow" are indistinguishable. */
        { PROF_SCOPE("cpp.glfwPollEvents");
        glfwPollEvents(); }
        /* Ctrl+Q quits. It was ESCAPE until 2026-09-07, which was a real collision, not just an
        unfortunate choice: Escape is a MEANINGFUL in-app key in three places already - it leaves a
        formula embed (editor_text.lua), closes the radial new-box menu (content.lua's
        radial_handle_input) and puts the caret back in a definition's name slot
        (editor_definition.lua) - so pressing it to back out of a formula also closed the whole
        application. Q is free: Alt+Q is \partial and Alt+Shift+Q is \int, both a different
        modifier, and nothing anywhere binds Q with Ctrl (checked across all 92 key call sites).

        Still glfwGetKey(), i.e. still the REAL OS keyboard rather than ImGui's own state, and
        deliberately: this is the one exit that keeps working when the Lua side has thrown and
        test_draw() is erroring out every frame, which is exactly when you most need to get out.
        The consequence is unchanged from Escape's - it does NOT work from debug_input_pipe, whose
        injected keys only ever reach this process's own ImGui state (see debug_input_pipe.h), and
        a hidden window never receives the real events either. `quit` over the pipe remains the
        only clean headless exit; see CLAUDE.md's live-testing section. */
        if (glfwGetKey(imgui_window, GLFW_KEY_Q) == GLFW_PRESS
                && (glfwGetKey(imgui_window, GLFW_KEY_LEFT_CONTROL) == GLFW_PRESS
                    || glfwGetKey(imgui_window, GLFW_KEY_RIGHT_CONTROL) == GLFW_PRESS)) {
            glfwSetWindowShouldClose(imgui_window, GL_TRUE);
            continue ;
        }

        /*  TEMPORARY: Ctrl+R rebuilds the Lua state in place, so an edit to the scripts can be
        tried without leaving the window and starting the app again. Requested 2026-09-07 as a
        development convenience and meant to be deleted afterwards - this block and the
        build_lua_state lambda it shares with startup are all there is to it now.

        It used to re-exec the whole process, which needed <unistd.h> and a static copy of argv;
        both went with it on 2026-09-10, when it became a Lua-only reload. See the block below for
        why that is better than a restart and what it costs.

        In C++ beside Ctrl+Q rather than as a keymap action, and deliberately: the moment a reload
        is most wanted is right after a Lua change has broken something, which is precisely when a
        Lua-side binding would no longer fire. glfwGetKey reads the real keyboard and keeps working
        while test_draw() is throwing every frame.

        A full re-exec rather than rebuilding the Lua state in place, for two reasons: it picks up
        a rebuilt BINARY as well as changed scripts, and it cannot leave half-torn-down state
        behind - the process image is simply replaced. test_shutdown() runs first, so the document
        and the keymap are saved through the normal path and the reloaded instance opens on exactly
        what was on screen.

        `reload_armed` exists because the key is almost certainly still held when the new process
        starts: without it, the replacement would see Ctrl+R down on its first frame and re-exec
        immediately, forever. The new process therefore refuses to reload until it has seen the
        combination NOT pressed at least once. */
        bool ctrl_now = glfwGetKey(imgui_window, GLFW_KEY_LEFT_CONTROL) == GLFW_PRESS
                || glfwGetKey(imgui_window, GLFW_KEY_RIGHT_CONTROL) == GLFW_PRESS;

        /*  Ctrl+Shift+D hands this instance over for inspection, and takes it back.

        The presentation instance does NOT listen at startup - see the --test check further up,
        and its reasoning: a person's own editor should not sit on an open port while they work.
        This is the other half of that decision rather than a hole in it. Nothing is listening
        until the person at the keyboard asks, the same key closes it again, and the marker drawn
        below says which state it is in - an open port nobody can see is exactly the thing not to
        build. Requested 2026-09-07: "make it such that you can take control to inspect my app when
        I ask you only... that way you will not interfere with it when I'm using it, but when it
        breaks you can connect".

        glfwGetKey rather than the keymap, for the same reason as Ctrl+Q and Ctrl+R above: the
        moment this is wanted is usually the moment something has broken, which may well be the
        Lua side that a rebindable action would have to travel through.

        init()/uninit() are symmetric and may be called repeatedly (debug_input_pipe.h), so this
        is a genuine toggle rather than a one-way door. */
        static bool pipe_armed = false;
        bool pipe_combo = ctrl_now
                && glfwGetKey(imgui_window, GLFW_KEY_LEFT_SHIFT) == GLFW_PRESS
                && glfwGetKey(imgui_window, GLFW_KEY_D) == GLFW_PRESS;
        if (!pipe_combo)
            pipe_armed = true;
        else if (pipe_armed) {
            pipe_armed = false;
            if (debug_input_pipe::is_listening()) {
                debug_input_pipe::uninit();
                DBG("Ctrl+Shift+D: debug pipe CLOSED");
            } else {
                /*  CHECK THE RESULT. This said "OPEN" unconditionally and lied outright the first
                time it mattered: another instance already held 127.0.0.1:47821, bind() failed, and
                the app cheerfully reported the pipe was open - so the person pressed it twice,
                believed it both times, and nothing was listening. The port is a fixed single
                resource (see main.cpp's own note on why only one instance may hold it), so
                "already taken" is an ordinary outcome here, not an unlikely one. */
                /*  Braces here are style, not necessity - they were necessity until
                2026-09-10, when DBG_RAW stopped baking a ";" into itself (see debug.h). A
                braceless if/else around a DBG compiles now. */
                /*  USER_PORT, not the test one. A session's --test instance owns TEST_PORT for
                as long as it runs, and sharing a single port meant the two competed for it - the
                developer's own instance could silently lose the race and be told otherwise (see
                debug_input_pipe.h's note on why there are two). On its own port this arming
                cannot be taken away by anything a test run does. */
                if (debug_input_pipe::init(debug_input_pipe::USER_PORT) == 0
                        && debug_input_pipe::is_listening()) {
                    DBG("Ctrl+Shift+D: debug pipe OPEN on port %d - this instance can now be driven",
                            (int)debug_input_pipe::USER_PORT);
                } else {
                    DBG("Ctrl+Shift+D: debug pipe FAILED to open - is another instance holding "
                            "127.0.0.1:%d?", (int)debug_input_pipe::USER_PORT);
                }
            }
        }

        static bool reload_armed = false;
        bool reload_combo = ctrl_now && glfwGetKey(imgui_window, GLFW_KEY_R) == GLFW_PRESS;
        if (!reload_combo)
            reload_armed = true;
        else if (reload_armed) {
            /*  RELOADS THE LUA SIDE ONLY, in place: the window, the GL context, ImGui, the async
            log thread and the debug pipe all stay exactly as they are, and only the Lua state is
            torn down and rebuilt. That is what makes this instant and flicker-free, and it is why
            it replaced an execv() re-exec of the whole process (which was POSIX-only, so on
            Windows Ctrl+R saved the document and then did nothing at all).

            THE PRICE, and it is deliberate: a rebuilt BINARY is not picked up, only changed
            scripts. Confirmed as fine 2026-09-10 - a C++ change means rebuilding, which means
            relaunching anyway.

            The document survives because the two calls bracket the teardown exactly as startup and
            shutdown do: test_shutdown writes math_writer.save (and the keymap), the new state's
            test_init reads it straight back, so the reloaded instance opens on what was on screen.

            NOTHING C++ MAY HOLD ACROSS THIS LINE. Destroying the old state closes its lua_State,
            and virt_composer.h is explicit that any vc::object_t/ref_t obtained from a state dies
            with it - unenforced, so a stale one is a use-after-free rather than an error. Checked
            when this was written: main() holds only `vs` itself, and none of the six composers
            caches a ref_t or lua_State* between calls. Anything added later that does must be
            rebuilt here too. */
            DBG("Ctrl+R: saving and reloading the Lua state");
            vc::call_lua<int>(vs.get(), "test_shutdown");

            /*  Into a SEPARATE pointer, and only swapped in once it is fully built: a half-built
            state assigned over `vs` would leave the frame loop calling test_draw on it. If the
            rebuild fails the old state is already gone (the save above ran), so it says so loudly
            and carries on with a state that cannot draw - rather than pretending. */
            std::shared_ptr<vc::virt_state_t> fresh;
            if (build_lua_state(fresh) == 0 && fresh) {
                vs = fresh;
                auto [rel_ret, rel_err] = vc::call_lua<int>(vs.get(), "test_init");
                /*  Braced by choice. This is where the DBG_RAW bug was found: the macro used
                to end in "));", so `DBG(x);` was the call plus a stray empty statement and this
                else had no if (C2181). Fixed in debug.h the same day - do/while(0), no baked-in
                semicolon - so the braces are now ordinary style rather than a workaround. */
                if (rel_ret < 0 || rel_err < 0) {
                    DBG("Ctrl+R: test_init failed after reload");
                }
                else {
                    DBG("Ctrl+R: Lua reloaded");
                }
            }
            else {
                DBG("Ctrl+R: rebuild FAILED - the scripts are probably not parseable");
            }
            reload_armed = false;
        }

        /*  Gated on the LISTENER, not on the mode. It was app_is_testing(), which was right while
        the pipe could only ever be open under --test - and became the missing half of Ctrl+Shift+D
        the moment a presentation instance could arm one: the background thread accepted the
        connection and queued every command, and nothing ever applied them, so the pipe looked
        alive from outside and did absolutely nothing. Found by using it (2026-09-07).

        is_listening() covers both cases by construction: --test arms at startup, a person arms by
        hand, and either way the queue is drained on the main thread exactly as before. */
        if (debug_input_pipe::is_listening()) { PROF_SCOPE("cpp.input_pipe_pump");
        debug_input_pipe::pump(); }
        { PROF_SCOPE("cpp.imgui_prepare");
        imgui_prepare_render(); }

        auto main_flags = 
                ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize | ImGuiWindowFlags_NoMove;
        auto *io = &ImGui::GetIO();
        ImGui::SetNextWindowSize(ImVec2(io->DisplaySize.x, io->DisplaySize.y));
        ImGui::SetNextWindowPos(ImVec2(0, 0));
        ImGui::GetStyle().WindowRounding = 0.0f;

        ImGui::Begin("Math Editor", NULL, main_flags);

        /*  While the pipe is open, say so on screen. Drawn here rather than from Lua so it
        cannot be switched off, styled away or lost to a Lua error - the one thing this marker
        must never do is fail to appear while the port is in fact open. */
        if (debug_input_pipe::is_listening() && !appm::app_is_testing()) {
            ImGui::GetForegroundDrawList()->AddText(ImVec2(8, 8), IM_COL32(255, 90, 90, 255),
                    "DEBUG PIPE OPEN on 47822  (Ctrl+Shift+D to close)");
        }

        auto [ret, err] = [&]{ PROF_SCOPE("cpp.call_lua");
                return vc::call_lua<int>(vs.get(), "test_draw"); }();
        ASSERT_FN(ret);
        ASSERT_FN(err);

        // bool true_val = true;
        // ImGui::ShowMetricsWindow(&true_val);

        ImGui::End();

        /* Add imgui stuff here */
        { PROF_SCOPE("cpp.imgui_render");
        imgui_render(clear_color); }

        /* Frame boundary for the profiler (perf_composer.h). Here rather than at the end of Lua's
        own test_draw() so the measured frame includes glfwPollEvents, the input pump and
        imgui_render - a spike caused by one of those would otherwise show up as unexplained time
        that no Lua scope accounts for. A no-op while the profiler is off. */
        perfc::prof_frame();
    }

    /* Mirrors the test_init() call above, at the other end of the app's lifetime - lets
     * math_writer.lua save state (content.lua's serialize()) before the window actually goes
     * away. `vs` is still valid here (its own destruction happens later, when the enclosing
     * shared_ptr goes out of scope at the end of main()). */
    auto [shutdown_ret, shutdown_err] = vc::call_lua<int>(vs.get(), "test_shutdown");
    ASSERT_FN(shutdown_ret);
    ASSERT_FN(shutdown_err);

    /* Drains the async log's queue and joins its writer thread (async_log_composer.h). test_shutdown
    above normally does this itself via input_recorder.close(); this is the backstop for the paths
    where it doesn't - a Lua error in test_shutdown, or a future caller that forgets - because a
    detached writer thread outliving main() is a far worse outcome than one redundant no-op call. */
    alogc::alog_close();

    if (appm::app_is_testing())
        debug_input_pipe::uninit();
    imgui_uninit();
    return 0;
}

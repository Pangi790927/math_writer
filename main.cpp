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

    auto vs = vc::create_state();
    ASSERT_FN(CHK_PTR(vs));
    ASSERT_FN(charc::register_meta(vs.get()));
    ASSERT_FN(mexpr::register_meta(vs.get()));
    ASSERT_FN(imgc::register_meta(vs.get()));
    ASSERT_FN(perfc::register_meta(vs.get()));
    ASSERT_FN(appm::register_meta(vs.get()));
    ASSERT_FN(alogc::register_meta(vs.get()));
    ASSERT_FN(vc::parse_config(vs.get(), "math_writer.yaml"));

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
        debug_input_pipe::init();

    while (!glfwWindowShouldClose(imgui_window)) {
        /* The four things the frame is made of besides Lua. Added 2026-09-05 after the spike log
        showed every frame at ~33ms while all the Lua scopes together accounted for only ~10 - i.e.
        two thirds of the frame was time no scope could see. Without these, "the app lags" and "the
        editor is slow" are indistinguishable. */
        { PROF_SCOPE("cpp.glfwPollEvents");
        glfwPollEvents(); }
        if (glfwGetKey(imgui_window, GLFW_KEY_ESCAPE) == GLFW_PRESS) {
            glfwSetWindowShouldClose(imgui_window, GL_TRUE);
            continue ;
        }

        if (appm::app_is_testing()) { PROF_SCOPE("cpp.input_pipe_pump");
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

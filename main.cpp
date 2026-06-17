#define NOMINMAX
#define IMGUI_DEFINE_MATH_OPERATORS

#include "imgui_helpers.h"
#include "imgui_internal.h"

/* composer plugins: */
#include "char_draw_composer.h"
#include "virt_composer_end.h"

#include "debug.h"

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
namespace drawc = draw_composer;

int main(int argc, char const *argv[])
{
    imgui_init();
    ImVec4 clear_color = ImVec4(0.45f, 0.55f, 0.60f, 1.00f);

    ImGuiIO& io = ImGui::GetIO();
    io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
    io.WantTextInput = true;
    ImFont* font_default = io.Fonts->AddFontDefault();
    
    ImFontConfig config;
    config.MergeMode = true;

    auto vs = vc::create_state();
    ASSERT_FN(CHK_PTR(vs));
    ASSERT_FN(drawc::register_meta(vs.get()));
    ASSERT_FN(vc::parse_config(vs.get(), "math_writer.yaml"));

    imgui_prepare_render();
    imgui_render(clear_color);
        
    auto [ret, err] = vc::call_lua<int>(vs.get(), "test_init");
    ASSERT_FN(ret);
    ASSERT_FN(err);

    while (!glfwWindowShouldClose(imgui_window)) {
        glfwPollEvents();
        if (glfwGetKey(imgui_window, GLFW_KEY_ESCAPE) == GLFW_PRESS) {
            glfwSetWindowShouldClose(imgui_window, GL_TRUE);
            continue ;
        }

        imgui_prepare_render();

        auto main_flags = 
                ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize | ImGuiWindowFlags_NoMove;
        auto *io = &ImGui::GetIO();
        ImGui::SetNextWindowSize(ImVec2(io->DisplaySize.x, io->DisplaySize.y));
        ImGui::SetNextWindowPos(ImVec2(0, 0));
        ImGui::GetStyle().WindowRounding = 0.0f;

        ImGui::Begin("Math Editor", NULL, main_flags);

        auto [ret, err] = vc::call_lua<int>(vs.get(), "test_draw");
        ASSERT_FN(ret);
        ASSERT_FN(err);

        // content_draw();

        bool true_val = true;
        ImGui::ShowMetricsWindow(&true_val);

        ImGui::End();

        /* Add imgui stuff here */
        imgui_render(clear_color);
    }
    imgui_uninit();
    return 0;
}

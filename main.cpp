#define NOMINMAX
#define IMGUI_DEFINE_MATH_OPERATORS

#include "imgui_helpers.h"
#include "imgui_internal.h"

#include "debug.h"

/*! TODO: rework this:
 * 
 * - Maybe? Use the new vulkan-lua to rework interactions
 * - The fonts should be loaded from a font remapping file. This file will define characters, it
 * will clasify them (give them namespaces) and give them names.
 * - Mathematical objects or objects in general will have mathematical object files that will again
 * give them namespaces and names. Those will also have a small drawing rules description, maybe a
 * lua script that will explain how to draw them. Most importantly, those description will contain
 * diverse rules of composition: number of parameters and things like asociativness with other
 * objects.
 * 
 * As such, all the hardcoded behaviours should be scripted from now on. */

/*! TODO: do a file that extends vulkan composer and does the parsing stuff. */

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

    // ASSERT_FN(chars_init());
    // ASSERT_FN(content_init());
    // ASSERT_FN(comments_init());
    // ASSERT_FN(defines_init());
    // ASSERT_FN(formulas_init());

    imgui_prepare_render();
    // cboxes[0].obj = comments_create();
    // cboxes[1].obj = defines_create();
    // cboxes[2].obj = formulas_create();
    imgui_render(clear_color);

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

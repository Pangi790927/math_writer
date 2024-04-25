#include "imgui_helpers.h"

int main(int argc, char const *argv[]) {
    imgui_init();
    ImVec4 clear_color = ImVec4(0.45f, 0.55f, 0.60f, 1.00f);
    while (!glfwWindowShouldClose(imgui_window)) {
        glfwPollEvents();
        imgui_prepare_render();
        /* Add imgui stuff here */
        imgui_render(clear_color);
    }
    imgui_uninit();
    return 0;
}

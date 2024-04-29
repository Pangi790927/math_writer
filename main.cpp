#include "imgui_helpers.h"

#define NOVIZ true

const char *codes[] = {
    "\x00","\x01","\x02","\x03","\x04","\x05","\x06","\x07","\x08","\x09","\x0A","\x0B","\x0C","\x0D","\x0E","\x0F",
    "\x10","\x11","\x12","\x13","\x14","\x15","\x16","\x17","\x18","\x19","\x1A","\x1B","\x1C","\x1D","\x1E","\x1F",
    "\x20","\x21","\x22","\x23","\x24","\x25","\x26","\x27","\x28","\x29","\x2A","\x2B","\x2C","\x2D","\x2E","\x2F",
    "\x30","\x31","\x32","\x33","\x34","\x35","\x36","\x37","\x38","\x39","\x3A","\x3B","\x3C","\x3D","\x3E","\x3F",
    "\x40","\x41","\x42","\x43","\x44","\x45","\x46","\x47","\x48","\x49","\x4A","\x4B","\x4C","\x4D","\x4E","\x4F",
    "\x50","\x51","\x52","\x53","\x54","\x55","\x56","\x57","\x58","\x59","\x5A","\x5B","\x5C","\x5D","\x5E","\x5F",
    "\x60","\x61","\x62","\x63","\x64","\x65","\x66","\x67","\x68","\x69","\x6A","\x6B","\x6C","\x6D","\x6E","\x6F",
    "\x70","\x71","\x72","\x73","\x74","\x75","\x76","\x77","\x78","\x79","\x7A","\x7B","\x7C","\x7D","\x7E","\x7F",
    "\x80","\x81","\x82","\x83","\x84","\x85","\x86","\x87","\x88","\x89","\x8A","\x8B","\x8C","\x8D","\x8E","\x8F",
    "\x90","\x91","\x92","\x93","\x94","\x95","\x96","\x97","\x98","\x99","\x9A","\x9B","\x9C","\x9D","\x9E","\x9F",
    "\xA0","\xA1","\xA2","\xA3","\xA4","\xA5","\xA6","\xA7","\xA8","\xA9","\xAA","\xAB","\xAC","\xAD","\xAE","\xAF",
    "\xB0","\xB1","\xB2","\xB3","\xB4","\xB5","\xB6","\xB7","\xB8","\xB9","\xBA","\xBB","\xBC","\xBD","\xBE","\xBF",
    "\xC0","\xC1","\xC2","\xC3","\xC4","\xC5","\xC6","\xC7","\xC8","\xC9","\xCA","\xCB","\xCC","\xCD","\xCE","\xCF",
    "\xD0","\xD1","\xD2","\xD3","\xD4","\xD5","\xD6","\xD7","\xD8","\xD9","\xDA","\xDB","\xDC","\xDD","\xDE","\xDF",
    "\xE0","\xE1","\xE2","\xE3","\xE4","\xE5","\xE6","\xE7","\xE8","\xE9","\xEA","\xEB","\xEC","\xED","\xEE","\xEF",
    "\xF0","\xF1","\xF2","\xF3","\xF4","\xF5","\xF6","\xF7","\xF8","\xF9","\xFA","\xFB","\xFC","\xFD","\xFE","\xFF",
};

int main(int argc, char const *argv[]) {
    imgui_init();
    ImVec4 clear_color = ImVec4(0.45f, 0.55f, 0.60f, 1.00f);

    float size_pixels = 72;
    ImGuiIO& io = ImGui::GetIO();
    ImFont* font_default = io.Fonts->AddFontDefault();
    
    ImFontConfig config;
    config.OversampleH = 2;
    config.OversampleV = 1;
    config.GlyphExtraSpacing.x = 1.0f;

    ImFont* font1 = io.Fonts->AddFontFromFileTTF("fonts/cmbx10.ttf", size_pixels);
    ImFont* font2 = io.Fonts->AddFontFromFileTTF("fonts/cmex10.ttf", size_pixels);
    ImFont* font3 = io.Fonts->AddFontFromFileTTF("fonts/cmmi10.ttf", size_pixels);
    ImFont* font4 = io.Fonts->AddFontFromFileTTF("fonts/cmr10.ttf" , size_pixels);
    ImFont* font5 = io.Fonts->AddFontFromFileTTF("fonts/cmsy10.ttf", size_pixels);
    ImFont* font6 = io.Fonts->AddFontFromFileTTF("fonts/cmti10.ttf", size_pixels);
    ImFont* font7 = io.Fonts->AddFontFromFileTTF("fonts/cmtt10.ttf", size_pixels);
    // io.Fonts->Build();

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

        ImGui::Begin("Data aquisition", NULL, main_flags);

        auto font = font7;

        ImGui::PushFont(font);

        ImDrawList* draw_list = ImGui::GetWindowDrawList();

        static float sz = 36.0f;
        static float thickness = 1.0f;

        ImVec2 p1 = ImGui::GetCursorScreenPos();
        ImVec2 p2 = ImGui::GetMousePos();
        float th = thickness;

        ImVec4 col = ImVec4(1.0f, 1.0f, 0.4f, 1.0f);
        ImU32 col32 = ImColor(col);
        draw_list->AddLine(ImVec2(0, 0), ImVec2(0, 0), col32, th);

        float off_y = 0;
        float max_off_x = 0;
        p1 = ImGui::GetCursorScreenPos();
        for (int i = 0; i < 16; i++) {
            float off_x = 0;
            bool at_least_one = false;
            for (int j = 0; j < 16; j++) {
                int code = i*16 + j;

                float r = 1.;
                float g = 1.;
                float b = 1.;

                auto glyph = font->FindGlyphNoFallback(code);
                if (!glyph)
                    continue;

                at_least_one = true;
                if (!glyph->Visible)
                    r = 0;

                ImVec2 box_origin = ImVec2(p1.x + off_x, p1.y + off_y);

                ImVec2 box_bot = ImVec2(p1.x + glyph->X0 + off_x, p1.y + off_y + glyph->Y0);
                ImVec2 box_top = ImVec2(p1.x + glyph->X1 + off_x, p1.y + off_y + glyph->Y1);
                off_x += glyph->AdvanceX;


                /* OBS: RenderChar is the only method that works, for unknown reasons, maybe I can
                fix it? */
                font->RenderChar(draw_list, font->FontSize, box_origin, 0xff00ffff, code);

                // draw_list->AddText(font, font->FontSize, box_origin, 0xffff00ff, codes[code], NULL);

                col = ImVec4(r, g, b, 1.0f);
                ImU32 col32 = ImColor(col);
                draw_list->AddLine(ImVec2(box_bot.x, box_bot.y), ImVec2(box_top.x, box_bot.y), col32, th);
                draw_list->AddLine(ImVec2(box_top.x, box_bot.y), ImVec2(box_top.x, box_top.y), col32, th);
                draw_list->AddLine(ImVec2(box_top.x, box_top.y), ImVec2(box_bot.x, box_top.y), col32, th);
                draw_list->AddLine(ImVec2(box_bot.x, box_top.y), ImVec2(box_bot.x, box_bot.y), col32, th);

                // draw_list->AddLine(p1, ImVec2(p1.x, p1.y + 100), 0xffffff00, th);
                // draw_list->AddLine(p1, p2, col32, th);

                // draw_list->AddLine(ImVec2(p1.x - 100, p1.y), ImVec2(p1.x, p1.y), 0xffff0000);

                // draw_list->AddLine(ImVec2(p1.x - 10, p1.y + font->Ascent),
                //         ImVec2(p1.x + 10, p1.y + font->Ascent), 0xff00ff00, th);

                // draw_list->AddLine(ImVec2(p1.x + 10, p1.y + font->Ascent - font->Descent),
                //         ImVec2(p1.x - 10, p1.y + font->Ascent - font->Descent), 0xff0000ff, th);

            }
            if (at_least_one) {
                off_y += -font->Descent + font->Ascent;
            }
            max_off_x = std::max(max_off_x, off_x);
        }
        ImGui::Dummy(ImVec2(max_off_x, off_y));

        ImGui::PopFont();

        bool true_val = true;
        ImGui::ShowMetricsWindow(&true_val);

        ImGui::End();

        /* Add imgui stuff here */
        imgui_render(clear_color);
    }
    imgui_uninit();
    return 0;
}

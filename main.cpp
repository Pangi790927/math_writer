#define IMGUI_DEFINE_MATH_OPERATORS

#include "imgui_helpers.h"
#include "imgui_internal.h"
#include "misc_utils.h"

#include "fonts.h"
#include "comments.h"

/* TODO:
    -> Comment text
    -> Definition
    -> Add formula
    -> Add basic transformation as configurable maybe? (example: (a + b)^2 -> a^2 + 2ab + b^2)
 */

#define KEY_TOGGLE(key)                                                                             \
[]{                                                                                                 \
    static bool key_state = false;                                                                  \
    static bool toggle_state = false;                                                               \
    if (key_state == false && ImGui::IsKeyPressed(key)) {                                           \
        key_state = true;                                                                           \
        toggle_state = !toggle_state;                                                               \
    }                                                                                               \
    else if (ImGui::IsKeyReleased(key)) {                                                           \
        key_state = false;                                                                          \
    }                                                                                               \
    return toggle_state;                                                                            \
}()

// static const char *codes[] = {
//     "\x00","\x01","\x02","\x03","\x04","\x05","\x06","\x07","\x08","\x09","\x0A","\x0B","\x0C","\x0D","\x0E","\x0F",
//     "\x10","\x11","\x12","\x13","\x14","\x15","\x16","\x17","\x18","\x19","\x1A","\x1B","\x1C","\x1D","\x1E","\x1F",
//     "\x20","\x21","\x22","\x23","\x24","\x25","\x26","\x27","\x28","\x29","\x2A","\x2B","\x2C","\x2D","\x2E","\x2F",
//     "\x30","\x31","\x32","\x33","\x34","\x35","\x36","\x37","\x38","\x39","\x3A","\x3B","\x3C","\x3D","\x3E","\x3F",
//     "\x40","\x41","\x42","\x43","\x44","\x45","\x46","\x47","\x48","\x49","\x4A","\x4B","\x4C","\x4D","\x4E","\x4F",
//     "\x50","\x51","\x52","\x53","\x54","\x55","\x56","\x57","\x58","\x59","\x5A","\x5B","\x5C","\x5D","\x5E","\x5F",
//     "\x60","\x61","\x62","\x63","\x64","\x65","\x66","\x67","\x68","\x69","\x6A","\x6B","\x6C","\x6D","\x6E","\x6F",
//     "\x70","\x71","\x72","\x73","\x74","\x75","\x76","\x77","\x78","\x79","\x7A","\x7B","\x7C","\x7D","\x7E","\x7F",
//     "\x80","\x81","\x82","\x83","\x84","\x85","\x86","\x87","\x88","\x89","\x8A","\x8B","\x8C","\x8D","\x8E","\x8F",
//     "\x90","\x91","\x92","\x93","\x94","\x95","\x96","\x97","\x98","\x99","\x9A","\x9B","\x9C","\x9D","\x9E","\x9F",
//     "\xA0","\xA1","\xA2","\xA3","\xA4","\xA5","\xA6","\xA7","\xA8","\xA9","\xAA","\xAB","\xAC","\xAD","\xAE","\xAF",
//     "\xB0","\xB1","\xB2","\xB3","\xB4","\xB5","\xB6","\xB7","\xB8","\xB9","\xBA","\xBB","\xBC","\xBD","\xBE","\xBF",
//     "\xC0","\xC1","\xC2","\xC3","\xC4","\xC5","\xC6","\xC7","\xC8","\xC9","\xCA","\xCB","\xCC","\xCD","\xCE","\xCF",
//     "\xD0","\xD1","\xD2","\xD3","\xD4","\xD5","\xD6","\xD7","\xD8","\xD9","\xDA","\xDB","\xDC","\xDD","\xDE","\xDF",
//     "\xE0","\xE1","\xE2","\xE3","\xE4","\xE5","\xE6","\xE7","\xE8","\xE9","\xEA","\xEB","\xEC","\xED","\xEE","\xEF",
//     "\xF0","\xF1","\xF2","\xF3","\xF4","\xF5","\xF6","\xF7","\xF8","\xF9","\xFA","\xFB","\xFC","\xFD","\xFE","\xFF",
// };


// struct math_symbol_t {
//     int font;
//     int code;
//     char str[64];
// };

// math_symbol_t math_symbols[] = {
//     { 0, 0xAE, "\\alpha" },
//     { 0, 0xAF, "\\beta" },
//     { 0, 0xB0, "\\gamma" },
//     { 0, 0xB1, "\\delta" },
//     { 0, 0xB2, "\\epsilon" },
//     { 0, 0xB3, "\\zeta" },
//     { 0, 0xB4, "\\eta" },
//     { 0, 0xB5, "\\theta" },
//     { 0, 0xB6, "\\iota" },
//     { 0, 0xB7, "\\kappa" },
//     { 0, 0xB8, "\\lambda" },
//     { 0, 0xB9, "\\mu" },
//     { 0, 0xBA, "\\nu" },
//     { 0, 0xBB, "\\xi" },
//     { 0, 0xBC, "\\pi" },
//     { 0, 0xBD, "\\rho" },
//     { 0, 0xBE, "\\sigma" },
//     { 0, 0xBF, "\\tau" },
//     { 0, 0xC0, "\\upsilon" },
//     { 0, 0xC1, "\\phi" },
//     { 0, 0xC2, "\\chi" },
//     { 0, 0xC3, "\\psi" },
//     { 0, 0x21, "\\omega" },

//     { 0, 0xA1, "\\Gamma" },
//     { 0, 0xA2, "\\Delta" },
//     { 0, 0xA3, "\\Theta" },
//     { 0, 0xA4, "\\Lambda" },
//     { 0, 0xA5, "\\Xi" },
//     { 0, 0xA6, "\\Pi" },
//     { 0, 0xA7, "\\Sigma" },
//     { 0, 0xA8, "\\Upsilon" },
//     { 0, 0xA9, "\\Phi" },
//     { 0, 0xAA, "\\Psi" },
//     { 0, 0xAB, "\\Omega" },

//     { 0, 0x40, "\\partial"}, /* derivative */

//     /* Arrow parts */
//     { 0, 0x28, "_arrow_left_part_up"},
//     { 0, 0x29, "_arrow_left_part_down"},
//     { 0, 0x2A, "_arrow_right_part_up"},
//     { 0, 0x2B, "_arrow_right_part_down"},

//     { 0, 0x3F, "_star_sym"},
//     { 0, 0x7E, "_vector_hat"},

//     /* TODO: font0: {0..9} {a..z} {A..Z} {.} {,} {<} {>} */
//     /* TODO: font0: figure out what is with the '/' sign there */

//     /* TODO: font1: {A..Z} */

//     { 1, 0x21, "_arrow_right" },
//     { 1, 0x22, "_arrow_up" },
//     { 1, 0x23, "_arrow_down" },
//     { 1, 0x24, "_arrow_left_right" },
//     { 1, 0x25, "_arrow_right_corner_up" },
//     { 1, 0x26, "_arrow_right_corner_down" },
//     { 1, 0x27, "_aprox_eq" },
//     { 1, 0x28, "_double_arrow_left" },
//     { 1, 0x29, "_double_arrow_right" },
//     { 1, 0x2A, "_double_arrow_up" },
//     { 1, 0x2B, "_double_arrow_down" },
//     { 1, 0x2C, "_double_arrow_left_right" },
//     { 1, 0x2D, "_arrow_left_corner_up" },
//     { 1, 0x2E, "_arrow_left_corner_down" },
//     { 1, 0x2F, "\\propto" },
//     { 1, 0x30, "this: ' " },
//     { 1, 0x31, "infinity" },
//     { 1, 0x32, "part of set" },
//     { 1, 0x33, "part of set rev" },
//     { 1, 0x34, "delta as operator" },
//     { 1, 0x35, "reverse delta" },
//     { 1, 0x36, "this: / " },
//     { 1, 0x37, "????" },
//     { 1, 0x38, "\\forall" },
//     { 1, 0x39, "\\exists" },
//     { 1, 0x3A, "negate" },
//     { 1, 0x3B, "empty set" },
//     { 1, 0x3C, "strange R" },
//     { 1, 0x3D, "strange something" },
//     { 1, 0x3E, "T" },
//     { 1, 0x3F, "T reversed" },
//     { 1, 0x40, "\\aleph" },
//     { 1, 0x5B, "union" },
//     { 1, 0x5C, "intersect" },
//     { 1, 0x5D, "union +" },
//     { 1, 0x5E, "and" },
//     { 1, 0x5F, "or" },
//     { 1, 0x60, "T to the left" },
//     { 1, 0x61, "T to the right" },

//     { 1, 0x5A, "\\int" },    // Integral symbol
//     { 1, 0x49, "\\iint" },   // Double integral symbol
//     { 1, 0x5C, "\\iiint" },  // Triple integral symbol

//     { 1, 0x66, "{" },
//     { 1, 0x67, "}" },
//     { 1, 0x71, "pi reversed" },
//     { 1, 0x72, "laplacian" },

//     { 1, 0xA1, "minus" },
//     { 1, 0xA2, "dot - product" },
//     { 1, 0xA3, "times" },
//     { 1, 0xA4, "star" },
//     { 1, 0xA5, "division" },
//     { 1, 0xA6, "romb" },
//     { 1, 0xA7, "+/-" },
//     { 1, 0xA8, "-/+" },
//     { 1, 0xA9, "+ in circle" },
//     { 1, 0xAA, "- in circle" },

//     { 1, 0xAE, "/ in circle" },
//     { 1, 0xAE, ". in circle" },
//     { 1, 0xAE, "empty circle" },
//     { 1, 0xB4, "congruence" },
//     { 1, 0xB5, "included or equal" },
//     { 1, 0xB6, "includes or equal" },
//     { 1, 0xB7, "less than" },
//     { 1, 0xB8, "greater than" },
//     { 1, 0xB9, "strange less than" },
//     { 1, 0xBA, "strange greater than" },
//     { 1, 0xBB, "aprox" },
//     { 1, 0xBC, "double aprox" },
//     { 1, 0xBD, "includes" },
//     { 1, 0xBE, "included" },
//     { 1, 0xBF, "much lesser" },
//     { 1, 0xC0, "much greater" },
//     { 1, 0xB1, "strange less" },
//     { 1, 0xB2, "strange greater" },
//     { 1, 0xB3, "arrow left" },

// };

// const char *math_elements[] = {
//     "variable",         /* optional subscripts */
//     "function",         /* has variable as name, has arguments */
//     "dfunction",        /* as function, but has discrete argument */
//     "fraction",         /* has terms */
//     "addition",         /* includes +,- */
//     "multiplication",   /* includes * */
//     "diffop",           /* d/dx */
//     "exponentiation",   /* or raise to power */
//     "integral",         /* has lower, upper, body */
//     "sum",
//     "prod",
//     "limit",
//     "min", "max", "argmin", "argmax",
//     "sin", "cos", "tan", "cot",
//     "sinh", "cosh", "tanh", "coth",
//     "asin", "acos", "atan", "acot",
//     "sqrt",
//     "equation",
//     "equation_system",
//     "inequation",
//     "inequation_system",
//     "modul",
//     "diffpow",          /* diferential superscript: ', '', ''', (n) */
//     "transpose",
//     "matrix",
//     "matrix_det",
//     "log",
//     "lg",
//     "ln",
// };

int main(int argc, char const *argv[]) {

    imgui_init();
    ImVec4 clear_color = ImVec4(0.45f, 0.55f, 0.60f, 1.00f);

    ImGuiIO& io = ImGui::GetIO();
    ImFont* font_default = io.Fonts->AddFontDefault();
    
    ImFontConfig config;
    config.MergeMode = true;

    ASSERT_FN(fonts_init());
    ASSERT_FN(comments_init());

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

        // ImGui::Text("Press R to hide/unhide the boxes");

        ASSERT_FN(comment_text());

        // ok pharanteses: () \xB5\xB6 [] \xB7\xB8 {} \xBD\xBE
        // \x58 - sum
        // \x59 - prod
        // \x5B - mass union
        // \x5C - mass intersect
        // \x5A - integral
        // \x49 - circle integral
        // all from FONT_MATH_EX
        // all of them need to be centered to be used
        const char str2[] =
                "\xC3\xB5\xB3\xA1\xA2\xB4\xB6\x21"
                "\x22\xB7\x68\xA3\xA4\x69\xB8\x23"
                "\x28\xBD\x6E\xA9\xAA\x6F\xBE\x29"
                "\x58\x59\x5B\x5C\x5A\x49";

        float off = 0;
        // const char str2[] = "\xAE\xAF\xB0\xB1\xB2\xB3\xB4\xB5\xB6\xB7\xB8\xB9\xBA\xBB\xBC\xBD\xBE\xBF";
        for (auto c : str2) {
            uint8_t code = c;
            // DBG("code: 0x%x sym: [%c]", code, c);
            if (!c)
                break;
            auto sym = symbol_t{ .code = code, .font_lvl = FONT_LVL_SUB0, .font_sub = FONT_MATH_EX };
            symbol_draw(ImVec2(100 + off, 100), sym);
            off += symbol_get_sz(sym).adv;
        }

        // for (int k = 0; k < 21; k++) {
        //     break;

        //     auto font = fonts[k/7][k%7];
        //     ImGui::PushFont(font);


        //     static float sz = 36.0f;
        //     static float thickness = 1.0f;

        //     ImVec2 p1 = ImGui::GetCursorScreenPos();
        //     ImVec2 p2 = ImGui::GetMousePos();
        //     float th = thickness;

        //     ImVec4 col = ImVec4(1.0f, 1.0f, 0.4f, 1.0f);
        //     ImU32 col32 = ImColor(col);
        //     draw_list->AddLine(ImVec2(0, 0), ImVec2(0, 0), col32, th);

        //     float off_y = 0;
        //     float max_off_x = 0;
        //     p1 = ImGui::GetCursorScreenPos();
        //     for (int i = 0; i < 16; i++) {
        //         float off_x = 0;
        //         bool at_least_one = false;
        //         for (int j = 0; j < 16; j++) {
        //             int code = i*16 + j;

        //             float r = 1.;
        //             float g = 1.;
        //             float b = 1.;

        //             auto glyph = font->FindGlyphNoFallback(code);
        //             if (!glyph)
        //                 continue;

        //             at_least_one = true;
        //             if (!glyph->Visible)
        //                 r = 0;

        //             ImVec2 box_origin = ImVec2(p1.x + off_x, p1.y + off_y);

        //             ImVec2 box_bot = ImVec2(p1.x + glyph->X0 + off_x, p1.y + off_y + glyph->Y0);
        //             ImVec2 box_top = ImVec2(p1.x + glyph->X1 + off_x, p1.y + off_y + glyph->Y1);
        //             off_x += glyph->AdvanceX;


        //             /* OBS: RenderChar is the only method that works, for unknown reasons, maybe I can
        //             fix it? */
        //             font->RenderChar(draw_list, font->FontSize, box_origin, 0xff00ffff, code);

        //             // draw_list->AddText(font, font->FontSize, box_origin, 0xffff00ff, codes[code], NULL);

        //             col = ImVec4(r, g, b, 1.0f);
        //             ImU32 col32 = ImColor(col);
        //             if (KEY_TOGGLE(ImGuiKey_R)) {
        //                 draw_list->AddLine(ImVec2(box_bot.x, box_bot.y), ImVec2(box_top.x, box_bot.y), col32, th);
        //                 draw_list->AddLine(ImVec2(box_top.x, box_bot.y), ImVec2(box_top.x, box_top.y), col32, th);
        //                 draw_list->AddLine(ImVec2(box_top.x, box_top.y), ImVec2(box_bot.x, box_top.y), col32, th);
        //                 draw_list->AddLine(ImVec2(box_bot.x, box_top.y), ImVec2(box_bot.x, box_bot.y), col32, th);
        //             }

        //             // draw_list->AddLine(p1, ImVec2(p1.x, p1.y + 100), 0xffffff00, th);
        //             // draw_list->AddLine(p1, p2, col32, th);

        //             // draw_list->AddLine(ImVec2(p1.x - 100, p1.y), ImVec2(p1.x, p1.y), 0xffff0000);

        //             // draw_list->AddLine(ImVec2(p1.x - 10, p1.y + font->Ascent),
        //             //         ImVec2(p1.x + 10, p1.y + font->Ascent), 0xff00ff00, th);

        //             // draw_list->AddLine(ImVec2(p1.x + 10, p1.y + font->Ascent - font->Descent),
        //             //         ImVec2(p1.x - 10, p1.y + font->Ascent - font->Descent), 0xff0000ff, th);

        //         }
        //         if (at_least_one) {
        //             off_y += -font->Descent + font->Ascent;
        //         }
        //         max_off_x = std::max(max_off_x, off_x);
        //     }
        //     ImGui::Dummy(ImVec2(max_off_x, off_y));

        //     ImGui::PopFont();
        // }

        bool true_val = true;
        ImGui::ShowMetricsWindow(&true_val);

        ImGui::End();

        /* Add imgui stuff here */
        imgui_render(clear_color);
    }
    imgui_uninit();
    return 0;
}


// This is fine as a text writer, cand  do:.
// TODO LIST_LIST:
//     1.  write this comment section
//         1.1 Add greadd geGreek leters: alpha , beta gama,
//         1.1 add aother symbols
//         1.2332 Createcreate the bounding box of this comment seciontion oand of other s
//         1.34 maybe transfer this to stb or whateever else was it (in imgui input box)
//         1.5 copy, paste, etc.
//         1.56 
//     2. write the definition writer, it must be able to save tokens as functions, variables, named constants and more
//     3.  write the function equiation writer: must be able to draw nice equiaations
//     4. write the controls for the greneral window stuff, : how to change betwween different modes of writing()comment , definition, equation
//     5. write the controls for different equations manipulations
//     6. write the file save functionality
//     7. write the latex exporter

// This was edited  and saved with my app, real finally works. somewhat...

// This is aitalinormal etext.
//     This is bold text.
// This is italic tetxt.
// This is bold again.
// This is normal text again.
// This is italic again.
// Back to normal.

// This text can exit the screen very easily ily, There is no problem in doing so , writing a lot of text will be a problem, at least copy must work this is thoo anoying, ereally mean it , must be fixed. How really annoying this is,. Selecting text mis bprobably a must , but for now, I'll enable saving the current line and in the futureentire box and pasting at cursor, iI thingk this accan be enough for now.



// . How can I do selections? And why does a character disaeppear when mobing ving outside of the screen? EHh? Well , the solution would be to remembreer the last cursor positoion before pn when pressing shift and when drawing draw all the positions between the tow wo cursors in a nother way. Cpoopy would copy this area, copying a line will move area, and I'll implement the rest of the things I rememgber liking, copy foover selection, copy etc.delete selection 

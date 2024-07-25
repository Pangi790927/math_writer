#define IMGUI_DEFINE_MATH_OPERATORS

#include "imgui_helpers.h"
#include "imgui_internal.h"
#include "misc_utils.h"

#include "fonts.h"
#include "comments.h"
#include "formulas.h"
#include "defines.h"
#include "time_utils.h"

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





// maybe for matrices maybe? or upper, lower bound?: "\xB9\xBA\xBB\xBC"? from math_ex

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
//     "log",
//     "lg",
//     "ln",

//     "matrix",
//     "matrix_det",
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

    imgui_prepare_render();
    auto empty = mathe_empty();
    auto eset = mathe_symbol(mathe_convert(MATHE_sum, FONT_LVL_SUB2));
    auto integ = mathe_bigop(eset, eset, eset, mathe_convert(MATHE_integral, FONT_LVL_SUB0));
    auto sum = mathe_bigop(integ, eset, eset, mathe_convert(MATHE_sum, FONT_LVL_SUB0));
    auto frac = mathe_frac(eset, eset, mathe_convert(MATHE_hline_basic, FONT_LVL_SUB0));
    imgui_render(clear_color);

    auto timer_start = get_time_ms();
    int symbol_index = 190;
    auto curr_sym = math_symbols[symbol_index];

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

        ImDrawList* draw_list = ImGui::GetWindowDrawList();
        draw_list->AddLine(ImVec2(0,0), ImVec2(400, 600), 0xff'00ffff, 1);

        ASSERT_FN(mathe_draw(ImVec2(400, 600), frac));

        draw_list->AddLine(ImVec2(0,0), ImVec2(100, 100), 0xff'00ffff, 1);
        
        // bool oldtoggle = symbol_toggle_bb(true);
        symbol_draw(ImVec2(100, 100), mathe_convert(curr_sym, FONT_LVL_SUB1));
        // symbol_toggle_bb(oldtoggle);

        if (get_time_ms() - timer_start > 3'000) {
            curr_sym = math_symbols[symbol_index];
            symbol_index = (symbol_index + 1) % ARR_SZ(math_symbols);
            timer_start = get_time_ms();
            DBG("symbol_index: %d, code: 0x%x, font: %d desc: %s",
                    symbol_index, curr_sym.code, curr_sym.font, curr_sym.latex_name);
        }

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

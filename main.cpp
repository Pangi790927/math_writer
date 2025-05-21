#define NOMINMAX
#define IMGUI_DEFINE_MATH_OPERATORS

#include "imgui_helpers.h"
#include "imgui_internal.h"
#include "debug.h"
#include "time_utils.h"

#include "mathd.h"
#include "comments.h"
#include "content.h"

/* TODO:
 * =================================================================================================
    - Content menu, meaning, the main way we split information:
        - Click to select the box (when you click outside the box you select another box)
        - Have them boxes connect on the left
        - Have the input redirected from content inwards
    - Comments (make them better):
        - selectable text
        - copy/paste
    - Saves
    - Boxes with callbacks in mathe and to redefine mathe (mathe, mathf, mathv - expression, formula/fucntion, var?)
    - Check out all the comments bellow
    - Figure out a fast select menu (some sort of circular menu?)
    - Keybinds
 */

/*      TODO: fix elements: */
/* DONE: add empty box above or bellow to make fraction centered at line center */
/* DONE: add empty box above or bellow to make supsub aligned with the base  */
/* TODO: fix the fact that the additional space is taken into account for next elements
(example fractions in fractions) */

/* TODO: make brackets size adjustable, based on the element */

/*      TODO: more elements: */
/* TODO: add abs and norm */
/* TODO: add matrix/matrix det */
/* TODO: add system of eq/ineq */
/* TODO: add square root (with bonus power) */

/*  TODO: continue the formula adder path:
    - has to have a tree of elements that use those things to draw elements
    - has to have a cursor (figure out how to navigate it)
    - has to have a way to change stuff (move terms, etc.)
    - has to have a way to configure what changes can be made (later)
    - has to have a way to input new operands
    - has to have a way to change between editing modes
 */

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


int main(int argc, char const *argv[]) {
    imgui_init();
    ImVec4 clear_color = ImVec4(0.45f, 0.55f, 0.60f, 1.00f);

    ImGuiIO& io = ImGui::GetIO();
    ImFont* font_default = io.Fonts->AddFontDefault();
    
    ImFontConfig config;
    config.MergeMode = true;

    ASSERT_FN(chars_init());
    ASSERT_FN(comments_init());
    ASSERT_FN(content_init());

    cboxes[0].obj = comments_create();

    char_font_lvl_e font0 = FONT_LVL_SUB0;
    char_font_lvl_e font1 = FONT_LVL_SUB2;
    char_font_lvl_e font2 = FONT_LVL_SUB4;

    imgui_prepare_render();
    auto empty = mathd_empty();
    auto eset = mathd_symbol(mathd_convert(MATHD_hash, font2));
    auto sym_e = mathd_symbol(mathd_convert(MATHD_e, font0));
    auto sym_e1 = mathd_symbol(mathd_convert(MATHD_e, font1));
    auto sym_a0 = mathd_symbol(mathd_convert(MATHD_a, font0));
    auto sym_a1 = mathd_symbol(mathd_convert(MATHD_a, font1));
    auto sym_a2 = mathd_symbol(mathd_convert(MATHD_a, font2));
    auto sym_n1 = mathd_symbol(mathd_convert(MATHD_n, font2));
    auto binar = mathd_binexpr(sym_e, mathd_convert(MATHD_plus, font0), sym_a0);
    auto binar_1 = mathd_binexpr(sym_e1, mathd_convert(MATHD_plus, font1), sym_a1);
    auto integ = mathd_bigop(sym_a0, sym_e1, binar_1, mathd_convert(MATHD_integral, font0));
    auto unar = mathd_unarexpr(mathd_convert(MATHD_minus, font0), sym_e);
    auto unar_1 = mathd_unarexpr(mathd_convert(MATHD_minus, font1), sym_e1);
    auto n_eq_1 = mathd_binexpr(sym_n1, mathd_convert(MATHD_equal, font1), sym_e1);
    auto sum = mathd_bigop(integ, unar_1, n_eq_1, mathd_convert(MATHD_sum, font0));
    auto sym_exp = mathd_supsub(sym_e, sym_a1, empty);
    auto binar2 = mathd_binexpr(binar, mathd_convert(MATHD_plus, font0), sum);
    auto frac = mathd_frac(sym_exp, binar2, mathd_convert(MATHD_hline_basic, font0));
    auto binar3 = mathd_binexpr(frac, mathd_convert(MATHD_minus, font0), sym_exp);
    auto binar4 = mathd_binexpr(binar3, mathd_convert(MATHD_minus, font0), sym_e);
    auto brack = mathd_bracket(binar3, mathd_convert(mathd_brack_square, font0));
    auto frac2 = mathd_frac(sym_exp, binar4, mathd_convert(MATHD_hline_basic, font0));

    auto curr_obj = frac2;
    imgui_render(clear_color);

    auto timer_start = get_time_ms();
    int symbol_index = 0;
    auto curr_sym = gchar(symbol_index);

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

        content_update();
        content_draw();

        ImDrawList* draw_list = ImGui::GetWindowDrawList();
        draw_list->AddLine(ImVec2(0,0), ImVec2(400, 600), 0xff'00ffff, 1);
        ASSERT_FN(mathd_draw(ImVec2(400, 600), curr_obj));

        draw_list->AddLine(ImVec2(0,0), ImVec2(100, 100), 0xff'00ffff, 1);
        
        bool oldtoggle = char_toggle_bb(true);
        char_draw(ImVec2(100, 100), mathd_convert(curr_sym, FONT_LVL_SUB1));
        char_toggle_bb(oldtoggle);

        if (get_time_ms() - timer_start > 1'000) {
            curr_sym = gchar(symbol_index);
            symbol_index = (symbol_index + 1) % chars_cnt();
            timer_start = get_time_ms();
            auto char_sz = char_get_sz(curr_sym);
            DBG("idx: %d, fcod: 0x%x, fnum: %d "
                "sz:[adv: %f, asc: %f, desc: %f, bl:(%f, %f), tr:(%f, %f)] description: %s",
                    symbol_index, (int)curr_sym.fcod, (int)curr_sym.fnum,
                    char_sz.adv, char_sz.asc, char_sz.desc,
                    char_sz.bl.x, char_sz.bl.y, char_sz.tr.x, char_sz.tr.y,
                    get_char_desc(curr_sym.ncod)->desc);
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

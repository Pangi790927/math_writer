#ifndef FONTS_H
#define FONTS_H

#include <string>
#include <vector>

#include "imgui.h"

#include "imgui_impl_glfw.h"
#include "imgui_impl_opengl3.h"
#include "imgui_internal.h"

#include "misc_utils.h"

enum font_sub_e : int {
    FONT_NORMAL,
    FONT_BOLD,
    FONT_ITALIC,
    FONT_MONO,

    FONT_MATH,
    FONT_SYMBOLS,
    FONT_MATH_EX,
};

enum font_lvl_e : int {
    FONT_LVL_SUB0,
    FONT_LVL_SUB1,
    FONT_LVL_SUB2,
    FONT_LVL_SUB3,
    FONT_LVL_SUB4,

    FONT_LVL_CNT,

    /* This is used sometimes for some control characters */
    FONT_LVL_SPECIAL = 0xfffffff,
};

/*  I have 7 fonts, 3 with mathematics, 4 for words but in need of some signs(ex: '{', '}')
    I'm interested in the math parts, so the first thing should be to map the 3 fonts to some
    numbers and symbols to make it clear.
*/

/* there will be 3 levels for the exponentiation/subscripts size, made by 3 loadings of the font.
The ratios will be 1, 0.5, 0.25 */

/* Those symbols have a line passing through them, the whole formula must be aligned to this line */
/* Those symbols are the building blocks for all mathematics symbols, the difference is that those
are allowed to intersect eachother and don't represent anything */
struct symbol_t {
    uint32_t code;         /* code of the symbol */
    font_lvl_e font_lvl;   /* selects the size of the font */
    font_sub_e font_sub;  /* selects the respective font from font_paths */
};

struct symbol_sz_t {
    float adv;          /* how much advance needs to be made till the next glyph */
    float asc;          /* Asecnt */
    float desc;         /* Descent */
    ImVec2 bl, tr;      /* bottom left and top right bounding box of the symbol */
};

inline int fonts_init();

inline symbol_sz_t symbol_get_sz(const symbol_t& s);
inline ImFont *symbol_get_font(const symbol_t& s);
inline void symbol_draw(ImVec2 pos, const symbol_t& s);
inline bool symbol_toggle_bb(bool val);
inline float symbol_get_lvl_mul(font_lvl_e lvl);

/* IMPLEMENTATION
 * =================================================================================================
 */

inline const char *font_paths[] = {
    /* Font - Roman
        * Has some math operators/Symbols
        * Usefull for description parts of the app
    */
    "fonts/cmr10.ttf",

    /* Font - Bold Extended
        * Has some math operators/Symbols
        * Usefull for description parts of the app
    */
    "fonts/cmbx10.ttf",

    /* Font - Text Italic
        * Has some math operators/Symbols
        * Usefull for description parts of the app
    */
    "fonts/cmti10.ttf",

    /* Font - Typewriter Type
        * Has some math operators/Symbols
        * Usefull for description parts of the app
        * Has constant spacing, can be used for code writing
    */
    "fonts/cmtt10.ttf",

    /* Font - Math Italic
        * Used for formulas (the variable names)
        * Has more/all greek
        * has some operators
    */
    "fonts/cmmi10.ttf",

    /* Font - Math Symbols
        * Used for formulas
        * A lot of signs
    */
    "fonts/cmsy10.ttf",

    /* Font - Math Extension
        * Used for formulas
        * big operators
        * brackets
    */
    "fonts/cmex10.ttf",
};


inline float font_lvl_mul[] = { 1., 0.75, 0.6, 0.5, 0.4, 0.3 };
inline float font_sub_mul[] = { 1., 1., 1., 1., 1., 1., 2.5 };

inline std::vector<std::vector<ImFont*>> fonts(
        (int)FONT_LVL_CNT, std::vector<ImFont*>(ARR_SZ(font_paths)));

inline bool draw_bb_chars = false;

inline bool symbol_toggle_bb(bool val) {
    auto ret = draw_bb_chars;
    draw_bb_chars = val;
    return ret;
}

inline symbol_sz_t symbol_get_sz(const symbol_t& s) {
    auto font = fonts[s.font_lvl][s.font_sub];
    auto glyph = font->FindGlyphNoFallback(s.code);
    if (!glyph)
        return {};

    return symbol_sz_t{
        .adv = glyph->AdvanceX,
        .asc = font->Ascent,
        .desc = font->Descent,
        .bl = ImVec2(glyph->X0, glyph->Y1),
        .tr = ImVec2(glyph->X1, glyph->Y0),
    };
}

inline ImFont *symbol_get_font(const symbol_t& s) {
    return fonts[s.font_lvl][s.font_sub];
}

inline void symbol_draw(ImVec2 pos, const symbol_t& s) {
    auto ssz = symbol_get_sz(s);

    ImDrawList* draw_list = ImGui::GetWindowDrawList();
    ImGuiWindow* window = ImGui::GetCurrentWindow();
    if (window->SkipItems)
        return ;

    pos.y -= ssz.asc;

    // DBG("bl.x: %f bl.y: %f tr.x: %f tr.y: %f", ssz.bl.x, ssz.bl.y, ssz.tr.x, ssz.tr.y);

    const ImRect bb(ssz.bl + pos, ssz.tr + pos);
    ImGui::ItemAdd(bb, 0);

    ImVec2 bl = ssz.bl + pos;
    ImVec2 tr = ssz.tr + pos;

    /* OBS: RenderChar is the only method that works, for unknown reasons, maybe I can
    fix it?(in imgui). For now the thing will be made out of raw drawing */
    auto font = symbol_get_font(s);
    ImGui::PushFont(font);
    
    font->RenderChar(draw_list, font->FontSize, pos, 0xff'eeeeee, s.code);
    if (draw_bb_chars) {
        // DBG("bl.x %f, bl.y %f tr.x %f, tr.y %f", bl.x, bl.y, tr.x, tr.y);
        draw_list->AddLine(ImVec2(bl.x, bl.y), ImVec2(tr.x, bl.y), 0xff'00ffff, 1);
        draw_list->AddLine(ImVec2(tr.x, bl.y), ImVec2(tr.x, tr.y), 0xff'00ffff, 1);
        draw_list->AddLine(ImVec2(tr.x, tr.y), ImVec2(bl.x, tr.y), 0xff'00ffff, 1);
        draw_list->AddLine(ImVec2(bl.x, tr.y), ImVec2(bl.x, bl.y), 0xff'00ffff, 1);
        // draw_list->AddLine(ImVec2(bl.x, bl.y + ssz.asc), ImVec2(tr.x, bl.y + ssz.asc), 0xff'ff0000, 1);
        // draw_list->AddLine(ImVec2(bl.x, bl.y + ssz.desc), ImVec2(tr.x, bl.y + ssz.desc), 0xff'00ff00, 1);
    }
    ImGui::PopFont();
}

inline int fonts_init() {
    ImGuiIO& io = ImGui::GetIO();

    float size_pixels = 42;
    for (int i = 0; i < fonts.size(); i++) {
        for (int j = 0; j < fonts[i].size(); j++) {
            fonts[i][j] = io.Fonts->AddFontFromFileTTF(font_paths[j],
                    font_lvl_mul[i] * size_pixels * font_sub_mul[j]);
         }
    }
    return 0;
}

inline float symbol_get_lvl_mul(font_lvl_e lvl) {
    return font_lvl_mul[lvl];
}

#endif
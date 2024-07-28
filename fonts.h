#ifndef FONTS_H
#define FONTS_H

#include <string>
#include <vector>

#include "imgui.h"

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

int fonts_init();

symbol_sz_t symbol_get_sz(const symbol_t& s);
ImFont *symbol_get_font(const symbol_t& s);
void symbol_draw(ImVec2 pos, const symbol_t& s);
bool symbol_toggle_bb(bool val);
float symbol_get_lvl_mul(font_lvl_e lvl);

#endif
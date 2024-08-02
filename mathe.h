#ifndef MATHE_H
#define MATHE_H

#include <memory>
#include <map>
#include <vector>
#include <math.h>

#include "fonts.h"
#include "misc_utils.h"
#include "debug.h"

enum mathe_e : int {
    MATHE_TYPE_EMPTY_BOX,
    MATHE_TYPE_SYMBOL,
    MATHE_TYPE_BIGOP,
    MATHE_TYPE_FRAC,
    MATHE_TYPE_SUPSUB,
    MATHE_TYPE_BRACKET,
};

/* TODO: maybe should stay in implementation */
enum mathe_cmd_e : int {
    /* movement: */
    MATHE_ABOVE,
    MATHE_BELLOW,
    MATHE_LEFT,
    MATHE_RIGHT,
    MATHE_SUP,
    MATHE_SUB,

    /* modifier: */
    MATHE_MAKEFIT,     /* Makes dst fit both src and dst */

    /* creators: */
    MATHE_EXPR,
    MATHE_SYM,
    MATHE_EMPTY,
    MATHE_MERGE,
};

enum mathe_obj_e : int {
    MATHE_OBJ_SYMB,
    MATHE_OBJ_SUBEXPR,
    MATHE_OBJ_EMPTY,
};

enum mathe_bracket_e : int {
    MATHE_BRACKET_ROUND,
    MATHE_BRACKET_SQUARE,
    MATHE_BRACKET_CURLY,
};

struct mathe_sym_t {
    int id;
    uint32_t code;
    font_sub_e font;
    char latex_name[64];
};

struct mathe_bracket_sym_t {
    mathe_bracket_e type;
    mathe_sym_t tl;
    mathe_sym_t bl;
    mathe_sym_t tr;
    mathe_sym_t br;
    mathe_sym_t cl;
    mathe_sym_t cr;
    mathe_sym_t con;
    mathe_sym_t left[4];
    mathe_sym_t right[4];
};

struct mathe_bracket_t {
    mathe_bracket_e type;
    symbol_t tl;
    symbol_t bl;
    symbol_t tr;
    symbol_t br;
    symbol_t cl;
    symbol_t cr;
    symbol_t con;
    symbol_t left[4];
    symbol_t right[4];
};

struct mathe_t;
using mathe_p = std::shared_ptr<mathe_t>;

template <typename ...Args>
mathe_p mathe_make(Args&&... args);

int mathe_draw(ImVec2 pos, mathe_p m);

mathe_p mathe_empty();
mathe_p mathe_symbol(symbol_t sym);
mathe_p mathe_bigop(mathe_p right, mathe_p above, mathe_p bellow, symbol_t bigop);
mathe_p mathe_frac(mathe_p above, mathe_p bellow, symbol_t divline);
mathe_p mathe_supsub(mathe_p base, mathe_p sup, mathe_p sub);
mathe_p mathe_bracket(mathe_p expr, symbol_t lb, symbol_t rb);
mathe_p mathe_unarexpr(symbol_t op, mathe_p b);
mathe_p mathe_binexpr(mathe_p a, symbol_t op, mathe_p b);
mathe_p mathe_merge_h(mathe_p l, mathe_p r);
mathe_p mathe_merge_v(mathe_p u, mathe_p d);

symbol_t        mathe_convert(mathe_sym_t msym, font_lvl_e font_lvl);
mathe_bracket_t mathe_convert(mathe_bracket_sym_t msym, font_lvl_e font_lvl);

/* TODO: matrix stuff */

inline bool mathe_draw_boxes = true;
// inline bool mathe_draw_boxes = false;

/* IMPLEMENTATION
================================================================================================= */

inline mathe_sym_t math_symbols[] = {
    {   0, 0x21, FONT_NORMAL , "!" }, /* exclamation mark */
    {   1, 0x22, FONT_NORMAL , "\"" }, /* double quote */
    {   2, 0x23, FONT_NORMAL , "#" }, /* hash */
    {   3, 0x24, FONT_NORMAL , "$" }, /* dollar sign */
    {   4, 0x25, FONT_NORMAL , "%" }, /* percent sign */
    {   5, 0x26, FONT_NORMAL , "&" }, /* ampersand */
    {   6, 0x27, FONT_NORMAL , "'" }, /* single quote */
    {   7, 0x28, FONT_NORMAL , "(" }, /* left parenthesis */
    {   8, 0x29, FONT_NORMAL , ")" }, /* right parenthesis */
    {   9, 0x2A, FONT_NORMAL , "*" }, /* asterisk */
    {  10, 0x2B, FONT_NORMAL , "+" }, /* plus sign */
    {  11, 0x2C, FONT_NORMAL , "," }, /* comma */
    {  12, 0x2D, FONT_NORMAL , "-" }, /* hyphen-minus */
    {  13, 0x2E, FONT_NORMAL , "." }, /* period */
    {  14, 0x2F, FONT_NORMAL , "/" }, /* slash */
    {  15, 0x30, FONT_MATH   , "0" }, /* digit zero */
    {  16, 0x31, FONT_MATH   , "1" }, /* digit one */
    {  17, 0x32, FONT_MATH   , "2" }, /* digit two */
    {  18, 0x33, FONT_MATH   , "3" }, /* digit three */
    {  19, 0x34, FONT_MATH   , "4" }, /* digit four */
    {  20, 0x35, FONT_MATH   , "5" }, /* digit five */
    {  21, 0x36, FONT_MATH   , "6" }, /* digit six */
    {  22, 0x37, FONT_MATH   , "7" }, /* digit seven */
    {  23, 0x38, FONT_MATH   , "8" }, /* digit eight */
    {  24, 0x39, FONT_MATH   , "9" }, /* digit nine */
    {  25, 0x3A, FONT_NORMAL , ":" }, /* colon */
    {  26, 0x3B, FONT_NORMAL , ";" }, /* semicolon */
    {  27, 0x3D, FONT_NORMAL , "=" }, /* equals sign */
    {  28, 0x3F, FONT_NORMAL , "?" }, /* question mark */
    {  29, 0x40, FONT_NORMAL , "@" }, /* at symbol */
    {  30, 0x41, FONT_MATH   , "A" }, /* uppercase A */
    {  31, 0x42, FONT_MATH   , "B" }, /* uppercase B */
    {  32, 0x43, FONT_MATH   , "C" }, /* uppercase C */
    {  33, 0x44, FONT_MATH   , "D" }, /* uppercase D */
    {  34, 0x45, FONT_MATH   , "E" }, /* uppercase E */
    {  35, 0x46, FONT_MATH   , "F" }, /* uppercase F */
    {  36, 0x47, FONT_MATH   , "G" }, /* uppercase G */
    {  37, 0x48, FONT_MATH   , "H" }, /* uppercase H */
    {  38, 0x49, FONT_MATH   , "I" }, /* uppercase I */
    {  39, 0x4A, FONT_MATH   , "J" }, /* uppercase J */
    {  40, 0x4B, FONT_MATH   , "K" }, /* uppercase K */
    {  41, 0x4C, FONT_MATH   , "L" }, /* uppercase L */
    {  42, 0x4D, FONT_MATH   , "M" }, /* uppercase M */
    {  43, 0x4E, FONT_MATH   , "N" }, /* uppercase N */
    {  44, 0x4F, FONT_MATH   , "O" }, /* uppercase O */
    {  45, 0x50, FONT_MATH   , "P" }, /* uppercase P */
    {  46, 0x51, FONT_MATH   , "Q" }, /* uppercase Q */
    {  47, 0x52, FONT_MATH   , "R" }, /* uppercase R */
    {  48, 0x53, FONT_MATH   , "S" }, /* uppercase S */
    {  49, 0x54, FONT_MATH   , "T" }, /* uppercase T */
    {  50, 0x55, FONT_MATH   , "U" }, /* uppercase U */
    {  51, 0x56, FONT_MATH   , "V" }, /* uppercase V */
    {  52, 0x57, FONT_MATH   , "W" }, /* uppercase W */
    {  53, 0x58, FONT_MATH   , "X" }, /* uppercase X */
    {  54, 0x59, FONT_MATH   , "Y" }, /* uppercase Y */
    {  55, 0x5A, FONT_MATH   , "Z" }, /* uppercase Z */
    {  56, 0x5B, FONT_NORMAL , "[" }, /* left square bracket */
    {  57, 0x5D, FONT_NORMAL , "]" }, /* right square bracket */
    {  58, 0x5E, FONT_NORMAL , "^" }, /* circumflex accent */
    {  59, 0x5F, FONT_MONO   , "_" }, /* underscore */
    {  60, 0xB5, FONT_NORMAL , "`" }, /* grave accent */
    {  61, 0x61, FONT_MATH   , "a" }, /* lowercase a */
    {  62, 0x62, FONT_MATH   , "b" }, /* lowercase b */
    {  63, 0x63, FONT_MATH   , "c" }, /* lowercase c */
    {  64, 0x64, FONT_MATH   , "d" }, /* lowercase d */
    {  65, 0x65, FONT_MATH   , "e" }, /* lowercase e */
    {  66, 0x66, FONT_MATH   , "f" }, /* lowercase f */
    {  67, 0x67, FONT_MATH   , "g" }, /* lowercase g */
    {  68, 0x68, FONT_MATH   , "h" }, /* lowercase h */
    {  69, 0x69, FONT_MATH   , "i" }, /* lowercase i */
    {  70, 0x6A, FONT_MATH   , "j" }, /* lowercase j */
    {  71, 0x6B, FONT_MATH   , "k" }, /* lowercase k */
    {  72, 0x6C, FONT_MATH   , "l" }, /* lowercase l */
    {  73, 0x6D, FONT_MATH   , "m" }, /* lowercase m */
    {  74, 0x6E, FONT_MATH   , "n" }, /* lowercase n */
    {  75, 0x6F, FONT_MATH   , "o" }, /* lowercase o */
    {  76, 0x70, FONT_MATH   , "p" }, /* lowercase p */
    {  77, 0x71, FONT_MATH   , "q" }, /* lowercase q */
    {  78, 0x72, FONT_MATH   , "r" }, /* lowercase r */
    {  79, 0x73, FONT_MATH   , "s" }, /* lowercase s */
    {  80, 0x74, FONT_MATH   , "t" }, /* lowercase t */
    {  81, 0x75, FONT_MATH   , "u" }, /* lowercase u */
    {  82, 0x76, FONT_MATH   , "v" }, /* lowercase v */
    {  83, 0x77, FONT_MATH   , "w" }, /* lowercase w */
    {  84, 0x78, FONT_MATH   , "x" }, /* lowercase x */
    {  85, 0x79, FONT_MATH   , "y" }, /* lowercase y */
    {  86, 0x7A, FONT_MATH   , "z" }, /* lowercase z */
    {  87, 0x66, FONT_SYMBOLS, "{" }, /* left curly brace */
    {  88, 0x6A, FONT_SYMBOLS, "|" }, /* vertical bar */
    {  89, 0x67, FONT_SYMBOLS, "}" }, /* right curly brace */
    {  90, 0x7E, FONT_NORMAL , "~" }, /* tilde */
    {  91, 0x6E, FONT_SYMBOLS, "\\"}, /* backslash */

    /* Symbols from cmr10.ttf */
    {  92, 0xA1, FONT_NORMAL , "\\Gamma" }, /* Greek uppercase Gamma */
    {  93, 0xA2, FONT_NORMAL , "\\Delta" }, /* Greek uppercase Delta */
    {  94, 0xA3, FONT_NORMAL , "\\Theta" }, /* Greek uppercase Theta */
    {  95, 0xA4, FONT_NORMAL , "\\Lambda" }, /* Greek uppercase Lambda */
    {  96, 0xA5, FONT_NORMAL , "\\Xi" }, /* Greek uppercase Xi */
    {  97, 0xA6, FONT_NORMAL , "\\Pi" }, /* Greek uppercase Pi */
    {  98, 0xA7, FONT_NORMAL , "\\Sigma" }, /* Greek uppercase Sigma */
    {  99, 0xA8, FONT_NORMAL , "\\Upsilon" }, /* Greek uppercase Upsilon */
    { 100, 0xA9, FONT_NORMAL , "\\Phi" }, /* Greek uppercase Phi */
    { 101, 0xAA, FONT_NORMAL , "\\Psi" }, /* Greek uppercase Psi */
    { 102, 0xAB, FONT_NORMAL , "\\Omega" }, /* Greek uppercase Omega */

    /* Greek letters (lowercase) */
    { 103, 0xAE, FONT_MATH   , "\\alpha" }, /* Greek lowercase alpha */
    { 104, 0xAF, FONT_MATH   , "\\beta" }, /* Greek lowercase beta */
    { 105, 0xB0, FONT_MATH   , "\\gamma" }, /* Greek lowercase gamma */
    { 106, 0xB1, FONT_MATH   , "\\delta" }, /* Greek lowercase delta */
    { 107, 0xB2, FONT_MATH   , "\\epsilon" }, /* Greek lowercase epsilon */
    { 108, 0xB3, FONT_MATH   , "\\zeta" }, /* Greek lowercase zeta */
    { 109, 0xB4, FONT_MATH   , "\\eta" }, /* Greek lowercase eta */
    { 110, 0xB5, FONT_MATH   , "\\theta" }, /* Greek lowercase theta */
    { 111, 0xB6, FONT_MATH   , "\\iota" }, /* Greek lowercase iota */
    { 112, 0xB7, FONT_MATH   , "\\kappa" }, /* Greek lowercase kappa */
    { 113, 0xB8, FONT_MATH   , "\\lambda" }, /* Greek lowercase lambda */
    { 114, 0xB9, FONT_MATH   , "\\mu" }, /* Greek lowercase mu */
    { 115, 0xBA, FONT_MATH   , "\\nu" }, /* Greek lowercase nu */
    { 116, 0xBB, FONT_MATH   , "\\xi" }, /* Greek lowercase xi */
    { 117, 0xBC, FONT_MATH   , "\\pi" }, /* Greek lowercase omicron */
    { 118, 0xBD, FONT_MATH   , "\\rho" }, /* Greek lowercase pi */
    { 119, 0xBE, FONT_MATH   , "\\sigma" }, /* Greek lowercase rho */
    { 120, 0xBF, FONT_MATH   , "\\tau" }, /* Greek lowercase sigma */
    { 121, 0xC0, FONT_MATH   , "\\upsilon" }, /* Greek lowercase tau */
    { 122, 0xC1, FONT_MATH   , "\\phi" }, /* Greek lowercase upsilon */
    { 123, 0xC2, FONT_MATH   , "\\chi" }, /* Greek lowercase phi */
    { 124, 0xC3, FONT_MATH   , "\\psi" }, /* Greek lowercase chi */
    { 125, 0x21, FONT_MATH   , "\\omega" }, /* Greek lowercase psi */

    /* Greek letters (uppercase) */
    { 126, 0xA1, FONT_MATH   , "\\Gamma" }, /* Greek uppercase Gamma */
    { 127, 0xA2, FONT_MATH   , "\\Delta" }, /* Greek uppercase Delta */
    { 128, 0xA3, FONT_MATH   , "\\Theta" }, /* Greek uppercase Theta */
    { 129, 0xA4, FONT_MATH   , "\\Lambda" }, /* Greek uppercase Lambda */
    { 130, 0xA5, FONT_MATH   , "\\Xi" }, /* Greek uppercase Xi */
    { 131, 0xA6, FONT_MATH   , "\\Pi" }, /* Greek uppercase Pi */
    { 132, 0xA7, FONT_MATH   , "\\Sigma" }, /* Greek uppercase Sigma */
    { 133, 0xA8, FONT_MATH   , "\\Upsilon" }, /* Greek uppercase Upsilon */
    { 134, 0xA9, FONT_MATH   , "\\Phi" }, /* Greek uppercase Phi */
    { 135, 0xAA, FONT_MATH   , "\\Psi" }, /* Greek uppercase Psi */
    { 136, 0xAB, FONT_MATH   , "\\Omega" }, /* Greek uppercase Omega */

    /* TODO: FIX ALL BELLOW THIS POINT (index: 137) */

    /* Symbols from cmsy10.ttf */
    { 137, 0xC3, FONT_SYMBOLS, "\\leftarrow" }, /* left arrow */
    { 138, 0x21, FONT_SYMBOLS, "\\rightarrow" }, /* right arrow */
    { 139, 0x22, FONT_SYMBOLS, "\\uparrow" }, /* up arrow */
    { 140, 0x23, FONT_SYMBOLS, "\\downarrow" }, /* down arrow */
    { 141, 0x24, FONT_SYMBOLS, "\\leftrightarrow" }, /* left-right arrow */
    { 142, 0x25, FONT_SYMBOLS, "\\nearrow" }, /* north-east arrow */
    { 143, 0x26, FONT_SYMBOLS, "\\searrow" }, /* south-east arrow */
    { 144, 0x27, FONT_SYMBOLS, "\\simeq" }, /* approximately equal */
    { 145, 0x28, FONT_SYMBOLS, "\\Leftarrow" }, /* left double arrow */
    { 146, 0x29, FONT_SYMBOLS, "\\Rightarrow" }, /* right double arrow */
    { 147, 0x2A, FONT_SYMBOLS, "\\Uparrow" }, /* up double arrow */
    { 148, 0x2B, FONT_SYMBOLS, "\\Downarrow" }, /* down double arrow */
    { 149, 0x2C, FONT_SYMBOLS, "\\Leftrightarrow" }, /* left-right double arrow */
    { 150, 0x2D, FONT_SYMBOLS, "\\nwarrow" }, /* north-west arrow */
    { 151, 0x2E, FONT_SYMBOLS, "\\swarrow" }, /* south-west arrow */
    { 152, 0x2F, FONT_SYMBOLS, "\\propto" }, /* proportional to */
    { 153, 0x30, FONT_SYMBOLS, "\\partial" }, /* partial derivative */
    { 154, 0x31, FONT_SYMBOLS, "\\infty" }, /* infinity */
    { 155, 0x32, FONT_SYMBOLS, "\\in" }, /* element of */
    { 156, 0x33, FONT_SYMBOLS, "\\ni" }, /* element of backwards */
    { 157, 0x35, FONT_SYMBOLS, "\\nabla" }, /* nabla */
    { 158, 0x36, FONT_SYMBOLS, "/" }, /* forward slash */
    { 159, 0x38, FONT_SYMBOLS, "\\forall" }, /* for all */
    { 160, 0x39, FONT_SYMBOLS, "\\exists" }, /* exists */
    { 161, 0x3A, FONT_SYMBOLS, "\\neg" }, /* negation */
    { 162, 0x3B, FONT_SYMBOLS, "\\emptyset" }, /* empty set */
    { 163, 0x3C, FONT_SYMBOLS, "\\Re" }, /* real part */
    { 164, 0x3D, FONT_SYMBOLS, "\\Im" }, /* imaginary part */
    { 165, 0x3E, FONT_SYMBOLS, "\\top" }, /* top */
    { 166, 0x3F, FONT_SYMBOLS, "\\bot" }, /* bottom */
    { 167, 0x40, FONT_SYMBOLS, "\\aleph" }, /* aleph */
    { 168, 0x5B, FONT_SYMBOLS, "\\cup" }, /* union */
    { 169, 0x5C, FONT_SYMBOLS, "\\cap" }, /* intersection */
    { 170, 0x5D, FONT_SYMBOLS, "\\uplus" }, /* multiset union */
    { 171, 0x5E, FONT_SYMBOLS, "\\wedge" }, /* logical and */
    { 172, 0x5F, FONT_SYMBOLS, "\\vee" }, /* logical or */
    { 173, 0x66, FONT_SYMBOLS, "\\{" }, /* DUPLICATE - left brace */
    { 174, 0x67, FONT_SYMBOLS, "\\}" }, /* DUPLICATE - right brace */
    { 175, 0x6A, FONT_SYMBOLS, "\\|" }, /* vertical bar */
    { 176, 0x6B, FONT_SYMBOLS, "\\parallel" }, /* parallel */
    { 177, 0xBF, FONT_SYMBOLS, "\\ll" }, /* much less than */
    { 178, 0xC0, FONT_SYMBOLS, "\\gg" }, /* much greater than */
    { 179, 0xB1, FONT_SYMBOLS, "\\circ" }, /* circle */
    { 180, 0xB2, FONT_SYMBOLS, "\\bullet" }, /* bullet */
    { 181, 0xA1, FONT_SYMBOLS, "-" }, /* minus sign */
    { 182, 0xA3, FONT_SYMBOLS, "\\times" }, /* multiplication sign */
    { 183, 0xA5, FONT_SYMBOLS, "\\div" }, /* division sign */
    { 184, 0xA7, FONT_SYMBOLS, "\\pm" }, /* plus-minus sign */
    { 185, 0xA8, FONT_SYMBOLS, "\\mp" }, /* minus-plus sign */
    { 186, 0xB7, FONT_SYMBOLS, "\\le" }, /* less than or equal */
    { 187, 0xB8, FONT_SYMBOLS, "\\ge" }, /* greater than or equal */
    { 188, 0xB4, FONT_SYMBOLS, "\\cong" }, /* congruent */
    { 189, 0xB6, FONT_SYMBOLS, "\\supseteq" }, /* superset equal */
    { 190, 0xB5, FONT_SYMBOLS, "\\subseteq" }, /* subset equal */

    /* Symbols from cmex10.ttf */
    { 191, 0x5A, FONT_MATH_EX, "\\int" }, /* integration sign */
    { 192, 0x58, FONT_MATH_EX, "\\sum" }, /* summation sign */
    { 193, 0x59, FONT_MATH_EX, "\\prod" }, /* product sign */
    { 194, 0x5B, FONT_MATH_EX, "\\bigcup" }, /* large union */
    { 195, 0x5C, FONT_MATH_EX, "\\bigcap" }, /* large intersection */
    { 196, 0x49, FONT_MATH_EX, "\\oint" }, /* circle integral */

    { 197, 0xC3, FONT_MATH_EX, "\\Biggl(" }, /* paranthesis '(' level 4 */
    { 198, 0xB5, FONT_MATH_EX, "\\biggl(" }, /* paranthesis '(' level 3 */
    { 199, 0xB3, FONT_MATH_EX, "\\Bigl(" }, /* paranthesis '(' level 2 */
    { 200, 0xA1, FONT_MATH_EX, "\\bigl(" }, /* paranthesis '(' level 1 */
    { 201, 0x21, FONT_MATH_EX, "\\Biggl)" }, /* paranthesis ')' level 4 */
    { 202, 0xB6, FONT_MATH_EX, "\\biggl)" }, /* paranthesis ')' level 3 */
    { 203, 0xB4, FONT_MATH_EX, "\\Bigl)" }, /* paranthesis ')' level 2 */
    { 204, 0xA2, FONT_MATH_EX, "\\bigl)" }, /* paranthesis ')' level 1 */

    { 205, 0x22, FONT_MATH_EX, "\\Biggl[" }, /* paranthesis '[' level 4 */
    { 206, 0xB7, FONT_MATH_EX, "\\biggl[" }, /* paranthesis '[' level 3 */
    { 207, 0x68, FONT_MATH_EX, "\\Bigl[" }, /* paranthesis '[' level 2 */
    { 208, 0xA3, FONT_MATH_EX, "\\bigl[" }, /* paranthesis '[' level 1 */
    { 209, 0x23, FONT_MATH_EX, "\\Biggl]" }, /* paranthesis ']' level 4 */
    { 210, 0xB8, FONT_MATH_EX, "\\biggl]" }, /* paranthesis ']' level 3 */
    { 211, 0x69, FONT_MATH_EX, "\\Bigl]" }, /* paranthesis ']' level 2 */
    { 212, 0xA4, FONT_MATH_EX, "\\bigl]" }, /* paranthesis ']' level 1 */

    { 213, 0x28, FONT_MATH_EX, "\\Biggl{" }, /* paranthesis '{' level 4 */
    { 214, 0xBD, FONT_MATH_EX, "\\biggl{" }, /* paranthesis '{' level 3 */
    { 215, 0x6E, FONT_MATH_EX, "\\Bigl{" }, /* paranthesis '{' level 2 */
    { 216, 0xA9, FONT_MATH_EX, "\\bigl{" }, /* paranthesis '{' level 1 */
    { 217, 0x29, FONT_MATH_EX, "\\Biggl}" }, /* paranthesis '}' level 4 */
    { 218, 0xBE, FONT_MATH_EX, "\\biggl}" }, /* paranthesis '}' level 3 */
    { 219, 0x6F, FONT_MATH_EX, "\\Bigl}" }, /* paranthesis '}' level 2 */
    { 220, 0xAA, FONT_MATH_EX, "\\bigl}" }, /* paranthesis '}' level 1 */

/* The following are internal(just decided they work for the task) */
    { 221, 0x7B, FONT_NORMAL , "\\_hline"}, /* horizontal line for building stuff */
    { 222, 0x7C, FONT_NORMAL , "\\_hline_long"}, /* longer line? */
    { 223, 0xB9, FONT_NORMAL , "\\_hline_above"}, /* same but displaced above? */

    { 224, 0x3E, FONT_MATH_EX, "\\_vline_small"}, /* those are all vertical lines */
    { 225, 0x3F, FONT_MATH_EX, "\\_vline_1"},
    { 226, 0x36, FONT_MATH_EX, "\\_vline_2"},
    { 227, 0x37, FONT_MATH_EX, "\\_vline_3"},
    { 228, 0x42, FONT_MATH_EX, "\\_vline_4"},
    { 229, 0x43, FONT_MATH_EX, "\\_vline_5"},
    { 230, 0x75, FONT_MATH_EX, "\\_vline_6"}, /* this is a bit different */

    { 231, 0x30, FONT_MATH_EX, "\\_brack_lt_round" },
    { 232, 0x31, FONT_MATH_EX, "\\_brack_rt_round" },
    { 233, 0x40, FONT_MATH_EX, "\\_brack_lb_round" },
    { 234, 0x41, FONT_MATH_EX, "\\_brack_rb_round" },

    { 235, 0x32, FONT_MATH_EX, "\\_brack_lt_square" },
    { 236, 0x33, FONT_MATH_EX, "\\_brack_rt_square" },
    { 237, 0x34, FONT_MATH_EX, "\\_brack_lb_square" },
    { 238, 0x35, FONT_MATH_EX, "\\_brack_rb_square" },

    { 239, 0x38, FONT_MATH_EX, "\\_brack_lt_curly" },
    { 240, 0x39, FONT_MATH_EX, "\\_brack_rt_curly" },
    { 241, 0x3A, FONT_MATH_EX, "\\_brack_lb_curly" },
    { 242, 0x3B, FONT_MATH_EX, "\\_brack_rb_curly" },
    { 243, 0x3C, FONT_MATH_EX, "\\_brack_lc_curly" },
    { 244, 0x3D, FONT_MATH_EX, "\\_brack_rc_curly" },

    { 245, 0x3C, FONT_MATH   , "<" },
    { 246, 0x3E, FONT_MATH   , ">" },
};

#define MATHE_DISTANCER         4
#define MATHE_DISTANCER_BIGO    2

#define MATHE_hash              (math_symbols[  2])
#define MATHE_plus              (math_symbols[ 10])
#define MATHE_comma             (math_symbols[ 11])

#define MATHE_equal             (math_symbols[ 27])

#define MATHE_e                 (math_symbols[ 65])
#define MATHE_a                 (math_symbols[ 61])
#define MATHE_n                 (math_symbols[ 74])

#define MATHE_minus             (math_symbols[181])
#define MATHE_integral          (math_symbols[191])
#define MATHE_sum               (math_symbols[192])

#define MATHE_hline_basic       (math_symbols[221])
#define MATHE_hline_long        (math_symbols[222])
#define MATHE_hline_above       (math_symbols[223])


inline mathe_bracket_sym_t mathe_brack_round = {
    .type = MATHE_BRACKET_ROUND,
    .tl  = math_symbols[231],
    .bl  = math_symbols[233],
    .tr  = math_symbols[232],
    .br  = math_symbols[234],
    .cl  = math_symbols[243],
    .cr  = math_symbols[244],
    .con = math_symbols[225],
    .left = { math_symbols[197], math_symbols[198], math_symbols[199], math_symbols[200] },
    .right = { math_symbols[201], math_symbols[202], math_symbols[203], math_symbols[204] },
};

inline mathe_bracket_sym_t mathe_brack_square = {
    .type = MATHE_BRACKET_SQUARE,
    .tl  = math_symbols[235],
    .bl  = math_symbols[237],
    .tr  = math_symbols[236],
    .br  = math_symbols[238],
    .cl  = math_symbols[243],
    .cr  = math_symbols[244],
    .con = math_symbols[225],
    .left = { math_symbols[205], math_symbols[206], math_symbols[207], math_symbols[208] },
    .right = { math_symbols[209], math_symbols[210], math_symbols[211], math_symbols[212] },
};

inline mathe_bracket_sym_t mathe_brack_curly = {
    .type = MATHE_BRACKET_CURLY,
    .tl  = math_symbols[239],
    .bl  = math_symbols[241],
    .tr  = math_symbols[240],
    .br  = math_symbols[242],
    .cl  = math_symbols[243],
    .cr  = math_symbols[244],
    .con = math_symbols[225],
    .left = { math_symbols[213], math_symbols[214], math_symbols[215], math_symbols[216] },
    .right = { math_symbols[217], math_symbols[218], math_symbols[219], math_symbols[220] },
};


/*                  w
              |<------->|
     _________|_________|
    |                   |
    |                   |
    |                   |
    |                   |
    |                   |
    |         C         |--
    |                   | ^
    |                   | | h
    |                   | |
    |                   | V
    |___________________|--
*/
struct mathe_bb_t {
    float h = 0, w = 0;
};

struct mathe_obj_t {
    mathe_obj_e type;
    int id;

    symbol_t sym;
    mathe_p expr;
    mathe_bb_t bb;
    ImVec2 off = {0, 0};     /* relative position to the origin of the mathe_t object
                            (not the same as the center of the object) */
};

struct mathe_cmd_t {
    mathe_cmd_e type;
    int param = -1;         /* The parameter expresion in used in the command */
    int spawn_id = -1;      /* If not -1, the id of the new block */
    int src_id = -1;        /* If acting on an element, the id of the reference element */
    int dst_id = -1;        /* If acting on an element, the id of the modified element */
    symbol_t sym;           /* In case this is a symbol element */
    mathe_bb_t bb;
};

struct mathe_t {
    mathe_e type;
    int anchor_id = -1;
    std::vector<mathe_cmd_t> cmds;

/* TODO: maybe protect those? */
    std::vector<mathe_obj_t> objs;
    std::map<int, int> id_mapping;
    bool was_init = false;
    float acnhor_y = 0;
    float max_x = 0, max_y = 0, min_x = 0, min_y = 0;
};

inline mathe_bb_t mathe_get_bb(mathe_p m) {
    return mathe_bb_t{
        .h = (m->max_y - m->min_y) / 2.0f,
        .w = (m->max_x - m->min_x) / 2.0f,
    };
}

inline void mathe_recalc_minmax(mathe_p m) {
    m->max_x = m->max_y = m->min_x = m->min_y = 0;
    for (auto &obj : m->objs) {
        // DBG("obj.bb: [.w = %f .h = %f]", obj.bb.w, obj.bb.h);
        m->max_x = std::max(m->max_x, obj.off.x + obj.bb.w);
        m->max_y = std::max(m->max_y, obj.off.y + obj.bb.h);
        m->min_x = std::min(m->min_x, obj.off.x - obj.bb.w);
        m->min_y = std::min(m->min_y, obj.off.y - obj.bb.h);
    }
}

inline int mathe_check_movcmd(mathe_p m, const mathe_cmd_t& cmd) {
    if (cmd.src_id < 0 || !HAS(m->id_mapping, cmd.src_id)) {
        DBG("the command source is invalid: cmd.src_id: %d", cmd.src_id);
        return -1;
    }
    if (cmd.dst_id < 0 || !HAS(m->id_mapping, cmd.dst_id)) {
        DBG("the command destination is invalid");
        return -1;
    }
    return 0;
}

inline mathe_bb_t mathe_symbol_bb(const symbol_t &sym) {
    auto ssz = symbol_get_sz(sym);
    return mathe_bb_t{
        .h = (float)abs(ssz.bl.y - ssz.tr.y) / 2.0f, 
        .w = (float)abs(ssz.bl.x - ssz.tr.x) / 2.0f
    };
}

inline void mathe_draw_bb(const ImVec2& center, const mathe_bb_t& bb, uint32_t color) {
    ImDrawList* draw_list = ImGui::GetWindowDrawList();
    auto bl = center + ImVec2(-bb.w, +bb.h);
    auto tr = center + ImVec2(+bb.w, -bb.h);

    draw_list->AddLine(ImVec2(bl.x, bl.y), ImVec2(tr.x, bl.y), color, 1);
    draw_list->AddLine(ImVec2(tr.x, bl.y), ImVec2(tr.x, tr.y), color, 1);
    draw_list->AddLine(ImVec2(tr.x, tr.y), ImVec2(bl.x, tr.y), color, 1);
    draw_list->AddLine(ImVec2(bl.x, tr.y), ImVec2(bl.x, bl.y), color, 1);
}

inline int mathe_init(mathe_p m, std::vector<mathe_p> params) {
    if (!m) {
        DBG("Invalid object passed for initialization");
        return -1;
    }
    if (m->was_init) {
        DBG("Can't initialize the object twice");
        return -1;
    }
    if (m->anchor_id < 0) {
        DBG("Invalid anchor id: %d", m->anchor_id);
        return -1;
    }
    for (auto &cmd : m->cmds) {
        int id = -1;
        if (cmd.spawn_id != -1) {
            if (HAS(m->id_mapping, cmd.spawn_id)) {
                DBG("Id was already allocated, failing object creation");
                return -1;
            }
            id = cmd.spawn_id;
        }
        switch (cmd.type) {
            case MATHE_EXPR: {
                if (cmd.param < 0) {
                    DBG("A math expresion can't be formed from an unknown param");
                    return -1;
                }
                if (cmd.param >= params.size()) {
                    DBG("Out of bounds parameter");
                    return -1;
                }
                if (!params[cmd.param] || !params[cmd.param]->was_init) {
                    DBG("Parameter must be initialized before using it inside another expresion");
                    return -1;
                }
                mathe_obj_t new_obj {
                    .type = MATHE_OBJ_SUBEXPR,
                    .id = id,
                    .expr = params[cmd.param],
                    .bb = mathe_get_bb(params[cmd.param]),
                };
                m->objs.push_back(new_obj);
                m->id_mapping[id] = m->objs.size() - 1;
            } break;
            case MATHE_SYM: {
                mathe_obj_t new_obj {
                    .type = MATHE_OBJ_SYMB,
                    .id = id,
                    .sym = cmd.sym,
                    .bb = mathe_symbol_bb(cmd.sym),
                };
                DBG("new_obj.bb: [.w = %f .h = %f]", new_obj.bb.w, new_obj.bb.h);
                m->objs.push_back(new_obj);
                m->id_mapping[id] = m->objs.size() - 1;
            } break;
            
            case MATHE_EMPTY: {
                mathe_obj_t new_obj {
                    .type = MATHE_OBJ_EMPTY,
                    .id = id,
                    .bb = cmd.bb,
                };
                m->objs.push_back(new_obj);
                m->id_mapping[id] = m->objs.size() - 1;
            } break;
            case MATHE_MERGE: {
                mathe_recalc_minmax(m);
                auto bb = mathe_get_bb(m);
                mathe_obj_t new_obj {
                    .type = MATHE_OBJ_EMPTY,
                    .id = id,
                    .bb = bb,
                };
                m->objs.push_back(new_obj);
                m->id_mapping[id] = m->objs.size() - 1;
            } break;
            case MATHE_ABOVE: {
                ASSERT_FN(mathe_check_movcmd(m, cmd));

                auto &src = m->objs[m->id_mapping[cmd.src_id]];
                auto &dst = m->objs[m->id_mapping[cmd.dst_id]];

                dst.off = src.off + ImVec2(0, -(src.bb.h + dst.bb.h));
            } break;
            case MATHE_BELLOW: {
                ASSERT_FN(mathe_check_movcmd(m, cmd));

                auto &src = m->objs[m->id_mapping[cmd.src_id]];
                auto &dst = m->objs[m->id_mapping[cmd.dst_id]];

                dst.off = src.off + ImVec2(0, +(src.bb.h + dst.bb.h));
            } break;
            case MATHE_LEFT: {
                ASSERT_FN(mathe_check_movcmd(m, cmd));

                auto &src = m->objs[m->id_mapping[cmd.src_id]];
                auto &dst = m->objs[m->id_mapping[cmd.dst_id]];

                dst.off = src.off + ImVec2(-(src.bb.w + dst.bb.w), 0);
            } break;
            case MATHE_RIGHT: {
                ASSERT_FN(mathe_check_movcmd(m, cmd));

                auto &src = m->objs[m->id_mapping[cmd.src_id]];
                auto &dst = m->objs[m->id_mapping[cmd.dst_id]];

                dst.off = src.off + ImVec2(+(src.bb.w + dst.bb.w), 0);
            } break;
            case MATHE_SUB: {
                ASSERT_FN(mathe_check_movcmd(m, cmd));

                auto &src = m->objs[m->id_mapping[cmd.src_id]];
                auto &dst = m->objs[m->id_mapping[cmd.dst_id]];

                dst.off = src.off + ImVec2(+(src.bb.w + dst.bb.w), src.bb.h);
            } break;
            case MATHE_SUP: {
                ASSERT_FN(mathe_check_movcmd(m, cmd));

                auto &src = m->objs[m->id_mapping[cmd.src_id]];
                auto &dst = m->objs[m->id_mapping[cmd.dst_id]];

                dst.off = src.off + ImVec2(+(src.bb.w + dst.bb.w), -src.bb.h);
            } break;
            case MATHE_MAKEFIT: {
                ASSERT_FN(mathe_check_movcmd(m, cmd));

                auto &src = m->objs[m->id_mapping[cmd.src_id]];
                auto &dst = m->objs[m->id_mapping[cmd.dst_id]];
                dst.bb = mathe_bb_t{
                    .h = std::max(src.bb.h, dst.bb.h),
                    .w = std::max(src.bb.w, dst.bb.w)
                };
            } break;
            default :{
                DBG("This type is not known");
                return -1;
            }
        }
    }
    mathe_recalc_minmax(m);
    if (m->anchor_id >= m->objs.size()) {
        DBG("Invalid anchor id: %d", m->anchor_id);
        return -1;
    }
    m->acnhor_y = m->objs[m->anchor_id].off.y;
    DBG("Anchor[%d]: %f", m->anchor_id, m->acnhor_y);
    m->was_init = true;
    return 0;
}

/* The drawing position is to the left of the bb and on the center of that side  */
inline int mathe_draw(ImVec2 pos, mathe_p m) {
    if (!m || !m->was_init) {
        DBG("Invalid element, can't draw it");
        return -1;
    }
    auto bb = mathe_get_bb(m);
    auto expr_tl = pos + ImVec2(0, -bb.h);
    auto expr_origin = expr_tl + ImVec2(-m->min_x, -m->min_y);
    for (auto &obj : m->objs) {
        auto obj_center = expr_origin + obj.off + ImVec2(0, m->acnhor_y);
        switch (obj.type) {
            case MATHE_OBJ_SUBEXPR: {
                auto subexpr_bb = mathe_get_bb(obj.expr);
                auto subexpr_pos = ImVec2(-subexpr_bb.w, 0) + obj_center;
                ASSERT_FN(mathe_draw(subexpr_pos, obj.expr));
                if (mathe_draw_boxes) {
                    mathe_draw_bb(obj_center, subexpr_bb, 0xff'00ff00);
                    mathe_draw_bb(obj_center, obj.bb, 0xff'00aa00);
                }
            } break;
            case MATHE_OBJ_SYMB: {
                auto ssz = symbol_get_sz(obj.sym);
                auto symb_bb = mathe_symbol_bb(obj.sym);
                auto symb_pos = ImVec2(-symb_bb.w, +symb_bb.h) - ssz.bl - ImVec2(0, -ssz.asc) +
                        obj_center;
                symbol_draw(symb_pos, obj.sym);
                if (mathe_draw_boxes) {
                    mathe_draw_bb(obj_center, symb_bb, 0xff'ff0000);
                    mathe_draw_bb(obj_center, obj.bb, 0xff'aa0000);
                }
            } break;
            case MATHE_OBJ_EMPTY: {
                if (mathe_draw_boxes) {
                    mathe_draw_bb(obj_center, obj.bb, 0xff'0000ff); /* bgr */
                }
            } break;
            default: {
                DBG("Unknown expresion type to draw");
                return -1;
            };
        }
    }
    return 0;
}

inline mathe_p mathe_empty() {
    auto m = mathe_make(mathe_t {
        .type = MATHE_TYPE_EMPTY_BOX,
        .anchor_id = 0,
        .cmds = {
            { .type = MATHE_EMPTY, .spawn_id = 0, .bb = {0, 0} },
        },
    });
    if (mathe_init(m, {}) < 0) {
        DBG("Failed to init object");
        return nullptr;
    }
    return m;
}

inline mathe_p mathe_symbol(symbol_t sym) {
    auto m = mathe_make(mathe_t {
        .type = MATHE_TYPE_SYMBOL,
        .anchor_id = 0,
        .cmds = {
            { .type = MATHE_SYM, .spawn_id = 0, .sym = sym },
        },
    });
    if (mathe_init(m, {}) < 0) {
        DBG("Failed to init object");
        return nullptr;
    }
    return m;
}

inline mathe_p mathe_bigop(mathe_p right, mathe_p above, mathe_p bellow, symbol_t bigop) {
    float distancer = MATHE_DISTANCER_BIGO * symbol_get_lvl_mul(bigop.font_lvl);
    auto m = mathe_make(mathe_t {
        .type = MATHE_TYPE_BIGOP,
        .anchor_id = 0,
        .cmds = {
            { .type = MATHE_SYM, .spawn_id = 0, .sym = bigop },
            { .type = MATHE_EMPTY, .spawn_id = 5, .bb = {distancer, 0}},
            { .type = MATHE_EMPTY, .spawn_id = 6, .bb = {distancer, 0}},
            { .type = MATHE_EXPR, .param = 1, .spawn_id = 2 },
            { .type = MATHE_EXPR, .param = 2, .spawn_id = 3 },
            { .type = MATHE_ABOVE, .src_id = 0, .dst_id = 5 },
            { .type = MATHE_ABOVE, .src_id = 5, .dst_id = 2 },
            { .type = MATHE_BELLOW, .src_id = 0, .dst_id = 6 },
            { .type = MATHE_BELLOW, .src_id = 6, .dst_id = 3 },
            { .type = MATHE_MERGE, .spawn_id = 4 },
            { .type = MATHE_EXPR, .param = 0, .spawn_id = 1 },
            { .type = MATHE_RIGHT, .src_id = 4, .dst_id = 1 },
        },
    });
    if (mathe_init(m, {right, above, bellow}) < 0) {
        DBG("Failed to init object");
        return nullptr;
    }
    return m;
};

inline mathe_p mathe_frac(mathe_p above, mathe_p bellow, symbol_t divline) {
    /* get the bounding boxes of the elements */
    float distancer = MATHE_DISTANCER * symbol_get_lvl_mul(divline.font_lvl);

    auto bb_above = mathe_get_bb(above);
    auto bb_below = mathe_get_bb(bellow);
    auto bb_sym = mathe_symbol_bb(divline);

    /* get the number of frac lines to place */
    int cnt = std::ceil(std::max(bb_above.w, bb_below.w) / bb_sym.w);
    DBG("frac: above: %f bellow: %f sym: %f cnt: %d",
            bb_above.w, bb_below.w, bb_sym.w, cnt);
    if (cnt % 2 == 0)
        cnt++;

    /* create the initial object */
    auto m = mathe_make(mathe_t{
        .type = MATHE_TYPE_FRAC,
        .cmds = {},
    });

    /* create the center line */
    for (int i = 0; i < cnt; i++) {
        m->cmds.push_back({.type = MATHE_SYM, .spawn_id = i, .sym = divline });
    }
    for (int i = 1; i < cnt; i++) {
        m->cmds.push_back({.type = MATHE_RIGHT, .src_id = i-1, .dst_id = i});
    }
    int center = cnt / 2;
    m->anchor_id = center,

    /* add the two elements  */
    m->cmds.push_back({.type = MATHE_EXPR, .param = 0, .spawn_id = cnt  });
    m->cmds.push_back({.type = MATHE_EXPR, .param = 1, .spawn_id = cnt+1});

    /* put the two elements above and bellow the center line */
    m->cmds.push_back({.type = MATHE_EMPTY, .spawn_id = cnt+2, .bb = {distancer, 0}});
    m->cmds.push_back({.type = MATHE_EMPTY, .spawn_id = cnt+3, .bb = {distancer, 0}});
    m->cmds.push_back({.type = MATHE_ABOVE, .src_id = center, .dst_id = cnt+2});
    m->cmds.push_back({.type = MATHE_ABOVE, .src_id = cnt+2, .dst_id = cnt});
    m->cmds.push_back({.type = MATHE_BELLOW, .src_id = center, .dst_id = cnt+3});
    m->cmds.push_back({.type = MATHE_BELLOW, .src_id = cnt+3, .dst_id = cnt+1});

    /* place a filler for the element that is smaller, such that the center line will remain in the
    center */
    // mathe_cmd_e fill_type = MATHE_BELLOW;
    // int fill_id = cnt+1;
    // if (bb_above.h < bb_below.h) {
    //     fill_id = cnt;
    //     fill_type = MATHE_ABOVE;
    // }
    // float fill_sz = (std::max(bb_above.h, bb_below.h) - std::min(bb_above.h, bb_below.h));
    // m->cmds.push_back({.type = MATHE_EMPTY, .spawn_id = cnt+4, .bb = {fill_sz, 0}});
    // m->cmds.push_back({.type = fill_type, .src_id = fill_id, .dst_id = cnt+4});

    if (mathe_init(m, {above, bellow}) < 0) {
        DBG("Failed to init object");
        return nullptr;
    }
    return m;
}

inline mathe_p mathe_supsub(mathe_p base, mathe_p sup, mathe_p sub) {
    auto m = mathe_make(mathe_t {
        .type = MATHE_TYPE_SUPSUB,
        .anchor_id = 0,
        .cmds = {
            { .type = MATHE_EXPR, .param = 0, .spawn_id = 0 },
            { .type = MATHE_EXPR, .param = 1, .spawn_id = 1 },
            { .type = MATHE_EXPR, .param = 2, .spawn_id = 2 },
            { .type = MATHE_SUP, .src_id = 0, .dst_id = 1},
            { .type = MATHE_SUB, .src_id = 0, .dst_id = 2},
        },
    });
    if (mathe_init(m, {base, sup, sub}) < 0) {
        DBG("Failed to init object");
        return nullptr;
    }
    return m;
}

inline mathe_p mathe_bracket(mathe_p expr, mathe_bracket_t bsym) {
    /* TODO: fix brackets to auto-resize */
    auto m = mathe_make(mathe_t {
        .type = MATHE_TYPE_BRACKET,
        .anchor_id = 0,
        .cmds = {
            { .type = MATHE_EXPR, .param = 0, .spawn_id = 0 },
            { .type = MATHE_SYM, .spawn_id = 1, .sym = bsym.left[0] },
            { .type = MATHE_SYM, .spawn_id = 2, .sym = bsym.right[0] },
            { .type = MATHE_LEFT, .src_id = 0, .dst_id = 1 },
            { .type = MATHE_RIGHT, .src_id = 0, .dst_id = 2 },
        },
    });
    if (mathe_init(m, {expr}) < 0) {
        DBG("Failed to init object");
        return nullptr;
    }
    return m;
}

inline mathe_p mathe_unarexpr(symbol_t op, mathe_p b) {
    const float distancer = MATHE_DISTANCER * symbol_get_lvl_mul(op.font_lvl);
    auto m = mathe_make(mathe_t {
        .type = MATHE_TYPE_BRACKET,
        .anchor_id = 0,
        .cmds = {
            { .type = MATHE_EXPR, .param = 0, .spawn_id = 0 },
            { .type = MATHE_SYM, .spawn_id = 1, .sym = op },
            { .type = MATHE_EMPTY, .spawn_id = 2, .bb = {0, distancer} },
            { .type = MATHE_RIGHT, .src_id = 1, .dst_id = 2 },
            { .type = MATHE_RIGHT, .src_id = 2, .dst_id = 0 },
        },
    });
    if (mathe_init(m, {b}) < 0) {
        DBG("Failed to init object");
        return nullptr;
    }
    return m;
}

inline mathe_p mathe_binexpr(mathe_p a, symbol_t op, mathe_p b) {
    float distancer = MATHE_DISTANCER * symbol_get_lvl_mul(op.font_lvl);
    auto m = mathe_make(mathe_t {
        .type = MATHE_TYPE_BRACKET,
        .anchor_id = 2,
        .cmds = {
            { .type = MATHE_EXPR, .param = 0, .spawn_id = 0 },
            { .type = MATHE_EXPR, .param = 1, .spawn_id = 1 },
            { .type = MATHE_SYM, .spawn_id = 2, .sym = op },
            { .type = MATHE_EMPTY, .spawn_id = 3, .bb = {0, distancer} },
            { .type = MATHE_EMPTY, .spawn_id = 4, .bb = {0, distancer} },
            { .type = MATHE_LEFT, .src_id = 2, .dst_id = 3 },
            { .type = MATHE_LEFT, .src_id = 3, .dst_id = 0 },
            { .type = MATHE_RIGHT, .src_id = 2, .dst_id = 4 },
            { .type = MATHE_RIGHT, .src_id = 4, .dst_id = 1 },
        },
    });
    if (mathe_init(m, {a, b}) < 0) {
        DBG("Failed to init object");
        return nullptr;
    }
    return m;
}

inline mathe_p mathe_merge_h(mathe_p l, mathe_p r) {
    auto m = mathe_make(mathe_t {
        .type = MATHE_TYPE_BRACKET,
        .anchor_id = 2,
        .cmds = {
            { .type = MATHE_EXPR, .param = 0, .spawn_id = 0 },
            { .type = MATHE_EXPR, .param = 1, .spawn_id = 1 },
            { .type = MATHE_EMPTY, .spawn_id = 2, .bb = {}},
            { .type = MATHE_RIGHT, .src_id = 0, .dst_id = 2 },
            { .type = MATHE_RIGHT, .src_id = 2, .dst_id = 1 },
        },
    });
    if (mathe_init(m, {l, r}) < 0) {
        DBG("Failed to init object");
        return nullptr;
    }
    return m;
}

inline mathe_p mathe_merge_v(mathe_p u, mathe_p d) {
    auto m = mathe_make(mathe_t {
        .type = MATHE_TYPE_BRACKET,
        .anchor_id = 2,
        .cmds = {
            { .type = MATHE_EXPR, .param = 0, .spawn_id = 0 },
            { .type = MATHE_EXPR, .param = 1, .spawn_id = 1 },
            { .type = MATHE_EMPTY, .spawn_id = 2, .bb = {}},
            { .type = MATHE_BELLOW, .src_id = 0, .dst_id = 2 },
            { .type = MATHE_BELLOW, .src_id = 2, .dst_id = 1 },
        },
    });
    if (mathe_init(m, {u, d}) < 0) {
        DBG("Failed to init object");
        return nullptr;
    }
    return m;
}

template <typename ...Args>
inline mathe_p mathe_make(Args&&... args) {
    return std::make_shared<mathe_t>(std::forward<Args>(args)...);
}

inline symbol_t mathe_convert(mathe_sym_t msym, font_lvl_e font_lvl) {
    return symbol_t{ .code = msym.code, .font_lvl = font_lvl, .font_sub = msym.font };
}

inline mathe_bracket_t mathe_convert(mathe_bracket_sym_t bsym, font_lvl_e font_lvl) {
    return mathe_bracket_t {
        .type = MATHE_BRACKET_CURLY,
        .tl  = mathe_convert(bsym.tl, font_lvl),
        .bl  = mathe_convert(bsym.bl, font_lvl),
        .tr  = mathe_convert(bsym.tr, font_lvl),
        .br  = mathe_convert(bsym.br, font_lvl),
        .cl  = mathe_convert(bsym.cl, font_lvl),
        .cr  = mathe_convert(bsym.cr, font_lvl),
        .con = mathe_convert(bsym.con, font_lvl),
        .left = {
            mathe_convert(bsym.left[0], font_lvl),
            mathe_convert(bsym.left[1], font_lvl),
            mathe_convert(bsym.left[2], font_lvl),
            mathe_convert(bsym.left[3], font_lvl),
        },
        .right = {
            mathe_convert(bsym.right[0], font_lvl),
            mathe_convert(bsym.right[1], font_lvl),
            mathe_convert(bsym.right[2], font_lvl),
            mathe_convert(bsym.right[3], font_lvl),
        },
    };
}

#endif

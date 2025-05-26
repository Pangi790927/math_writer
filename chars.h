#ifndef CHAR_H
#define CHAR_H

#include <string>
#include <vector>

#include <unordered_map>

#include "imgui.h"
#include "imgui_impl_glfw.h"
#include "imgui_impl_opengl3.h"
#include "imgui_internal.h"

#include "misc_utils.h"

enum char_font_num_e : uint64_t {
    FONT_NORMAL,
    FONT_BOLD,
    FONT_ITALIC,
    FONT_MONO,

    FONT_MATH,
    FONT_SYMBOLS,
    FONT_MATH_EX,
};

enum char_font_lvl_e : uint64_t {
    FONT_LVL_SUB0,
    FONT_LVL_SUB1,
    FONT_LVL_SUB2,
    FONT_LVL_SUB3,
    FONT_LVL_SUB4,

    FONT_LVL_CNT,

    /* This is used sometimes for some control characters */
    FONT_LVL_SPECIAL = 0x7,
};

struct char_t {
    union {
        struct {
            uint64_t acod : 8;  /* ascii code, if it happens to be ascii */
            uint64_t fcod : 8;  /* the code inside the font */
            uint64_t fnum : 3;  /* char_font_num_e */
            uint64_t flvl : 3;  /* char_font_lvl_e */
            uint64_t bold : 1;  /* bold T/F */
            uint64_t ital : 1;  /* italiic T/F */
            uint64_t ncod : 8;  /* number code of the symbol */
            uint64_t resv : 32; /* reserved for later use */
        };
        uint64_t code = 0;
    };
};

struct char_desc_t {
    char_t ch;
    char desc[32];
};

struct char_sz_t {
    float adv;          /* how much advance needs to be made till the next glyph */
    float asc;          /* Asecnt */
    float desc;         /* Descent */
    ImVec2 bl, tr;      /* bottom left and top right bounding box of the symbol */
};

inline int chars_init();
inline char_t gchar(int num);
inline char_t gascii(unsigned char c);
inline int chars_cnt();
inline char_desc_t *get_char_desc(int num);

inline char_sz_t char_get_sz(const char_t& c);
inline ImFont *char_get_font(const char_t& c);
inline void char_draw(ImVec2 pos, const char_t& c);
inline bool char_toggle_bb(bool val);
inline float char_get_lvl_mul(char_font_lvl_e lvl);
inline std::pair<ImVec2, ImVec2> char_get_draw_box(ImVec2 pos, const char_t& c);

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

inline bool char_toggle_bb(bool val) {
    auto ret = draw_bb_chars;
    draw_bb_chars = val;
    return ret;
}

inline char_sz_t char_get_sz(const char_t& c) {
    auto font = fonts[c.flvl][c.fnum];
    auto glyph = font->FindGlyphNoFallback(c.fcod);
    if (!glyph) {
        DBG("oops: flvl: %d fnum: %d fcod: %d [%c]",
                (int)c.flvl, (int)c.fnum, (int)c.fcod, (char)c.fcod);
        return {};
        // throw "oops";
    }

    return char_sz_t{
        .adv = glyph->AdvanceX,
        .asc = font->Ascent,
        .desc = font->Descent,
        .bl = ImVec2(glyph->X0, glyph->Y1),
        .tr = ImVec2(glyph->X1, glyph->Y0),
    };
}

inline ImFont *char_get_font(const char_t& c) {
    return fonts[c.flvl][c.fnum];
}

inline std::pair<ImVec2, ImVec2> char_get_draw_box(ImVec2 pos, const char_t& c) {
    auto ssz = char_get_sz(c);

    ImVec2 bl = ssz.bl + pos;
    ImVec2 tr = ssz.tr + pos;

    return {ImVec2{std::min(bl.x, tr.x), std::min(bl.y, tr.y)},
            ImVec2{std::max(bl.x, tr.x), std::max(bl.y, tr.y)}};
}

inline void char_draw(ImVec2 pos, const char_t& c) {
    auto ssz = char_get_sz(c);

    ImDrawList* draw_list = ImGui::GetWindowDrawList();
    ImGuiWindow* window = ImGui::GetCurrentWindow();
    if (window->SkipItems)
        return ;

    ImVec2 bl = ssz.bl + pos;
    ImVec2 tr = ssz.tr + pos;

    /* OBS: RenderChar is the only method that works, for unknown reasons, maybe I can
    fix it?(in imgui). For now the thing will be made out of raw drawing */
    auto font = char_get_font(c);
    ImGui::PushFont(font);
    
    font->RenderChar(draw_list, font->FontSize, pos, 0xff'eeeeee, c.fcod);
    if (draw_bb_chars) {
        draw_list->AddLine(ImVec2(bl.x, bl.y), ImVec2(tr.x, bl.y), 0xff'00ffff, 1);
        draw_list->AddLine(ImVec2(tr.x, bl.y), ImVec2(tr.x, tr.y), 0xff'00ffff, 1);
        draw_list->AddLine(ImVec2(tr.x, tr.y), ImVec2(bl.x, tr.y), 0xff'00ffff, 1);
        draw_list->AddLine(ImVec2(bl.x, tr.y), ImVec2(bl.x, bl.y), 0xff'00ffff, 1);
    }
    ImGui::PopFont();
}




inline int chars_init() {
    ImGuiIO& io = ImGui::GetIO();

    float size_pixels = 42;
    for (int i = 0; i < fonts.size(); i++) {
        for (int j = 0; j < fonts[i].size(); j++) {
            fonts[i][j] = io.Fonts->AddFontFromFileTTF(font_paths[j],
                    font_lvl_mul[i] * size_pixels * font_sub_mul[j]);
         }
    }
    // for (auto &file : list_dir("fonts/amsfonts-ttf")) {
    //     if (!has_ending(file, ".ttf"))
    //         continue;

    //     DBG("file: %s", file.c_str());
    //     io.Fonts->AddFontFromFileTTF(file.c_str(), size_pixels);
    // }
    return 0;
}

inline float char_get_lvl_mul(char_font_lvl_e lvl) {
    return font_lvl_mul[lvl];
}

struct alternative_t {
    int with_alt = 0;
    int with_alt_shift1 = 0;    /* from normal font */
    int with_alt_shift2 = 0;    /* from math font */
};

inline std::unordered_map<uint8_t, alternative_t> greek_alternative = {
    {'a', {.with_alt = 103, .with_alt_shift1 =   0, .with_alt_shift2 = 0}},    /* alpha */
    {'b', {.with_alt = 104, .with_alt_shift1 =   0, .with_alt_shift2 = 0}},    /* beta */
    {'c', {.with_alt = 123, .with_alt_shift1 =   0, .with_alt_shift2 = 0}},    /* chi */
    {'d', {.with_alt = 106, .with_alt_shift1 =  93, .with_alt_shift2 = 127}},  /* delta */
    {'e', {.with_alt = 107, .with_alt_shift1 =   0, .with_alt_shift2 = 0}},    /* epsilon */
    {'f', {.with_alt = 122, .with_alt_shift1 = 100, .with_alt_shift2 = 134}},  /* phi */
    {'g', {.with_alt = 105, .with_alt_shift1 =  92, .with_alt_shift2 = 126}},  /* gamma */
    {'h', {.with_alt =   0, .with_alt_shift1 =   0, .with_alt_shift2 = 0}},     
    {'i', {.with_alt = 111, .with_alt_shift1 =   0, .with_alt_shift2 = 0}},    /* iota */
    {'j', {.with_alt = 124, .with_alt_shift1 = 101, .with_alt_shift2 = 135}},  /* psi */
    {'k', {.with_alt = 112, .with_alt_shift1 =   0, .with_alt_shift2 = 0}},    /* kappa */
    {'l', {.with_alt = 113, .with_alt_shift1 =  95, .with_alt_shift2 = 129}},  /* lambda */     
    {'m', {.with_alt =   0, .with_alt_shift1 =   0, .with_alt_shift2 = 0}},
    {'n', {.with_alt = 109, .with_alt_shift1 =   0, .with_alt_shift2 = 0}},    /* eta */
    {'o', {.with_alt = 110, .with_alt_shift1 =  94, .with_alt_shift2 = 128}},  /* theta */
    {'p', {.with_alt = 117, .with_alt_shift1 =  97, .with_alt_shift2 = 131}},  /* pi */
    {'q', {.with_alt =   0, .with_alt_shift1 =   0, .with_alt_shift2 = 0}},
    {'r', {.with_alt = 118, .with_alt_shift1 =   0, .with_alt_shift2 = 0}},    /* rho */
    {'s', {.with_alt = 119, .with_alt_shift1 =  98, .with_alt_shift2 = 132}},  /* sigma */
    {'t', {.with_alt = 120, .with_alt_shift1 =   0, .with_alt_shift2 = 0}},    /* tau */
    {'u', {.with_alt = 114, .with_alt_shift1 =   0, .with_alt_shift2 = 0}},    /* mu */
    {'v', {.with_alt = 115, .with_alt_shift1 =   0, .with_alt_shift2 = 0}},    /* nu */
    {'w', {.with_alt = 125, .with_alt_shift1 = 102, .with_alt_shift2 = 136}},  /* omega */
    {'x', {.with_alt = 116, .with_alt_shift1 =  96, .with_alt_shift2 = 130}},  /* xi */
    {'y', {.with_alt = 121, .with_alt_shift1 =  99, .with_alt_shift2 = 133}},  /* upsilon */
    {'z', {.with_alt = 108, .with_alt_shift1 =   0, .with_alt_shift2 = 0}},    /* zeta */
};

inline char_desc_t _internal_chars[] = {
    {.ch = {.acod='!', .fcod=0x21, .fnum=FONT_NORMAL , .ncod=  0}, .desc="!" },               /* exclamation mark */
    {.ch = {.acod='"', .fcod=0x22, .fnum=FONT_NORMAL , .ncod=  1}, .desc="\""},               /* double quote */
    {.ch = {.acod='#', .fcod=0x23, .fnum=FONT_NORMAL , .ncod=  2}, .desc="#" },               /* hash */
    {.ch = {.acod='$', .fcod=0x24, .fnum=FONT_NORMAL , .ncod=  3}, .desc="$" },               /* dollar sign */
    {.ch = {.acod='%', .fcod=0x25, .fnum=FONT_NORMAL , .ncod=  4}, .desc="%" },               /* percent sign */
    {.ch = {.acod='&', .fcod=0x26, .fnum=FONT_NORMAL , .ncod=  5}, .desc="&" },               /* ampersand */
    {.ch = {.acod='\'',.fcod=0x27, .fnum=FONT_NORMAL , .ncod=  6}, .desc="'" },               /* single quote */
    {.ch = {.acod='(', .fcod=0x28, .fnum=FONT_NORMAL , .ncod=  7}, .desc="(" },               /* left parenthesis */
    {.ch = {.acod=')', .fcod=0x29, .fnum=FONT_NORMAL , .ncod=  8}, .desc=")" },               /* right parenthesis */
    {.ch = {.acod='*', .fcod=0x2A, .fnum=FONT_NORMAL , .ncod=  9}, .desc="*" },               /* asterisk */
    {.ch = {.acod='+', .fcod=0x2B, .fnum=FONT_NORMAL , .ncod= 10}, .desc="+" },               /* plus sign */
    {.ch = {.acod=',', .fcod=0x2C, .fnum=FONT_NORMAL , .ncod= 11}, .desc="," },               /* comma */
    {.ch = {.acod='-', .fcod=0x2D, .fnum=FONT_NORMAL , .ncod= 12}, .desc="-" },               /* hyphen-minus */
    {.ch = {.acod='.', .fcod=0x2E, .fnum=FONT_NORMAL , .ncod= 13}, .desc="." },               /* period */
    {.ch = {.acod='/', .fcod=0x2F, .fnum=FONT_NORMAL , .ncod= 14}, .desc="/" },               /* slash */
    {.ch = {.acod='0', .fcod=0x30, .fnum=FONT_MATH   , .ncod= 15}, .desc="0" },               /* digit zero */
    {.ch = {.acod='1', .fcod=0x31, .fnum=FONT_MATH   , .ncod= 16}, .desc="1" },               /* digit one */
    {.ch = {.acod='2', .fcod=0x32, .fnum=FONT_MATH   , .ncod= 17}, .desc="2" },               /* digit two */
    {.ch = {.acod='3', .fcod=0x33, .fnum=FONT_MATH   , .ncod= 18}, .desc="3" },               /* digit three */
    {.ch = {.acod='4', .fcod=0x34, .fnum=FONT_MATH   , .ncod= 19}, .desc="4" },               /* digit four */
    {.ch = {.acod='5', .fcod=0x35, .fnum=FONT_MATH   , .ncod= 20}, .desc="5" },               /* digit five */
    {.ch = {.acod='6', .fcod=0x36, .fnum=FONT_MATH   , .ncod= 21}, .desc="6" },               /* digit six */
    {.ch = {.acod='7', .fcod=0x37, .fnum=FONT_MATH   , .ncod= 22}, .desc="7" },               /* digit seven */
    {.ch = {.acod='8', .fcod=0x38, .fnum=FONT_MATH   , .ncod= 23}, .desc="8" },               /* digit eight */
    {.ch = {.acod='9', .fcod=0x39, .fnum=FONT_MATH   , .ncod= 24}, .desc="9" },               /* digit nine */
    {.ch = {.acod=':', .fcod=0x3A, .fnum=FONT_NORMAL , .ncod= 25}, .desc=":" },               /* colon */
    {.ch = {.acod=';', .fcod=0x3B, .fnum=FONT_NORMAL , .ncod= 26}, .desc=";" },               /* semicolon */
    {.ch = {.acod='=', .fcod=0x3D, .fnum=FONT_NORMAL , .ncod= 27}, .desc="=" },               /* equals sign */
    {.ch = {.acod='?', .fcod=0x3F, .fnum=FONT_NORMAL , .ncod= 28}, .desc="?" },               /* question mark */
    {.ch = {.acod='@', .fcod=0x40, .fnum=FONT_NORMAL , .ncod= 29}, .desc="@" },               /* at symbol */
    {.ch = {.acod='A', .fcod=0x41, .fnum=FONT_MATH   , .ncod= 30}, .desc="A" },               /* uppercase A */
    {.ch = {.acod='B', .fcod=0x42, .fnum=FONT_MATH   , .ncod= 31}, .desc="B" },               /* uppercase B */
    {.ch = {.acod='C', .fcod=0x43, .fnum=FONT_MATH   , .ncod= 32}, .desc="C" },               /* uppercase C */
    {.ch = {.acod='D', .fcod=0x44, .fnum=FONT_MATH   , .ncod= 33}, .desc="D" },               /* uppercase D */
    {.ch = {.acod='E', .fcod=0x45, .fnum=FONT_MATH   , .ncod= 34}, .desc="E" },               /* uppercase E */
    {.ch = {.acod='F', .fcod=0x46, .fnum=FONT_MATH   , .ncod= 35}, .desc="F" },               /* uppercase F */
    {.ch = {.acod='G', .fcod=0x47, .fnum=FONT_MATH   , .ncod= 36}, .desc="G" },               /* uppercase G */
    {.ch = {.acod='H', .fcod=0x48, .fnum=FONT_MATH   , .ncod= 37}, .desc="H" },               /* uppercase H */
    {.ch = {.acod='I', .fcod=0x49, .fnum=FONT_MATH   , .ncod= 38}, .desc="I" },               /* uppercase I */
    {.ch = {.acod='J', .fcod=0x4A, .fnum=FONT_MATH   , .ncod= 39}, .desc="J" },               /* uppercase J */
    {.ch = {.acod='K', .fcod=0x4B, .fnum=FONT_MATH   , .ncod= 40}, .desc="K" },               /* uppercase K */
    {.ch = {.acod='L', .fcod=0x4C, .fnum=FONT_MATH   , .ncod= 41}, .desc="L" },               /* uppercase L */
    {.ch = {.acod='M', .fcod=0x4D, .fnum=FONT_MATH   , .ncod= 42}, .desc="M" },               /* uppercase M */
    {.ch = {.acod='N', .fcod=0x4E, .fnum=FONT_MATH   , .ncod= 43}, .desc="N" },               /* uppercase N */
    {.ch = {.acod='O', .fcod=0x4F, .fnum=FONT_MATH   , .ncod= 44}, .desc="O" },               /* uppercase O */
    {.ch = {.acod='P', .fcod=0x50, .fnum=FONT_MATH   , .ncod= 45}, .desc="P" },               /* uppercase P */
    {.ch = {.acod='Q', .fcod=0x51, .fnum=FONT_MATH   , .ncod= 46}, .desc="Q" },               /* uppercase Q */
    {.ch = {.acod='R', .fcod=0x52, .fnum=FONT_MATH   , .ncod= 47}, .desc="R" },               /* uppercase R */
    {.ch = {.acod='S', .fcod=0x53, .fnum=FONT_MATH   , .ncod= 48}, .desc="S" },               /* uppercase S */
    {.ch = {.acod='T', .fcod=0x54, .fnum=FONT_MATH   , .ncod= 49}, .desc="T" },               /* uppercase T */
    {.ch = {.acod='U', .fcod=0x55, .fnum=FONT_MATH   , .ncod= 50}, .desc="U" },               /* uppercase U */
    {.ch = {.acod='V', .fcod=0x56, .fnum=FONT_MATH   , .ncod= 51}, .desc="V" },               /* uppercase V */
    {.ch = {.acod='W', .fcod=0x57, .fnum=FONT_MATH   , .ncod= 52}, .desc="W" },               /* uppercase W */
    {.ch = {.acod='X', .fcod=0x58, .fnum=FONT_MATH   , .ncod= 53}, .desc="X" },               /* uppercase X */
    {.ch = {.acod='Y', .fcod=0x59, .fnum=FONT_MATH   , .ncod= 54}, .desc="Y" },               /* uppercase Y */
    {.ch = {.acod='Z', .fcod=0x5A, .fnum=FONT_MATH   , .ncod= 55}, .desc="Z" },               /* uppercase Z */
    {.ch = {.acod='[', .fcod=0x5B, .fnum=FONT_NORMAL , .ncod= 56}, .desc="[" },               /* left square bracket */
    {.ch = {.acod=']', .fcod=0x5D, .fnum=FONT_NORMAL , .ncod= 57}, .desc="]" },               /* right square bracket */
    {.ch = {.acod='^', .fcod=0x5E, .fnum=FONT_NORMAL , .ncod= 58}, .desc="^" },               /* circumflex accent */
    {.ch = {.acod='_', .fcod=0x5F, .fnum=FONT_MONO   , .ncod= 59}, .desc="_" },               /* underscore */
    {.ch = {.acod='`', .fcod=0xB5, .fnum=FONT_NORMAL , .ncod= 60}, .desc="`" },               /* grave accent */
    {.ch = {.acod='a', .fcod=0x61, .fnum=FONT_MATH   , .ncod= 61}, .desc="a" },               /* lowercase a */
    {.ch = {.acod='b', .fcod=0x62, .fnum=FONT_MATH   , .ncod= 62}, .desc="b" },               /* lowercase b */
    {.ch = {.acod='c', .fcod=0x63, .fnum=FONT_MATH   , .ncod= 63}, .desc="c" },               /* lowercase c */
    {.ch = {.acod='d', .fcod=0x64, .fnum=FONT_MATH   , .ncod= 64}, .desc="d" },               /* lowercase d */
    {.ch = {.acod='e', .fcod=0x65, .fnum=FONT_MATH   , .ncod= 65}, .desc="e" },               /* lowercase e */
    {.ch = {.acod='f', .fcod=0x66, .fnum=FONT_MATH   , .ncod= 66}, .desc="f" },               /* lowercase f */
    {.ch = {.acod='g', .fcod=0x67, .fnum=FONT_MATH   , .ncod= 67}, .desc="g" },               /* lowercase g */
    {.ch = {.acod='h', .fcod=0x68, .fnum=FONT_MATH   , .ncod= 68}, .desc="h" },               /* lowercase h */
    {.ch = {.acod='i', .fcod=0x69, .fnum=FONT_MATH   , .ncod= 69}, .desc="i" },               /* lowercase i */
    {.ch = {.acod='j', .fcod=0x6A, .fnum=FONT_MATH   , .ncod= 70}, .desc="j" },               /* lowercase j */
    {.ch = {.acod='k', .fcod=0x6B, .fnum=FONT_MATH   , .ncod= 71}, .desc="k" },               /* lowercase k */
    {.ch = {.acod='l', .fcod=0x6C, .fnum=FONT_MATH   , .ncod= 72}, .desc="l" },               /* lowercase l */
    {.ch = {.acod='m', .fcod=0x6D, .fnum=FONT_MATH   , .ncod= 73}, .desc="m" },               /* lowercase m */
    {.ch = {.acod='n', .fcod=0x6E, .fnum=FONT_MATH   , .ncod= 74}, .desc="n" },               /* lowercase n */
    {.ch = {.acod='o', .fcod=0x6F, .fnum=FONT_MATH   , .ncod= 75}, .desc="o" },               /* lowercase o */
    {.ch = {.acod='p', .fcod=0x70, .fnum=FONT_MATH   , .ncod= 76}, .desc="p" },               /* lowercase p */
    {.ch = {.acod='q', .fcod=0x71, .fnum=FONT_MATH   , .ncod= 77}, .desc="q" },               /* lowercase q */
    {.ch = {.acod='r', .fcod=0x72, .fnum=FONT_MATH   , .ncod= 78}, .desc="r" },               /* lowercase r */
    {.ch = {.acod='s', .fcod=0x73, .fnum=FONT_MATH   , .ncod= 79}, .desc="s" },               /* lowercase s */
    {.ch = {.acod='t', .fcod=0x74, .fnum=FONT_MATH   , .ncod= 80}, .desc="t" },               /* lowercase t */
    {.ch = {.acod='u', .fcod=0x75, .fnum=FONT_MATH   , .ncod= 81}, .desc="u" },               /* lowercase u */
    {.ch = {.acod='v', .fcod=0x76, .fnum=FONT_MATH   , .ncod= 82}, .desc="v" },               /* lowercase v */
    {.ch = {.acod='w', .fcod=0x77, .fnum=FONT_MATH   , .ncod= 83}, .desc="w" },               /* lowercase w */
    {.ch = {.acod='x', .fcod=0x78, .fnum=FONT_MATH   , .ncod= 84}, .desc="x" },               /* lowercase x */
    {.ch = {.acod='y', .fcod=0x79, .fnum=FONT_MATH   , .ncod= 85}, .desc="y" },               /* lowercase y */
    {.ch = {.acod='z', .fcod=0x7A, .fnum=FONT_MATH   , .ncod= 86}, .desc="z" },               /* lowercase z */
    {.ch = {.acod='{', .fcod=0x66, .fnum=FONT_SYMBOLS, .ncod= 87}, .desc="{" },               /* left curly brace */
    {.ch = {.acod='|', .fcod=0x6A, .fnum=FONT_SYMBOLS, .ncod= 88}, .desc="|" },               /* vertical bar */
    {.ch = {.acod='}', .fcod=0x67, .fnum=FONT_SYMBOLS, .ncod= 89}, .desc="}" },               /* right curly brace */
    {.ch = {.acod='~', .fcod=0x7E, .fnum=FONT_NORMAL , .ncod= 90}, .desc="~" },               /* tilde */
    {.ch = {.acod='\\',.fcod=0x6E, .fnum=FONT_SYMBOLS, .ncod= 91}, .desc="\\"},               /* backslash */
    {.ch = {.acod='\0',.fcod=0xA1, .fnum=FONT_NORMAL , .ncod= 92}, .desc="\\Gamma" },         /* Greek uppercase Gamma */
    {.ch = {.acod='\0',.fcod=0xA2, .fnum=FONT_NORMAL , .ncod= 93}, .desc="\\Delta" },         /* Greek uppercase Delta */
    {.ch = {.acod='\0',.fcod=0xA3, .fnum=FONT_NORMAL , .ncod= 94}, .desc="\\Theta" },         /* Greek uppercase Theta */
    {.ch = {.acod='\0',.fcod=0xA4, .fnum=FONT_NORMAL , .ncod= 95}, .desc="\\Lambda" },        /* Greek uppercase Lambda */
    {.ch = {.acod='\0',.fcod=0xA5, .fnum=FONT_NORMAL , .ncod= 96}, .desc="\\Xi" },            /* Greek uppercase Xi */
    {.ch = {.acod='\0',.fcod=0xA6, .fnum=FONT_NORMAL , .ncod= 97}, .desc="\\Pi" },            /* Greek uppercase Pi */
    {.ch = {.acod='\0',.fcod=0xA7, .fnum=FONT_NORMAL , .ncod= 98}, .desc="\\Sigma" },         /* Greek uppercase Sigma */
    {.ch = {.acod='\0',.fcod=0xA8, .fnum=FONT_NORMAL , .ncod= 99}, .desc="\\Upsilon" },       /* Greek uppercase Upsilon */
    {.ch = {.acod='\0',.fcod=0xA9, .fnum=FONT_NORMAL , .ncod=100}, .desc="\\Phi" },           /* Greek uppercase Phi */
    {.ch = {.acod='\0',.fcod=0xAA, .fnum=FONT_NORMAL , .ncod=101}, .desc="\\Psi" },           /* Greek uppercase Psi */
    {.ch = {.acod='\0',.fcod=0xAB, .fnum=FONT_NORMAL , .ncod=102}, .desc="\\Omega" },         /* Greek uppercase Omega */
    {.ch = {.acod='\0',.fcod=0xAE, .fnum=FONT_MATH   , .ncod=103}, .desc="\\alpha" },         /* Greek lowercase alpha */
    {.ch = {.acod='\0',.fcod=0xAF, .fnum=FONT_MATH   , .ncod=104}, .desc="\\beta" },          /* Greek lowercase beta */
    {.ch = {.acod='\0',.fcod=0xB0, .fnum=FONT_MATH   , .ncod=105}, .desc="\\gamma" },         /* Greek lowercase gamma */
    {.ch = {.acod='\0',.fcod=0xB1, .fnum=FONT_MATH   , .ncod=106}, .desc="\\delta" },         /* Greek lowercase delta */
    {.ch = {.acod='\0',.fcod=0xB2, .fnum=FONT_MATH   , .ncod=107}, .desc="\\epsilon" },       /* Greek lowercase epsilon */
    {.ch = {.acod='\0',.fcod=0xB3, .fnum=FONT_MATH   , .ncod=108}, .desc="\\zeta" },          /* Greek lowercase zeta */
    {.ch = {.acod='\0',.fcod=0xB4, .fnum=FONT_MATH   , .ncod=109}, .desc="\\eta" },           /* Greek lowercase eta */
    {.ch = {.acod='\0',.fcod=0xB5, .fnum=FONT_MATH   , .ncod=110}, .desc="\\theta" },         /* Greek lowercase theta */
    {.ch = {.acod='\0',.fcod=0xB6, .fnum=FONT_MATH   , .ncod=111}, .desc="\\iota" },          /* Greek lowercase iota */
    {.ch = {.acod='\0',.fcod=0xB7, .fnum=FONT_MATH   , .ncod=112}, .desc="\\kappa" },         /* Greek lowercase kappa */
    {.ch = {.acod='\0',.fcod=0xB8, .fnum=FONT_MATH   , .ncod=113}, .desc="\\lambda" },        /* Greek lowercase lambda */
    {.ch = {.acod='\0',.fcod=0xB9, .fnum=FONT_MATH   , .ncod=114}, .desc="\\mu" },            /* Greek lowercase mu */
    {.ch = {.acod='\0',.fcod=0xBA, .fnum=FONT_MATH   , .ncod=115}, .desc="\\nu" },            /* Greek lowercase nu */
    {.ch = {.acod='\0',.fcod=0xBB, .fnum=FONT_MATH   , .ncod=116}, .desc="\\xi" },            /* Greek lowercase xi */
    {.ch = {.acod='\0',.fcod=0xBC, .fnum=FONT_MATH   , .ncod=117}, .desc="\\pi" },            /* Greek lowercase pi */
    {.ch = {.acod='\0',.fcod=0xBD, .fnum=FONT_MATH   , .ncod=118}, .desc="\\rho" },           /* Greek lowercase rho */
    {.ch = {.acod='\0',.fcod=0xBE, .fnum=FONT_MATH   , .ncod=119}, .desc="\\sigma" },         /* Greek lowercase sigma */
    {.ch = {.acod='\0',.fcod=0xBF, .fnum=FONT_MATH   , .ncod=120}, .desc="\\tau" },           /* Greek lowercase tau */
    {.ch = {.acod='\0',.fcod=0xC0, .fnum=FONT_MATH   , .ncod=121}, .desc="\\upsilon" },       /* Greek lowercase upsilon */
    {.ch = {.acod='\0',.fcod=0xC1, .fnum=FONT_MATH   , .ncod=122}, .desc="\\phi" },           /* Greek lowercase phi */
    {.ch = {.acod='\0',.fcod=0xC2, .fnum=FONT_MATH   , .ncod=123}, .desc="\\chi" },           /* Greek lowercase chi */
    {.ch = {.acod='\0',.fcod=0xC3, .fnum=FONT_MATH   , .ncod=124}, .desc="\\psi" },           /* Greek lowercase psi */
    {.ch = {.acod='\0',.fcod=0x21, .fnum=FONT_MATH   , .ncod=125}, .desc="\\omega" },         /* Greek lowercase omega */
    {.ch = {.acod='\0',.fcod=0xA1, .fnum=FONT_MATH   , .ncod=126}, .desc="\\Gamma" },         /* Greek uppercase Gamma */
    {.ch = {.acod='\0',.fcod=0xA2, .fnum=FONT_MATH   , .ncod=127}, .desc="\\Delta" },         /* Greek uppercase Delta */
    {.ch = {.acod='\0',.fcod=0xA3, .fnum=FONT_MATH   , .ncod=128}, .desc="\\Theta" },         /* Greek uppercase Theta */
    {.ch = {.acod='\0',.fcod=0xA4, .fnum=FONT_MATH   , .ncod=129}, .desc="\\Lambda" },        /* Greek uppercase Lambda */
    {.ch = {.acod='\0',.fcod=0xA5, .fnum=FONT_MATH   , .ncod=130}, .desc="\\Xi" },            /* Greek uppercase Xi */
    {.ch = {.acod='\0',.fcod=0xA6, .fnum=FONT_MATH   , .ncod=131}, .desc="\\Pi" },            /* Greek uppercase Pi */
    {.ch = {.acod='\0',.fcod=0xA7, .fnum=FONT_MATH   , .ncod=132}, .desc="\\Sigma" },         /* Greek uppercase Sigma */
    {.ch = {.acod='\0',.fcod=0xA8, .fnum=FONT_MATH   , .ncod=133}, .desc="\\Upsilon" },       /* Greek uppercase Upsilon */
    {.ch = {.acod='\0',.fcod=0xA9, .fnum=FONT_MATH   , .ncod=134}, .desc="\\Phi" },           /* Greek uppercase Phi */
    {.ch = {.acod='\0',.fcod=0xAA, .fnum=FONT_MATH   , .ncod=135}, .desc="\\Psi" },           /* Greek uppercase Psi */
    {.ch = {.acod='\0',.fcod=0xAB, .fnum=FONT_MATH   , .ncod=136}, .desc="\\Omega" },         /* Greek uppercase Omega */
    {.ch = {.acod='\0',.fcod=0xC3, .fnum=FONT_SYMBOLS, .ncod=137}, .desc="\\leftarrow" },     /* left arrow */
    {.ch = {.acod='\0',.fcod=0x21, .fnum=FONT_SYMBOLS, .ncod=138}, .desc="\\rightarrow" },    /* right arrow */
    {.ch = {.acod='\0',.fcod=0x22, .fnum=FONT_SYMBOLS, .ncod=139}, .desc="\\uparrow" },       /* up arrow */
    {.ch = {.acod='\0',.fcod=0x23, .fnum=FONT_SYMBOLS, .ncod=140}, .desc="\\downarrow" },     /* down arrow */
    {.ch = {.acod='\0',.fcod=0x24, .fnum=FONT_SYMBOLS, .ncod=141}, .desc="\\leftrightarrow" },/* left-right arrow */
    {.ch = {.acod='\0',.fcod=0x25, .fnum=FONT_SYMBOLS, .ncod=142}, .desc="\\nearrow" },       /* north-east arrow */
    {.ch = {.acod='\0',.fcod=0x26, .fnum=FONT_SYMBOLS, .ncod=143}, .desc="\\searrow" },       /* south-east arrow */
    {.ch = {.acod='\0',.fcod=0x27, .fnum=FONT_SYMBOLS, .ncod=144}, .desc="\\simeq" },         /* approximately equal */
    {.ch = {.acod='\0',.fcod=0x28, .fnum=FONT_SYMBOLS, .ncod=145}, .desc="\\Leftarrow" },     /* left double arrow */
    {.ch = {.acod='\0',.fcod=0x29, .fnum=FONT_SYMBOLS, .ncod=146}, .desc="\\Rightarrow" },    /* right double arrow */
    {.ch = {.acod='\0',.fcod=0x2A, .fnum=FONT_SYMBOLS, .ncod=147}, .desc="\\Uparrow" },       /* up double arrow */
    {.ch = {.acod='\0',.fcod=0x2B, .fnum=FONT_SYMBOLS, .ncod=148}, .desc="\\Downarrow" },     /* down double arrow */
    {.ch = {.acod='\0',.fcod=0x2C, .fnum=FONT_SYMBOLS, .ncod=149}, .desc="\\Leftrightarrow" },/* left-right double arrow */
    {.ch = {.acod='\0',.fcod=0x2D, .fnum=FONT_SYMBOLS, .ncod=150}, .desc="\\nwarrow" },       /* north-west arrow */
    {.ch = {.acod='\0',.fcod=0x2E, .fnum=FONT_SYMBOLS, .ncod=151}, .desc="\\swarrow" },       /* south-west arrow */
    {.ch = {.acod='\0',.fcod=0x2F, .fnum=FONT_SYMBOLS, .ncod=152}, .desc="\\propto" },        /* proportional to */
    {.ch = {.acod='\0',.fcod=0x30, .fnum=FONT_SYMBOLS, .ncod=153}, .desc="\\partial" },       /* partial derivative */
    {.ch = {.acod='\0',.fcod=0x31, .fnum=FONT_SYMBOLS, .ncod=154}, .desc="\\infty" },         /* infinity */
    {.ch = {.acod='\0',.fcod=0x32, .fnum=FONT_SYMBOLS, .ncod=155}, .desc="\\in" },            /* element of */
    {.ch = {.acod='\0',.fcod=0x33, .fnum=FONT_SYMBOLS, .ncod=156}, .desc="\\ni" },            /* element of backwards */
    {.ch = {.acod='\0',.fcod=0x35, .fnum=FONT_SYMBOLS, .ncod=157}, .desc="\\nabla" },         /* nabla */
    {.ch = {.acod='/', .fcod=0x36, .fnum=FONT_SYMBOLS, .ncod=158}, .desc="/" },               /* forward slash */
    {.ch = {.acod='\0',.fcod=0x38, .fnum=FONT_SYMBOLS, .ncod=159}, .desc="\\forall" },        /* for all */
    {.ch = {.acod='\0',.fcod=0x39, .fnum=FONT_SYMBOLS, .ncod=160}, .desc="\\exists" },        /* exists */
    {.ch = {.acod='\0',.fcod=0x3A, .fnum=FONT_SYMBOLS, .ncod=161}, .desc="\\neg" },           /* negation */
    {.ch = {.acod='\0',.fcod=0x3B, .fnum=FONT_SYMBOLS, .ncod=162}, .desc="\\emptyset" },      /* empty set */
    {.ch = {.acod='\0',.fcod=0x3C, .fnum=FONT_SYMBOLS, .ncod=163}, .desc="\\Re" },            /* real part */
    {.ch = {.acod='\0',.fcod=0x3D, .fnum=FONT_SYMBOLS, .ncod=164}, .desc="\\Im" },            /* imaginary part */
    {.ch = {.acod='\0',.fcod=0x3E, .fnum=FONT_SYMBOLS, .ncod=165}, .desc="\\top" },           /* top */
    {.ch = {.acod='\0',.fcod=0x3F, .fnum=FONT_SYMBOLS, .ncod=166}, .desc="\\bot" },           /* bottom */
    {.ch = {.acod='\0',.fcod=0x40, .fnum=FONT_SYMBOLS, .ncod=167}, .desc="\\aleph" },         /* aleph */
    {.ch = {.acod='\0',.fcod=0x5B, .fnum=FONT_SYMBOLS, .ncod=168}, .desc="\\cup" },           /* union */
    {.ch = {.acod='\0',.fcod=0x5C, .fnum=FONT_SYMBOLS, .ncod=169}, .desc="\\cap" },           /* intersection */
    {.ch = {.acod='\0',.fcod=0x5D, .fnum=FONT_SYMBOLS, .ncod=170}, .desc="\\uplus" },         /* multiset union */
    {.ch = {.acod='\0',.fcod=0x5E, .fnum=FONT_SYMBOLS, .ncod=171}, .desc="\\wedge" },         /* logical and */
    {.ch = {.acod='\0',.fcod=0x5F, .fnum=FONT_SYMBOLS, .ncod=172}, .desc="\\vee" },           /* logical or */
    {.ch = {.acod='\0',.fcod=0x66, .fnum=FONT_SYMBOLS, .ncod=173}, .desc="\\{" },             /* DUPLICATE - left brace */
    {.ch = {.acod='\0',.fcod=0x67, .fnum=FONT_SYMBOLS, .ncod=174}, .desc="\\}" },             /* DUPLICATE - right brace */
    {.ch = {.acod='\0',.fcod=0x6A, .fnum=FONT_SYMBOLS, .ncod=175}, .desc="\\|" },             /* vertical bar */
    {.ch = {.acod='\0',.fcod=0x6B, .fnum=FONT_SYMBOLS, .ncod=176}, .desc="\\parallel" },      /* parallel */
    {.ch = {.acod='\0',.fcod=0xBF, .fnum=FONT_SYMBOLS, .ncod=177}, .desc="\\ll" },            /* much less than */
    {.ch = {.acod='\0',.fcod=0xC0, .fnum=FONT_SYMBOLS, .ncod=178}, .desc="\\gg" },            /* much greater than */
    {.ch = {.acod='\0',.fcod=0xB1, .fnum=FONT_SYMBOLS, .ncod=179}, .desc="\\circ" },          /* circle */
    {.ch = {.acod='\0',.fcod=0xB2, .fnum=FONT_SYMBOLS, .ncod=180}, .desc="\\bullet" },        /* bullet */
    {.ch = {.acod='-' ,.fcod=0xA1, .fnum=FONT_SYMBOLS, .ncod=181}, .desc="-" },               /* minus sign */
    {.ch = {.acod='\0',.fcod=0xA3, .fnum=FONT_SYMBOLS, .ncod=182}, .desc="\\times" },         /* multiplication sign */
    {.ch = {.acod='\0',.fcod=0xA5, .fnum=FONT_SYMBOLS, .ncod=183}, .desc="\\div" },           /* division sign */
    {.ch = {.acod='\0',.fcod=0xA7, .fnum=FONT_SYMBOLS, .ncod=184}, .desc="\\pm" },            /* plus-minus sign */
    {.ch = {.acod='\0',.fcod=0xA8, .fnum=FONT_SYMBOLS, .ncod=185}, .desc="\\mp" },            /* minus-plus sign */
    {.ch = {.acod='\0',.fcod=0xB7, .fnum=FONT_SYMBOLS, .ncod=186}, .desc="\\le" },            /* less than or equal */
    {.ch = {.acod='\0',.fcod=0xB8, .fnum=FONT_SYMBOLS, .ncod=187}, .desc="\\ge" },            /* greater than or equal */
    {.ch = {.acod='\0',.fcod=0xB4, .fnum=FONT_SYMBOLS, .ncod=188}, .desc="\\cong" },          /* congruent */
    {.ch = {.acod='\0',.fcod=0xB6, .fnum=FONT_SYMBOLS, .ncod=189}, .desc="\\supseteq" },      /* superset equal */
    {.ch = {.acod='\0',.fcod=0xB5, .fnum=FONT_SYMBOLS, .ncod=190}, .desc="\\subseteq" },      /* subset equal */
    {.ch = {.acod='\0',.fcod=0x5A, .fnum=FONT_MATH_EX, .ncod=191}, .desc="\\int" },           /* integration sign */
    {.ch = {.acod='\0',.fcod=0x58, .fnum=FONT_MATH_EX, .ncod=192}, .desc="\\sum" },           /* summation sign */
    {.ch = {.acod='\0',.fcod=0x59, .fnum=FONT_MATH_EX, .ncod=193}, .desc="\\prod" },          /* product sign */
    {.ch = {.acod='\0',.fcod=0x5B, .fnum=FONT_MATH_EX, .ncod=194}, .desc="\\bigcup" },        /* large union */
    {.ch = {.acod='\0',.fcod=0x5C, .fnum=FONT_MATH_EX, .ncod=195}, .desc="\\bigcap" },        /* large intersection */
    {.ch = {.acod='\0',.fcod=0x49, .fnum=FONT_MATH_EX, .ncod=196}, .desc="\\oint" },          /* circle integral */
    {.ch = {.acod='\0',.fcod=0xC3, .fnum=FONT_MATH_EX, .ncod=197}, .desc="\\Biggl(" },        /* paranthesis '(' level 4 */
    {.ch = {.acod='\0',.fcod=0xB5, .fnum=FONT_MATH_EX, .ncod=198}, .desc="\\biggl(" },        /* paranthesis '(' level 3 */
    {.ch = {.acod='\0',.fcod=0xB3, .fnum=FONT_MATH_EX, .ncod=199}, .desc="\\Bigl(" },         /* paranthesis '(' level 2 */
    {.ch = {.acod='\0',.fcod=0xA1, .fnum=FONT_MATH_EX, .ncod=200}, .desc="\\bigl(" },         /* paranthesis '(' level 1 */
    {.ch = {.acod='\0',.fcod=0x21, .fnum=FONT_MATH_EX, .ncod=201}, .desc="\\Biggl)" },        /* paranthesis ')' level 4 */
    {.ch = {.acod='\0',.fcod=0xB6, .fnum=FONT_MATH_EX, .ncod=202}, .desc="\\biggl)" },        /* paranthesis ')' level 3 */
    {.ch = {.acod='\0',.fcod=0xB4, .fnum=FONT_MATH_EX, .ncod=203}, .desc="\\Bigl)" },         /* paranthesis ')' level 2 */
    {.ch = {.acod='\0',.fcod=0xA2, .fnum=FONT_MATH_EX, .ncod=204}, .desc="\\bigl)" },         /* paranthesis ')' level 1 */
    {.ch = {.acod='\0',.fcod=0x22, .fnum=FONT_MATH_EX, .ncod=205}, .desc="\\Biggl[" },        /* paranthesis '[' level 4 */
    {.ch = {.acod='\0',.fcod=0xB7, .fnum=FONT_MATH_EX, .ncod=206}, .desc="\\biggl[" },        /* paranthesis '[' level 3 */
    {.ch = {.acod='\0',.fcod=0x68, .fnum=FONT_MATH_EX, .ncod=207}, .desc="\\Bigl[" },         /* paranthesis '[' level 2 */
    {.ch = {.acod='\0',.fcod=0xA3, .fnum=FONT_MATH_EX, .ncod=208}, .desc="\\bigl[" },         /* paranthesis '[' level 1 */
    {.ch = {.acod='\0',.fcod=0x23, .fnum=FONT_MATH_EX, .ncod=209}, .desc="\\Biggl]" },        /* paranthesis ']' level 4 */
    {.ch = {.acod='\0',.fcod=0xB8, .fnum=FONT_MATH_EX, .ncod=210}, .desc="\\biggl]" },        /* paranthesis ']' level 3 */
    {.ch = {.acod='\0',.fcod=0x69, .fnum=FONT_MATH_EX, .ncod=211}, .desc="\\Bigl]" },         /* paranthesis ']' level 2 */
    {.ch = {.acod='\0',.fcod=0xA4, .fnum=FONT_MATH_EX, .ncod=212}, .desc="\\bigl]" },         /* paranthesis ']' level 1 */
    {.ch = {.acod='\0',.fcod=0x28, .fnum=FONT_MATH_EX, .ncod=213}, .desc="\\Biggl{" },        /* paranthesis '{' level 4 */
    {.ch = {.acod='\0',.fcod=0xBD, .fnum=FONT_MATH_EX, .ncod=214}, .desc="\\biggl{" },        /* paranthesis '{' level 3 */
    {.ch = {.acod='\0',.fcod=0x6E, .fnum=FONT_MATH_EX, .ncod=215}, .desc="\\Bigl{" },         /* paranthesis '{' level 2 */
    {.ch = {.acod='\0',.fcod=0xA9, .fnum=FONT_MATH_EX, .ncod=216}, .desc="\\bigl{" },         /* paranthesis '{' level 1 */
    {.ch = {.acod='\0',.fcod=0x29, .fnum=FONT_MATH_EX, .ncod=217}, .desc="\\Biggl}" },        /* paranthesis '}' level 4 */
    {.ch = {.acod='\0',.fcod=0xBE, .fnum=FONT_MATH_EX, .ncod=218}, .desc="\\biggl}" },        /* paranthesis '}' level 3 */
    {.ch = {.acod='\0',.fcod=0x6F, .fnum=FONT_MATH_EX, .ncod=219}, .desc="\\Bigl}" },         /* paranthesis '}' level 2 */
    {.ch = {.acod='\0',.fcod=0xAA, .fnum=FONT_MATH_EX, .ncod=220}, .desc="\\bigl}" },         /* paranthesis '}' level 1 */
    {.ch = {.acod='\0',.fcod=0x7B, .fnum=FONT_NORMAL , .ncod=221}, .desc="\\_hline"},         /* horizontal line for building stuff */
    {.ch = {.acod='\0',.fcod=0x7C, .fnum=FONT_NORMAL , .ncod=222}, .desc="\\_hline_long"},    /* longer line? */
    {.ch = {.acod='\0',.fcod=0xB9, .fnum=FONT_NORMAL , .ncod=223}, .desc="\\_hline_above"},   /* same but displaced above? */
    {.ch = {.acod='\0',.fcod=0x3E, .fnum=FONT_MATH_EX, .ncod=224}, .desc="\\_vline_small"},   /* those are all vertical lines */
    {.ch = {.acod='\0',.fcod=0x3F, .fnum=FONT_MATH_EX, .ncod=225}, .desc="\\_vline_1"},
    {.ch = {.acod='\0',.fcod=0x36, .fnum=FONT_MATH_EX, .ncod=226}, .desc="\\_vline_2"},
    {.ch = {.acod='\0',.fcod=0x37, .fnum=FONT_MATH_EX, .ncod=227}, .desc="\\_vline_3"},
    {.ch = {.acod='\0',.fcod=0x42, .fnum=FONT_MATH_EX, .ncod=228}, .desc="\\_vline_4"},
    {.ch = {.acod='\0',.fcod=0x43, .fnum=FONT_MATH_EX, .ncod=229}, .desc="\\_vline_5"},
    {.ch = {.acod='\0',.fcod=0x75, .fnum=FONT_MATH_EX, .ncod=230}, .desc="\\_vline_6"},       /* this is a bit different */
    {.ch = {.acod='\0',.fcod=0x30, .fnum=FONT_MATH_EX, .ncod=231}, .desc="\\_brack_lt_round" },
    {.ch = {.acod='\0',.fcod=0x31, .fnum=FONT_MATH_EX, .ncod=232}, .desc="\\_brack_rt_round" },
    {.ch = {.acod='\0',.fcod=0x40, .fnum=FONT_MATH_EX, .ncod=233}, .desc="\\_brack_lb_round" },
    {.ch = {.acod='\0',.fcod=0x41, .fnum=FONT_MATH_EX, .ncod=234}, .desc="\\_brack_rb_round" },
    {.ch = {.acod='\0',.fcod=0x32, .fnum=FONT_MATH_EX, .ncod=235}, .desc="\\_brack_lt_square" },
    {.ch = {.acod='\0',.fcod=0x33, .fnum=FONT_MATH_EX, .ncod=236}, .desc="\\_brack_rt_square" },
    {.ch = {.acod='\0',.fcod=0x34, .fnum=FONT_MATH_EX, .ncod=237}, .desc="\\_brack_lb_square" },
    {.ch = {.acod='\0',.fcod=0x35, .fnum=FONT_MATH_EX, .ncod=238}, .desc="\\_brack_rb_square" },
    {.ch = {.acod='\0',.fcod=0x38, .fnum=FONT_MATH_EX, .ncod=239}, .desc="\\_brack_lt_curly" },
    {.ch = {.acod='\0',.fcod=0x39, .fnum=FONT_MATH_EX, .ncod=240}, .desc="\\_brack_rt_curly" },
    {.ch = {.acod='\0',.fcod=0x3A, .fnum=FONT_MATH_EX, .ncod=241}, .desc="\\_brack_lb_curly" },
    {.ch = {.acod='\0',.fcod=0x3B, .fnum=FONT_MATH_EX, .ncod=242}, .desc="\\_brack_rb_curly" },
    {.ch = {.acod='\0',.fcod=0x3C, .fnum=FONT_MATH_EX, .ncod=243}, .desc="\\_brack_lc_curly" },
    {.ch = {.acod='\0',.fcod=0x3D, .fnum=FONT_MATH_EX, .ncod=244}, .desc="\\_brack_rc_curly" },
    {.ch = {.acod='<', .fcod=0x3C, .fnum=FONT_MATH   , .ncod=245}, .desc="<" },
    {.ch = {.acod='>', .fcod=0x3E, .fnum=FONT_MATH   , .ncod=246}, .desc=">" },
    {.ch = {.acod=' ', .fcod=0x20, .fnum=FONT_NORMAL , .ncod=247}, .desc=" " },
};

inline char_desc_t *get_char_desc(int num) {
    if (num < 0 || num > chars_cnt())
        return nullptr;
    return &_internal_chars[num];
}

inline char_t gchar(int num) {
    if (num < 0 || num > chars_cnt())
        return _internal_chars['?'].ch;
    return _internal_chars[num].ch;
}

inline int chars_cnt() {
    return sizeof(_internal_chars) / sizeof(_internal_chars[0]);
}

inline char_t gascii(unsigned char c) {
    static std::unordered_map<char, int> ascii2char;
    if (!ascii2char.size()) {
        for (int i = 0; i < chars_cnt(); i++) {
            ascii2char[_internal_chars[i].ch.acod] = i;
        }
        ascii2char[(unsigned char)'?'] = 28;
    }
    if (!HAS(ascii2char, c)) {
        return char_t{.acod=c, .fcod=c, .fnum=FONT_NORMAL, .flvl=FONT_LVL_SPECIAL, .ncod=255};
    }
    return _internal_chars[ascii2char[c]].ch;
}


#endif

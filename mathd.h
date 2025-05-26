#ifndef MATHD_H
#define MATHD_H

/* Math Drawing: Symbol and Expression Drawing */

#include <memory>
#include <map>
#include <vector>
#include <math.h>
#include <algorithm>

#include "chars.h"
#include "misc_utils.h"
#include "debug.h"

enum mathd_e : int {
    MATHD_TYPE_EMPTY_BOX,
    MATHD_TYPE_SYMBOL,
    MATHD_TYPE_BIGOP,
    MATHD_TYPE_FRAC,
    MATHD_TYPE_SUPSUB,
    MATHD_TYPE_BRACKET,
    MATHD_TYPE_BINAR_OP,
    MATHD_TYPE_UNAR_OP,
    MATHD_TYPE_MERGE_VERTICAL,
    MATHD_TYPE_MERGE_HORIZONTAL,
};

enum mathd_bracket_e : int {
    MATHD_BRACKET_ROUND,
    MATHD_BRACKET_SQUARE,
    MATHD_BRACKET_CURLY,
};

struct mathd_t;
using mathd_p = std::shared_ptr<mathd_t>;

struct mathd_bracket_t {
    mathd_bracket_e type;
    char_t tl;
    char_t bl;
    char_t tr;
    char_t br;
    char_t cl;
    char_t cr;
    char_t con;
    char_t left[4];
    char_t right[4];
};

struct mathd_bb_t {
    ImVec2 tl = ImVec2(0, 0); /*!< Holds the minimums of the bounding box, so, the top-left */
    ImVec2 br = ImVec2(0, 0); /*!< Holds the maximums of the bounding box, so, the bottom-right */
};

struct mathd_t {
    mathd_e type; /*!< The type that this object will hold */
    char_t symb;  /*!< Optional symbol if this object is a leaf */

    /*! The subobjects of this object and their relative positions are stored in this */
    std::vector<std::pair<mathd_p, ImVec2>> subobjs;

    ImVec2 size;          /*!< The calculated bounding box of this element */
    float voff = 0.0f;    /*!< Vertical offset of the object */
    float vcenter = 0.0f; /*!< The still don't know what to do with it */

    union {
        struct {
            uint64_t is_char : 1;
        };
        uint64_t flags = 0;
    };

    std::function<void(mathd_p, ImVec2)> cbk;   /*!< This will be called on diverse actions */
    std::shared_ptr<void> usr_ptr;              /*!< This is the user's pointer */
};

template <typename ...Args>
inline mathd_p mathd_make(Args&&... args);

inline mathd_bb_t mathd_get_bb(mathd_p m, ImVec2 pos = ImVec2(0, 0));

inline void mathd_draw(ImVec2 pos, mathd_p m);
inline mathd_p mathd_empty(float x, float y);
inline mathd_p mathd_symbol(char_t sym, bool is_char = true);
inline mathd_p mathd_bigop(mathd_p right, mathd_p above, mathd_p bellow, char_t bigop);
inline mathd_p mathd_frac(mathd_p above, mathd_p bellow, char_t divline);
inline mathd_p mathd_supsub(mathd_p base, mathd_p sup, mathd_p sub);
inline mathd_p mathd_bracket(mathd_p expr, mathd_bracket_t bracket);
inline mathd_p mathd_unarexpr(char_t op, mathd_p b);
inline mathd_p mathd_binexpr(mathd_p a, char_t op, mathd_p b);
inline mathd_p mathd_merge_h(mathd_p l, mathd_p r);
inline mathd_p mathd_merge_v(mathd_p u, mathd_p d);

inline char_t          mathd_convert(char_t msym, char_font_lvl_e font_lvl);
inline mathd_bracket_t mathd_convert(mathd_bracket_t msym, char_font_lvl_e font_lvl);

/* TODO: matrix stuff */

// inline bool mathd_draw_boxes = true;
inline bool mathd_draw_boxes = false;

/* IMPLEMENTATION
 * =================================================================================================
 */


#define MATHD_DISTANCER         4
#define MATHD_DISTANCER_BIGO    2

#define MATHD_hash              (gchar(  2))
#define MATHD_plus              (gchar( 10))
#define MATHD_comma             (gchar( 11))

#define MATHD_equal             (gchar( 27))

#define MATHD_e                 (gchar( 65))
#define MATHD_a                 (gchar( 61))
#define MATHD_n                 (gchar( 74))

#define MATHD_minus             (gchar(181))
#define MATHD_integral          (gchar(191))
#define MATHD_sum               (gchar(192))

#define MATHD_hline_basic       (gchar(221))
#define MATHD_hline_long        (gchar(222))
#define MATHD_hline_above       (gchar(223))


inline mathd_bracket_t mathd_brack_round = {
    .type = MATHD_BRACKET_ROUND,
    .tl  = gchar(231),
    .bl  = gchar(233),
    .tr  = gchar(232),
    .br  = gchar(234),
    .cl  = gchar(243),
    .cr  = gchar(244),
    .con = gchar(225),
    .left = { gchar(197), gchar(198), gchar(199), gchar(200) },
    .right = { gchar(201), gchar(202), gchar(203), gchar(204) },
};

inline mathd_bracket_t mathd_brack_square = {
    .type = MATHD_BRACKET_SQUARE,
    .tl  = gchar(235),
    .bl  = gchar(237),
    .tr  = gchar(236),
    .br  = gchar(238),
    .cl  = gchar(243),
    .cr  = gchar(244),
    .con = gchar(225),
    .left = { gchar(205), gchar(206), gchar(207), gchar(208) },
    .right = { gchar(209), gchar(210), gchar(211), gchar(212) },
};

inline mathd_bracket_t mathd_brack_curly = {
    .type = MATHD_BRACKET_CURLY,
    .tl  = gchar(239),
    .bl  = gchar(241),
    .tr  = gchar(240),
    .br  = gchar(242),
    .cl  = gchar(243),
    .cr  = gchar(244),
    .con = gchar(225),
    .left = { gchar(213), gchar(214), gchar(215), gchar(216) },
    .right = { gchar(217), gchar(218), gchar(219), gchar(220) },
};

inline std::pair<float, float> mathd_a_horiz_sz(char_font_lvl_e flvl) {
    static std::unordered_map<char_font_lvl_e, std::pair<float, float>> sizes;
    if (!HAS(sizes, flvl)) {
        auto a = gascii('a');
        a.flvl = flvl;
        auto [a_min, a_max] = char_get_draw_box(a);
        sizes[flvl] = std::pair{a_min.y, a_max.y};
    }
    return sizes[flvl];
}

inline void mathd_draw(ImVec2 pos, mathd_p m) {
    if (m->type == MATHD_TYPE_SYMBOL) {
        /* Characters are drawn from the baseline upwards */
        /* TODO: use vcenter or voff or both */
        auto off = ImVec2(0, -mathd_a_horiz_sz((char_font_lvl_e)m->symb.flvl).second);
        char_draw(pos + off, m->symb);
    }
    for (auto &[obj, obj_pos] : m->subobjs)
        mathd_draw(pos + obj_pos, obj);
}

inline mathd_p mathd_empty(float x, float y) {
    return mathd_make(mathd_t{.type = MATHD_TYPE_EMPTY_BOX });
}

inline mathd_p mathd_symbol(char_t sym, bool is_char) {
    auto def_size = mathd_a_horiz_sz((char_font_lvl_e)sym.flvl);
    float h = (def_size.first + def_size.second) / 2.;

    auto [sym_min, sym_max] = char_get_draw_box(sym);
    auto ret = mathd_make(mathd_t{
        .type = MATHD_TYPE_SYMBOL,
        .symb = sym,
        .size = sym_max - sym_min,
        .voff = 0,
        .vcenter = (is_char ? h : (sym_max.y + sym_min.y) / 2.0f),
        .is_char = is_char,
    });

    return ret;
}

inline mathd_p mathd_bigop(mathd_p right, mathd_p above, mathd_p bellow, char_t bigop) {
    float distancer = MATHD_DISTANCER_BIGO * char_get_lvl_mul((char_font_lvl_e)bigop.flvl);
    auto ret = mathd_make(mathd_t{ .type = MATHD_TYPE_BIGOP });
    auto op = mathd_symbol(bigop, false);

    ret->subobjs = std::vector<std::pair<mathd_p, ImVec2>> {
        {op,     ImVec2(0, 0)}, /* The operator is drawn first */
        {above,  ImVec2( above->size.x/2.,-distancer - op->size.y/2. - above->size.y)},
        {bellow, ImVec2(bellow->size.x/2., distancer + op->size.y/2. + bellow->size.y)},
        {right,  ImVec2(distancer + op->size.x, 0)},
    };
    ret->size = ImVec2(  distancer + op->size.x + right->size.x,
                       2*distancer + op->size.y + above->size.y + bellow->size.y);

    return ret;
}

inline mathd_p mathd_frac(mathd_p above, mathd_p bellow, char_t divline) {
    float distancer = MATHD_DISTANCER * char_get_lvl_mul((char_font_lvl_e)divline.flvl);
    auto ret = mathd_make(mathd_t{ .type = MATHD_TYPE_FRAC });
    auto dl = mathd_symbol(divline, false);

    float sz = std::max(bellow->size.x, above->size.x);
    int cnt = std::ceil(sz / dl->size.x);
    if (cnt % 2 == 0)
        cnt++;

    sz = (cnt / 2) * dl->size.x;
    ret->subobjs = std::vector<std::pair<mathd_p, ImVec2>> {
        {above,  ImVec2(sz/2. - above->size.x/2., -above->size.y - distancer)},
        {bellow, ImVec2(sz/2. - bellow->size.x/2., bellow->size.y + distancer)}
    };

    for (int i = 0; i < cnt; i++) {
        ret->subobjs.push_back({mathd_symbol(divline, false), ImVec2(i * dl->size.x, 0)});
    }

    ret->size = ImVec2(cnt * dl->size.x, 2*distancer + above->size.y + bellow->size.y);
    return ret;
}

inline mathd_p mathd_supsub(mathd_p base, mathd_p sup, mathd_p sub) {
    auto ret = mathd_make(mathd_t{ .type = MATHD_TYPE_SUPSUB });

    ret->subobjs = std::vector<std::pair<mathd_p, ImVec2>> {
        {base, ImVec2(0, 0)},
        {sup,  ImVec2(base->size.x, 0 /* TODO: I want at most 1/3 of the base object and once that is ok*/)},
        {sub,  ImVec2(base->size.x, 0 /* TODO: at least 2/3 of the other be outside (viewed vertically) */)},
    };

    ret->size = ImVec2(base->size.x + std::max(sup->size.x, sub->size.x), 0/* TODO: */);
    return ret;
}

inline mathd_p mathd_bracket(mathd_p expr, mathd_bracket_t bracket) {
    // float distancer = MATHD_DISTANCER * char_get_lvl_mul((char_font_lvl_e)op.flvl);
    auto ret = mathd_make(mathd_t{ .type = MATHD_TYPE_UNAR_OP });

    // inline mathd_bracket_t mathd_brack_curly = {
    //     .type = MATHD_BRACKET_CURLY,
    //     .tl  = gchar(239),
    //     .bl  = gchar(241),
    //     .tr  = gchar(240),
    //     .br  = gchar(242),
    //     .cl  = gchar(243),
    //     .cr  = gchar(244),
    //     .con = gchar(225),
    //     .left = { gchar(213), gchar(214), gchar(215), gchar(216) },
    //     .right = { gchar(217), gchar(218), gchar(219), gchar(220) },
    // };

    // MATHD_TYPE_BRACKET
    /* TODO: this is very similar to he vertical lines thing */
    return ret;
}

inline mathd_p mathd_unarexpr(char_t op, mathd_p b) {
    float distancer = MATHD_DISTANCER * char_get_lvl_mul((char_font_lvl_e)op.flvl);
    auto ret = mathd_make(mathd_t{ .type = MATHD_TYPE_UNAR_OP });
    /* TODO: */
    return ret;
}

inline mathd_p mathd_binexpr(mathd_p a, char_t op, mathd_p b) {
    float distancer = MATHD_DISTANCER * char_get_lvl_mul((char_font_lvl_e)op.flvl);
    auto ret = mathd_make(mathd_t{ .type = MATHD_TYPE_BINAR_OP });
    /* TODO: */

    return ret;
}

inline mathd_p mathd_merge_h(mathd_p l, mathd_p r) {
    auto ret = mathd_make(mathd_t{ .type = MATHD_TYPE_MERGE_HORIZONTAL });

    /* TODO: */
    return ret;
}

inline mathd_p mathd_merge_v(mathd_p u, mathd_p d) {
    auto ret = mathd_make(mathd_t{ .type = MATHD_TYPE_MERGE_VERTICAL });

    /* TODO: */
    return ret;
}

inline mathd_bb_t mathd_get_bb(mathd_p m, ImVec2 pos) {
    /* TODO: */
    return mathd_bb_t {};
}

template <typename ...Args>
inline mathd_p mathd_make(Args&&... args) {
    return std::make_shared<mathd_t>(std::forward<Args>(args)...);
}

inline char_t mathd_convert(char_t msym, char_font_lvl_e font_lvl) {
    msym.flvl = font_lvl;
    return msym;
}

inline mathd_bracket_t mathd_convert(mathd_bracket_t bsym, char_font_lvl_e font_lvl) {
    return mathd_bracket_t {
        .type = MATHD_BRACKET_CURLY,
        .tl  = mathd_convert(bsym.tl, font_lvl),
        .bl  = mathd_convert(bsym.bl, font_lvl),
        .tr  = mathd_convert(bsym.tr, font_lvl),
        .br  = mathd_convert(bsym.br, font_lvl),
        .cl  = mathd_convert(bsym.cl, font_lvl),
        .cr  = mathd_convert(bsym.cr, font_lvl),
        .con = mathd_convert(bsym.con, font_lvl),
        .left = {
            mathd_convert(bsym.left[0], font_lvl),
            mathd_convert(bsym.left[1], font_lvl),
            mathd_convert(bsym.left[2], font_lvl),
            mathd_convert(bsym.left[3], font_lvl),
        },
        .right = {
            mathd_convert(bsym.right[0], font_lvl),
            mathd_convert(bsym.right[1], font_lvl),
            mathd_convert(bsym.right[2], font_lvl),
            mathd_convert(bsym.right[3], font_lvl),
        },
    };
}

#endif

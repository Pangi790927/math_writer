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
    MATHD_TYPE_INTERNAL,
    MATHD_TYPE_LINE_STRIP,
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
    char_t tl;          /* top left */
    char_t bl;          /* bottom left */
    char_t tr;          /* top right */
    char_t br;          /* bottom right */
    char_t cl;          /* center left */
    char_t cr;          /* center right */
    char_t conl;        /* connector */
    char_t conr;        /* connector */
    char_t left[4];     /* smaller brackets left part */
    char_t right[4];    /* smaller brackets right part */
};

struct mathd_bb_t {
    ImVec2 tl = ImVec2(0, 0); /*!< Holds the minimums of the bounding box, so, the top-left */
    ImVec2 br = ImVec2(0, 0); /*!< Holds the maximums of the bounding box, so, the bottom-right */
};

struct mathd_t {
    mathd_e type;       /*!< The type that this object will hold */
    uint32_t color = 0xff'eeeeee;

    char_t symb;        /*!< Optional symbol if this object is a leaf */

    std::vector<ImVec2> line_strip; /*!< Optional, if type is MATHD_TYPE_LINE_STRIP */
    float line_width = 1.0f;        /*!< Optional, if type is line */

    /*! The subobjects of this object and their relative positions are stored in this */
    std::vector<std::pair<mathd_p, ImVec2>> subobjs;

    ImVec2 size;          /*!< The calculated bounding box of this element */
    float voff = 0.0f;    /*!< Vertical offset of the object */

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

inline bool mathd_draw_boxes = true;
// inline bool mathd_draw_boxes = false;

/* IMPLEMENTATION
 * =================================================================================================
 */


#define MATHD_DISTANCER         4
#define MATHD_DISTANCER_BIGO    2

#define MATHD_hash              (gchar(  2))
#define MATHD_plus              (gchar( 10))
#define MATHD_comma             (gchar( 11))

#define MATHD_equal             (gchar( 27))
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
    .cl  = gchar(228),
    .cr  = gchar(229),
    .conl = gchar(228),
    .conr = gchar(229),
    .left = { gchar(197), gchar(198), gchar(199), gchar(200) },
    .right = { gchar(201), gchar(202), gchar(203), gchar(204) },
};

inline mathd_bracket_t mathd_brack_square = {
    .type = MATHD_BRACKET_SQUARE,
    .tl  = gchar(235),
    .bl  = gchar(237),
    .tr  = gchar(236),
    .br  = gchar(238),
    .cl  = gchar(226),
    .cr  = gchar(227),
    .conl = gchar(226),
    .conr = gchar(227),
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
    .conl = gchar(224),
    .conr = gchar(224),
    .left = { gchar(213), gchar(214), gchar(215), gchar(216) },
    .right = { gchar(217), gchar(218), gchar(219), gchar(220) },
};

inline void mathd_draw(ImVec2 pos, mathd_p m) {
    if (!m)
        return ;
    ImDrawList* draw_list = ImGui::GetWindowDrawList();
    auto bb = mathd_get_bb(m, pos);
    if (mathd_draw_boxes) {
        draw_list->AddRect(bb.tl, bb.br, 0xff'ffff00);

        auto voff_center = bb.tl + ImVec2(0, m->voff);
        draw_list->AddLine(voff_center - ImVec2(m->voff/4., 0), voff_center + ImVec2(m->voff/4., 0),
                0xff'ff00ff);
    }
    if (m->type == MATHD_TYPE_SYMBOL) {
        auto off = ImVec2(0, -char_get_draw_box(m->symb).first.y);
        char_draw(pos + off, m->symb, m->color);
    }
    else if (m->type == MATHD_TYPE_LINE_STRIP) {
        for (int i = 1; i < m->line_strip.size(); i++)
            draw_list->AddLine(pos + m->line_strip[i-1],
                    pos + m->line_strip[i], m->color, m->line_width);
    }
    else if (m->type == MATHD_TYPE_EMPTY_BOX) {
        draw_list->AddRectFilled(bb.tl, bb.br, m->color);
    }
    for (auto &[obj, obj_pos] : m->subobjs) {
        mathd_draw(pos + obj_pos, obj);
    }
}

inline mathd_p mathd_empty(float x, float y) {
    return mathd_make(mathd_t{
        .type = MATHD_TYPE_EMPTY_BOX,
        .size = ImVec2(x, y)
    });
}

inline mathd_p mathd_symbol(char_t sym, bool is_char) {
    auto a = gascii('a');
    a.flvl = sym.flvl;
    auto [a_min, a_max] = char_get_draw_box(a);
    auto [s_min, s_max] = char_get_draw_box(sym);
    float hmed = (a_max.y - a_min.y) / 2.;

    auto ret = mathd_make(mathd_t{
        .type = MATHD_TYPE_SYMBOL,
        .symb = sym,
        .size = s_max - s_min,

        /* If we have a character (in the sense: part of a name), it's anchor point is the middle of
        the character 'a' above the baseline, else if it's a symbol, it's center is the anchor point
        (for example for the integral sign) */
        .voff = is_char ? a_min.y - s_min.y + hmed : (s_max.y - s_min.y) / 2.0f,

        /* This is the flag that remembers that this symbol type is variable-like or sign-like */
        .is_char = is_char,
    });

    return ret;
}

inline mathd_p mathd_bigop(mathd_p right, mathd_p above, mathd_p bellow, char_t bigop) {
    float distancer = MATHD_DISTANCER_BIGO * char_get_lvl_mul((char_font_lvl_e)bigop.flvl);
    auto ret = mathd_make(mathd_t{ .type = MATHD_TYPE_BIGOP });
    auto op = mathd_symbol(bigop, false);

    float aux_x = std::max(std::max(op->size.x, above->size.x), bellow->size.x) / 2.0f;
    float aux_y = std::max(above->size.y + distancer + op->size.y / 2.0f, right->voff);

    float op_x = aux_x - op->size.x/2;
    float above_x = aux_x - above->size.x/2.;
    float bellow_x = aux_x - bellow->size.x/2.;

    float op_y = aux_y - op->size.y/2.;

    /* TODO: maybe see if it fits between the integrands and place the right side there */
    float right_x = distancer + std::max(std::max(op_x + op->size.x, above_x + above->size.x),
            bellow_x + bellow->size.x);
    float right_y = op_y + op->voff - right->voff;

    ret->subobjs = std::vector<std::pair<mathd_p, ImVec2>> {
        {op,     ImVec2(op_x,     op_y)},
        {above,  ImVec2(above_x,  op_y - distancer - above->size.y)},
        {bellow, ImVec2(bellow_x, op_y + distancer + op->size.y)},
        {right,  ImVec2(right_x,  right_y)},
    };
    float h = std::max(op_y + distancer + op->size.y + bellow->size.y, right_y + right->size.y);
    ret->size = ImVec2(right_x + right->size.x, h);
    ret->voff = op_y + op->voff;

    return ret;
}

inline mathd_p mathd_frac(mathd_p above, mathd_p bellow, char_t divline) {
    /* TODO; */
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
    ret->voff = /* TODO */0;
    return ret;
}

inline mathd_p mathd_supsub(mathd_p base, mathd_p sup, mathd_p sub) {
    auto ret = mathd_make(mathd_t{ .type = MATHD_TYPE_SUPSUB });

    float base_y = sup ? sup->size.y - base->size.y / 3. : 0;
    if (sup && sup->size.y < base->size.y / 3.)
        base_y = sup->size.y * 2./3.;

    float sub_y = base_y + base->size.y / 3.;
    if (sub && sub->size.y < base->size.y)
        sub_y = base_y + base->size.y - sub->size.y / 3.;

    ret->subobjs = std::vector<std::pair<mathd_p, ImVec2>> {
        {sup,  ImVec2(base->size.x, 0)},
        {base, ImVec2(0, base_y)},
        {sub,  ImVec2(base->size.x, sub_y)},
    };

    ret->size = ImVec2(base->size.x + std::max(sup ? sup->size.x : 0, sub ? sub->size.x : 0),
            sub ? sub->size.y + sub_y : base_y + base->size.y);
    ret->voff = base->voff + base_y;
    return ret;
}

/* This is taken from ImGui and transformed to fit my needs */
static void beziere_path_rec(std::vector<ImVec2>& path, ImVec2 P1, ImVec2 P2, ImVec2 P3, ImVec2 P4,
        int level = 0)
{
    static const float tess_tol = 1.25f;
    float dx = P4.x - P1.x;
    float dy = P4.y - P1.y;
    float d2 = (P2.x - P4.x) * dy - (P2.y - P4.y) * dx;
    float d3 = (P3.x - P4.x) * dy - (P3.y - P4.y) * dx;
    d2 = (d2 >= 0) ? d2 : -d2;
    d3 = (d3 >= 0) ? d3 : -d3;
    if ((d2 + d3) * (d2 + d3) < tess_tol * (dx * dx + dy * dy))
    {
        path.push_back(ImVec2(P4.x, P4.y));
    }
    else if (level < 10)
    {
        float x12 = (P1.x + P2.x) * 0.5f, y12 = (P1.y + P2.y) * 0.5f;
        float x23 = (P2.x + P3.x) * 0.5f, y23 = (P2.y + P3.y) * 0.5f;
        float x34 = (P3.x + P4.x) * 0.5f, y34 = (P3.y + P4.y) * 0.5f;
        float x123 = (x12 + x23) * 0.5f, y123 = (y12 + y23) * 0.5f;
        float x234 = (x23 + x34) * 0.5f, y234 = (y23 + y34) * 0.5f;
        float x1234 = (x123 + x234) * 0.5f, y1234 = (y123 + y234) * 0.5f;
        beziere_path_rec(path, P1, ImVec2(x12, y12), ImVec2(x123, y123), ImVec2(x1234, y1234), level + 1);
        beziere_path_rec(path, ImVec2(x1234, y1234), ImVec2(x234, y234), ImVec2(x34, y34), P4, level + 1);
    }
}

inline mathd_p mathd_bracket(mathd_p expr, mathd_bracket_t bracket) {
    auto sym_h = [](char_t sym) {
        return char_get_draw_box(sym).second.y - char_get_draw_box(sym).first.y;
    };

    /* First we need to select the appropiate paranthesis dimension for the expression and construct
    the paranthesis objects */
    mathd_p lb, rb;
    if (sym_h(bracket.left[3]) > expr->size.y) {
        lb = mathd_symbol(bracket.left[3], false);
        rb = mathd_symbol(bracket.right[3], false);
    }
    else if (sym_h(bracket.left[2]) > expr->size.y) {
        lb = mathd_symbol(bracket.left[2], false);
        rb = mathd_symbol(bracket.right[2], false);
    }
    else if (sym_h(bracket.left[1]) > expr->size.y) {
        lb = mathd_symbol(bracket.left[1], false);
        rb = mathd_symbol(bracket.right[1], false);
    }
    else if (sym_h(bracket.left[0]) > expr->size.y) {
        lb = mathd_symbol(bracket.left[0], false);
        rb = mathd_symbol(bracket.right[0], false);
    }
    else {
        float f = 1;
        lb = mathd_make(mathd_t{ .type = MATHD_TYPE_INTERNAL });
        rb = mathd_make(mathd_t{ .type = MATHD_TYPE_INTERNAL });
        auto lb_tl = mathd_symbol(bracket.tl, false);
        auto lb_bl = mathd_symbol(bracket.bl, false);
        auto lb_cl = mathd_symbol(bracket.cl, false);
        auto rb_tr = mathd_symbol(bracket.tr, false);
        auto rb_br = mathd_symbol(bracket.br, false);
        auto rb_cr = mathd_symbol(bracket.cr, false);
        auto conl = mathd_symbol(bracket.conl, false);
        auto conr = mathd_symbol(bracket.conr, false);

        float sz = lb_tl->size.y + lb_cl->size.y + lb_bl->size.y;
        int con_cnt = 0;
        if (sz < expr->size.y) {
            con_cnt = std::ceil((expr->size.y - sz) / (conl->size.y*f));
            if (con_cnt % 2 == 1)
                con_cnt++;
        }

        float h = 0;
        if (bracket.type == MATHD_BRACKET_SQUARE) {
            h = lb_tl->size.y + lb_bl->size.y + lb_cl->size.y + con_cnt * conl->size.y;
            auto lines_l = mathd_make(mathd_t{ .type = MATHD_TYPE_LINE_STRIP });
            auto [a_min, a_max] = char_get_draw_box(bracket.tl);
            float minx = a_min.x;
            lines_l->line_strip.push_back(ImVec2(a_max.x - minx, 0));
            lines_l->line_strip.push_back(ImVec2(a_min.x - minx, 0));
            lines_l->line_strip.push_back(ImVec2(a_min.x - minx, h));
            lines_l->line_strip.push_back(ImVec2(a_max.x - minx, h));
            lines_l->line_width = conl->size.x;
            lines_l->color = 0xff'eeeeee;
            lb->subobjs.push_back({lines_l, ImVec2(0, 0)});

            auto lines_r = mathd_make(mathd_t{ .type = MATHD_TYPE_LINE_STRIP });
            auto [b_min, b_max] = char_get_draw_box(bracket.tr);
            minx = b_min.x;
            lines_r->line_strip.push_back(ImVec2(b_min.x - minx, 0));
            lines_r->line_strip.push_back(ImVec2(b_max.x - minx, 0));
            lines_r->line_strip.push_back(ImVec2(b_max.x - minx, h));
            lines_r->line_strip.push_back(ImVec2(b_min.x - minx, h));
            lines_r->line_width = conl->size.x;
            lines_r->color = 0xff'eeeeee;
            rb->subobjs.push_back({lines_r, ImVec2(0, 0)});
        }
        else if (bracket.type == MATHD_BRACKET_ROUND) {
            h = lb_tl->size.y + lb_bl->size.y + lb_cl->size.y + con_cnt * conl->size.y;
            auto lines_l = mathd_make(mathd_t{ .type = MATHD_TYPE_LINE_STRIP });
            auto [a_min, a_max] = char_get_draw_box(bracket.tl);
            float minx = a_min.x;
            lines_l->line_strip.push_back(ImVec2(a_max.x - minx, 0));
            beziere_path_rec(lines_l->line_strip,
                ImVec2(a_max.x - minx, 0),
                ImVec2((a_max.x + a_min.x) / 2. - minx, lb_tl->size.y / 8.),
                ImVec2(a_min.x - minx, lb_tl->size.y / 8. * 3.),
                ImVec2(a_min.x - minx, lb_tl->size.y));
            lines_l->line_strip.push_back(ImVec2(a_min.x - minx, lb_tl->size.y));
            beziere_path_rec(lines_l->line_strip,
                    ImVec2(a_min.x - minx, h - lb_bl->size.y),
                    ImVec2(a_min.x - minx, h - lb_bl->size.y / 8. * 3.),
                    ImVec2((a_min.x + a_max.x) / 2. - minx, h - lb_bl->size.y / 8.),
                    ImVec2(a_max.x - minx, h));
            lines_l->line_width = conl->size.x;
            lines_l->color = 0xff'eeeeee;
            lb->subobjs.push_back({lines_l, ImVec2(0, 0)});

            auto lines_r = mathd_make(mathd_t{ .type = MATHD_TYPE_LINE_STRIP });
            auto [b_min, b_max] = char_get_draw_box(bracket.tr);
            minx = b_min.x;
            lines_r->line_strip.push_back(ImVec2(b_min.x - minx, 0));
            beziere_path_rec(lines_r->line_strip,
                ImVec2(b_min.x - minx, 0),
                ImVec2((b_min.x + b_max.x) / 2. - minx, rb_tr->size.y / 8.),
                ImVec2(b_max.x - minx, rb_tr->size.y / 8. * 3.),
                ImVec2(b_max.x - minx, rb_tr->size.y));
            lines_r->line_strip.push_back(ImVec2(b_max.x - minx, rb_tr->size.y));
            beziere_path_rec(lines_r->line_strip,
                    ImVec2(b_max.x - minx, h - rb_br->size.y),
                    ImVec2(b_max.x - minx, h - rb_br->size.y / 8. * 3.),
                    ImVec2((b_max.x + b_min.x) / 2. - minx, h - rb_br->size.y / 8.),
                    ImVec2(b_min.x - minx, h));
            lines_r->line_width = conr->size.x;
            lines_r->color = 0xff'eeeeee;
            rb->subobjs.push_back({lines_r, ImVec2(0, 0)});
        }
        else if (bracket.type == MATHD_BRACKET_CURLY) {
            h = lb_tl->size.y + lb_bl->size.y + lb_cl->size.y + con_cnt * conl->size.y;
            float h2 = h / 2.;
            auto [a_min, a_max] = char_get_draw_box(bracket.tl);
            auto [b_min, b_max] = char_get_draw_box(bracket.cl);
            auto [c_min, c_max] = char_get_draw_box(bracket.bl);

            float minx = std::min({a_min.x, b_min.x, c_min.x});

            auto lines_l = mathd_make(mathd_t{ .type = MATHD_TYPE_LINE_STRIP });
            lines_l->line_strip.push_back(ImVec2(a_max.x - minx, 0));
            beziere_path_rec(lines_l->line_strip,
                    ImVec2(a_max.x - minx, 0),
                    ImVec2(a_min.x * 0.75 + a_max.x * 0.25 - minx, 0),
                    ImVec2(a_min.x - minx, lb_tl->size.y * 0.25),
                    ImVec2(a_min.x - minx, lb_tl->size.y));
            lines_l->line_strip.push_back(ImVec2(b_max.x - minx, h2 - lb_cl->size.y * 0.5));
            beziere_path_rec(lines_l->line_strip,
                    ImVec2(b_max.x - minx, h2 - lb_cl->size.y * 0.5),
                    ImVec2(b_max.x - minx, h2 + lb_cl->size.y * (.75 * .5 - .5)),
                    ImVec2(b_max.x * 0.75 + b_min.x * 0.25 - minx, h2),
                    ImVec2(b_min.x - minx, h2));
            lines_l->line_strip.push_back(ImVec2(b_min.x - minx, h2));
            beziere_path_rec(lines_l->line_strip,
                    ImVec2(b_min.x - minx, h2),
                    ImVec2(b_min.x * .25 + b_max.x * .75 - minx, h2),
                    ImVec2(b_max.x - minx, h2 + lb_cl->size.y * .75 * .5),
                    ImVec2(b_max.x - minx, h2 + lb_cl->size.y * .5));
            lines_l->line_strip.push_back(ImVec2(c_min.x - minx, h - lb_bl->size.y));
            beziere_path_rec(lines_l->line_strip,
                    ImVec2(c_min.x - minx, h - lb_bl->size.y),
                    ImVec2(c_min.x - minx, h - lb_bl->size.y * .25),
                    ImVec2(c_min.x * .75 + c_max.x * .25 - minx, h),
                    ImVec2(c_max.x - minx, h));
            lines_l->color = 0xff'eeeeee;
            lines_l->line_width = conl->size.x;
            lb->subobjs.push_back({lines_l, ImVec2(0, 0)});

            auto [d_min, d_max] = char_get_draw_box(bracket.tr);
            auto [e_min, e_max] = char_get_draw_box(bracket.cr);
            auto [f_min, f_max] = char_get_draw_box(bracket.br);

            minx = std::min({d_min.x, e_min.x, f_min.x});

            auto lines_r = mathd_make(mathd_t{ .type = MATHD_TYPE_LINE_STRIP });
            lines_r->line_strip.push_back(ImVec2(d_min.x - minx, 0));
            beziere_path_rec(lines_r->line_strip,
                    ImVec2(d_min.x - minx, 0),
                    ImVec2(d_max.x * 0.75 + d_min.x * 0.25 - minx, 0),
                    ImVec2(d_max.x - minx, rb_tr->size.y * 0.25),
                    ImVec2(d_max.x - minx, rb_tr->size.y));
            lines_r->line_strip.push_back(ImVec2(e_min.x - minx, h2 - rb_cr->size.y * 0.5));
            beziere_path_rec(lines_r->line_strip,
                    ImVec2(e_min.x - minx, h2 - rb_cr->size.y * 0.5),
                    ImVec2(e_min.x - minx, h2 + rb_cr->size.y * (.75 * .5 - .5)),
                    ImVec2(e_min.x * 0.75 + e_max.x * 0.25 - minx, h2),
                    ImVec2(e_max.x - minx, h2));
            lines_r->line_strip.push_back(ImVec2(e_max.x - minx, h2));
            beziere_path_rec(lines_r->line_strip,
                    ImVec2(e_max.x - minx, h2),
                    ImVec2(e_max.x * .25 + e_min.x * .75 - minx, h2),
                    ImVec2(e_min.x - minx, h2 + rb_cr->size.y * .75 * .5),
                    ImVec2(e_min.x - minx, h2 + rb_cr->size.y * .5));
            lines_r->line_strip.push_back(ImVec2(f_max.x - minx, h - rb_br->size.y));
            beziere_path_rec(lines_r->line_strip,
                    ImVec2(f_max.x - minx, h - rb_br->size.y),
                    ImVec2(f_max.x - minx, h - rb_br->size.y * .25),
                    ImVec2(f_max.x * .75 + f_min.x * .25 - minx, h),
                    ImVec2(f_min.x - minx, h));
            lines_r->color = 0xff'eeeeee;
            lines_r->line_width = conr->size.x;
            rb->subobjs.push_back({lines_r, ImVec2(0, 0)});
        }

        lb->size = ImVec2(std::max({lb_tl->size.x, conl->size.x, lb_cl->size.x, lb_bl->size.x}), h);
        rb->size = ImVec2(std::max({rb_tr->size.x, conr->size.x, rb_cr->size.x, rb_br->size.x}), h);
    }

    float distancer = MATHD_DISTANCER * char_get_lvl_mul((char_font_lvl_e)bracket.left[0].flvl);
    auto ret = mathd_make(mathd_t{ .type = MATHD_TYPE_UNAR_OP });

    /* afterwards we construct the final object */
    float h = (lb->size.y - expr->size.y) / 2.;
    ret->subobjs = std::vector<std::pair<mathd_p, ImVec2>> {
        {lb,   ImVec2(0, 0)},
        {expr, ImVec2(lb->size.x + distancer, h)},
        {rb,   ImVec2(lb->size.x + expr->size.x + 2*distancer, 0)},
    };    

    ret->size = ImVec2(expr->size.x + 2*distancer + lb->size.x + rb->size.x, lb->size.y);
    ret->voff = expr->voff + h;

    return ret;
}

inline mathd_p mathd_unarexpr(char_t op, mathd_p a) {
    float distancer = MATHD_DISTANCER * char_get_lvl_mul((char_font_lvl_e)op.flvl);
    auto ret = mathd_make(mathd_t{ .type = MATHD_TYPE_BINAR_OP });
    auto sym_op = mathd_symbol(op);

    float aoff = a->voff - sym_op->voff;
    float hmax = std::max(aoff, 0.0f);
    ret->subobjs = std::vector<std::pair<mathd_p, ImVec2>> {
        {sym_op, ImVec2(0,                         hmax - 0)},
        {a,      ImVec2(sym_op->size.x + distancer, hmax - aoff)},
    };

    float h = std::max(hmax - aoff + a->size.y, hmax + sym_op->size.y);
    ret->size = ImVec2(a->size.x + sym_op->size.x + distancer, h);
    ret->voff = hmax + sym_op->voff;
    return ret;
}

inline mathd_p mathd_binexpr(mathd_p a, char_t op, mathd_p b) {
    float distancer = MATHD_DISTANCER * char_get_lvl_mul((char_font_lvl_e)op.flvl);
    auto ret = mathd_make(mathd_t{ .type = MATHD_TYPE_BINAR_OP });
    auto sym_op = mathd_symbol(op);

    float aoff = a->voff - sym_op->voff;
    float boff = b->voff - sym_op->voff;
    float hmax = std::max(std::max(aoff, boff), 0.0f);
    ret->subobjs = std::vector<std::pair<mathd_p, ImVec2>> {
        {a,      ImVec2(0,                                         hmax - aoff)},
        {sym_op, ImVec2(a->size.x + distancer,                     hmax - 0)},
        {b,      ImVec2(sym_op->size.x + a->size.x + 2.*distancer, hmax - boff)},
    };

    float h = std::max(std::max(hmax - aoff + a->size.y, hmax - boff + b->size.y),
            hmax + sym_op->size.y);
    ret->size = ImVec2(a->size.x + b->size.x + sym_op->size.x + distancer*2., h);
    ret->voff = hmax + sym_op->voff;

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
    return mathd_bb_t{ .tl = pos, .br = pos + m->size };
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
        .type = bsym.type,
        .tl  = mathd_convert(bsym.tl, font_lvl),
        .bl  = mathd_convert(bsym.bl, font_lvl),
        .tr  = mathd_convert(bsym.tr, font_lvl),
        .br  = mathd_convert(bsym.br, font_lvl),
        .cl  = mathd_convert(bsym.cl, font_lvl),
        .cr  = mathd_convert(bsym.cr, font_lvl),
        .conl = mathd_convert(bsym.conl, font_lvl),
        .conr = mathd_convert(bsym.conr, font_lvl),
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

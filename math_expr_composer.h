#ifndef MATH_DRAWING_H
#define MATH_DRAWING_H

/* Math Drawing: Symbol and Expression Drawing */

#include <memory>
#include <map>
#include <vector>
#include <math.h>
#include <algorithm>

#include "char_draw_composer.h"
#include "misc_utils.h"
#include "debug.h"

namespace math_expr_composer {

enum mexpr_bracket_e : int {
    MEXPR_BRACKET_ROUND,
    MEXPR_BRACKET_SQUARE,
    MEXPR_BRACKET_CURLY,
};

struct mexpr_bracket_t {
    mexpr_bracket_e type;
    char_draw_composer::char_t tl;          /* top left */
    char_draw_composer::char_t bl;          /* bottom left */
    char_draw_composer::char_t tr;          /* top right */
    char_draw_composer::char_t br;          /* bottom right */
    char_draw_composer::char_t cl;          /* center left */
    char_draw_composer::char_t cr;          /* center right */
    char_draw_composer::char_t conl;        /* connector */
    char_draw_composer::char_t conr;        /* connector */
    char_draw_composer::char_t left[4];     /* smaller brackets left part */
    char_draw_composer::char_t right[4];    /* smaller brackets right part */
};

} /* math_expr_composer */

namespace virt_composer {

extern inline std::unordered_map<std::string, math_expr_composer::mexpr_bracket_e>
        mexpr_bracket_from_str;

template <> inline math_expr_composer::mexpr_bracket_e
get_enum_val<math_expr_composer::mexpr_bracket_e>(fkyaml::node &n);

template <ssize_t index>
struct luaw_param_t<math_expr_composer::mexpr_bracket_t, index> {
    math_expr_composer::mexpr_bracket_t luaw_single_param(lua_State *L);
};

} /* virt_composer */

namespace math_expr_composer {

namespace vc = virt_composer;
namespace drawc = char_draw_composer;
namespace mexpr = math_expr_composer;

VIRT_COMPOSER_REGISTER_TYPE(MEXPR_TYPE_EXPR);

enum mexpr_e : int {
    MEXPR_TYPE_INTERNAL,
    MEXPR_TYPE_LINE_STRIP,
    MEXPR_TYPE_EMPTY_BOX,
    MEXPR_TYPE_SYMBOL,
};

using char_t = drawc::char_t;

struct mexpr_t;
using mexpr_p = vc::ref_t<mexpr_t>;

/*! holds an object and it's position */
struct anchor_t {
    mexpr_p obj;
    ImVec2  pos;
};

/*! How it works: If you where to draw this object as-is you would draw it at the baseline.
 * So let's take the character 'g', it's bounding box is slightly bellow the baseline and also
 * above the baseline. So assuming (0, 0) is on the baseline, the character would have it's
 * bounding box cut by the baseline.
 * 
 * As such, top left(tl) and bottom right(br) give us the bounding box of the object. While point
 * (0, 0) is the baseline for that object.
 * 
 * An object may have multiple subobjects, those having a position each.
 */
struct mexpr_t : public vc::object_t {
    /*! The type that this object will hold -> dictates what/how it is drawn */
    mexpr_e type = MEXPR_TYPE_INTERNAL;

    ImVec2 tl;                      /*!< Top Left */
    ImVec2 br;                      /*!< Bottom Right */

    /*! The subobjects of this object and their relative positions are stored in this */
    std::vector<anchor_t> subobjs;

    uint32_t color = 0xff'eeeeee;   /*!< Optional Color of the object  */

    char_t symb;                    /*!< Optional symbol if this object is a leaf */
    ImVec2 symb_off;                /*!< Optional position of the symbol, such that it is drawn on
                                         it's baseline when drawn at (0, 0) */

    float line_width = 1.0f;        /*!< Optional, if type is line */
    std::vector<ImVec2> line_strip; /*!< Optional, if type is MATHD_TYPE_LINE_STRIP */

    static vc::object_type_e type_id_static() { return MEXPR_TYPE_EXPR; }
    virtual vc::object_type_e type_id() const override { return MEXPR_TYPE_EXPR; }

    static vc::ref_t<mexpr_t> create(mexpr_e type) {
        auto ret = std::make_shared<mexpr_t>();
        ret->type = type;
        return ret;
    }

    inline virtual std::string to_string() const override {
        return std::format("mexpr::mexpr_t[{}] type: {}", (void *)this, (int)type);
    }
};

inline void mexpr_draw(vc::ref_t<drawc::fontset_t> fs, ImVec2 pos, mexpr_p m, bool draw_bb);
inline mexpr_p mexpr_empty(vc::ref_t<drawc::fontset_t> fs, float x, float y, float above_bl);
inline mexpr_p mexpr_symbol(vc::ref_t<drawc::fontset_t> fs, char_t sym, bool is_char);
inline mexpr_p mexpr_bigop(vc::ref_t<drawc::fontset_t> fs, mexpr_p right, mexpr_p above,
        mexpr_p bellow, char_t bigop);
inline mexpr_p mexpr_frac(vc::ref_t<drawc::fontset_t> fs, mexpr_p above, mexpr_p bellow,
        char_t divline);
inline mexpr_p mexpr_supsub(vc::ref_t<drawc::fontset_t> fs, mexpr_p base, mexpr_p sup, mexpr_p sub);
inline mexpr_p mexpr_bracket(vc::ref_t<drawc::fontset_t> fs, mexpr_p expr, mexpr_bracket_t bracket);
inline mexpr_p mexpr_unarexpr(vc::ref_t<drawc::fontset_t> fs, char_t op, mexpr_p b);
inline mexpr_p mexpr_binexpr(vc::ref_t<drawc::fontset_t> fs, mexpr_p a, char_t op, mexpr_p b);
inline mexpr_p mexpr_merge_h(vc::ref_t<drawc::fontset_t> fs, mexpr_p l, mexpr_p r);
inline mexpr_p mexpr_merge_v(vc::ref_t<drawc::fontset_t> fs, mexpr_p u, mexpr_p d);

/* TODO: matrix stuff */

/* IMPLEMENTATION
 * =================================================================================================
 */

inline int register_meta(vc::virt_state_t *vs) {
    DBG_SCOPE();

    std::vector<luaL_Reg> mexpr_tab_funcs = {
        { "mexpr_draw", vc::luaw_function_wrapper<mexpr_draw,
                vc::ref_t<drawc::fontset_t>, ImVec2, mexpr_p, bool>
        },
        { "mexpr_empty", vc::luaw_function_wrapper<mexpr_empty,
                vc::ref_t<drawc::fontset_t>, float, float, float>
        },
        { "mexpr_symbol", vc::luaw_function_wrapper<mexpr_symbol,
                vc::ref_t<drawc::fontset_t>, char_t, bool> 
        },
        { "mexpr_bigop", vc::luaw_function_wrapper<mexpr_bigop,
                vc::ref_t<drawc::fontset_t>, mexpr_p, mexpr_p, mexpr_p, char_t>
        },
        { "mexpr_frac", vc::luaw_function_wrapper<mexpr_frac,
                vc::ref_t<drawc::fontset_t>, mexpr_p, mexpr_p, char_t>
        },
        { "mexpr_supsub", vc::luaw_function_wrapper<mexpr_supsub,
                vc::ref_t<drawc::fontset_t>, mexpr_p, mexpr_p, mexpr_p>
        },
        { "mexpr_bracket", vc::luaw_function_wrapper<mexpr_bracket,
                vc::ref_t<drawc::fontset_t>, mexpr_p, mexpr_bracket_t>
        },
        { "mexpr_unarexpr", vc::luaw_function_wrapper<mexpr_unarexpr,
                vc::ref_t<drawc::fontset_t>, char_t, mexpr_p>
        },
        { "mexpr_binexpr", vc::luaw_function_wrapper<mexpr_binexpr,
                vc::ref_t<drawc::fontset_t>, mexpr_p, char_t, mexpr_p>
        },
        { "mexpr_merge_h", vc::luaw_function_wrapper<mexpr_merge_h,
                vc::ref_t<drawc::fontset_t>, mexpr_p, mexpr_p>
        },
        { "mexpr_merge_v", vc::luaw_function_wrapper<mexpr_merge_v,
                vc::ref_t<drawc::fontset_t>, mexpr_p, mexpr_p>
        },
    };

    vc::add_lua_flag_mapping(vs, vc::mexpr_bracket_from_str);

    ASSERT_FN(add_lua_tab_funcs(vs, mexpr_tab_funcs));
    return vc::VC_ERROR_OK;
}


#define MEXPR_DISTANCER         4
#define MEXPR_DISTANCER_BIGO    0.5

inline void mexpr_draw(vc::ref_t<drawc::fontset_t> fs, ImVec2 pos, mexpr_p m, bool draw_bb) {
    ImDrawList* draw_list = ImGui::GetWindowDrawList();
    if (!m)
        return ;
    ImVec2 bb_tl = pos + m->tl;
    ImVec2 bb_br = pos + m->br;
    if (draw_bb) {
        draw_list->AddRect(bb_tl, bb_br, 0xff'ffff00);
        draw_list->AddCircleFilled(pos, 3, 0xff'ff00ff);
    }

    switch (m->type) {
        case MEXPR_TYPE_SYMBOL: {
            fs->char_draw(m->symb, pos + m->symb_off, m->color, 0, 0);
        } break;
        case MEXPR_TYPE_LINE_STRIP: {
            for (int i = 1; i < m->line_strip.size(); i++) {
                draw_list->AddLine(pos + m->line_strip[i-1], pos + m->line_strip[i], m->color,
                        m->line_width);
            }
        } break;
        case MEXPR_TYPE_EMPTY_BOX: {
        } break;
        case MEXPR_TYPE_INTERNAL: {
            for (auto &anch : m->subobjs) {
                if (draw_bb) {
                    draw_list->AddLine(pos, pos + anch.pos, 0xff'00ff00);
                }
                mexpr_draw(fs, pos + anch.pos, anch.obj, draw_bb);
            }
        } break;
    }
}

inline mexpr_p mexpr_empty(vc::ref_t<drawc::fontset_t> fs, float x, float y, float above_bl) {
    auto ret = mexpr_t::create(MEXPR_TYPE_EMPTY_BOX);
    ret->tl = ImVec2(0, 0 - above_bl);
    ret->br = ImVec2(x, y - above_bl);
    return ret;
}

inline mexpr_p mexpr_symbol(vc::ref_t<drawc::fontset_t> fs, char_t sym, bool is_char) {
    auto [tl, br] = fs->char_get_bb(sym);

    auto ret = mexpr_t::create(MEXPR_TYPE_SYMBOL);
    ret->symb = sym;
    if (is_char) {
        /* For characters in general we want them to stay on the same baseline as 'a',
        more precisely the baseline passes through the middle of a */
        auto [a_tl, a_br] = fs->char_get_bb(char_t{.size=sym.size, .code=fs->m_a_code});
        ret->symb_off = ImVec2(0, -a_br.y + (a_br.y - a_tl.y) / 2.);
    }
    else {
        /* For bigsum or integral sign we want it to be centered on the baseline */
        ret->symb_off = ImVec2(0, -(tl.y + br.y) / 2.);
    }
    ret->tl = tl + ret->symb_off;
    ret->br = br + ret->symb_off;
    return ret;
}

inline float get_font_mul(vc::ref_t<drawc::fontset_t> fs, char_t c) {
    auto sz = fs->char_get_bb(char_t{ .size=c.size, .code=fs->m_a_code });
    return (sz.a_max.y - sz.a_min.y) / 10.0f;
}

inline std::pair<ImVec2, ImVec2> calc_bb(const std::vector<anchor_t>& anchors) {
    if (anchors.size() == 0)
        return {ImVec2(0, 0), ImVec2(0, 0)};
    auto tl = anchors[0].pos + anchors[0].obj->tl;
    auto br = anchors[0].pos + anchors[0].obj->br;
    for (auto &a : anchors) {
        tl.x = std::min(tl.x, a.pos.x + a.obj->tl.x);
        tl.y = std::min(tl.y, a.pos.y + a.obj->tl.y);
        br.x = std::max(br.x, a.pos.x + a.obj->br.x);
        br.y = std::max(br.y, a.pos.y + a.obj->br.y);
    }
    return {tl, br};
}

inline ImVec2 calc_sz(ImVec2 tl, ImVec2 br) {
    return ImVec2(br.x - tl.x, br.y - tl.y);
}

inline mexpr_p mexpr_bigop(vc::ref_t<drawc::fontset_t> fs,
        mexpr_p right, mexpr_p above, mexpr_p bellow, char_t bigop)
{
    /* OBS: 1. a random distance is used to delimit above and bellow
            2. above and bellow don't stay nicely on integral big op
            3. the integral operator is to far from `right`, the operand */
    if (!right)
        throw vc::except_t("can't use mexpr_bigop without right");
    if (!above)
        above = mexpr_t::create(MEXPR_TYPE_EMPTY_BOX);
    if (!bellow)
        bellow = mexpr_t::create(MEXPR_TYPE_EMPTY_BOX);

    float dst = MEXPR_DISTANCER_BIGO * get_font_mul(fs, bigop);
    auto ret = mexpr_t::create(MEXPR_TYPE_INTERNAL);
    auto op = mexpr_symbol(fs, bigop, false);

    auto sz_above = calc_sz(above->tl, above->br);
    auto sz_bellow = calc_sz(bellow->tl, bellow->br);
    auto sz_op = calc_sz(op->tl, op->br);

    ret->subobjs = std::vector<anchor_t> {
        { .obj = op,     .pos = ImVec2(0, 0) },
        { .obj = above,  .pos = ImVec2( -sz_above.x/2. + sz_op.x/2., op->tl.y - above->br.y - dst) },
        { .obj = bellow, .pos = ImVec2(-sz_bellow.x/2. + sz_op.x/2., op->br.y - bellow->tl.y + dst) },
        { .obj = right,  .pos = ImVec2(op->br.x, 0) },
    };

    auto [tl, br] = calc_bb(ret->subobjs);
    ret->tl = tl;
    ret->br = br;

    return ret;
}

inline mexpr_p mexpr_frac(vc::ref_t<drawc::fontset_t> fs,
        mexpr_p above, mexpr_p bellow, char_t divline)
{
    /* OBS: 1. divline is not actually used, only it's height
            2. a random distance is used to calc the distance from the line and additional 
               width of the fraction line */
    if (!bellow || !above)
        throw vc::except_t("can't use mexpr_frac without both ops");

    float dst = MEXPR_DISTANCER * get_font_mul(fs, divline);
    auto sz_above = calc_sz(above->tl, above->br);
    auto sz_bellow = calc_sz(bellow->tl, bellow->br);
    float sz_frac_x = std::max(sz_above.x, sz_bellow.x) + 2*dst;

    auto ret = mexpr_t::create(MEXPR_TYPE_INTERNAL);

    auto dl = mexpr_t::create(MEXPR_TYPE_LINE_STRIP);
    auto tmp_div = mexpr_symbol(fs, divline, false);
    dl->tl = ImVec2(0, tmp_div->tl.y);
    dl->br = ImVec2(sz_frac_x, tmp_div->br.y);
    dl->line_strip.push_back(ImVec2(0, 0));
    dl->line_strip.push_back(ImVec2(sz_frac_x, 0));
    dl->line_width = (tmp_div->br.y - tmp_div->tl.y);

    ret->subobjs = std::vector<anchor_t> {
        { .obj = above,   .pos = ImVec2((sz_frac_x - sz_above.x)/2., -above->br.y - dst) },
        { .obj = bellow,  .pos = ImVec2((sz_frac_x - sz_bellow.x)/2., -bellow->tl.y + dst) },
        { .obj = dl,      .pos = ImVec2(0, 0) }
    };

    auto [tl, br] = calc_bb(ret->subobjs);
    ret->tl = tl;
    ret->br = br;

    return ret;
}

/*       -#####
          #   #
          # E #
         +#   #
 #####-   #   #
 #   #   =#####
 #   #
+# B #
 #   #
 #   #
 #####

The idea is that we want to match the superscript's baseline (E+) with that of the base's top (B-)
if possible.

TODO: There are two posible problems that must be avoided:

1. The exponent must be at least 2/5 of the base above the base's bottom
2. The exponent must have at least 1/4 of it's height above the base's top

mirrored for subscripts
*/
inline mexpr_p mexpr_supsub(vc::ref_t<drawc::fontset_t> fs,
        mexpr_p base, mexpr_p sup, mexpr_p sub)
{
    /* OBS: 1. the distance from the `exponent` is a random distance
            2. the placement of sub/sup are chosen at random */
    if (!base)
        throw vc::except_t("can't use mexpr_supsub without a base");

    auto ret = mexpr_t::create(MEXPR_TYPE_INTERNAL);
    auto sz_base = calc_sz(base->tl, base->br);

    ret->subobjs.push_back(anchor_t{ .obj = base, .pos = ImVec2(0, 0) });

    if (sup) {
        auto sz_sup = calc_sz(sup->tl, sup->br);
        ret->subobjs.push_back(anchor_t{ .obj = sup, .pos = ImVec2(base->br.x, base->tl.y) });
    }

    if (sub) {
        auto sz_sub = calc_sz(sup->tl, sup->br);
        ret->subobjs.push_back(anchor_t{ .obj = sub, .pos = ImVec2(base->br.x, base->br.y) });
    }

    auto [tl, br] = calc_bb(ret->subobjs);
    ret->tl = tl;
    ret->br = br;

    return ret;
}

inline mexpr_p mexpr_unarexpr(vc::ref_t<drawc::fontset_t> fs, char_t op, mexpr_p a) {
    // float distancer = MEXPR_DISTANCER * get_font_mul(fs, op);
    // auto ret = mexpr_t::create(MATHD_TYPE_BINAR_OP);
    // auto sym_op = mexpr_symbol(fs, op, true);

    // float aoff = a->voff - sym_op->voff;
    // float hmax = std::max(aoff, 0.0f);
    // ret->subobjs = std::vector<std::pair<mexpr_p, ImVec2>> {
    //     {sym_op, ImVec2(0,                         hmax - 0)},
    //     {a,      ImVec2(sym_op->size.x + distancer, hmax - aoff)},
    // };

    // float h = std::max(hmax - aoff + a->size.y, hmax + sym_op->size.y);
    // ret->size = ImVec2(a->size.x + sym_op->size.x + distancer, h);
    // ret->voff = hmax + sym_op->voff;
    // return ret;
    return nullptr;
}

inline mexpr_p mexpr_binexpr(vc::ref_t<drawc::fontset_t> fs, mexpr_p a, char_t op, mexpr_p b) {
    // float distancer = MEXPR_DISTANCER * get_font_mul(fs, op);
    // auto ret = mexpr_t::create(MATHD_TYPE_BINAR_OP);
    // auto sym_op = mexpr_symbol(fs, op, true);

    // float aoff = a->voff - sym_op->voff;
    // float boff = b->voff - sym_op->voff;
    // float hmax = std::max(std::max(aoff, boff), 0.0f);
    // ret->subobjs = std::vector<std::pair<mexpr_p, ImVec2>> {
    //     {a,      ImVec2(0,                                         hmax - aoff)},
    //     {sym_op, ImVec2(a->size.x + distancer,                     hmax - 0)},
    //     {b,      ImVec2(sym_op->size.x + a->size.x + 2.*distancer, hmax - boff)},
    // };

    // float h = std::max(std::max(hmax - aoff + a->size.y, hmax - boff + b->size.y),
    //         hmax + sym_op->size.y);
    // ret->size = ImVec2(a->size.x + b->size.x + sym_op->size.x + distancer*2., h);
    // ret->voff = hmax + sym_op->voff;

    // return ret;
    return nullptr;
}

inline mexpr_p mexpr_merge_h(vc::ref_t<drawc::fontset_t> fs, mexpr_p l, mexpr_p r) {
    // auto ret = mexpr_t::create(MATHD_TYPE_MERGE_HORIZONTAL);

    // /* TODO: */
    // return ret;
    return nullptr;
}

inline mexpr_p mexpr_merge_v(vc::ref_t<drawc::fontset_t> fs, mexpr_p u, mexpr_p d) {
    // auto ret = mexpr_t::create(MATHD_TYPE_MERGE_VERTICAL);

    // /* TODO: */
    // return ret;
    return nullptr;
}

/* This is taken from ImGui and transformed to fit my needs */
inline void beziere_path_rec(std::vector<ImVec2>& path, ImVec2 P1, ImVec2 P2, ImVec2 P3, ImVec2 P4,
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

inline mexpr_p mexpr_bracket(vc::ref_t<drawc::fontset_t> fs, mexpr_p expr, mexpr_bracket_t bracket) {
    // auto sym_h = [&](char_t sym) {
    //     return fs->char_get_bb(sym).a_max.y - fs->char_get_bb(sym).a_min.y;
    // };

    // float brack_h = 0;
    // float off_l = 0.0f, off_r = 0.0f;
    // float sz_l = 0.0f, sz_r = 0.0f;
    // auto calc_offsets = [&](const std::vector<ImVec2>& ls, const std::vector<ImVec2>& rs) {
    //     for (auto &p : ls) {
    //         brack_h = std::max(brack_h, p.y);
    //         sz_l = std::max(sz_l, p.x);
    //     }
    //     for (auto &p : rs) {
    //         brack_h = std::max(brack_h, p.y);
    //         sz_r = std::max(sz_r, p.x);
    //     }

    //     off_l = 0;
    //     off_r = sz_r;

    //     float h1 = (brack_h - expr->size.y) / 2.;
    //     float h2 = expr->size.y + h1;
    //     for (auto &p : ls) {
    //         if (p.y < h1 || p.y > h2)
    //             continue;
    //         off_l = std::max(off_l, p.x);
    //     }
    //     for (auto &p : rs) {
    //         if (p.y < h1 || p.y > h2)
    //             continue;
    //         off_r = std::min(off_r, p.x);
    //     }

    //     off_r = -off_r;
    // };

    // /* First we need to select the appropiate paranthesis dimension for the expression and construct
    // the paranthesis objects */
    // mexpr_p lb, rb;
    // if (sym_h(bracket.left[3]) > expr->size.y) {
    //     lb = mexpr_symbol(fs, bracket.left[3], false);
    //     rb = mexpr_symbol(fs, bracket.right[3], false);
    // }
    // else if (sym_h(bracket.left[2]) > expr->size.y) {
    //     lb = mexpr_symbol(fs, bracket.left[2], false);
    //     rb = mexpr_symbol(fs, bracket.right[2], false);
    // }
    // else if (sym_h(bracket.left[1]) > expr->size.y) {
    //     lb = mexpr_symbol(fs, bracket.left[1], false);
    //     rb = mexpr_symbol(fs, bracket.right[1], false);
    // }
    // else if (sym_h(bracket.left[0]) > expr->size.y) {
    //     lb = mexpr_symbol(fs, bracket.left[0], false);
    //     rb = mexpr_symbol(fs, bracket.right[0], false);
    // }
    // else {
    //     float f = 1;
    //     lb = mexpr_t::create(MATHD_TYPE_INTERNAL);
    //     rb = mexpr_t::create(MATHD_TYPE_INTERNAL);
    //     auto lb_tl = mexpr_symbol(fs, bracket.tl, false);
    //     auto lb_bl = mexpr_symbol(fs, bracket.bl, false);
    //     auto lb_cl = mexpr_symbol(fs, bracket.cl, false);
    //     auto rb_tr = mexpr_symbol(fs, bracket.tr, false);
    //     auto rb_br = mexpr_symbol(fs, bracket.br, false);
    //     auto rb_cr = mexpr_symbol(fs, bracket.cr, false);
    //     auto conl = mexpr_symbol(fs, bracket.conl, false);
    //     auto conr = mexpr_symbol(fs, bracket.conr, false);

    //     float sz = lb_tl->size.y + lb_cl->size.y + lb_bl->size.y;
    //     int con_cnt = 0;
    //     if (sz < expr->size.y) {
    //         con_cnt = std::ceil((expr->size.y - sz) / (conl->size.y*f));
    //         if (con_cnt % 2 == 1)
    //             con_cnt++;
    //     }

    //     float h = 0;
    //     if (bracket.type == MEXPR_BRACKET_SQUARE) {
    //         h = lb_tl->size.y + lb_bl->size.y + lb_cl->size.y + con_cnt * conl->size.y;
    //         auto lines_l = mexpr_t::create(MATHD_TYPE_LINE_STRIP);
    //         auto [a_min, a_max] = fs->char_get_bb(bracket.tl);
    //         float minx = a_min.x;
    //         lines_l->line_strip.push_back(ImVec2(a_max.x - minx, 0));
    //         lines_l->line_strip.push_back(ImVec2(a_min.x - minx, 0));
    //         lines_l->line_strip.push_back(ImVec2(a_min.x - minx, h));
    //         lines_l->line_strip.push_back(ImVec2(a_max.x - minx, h));
    //         lines_l->line_width = conl->size.x;
    //         lines_l->color = 0xff'eeeeee;
    //         lb->subobjs.push_back({lines_l, ImVec2(0, 0)});

    //         auto lines_r = mexpr_t::create(MATHD_TYPE_LINE_STRIP);
    //         auto [b_min, b_max] = fs->char_get_bb(bracket.tr);
    //         minx = b_min.x;
    //         lines_r->line_strip.push_back(ImVec2(b_min.x - minx, 0));
    //         lines_r->line_strip.push_back(ImVec2(b_max.x - minx, 0));
    //         lines_r->line_strip.push_back(ImVec2(b_max.x - minx, h));
    //         lines_r->line_strip.push_back(ImVec2(b_min.x - minx, h));
    //         lines_r->line_width = conl->size.x;
    //         lines_r->color = 0xff'eeeeee;
    //         rb->subobjs.push_back({lines_r, ImVec2(0, 0)});
    //         calc_offsets(lines_l->line_strip, lines_r->line_strip);
    //     }
    //     else if (bracket.type == MEXPR_BRACKET_ROUND) {
    //         h = lb_tl->size.y + lb_bl->size.y + lb_cl->size.y + con_cnt * conl->size.y;
    //         auto lines_l = mexpr_t::create(MATHD_TYPE_LINE_STRIP);
    //         auto [a_min, a_max] = fs->char_get_bb(bracket.tl);
    //         float minx = a_min.x;
    //         lines_l->line_strip.push_back(ImVec2(a_max.x - minx, 0));
    //         beziere_path_rec(lines_l->line_strip,
    //             ImVec2(a_max.x - minx, 0),
    //             ImVec2((a_max.x + a_min.x) / 2. - minx, lb_tl->size.y / 8.),
    //             ImVec2(a_min.x - minx, lb_tl->size.y / 8. * 3.),
    //             ImVec2(a_min.x - minx, lb_tl->size.y));
    //         lines_l->line_strip.push_back(ImVec2(a_min.x - minx, lb_tl->size.y));
    //         beziere_path_rec(lines_l->line_strip,
    //                 ImVec2(a_min.x - minx, h - lb_bl->size.y),
    //                 ImVec2(a_min.x - minx, h - lb_bl->size.y / 8. * 3.),
    //                 ImVec2((a_min.x + a_max.x) / 2. - minx, h - lb_bl->size.y / 8.),
    //                 ImVec2(a_max.x - minx, h));
    //         lines_l->line_width = conl->size.x;
    //         lines_l->color = 0xff'eeeeee;
    //         lb->subobjs.push_back({lines_l, ImVec2(0, 0)});

    //         auto lines_r = mexpr_t::create(MATHD_TYPE_LINE_STRIP);
    //         auto [b_min, b_max] = fs->char_get_bb(bracket.tr);
    //         minx = b_min.x;
    //         lines_r->line_strip.push_back(ImVec2(b_min.x - minx, 0));
    //         beziere_path_rec(lines_r->line_strip,
    //             ImVec2(b_min.x - minx, 0),
    //             ImVec2((b_min.x + b_max.x) / 2. - minx, rb_tr->size.y / 8.),
    //             ImVec2(b_max.x - minx, rb_tr->size.y / 8. * 3.),
    //             ImVec2(b_max.x - minx, rb_tr->size.y));
    //         lines_r->line_strip.push_back(ImVec2(b_max.x - minx, rb_tr->size.y));
    //         beziere_path_rec(lines_r->line_strip,
    //                 ImVec2(b_max.x - minx, h - rb_br->size.y),
    //                 ImVec2(b_max.x - minx, h - rb_br->size.y / 8. * 3.),
    //                 ImVec2((b_max.x + b_min.x) / 2. - minx, h - rb_br->size.y / 8.),
    //                 ImVec2(b_min.x - minx, h));
    //         lines_r->line_width = conr->size.x;
    //         lines_r->color = 0xff'eeeeee;
    //         rb->subobjs.push_back({lines_r, ImVec2(0, 0)});
    //         calc_offsets(lines_l->line_strip, lines_r->line_strip);
    //     }
    //     else if (bracket.type == MEXPR_BRACKET_CURLY) {
    //         h = lb_tl->size.y + lb_bl->size.y + lb_cl->size.y + con_cnt * conl->size.y;
    //         float h2 = h / 2.;
    //         auto [a_min, a_max] = fs->char_get_bb(bracket.tl);
    //         auto [b_min, b_max] = fs->char_get_bb(bracket.cl);
    //         auto [c_min, c_max] = fs->char_get_bb(bracket.bl);

    //         float minx = std::min({a_min.x, b_min.x, c_min.x});

    //         auto lines_l = mexpr_t::create(MATHD_TYPE_LINE_STRIP);
    //         lines_l->line_strip.push_back(ImVec2(a_max.x - minx, 0));
    //         beziere_path_rec(lines_l->line_strip,
    //                 ImVec2(a_max.x - minx, 0),
    //                 ImVec2(a_min.x * 0.75 + a_max.x * 0.25 - minx, 0),
    //                 ImVec2(a_min.x - minx, lb_tl->size.y * 0.25),
    //                 ImVec2(a_min.x - minx, lb_tl->size.y));
    //         lines_l->line_strip.push_back(ImVec2(b_max.x - minx, h2 - lb_cl->size.y * 0.5));
    //         beziere_path_rec(lines_l->line_strip,
    //                 ImVec2(b_max.x - minx, h2 - lb_cl->size.y * 0.5),
    //                 ImVec2(b_max.x - minx, h2 + lb_cl->size.y * (.75 * .5 - .5)),
    //                 ImVec2(b_max.x * 0.75 + b_min.x * 0.25 - minx, h2),
    //                 ImVec2(b_min.x - minx, h2));
    //         lines_l->line_strip.push_back(ImVec2(b_min.x - minx, h2));
    //         beziere_path_rec(lines_l->line_strip,
    //                 ImVec2(b_min.x - minx, h2),
    //                 ImVec2(b_min.x * .25 + b_max.x * .75 - minx, h2),
    //                 ImVec2(b_max.x - minx, h2 + lb_cl->size.y * .75 * .5),
    //                 ImVec2(b_max.x - minx, h2 + lb_cl->size.y * .5));
    //         lines_l->line_strip.push_back(ImVec2(c_min.x - minx, h - lb_bl->size.y));
    //         beziere_path_rec(lines_l->line_strip,
    //                 ImVec2(c_min.x - minx, h - lb_bl->size.y),
    //                 ImVec2(c_min.x - minx, h - lb_bl->size.y * .25),
    //                 ImVec2(c_min.x * .75 + c_max.x * .25 - minx, h),
    //                 ImVec2(c_max.x - minx, h));
    //         lines_l->color = 0xff'eeeeee;
    //         lines_l->line_width = conl->size.x;
    //         lb->subobjs.push_back({lines_l, ImVec2(0, 0)});

    //         auto [d_min, d_max] = fs->char_get_bb(bracket.tr);
    //         auto [e_min, e_max] = fs->char_get_bb(bracket.cr);
    //         auto [f_min, f_max] = fs->char_get_bb(bracket.br);

    //         minx = std::min({d_min.x, e_min.x, f_min.x});

    //         auto lines_r = mexpr_t::create(MATHD_TYPE_LINE_STRIP);
    //         lines_r->line_strip.push_back(ImVec2(d_min.x - minx, 0));
    //         beziere_path_rec(lines_r->line_strip,
    //                 ImVec2(d_min.x - minx, 0),
    //                 ImVec2(d_max.x * 0.75 + d_min.x * 0.25 - minx, 0),
    //                 ImVec2(d_max.x - minx, rb_tr->size.y * 0.25),
    //                 ImVec2(d_max.x - minx, rb_tr->size.y));
    //         lines_r->line_strip.push_back(ImVec2(e_min.x - minx, h2 - rb_cr->size.y * 0.5));
    //         beziere_path_rec(lines_r->line_strip,
    //                 ImVec2(e_min.x - minx, h2 - rb_cr->size.y * 0.5),
    //                 ImVec2(e_min.x - minx, h2 + rb_cr->size.y * (.75 * .5 - .5)),
    //                 ImVec2(e_min.x * 0.75 + e_max.x * 0.25 - minx, h2),
    //                 ImVec2(e_max.x - minx, h2));
    //         lines_r->line_strip.push_back(ImVec2(e_max.x - minx, h2));
    //         beziere_path_rec(lines_r->line_strip,
    //                 ImVec2(e_max.x - minx, h2),
    //                 ImVec2(e_max.x * .25 + e_min.x * .75 - minx, h2),
    //                 ImVec2(e_min.x - minx, h2 + rb_cr->size.y * .75 * .5),
    //                 ImVec2(e_min.x - minx, h2 + rb_cr->size.y * .5));
    //         lines_r->line_strip.push_back(ImVec2(f_max.x - minx, h - rb_br->size.y));
    //         beziere_path_rec(lines_r->line_strip,
    //                 ImVec2(f_max.x - minx, h - rb_br->size.y),
    //                 ImVec2(f_max.x - minx, h - rb_br->size.y * .25),
    //                 ImVec2(f_max.x * .75 + f_min.x * .25 - minx, h),
    //                 ImVec2(f_min.x - minx, h));
    //         lines_r->color = 0xff'eeeeee;
    //         lines_r->line_width = conr->size.x;
    //         rb->subobjs.push_back({lines_r, ImVec2(0, 0)});
    //         calc_offsets(lines_l->line_strip, lines_r->line_strip);
    //     }

    //     // lb->size = ImVec2(std::max({lb_tl->size.x, conl->size.x, lb_cl->size.x, lb_bl->size.x}), h);
    //     // rb->size = ImVec2(std::max({rb_tr->size.x, conr->size.x, rb_cr->size.x, rb_br->size.x}), h);
    // }

    // float distancer = MEXPR_DISTANCER * 2 * get_font_mul(fs, bracket.left[0]);
    // auto ret = mexpr_t::create(MATHD_TYPE_UNAR_OP);

    // /* afterwards we construct the final object */
    // float h = (lb->size.y + brack_h - expr->size.y) / 2.;
    // ret->subobjs = std::vector<std::pair<mexpr_p, ImVec2>> {
    //     {lb,   ImVec2(0, 0)},
    //     {expr, ImVec2(off_l + lb->size.x + distancer, h)},
    //     {rb,   ImVec2(off_l + off_r + lb->size.x + expr->size.x + 2*distancer, 0)},
    // };    

    // ret->size = ImVec2(expr->size.x + 2*distancer + off_l + off_r + sz_r +
    //         lb->size.x + rb->size.x, lb->size.y + brack_h);
    // ret->voff = expr->voff + h;

    // return ret;
    return nullptr;
}

} /* math_expr_composer */

namespace virt_composer
{

inline std::unordered_map<std::string, math_expr_composer::mexpr_bracket_e> mexpr_bracket_from_str =
{
    {"MEXPR_BRACKET_ROUND", math_expr_composer::MEXPR_BRACKET_ROUND},
    {"MEXPR_BRACKET_SQUARE", math_expr_composer::MEXPR_BRACKET_SQUARE},
    {"MEXPR_BRACKET_CURLY", math_expr_composer::MEXPR_BRACKET_CURLY},
};

template <> inline math_expr_composer::mexpr_bracket_e
get_enum_val<math_expr_composer::mexpr_bracket_e>(fkyaml::node &n) {
    return get_enum_val(n, mexpr_bracket_from_str);
}


template <ssize_t index>
inline math_expr_composer::mexpr_bracket_t
luaw_param_t<math_expr_composer::mexpr_bracket_t, index>::luaw_single_param(lua_State *L) {
    math_expr_composer::mexpr_bracket_t ret{};
    if (lua_isnil(L, index))
        return ret;
    using char_t = char_draw_composer::char_t;

    lua_getfield(L, index, "type");
    ret.type = luaw_param_t<bm_t<math_expr_composer::mexpr_bracket_e>, -1>{}.luaw_single_param(L);
    lua_pop(L, 1);

    lua_getfield(L, index, "tl");
    ret.tl = luaw_param_t<char_t, -1>{}.luaw_single_param(L);
    lua_pop(L, 1);
    
    lua_getfield(L, index, "bl");
    ret.bl = luaw_param_t<char_t, -1>{}.luaw_single_param(L);
    lua_pop(L, 1);
    
    lua_getfield(L, index, "tr");
    ret.tr = luaw_param_t<char_t, -1>{}.luaw_single_param(L);
    lua_pop(L, 1);
    
    lua_getfield(L, index, "br");
    ret.br = luaw_param_t<char_t, -1>{}.luaw_single_param(L);
    lua_pop(L, 1);
    
    lua_getfield(L, index, "cl");
    ret.cl = luaw_param_t<char_t, -1>{}.luaw_single_param(L);
    lua_pop(L, 1);
    
    lua_getfield(L, index, "cr");
    ret.cr = luaw_param_t<char_t, -1>{}.luaw_single_param(L);
    lua_pop(L, 1);

    lua_getfield(L, index, "conl");
    ret.conl = luaw_param_t<char_t, -1>{}.luaw_single_param(L);
    lua_pop(L, 1);

    lua_getfield(L, index, "conr");
    ret.conr = luaw_param_t<char_t, -1>{}.luaw_single_param(L);
    lua_pop(L, 1);
    
    lua_getfield(L, index, "left");
    auto left = luaw_param_t<std::vector<char_t>, -1>{}.luaw_single_param(L);
    for (int i = 0; i < left.size() && i < 4; i++)
        ret.left[i] = left[i];
    lua_pop(L, 1);

    lua_getfield(L, index, "right");
    auto right = luaw_param_t<std::vector<char_t>, -1>{}.luaw_single_param(L);
    for (int i = 0; i < right.size() && i < 4; i++)
        ret.right[i] = right[i];
    lua_pop(L, 1);

    return ret;
}

} /* virt_composer */

#endif

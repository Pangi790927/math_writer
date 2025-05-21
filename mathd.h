#ifndef MATHD_H
#define MATHD_H

/* Math Symbol and Expression Drawing */

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
};

/* TODO: maybe should stay in implementation */
enum mathd_cmd_e : int {
    /* movement: */
    MATHD_ABOVE,
    MATHD_BELLOW,
    MATHD_LEFT,
    MATHD_RIGHT,
    MATHD_SUP,
    MATHD_SUB,

    /* modifier: */
    MATHD_MAKEFIT,     /* Makes dst fit both src and dst */

    /* creators: */
    MATHD_EXPR,
    MATHD_SYM,
    MATHD_EMPTY,
    MATHD_MERGE,
};

enum mathd_obj_e : int {
    MATHD_OBJ_SYMB,
    MATHD_OBJ_SUBEXPR,
    MATHD_OBJ_EMPTY,
};

enum mathd_bracket_e : int {
    MATHD_BRACKET_ROUND,
    MATHD_BRACKET_SQUARE,
    MATHD_BRACKET_CURLY,
};

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

struct mathd_t;
using mathd_p = std::shared_ptr<mathd_t>;

template <typename ...Args>
mathd_p mathd_make(Args&&... args);

int mathd_draw(ImVec2 pos, mathd_p m);

mathd_p mathd_empty();
mathd_p mathd_symbol(char_t sym);
mathd_p mathd_bigop(mathd_p right, mathd_p above, mathd_p bellow, char_t bigop);
mathd_p mathd_frac(mathd_p above, mathd_p bellow, char_t divline);
mathd_p mathd_supsub(mathd_p base, mathd_p sup, mathd_p sub);
mathd_p mathd_bracket(mathd_p expr, char_t lb, char_t rb);
mathd_p mathd_unarexpr(char_t op, mathd_p b);
mathd_p mathd_binexpr(mathd_p a, char_t op, mathd_p b);
mathd_p mathd_merge_h(mathd_p l, mathd_p r);
mathd_p mathd_merge_v(mathd_p u, mathd_p d);

char_t          mathd_convert(char_t msym, char_font_lvl_e font_lvl);
mathd_bracket_t mathd_convert(mathd_bracket_t msym, char_font_lvl_e font_lvl);

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
struct mathd_bb_t {
    float h = 0, w = 0;
};

struct mathd_obj_t {
    mathd_obj_e type;
    int id;

    char_t sym;
    mathd_p expr;
    mathd_bb_t bb;
    ImVec2 off = {0, 0};     /* relative position to the origin of the mathd_t object
                            (not the same as the center of the object) */
};

struct mathd_cmd_t {
    mathd_cmd_e type;
    int param = -1;         /* The parameter expresion in used in the command */
    int spawn_id = -1;      /* If not -1, the id of the new block */
    int src_id = -1;        /* If acting on an element, the id of the reference element */
    int dst_id = -1;        /* If acting on an element, the id of the modified element */
    char_t sym;             /* In case this is a symbol element */
    mathd_bb_t bb;
};

struct mathd_t {
    mathd_e type;
    int anchor_id = -1;
    std::vector<mathd_cmd_t> cmds;

/* TODO: maybe protect those? */
    std::vector<mathd_obj_t> objs;
    std::map<int, int> id_mapping;
    bool was_init = false;
    float acnhor_y = 0;
    float max_x = 0, max_y = 0, min_x = 0, min_y = 0;
    std::function<void(mathd_p, ImVec2)> cbk;
    std::shared_ptr<void> usr_ptr;
};

inline mathd_bb_t mathd_get_bb(mathd_p m) {
    return mathd_bb_t{
        .h = (m->max_y - m->min_y) / 2.0f,
        .w = (m->max_x - m->min_x) / 2.0f,
    };
}

inline void mathd_recalc_minmax(mathd_p m) {
    m->max_x = m->max_y = m->min_x = m->min_y = 0;
    for (auto &obj : m->objs) {
        // DBG("obj.bb: [.w = %f .h = %f]", obj.bb.w, obj.bb.h);
        m->max_x = std::max(m->max_x, obj.off.x + obj.bb.w);
        m->max_y = std::max(m->max_y, obj.off.y + obj.bb.h);
        m->min_x = std::min(m->min_x, obj.off.x - obj.bb.w);
        m->min_y = std::min(m->min_y, obj.off.y - obj.bb.h);
    }
}

inline int mathd_check_movcmd(mathd_p m, const mathd_cmd_t& cmd) {
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

inline mathd_bb_t mathd_char_bb(const char_t &sym) {
    auto ssz = char_get_sz(sym);
    return mathd_bb_t{
        .h = (float)abs(ssz.bl.y - ssz.tr.y) / 2.0f, 
        .w = (float)abs(ssz.bl.x - ssz.tr.x) / 2.0f
    };
}

inline void mathd_draw_bb(const ImVec2& center, const mathd_bb_t& bb, uint32_t color) {
    ImDrawList* draw_list = ImGui::GetWindowDrawList();
    auto bl = center + ImVec2(-bb.w, +bb.h);
    auto tr = center + ImVec2(+bb.w, -bb.h);

    draw_list->AddLine(ImVec2(bl.x, bl.y), ImVec2(tr.x, bl.y), color, 1);
    draw_list->AddLine(ImVec2(tr.x, bl.y), ImVec2(tr.x, tr.y), color, 1);
    draw_list->AddLine(ImVec2(tr.x, tr.y), ImVec2(bl.x, tr.y), color, 1);
    draw_list->AddLine(ImVec2(bl.x, tr.y), ImVec2(bl.x, bl.y), color, 1);
}

inline int mathd_init(mathd_p m, std::vector<mathd_p> params) {
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
            case MATHD_EXPR: {
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
                mathd_obj_t new_obj {
                    .type = MATHD_OBJ_SUBEXPR,
                    .id = id,
                    .expr = params[cmd.param],
                    .bb = mathd_get_bb(params[cmd.param]),
                };
                m->objs.push_back(new_obj);
                m->id_mapping[id] = m->objs.size() - 1;
            } break;
            case MATHD_SYM: {
                mathd_obj_t new_obj {
                    .type = MATHD_OBJ_SYMB,
                    .id = id,
                    .sym = cmd.sym,
                    .bb = mathd_char_bb(cmd.sym),
                };
                DBG("new_obj.bb: [.w = %f .h = %f]", new_obj.bb.w, new_obj.bb.h);
                m->objs.push_back(new_obj);
                m->id_mapping[id] = m->objs.size() - 1;
            } break;
            
            case MATHD_EMPTY: {
                mathd_obj_t new_obj {
                    .type = MATHD_OBJ_EMPTY,
                    .id = id,
                    .bb = cmd.bb,
                };
                m->objs.push_back(new_obj);
                m->id_mapping[id] = m->objs.size() - 1;
            } break;
            case MATHD_MERGE: {
                mathd_recalc_minmax(m);
                auto bb = mathd_get_bb(m);
                mathd_obj_t new_obj {
                    .type = MATHD_OBJ_EMPTY,
                    .id = id,
                    .bb = bb,
                };
                m->objs.push_back(new_obj);
                m->id_mapping[id] = m->objs.size() - 1;
            } break;
            case MATHD_ABOVE: {
                // if (intptr_t(mathd_check_movcmd(m, cmd)) < 0) {
                //     DBG("[SYS] " "FAILED: " "mathd_check_movcmd(m, cmd)" "[err: %s [%s], code: %d]",, strerror(errno), errnoname(errno), errno)

                //     return -1;
                // }

                ASSERT_FN(mathd_check_movcmd(m, cmd));

                auto &src = m->objs[m->id_mapping[cmd.src_id]];
                auto &dst = m->objs[m->id_mapping[cmd.dst_id]];

                dst.off = src.off + ImVec2(0, -(src.bb.h + dst.bb.h));
            } break;
            case MATHD_BELLOW: {
                ASSERT_FN(mathd_check_movcmd(m, cmd));

                auto &src = m->objs[m->id_mapping[cmd.src_id]];
                auto &dst = m->objs[m->id_mapping[cmd.dst_id]];

                dst.off = src.off + ImVec2(0, +(src.bb.h + dst.bb.h));
            } break;
            case MATHD_LEFT: {
                ASSERT_FN(mathd_check_movcmd(m, cmd));

                auto &src = m->objs[m->id_mapping[cmd.src_id]];
                auto &dst = m->objs[m->id_mapping[cmd.dst_id]];

                dst.off = src.off + ImVec2(-(src.bb.w + dst.bb.w), 0);
            } break;
            case MATHD_RIGHT: {
                ASSERT_FN(mathd_check_movcmd(m, cmd));

                auto &src = m->objs[m->id_mapping[cmd.src_id]];
                auto &dst = m->objs[m->id_mapping[cmd.dst_id]];

                dst.off = src.off + ImVec2(+(src.bb.w + dst.bb.w), 0);
            } break;
            case MATHD_SUB: {
                ASSERT_FN(mathd_check_movcmd(m, cmd));

                auto &src = m->objs[m->id_mapping[cmd.src_id]];
                auto &dst = m->objs[m->id_mapping[cmd.dst_id]];

                dst.off = src.off + ImVec2(+(src.bb.w + dst.bb.w), src.bb.h);
            } break;
            case MATHD_SUP: {
                ASSERT_FN(mathd_check_movcmd(m, cmd));

                auto &src = m->objs[m->id_mapping[cmd.src_id]];
                auto &dst = m->objs[m->id_mapping[cmd.dst_id]];

                dst.off = src.off + ImVec2(+(src.bb.w + dst.bb.w), -src.bb.h);
            } break;
            case MATHD_MAKEFIT: {
                ASSERT_FN(mathd_check_movcmd(m, cmd));

                auto &src = m->objs[m->id_mapping[cmd.src_id]];
                auto &dst = m->objs[m->id_mapping[cmd.dst_id]];
                dst.bb = mathd_bb_t{
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
    mathd_recalc_minmax(m);
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
inline int mathd_draw(ImVec2 pos, mathd_p m) {
    if (!m || !m->was_init) {
        DBG("Invalid element, can't draw it");
        return -1;
    }
    auto bb = mathd_get_bb(m);
    auto expr_tl = pos + ImVec2(0, -bb.h);
    auto expr_origin = expr_tl + ImVec2(-m->min_x, -m->min_y);
    if (m->cbk)
        m->cbk(m, pos);
    for (auto &obj : m->objs) {
        auto obj_center = expr_origin + obj.off + ImVec2(0, m->acnhor_y);
        switch (obj.type) {
            case MATHD_OBJ_SUBEXPR: {
                auto subexpr_bb = mathd_get_bb(obj.expr);
                auto subexpr_pos = ImVec2(-subexpr_bb.w, 0) + obj_center;
                ASSERT_FN(mathd_draw(subexpr_pos, obj.expr));
                if (mathd_draw_boxes) {
                    mathd_draw_bb(obj_center, subexpr_bb, 0xff'00ff00);
                    mathd_draw_bb(obj_center, obj.bb, 0xff'00aa00);
                }
            } break;
            case MATHD_OBJ_SYMB: {
                auto ssz = char_get_sz(obj.sym);
                auto symb_bb = mathd_char_bb(obj.sym);
                auto symb_pos = ImVec2(-symb_bb.w, +symb_bb.h) - ssz.bl + obj_center;
                char_draw(symb_pos, obj.sym);
                if (mathd_draw_boxes) {
                    mathd_draw_bb(obj_center, symb_bb, 0xff'ff0000);
                    mathd_draw_bb(obj_center, obj.bb, 0xff'aa0000);
                }
            } break;
            case MATHD_OBJ_EMPTY: {
                if (mathd_draw_boxes) {
                    mathd_draw_bb(obj_center, obj.bb, 0xff'0000ff); /* bgr */
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

inline mathd_p mathd_empty() {
    auto m = mathd_make(mathd_t {
        .type = MATHD_TYPE_EMPTY_BOX,
        .anchor_id = 0,
        .cmds = {
            { .type = MATHD_EMPTY, .spawn_id = 0, .bb = {0, 0} },
        },
    });
    if (mathd_init(m, {}) < 0) {
        DBG("Failed to init object");
        return nullptr;
    }
    return m;
}

inline mathd_p mathd_symbol(char_t sym) {
    auto m = mathd_make(mathd_t {
        .type = MATHD_TYPE_SYMBOL,
        .anchor_id = 0,
        .cmds = {
            { .type = MATHD_SYM, .spawn_id = 0, .sym = sym },
        },
    });
    if (mathd_init(m, {}) < 0) {
        DBG("Failed to init object");
        return nullptr;
    }
    return m;
}

inline mathd_p mathd_bigop(mathd_p right, mathd_p above, mathd_p bellow, char_t bigop) {
    float distancer = MATHD_DISTANCER_BIGO * char_get_lvl_mul((char_font_lvl_e)bigop.flvl);
    auto m = mathd_make(mathd_t {
        .type = MATHD_TYPE_BIGOP,
        .anchor_id = 0,
        .cmds = {
            { .type = MATHD_SYM, .spawn_id = 0, .sym = bigop },
            { .type = MATHD_EMPTY, .spawn_id = 5, .bb = {distancer, 0}},
            { .type = MATHD_EMPTY, .spawn_id = 6, .bb = {distancer, 0}},
            { .type = MATHD_EXPR, .param = 1, .spawn_id = 2 },
            { .type = MATHD_EXPR, .param = 2, .spawn_id = 3 },
            { .type = MATHD_ABOVE, .src_id = 0, .dst_id = 5 },
            { .type = MATHD_ABOVE, .src_id = 5, .dst_id = 2 },
            { .type = MATHD_BELLOW, .src_id = 0, .dst_id = 6 },
            { .type = MATHD_BELLOW, .src_id = 6, .dst_id = 3 },
            { .type = MATHD_MERGE, .spawn_id = 4 },
            { .type = MATHD_EXPR, .param = 0, .spawn_id = 1 },
            { .type = MATHD_RIGHT, .src_id = 4, .dst_id = 1 },
        },
    });
    if (mathd_init(m, {right, above, bellow}) < 0) {
        DBG("Failed to init object");
        return nullptr;
    }
    return m;
};

inline mathd_p mathd_frac(mathd_p above, mathd_p bellow, char_t divline) {
    /* get the bounding boxes of the elements */
    float distancer = MATHD_DISTANCER * char_get_lvl_mul((char_font_lvl_e)divline.flvl);

    auto bb_above = mathd_get_bb(above);
    auto bb_below = mathd_get_bb(bellow);
    auto bb_sym = mathd_char_bb(divline);

    /* get the number of frac lines to place */
    int cnt = std::ceil(std::max(bb_above.w, bb_below.w) / bb_sym.w);
    DBG("frac: above: %f bellow: %f sym: %f cnt: %d",
            bb_above.w, bb_below.w, bb_sym.w, cnt);
    if (cnt % 2 == 0)
        cnt++;

    /* create the initial object */
    auto m = mathd_make(mathd_t{
        .type = MATHD_TYPE_FRAC,
        .cmds = {},
    });

    /* create the center line */
    for (int i = 0; i < cnt; i++) {
        m->cmds.push_back({.type = MATHD_SYM, .spawn_id = i, .sym = divline });
    }
    for (int i = 1; i < cnt; i++) {
        m->cmds.push_back({.type = MATHD_RIGHT, .src_id = i-1, .dst_id = i});
    }
    int center = cnt / 2;
    m->anchor_id = center,

    /* add the two elements  */
    m->cmds.push_back({.type = MATHD_EXPR, .param = 0, .spawn_id = cnt  });
    m->cmds.push_back({.type = MATHD_EXPR, .param = 1, .spawn_id = cnt+1});

    /* put the two elements above and bellow the center line */
    m->cmds.push_back({.type = MATHD_EMPTY, .spawn_id = cnt+2, .bb = {distancer, 0}});
    m->cmds.push_back({.type = MATHD_EMPTY, .spawn_id = cnt+3, .bb = {distancer, 0}});
    m->cmds.push_back({.type = MATHD_ABOVE, .src_id = center, .dst_id = cnt+2});
    m->cmds.push_back({.type = MATHD_ABOVE, .src_id = cnt+2, .dst_id = cnt});
    m->cmds.push_back({.type = MATHD_BELLOW, .src_id = center, .dst_id = cnt+3});
    m->cmds.push_back({.type = MATHD_BELLOW, .src_id = cnt+3, .dst_id = cnt+1});

    /* place a filler for the element that is smaller, such that the center line will remain in the
    center */
    // mathd_cmd_e fill_type = MATHD_BELLOW;
    // int fill_id = cnt+1;
    // if (bb_above.h < bb_below.h) {
    //     fill_id = cnt;
    //     fill_type = MATHD_ABOVE;
    // }
    // float fill_sz = (std::max(bb_above.h, bb_below.h) - std::min(bb_above.h, bb_below.h));
    // m->cmds.push_back({.type = MATHD_EMPTY, .spawn_id = cnt+4, .bb = {fill_sz, 0}});
    // m->cmds.push_back({.type = fill_type, .src_id = fill_id, .dst_id = cnt+4});

    if (mathd_init(m, {above, bellow}) < 0) {
        DBG("Failed to init object");
        return nullptr;
    }
    return m;
}

inline mathd_p mathd_supsub(mathd_p base, mathd_p sup, mathd_p sub) {
    auto m = mathd_make(mathd_t {
        .type = MATHD_TYPE_SUPSUB,
        .anchor_id = 0,
        .cmds = {
            { .type = MATHD_EXPR, .param = 0, .spawn_id = 0 },
            { .type = MATHD_EXPR, .param = 1, .spawn_id = 1 },
            { .type = MATHD_EXPR, .param = 2, .spawn_id = 2 },
            { .type = MATHD_SUP, .src_id = 0, .dst_id = 1},
            { .type = MATHD_SUB, .src_id = 0, .dst_id = 2},
        },
    });
    if (mathd_init(m, {base, sup, sub}) < 0) {
        DBG("Failed to init object");
        return nullptr;
    }
    return m;
}

inline mathd_p mathd_bracket(mathd_p expr, mathd_bracket_t bsym) {
    /* TODO: fix brackets to auto-resize */
    auto m = mathd_make(mathd_t {
        .type = MATHD_TYPE_BRACKET,
        .anchor_id = 0,
        .cmds = {
            { .type = MATHD_EXPR, .param = 0, .spawn_id = 0 },
            { .type = MATHD_SYM, .spawn_id = 1, .sym = bsym.left[0] },
            { .type = MATHD_SYM, .spawn_id = 2, .sym = bsym.right[0] },
            { .type = MATHD_LEFT, .src_id = 0, .dst_id = 1 },
            { .type = MATHD_RIGHT, .src_id = 0, .dst_id = 2 },
        },
    });
    if (mathd_init(m, {expr}) < 0) {
        DBG("Failed to init object");
        return nullptr;
    }
    return m;
}

inline mathd_p mathd_unarexpr(char_t op, mathd_p b) {
    const float distancer = MATHD_DISTANCER * char_get_lvl_mul((char_font_lvl_e)op.flvl);
    auto m = mathd_make(mathd_t {
        .type = MATHD_TYPE_BRACKET,
        .anchor_id = 0,
        .cmds = {
            { .type = MATHD_EXPR, .param = 0, .spawn_id = 0 },
            { .type = MATHD_SYM, .spawn_id = 1, .sym = op },
            { .type = MATHD_EMPTY, .spawn_id = 2, .bb = {0, distancer} },
            { .type = MATHD_RIGHT, .src_id = 1, .dst_id = 2 },
            { .type = MATHD_RIGHT, .src_id = 2, .dst_id = 0 },
        },
    });
    if (mathd_init(m, {b}) < 0) {
        DBG("Failed to init object");
        return nullptr;
    }
    return m;
}

inline mathd_p mathd_binexpr(mathd_p a, char_t op, mathd_p b) {
    float distancer = MATHD_DISTANCER * char_get_lvl_mul((char_font_lvl_e)op.flvl);
    auto m = mathd_make(mathd_t {
        .type = MATHD_TYPE_BRACKET,
        .anchor_id = 2,
        .cmds = {
            { .type = MATHD_EXPR, .param = 0, .spawn_id = 0 },
            { .type = MATHD_EXPR, .param = 1, .spawn_id = 1 },
            { .type = MATHD_SYM, .spawn_id = 2, .sym = op },
            { .type = MATHD_EMPTY, .spawn_id = 3, .bb = {0, distancer} },
            { .type = MATHD_EMPTY, .spawn_id = 4, .bb = {0, distancer} },
            { .type = MATHD_LEFT, .src_id = 2, .dst_id = 3 },
            { .type = MATHD_LEFT, .src_id = 3, .dst_id = 0 },
            { .type = MATHD_RIGHT, .src_id = 2, .dst_id = 4 },
            { .type = MATHD_RIGHT, .src_id = 4, .dst_id = 1 },
        },
    });
    if (mathd_init(m, {a, b}) < 0) {
        DBG("Failed to init object");
        return nullptr;
    }
    return m;
}

inline mathd_p mathd_merge_h(mathd_p l, mathd_p r) {
    auto m = mathd_make(mathd_t {
        .type = MATHD_TYPE_BRACKET,
        .anchor_id = 2,
        .cmds = {
            { .type = MATHD_EXPR, .param = 0, .spawn_id = 0 },
            { .type = MATHD_EXPR, .param = 1, .spawn_id = 1 },
            { .type = MATHD_EMPTY, .spawn_id = 2, .bb = {}},
            { .type = MATHD_RIGHT, .src_id = 0, .dst_id = 2 },
            { .type = MATHD_RIGHT, .src_id = 2, .dst_id = 1 },
        },
    });
    if (mathd_init(m, {l, r}) < 0) {
        DBG("Failed to init object");
        return nullptr;
    }
    return m;
}

inline mathd_p mathd_merge_v(mathd_p u, mathd_p d) {
    auto m = mathd_make(mathd_t {
        .type = MATHD_TYPE_BRACKET,
        .anchor_id = 2,
        .cmds = {
            { .type = MATHD_EXPR, .param = 0, .spawn_id = 0 },
            { .type = MATHD_EXPR, .param = 1, .spawn_id = 1 },
            { .type = MATHD_EMPTY, .spawn_id = 2, .bb = {}},
            { .type = MATHD_BELLOW, .src_id = 0, .dst_id = 2 },
            { .type = MATHD_BELLOW, .src_id = 2, .dst_id = 1 },
        },
    });
    if (mathd_init(m, {u, d}) < 0) {
        DBG("Failed to init object");
        return nullptr;
    }
    return m;
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

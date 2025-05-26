#ifndef FORMULAS_H
#define FORMULAS_H

#include "mathd.h"

struct formula_box_t;
using formula_box_p = std::shared_ptr<formula_box_t>;

inline int formulas_init();
inline formula_box_p formulas_create();

/* IMPLEMENTATION
 * =================================================================================================
 */

inline int formulas_init() {
    return 0;
}

inline formula_box_p formulas_create() {
    return std::make_shared<formula_box_t>();
}

struct formula_box_t : public cbox_i {
    mathd_p formula;

    formula_box_t() {
        char_font_lvl_e font0 = FONT_LVL_SUB0;
        char_font_lvl_e font1 = FONT_LVL_SUB2;
        char_font_lvl_e font2 = FONT_LVL_SUB4;

        auto empty = mathd_empty(0, 0);
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
        formula = frac2;
    }

    void update() override {
    }

    std::pair<float, float> draw_area(float width_limit, float height_limit) override {
        if (formula) {
            auto bb = mathd_get_bb(formula);
            return {bb.br.x - bb.tl.x, bb.br.y - bb.tl.y};
        }
        return {0.0f, 0.0f};
    }

    void draw(ImVec2 pos, float width_limit, float height_limit) override {
        if (formula) {
            auto bb = mathd_get_bb(formula);
            mathd_draw(pos, formula);
        }
    }
};

#endif

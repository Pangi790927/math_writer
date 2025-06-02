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

        auto empty      = mathd_empty(100, 200);
        auto eset       = mathd_symbol(mathd_convert(MATHD_hash, font2));
        auto sym_a      = mathd_symbol(mathd_convert(gascii('a'), font0));
        auto sym_e      = mathd_symbol(mathd_convert(gascii('e'), font0));
        auto sym_a_1    = mathd_symbol(mathd_convert(gascii('a'), font1));
        auto sym_e_1    = mathd_symbol(mathd_convert(gascii('e'), font1));
        auto sym_B      = mathd_symbol(mathd_convert(gascii('B'), font0));
        auto sym_B_1    = mathd_symbol(mathd_convert(gascii('B'), font1));
        auto sym_h_1    = mathd_symbol(mathd_convert(gascii('h'), font1));
        auto sym_g      = mathd_symbol(mathd_convert(gascii('g'), font0));
        auto sym_g_1    = mathd_symbol(mathd_convert(gascii('g'), font1));
        auto sym_a_2    = mathd_symbol(mathd_convert(gascii('a'), font2));
        auto sym_n_1    = mathd_symbol(mathd_convert(gascii('n'), font1));
        auto plus       = mathd_convert(MATHD_plus, font0);
        auto plus_1     = mathd_convert(MATHD_plus, font1);
        auto sum        = mathd_convert(MATHD_sum, font0);
        auto sum_1      = mathd_convert(MATHD_sum, font1);
        auto minus      = mathd_convert(MATHD_minus, font0);
        auto minus_1    = mathd_convert(MATHD_minus, font1);
        auto integral   = mathd_convert(MATHD_integral, font0);
        auto integral_1 = mathd_convert(MATHD_integral, font1);
        auto equal      = mathd_convert(MATHD_equal, font0);
        auto equal_1    = mathd_convert(MATHD_equal, font1);
        auto plus1      = mathd_convert(MATHD_plus, font1);
        auto binar      = mathd_binexpr(sym_g, plus, sym_B);
        auto binar2     = mathd_binexpr(binar, plus, sym_a);
        auto binar_1    = mathd_binexpr(sym_g_1, plus_1, sym_h_1);
        auto integ_1    = mathd_bigop(sym_a, sym_e_1, binar_1, integral); /* keep the bigops symbols one tier higher */
        auto int_sym    = mathd_symbol(integral, false);
        auto unar       = mathd_unarexpr(minus, sym_e);
        auto unar_1     = mathd_unarexpr(minus_1, sym_e_1);
        auto n_eq_1     = mathd_binexpr(sym_n_1, equal_1, sym_e_1);
        auto sum_eq     = mathd_bigop(integ_1, unar_1, n_eq_1, sum);
        auto sym_exp    = mathd_supsub(sym_e, sym_a_1, nullptr);
        auto sym_sub    = mathd_supsub(sym_e, nullptr, sym_a_1);
        auto sym_sub_exp= mathd_supsub(sym_e, integ_1, sym_n_1);
        auto sqr_brack  = mathd_convert(mathd_brack_square, font0);
        auto crl_brack  = mathd_convert(mathd_brack_curly, font0);
        auto rnd_brack  = mathd_convert(mathd_brack_round, font0);
        auto sqr_brack_1= mathd_convert(mathd_brack_square, font1);
        auto crl_brack_1= mathd_convert(mathd_brack_curly, font1);
        auto rnd_brack_1= mathd_convert(mathd_brack_round, font1);
        auto sqr_brack_2= mathd_convert(mathd_brack_square, font2);
        auto crl_brack_2= mathd_convert(mathd_brack_curly, font2);
        auto rnd_brack_2= mathd_convert(mathd_brack_round, font2);
        auto brack      = mathd_bracket(empty, crl_brack);
        auto brack1     = mathd_bracket(brack, sqr_brack);
        auto brack2     = mathd_bracket(brack1, rnd_brack);
        auto brack_1    = mathd_bracket(brack2, crl_brack_1);
        auto brack1_1   = mathd_bracket(brack_1, sqr_brack_1);
        auto brack2_1   = mathd_bracket(brack1_1, rnd_brack_1);
        auto brack_2    = mathd_bracket(brack2_1, crl_brack_2);
        auto brack1_2   = mathd_bracket(brack_2, sqr_brack_2);
        auto brack2_2   = mathd_bracket(brack1_2, rnd_brack_2);
        // auto binar2 = mathd_binexpr(binar, mathd_convert(MATHD_plus, font0), sum);
        // auto frac = mathd_frac(sym_exp, binar2, mathd_convert(MATHD_hline_basic, font0));
        // auto binar3 = mathd_binexpr(frac, mathd_convert(MATHD_minus, font0), sym_exp);
        // auto binar4 = mathd_binexpr(binar3, mathd_convert(MATHD_minus, font0), sym_e);
        // auto brack = mathd_bracket(binar3, mathd_convert(mathd_brack_square, font0));
        // auto frac2 = mathd_frac(sym_exp, binar4, mathd_convert(MATHD_hline_basic, font0));
        formula = brack2_2;
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
        mathd_draw(pos, formula);
    }
};

#endif

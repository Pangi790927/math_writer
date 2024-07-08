#ifndef MATHE_H
#define MATHE_H

#include <memory>
#include "fonts.h"

enum mathe_e : int {
	MATHE_INTEGRAL,
};

enum mathe_anchor_e : int {
	MATHE_ABOVE,
	MATHE_BELLOW,
	MATHE_LEFT,
	MATHE_RIGHT,

	MATHE_SUP,
	MATHE_SUB,

	MATHE_SYM,
	MATHE_MERGE,
};

struct mathe_t;

using mathe_p = std::shared_ptr<mathe_t>;

template <typename ...Args>
mathe_p mathe_make(Args&&... args);

void mathe_draw(ImVec2 pos, mathe_p m);

mathe_p mathe_integral(mathe_p right, mathe_p above, mathe_p bellow);

/* IMPLEMENTATION
================================================================================================= */

/* links two math expresions in some way inside an bigger expresion, for example making them the
same size */
struct mathe_link_t {
	mathe_p a, b;
};

struct mathe_anchor_t {
	mathe_anchor_e type;
	int sym_a = -1;
	int sub_a = -1;
	int sym_b = -1;
	int sub_b = -1;
	ImVec2 dirpos;
};

struct mathe_t {
	mathe_e type;
	std::vector<symbol_t> syms;				/* some math expressions are made only of symbols */
	std::vector<mathe_p> sub_me;			/*  */
	std::vector<mathe_link_t> links;
	std::vector<mathe_anchor_t> anchors;
};


struct mathe_t {
	mathe_e type;
	std::vector<std::pair<ImVec2, symbol_t>> syms;
	std::vector<mathe_anchor_t> anchors;
};

inline ImRect mathe_get_bb(mathe_p m) {
	for (auto &[t, e, s] : m->anchors) {
		if (t == MATHE_SYM) {

		}
		else if (t == MATHE_MERGE) {

		}
	}
}

inline ImRect mathe_get_bb(mathe_p m) {
	for (auto &[t, e] : m->anchors) {
		mathe_get_bb(e);
	}
	for (auto &[relpos, sym] : m->syms) {
    	auto ssz = symbol_get_sz(sym);
	}
}

inline void mathe_draw(ImVec2 pos, mathe_p m) {
    ImDrawList* draw_list = ImGui::GetWindowDrawList();
    draw_list->AddLine(ImVec2(0, 0), pos, 0xff'00ff00, 1);

	auto old_toggle = symbol_toggle_bb(true);
	for (auto &[t, e] : m->anchors) {
		// mathe_draw(pos + )
	}
	for (auto &[relpos, sym] : m->syms) {
		symbol_draw(pos + relpos, sym);
	}
	symbol_toggle_bb(old_toggle);
}

inline mathe_p mathe_integral(mathe_p right, mathe_p above, mathe_p bellow) {
	symbol_t integral_symbol = { .code = 0x5A, .font_lvl = FONT_LVL_SUB0, .font_sub = FONT_MATH_EX };
	return mathe_make(mathe_t{
		.type = MATHE_INTEGRAL,
		.syms = {
			{ ImVec2(0, 0), integral_symbol }
		},
		.anchors = {
			{ .type = MATHE_ABOVE,  .element = above  },
			{ .type = MATHE_BELLOW, .element = bellow },
			{ .type = MATHE_RIGHT,  .element = right  },
		},
	});
};

template <typename ...Args>
inline mathe_p mathe_make(Args&&... args) {
	return std::make_shared<mathe_t>(std::forward<Args>(args)...);
}


#endif

// // ok pharanteses: () \xB5\xB6 [] \xB7\xB8 {} \xBD\xBE
//         // \x58 - sum
//         // \x59 - prod
//         // \x5B - mass union
//         // \x5C - mass intersect
//         // \x5A - integral
//         // \x49 - circle integral
//         // all from FONT_MATH_EX
//         // all of them need to be centered to be used
//         const char str2[] =
//                 "\xC3\xB5\xB3\xA1\xA2\xB4\xB6\x21"
//                 "\x22\xB7\x68\xA3\xA4\x69\xB8\x23"
//                 "\x28\xBD\x6E\xA9\xAA\x6F\xBE\x29"
//                 "\x58\x59\x5B\x5C\x5A\x49";

//         float off = 0;
//         // const char str2[] = "\xAE\xAF\xB0\xB1\xB2\xB3\xB4\xB5\xB6\xB7\xB8\xB9\xBA\xBB\xBC\xBD\xBE\xBF";
//         for (auto c : str2) {
//             uint8_t code = c;
//             // DBG("code: 0x%x sym: [%c]", code, c);
//             if (!c)
//                 break;
//             auto sym = symbol_t{ .code = code, .font_lvl = FONT_LVL_SUB0, .font_sub = FONT_MATH_EX };
//             symbol_draw(ImVec2(100 + off, 100), sym);
//             off += symbol_get_sz(sym).adv;
//         }
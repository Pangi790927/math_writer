#ifndef DRAW_COMPOSER_H
#define DRAW_COMPOSER_H

#include "virt_composer.h"
#include "perf_composer.h"
#include "imgui_impl_glfw.h"
#include "imgui_impl_opengl3.h"
#include "imgui_internal.h"

/*! A bit of a description of what this file will hold. Not sure if I want a single composer to
 * hold all that I will describe, but here we go: 
 * - Symbols, ie all from chars.h
 * - Content boxes, ie content.h
 * 
 * Now I'm not really sure where comments.h comes in, but I am sure that all the math drawing stuff
 * will stay inside lua scripts AND the drawing will be constructed above the ast_composer objects.
 * As such, this composer will have to know about the ast_composer.h
 * 
 * It is not clear to me if c++ or lua will hold the content (serialized formulas and pure text).
 * But it is clear that I want to be able to do ctrl+z and ctrl+shift+z and I must make sure to
 * create the actions that the user can take with this in mind
 * 
 * Some other observations:
 * - I need some way to write formulas and wander around in them
 * - math_drawing.h -- This will be a combination between this and lua scripts describing exactly how
 *                     to draw formulas
 * - math_*         -- The rest of math_ stuff are now deprecated
 * - defines.h      -- Not sure if I keep it, but this practically will be a variable definition
 *                     from now on
 * - comments.h     -- pure text, need to figure out
 * 
 */

namespace char_draw_composer
{

struct char_t {
    uint32_t size = 0;
    uint32_t code = 0;
};

}; /* char_draw_composer */

namespace virt_composer {

template <ssize_t index>
struct luaw_param_t<ImVec2, index> {
    ImVec2 luaw_single_param(lua_State *L);
};

template <ssize_t index>
struct luaw_param_t<char_draw_composer::char_t, index> {
    char_draw_composer::char_t luaw_single_param(lua_State *L);
};

} /* virt_composer */

namespace char_draw_composer
{

namespace vc = virt_composer;
namespace charc = char_draw_composer;

VIRT_COMPOSER_REGISTER_TYPE(CHARC_TYPE_SUBFONT);
VIRT_COMPOSER_REGISTER_TYPE(CHARC_TYPE_FONT);
VIRT_COMPOSER_REGISTER_TYPE(CHARC_TYPE_FONTSET);

struct char_bb_t {
    ImVec2 a_min;
    ImVec2 a_max;
};

struct char_sz_t {
    float adv = 0.0f;
    ImVec2 bl;
    ImVec2 tr;
};

} /* char_draw_composer */

namespace virt_composer {

/*! Return-direction (C++ -> Lua) counterparts of the param-direction specializations above:
 * pushed as a plain {x=, y=} table / {adv=, bl={x=,y=}, tr={x=,y=}} table respectively. */
template <>
struct luaw_returner_t<ImVec2> {
    void luaw_ret_push(lua_State *L, ImVec2 v);
};

template <>
struct luaw_returner_t<char_draw_composer::char_sz_t> {
    void luaw_ret_push(lua_State *L, const char_draw_composer::char_sz_t& sz);
};

} /* virt_composer */

namespace char_draw_composer {

struct fontset_t : public vc::object_t {
    struct font_loc_t {
        uint32_t font;
        uint32_t fcode;

        /*! Vertical correction for THIS glyph, as a fraction of the font size (so it scales with
         * the size table and with zoom on its own - a pixel count would only be right at one size).
         * Positive moves the glyph DOWN, y growing downward as everywhere else here.
         *
         * It exists because the fonts are TTF conversions that lost TeX's height/depth split: every
         * cmex10 glyph reports the same flattened ascent, with no depth at all, so the big
         * operators come out sitting entirely ABOVE the baseline instead of centred on the math
         * axis the way TeX sets them. Measured 2026-09-06: \sum's ink ended a whole 8.5 units above
         * the baseline it should have been straddling.
         *
         * A per-glyph correction to the FONT's own metrics, so it belongs with the font location
         * rather than in the layout above it - same argument as char.lua's size_delta_by_desc,
         * which corrects the other half of the same lossy conversion. Both are set from char.lua,
         * which is where the catalog of what each glyph IS already lives. */
        float y_off_em = 0.f;

        /*! Advance width for THIS glyph, as a fraction of the font size, REPLACING the font's own.
         * Negative means "use the font's", which is every glyph but a handful.
         *
         * An override rather than an offset (unlike y_off_em) because what it expresses is not a
         * nudge but a fact the font lost: TeX gives \not a width of exactly ZERO so the slash is
         * overprinted on whatever follows it, which is how it builds \ne, \notin and the rest. This
         * TTF gave that glyph an ordinary full-width advance, so the slash landed BESIDE the equals
         * sign instead of through it. Setting it to 0 restores the composition TeX does.
         *
         * Measured 2026-09-06: cmsy 0x36 came back with adv 27.97 at the default level, identical
         * to the "=" it is meant to overprint. */
        float adv_em = -1.f;
    };

    /*! Code of letter a inside the subfont, or more precisely, some letter that stays above the
     * write line and is a `small` letter (as oposed to `tall` letters such as "tlikjhf")
     * It's dimensions are used internally assuming those properties. */
    uint32_t m_a_code; 

    std::vector<std::string> font_paths;
    std::vector<float> font_sizes;

    std::map<int, font_loc_t> code_to_font_loc;
    std::vector<std::vector<std::shared_ptr<ImFont>>> fonts;

    fontset_t(vc::object_t::Private priv) : vc::object_t(priv) {}
    virtual ~fontset_t() {}

    static vc::object_type_e type_id_static() { return CHARC_TYPE_FONTSET; }
    virtual vc::object_type_e type_id() const override { return CHARC_TYPE_FONTSET; }

    static vc::ref_t<fontset_t> create(const std::vector<std::string>& font_paths,
            const std::vector<float>& font_sizes, int a_code)
    {
        auto ret = std::make_shared<fontset_t>(vc::object_t::Private{type_id_static()});
        ret->font_paths = font_paths;
        ret->font_sizes = font_sizes;
        ret->m_a_code = a_code;
        if (ret->init() != vc::VC_ERROR_OK)
            throw vc::except_t(sformat("Failed to load fontset"));
        return ret;
    }

    inline virtual std::string to_string() const override {
        /* TODO: maybe describe more? */
        return std::format("charc::fontset_t[{}]", (void *)this);
    }

    vc::ret_t init() {
        ImGuiIO& io = ImGui::GetIO();
        fonts = std::vector<std::vector<std::shared_ptr<ImFont>>>(font_sizes.size());

        for (size_t sz_id = 0; sz_id < font_sizes.size(); sz_id++) {
            fonts[sz_id] = std::vector<std::shared_ptr<ImFont>>(font_paths.size());

            for (size_t font_id = 0; font_id < font_paths.size(); font_id++) {
                auto font = io.Fonts->AddFontFromFileTTF(
                        font_paths[font_id].c_str(), font_sizes[sz_id]);
                if (!font) {
                    fonts = std::vector<std::vector<std::shared_ptr<ImFont>>>();
                    DBG("Failed to load font: %s of font size: %f",
                            font_paths[font_id].c_str(), font_sizes[sz_id]);
                    return vc::VC_ERROR_GENERIC;
                }
                fonts[sz_id][font_id] = std::shared_ptr<ImFont>(font, [](ImFont *font){
                    ImGuiIO& io = ImGui::GetIO();
                    io.Fonts->RemoveFont(font);
                });
            }
        }

        return vc::VC_ERROR_OK;
    }

    /*! Both corrections default to "none", so a glyph that needs neither registers as it always did. */
    void register_code(uint32_t code, uint32_t font, uint32_t fcode, float y_off_em = 0.f,
            float adv_em = -1.f)
    {
        code_to_font_loc[code] = font_loc_t{ .font = font, .fcode = fcode,
                .y_off_em = y_off_em, .adv_em = adv_em };
    }

    /*! The one place y_off_em turns into pixels. Both char_get_sz() (metrics) and char_draw() (ink)
     * have to apply it, and they must apply the SAME value - char_draw doesn't position through the
     * metrics, it hands `pos` straight to RenderChar, so a correction applied to only one of them
     * would slide the glyph out of its own bounding box. */
    float char_y_off(char_t c) {
        return code_to_font_loc[c.code].y_off_em * font_sizes[c.size-1];
    }

    char_sz_t char_get_sz(char_t c) {
        /* Instrumented for its COUNT above all: this is the one call every glyph metric in the
        whole app funnels through, it memoizes nothing, and cursor_metrics()/min_extent() re-query
        it on every single call. The timer's own overhead is significant relative to one lookup, so
        read the count as exact and the milliseconds as an upper bound. */
        PROF_SCOPE("cpp.char_get_sz");
        check_char(c);
        auto glyph = fonts[c.size-1][code_to_font_loc[c.code].font-1]
                ->GetFontBaked(font_sizes[c.size-1])->FindGlyphNoFallback(code_to_font_loc[c.code].fcode);
        /* Applied here rather than at the call sites because this is the single funnel every glyph
        metric in the app goes through (see the PROF_SCOPE note above) - so bb, layout, cursor
        height and mexpr_bigop's limit placement all see the corrected position without any of them
        knowing the correction exists. char_draw() applies the identical shift to the ink. */
        float dy = char_y_off(c);
        /* The advance is REPLACED when an override is set, not adjusted - see font_loc_t::adv_em.
        The ink (bl/tr) is deliberately left alone: a zero-width \not still has to DRAW its slash,
        it just must not push the next glyph along. */
        const auto &loc = code_to_font_loc[c.code];
        float adv = (loc.adv_em >= 0.f) ? loc.adv_em * font_sizes[c.size-1] : glyph->AdvanceX;
        return {
            .adv = adv,
            .bl = ImVec2(glyph->X0, glyph->Y1 + dy),
            .tr = ImVec2(glyph->X1, glyph->Y0 + dy),
        };
    }

    char_bb_t char_get_bb(char_t c, ImVec2 pos = ImVec2(0, 0)) {
        auto ssz = char_get_sz(c);

        ImVec2 bl = ssz.bl + pos;
        ImVec2 tr = ssz.tr + pos;

        return {
            .a_min = ImVec2(std::min(bl.x, tr.x), std::min(bl.y, tr.y)),
            .a_max = ImVec2(std::max(bl.x, tr.x), std::max(bl.y, tr.y)),
        };
    }

    void char_draw(char_t c, ImVec2 pos, uint32_t color, bool draw_bb, uint32_t bb_color) {
        PROF_SCOPE("cpp.char_draw");
        auto ssz = char_get_sz(c);

        ImDrawList* draw_list = ImGui::GetWindowDrawList();
        ImGuiWindow* window = ImGui::GetCurrentWindow();
        if (window->SkipItems)
            return ;

        ImVec2 bl = ssz.bl + pos;
        ImVec2 tr = ssz.tr + pos;

        /* OBS: RenderChar is the only method that works, for unknown reasons, maybe I can
        fix it?(in imgui). For now the thing will be made out of raw drawing */
        auto font = fonts[c.size-1][code_to_font_loc[c.code].font-1];
        ImGui::PushFont(font.get());
        if (draw_bb) {
            draw_list->AddLine(ImVec2(bl.x, bl.y), ImVec2(tr.x, bl.y), bb_color, 1);
            draw_list->AddLine(ImVec2(tr.x, bl.y), ImVec2(tr.x, tr.y), bb_color, 1);
            draw_list->AddLine(ImVec2(tr.x, tr.y), ImVec2(bl.x, tr.y), bb_color, 1);
            draw_list->AddLine(ImVec2(bl.x, tr.y), ImVec2(bl.x, bl.y), bb_color, 1);
        }
        /* The same shift char_get_sz() already baked into bl/tr above - RenderChar takes `pos`
        directly and never consults the metrics, so the ink has to be moved on its own or it would
        part company with the box that was measured for it. */
        font->RenderChar(draw_list, font_sizes[c.size-1], ImVec2(pos.x, pos.y + char_y_off(c)),
                color, code_to_font_loc[c.code].fcode);
        ImGui::PopFont();
    }

private:
    void check_char(char_t c) {
        if (c.size <= 0 || c.size > fonts.size())
            throw vc::except_t(std::format("char size invalid: {} vs {}", c.size, fonts.size()));
        if (!has(code_to_font_loc, c.code))
            throw vc::except_t(std::format("char code not known: {}", c.code));
        if (code_to_font_loc[c.code].font <= 0 || code_to_font_loc[c.code].font > font_paths.size())
            throw vc::except_t(std::format("invalid font loc: {}", code_to_font_loc[c.code].font));
    }
};

inline int register_meta(vc::virt_state_t *vs) {
    DBG_SCOPE();

    VC_REGISTER_MEMBER_OBJECT(vs, fontset_t, m_a_code);

    /* 5 params, not 3: the trailing y_off_em/adv_em are defaulted in C++ but the binding takes the
    signature it is GIVEN, so a short registration would silently drop the arguments Lua passes
    (which is exactly what happened first time round - char.lua passed the offset, the glyphs never
    moved, and nothing errored). char.lua always passes all five. */
    VC_REGISTER_MEMBER_FUNCTION(vs, fontset_t, register_code,
            uint32_t, uint32_t, uint32_t, float, float);
    VC_REGISTER_MEMBER_FUNCTION(vs, fontset_t, char_draw, char_t, ImVec2, uint32_t, bool, uint32_t);
    VC_REGISTER_MEMBER_FUNCTION(vs, fontset_t, char_get_sz, char_t);

    int ret = add_named_builder_callback(vs,
        "charc::fontset_t",
        [](vc::virt_state_t *vs, const std::string& node_name, fkyaml::node& node)
            -> co::task<vc::ref_t<vc::object_t>>
        {
            std::vector<std::string> font_paths;
            std::vector<float> font_sizes;
            for (auto& subnode : node["m_font_paths"])
                font_paths.push_back(subnode.as_str());
            for (auto& subnode : node["m_font_sizes"])
                font_sizes.push_back(subnode.as_float());
            int a_code = co_await vc::resolve_int(vs, node["m_a_code"]);
            auto obj = fontset_t::create(font_paths, font_sizes, a_code);
            mark_dependency_solved(vs, node_name, obj->to_related<vc::object_t>());
            co_return obj->to_related<vc::object_t>();
        }
    );
    ASSERT_FN(ret);

    return vc::VC_ERROR_OK;
}

} /* char_draw_composer */

namespace virt_composer
{
    
template <ssize_t index>
inline ImVec2 luaw_param_t<ImVec2, index>::luaw_single_param(lua_State *L) {
    ImVec2 ret;
    if (lua_isnil(L, index))
        return ret;
    lua_getfield(L, index, "x");
    ret.x = lua_tonumber(L, -1);
    lua_pop(L, 1);
    lua_getfield(L, index, "y");
    ret.y = lua_tonumber(L, -1);
    lua_pop(L, 1);
    return ret;
}

template <ssize_t index>
inline char_draw_composer::char_t
luaw_param_t<char_draw_composer::char_t, index>::luaw_single_param(lua_State *L)
{
    char_draw_composer::char_t ret;
    if (lua_isnil(L, index))
        return ret;
    lua_getfield(L, index, "code");
    ret.code = lua_tonumber(L, -1);
    lua_pop(L, 1);
    lua_getfield(L, index, "size");
    ret.size = lua_tonumber(L, -1);
    lua_pop(L, 1);
    return ret;
}

inline void luaw_returner_t<ImVec2>::luaw_ret_push(lua_State *L, ImVec2 v) {
    lua_createtable(L, 0, 2);
    lua_pushnumber(L, v.x);
    lua_setfield(L, -2, "x");
    lua_pushnumber(L, v.y);
    lua_setfield(L, -2, "y");
}

inline void luaw_returner_t<char_draw_composer::char_sz_t>::luaw_ret_push(
        lua_State *L, const char_draw_composer::char_sz_t& sz)
{
    lua_createtable(L, 0, 3);
    lua_pushnumber(L, sz.adv);
    lua_setfield(L, -2, "adv");
    luaw_returner_t<ImVec2>{}.luaw_ret_push(L, sz.bl);
    lua_setfield(L, -2, "bl");
    luaw_returner_t<ImVec2>{}.luaw_ret_push(L, sz.tr);
    lua_setfield(L, -2, "tr");
}

}; /* virt_composer */

#endif

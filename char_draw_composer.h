#ifndef DRAW_COMPOSER_H
#define DRAW_COMPOSER_H

#include "virt_composer.h"
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

namespace virt_composer {

template <ssize_t index>
struct luaw_param_t<ImVec2, index> {
    auto luaw_single_param(lua_State *L) {
        ImVec2 ret;
        if (lua_isnil(L, index))
            return ret;
        /* TODO: this table must be filled, of the form { x=float, y=float } */
        return ret;
    }
};

} /* virt_composer */

namespace char_draw_composer
{

namespace vc = virt_composer;
namespace drawc = char_draw_composer;

VIRT_COMPOSER_REGISTER_TYPE(DRAWC_TYPE_SUBFONT);
VIRT_COMPOSER_REGISTER_TYPE(DRAWC_TYPE_FONT);
VIRT_COMPOSER_REGISTER_TYPE(DRAWC_TYPE_FONTSET);

struct char_bb_t {
    ImVec2 a_min;
    ImVec2 a_max;
};

struct char_sz_t {
    float adv = 0.0f;
    ImVec2 bl;
    ImVec2 tr;
};

struct char_t {
    uint32_t font;
    uint32_t code;
};

struct subfont_t : public vc::object_t {
    std::string m_path;
    float m_font_size = 42;

    ImFont* font = nullptr;

    static vc::object_type_e type_id_static() { return DRAWC_TYPE_FONT; }
    virtual vc::object_type_e type_id() const override { return DRAWC_TYPE_FONT; }

    static vc::ref_t<subfont_t> create(std::string path, float font_size) {
        auto ret = std::make_shared<subfont_t>();
        ret->m_path = path;
        ret->m_font_size = font_size;
        if (ret->init() != vc::VC_ERROR_OK)
            throw vc::except_t(sformat("Failed to load font: %s, sz: %f", path.c_str(), font_size));
        return ret;
    }

    inline virtual std::string to_string() const override {
        return std::format("drawc::subfont_t[{}] path: %s sz: %f",
                (void *)this, m_path.c_str(), m_font_size);
    }

    char_sz_t char_get_sz(uint32_t code) {
        auto glyph = font->GetFontBaked(m_font_size)->FindGlyphNoFallback(code);
        return {
            .adv = glyph->AdvanceX,
            .bl = ImVec2(glyph->X0, glyph->Y1),
            .tr = ImVec2(glyph->X1, glyph->Y0),
        };
    }

    char_bb_t char_get_bb(uint32_t code, ImVec2 pos) {
        auto ssz = char_get_sz(code);

        ImVec2 bl = ssz.bl + pos;
        ImVec2 tr = ssz.tr + pos;

        return {
            .a_min = ImVec2(std::min(bl.x, tr.x), std::min(bl.y, tr.y)),
            .a_max = ImVec2(std::max(bl.x, tr.x), std::max(bl.y, tr.y)),
        };
    }

    void char_draw(uint32_t code, ImVec2 pos, uint32_t color, bool draw_bb, uint32_t bb_color) {
        auto ssz = char_get_sz(code);

        ImDrawList* draw_list = ImGui::GetWindowDrawList();
        ImGuiWindow* window = ImGui::GetCurrentWindow();
        if (window->SkipItems)
            return ;

        ImVec2 bl = ssz.bl + pos;
        ImVec2 tr = ssz.tr + pos;

        /* OBS: RenderChar is the only method that works, for unknown reasons, maybe I can
        fix it?(in imgui). For now the thing will be made out of raw drawing */
        ImGui::PushFont(font);
        if (draw_bb) {
            draw_list->AddLine(ImVec2(bl.x, bl.y), ImVec2(tr.x, bl.y), bb_color, 1);
            draw_list->AddLine(ImVec2(tr.x, bl.y), ImVec2(tr.x, tr.y), bb_color, 1);
            draw_list->AddLine(ImVec2(tr.x, tr.y), ImVec2(bl.x, tr.y), bb_color, 1);
            draw_list->AddLine(ImVec2(bl.x, tr.y), ImVec2(bl.x, bl.y), bb_color, 1);
        }
        font->RenderChar(draw_list, m_font_size, pos, color, code);
        ImGui::PopFont();
    }

    virtual vc::ret_t init() override {
        ImGuiIO& io = ImGui::GetIO();
        font = io.Fonts->AddFontFromFileTTF(m_path.c_str(), m_font_size);
        if (!font)
            return vc::VC_ERROR_GENERIC;
        return vc::VC_ERROR_OK;
    }

    virtual vc::ret_t uninit() override {
        ImGuiIO& io = ImGui::GetIO();
        io.Fonts->RemoveFont(font);
        return vc::VC_ERROR_OK;
    }
};

struct font_t : public vc::object_t {
    std::vector<vc::ref_t<subfont_t>> m_subfonts;

    static vc::object_type_e type_id_static() { return DRAWC_TYPE_SUBFONT; }
    virtual vc::object_type_e type_id() const override { return DRAWC_TYPE_SUBFONT; }

    static vc::ref_t<font_t> create(std::vector<vc::ref_t<subfont_t>> subfonts) {
        auto ret = std::make_shared<font_t>();
        ret->m_subfonts = subfonts;
        return ret;
    }

    inline virtual std::string to_string() const override {
        return std::format("drawc::subfont_t[{}]", (void *)this);
    }
};

struct fontset_t : public vc::object_t {
    std::vector<vc::ref_t<font_t>> m_fonts;
    std::vector<uint32_t> m_code_redirect;
    std::vector<uint32_t> m_subf_redirect;
    uint32_t m_a_code = 61;

    static vc::object_type_e type_id_static() { return DRAWC_TYPE_FONT; }
    virtual vc::object_type_e type_id() const override { return DRAWC_TYPE_FONT; }

    static vc::ref_t<fontset_t> create(std::vector<vc::ref_t<font_t>> fonts,
            std::vector<uint32_t> m_code_redirect, std::vector<uint32_t> m_subf_redirect,
            uint32_t m_a_code = 61)
    {
        auto ret = std::make_shared<fontset_t>();
        ret->m_fonts = fonts;
        return ret;
    }

    inline virtual std::string to_string() const override {
        return std::format("drawc::fontset_t[{}]", (void *)this);
    }

    char_sz_t char_get_sz(char_t c) {
        return get_subf(c.font, c.code)->char_get_sz(get_subcode(c.code));
    }

    char_bb_t char_get_bb(char_t c, ImVec2 pos = ImVec2(0, 0)) {
        return get_subf(c.font, c.code)->char_get_bb(get_subcode(c.code), pos);
    }

    void char_draw(char_t c, ImVec2 pos, uint32_t color, bool draw_bb, uint32_t bb_color) {
        return get_subf(c.font, c.code)->char_draw(
                get_subcode(c.code), pos, color, draw_bb, bb_color);
    }

private:
    uint32_t get_subcode(uint32_t code) {
        if (code >= m_code_redirect.size())
            throw vc::except_t("Invalid char code [character redirect]");
        return m_code_redirect[code];
    }

    subfont_t *get_subf(uint32_t font, uint32_t code) {
        if (font >= m_fonts.size())
            throw vc::except_t("Invalid font code (size code");
        if (code >= m_subf_redirect.size())
            throw vc::except_t("Invalid char code [subfont redirect]");
        if (m_subf_redirect[code] >= m_fonts[font]->m_subfonts.size())
            throw vc::except_t("Invalid font sub-code");
        return m_fonts[font]->m_subfonts[m_subf_redirect[code]].get();
    }
};

inline int register_meta(vc::virt_state_t *vs) {
    DBG_SCOPE();

    std::vector<luaL_Reg> drawc_tab_funcs = {
        // {"create_symbol", vc::luaw_function_wrapper<fnname, TODO:>},
        // {"draw_symbol", vc::luaw_function_wrapper<fnname, TODO:>},
    };

    ASSERT_FN(add_lua_tab_funcs(vs, drawc_tab_funcs));

    VC_REGISTER_MEMBER_OBJECT(vs, subfont_t, m_path);
    VC_REGISTER_MEMBER_OBJECT(vs, subfont_t, m_font_size);

    int ret = add_named_builder_callback(vs,
        "drawc::subfont_t",
        [](vc::virt_state_t *vs, const std::string& node_name, fkyaml::node& node)
            -> co::task<vc::ref_t<vc::object_t>>
        {
            auto m_path = co_await resolve_str(vs, node["m_path"]);
            auto m_fontsz = co_await resolve_float(vs, node["m_font_size"]);
            auto obj = subfont_t::create(m_path, m_fontsz);
            mark_dependency_solved(vs, node_name, obj->to_related<vc::object_t>());
            co_return obj->to_related<vc::object_t>();
        }
    );
    ASSERT_FN(ret);

    ret = add_named_builder_callback(vs,
        "drawc::font_t",
        [](vc::virt_state_t *vs, const std::string& node_name, fkyaml::node& node)
            -> co::task<vc::ref_t<vc::object_t>>
        {
            std::vector<vc::ref_t<subfont_t>> m_subfonts;
            /* TODO: fill this */
            auto obj = font_t::create(m_subfonts);
            mark_dependency_solved(vs, node_name, obj->to_related<vc::object_t>());
            co_return obj->to_related<vc::object_t>();
        }
    );
    ASSERT_FN(ret);

    ret = add_named_builder_callback(vs,
        "drawc::fontset_t",
        [](vc::virt_state_t *vs, const std::string& node_name, fkyaml::node& node)
            -> co::task<vc::ref_t<vc::object_t>>
        {
            std::vector<vc::ref_t<font_t>> m_fonts;
            std::vector<uint32_t> m_code_redirect;
            std::vector<uint32_t> m_subf_redirect;
            uint32_t m_a_code;
            /* TODO: fill this */
            auto obj = fontset_t::create(m_fonts, m_code_redirect, m_subf_redirect, m_a_code);
            mark_dependency_solved(vs, node_name, obj->to_related<vc::object_t>());
            co_return obj->to_related<vc::object_t>();
        }
    );
    ASSERT_FN(ret);

    return vc::VC_ERROR_OK;
}

} /* char_draw_composer */

#endif

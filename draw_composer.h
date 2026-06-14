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
 * 
 */

namespace draw_composer
{

namespace vo = virt_object;
namespace vc = virt_composer;
namespace drawc = draw_composer;

VIRT_COMPOSER_REGISTER_TYPE(DRAWC_TYPE_SYMBOL);
VIRT_COMPOSER_REGISTER_TYPE(DRAWC_TYPE_FONT);

struct drawc_font_t : public vc::object_t {
    std::string m_path;
    float m_font_size = 42;

    ImFont* font = nullptr;

    static vc::object_type_e type_id_static() { return DRAWC_TYPE_FONT; }
    virtual vc::object_type_e type_id() const override { return DRAWC_TYPE_FONT; }

    static vc::ref_t<drawc_font_t> create(std::string path, float font_size) {
        auto ret = vc::ref_t<drawc_font_t>::create_obj_ref(std::make_unique<drawc_font_t>(), {});
        ret->m_path = path;
        ret->m_font_size = font_size;
        if (ret->_call_init() != vc::VC_ERROR_OK)
            throw vc::except_t(sformat("Failed to load font: %s, sz: %f", path.c_str(), font_size));
        return ret;
    }

    inline virtual std::string to_string() const override {
        return std::format("drawc_font_t[{}] path: %s sz: %f",
                (void *)this, m_path.c_str(), m_font_size);
    }

    /* returns advance_x, ascent, descent, botom_left, top_right  */
    std::tuple<float, std::tuple<float, float>, std::tuple<float, float>>
    char_get_sz(uint32_t code) {
        auto glyph = font->GetFontBaked(m_font_size)->FindGlyphNoFallback(code);
        return {
            glyph->AdvanceX,
            {
                glyph->X0,
                glyph->Y1,
            },
            {
                glyph->X1,
                glyph->Y0,
            },
        };
    }

    /* returns the bounding box as it will be drawn by the program */
    std::tuple<std::tuple<float, float>, std::tuple<float, float>>
    char_get_bb(uint32_t code, float posx, float posy) {
        auto ssz = char_get_sz(code);

        ImVec2 pos(posx, posy);
        ImVec2 bb_bl(std::get<0>(std::get<1>(ssz)), std::get<1>(std::get<1>(ssz)));
        ImVec2 bb_tr(std::get<0>(std::get<2>(ssz)), std::get<1>(std::get<2>(ssz)));

        ImVec2 bl = bb_bl + pos;
        ImVec2 tr = bb_tr + pos;

        return {
            {std::min(bl.x, tr.x), std::min(bl.y, tr.y)},
            {std::max(bl.x, tr.x), std::max(bl.y, tr.y)},
        };
    }

    void char_draw(uint32_t code, float posx, float posy, uint32_t color, bool draw_bb, uint32_t bb_color) {
        auto ssz = char_get_sz(code);

        ImVec2 pos(posx, posy);
        ImVec2 bb_bl(std::get<0>(std::get<1>(ssz)), std::get<1>(std::get<1>(ssz)));
        ImVec2 bb_tr(std::get<0>(std::get<2>(ssz)), std::get<1>(std::get<2>(ssz)));

        ImDrawList* draw_list = ImGui::GetWindowDrawList();
        ImGuiWindow* window = ImGui::GetCurrentWindow();
        if (window->SkipItems)
            return ;

        ImVec2 bl = bb_bl + pos;
        ImVec2 tr = bb_tr + pos;

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

    virtual vc::ret_t _init() override {
        ImGuiIO& io = ImGui::GetIO();
        font = io.Fonts->AddFontFromFileTTF(m_path.c_str(), m_font_size);
        if (!font)
            return vc::VC_ERROR_GENERIC;
        return vc::VC_ERROR_OK;
    }

    virtual vc::ret_t _uninit() override {
        ImGuiIO& io = ImGui::GetIO();
        io.Fonts->RemoveFont(font);
        return vc::VC_ERROR_OK;
    }
};

inline int register_meta(vc::virt_state_t *vs) {
    DBG_SCOPE();

    std::vector<luaL_Reg> drawc_tab_funcs = {
        // {"create_symbol", vc::luaw_function_wrapper<fnname, TODO:>},
        // {"draw_symbol", vc::luaw_function_wrapper<fnname, TODO:>},
    };

    ASSERT_FN(add_lua_tab_funcs(vs, drawc_tab_funcs));

    VC_REGISTER_MEMBER_OBJECT(vs, drawc_font_t, m_path);
    VC_REGISTER_MEMBER_OBJECT(vs, drawc_font_t, m_font_size);

    VC_REGISTER_MEMBER_FUNCTION(vs, drawc_font_t, char_draw,
            uint32_t, float, float, uint32_t, bool, uint32_t);
    VC_REGISTER_MEMBER_FUNCTION(vs, drawc_font_t, char_get_sz, uint32_t);
    VC_REGISTER_MEMBER_FUNCTION(vs, drawc_font_t, char_get_bb, uint32_t, float, float);

    // VC_REGISTER_MEMBER_OBJECT(vs, ast_node_t, ...)
    // vc::add_lua_flag_mapping(vs, ...);

    int ret = add_named_builder_callback(vs,
        "drawc_font_t",
        [](vc::virt_state_t *vs, const std::string& node_name, fkyaml::node& node)
            -> co::task<vc::ref_t<vc::object_t>>
        {
            auto m_path = co_await resolve_str(vs, node["m_path"]);
            auto m_fontsz = co_await resolve_float(vs, node["m_font_size"]);
            auto obj = drawc_font_t::create(m_path, m_fontsz);
            mark_dependency_solved(vs, node_name, obj.to_related<vc::object_t>());
            co_return obj.to_related<vc::object_t>();
        }
    );
    ASSERT_FN(ret);

    return vc::VC_ERROR_OK;
}

}

#endif

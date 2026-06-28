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


struct fontset_t : public vc::object_t {
    struct font_loc_t {
        uint32_t font;
        uint32_t fcode;
    };

    /*! Code of letter a inside the subfont, or more precisely, some letter that stays above the
     * write line and is a `small` letter (as oposed to `tall` letters such as "tlikjhf")
     * It's dimensions are used internally assuming those properties. */
    uint32_t m_a_code; 

    std::vector<std::string> font_paths;
    std::vector<float> font_sizes;

    std::map<int, font_loc_t> code_to_font_loc;
    std::vector<std::vector<std::shared_ptr<ImFont>>> fonts;

    static vc::object_type_e type_id_static() { return DRAWC_TYPE_FONTSET; }
    virtual vc::object_type_e type_id() const override { return DRAWC_TYPE_FONTSET; }

    static vc::ref_t<fontset_t> create(const std::vector<std::string>& font_paths,
            const std::vector<float>& font_sizes, int a_code)
    {
        auto ret = std::make_shared<fontset_t>();
        ret->font_paths = font_paths;
        ret->font_sizes = font_sizes;
        ret->m_a_code = a_code;
        if (ret->init() != vc::VC_ERROR_OK)
            throw vc::except_t(sformat("Failed to load fontset"));
        return ret;
    }

    inline virtual std::string to_string() const override {
        /* TODO: maybe describe more? */
        return std::format("drawc::fontset_t[{}]", (void *)this);
    }

    virtual vc::ret_t init() override {
        ImGuiIO& io = ImGui::GetIO();
        fonts = std::vector<std::vector<std::shared_ptr<ImFont>>>(font_sizes.size());

        for (size_t sz_id = 0; sz_id < font_sizes.size(); sz_id++) {
            fonts[sz_id] = std::vector<std::shared_ptr<ImFont>>(font_paths.size());

            for (size_t font_id = 0; font_id < font_paths.size(); font_id++) {
                auto font = io.Fonts->AddFontFromFileTTF(
                        font_paths[font_id].c_str(), font_sizes[sz_id]);
                if (!font) {
                    fonts = std::vector<std::vector<std::shared_ptr<ImFont>>>();
                    DBG("Failed to load font: %s of font size: %d",
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

    virtual vc::ret_t uninit() override {
        fonts = std::vector<std::vector<std::shared_ptr<ImFont>>>();
        return vc::VC_ERROR_OK;
    }

    void register_code(uint32_t code, uint32_t font, uint32_t fcode) {
        code_to_font_loc[code] = font_loc_t{ .font = font, .fcode = fcode };
    }

    char_sz_t char_get_sz(char_t c) {
        check_char(c);
        auto glyph = fonts[c.size-1][code_to_font_loc[c.code].font-1]
                ->GetFontBaked(font_sizes[c.size-1])->FindGlyphNoFallback(code_to_font_loc[c.code].fcode);
        return {
            .adv = glyph->AdvanceX,
            .bl = ImVec2(glyph->X0, glyph->Y1),
            .tr = ImVec2(glyph->X1, glyph->Y0),
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
        font->RenderChar(draw_list, font_sizes[c.size-1], pos, color, code_to_font_loc[c.code].fcode);
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

    VC_REGISTER_MEMBER_FUNCTION(vs, fontset_t, register_code, uint32_t, uint32_t, uint32_t);
    VC_REGISTER_MEMBER_FUNCTION(vs, fontset_t, char_draw, char_t, ImVec2, uint32_t, bool, uint32_t);

    int ret = add_named_builder_callback(vs,
        "drawc::fontset_t",
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

}; /* virt_composer */

#endif

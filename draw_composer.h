#ifndef DRAW_COMPOSER_H
#define DRAW_COMPOSER_H

#include "virt_composer.h"

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

/* TODO: drawc_content_t -- the holder of content, ast or text, depending of it's type */

struct drawc_symbol_t : public vc::object_t {
    /* TODO: */

    static vc::object_type_e type_id_static() { return DRAWC_TYPE_SYMBOL; }
    virtual vc::object_type_e type_id() const override { return DRAWC_TYPE_SYMBOL; }

    static vc::ref_t<drawc_symbol_t> create(/*TODO:*/) {
        auto ret = vc::ref_t<drawc_symbol_t>::create_obj_ref(std::make_unique<drawc_symbol_t>(), {});
        /* TODO: */
        return ret;
    }

    inline virtual std::string to_string() const override {
        return std::format("drawc_symbol_t[{}]", (void *)this);
    }

    virtual vc::ret_t _init() override { return vc::VC_ERROR_OK; }
    virtual vc::ret_t _uninit() override { return vc::VC_ERROR_OK; }
};

struct drawc_font_t : public vc::object_t {
    /* TODO: */
    std::vector<vc::ref_t<drawc_symbol_t>> symbols;

    static vc::object_type_e type_id_static() { return DRAWC_TYPE_FONT; }
    virtual vc::object_type_e type_id() const override { return DRAWC_TYPE_FONT; }

    static vc::ref_t<drawc_font_t> create(/*TODO:*/) {
        auto ret = vc::ref_t<drawc_font_t>::create_obj_ref(std::make_unique<drawc_font_t>(), {});
        /* TODO: */
        return ret;
    }

    inline virtual std::string to_string() const override {
        return std::format("drawc_font_t[{}]", (void *)this);
    }

    virtual vc::ret_t _init() override { return vc::VC_ERROR_OK; }
    virtual vc::ret_t _uninit() override { return vc::VC_ERROR_OK; }
};

inline int register_meta(vc::virt_state_t *vs) {
    DBG_SCOPE();

    std::vector<luaL_Reg> ast_tab_funcs = {
        // {"create_symbol", vc::luaw_function_wrapper<fnname, TODO:>},
        // {"draw_symbol", vc::luaw_function_wrapper<fnname, TODO:>},
    };

    ASSERT_FN(add_lua_tab_funcs(vs, ast_tab_funcs));

    // VC_REGISTER_MEMBER_OBJECT(vs, ast_node_t, ...)
    // vc::add_lua_flag_mapping(vs, ...);

    int ret = add_named_builder_callback(vs,
        "drawc_symbol_t",
        [](vc::virt_state_t *vs, const std::string& node_name, fkyaml::node& node)
            -> co::task<vc::ref_t<vc::object_t>>
        {
            auto obj = drawc_symbol_t::create();
            mark_dependency_solved(vs, node_name, obj.to_related<vc::object_t>());
            co_return obj.to_related<vc::object_t>();
        }
    );
    ASSERT_FN(ret);

    ret = add_named_builder_callback(vs,
        "drawc_font_t",
        [](vc::virt_state_t *vs, const std::string& node_name, fkyaml::node& node)
            -> co::task<vc::ref_t<vc::object_t>>
        {
            auto obj = drawc_font_t::create();
            mark_dependency_solved(vs, node_name, obj.to_related<vc::object_t>());
            co_return obj.to_related<vc::object_t>();
        }
    );
    ASSERT_FN(ret);

    return vc::VC_ERROR_OK;
}

}

#endif

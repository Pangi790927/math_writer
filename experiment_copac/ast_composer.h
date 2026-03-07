#ifndef AST_COMPOSER_H
#define AST_COMPOSER_H

#include "virt_composer.h"

namespace ast_composer
{

enum ast_node_e : int32_t {
    AST_NODE_ADDITION,

    AST_NODE_VAR,
    AST_NODE_INT,
};

inline std::string to_string(ast_node_e type);

} /*ast_composer*/

namespace virt_composer
{

namespace astc = ast_composer;

extern inline std::unordered_map<std::string, astc::ast_node_e> ast_node_from_str;
template <> inline astc::ast_node_e get_enum_val<astc::ast_node_e>(fkyaml::node &n);

} /*virt_composer*/

namespace ast_composer
{

namespace vo = virt_object;
namespace vc = virt_composer;
namespace astc = ast_composer;

VIRT_COMPOSER_REGISTER_TYPE(AST_TYPE_NODE);
VIRT_COMPOSER_REGISTER_TYPE(AST_TYPE_VAR);
VIRT_COMPOSER_REGISTER_TYPE(AST_TYPE_INT);

struct ast_node_t : public vc::object_t {
    ast_node_e m_op;
    std::vector<vc::ref_t<ast_node_t>> m_childs;

    static vc::object_type_e type_id_static() { return AST_TYPE_NODE; }
    virtual vc::object_type_e type_id() const override { return AST_TYPE_NODE; }

    static vc::ref_t<ast_node_t> create(ast_node_e op,
            const std::vector<vc::ref_t<ast_node_t>>& childs)
    {
        auto ret = vc::ref_t<ast_node_t>::create_obj_ref(std::make_unique<ast_node_t>(), {});
        ret->m_op = op;
        ret->m_childs = childs;
        return ret;
    }

    virtual std::string to_string_opt_rec_childs(int lvl=0) const {
        std::string padd = std::string(lvl*2, ' ');
        std::string res = "{\n";
        for (auto &r : m_childs)
            res += r->to_string_opt_rec_childs(lvl+1) + "\n";
        res += padd + "}\n";
        return std::format("{}ast_node_t: m_op={} m_childs={} ", padd, astc::to_string(m_op), res);
    }

    inline virtual std::string to_string() const override {
        return to_string_opt_rec_childs();
    }

    int add_child(vc::ref_t<ast_node_t> c) {
        m_childs.push_back(c);
        return 0;
    }


private:
    virtual vc::ret_t _init() override { return vc::VC_ERROR_OK; }
    virtual vc::ret_t _uninit() override { return vc::VC_ERROR_OK; }
};

struct ast_var_t : public ast_node_t {
    std::string m_name;

    static vc::object_type_e type_id_static() { return AST_TYPE_VAR; }
    virtual vc::object_type_e type_id() const override { return AST_TYPE_VAR; }

    static vc::ref_t<ast_var_t> create(const std::string& name) {
        auto ret = vc::ref_t<ast_var_t>::create_obj_ref(std::make_unique<ast_var_t>(), {});
        ret->m_op = AST_NODE_VAR;
        ret->m_name = name;
        return ret;
    }

    virtual std::string to_string_opt_rec_childs(int lvl=0) const override {
        std::string padd = std::string(lvl*2, ' ');
        return std::format("{}ast_var_t: m_name={} ", padd, m_name);
    }
};

struct ast_integer_t : public ast_node_t {
    int64_t m_value = 0;

    static vc::object_type_e type_id_static() { return AST_TYPE_INT; }
    virtual vc::object_type_e type_id() const override { return AST_TYPE_INT; }

    static vc::ref_t<ast_integer_t> create(int64_t value) {
        auto ret = vc::ref_t<ast_integer_t>::create_obj_ref(std::make_unique<ast_integer_t>(), {});
        ret->m_op = AST_NODE_VAR;
        ret->m_value = value;
        return ret;
    }

    virtual std::string to_string_opt_rec_childs(int lvl=0) const override {
        std::string padd = std::string(lvl*2, ' ');
        return std::format("{}ast_integer_t: m_value={} ", padd, m_value);
    }
};

inline int register_meta(vc::virt_state_t *vs) {
    DBG_SCOPE();

    VC_REGISTER_MEMBER_OBJECT(vs, ast_node_t, m_op);
    VC_REGISTER_MEMBER_OBJECT(vs, ast_var_t, m_name);
    VC_REGISTER_MEMBER_OBJECT(vs, ast_integer_t, m_value);
    // VC_REGISTER_MEMBER_OBJECT(vs, ast_node_t, m_childs);

    /* TODO: this is temp, maybe add a full suite in the future? I'll see if needed*/
    VC_REGISTER_MEMBER_FUNCTION(vs, ast_node_t, add_child, vc::ref_t<ast_node_t>);

    vc::add_lua_flag_mapping(vs, vc::ast_node_from_str);

    int ret = add_named_builder_callback(vs,
        "ast_node_t",
        [](vc::virt_state_t *vs, const std::string& node_name, fkyaml::node& node)
            -> co::task<vc::ref_t<vc::object_t>>
        {
            auto m_op = vc::get_enum_val<ast_node_e>(node["m_op"]);
            std::vector<vc::ref_t<ast_node_t>> childs;
            for (auto attr : node["m_childs"].as_seq())
                childs.push_back(co_await resolve_obj<ast_node_t>(vs, attr));
            auto obj = ast_node_t::create(m_op, childs);
            mark_dependency_solved(vs, node_name, obj.to_related<vc::object_t>());
            co_return obj.to_related<vc::object_t>();
        }
    );
    ASSERT_FN(ret);

    ret = add_named_builder_callback(vs,
        "ast_var_t",
        [](vc::virt_state_t *vs, const std::string& node_name, fkyaml::node& node)
            -> co::task<vc::ref_t<vc::object_t>>
        {
            auto m_name = co_await resolve_str(vs, node["m_name"]);
            auto obj = ast_var_t::create(m_name);
            mark_dependency_solved(vs, node_name, obj.to_related<vc::object_t>());
            co_return obj.to_related<vc::object_t>();
        }
    );
    ASSERT_FN(ret);


    ret = add_named_builder_callback(vs,
        "ast_integer_t",
        [](vc::virt_state_t *vs, const std::string& node_name, fkyaml::node& node)
            -> co::task<vc::ref_t<vc::object_t>>
        {
            auto m_value = co_await resolve_int(vs, node["m_value"]);
            auto obj = ast_integer_t::create(m_value);
            mark_dependency_solved(vs, node_name, obj.to_related<vc::object_t>());
            co_return obj.to_related<vc::object_t>();
        }
    );
    ASSERT_FN(ret);


    return 0;
}

inline std::string to_string(ast_node_e type) {
    switch (type) {
        case AST_NODE_ADDITION: return "AST_NODE_ADDITION";
        case AST_NODE_VAR: return "AST_NODE_VAR";
        case AST_NODE_INT: return "AST_NODE_INT";
        default: return "INVALID_TYPE";
    }
}

} /*ast_composer*/

namespace virt_composer {

template <> inline astc::ast_node_e get_enum_val<astc::ast_node_e>(fkyaml::node &n) {
    return get_enum_val(n, ast_node_from_str);
}

inline std::unordered_map<std::string, astc::ast_node_e> ast_node_from_str = {
    {"AST_NODE_ADDITION", astc::AST_NODE_ADDITION},
    {"AST_NODE_VAR", astc::AST_NODE_VAR},
    {"AST_NODE_INT", astc::AST_NODE_INT},
};


} /*virt_composer*/


#endif

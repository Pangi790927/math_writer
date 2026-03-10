#ifndef AST_COMPOSER_H
#define AST_COMPOSER_H

#include "virt_composer.h"

namespace ast_composer
{

/*! TODO: I need some sort of 'feature' addition to the node not sure if inheritance is the way to
 * go. For example: I want to add subscripts to a variable, that is of course the job of a variable.
 * Or maybe inheritance is the way to go? But how do I make for example integrals? Answ: I use the
 * list node type. (So nothing to do)
 * 
 * TODO: I am pertty sure I need to keep a sort of graph of inheritance for all the types, as such,
 * I will be able to use functions marked for base in child. (This seems important)
 * 
 * The advantage of the inheritance model is that things are easier to work with: faster, shorter
 * init scripts, etc.
 * 
 * OBS: ast_var_t is special, as there can not be other "permanent" references between 'steps'
 * a 'step' is a transformation. User will be able to prepare a context and apply a transformation
 * with the given context. Transforamtion rules that should be found in lua. As such, maybe we
 * could better remember transform steps from an origin to a destination and hold a single ast for
 * each branch.
 * This enables the construction of instances. 
 * TODO: Save-AST Load-AST - maybe do that into/from yaml for now?
 */

enum ast_node_e : int32_t {
    /* ---------- ast_node_t ---------- */

    /*! Childs are the terms of the addition */
    AST_NODE_ADD,

    /*! Childs are the factors of the multiplication */
    AST_NODE_MUL,

    /*! 1st child is the function, rest of childs are args */
    AST_NODE_FN_CALL,

    /*! A node with exactly two childs: num, den */
    AST_NODE_DIV,

    /*! A node that doesn't do much, just holds a list of nodes */
    /* TODO: */
    AST_NODE_LIST,

    /* ---------- ast_var_t ---------- */

    /*! Only for ast_var_t, holds the name of the var, eventually childs can be vector/matrix
     * fields
     */
    /* TOOD: configure to be able to have subscripts, maybe? Or create a new node type that
    handles subscriptions? Or maybe leave it alone and make list nodes for vector-fields, subscripts,
    superscripts, Inherited type, etc? */
    AST_NODE_VAR,

    /* ---------- ast_integer_t ---------- */

    /*! Holds an integer, not sure what use do the childs have for this one if they have any. This
     * is a building block for other types, TODO: for example I think I want rational numbers to be
     * made out of two numbers. for example the number 1.5*sqrt(2)*sqrt(3), can be made out to be:
     *      node*(real(3, 2), fn(sqrt, 2), fn(sqrt, 3))
     * where 2 and 3 are node_int, fn is fn_call, sqrt is node_var with the name of the var
     */
    AST_NODE_INT,
};

enum ast_flags_e : uint64_t {
    AST_FLAG_NONE = 0,

    /* Flags for fn_call: */
    AST_FLAG_FN_CALL_BUILTIN = (1 << 0),    /*!< handle it by it's built-in name (name of 
                                                 childs[0]) */

    /* Flags for vars: */
    AST_FLAG_VAR_REPLACE = (1 << 0),        /*!< replaces the var with it's content on draw/latex */
    AST_FLAG_VAR_MATRIX = (1 << 1),         /*!< remembers that the result is a matrix (childs are
                                                 rows, values for vec or lists in case of matrix) */

    /* Flags for cints: */

    /* Flags for lists: */
    AST_FLAG_LIST_VERTICAL = (1 << 0),      /*!< specifies vertical list (\\ delimiter) */
    AST_FLAG_LIST_HORIZ_BALANCED = (1 << 1),/*!< specifies the '&' as delimiter for horiz case */
    AST_FLAG_LIST_VERT_SUBSTACK = (1 << 2), /*!< specifies the \substack{} guard for vert case */

    /* flags for all: */
    /* OBS: whatever flag is >= bit 32 is common to all */
    AST_FLAG_RANDOM_FLAG = (1ULL << 32),
};

enum ast_error_e : int64_t {
    AST_ERROR_OK = 0,
    AST_ERROR_GENERIC = -1,
    AST_ERROR_HAS_PARENT = -2,
    AST_ERROR_NO_PARENT = -3,
};

inline std::string to_string(ast_node_e type);
inline std::string to_string(ast_node_e type, ast_flags_e flag);

} /*ast_composer*/

namespace virt_composer
{

namespace astc = ast_composer;

extern inline std::unordered_map<std::string, astc::ast_node_e> ast_node_from_str;
template <> inline astc::ast_node_e get_enum_val<astc::ast_node_e>(fkyaml::node &n);

extern inline std::unordered_map<std::string, astc::ast_flags_e> ast_flags_from_str;
template <> inline astc::ast_flags_e get_enum_val<astc::ast_flags_e>(fkyaml::node &n);

} /*virt_composer*/

namespace ast_composer
{

namespace vo = virt_object;
namespace vc = virt_composer;
namespace astc = ast_composer;

VIRT_COMPOSER_REGISTER_TYPE(AST_TYPE_NODE);
VIRT_COMPOSER_REGISTER_TYPE(AST_TYPE_VAR);
VIRT_COMPOSER_REGISTER_TYPE(AST_TYPE_INT);

struct except_t : public vc::except_t {
    std::string err_str;
    ast_error_e err_code;

    except_t(ast_error_e err_code, const std::string& str) : err_code(err_code), vc::except_t(str) {}
};


inline void childs_list_maker(auto &childs, std::string &result, const std::string& separator,
        int start, int stop)
{
    for (int i = start; i < stop - 1; i++)
        result += childs[i]->generate_latex() + separator;
    if (stop - 1 < childs.size())
        result += childs[stop - 1]->generate_latex();
};

struct ast_node_t : public vc::object_t {
    ast_node_e m_op;
    ast_flags_e m_flags = AST_FLAG_NONE;

    static vc::object_type_e type_id_static() { return AST_TYPE_NODE; }
    virtual vc::object_type_e type_id() const override { return AST_TYPE_NODE; }

    static vc::ref_t<ast_node_t> create(ast_node_e op) {
        auto ret = vc::ref_t<ast_node_t>::create_obj_ref(std::make_unique<ast_node_t>(), {});
        ret->m_self = ret._base;
        ret->m_op = op;
        return ret;
    }

    virtual std::string to_string_opt_rec_childs(int lvl=0) const {
        std::string padd = std::string(lvl*2, ' ');
        std::string res = "{\n";
        for (auto &r : m_childs)
            res += r->to_string_opt_rec_childs(lvl+1) + "\n";
        res += padd + "}\n";
        return std::format("{}ast_node_t: m_op={} m_flags={} m_childs={} ",
                padd, astc::to_string(m_op), astc::to_string(m_op, m_flags), res);
    }

    inline virtual std::string to_string() const override {
        return to_string_opt_rec_childs();
    }

    virtual std::string generate_latex();

    vc::ref_t<ast_node_t> get_selfref() {
        return vc::ref_t<ast_node_t>{m_self.lock()};
    }

    bool has_flags(ast_flags_e flags) {
        return (m_flags & flags) == flags;
    }

    size_t num_childs() {
        return m_childs.size();
    }

    int push_child(vc::ref_t<ast_node_t> c) {
        if (!c)
            throw except_t(AST_ERROR_GENERIC, "Can't push a null/nil child");
        c->set_parent(this);
        m_childs.push_back(c);
        return 0;
    }

    int pop_child() {
        m_childs.back()->unset_parent(this);
        m_childs.pop_back();
        return 0;
    }

    void erase_child(int i) {
        if (i < 0 || i >= m_childs.size())
            throw except_t(AST_ERROR_GENERIC,
                    std::format("erase: Invalid index: {} size: {}", i, m_childs.size()));
        m_childs.erase(m_childs.begin() + i);
    }

    void insert_child(int i, vc::ref_t<ast_node_t> to_insert) {
        if (i < 0 || i >= m_childs.size())
            throw except_t(AST_ERROR_GENERIC,
                    std::format("insert: Invalid index: {} size: {}", i, m_childs.size()));
        m_childs.insert(m_childs.begin() + i, to_insert);
    }

    vc::ref_t<ast_node_t> get_child(int i) {
        if (i < 0 || i >= m_childs.size())
            throw except_t(AST_ERROR_GENERIC,
                    std::format("getc: Invalid index: {} size: {}", i, m_childs.size()));
        return m_childs[i];
    }

    void set_child(int i, vc::ref_t<ast_node_t> to_set) {
        if (!to_set)
            throw except_t(AST_ERROR_GENERIC, "Can't set a null/nil child");
        if (i < 0 || i >= m_childs.size())
            throw except_t(AST_ERROR_GENERIC, std::format("Invalid index: {} size: {}",
                    i, m_childs.size()));
        m_childs[i]->unset_parent(this);
        m_childs[i] = to_set;
        to_set->set_parent(this);
    }

    virtual vc::ref_t<ast_node_t> create_copy() {
        auto ret = create(m_op);
        ret->m_flags = m_flags;
        for (auto &child : m_childs)
            ret->push_child(child->create_copy());
        return ret;
    }

    std::tuple<int, int, std::string> test_tuple_return() {
        return {10, 12, "Ana are mere"};
    }

    std::tuple<vc::ref_t<ast_node_t>, int> get_parent(int i) {
        if (i < 0 || i >= m_parents.size())
            return {nullptr, 0};
        auto it = m_parents.begin();
        std::advance(it, i);
        auto ret = it->first->get_selfref();
        for (int index = 0; index < ret->m_childs.size(); index++)
            if (ret->m_childs[index].get() == this)
                return {ret, index};
        DBG("Something is very wrong if we didn't find the child in the parrents child list");
        throw except_t(AST_ERROR_GENERIC, "Parent forgot it's child");
    }

    int num_parents() {
        return m_parents.size();
    }

    intptr_t selfp() {
        return (intptr_t)this;
    }

    /* TODO: check when ref_t objects are destroyed, if ever */

    /* TODO: is this not needed now that I have the parent? */
    /* This searches for the expression `to_find` inside the expression `expr_src` */
    // std::tuple<int, vc::ref_t<ast_node_t>> find_expr(vc::ref_t<ast_node_t> expr_src,
    //         vc::ref_t<ast_node_t> to_find)
    // {
    // }

protected:
    std::map<ast_node_t *, int> m_parents;
    std::vector<vc::ref_t<ast_node_t>> m_childs;
    std::weak_ptr<vo::base_t<vc::virt_traits_t>> m_self;

    virtual void set_parent(ast_node_t *parent) {
        if (m_parents.size())
            throw except_t(AST_ERROR_HAS_PARENT, "Node already has a parent");
        m_parents[parent] = 1;
    }

    virtual void unset_parent(ast_node_t *parent) {
        if (!has(m_parents, parent))
            throw except_t(AST_ERROR_NO_PARENT, "ERROR: Not a parent of this object");
        m_parents.erase(parent);
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
        ret->m_self = ret._base;
        ret->m_op = AST_NODE_VAR;
        ret->m_name = name;
        return ret;
    }

    virtual std::string to_string_opt_rec_childs(int lvl=0) const override {
        bool replace = m_flags & AST_FLAG_VAR_REPLACE;
        std::string padd = std::string(lvl*2, ' ');
        std::string content;

        if (replace) {
            content = "m_childs={\n";
            for (auto &r : m_childs)
                content += r->to_string_opt_rec_childs(lvl+1) + "\n";
            content += padd + "}\n";
        }
        return std::format("{}ast_var_t: m_flags={} m_name={} {}",
                padd, astc::to_string(m_op, m_flags), m_name, content);
    }

    virtual std::string generate_latex() override {
        /* TODO: maybe escape things in name? */
        bool replace = m_flags & AST_FLAG_VAR_REPLACE;
        bool is_matrix = m_flags & AST_FLAG_VAR_MATRIX;
        if (replace && is_matrix) {
            std::string ret = "\\begin{pmatrix}";
            childs_list_maker(m_childs, ret, "\\\\", 0, m_childs.size());
            ret += "\\end{pmatrix}";
            return ret;
        }
        else {
            return m_name;
        }
    }

    virtual vc::ref_t<ast_node_t> create_copy() override {
        /* The thing is vars are not copy-able in a sense. The same var should be able to be
        referenced from multiple locations, as such, vars should not be copied on the create_copy
        call and two different vars are only created when there are two different create calls for
        vars*/
        return get_selfref();
    }

protected:
    virtual void set_parent(ast_node_t *parent) override {
        m_parents[parent]++;
    }

    virtual void unset_parent(ast_node_t *parent) override {
        if (!has(m_parents, parent))
            throw except_t(AST_ERROR_NO_PARENT, "ERROR: Not a parent of this object");
        m_parents[parent]--;
        if (!m_parents[parent])
            m_parents.erase(parent);
    }
};

struct ast_integer_t : public ast_node_t {
    int64_t m_value = 0;

    static vc::object_type_e type_id_static() { return AST_TYPE_INT; }
    virtual vc::object_type_e type_id() const override { return AST_TYPE_INT; }

    static vc::ref_t<ast_integer_t> create(int64_t value) {
        auto ret = vc::ref_t<ast_integer_t>::create_obj_ref(std::make_unique<ast_integer_t>(), {});
        ret->m_self = ret._base;
        ret->m_op = AST_NODE_VAR;
        ret->m_value = value;
        return ret;
    }

    virtual std::string to_string_opt_rec_childs(int lvl=0) const override {
        std::string padd = std::string(lvl*2, ' ');
        return std::format("{}ast_integer_t: m_flags={} m_value={}",
                padd, astc::to_string(m_op, m_flags), m_value);
    }

    virtual std::string generate_latex() override {
        return std::to_string(m_value);
    }
};

/* TODO: generate_latex has no place here, it stays just well in Lua */

inline std::string ast_node_t::generate_latex() {
    // DBG("Gen latex: m_op[%d] m_childs[%zd]", m_op, m_childs.size());
    std::string result;
    std::string biop = " + ";

    switch (m_op) {
        case AST_NODE_MUL: {
            if (!m_childs.size()) {
                result = "[empty_mul]";
                break;
            }
            childs_list_maker(m_childs, result, "", 0, m_childs.size());
        } break;
        case AST_NODE_ADD: {
            if (!m_childs.size()) {
                result = "[empty_add]";
                break;
            }
            result += "(";
            childs_list_maker(m_childs, result, " + ", 0, m_childs.size());
            result += ")";
        } break;
        case AST_NODE_FN_CALL: {
            if (!m_childs.size()) {
                result = "[empty_call]";
                break;
            }
            bool builtin = m_flags & AST_FLAG_FN_CALL_BUILTIN;

            if (builtin) {
                auto var = m_childs[0].to_related<ast_var_t>();
                if (var->m_name == "sqrt") {
                    if (m_childs.size() < 2)
                        throw except_t(AST_ERROR_GENERIC,
                                "sqrt must have at least one argument");
                    result += "\\sqrt{";
                    result += m_childs[1]->generate_latex();
                    result += "}";
                }
                else
                    throw except_t(AST_ERROR_GENERIC, "Not a known built-in");
            }
            else {
                result += m_childs[0]->generate_latex() + "(";
                childs_list_maker(m_childs, result, ", ", 1, m_childs.size());
                result += ")";
            }

        } break;
        case AST_NODE_LIST: {
            bool horiz = !(m_flags & AST_FLAG_LIST_VERTICAL);
            bool balanced = m_flags & AST_FLAG_LIST_HORIZ_BALANCED;
            bool substack = m_flags & AST_FLAG_LIST_VERT_SUBSTACK;

            if (horiz) {
                childs_list_maker(m_childs, result, balanced ? "&" : ",", 0, m_childs.size());
            }
            else {
                if (substack)
                    result += "\\substack{";
                childs_list_maker(m_childs, result, "\\\\", 0, m_childs.size());
                if (substack)
                    result += "}";
            }
        } break;
    }
    return result;
}

static co::task_t parse_optionals(auto &vs, auto &node, auto &obj) {
    if (node.contains("m_childs")) {
        for (auto attr : node["m_childs"].as_seq()) {
            vc::ref_t<ast_node_t> future_child = co_await resolve_obj<ast_node_t>(vs, attr);
            try {
                obj->push_child(future_child);
            }
            catch (except_t &e) {
                if (e.err_code == AST_ERROR_HAS_PARENT)
                    obj->push_child(future_child->create_copy());
                else
                    throw ;
            }
        }
    }
    if (node.contains("m_flags")) {
        obj->m_flags = vc::get_enum_val<ast_flags_e>(node["m_flags"]);
    }
    co_return 0;
}

inline vc::ref_t<ast_node_t> create_ast_node(ast_node_e op) {
    return ast_node_t::create(op);
}

inline vc::ref_t<ast_var_t> create_ast_var(const char *name) {
    return ast_var_t::create(name);
}

inline vc::ref_t<ast_integer_t> create_ast_int(int64_t value) {
    return ast_integer_t::create(value);
}

inline int register_meta(vc::virt_state_t *vs) {
    DBG_SCOPE();

    std::vector<luaL_Reg> ast_tab_funcs = {
        {"create_ast_node", vc::luaw_function_wrapper<create_ast_node, vc::bm_t<ast_node_e>>},
        {"create_ast_var",  vc::luaw_function_wrapper<create_ast_var,  const char *>},
        {"create_ast_int",  vc::luaw_function_wrapper<create_ast_int,  int64_t>},
    };

    ASSERT_FN(add_lua_tab_funcs(vs, ast_tab_funcs));

    luaw_register_inheritance<ast_node_t, ast_var_t>(vs);
    luaw_register_inheritance<ast_node_t, ast_integer_t>(vs);

    VC_REGISTER_MEMBER_OBJECT(vs, ast_node_t, m_op);
    VC_REGISTER_MEMBER_OBJECT(vs, ast_node_t, m_flags);
    VC_REGISTER_MEMBER_OBJECT(vs, ast_var_t, m_name);
    VC_REGISTER_MEMBER_OBJECT(vs, ast_integer_t, m_value);

    VC_REGISTER_MEMBER_FUNCTION(vs, ast_node_t, push_child, vc::ref_t<ast_node_t>);
    VC_REGISTER_MEMBER_FUNCTION(vs, ast_node_t, generate_latex);
    VC_REGISTER_MEMBER_FUNCTION(vs, ast_node_t, has_flags, vc::bm_t<ast_flags_e>);
    VC_REGISTER_MEMBER_FUNCTION(vs, ast_node_t, num_childs);
    VC_REGISTER_MEMBER_FUNCTION(vs, ast_node_t, push_child, vc::ref_t<ast_node_t>);
    VC_REGISTER_MEMBER_FUNCTION(vs, ast_node_t, pop_child);
    VC_REGISTER_MEMBER_FUNCTION(vs, ast_node_t, get_child, int);
    VC_REGISTER_MEMBER_FUNCTION(vs, ast_node_t, set_child, int, vc::ref_t<ast_node_t>);
    VC_REGISTER_MEMBER_FUNCTION(vs, ast_node_t, erase_child, int);
    VC_REGISTER_MEMBER_FUNCTION(vs, ast_node_t, insert_child, int, vc::ref_t<ast_node_t>);
    VC_REGISTER_MEMBER_FUNCTION(vs, ast_node_t, test_tuple_return);
    VC_REGISTER_MEMBER_FUNCTION(vs, ast_node_t, create_copy);
    VC_REGISTER_MEMBER_FUNCTION(vs, ast_node_t, get_parent, int);
    VC_REGISTER_MEMBER_FUNCTION(vs, ast_node_t, num_parents);
    VC_REGISTER_MEMBER_FUNCTION(vs, ast_node_t, selfp);

    vc::add_lua_flag_mapping(vs, vc::ast_node_from_str);
    vc::add_lua_flag_mapping(vs, vc::ast_flags_from_str);

    int ret = add_named_builder_callback(vs,
        "ast_node_t",
        [](vc::virt_state_t *vs, const std::string& node_name, fkyaml::node& node)
            -> co::task<vc::ref_t<vc::object_t>>
        {
            auto m_op = vc::get_enum_val<ast_node_e>(node["m_op"]);
            auto obj = ast_node_t::create(m_op);
            if (co_await parse_optionals(vs, node, obj) != vc::VC_ERROR_OK)
                throw except_t(AST_ERROR_GENERIC, "Failed to parse optionals in node");
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
            if (co_await parse_optionals(vs, node, obj) != vc::VC_ERROR_OK)
                throw except_t(AST_ERROR_GENERIC, "Failed to parse optionals in var");
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
            if (co_await parse_optionals(vs, node, obj) != vc::VC_ERROR_OK)
                throw except_t(AST_ERROR_GENERIC, "Failed to parse optionals in const int");
            mark_dependency_solved(vs, node_name, obj.to_related<vc::object_t>());
            co_return obj.to_related<vc::object_t>();
        }
    );
    ASSERT_FN(ret);

    return 0;
}

inline std::string to_string(ast_node_e type) {
    switch (type) {
        case AST_NODE_ADD: return "AST_NODE_ADD";
        case AST_NODE_MUL: return "AST_NODE_MUL";
        case AST_NODE_LIST: return "AST_NODE_LIST";
        case AST_NODE_FN_CALL: return "AST_NODE_FN_CALL";
        case AST_NODE_VAR: return "AST_NODE_VAR";
        case AST_NODE_INT: return "AST_NODE_INT";
        default: return "INVALID_TYPE";
    }
}

#define ASTC_TO_STRING_FLAGS(flag) \
do { \
    if (flags & flag) { \
        if (ret_str != "[") \
            ret_str += ", "; \
        ret_str += #flag; \
        flags = ast_flags_e(flags & (~flag)); \
    } \
} while (0)

inline std::string to_string(ast_node_e type, ast_flags_e flags) {
    std::string ret_str = "[";

    if (type == AST_NODE_FN_CALL) {
        ASTC_TO_STRING_FLAGS(AST_FLAG_FN_CALL_BUILTIN);
    }

    if (type == AST_NODE_VAR) {
        ASTC_TO_STRING_FLAGS(AST_FLAG_VAR_REPLACE);
        ASTC_TO_STRING_FLAGS(AST_FLAG_VAR_MATRIX);
    }

    if (type == AST_NODE_LIST) {
        ASTC_TO_STRING_FLAGS(AST_FLAG_LIST_VERTICAL);
        ASTC_TO_STRING_FLAGS(AST_FLAG_LIST_HORIZ_BALANCED);
        ASTC_TO_STRING_FLAGS(AST_FLAG_LIST_VERT_SUBSTACK);
    }

    ASTC_TO_STRING_FLAGS(AST_FLAG_RANDOM_FLAG);
    
    if (flags != 0) {
        DBG("!!! ERROR: MISSED FLAGS IN TO_STRING !!! ");
        return "!!! ERROR: MISSED FLAGS IN TO_STRING !!! ";
    }
    ret_str += "]";
    return ret_str;
}

#undef ASTC_TO_STRING_FLAGS

} /*ast_composer*/

namespace virt_composer {

template <> inline astc::ast_node_e get_enum_val<astc::ast_node_e>(fkyaml::node &n) {
    return get_enum_val(n, ast_node_from_str);
}

inline std::unordered_map<std::string, astc::ast_node_e> ast_node_from_str = {
    {"AST_NODE_ADD", astc::AST_NODE_ADD},
    {"AST_NODE_MUL", astc::AST_NODE_MUL},
    {"AST_NODE_LIST", astc::AST_NODE_LIST},
    {"AST_NODE_FN_CALL", astc::AST_NODE_FN_CALL},
    {"AST_NODE_VAR", astc::AST_NODE_VAR},
    {"AST_NODE_INT", astc::AST_NODE_INT},
};

template <> inline astc::ast_flags_e get_enum_val<astc::ast_flags_e>(fkyaml::node &n) {
    return get_enum_val(n, ast_flags_from_str);
}

inline std::unordered_map<std::string, astc::ast_flags_e> ast_flags_from_str = {
    {"AST_FLAG_RANDOM_FLAG", astc::AST_FLAG_RANDOM_FLAG},
    {"AST_FLAG_LIST_VERTICAL", astc::AST_FLAG_LIST_VERTICAL},
    {"AST_FLAG_LIST_HORIZ_BALANCED", astc::AST_FLAG_LIST_HORIZ_BALANCED},
    {"AST_FLAG_LIST_VERT_SUBSTACK", astc::AST_FLAG_LIST_VERT_SUBSTACK},
    {"AST_FLAG_VAR_REPLACE", astc::AST_FLAG_VAR_REPLACE},
    {"AST_FLAG_VAR_MATRIX", astc::AST_FLAG_VAR_MATRIX},
    {"AST_FLAG_FN_CALL_BUILTIN", astc::AST_FLAG_FN_CALL_BUILTIN},

};

} /*virt_composer*/


#endif

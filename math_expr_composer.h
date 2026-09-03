#ifndef MATH_DRAWING_H
#define MATH_DRAWING_H

/* Math Drawing: Symbol and Expression Drawing */

#include <memory>
#include <map>
#include <vector>
#include <math.h>
#include <algorithm>

#include "char_draw_composer.h"
#include "misc_utils.h"
#include "debug.h"

namespace math_expr_composer {

enum mexpr_bracket_e : int {
    MEXPR_BRACKET_ROUND,
    MEXPR_BRACKET_SQUARE,
    MEXPR_BRACKET_CURLY,
};

enum mexpr_e : int {
    MEXPR_TYPE_INTERNAL,
    MEXPR_TYPE_LINE_STRIP,
    MEXPR_TYPE_EMPTY_BOX,
    MEXPR_TYPE_SYMBOL,
};

struct mexpr_bracket_t {
    mexpr_bracket_e type;
    char_draw_composer::char_t tl;          /* top left */
    char_draw_composer::char_t bl;          /* bottom left */
    char_draw_composer::char_t tr;          /* top right */
    char_draw_composer::char_t br;          /* bottom right */
    char_draw_composer::char_t cl;          /* center left */
    char_draw_composer::char_t cr;          /* center right */
    char_draw_composer::char_t conl;        /* connector */
    char_draw_composer::char_t conr;        /* connector */
    char_draw_composer::char_t left[4];     /* smaller brackets left part */
    char_draw_composer::char_t right[4];    /* smaller brackets right part */
};

/*! Just the (tl, br) bounding box already stored on any mexpr_t, exposed to Lua - lets a script
measure a built expression (or a subtree of one) without drawing it, e.g. to size a container to
fit it, or to work out where a sub-part landed relative to the whole. */
struct mexpr_bb_t {
    ImVec2 tl;
    ImVec2 br;
};


} /* math_expr_composer */

namespace virt_composer {

extern inline std::unordered_map<std::string, math_expr_composer::mexpr_bracket_e>
        mexpr_bracket_from_str;

extern inline std::unordered_map<std::string, math_expr_composer::mexpr_e>
        mexpr_e_from_str;

template <> inline math_expr_composer::mexpr_bracket_e
get_enum_val<math_expr_composer::mexpr_bracket_e>(fkyaml::node &n);

template <> inline math_expr_composer::mexpr_e
get_enum_val<math_expr_composer::mexpr_e>(fkyaml::node &n);

template <ssize_t index>
struct luaw_param_t<math_expr_composer::mexpr_bracket_t, index> {
    math_expr_composer::mexpr_bracket_t luaw_single_param(lua_State *L);
};

template <>
struct luaw_returner_t<math_expr_composer::mexpr_bb_t> {
    void luaw_ret_push(lua_State *L, const math_expr_composer::mexpr_bb_t& bb);
};

template <>
struct luaw_returner_t<char_draw_composer::char_t> {
    void luaw_ret_push(lua_State *L, const char_draw_composer::char_t& c);
};


} /* virt_composer */

namespace math_expr_composer {

namespace vc = virt_composer;
namespace charc = char_draw_composer;
namespace mexpr = math_expr_composer;

VIRT_COMPOSER_REGISTER_TYPE(MEXPR_TYPE_EXPR);
VIRT_COMPOSER_REGISTER_TYPE(MEXPR_TYPE_WREF);
VIRT_COMPOSER_REGISTER_TYPE(MEXPR_TYPE_RREF);

using char_t = charc::char_t;

struct mexpr_t;
using mexpr_p = vc::ref_t<mexpr_t>;

/*! holds an object and it's position */
struct anchor_t {
    mexpr_p obj;
    ImVec2  pos;
};

/*! std::vector<T>, plus a small bounds-checked, 1-indexed convenience API on top. Leading
underscore on every added method so none of them ever collide with/hide std::vector<T>'s own
same-shaped members (e.g. `_insert(i, val)` sits right alongside the inherited iterator-based
`insert()`, no `using` declarations needed to keep both reachable).

Deliberately NOT a vc::object_t - this type is never itself registered with or passed to Lua. The
owning object_t picks and chooses what to forward (see mexpr_t's anchor_* wrappers below), so only
exactly what's meant to be Lua-reachable ever is - everything else (push_back, resize, operator[],
begin()/end(), ...) stays available for plain C++ use, with zero Lua footprint. */
template <typename T>
struct lua_vector_t : public std::vector<T> {
    using std::vector<T>::vector;   // inherit std::vector<T>'s own constructors too
    using std::vector<T>::operator=; // ...and its assignment operators - NOT inherited by default
    // (unlike constructors): every derived class implicitly declares its own operator=, which
    // hides the base ones unless pulled back in here - without this, `subobjs = some_std_vector`
    // (several mexpr_* factories below do exactly that) fails to compile.

    int _len() const { return (int)this->size(); }
    bool _is_empty() const { return this->empty(); }

    /*! 1-indexed, bounds-checked read. */
    T _at(int i) const {
        if (i < 1 || i > _len())
            throw vc::except_t(std::format("lua_vector _at: index {} out of range (1..{})",
                    i, _len()));
        return (*this)[i - 1];
    }

    /*! Overwrites the element already at `i` (1-indexed) - i must already be occupied. */
    void _set(int i, T val) {
        if (i < 1 || i > _len())
            throw vc::except_t(std::format("lua_vector _set: index {} out of range (1..{})",
                    i, _len()));
        (*this)[i - 1] = std::move(val);
    }

    /*! Inserts `val` right after position `i` (1-indexed); i=0 inserts before everything. Valid
    range for i is [0, _len()] - same position insert(begin()+i, val) would use, just int instead of
    an iterator. */
    void _insert(int i, T val) {
        if (i < 0 || i > _len())
            throw vc::except_t(std::format("lua_vector _insert: index {} out of range (0..{})",
                    i, _len()));
        this->insert(this->begin() + i, std::move(val));
    }

    /*! Erases every element from `i` to `j` inclusive (both 1-indexed). _erase(i, i) removes just
    one. */
    void _erase(int i, int j) {
        if (i < 1 || j < i || j > _len())
            throw vc::except_t(std::format("lua_vector _erase: range {}..{} out of range (1..{})",
                    i, j, _len()));
        this->erase(this->begin() + (i - 1), this->begin() + j);
    }

    /*! Replaces the inclusive range i..j (1-indexed) with `vals` in one call - _erase(i,j) then
    insert `vals` at that spot, atomically. j == i-1 means "erase nothing, just insert before i". */
    void _replace(int i, int j, std::vector<T> vals) {
        if (i < 1 || i > _len() + 1 || j < i - 1 || j > _len())
            throw vc::except_t(std::format(
                    "lua_vector _replace: range {}..{} out of range (1..{})", i, j, _len()));
        this->erase(this->begin() + (i - 1), this->begin() + j);
        this->insert(this->begin() + (i - 1), vals.begin(), vals.end());
    }
};

/*! wref_t<T> - a weak, Lua-creatable reference to a T (T must derive from vc::object_t). Doesn't
keep the target alive - get_obj() returns an empty ref_t<T> if the target's already gone, instead of
a dangling access. One instantiation = one virt_composer object type - VIRT_COMPOSER_REGISTER_TYPE
hands out ids per named type, not per template instantiation, so each concrete T needs its own
type_id_static() specialization (see the mexpr_t one right below both templates). */
template <typename T>
struct wref_t : public vc::object_t {
    std::weak_ptr<T> o;

    wref_t(vc::object_t::Private priv) : vc::object_t(priv) {}
    virtual ~wref_t() {}

    static vc::object_type_e type_id_static(); // specialized per T
    virtual vc::object_type_e type_id() const override { return type_id_static(); }

    static vc::ref_t<wref_t<T>> create(vc::ref_t<T> target) {
        auto ret = std::make_shared<wref_t<T>>(vc::object_t::Private{type_id_static()});
        ret->o = target;
        return ret;
    }

    vc::ref_t<T> get_obj() const { return o.lock(); }

    inline virtual std::string to_string() const override {
        return std::format("wref[{}]: alive={}", (void *)this, !o.expired());
    }
};

template <>
inline vc::object_type_e wref_t<mexpr_t>::type_id_static() { return MEXPR_TYPE_WREF; }

/*! rref_t<T> - the raw-pointer counterpart to wref_t<T>: no weak_ptr control-block overhead, but
correspondingly no safety - get_obj() is only valid while the target is still guaranteed alive by
something else (e.g. still reachable from the tree root). Past that it's a plain dangling-pointer
read, same risk a bare T* always carries - prefer wref_t<T> unless that overhead is shown to
matter. */
template <typename T>
struct rref_t : public vc::object_t {
    T *o = nullptr;

    rref_t(vc::object_t::Private priv) : vc::object_t(priv) {}
    virtual ~rref_t() {}

    static vc::object_type_e type_id_static(); // specialized per T
    virtual vc::object_type_e type_id() const override { return type_id_static(); }

    static vc::ref_t<rref_t<T>> create(vc::ref_t<T> target) {
        auto ret = std::make_shared<rref_t<T>>(vc::object_t::Private{type_id_static()});
        ret->o = target.get();
        return ret;
    }

    /*! Upgrades the raw pointer back to a real ref_t<T> via object_t::to_related<T>() (itself
    shared_from_this()-based) - throws if `o` is null, or if the object it points to is no longer
    owned by any shared_ptr anywhere. Does NOT detect "freed and the memory reused" - still a plain
    dangling read in that case, same as any bare T*. */
    vc::ref_t<T> get_obj() const {
        if (!o)
            throw vc::except_t("rref_t::get_obj: target is null");
        return o->template to_related<T>();
    }

    inline virtual std::string to_string() const override {
        return std::format("rref[{}]: o={}", (void *)this, (void *)o);
    }
};

template <>
inline vc::object_type_e rref_t<mexpr_t>::type_id_static() { return MEXPR_TYPE_RREF; }

/*! How it works: If you where to draw this object as-is you would draw it at the baseline.
 * So let's take the character 'g', it's bounding box is slightly bellow the baseline and also
 * above the baseline. So assuming (0, 0) is on the baseline, the character would have it's
 * bounding box cut by the baseline.
 * 
 * As such, top left(tl) and bottom right(br) give us the bounding box of the object. While point
 * (0, 0) is the baseline for that object.
 * 
 * An object may have multiple subobjects, those having a position each.
 */
struct mexpr_t : public vc::object_t {
    /*! The type that this object will hold -> dictates what/how it is drawn */
    mexpr_e type = MEXPR_TYPE_INTERNAL;

    ImVec2 tl;                      /*!< Top Left */
    ImVec2 br;                      /*!< Bottom Right */

    /*! The subobjects of this object and their relative positions are stored in this - a
    lua_vector_t (not a plain std::vector) so anchor_set()/anchor_insert()/anchor_erase() below can
    mutate it directly, in place, instead of a caller rebuilding the whole node to change one
    child. */
    lua_vector_t<anchor_t> subobjs;

    uint32_t color = 0xff'eeeeee;   /*!< Optional Color of the object  */

    char_t symb;                    /*!< Optional symbol if this object is a leaf */
    ImVec2 symb_off;                /*!< Optional position of the symbol, such that it is drawn on
                                         it's baseline when drawn at (0, 0) */

    float line_width = 1.0f;        /*!< Optional, if type is line */
    lua_vector_t<ImVec2> line_strip; /*!< Optional, if type is MATHD_TYPE_LINE_STRIP */

    /*! Free slot for Lua to stash arbitrary data on this node (e.g. a back-reference to whichever
    row item this leaf corresponds to) - virt_composer/math_expr_composer never read or write this
    themselves, purely a courtesy hook. Needs lua_object_t's own capture()/push() to actually put a
    value in, not a bare assignment - see vc::lua_object_t's doc comment. */
    vc::ref_t<vc::lua_object_t> u;

    mexpr_t(vc::object_t::Private priv) : vc::object_t(priv) {}
    virtual ~mexpr_t() {}

    static vc::object_type_e type_id_static() { return MEXPR_TYPE_EXPR; }
    virtual vc::object_type_e type_id() const override { return MEXPR_TYPE_EXPR; }

    static vc::ref_t<mexpr_t> create(mexpr_e type) {
        auto ret = std::make_shared<mexpr_t>(vc::object_t::Private{type_id_static()});
        ret->type = type;
        ret->u = vc::lua_object_t::create(); // always a valid receiver for u:capture()/u:push()
        return ret;
    }

    inline virtual std::string to_string() const override {
        return std::format("mexpr::mexpr_t[{}] type: {}", (void *)this, (int)type);
    }

    std::tuple<mexpr_p, ImVec2> anchor_at(int i) const {
        auto a = subobjs._at(i); // bounds-checked, throws vc::except_t itself on a bad index
        return {a.obj, a.pos};
    }

    int anchor_len() const { return subobjs._len(); }
    void anchor_set(int i, mexpr_p obj, ImVec2 pos) { subobjs._set(i, anchor_t{obj, pos}); }
    void anchor_insert(int i, mexpr_p obj, ImVec2 pos) { subobjs._insert(i, anchor_t{obj, pos}); }
    void anchor_erase(int i, int j) { subobjs._erase(i, j); }

    int line_strip_len() const { return line_strip._len(); }
    ImVec2 line_strip_at(int i) const { return line_strip._at(i); }
    void line_strip_set(int i, ImVec2 p) { line_strip._set(i, p); }
    void line_strip_insert(int i, ImVec2 p) { line_strip._insert(i, p); }
    void line_strip_erase(int i, int j) { line_strip._erase(i, j); }
};

} /* math_expr_composer */

namespace math_expr_composer {

inline mexpr_bb_t mexpr_get_bb(mexpr_p m) {
    if (!m)
        return mexpr_bb_t{};
    return mexpr_bb_t{m->tl, m->br};
}

/* TODO: instead of fontset_t, create a context_t that will be used in all the drawing functions.
This context should have the fontset as well as required distancers and sizes */
inline void mexpr_draw(vc::ref_t<charc::fontset_t> fs, ImVec2 pos, mexpr_p m, bool draw_bb);
inline mexpr_p mexpr_empty(vc::ref_t<charc::fontset_t> fs, float x, float y, float above_bl);
inline mexpr_p mexpr_symbol(vc::ref_t<charc::fontset_t> fs, char_t sym, bool is_char);
inline mexpr_p mexpr_bigop(vc::ref_t<charc::fontset_t> fs, mexpr_p right, mexpr_p above,
        mexpr_p bellow, char_t bigop);
inline mexpr_p mexpr_frac(vc::ref_t<charc::fontset_t> fs, mexpr_p above, mexpr_p bellow,
        char_t divline);
inline mexpr_p mexpr_supsub(vc::ref_t<charc::fontset_t> fs, mexpr_p base, mexpr_p sup, mexpr_p sub);
inline mexpr_p mexpr_bracket(vc::ref_t<charc::fontset_t> fs, mexpr_p expr, mexpr_bracket_t bracket);
inline mexpr_p mexpr_unarexpr(vc::ref_t<charc::fontset_t> fs, char_t op, mexpr_p b);
inline mexpr_p mexpr_binexpr(vc::ref_t<charc::fontset_t> fs, mexpr_p a, char_t op, mexpr_p b);
inline mexpr_p mexpr_merge_h(vc::ref_t<charc::fontset_t> fs, mexpr_p l, mexpr_p r);
inline mexpr_p mexpr_merge_v(vc::ref_t<charc::fontset_t> fs, mexpr_p u, mexpr_p d);

/* TODO: matrix stuff */

/* IMPLEMENTATION
 * =================================================================================================
 */

inline int register_meta(vc::virt_state_t *vs) {
    DBG_SCOPE();

    VC_REGISTER_MEMBER_OBJECT(vs, mexpr_t, type);
    VC_REGISTER_MEMBER_OBJECT(vs, mexpr_t, color);
    VC_REGISTER_MEMBER_OBJECT(vs, mexpr_t, line_width);
    VC_REGISTER_MEMBER_OBJECT(vs, mexpr_t, u);
    VC_REGISTER_MEMBER_OBJECT(vs, mexpr_t, symb);
    VC_REGISTER_MEMBER_OBJECT(vs, mexpr_t, symb_off);
    VC_REGISTER_MEMBER_FUNCTION(vs, mexpr_t, anchor_len);
    VC_REGISTER_MEMBER_FUNCTION(vs, mexpr_t, anchor_at, int);
    VC_REGISTER_MEMBER_FUNCTION(vs, mexpr_t, anchor_set, int, mexpr_p, ImVec2);
    VC_REGISTER_MEMBER_FUNCTION(vs, mexpr_t, anchor_insert, int, mexpr_p, ImVec2);
    VC_REGISTER_MEMBER_FUNCTION(vs, mexpr_t, anchor_erase, int, int);
    VC_REGISTER_MEMBER_FUNCTION(vs, mexpr_t, line_strip_len);
    VC_REGISTER_MEMBER_FUNCTION(vs, mexpr_t, line_strip_at, int);
    VC_REGISTER_MEMBER_FUNCTION(vs, mexpr_t, line_strip_set, int, ImVec2);
    VC_REGISTER_MEMBER_FUNCTION(vs, mexpr_t, line_strip_insert, int, ImVec2);
    VC_REGISTER_MEMBER_FUNCTION(vs, mexpr_t, line_strip_erase, int, int);

    VC_REGISTER_MEMBER_FUNCTION(vs, wref_t<mexpr_t>, get_obj);
    VC_REGISTER_MEMBER_FUNCTION(vs, rref_t<mexpr_t>, get_obj);

    std::vector<luaL_Reg> mexpr_tab_funcs = {
        { "wref_mexpr", vc::luaw_function_wrapper<wref_t<mexpr_t>::create, mexpr_p>
        },
        { "rref_mexpr", vc::luaw_function_wrapper<rref_t<mexpr_t>::create, mexpr_p>
        },
        { "mexpr_draw", vc::luaw_function_wrapper<mexpr_draw,
                vc::ref_t<charc::fontset_t>, ImVec2, mexpr_p, bool>
        },
        { "mexpr_empty", vc::luaw_function_wrapper<mexpr_empty,
                vc::ref_t<charc::fontset_t>, float, float, float>
        },
        { "mexpr_symbol", vc::luaw_function_wrapper<mexpr_symbol,
                vc::ref_t<charc::fontset_t>, char_t, bool> 
        },
        { "mexpr_bigop", vc::luaw_function_wrapper<mexpr_bigop,
                vc::ref_t<charc::fontset_t>, mexpr_p, mexpr_p, mexpr_p, char_t>
        },
        { "mexpr_frac", vc::luaw_function_wrapper<mexpr_frac,
                vc::ref_t<charc::fontset_t>, mexpr_p, mexpr_p, char_t>
        },
        { "mexpr_supsub", vc::luaw_function_wrapper<mexpr_supsub,
                vc::ref_t<charc::fontset_t>, mexpr_p, mexpr_p, mexpr_p>
        },
        { "mexpr_bracket", vc::luaw_function_wrapper<mexpr_bracket,
                vc::ref_t<charc::fontset_t>, mexpr_p, mexpr_bracket_t>
        },
        { "mexpr_unarexpr", vc::luaw_function_wrapper<mexpr_unarexpr,
                vc::ref_t<charc::fontset_t>, char_t, mexpr_p>
        },
        { "mexpr_binexpr", vc::luaw_function_wrapper<mexpr_binexpr,
                vc::ref_t<charc::fontset_t>, mexpr_p, char_t, mexpr_p>
        },
        { "mexpr_merge_h", vc::luaw_function_wrapper<mexpr_merge_h,
                vc::ref_t<charc::fontset_t>, mexpr_p, mexpr_p>
        },
        { "mexpr_merge_v", vc::luaw_function_wrapper<mexpr_merge_v,
                vc::ref_t<charc::fontset_t>, mexpr_p, mexpr_p>
        },
        { "mexpr_get_bb", vc::luaw_function_wrapper<mexpr_get_bb, mexpr_p>
        },
    };

    vc::add_lua_flag_mapping(vs, vc::mexpr_bracket_from_str);
    vc::add_lua_flag_mapping(vs, vc::mexpr_e_from_str);

    ASSERT_FN(add_lua_tab_funcs(vs, mexpr_tab_funcs));
    return vc::VC_ERROR_OK;
}


#define MEXPR_DISTANCER         4
#define MEXPR_DISTANCER_BIGO    0.5

struct draw_info_t {
    float startx;
    float skipy;
    float edge;
};

/* TODO: figure out selection, ie, how to select objects, stuff and how to select those objects
in the wrapped things:

OBS: potential solution, draw coliders twice, one colider on the edge and one after the edge,
as such, we get the boest of both worlds */

inline void mexpr_draw_rec(vc::ref_t<charc::fontset_t> fs, ImVec2 pos, mexpr_p m, bool draw_bb,
        draw_info_t *di);

inline void mexpr_draw(vc::ref_t<charc::fontset_t> fs, ImVec2 pos, mexpr_p m, bool draw_bb) {
    auto *io = &ImGui::GetIO();
    draw_info_t di {
        .startx = pos.x,
        .skipy = m->br.y - m->tl.y,
        .edge = io->DisplaySize.x,
    };
    mexpr_draw_rec(fs, pos, m, draw_bb, &di);
}

inline void mexpr_draw_rec(vc::ref_t<charc::fontset_t> fs, ImVec2 pos, mexpr_p m, bool draw_bb,
        draw_info_t *di)
{
    ImDrawList* draw_list = ImGui::GetWindowDrawList();
    if (!m)
        return ;
    ImVec2 bb_tl = pos + m->tl;
    ImVec2 bb_br = pos + m->br;
    ImVec2 offpos = pos;

    bool draw_twice = false;
    ImVec2 bb_tl2;
    ImVec2 bb_br2;
    ImVec2 offpos2;

    while (bb_tl.x > di->edge || bb_br.x > di->edge) {
        if (bb_tl.x <= di->edge && bb_br.x > di->edge) {
            bb_tl2 = bb_tl;
            bb_br2 = bb_br;
            offpos2 = offpos;
            draw_twice = true;
        }
        auto adj = ImVec2(-(di->edge-di->startx), di->skipy);
        bb_tl += adj;
        bb_br += adj;
        offpos += adj;
    }

    if (draw_bb) {
        draw_list->AddRect(bb_tl, bb_br, 0xff'ffff00);
        draw_list->AddCircleFilled(offpos, 3, 0xff'ff00ff);
        if (draw_twice) {
            draw_list->AddRect(bb_tl2, bb_br2, 0xff'ffff00);
            draw_list->AddCircleFilled(offpos2, 3, 0xff'ff00ff);
        }
    }

    switch (m->type) {
        case MEXPR_TYPE_SYMBOL: {
            fs->char_draw(m->symb, offpos + m->symb_off, m->color, 0, 0);
        } break;
        case MEXPR_TYPE_LINE_STRIP: {
            for (int i = 1; i < m->line_strip.size(); i++) {
                draw_list->AddLine(offpos + m->line_strip[i-1], offpos + m->line_strip[i], m->color,
                        m->line_width);
            }
        } break;
        case MEXPR_TYPE_EMPTY_BOX: {
            if (draw_bb) {
                draw_list->AddRectFilled(bb_tl, bb_br, 0xff'aaaaaa, 15);
                if (draw_twice)
                    draw_list->AddRectFilled(bb_tl2, bb_br2, 0xff'aaaaaa, 15);
            }
        } break;
        case MEXPR_TYPE_INTERNAL: {
            for (auto &anch : m->subobjs) {
                if (draw_bb) {
                    draw_list->AddLine(offpos, offpos + anch.pos, 0xff'00ff00);
                    if (draw_twice)
                        draw_list->AddLine(offpos2, offpos2 + anch.pos, 0xff'00ff00);
                }
                mexpr_draw_rec(fs, pos + anch.pos, anch.obj, draw_bb, di);
            }
        } break;
    }
}

inline mexpr_p mexpr_empty(vc::ref_t<charc::fontset_t> fs, float x, float y, float above_bl) {
    auto ret = mexpr_t::create(MEXPR_TYPE_EMPTY_BOX);
    ret->tl = ImVec2(0, 0 - above_bl);
    ret->br = ImVec2(x, y - above_bl);
    return ret;
}

inline mexpr_p mexpr_symbol(vc::ref_t<charc::fontset_t> fs, char_t sym, bool is_char) {
    auto [tl, br] = fs->char_get_bb(sym);

    auto ret = mexpr_t::create(MEXPR_TYPE_SYMBOL);
    ret->symb = sym;
    if (is_char) {
        /* For characters in general we want them to stay on the same baseline as 'a',
        more precisely the baseline passes through the middle of a */
        auto [a_tl, a_br] = fs->char_get_bb(char_t{.size=sym.size, .code=fs->m_a_code});
        ret->symb_off = ImVec2(0, -a_br.y + (a_br.y - a_tl.y) / 2.);
    }
    else {
        /* For bigsum or integral sign we want it to be centered on the baseline */
        ret->symb_off = ImVec2(0, -(tl.y + br.y) / 2.);
    }
    ret->tl = tl + ret->symb_off;
    ret->br = br + ret->symb_off;
    return ret;
}

inline float get_font_mul(vc::ref_t<charc::fontset_t> fs, char_t c) {
    auto sz = fs->char_get_bb(char_t{ .size=c.size, .code=fs->m_a_code });
    return (sz.a_max.y - sz.a_min.y) / 10.0f;
}

inline std::pair<ImVec2, ImVec2> calc_bb(const std::vector<anchor_t>& anchors) {
    if (anchors.size() == 0)
        return {ImVec2(0, 0), ImVec2(0, 0)};
    auto tl = anchors[0].pos + anchors[0].obj->tl;
    auto br = anchors[0].pos + anchors[0].obj->br;
    for (auto &a : anchors) {
        tl.x = std::min(tl.x, a.pos.x + a.obj->tl.x);
        tl.y = std::min(tl.y, a.pos.y + a.obj->tl.y);
        br.x = std::max(br.x, a.pos.x + a.obj->br.x);
        br.y = std::max(br.y, a.pos.y + a.obj->br.y);
    }
    return {tl, br};
}

inline ImVec2 calc_sz(ImVec2 tl, ImVec2 br) { return ImVec2(br.x - tl.x, br.y - tl.y); }
inline ImVec2 calc_sz(mexpr_p m)            { return calc_sz(m->tl, m->br); }

inline mexpr_p mexpr_bigop(vc::ref_t<charc::fontset_t> fs,
        mexpr_p right, mexpr_p above, mexpr_p bellow, char_t bigop)
{
    /* OBS: 1. a random distance is used to delimit above and bellow
            2. above and bellow don't stay nicely on integral big op
            3. the integral operator is to far from `right`, the operand */
    if (!right)
        throw vc::except_t("can't use mexpr_bigop without right");
    if (!above)
        above = mexpr_t::create(MEXPR_TYPE_EMPTY_BOX);
    if (!bellow)
        bellow = mexpr_t::create(MEXPR_TYPE_EMPTY_BOX);

    float dst = MEXPR_DISTANCER_BIGO * get_font_mul(fs, bigop);
    auto ret = mexpr_t::create(MEXPR_TYPE_INTERNAL);
    auto op = mexpr_symbol(fs, bigop, false);

    auto sz_above = calc_sz(above);
    auto sz_bellow = calc_sz(bellow);
    auto sz_op = calc_sz(op);

    ret->subobjs = std::vector<anchor_t> {
        { .obj = op,     .pos = ImVec2(0, 0) },
        { .obj = above,  .pos = ImVec2( -sz_above.x/2. + sz_op.x/2., op->tl.y - above->br.y - dst) },
        { .obj = bellow, .pos = ImVec2(-sz_bellow.x/2. + sz_op.x/2., op->br.y - bellow->tl.y + dst) },
        { .obj = right,  .pos = ImVec2(op->br.x, 0) },
    };

    std::tie(ret->tl, ret->br) = calc_bb(ret->subobjs);
    return ret;
}

inline mexpr_p mexpr_frac(vc::ref_t<charc::fontset_t> fs,
        mexpr_p above, mexpr_p bellow, char_t divline)
{
    /* OBS: 1. divline is not actually used, only it's height
            2. a random distance is used to calc the distance from the line and additional 
               width of the fraction line */
    if (!bellow || !above)
        throw vc::except_t("can't use mexpr_frac without both ops");

    float dst = MEXPR_DISTANCER * get_font_mul(fs, divline);
    auto sz_above = calc_sz(above);
    auto sz_bellow = calc_sz(bellow);
    float sz_frac_x = std::max(sz_above.x, sz_bellow.x) + 2*dst;

    auto ret = mexpr_t::create(MEXPR_TYPE_INTERNAL);

    auto dl = mexpr_t::create(MEXPR_TYPE_LINE_STRIP);
    auto tmp_div = mexpr_symbol(fs, divline, false);
    dl->tl = ImVec2(0, tmp_div->tl.y);
    dl->br = ImVec2(sz_frac_x, tmp_div->br.y);
    /* TODO: to enable spliting fractions we need to make the fractions line from multiple smaller
    lines in multiple different objects */
    dl->line_strip.push_back(ImVec2(0, 0));
    dl->line_strip.push_back(ImVec2(sz_frac_x, 0));
    dl->line_width = (tmp_div->br.y - tmp_div->tl.y);

    ret->subobjs = std::vector<anchor_t> {
        { .obj = above,   .pos = ImVec2((sz_frac_x - sz_above.x)/2., -above->br.y - dst) },
        { .obj = bellow,  .pos = ImVec2((sz_frac_x - sz_bellow.x)/2., -bellow->tl.y + dst) },
        { .obj = dl,      .pos = ImVec2(0, 0) }
    };

    std::tie(ret->tl, ret->br) = calc_bb(ret->subobjs);
    return ret;
}

/*       -#####
          #   #
          # E #
         +#   #
 #####-   #   #
 #   #   =#####
 #   #
+# B #
 #   #
 #   #
 #####

The idea is that we want to match the superscript's baseline (E+) with that of the base's top (B-)
if possible.

The exponent must be at least 2/5 of the base above the base's bottom.
Mirrored for subscripts.
*/
inline mexpr_p mexpr_supsub(vc::ref_t<charc::fontset_t> fs,
        mexpr_p base, mexpr_p sup, mexpr_p sub)
{
    /* OBS: 1. the y placement of sub/sup are chosen at random */
    if (!base)
        throw vc::except_t("can't use mexpr_supsub without a base");

    auto ret = mexpr_t::create(MEXPR_TYPE_INTERNAL);
    auto sz_base = calc_sz(base);

    ret->subobjs.push_back(anchor_t{ .obj = base, .pos = ImVec2(0, 0) });

    if (sup) {
        auto sz_sup = calc_sz(sup);
        float yoff = base->tl.y;

        /* Correction for the case in which the exponent shadows to much of the base */
        if (base->br.y - (sup->br.y + yoff) < sz_base.y*3./5.)
            yoff = base->tl.y - sup->br.y + sz_base.y*2./5;

        ret->subobjs.push_back(anchor_t{ .obj = sup, .pos = ImVec2(base->br.x, yoff) });
    }

    if (sub) {
        auto sz_sub = calc_sz(sub);
        float yoff = base->br.y;

        if ((sub->tl.y + yoff) - base->tl.y < sz_base.y*3./5.)
            yoff = base->br.y - sub->tl.y - sz_base.y*2./5.;

        ret->subobjs.push_back(anchor_t{ .obj = sub, .pos = ImVec2(base->br.x, yoff) });
    }

    std::tie(ret->tl, ret->br) = calc_bb(ret->subobjs);
    return ret;
}

inline mexpr_p mexpr_unarexpr(vc::ref_t<charc::fontset_t> fs, char_t op, mexpr_p a) {
    float dst = MEXPR_DISTANCER / 2. * get_font_mul(fs, op);
    auto ret = mexpr_t::create(MEXPR_TYPE_INTERNAL);
    auto op_sym = mexpr_symbol(fs, op, true);

    ret->subobjs = std::vector<anchor_t> {
        { .obj = op_sym, .pos = ImVec2(0, 0) },
        { .obj = a,      .pos = ImVec2(dst + op_sym->br.x, 0) },
    };

    std::tie(ret->tl, ret->br) = calc_bb(ret->subobjs);
    return ret;
}

inline mexpr_p mexpr_binexpr(vc::ref_t<charc::fontset_t> fs, mexpr_p a, char_t op, mexpr_p b) {
    float dst = MEXPR_DISTANCER * get_font_mul(fs, op);
    auto ret = mexpr_t::create(MEXPR_TYPE_INTERNAL);

    auto op_sym = mexpr_symbol(fs, op, true);

    ret->subobjs = std::vector<anchor_t> {
        { .obj = a,      .pos = ImVec2(0, 0) },
        { .obj = op_sym, .pos = ImVec2(dst + a->br.x , 0) },
        { .obj = b,      .pos = ImVec2(dst + a->br.x + dst + op_sym->br.x, 0) },
    };

    auto [tl, br] = calc_bb(ret->subobjs);
    ret->tl = tl;
    ret->br = br;
    return ret;
}

inline mexpr_p mexpr_merge_h(vc::ref_t<charc::fontset_t> fs, mexpr_p l, mexpr_p r) {
    auto ret = mexpr_t::create(MEXPR_TYPE_INTERNAL);

    ret->subobjs = std::vector<anchor_t> {
        { .obj = l, .pos = ImVec2(0, 0) },
        { .obj = r, .pos = ImVec2(l->br.x, 0) },
    };

    std::tie(ret->tl, ret->br) = calc_bb(ret->subobjs);
    return ret;
}

/* TODO: of interest about this one is the fact that to build a matrix, column vector or as such from
it we may want to either balance out the elements or create a new function accepting a vector. This
problem doesn't seem to appear inside the hmerge */
inline mexpr_p mexpr_merge_v(vc::ref_t<charc::fontset_t> fs, mexpr_p u, mexpr_p d) {
    auto ret = mexpr_t::create(MEXPR_TYPE_INTERNAL);

    ret->subobjs = std::vector<anchor_t> {
        { .obj = u, .pos = ImVec2(0, -u->br.y) },
        { .obj = d, .pos = ImVec2(0, -d->tl.y) },
    };

    std::tie(ret->tl, ret->br) = calc_bb(ret->subobjs);
    return ret;
}

/* This is taken from ImGui and transformed to fit my needs */
inline void beziere_path_rec(std::vector<ImVec2>& path, ImVec2 P1, ImVec2 P2, ImVec2 P3, ImVec2 P4,
        int level = 0)
{
    static const float tess_tol = 1.25f;
    float dx = P4.x - P1.x;
    float dy = P4.y - P1.y;
    float d2 = (P2.x - P4.x) * dy - (P2.y - P4.y) * dx;
    float d3 = (P3.x - P4.x) * dy - (P3.y - P4.y) * dx;
    d2 = (d2 >= 0) ? d2 : -d2;
    d3 = (d3 >= 0) ? d3 : -d3;
    if ((d2 + d3) * (d2 + d3) < tess_tol * (dx * dx + dy * dy))
    {
        path.push_back(ImVec2(P4.x, P4.y));
    }
    else if (level < 10)
    {
        float x12 = (P1.x + P2.x) * 0.5f, y12 = (P1.y + P2.y) * 0.5f;
        float x23 = (P2.x + P3.x) * 0.5f, y23 = (P2.y + P3.y) * 0.5f;
        float x34 = (P3.x + P4.x) * 0.5f, y34 = (P3.y + P4.y) * 0.5f;
        float x123 = (x12 + x23) * 0.5f, y123 = (y12 + y23) * 0.5f;
        float x234 = (x23 + x34) * 0.5f, y234 = (y23 + y34) * 0.5f;
        float x1234 = (x123 + x234) * 0.5f, y1234 = (y123 + y234) * 0.5f;
        beziere_path_rec(path, P1, ImVec2(x12, y12), ImVec2(x123, y123), ImVec2(x1234, y1234), level + 1);
        beziere_path_rec(path, ImVec2(x1234, y1234), ImVec2(x234, y234), ImVec2(x34, y34), P4, level + 1);
    }
}

inline mexpr_p mexpr_bracket(vc::ref_t<charc::fontset_t> fs, mexpr_p expr, mexpr_bracket_t bracket) {
    auto sym_h = [&](char_t sym) {
        return fs->char_get_bb(sym).a_max.y - fs->char_get_bb(sym).a_min.y;
    };

    float sz_threshold = 1.1;
    auto expr_sz = calc_sz(expr);

    auto calc_tl = [](const std::vector<ImVec2>& points) {
        ImVec2 tl = points[0];
        for (auto &p : points) {
            tl.x = std::min(p.x, tl.x);
            tl.y = std::min(p.y, tl.y);
        }
        return tl;
    };
    auto calc_br = [](const std::vector<ImVec2>& points) {
        ImVec2 br = points[0];
        for (auto &p : points) {
            br.x = std::max(p.x, br.x);
            br.y = std::max(p.y, br.y);
        }
        return br;
    };
    auto offset_all = [](std::vector<ImVec2>& points, ImVec2 off) {
        for (auto &p : points)
            p += off;
    };

    /* First we need to select the appropiate paranthesis dimension for the expression and construct
    the paranthesis objects */
    mexpr_p lb, rb;
    if (sym_h(bracket.left[3]) > expr_sz.y * sz_threshold) {
        lb = mexpr_symbol(fs, bracket.left[3], false);
        rb = mexpr_symbol(fs, bracket.right[3], false);
    }
    else if (sym_h(bracket.left[2]) > expr_sz.y * sz_threshold) {
        lb = mexpr_symbol(fs, bracket.left[2], false);
        rb = mexpr_symbol(fs, bracket.right[2], false);
    }
    else if (sym_h(bracket.left[1]) > expr_sz.y * sz_threshold) {
        lb = mexpr_symbol(fs, bracket.left[1], false);
        rb = mexpr_symbol(fs, bracket.right[1], false);
    }
    else if (sym_h(bracket.left[0]) > expr_sz.y * sz_threshold) {
        lb = mexpr_symbol(fs, bracket.left[0], false);
        rb = mexpr_symbol(fs, bracket.right[0], false);
    }
    else {
        lb = mexpr_t::create(MEXPR_TYPE_INTERNAL);
        rb = mexpr_t::create(MEXPR_TYPE_INTERNAL);

        auto lb_tl_sz = calc_sz(mexpr_symbol(fs, bracket.tl,   false));
        auto lb_bl_sz = calc_sz(mexpr_symbol(fs, bracket.bl,   false));
        auto lb_cl_sz = calc_sz(mexpr_symbol(fs, bracket.cl,   false));
        auto rb_tr_sz = calc_sz(mexpr_symbol(fs, bracket.tr,   false));
        auto rb_br_sz = calc_sz(mexpr_symbol(fs, bracket.br,   false));
        auto rb_cr_sz = calc_sz(mexpr_symbol(fs, bracket.cr,   false));
        auto conl_sz  = calc_sz(mexpr_symbol(fs, bracket.conl, false));
        auto conr_sz  = calc_sz(mexpr_symbol(fs, bracket.conr, false));

        float sz = lb_tl_sz.y + lb_cl_sz.y + lb_bl_sz.y;
        int con_cnt = 0;
        if (sz < expr_sz.y) {
            con_cnt = std::ceil((expr_sz.y - sz) / (conl_sz.y));
            if (con_cnt % 2 == 1)
                con_cnt++;
        }

        float h = 0;
        if (bracket.type == MEXPR_BRACKET_SQUARE) {
            h = lb_tl_sz.y + lb_bl_sz.y + lb_cl_sz.y + con_cnt * conl_sz.y;
            auto lines_l = mexpr_t::create(MEXPR_TYPE_LINE_STRIP);
            auto [a_min, a_max] = fs->char_get_bb(bracket.tl);
            float minx = a_min.x;
            lines_l->line_strip.push_back(ImVec2(a_max.x - minx, 0));
            lines_l->line_strip.push_back(ImVec2(a_min.x - minx, 0));
            lines_l->line_strip.push_back(ImVec2(a_min.x - minx, h));
            lines_l->line_strip.push_back(ImVec2(a_max.x - minx, h));
            lines_l->line_width = conl_sz.x;
            lines_l->color = 0xff'eeeeee;
            offset_all(lines_l->line_strip, ImVec2(0, -h/2.));
            lines_l->tl = calc_tl(lines_l->line_strip);
            lines_l->br = calc_br(lines_l->line_strip);
            lb->subobjs.push_back({lines_l, ImVec2(0, 0)});

            auto lines_r = mexpr_t::create(MEXPR_TYPE_LINE_STRIP);
            auto [b_min, b_max] = fs->char_get_bb(bracket.tr);
            minx = b_min.x;
            lines_r->line_strip.push_back(ImVec2(b_min.x - minx, 0));
            lines_r->line_strip.push_back(ImVec2(b_max.x - minx, 0));
            lines_r->line_strip.push_back(ImVec2(b_max.x - minx, h));
            lines_r->line_strip.push_back(ImVec2(b_min.x - minx, h));
            lines_r->line_width = conl_sz.x;
            lines_r->color = 0xff'eeeeee;
            offset_all(lines_r->line_strip, ImVec2(0, -h/2.));
            lines_r->tl = calc_tl(lines_r->line_strip);
            lines_r->br = calc_br(lines_r->line_strip);
            rb->subobjs.push_back({lines_r, ImVec2(0, 0)});
            std::tie(lb->tl, lb->br) = calc_bb(lb->subobjs);
            std::tie(rb->tl, rb->br) = calc_bb(rb->subobjs);
        }
        else if (bracket.type == MEXPR_BRACKET_ROUND) {
            h = lb_tl_sz.y + lb_bl_sz.y + lb_cl_sz.y + con_cnt * conl_sz.y;
            auto lines_l = mexpr_t::create(MEXPR_TYPE_LINE_STRIP);
            auto [a_min, a_max] = fs->char_get_bb(bracket.tl);
            float minx = a_min.x;
            lines_l->line_strip.push_back(ImVec2(a_max.x - minx, 0));
            beziere_path_rec(lines_l->line_strip,
                    ImVec2(a_max.x - minx, 0),
                    ImVec2((a_max.x + a_min.x) / 2. - minx, lb_tl_sz.y / 8.),
                    ImVec2(a_min.x - minx, lb_tl_sz.y / 8. * 3.),
                    ImVec2(a_min.x - minx, lb_tl_sz.y));
            lines_l->line_strip.push_back(ImVec2(a_min.x - minx, lb_tl_sz.y));
            beziere_path_rec(lines_l->line_strip,
                    ImVec2(a_min.x - minx, h - lb_bl_sz.y),
                    ImVec2(a_min.x - minx, h - lb_bl_sz.y / 8. * 3.),
                    ImVec2((a_min.x + a_max.x) / 2. - minx, h - lb_bl_sz.y / 8.),
                    ImVec2(a_max.x - minx, h));
            lines_l->line_width = conl_sz.x;
            lines_l->color = 0xff'eeeeee;
            offset_all(lines_l->line_strip, ImVec2(0, -h/2.));
            lines_l->tl = calc_tl(lines_l->line_strip);
            lines_l->br = calc_br(lines_l->line_strip);
            lb->subobjs.push_back({lines_l, ImVec2(0, 0)});

            auto lines_r = mexpr_t::create(MEXPR_TYPE_LINE_STRIP);
            auto [b_min, b_max] = fs->char_get_bb(bracket.tr);
            minx = b_min.x;
            lines_r->line_strip.push_back(ImVec2(b_min.x - minx, 0));
            beziere_path_rec(lines_r->line_strip,
                    ImVec2(b_min.x - minx, 0),
                    ImVec2((b_min.x + b_max.x) / 2. - minx, rb_tr_sz.y / 8.),
                    ImVec2(b_max.x - minx, rb_tr_sz.y / 8. * 3.),
                    ImVec2(b_max.x - minx, rb_tr_sz.y));
            lines_r->line_strip.push_back(ImVec2(b_max.x - minx, rb_tr_sz.y));
            beziere_path_rec(lines_r->line_strip,
                    ImVec2(b_max.x - minx, h - rb_br_sz.y),
                    ImVec2(b_max.x - minx, h - rb_br_sz.y / 8. * 3.),
                    ImVec2((b_max.x + b_min.x) / 2. - minx, h - rb_br_sz.y / 8.),
                    ImVec2(b_min.x - minx, h));
            lines_r->line_width = conr_sz.x;
            lines_r->color = 0xff'eeeeee;
            offset_all(lines_r->line_strip, ImVec2(0, -h/2.));
            lines_r->tl = calc_tl(lines_r->line_strip);
            lines_r->br = calc_br(lines_r->line_strip);
            rb->subobjs.push_back({lines_r, ImVec2(0, 0)});
            std::tie(lb->tl, lb->br) = calc_bb(lb->subobjs);
            std::tie(rb->tl, rb->br) = calc_bb(rb->subobjs);
        }
        else if (bracket.type == MEXPR_BRACKET_CURLY) {
            h = lb_tl_sz.y + lb_bl_sz.y + lb_cl_sz.y + con_cnt * conl_sz.y;
            float h2 = h / 2.;
            auto [a_min, a_max] = fs->char_get_bb(bracket.tl);
            auto [b_min, b_max] = fs->char_get_bb(bracket.cl);
            auto [c_min, c_max] = fs->char_get_bb(bracket.bl);

            float minx = std::min({a_min.x, b_min.x, c_min.x});

            auto lines_l = mexpr_t::create(MEXPR_TYPE_LINE_STRIP);
            lines_l->line_strip.push_back(ImVec2(a_max.x - minx, 0));
            beziere_path_rec(lines_l->line_strip,
                    ImVec2(a_max.x - minx, 0),
                    ImVec2(a_min.x * 0.75 + a_max.x * 0.25 - minx, 0),
                    ImVec2(a_min.x - minx, lb_tl_sz.y * 0.25),
                    ImVec2(a_min.x - minx, lb_tl_sz.y));
            lines_l->line_strip.push_back(ImVec2(b_max.x - minx, h2 - lb_cl_sz.y * 0.5));
            beziere_path_rec(lines_l->line_strip,
                    ImVec2(b_max.x - minx, h2 - lb_cl_sz.y * 0.5),
                    ImVec2(b_max.x - minx, h2 + lb_cl_sz.y * (.75 * .5 - .5)),
                    ImVec2(b_max.x * 0.75 + b_min.x * 0.25 - minx, h2),
                    ImVec2(b_min.x - minx, h2));
            lines_l->line_strip.push_back(ImVec2(b_min.x - minx, h2));
            beziere_path_rec(lines_l->line_strip,
                    ImVec2(b_min.x - minx, h2),
                    ImVec2(b_min.x * .25 + b_max.x * .75 - minx, h2),
                    ImVec2(b_max.x - minx, h2 + lb_cl_sz.y * .75 * .5),
                    ImVec2(b_max.x - minx, h2 + lb_cl_sz.y * .5));
            lines_l->line_strip.push_back(ImVec2(c_min.x - minx, h - lb_bl_sz.y));
            beziere_path_rec(lines_l->line_strip,
                    ImVec2(c_min.x - minx, h - lb_bl_sz.y),
                    ImVec2(c_min.x - minx, h - lb_bl_sz.y * .25),
                    ImVec2(c_min.x * .75 + c_max.x * .25 - minx, h),
                    ImVec2(c_max.x - minx, h));
            lines_l->color = 0xff'eeeeee;
            lines_l->line_width = conl_sz.x;
            offset_all(lines_l->line_strip, ImVec2(0, -h/2.));
            lines_l->tl = calc_tl(lines_l->line_strip);
            lines_l->br = calc_br(lines_l->line_strip);
            lb->subobjs.push_back({lines_l, ImVec2(0, 0)});

            auto [d_min, d_max] = fs->char_get_bb(bracket.tr);
            auto [e_min, e_max] = fs->char_get_bb(bracket.cr);
            auto [f_min, f_max] = fs->char_get_bb(bracket.br);

            minx = std::min({d_min.x, e_min.x, f_min.x});

            auto lines_r = mexpr_t::create(MEXPR_TYPE_LINE_STRIP);
            lines_r->line_strip.push_back(ImVec2(d_min.x - minx, 0));
            beziere_path_rec(lines_r->line_strip,
                    ImVec2(d_min.x - minx, 0),
                    ImVec2(d_max.x * 0.75 + d_min.x * 0.25 - minx, 0),
                    ImVec2(d_max.x - minx, rb_tr_sz.y * 0.25),
                    ImVec2(d_max.x - minx, rb_tr_sz.y));
            lines_r->line_strip.push_back(ImVec2(e_min.x - minx, h2 - rb_cr_sz.y * 0.5));
            beziere_path_rec(lines_r->line_strip,
                    ImVec2(e_min.x - minx, h2 - rb_cr_sz.y * 0.5),
                    ImVec2(e_min.x - minx, h2 + rb_cr_sz.y * (.75 * .5 - .5)),
                    ImVec2(e_min.x * 0.75 + e_max.x * 0.25 - minx, h2),
                    ImVec2(e_max.x - minx, h2));
            lines_r->line_strip.push_back(ImVec2(e_max.x - minx, h2));
            beziere_path_rec(lines_r->line_strip,
                    ImVec2(e_max.x - minx, h2),
                    ImVec2(e_max.x * .25 + e_min.x * .75 - minx, h2),
                    ImVec2(e_min.x - minx, h2 + rb_cr_sz.y * .75 * .5),
                    ImVec2(e_min.x - minx, h2 + rb_cr_sz.y * .5));
            lines_r->line_strip.push_back(ImVec2(f_max.x - minx, h - rb_br_sz.y));
            beziere_path_rec(lines_r->line_strip,
                    ImVec2(f_max.x - minx, h - rb_br_sz.y),
                    ImVec2(f_max.x - minx, h - rb_br_sz.y * .25),
                    ImVec2(f_max.x * .75 + f_min.x * .25 - minx, h),
                    ImVec2(f_min.x - minx, h));
            lines_r->color = 0xff'eeeeee;
            lines_r->line_width = conr_sz.x;
            offset_all(lines_r->line_strip, ImVec2(0, -h/2.));
            lines_r->tl = calc_tl(lines_r->line_strip);
            lines_r->br = calc_br(lines_r->line_strip);
            rb->subobjs.push_back({lines_r, ImVec2(0, 0)});
            std::tie(lb->tl, lb->br) = calc_bb(lb->subobjs);
            std::tie(rb->tl, rb->br) = calc_bb(rb->subobjs);
        }
    }

    auto lb_sz = calc_sz(lb);
    auto rb_sz = calc_sz(rb);

    float dst = MEXPR_DISTANCER * 2 * get_font_mul(fs, bracket.left[0]);
    auto ret = mexpr_t::create(MEXPR_TYPE_INTERNAL);

    float h = (expr->tl.y + expr->br.y) / 2.;
    ret->subobjs = std::vector<anchor_t> {
        {lb,   ImVec2(0, h)},
        {expr, ImVec2(lb->br.x - expr->tl.x, 0)},
        {rb,   ImVec2(lb->br.x - expr->tl.x + expr->br.x, h)},
    };

    std::tie(ret->tl, ret->br) = calc_bb(ret->subobjs);
    return ret;
}

} /* math_expr_composer */

namespace virt_composer
{

inline std::unordered_map<std::string, math_expr_composer::mexpr_bracket_e> mexpr_bracket_from_str =
{
    {"MEXPR_BRACKET_ROUND", math_expr_composer::MEXPR_BRACKET_ROUND},
    {"MEXPR_BRACKET_SQUARE", math_expr_composer::MEXPR_BRACKET_SQUARE},
    {"MEXPR_BRACKET_CURLY", math_expr_composer::MEXPR_BRACKET_CURLY},
};

template <> inline math_expr_composer::mexpr_bracket_e
get_enum_val<math_expr_composer::mexpr_bracket_e>(fkyaml::node &n) {
    return get_enum_val(n, mexpr_bracket_from_str);
}

inline std::unordered_map<std::string, math_expr_composer::mexpr_e> mexpr_e_from_str =
{
    {"MEXPR_TYPE_INTERNAL", math_expr_composer::MEXPR_TYPE_INTERNAL},
    {"MEXPR_TYPE_LINE_STRIP", math_expr_composer::MEXPR_TYPE_LINE_STRIP},
    {"MEXPR_TYPE_EMPTY_BOX", math_expr_composer::MEXPR_TYPE_EMPTY_BOX},
    {"MEXPR_TYPE_SYMBOL", math_expr_composer::MEXPR_TYPE_SYMBOL},
};

template <> inline math_expr_composer::mexpr_e
get_enum_val<math_expr_composer::mexpr_e>(fkyaml::node &n) {
    return get_enum_val(n, mexpr_e_from_str);
}


template <ssize_t index>
inline math_expr_composer::mexpr_bracket_t
luaw_param_t<math_expr_composer::mexpr_bracket_t, index>::luaw_single_param(lua_State *L) {
    math_expr_composer::mexpr_bracket_t ret{};
    if (lua_isnil(L, index))
        return ret;
    using char_t = char_draw_composer::char_t;

    lua_getfield(L, index, "type");
    ret.type = luaw_param_t<bm_t<math_expr_composer::mexpr_bracket_e>, -1>{}.luaw_single_param(L);
    lua_pop(L, 1);

    lua_getfield(L, index, "tl");
    ret.tl = luaw_param_t<char_t, -1>{}.luaw_single_param(L);
    lua_pop(L, 1);
    
    lua_getfield(L, index, "bl");
    ret.bl = luaw_param_t<char_t, -1>{}.luaw_single_param(L);
    lua_pop(L, 1);
    
    lua_getfield(L, index, "tr");
    ret.tr = luaw_param_t<char_t, -1>{}.luaw_single_param(L);
    lua_pop(L, 1);
    
    lua_getfield(L, index, "br");
    ret.br = luaw_param_t<char_t, -1>{}.luaw_single_param(L);
    lua_pop(L, 1);
    
    lua_getfield(L, index, "cl");
    ret.cl = luaw_param_t<char_t, -1>{}.luaw_single_param(L);
    lua_pop(L, 1);
    
    lua_getfield(L, index, "cr");
    ret.cr = luaw_param_t<char_t, -1>{}.luaw_single_param(L);
    lua_pop(L, 1);

    lua_getfield(L, index, "conl");
    ret.conl = luaw_param_t<char_t, -1>{}.luaw_single_param(L);
    lua_pop(L, 1);

    lua_getfield(L, index, "conr");
    ret.conr = luaw_param_t<char_t, -1>{}.luaw_single_param(L);
    lua_pop(L, 1);
    
    lua_getfield(L, index, "left");
    auto left = luaw_param_t<std::vector<char_t>, -1>{}.luaw_single_param(L);
    for (int i = 0; i < left.size() && i < 4; i++)
        ret.left[i] = left[i];
    lua_pop(L, 1);

    lua_getfield(L, index, "right");
    auto right = luaw_param_t<std::vector<char_t>, -1>{}.luaw_single_param(L);
    for (int i = 0; i < right.size() && i < 4; i++)
        ret.right[i] = right[i];
    lua_pop(L, 1);

    return ret;
}

inline void luaw_returner_t<math_expr_composer::mexpr_bb_t>::luaw_ret_push(lua_State *L,
        const math_expr_composer::mexpr_bb_t& bb)
{
    lua_createtable(L, 0, 2);
    luaw_returner_t<ImVec2>{}.luaw_ret_push(L, bb.tl);
    lua_setfield(L, -2, "tl");
    luaw_returner_t<ImVec2>{}.luaw_ret_push(L, bb.br);
    lua_setfield(L, -2, "br");
}

inline void luaw_returner_t<char_draw_composer::char_t>::luaw_ret_push(lua_State *L,
        const char_draw_composer::char_t& c)
{
    lua_createtable(L, 0, 2);
    lua_pushinteger(L, c.size);
    lua_setfield(L, -2, "size");
    lua_pushinteger(L, c.code);
    lua_setfield(L, -2, "code");
}


} /* virt_composer */

#endif

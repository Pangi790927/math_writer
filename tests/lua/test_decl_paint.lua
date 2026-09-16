--[[
test_decl_paint.lua - the declared-name orange: which glyphs wear it, and what takes it off.

WHAT IS ASSERTED is the field the renderer reads (node.color), because no test can run the draw
path - the composer draws a symbol with its own colour member, the same one the definition box's
parameter dots set, so the value on the node is the whole contract with the screen.

THE RULE IT GUARDS (the author, 2026-09-16): declared names turn "a brighter orange than the one
of the diff, meaning more orange, like, not faded", and only the ROOT of the declaration - in
f(x) the f, never the x. The paint happens in the parse - at validation, the lock or a gesture or
a paste, "don't continuously verify" - and it is a parse FACT: a re-parse without the declaration
takes it off, and a differential's orange bar is not the parse's to touch.

@date 2026-09-16
]]

package.path = package.path .. ";./scripts/?.lua"

local vc = require("virt_composer")
local char = require("char")
local mexpru = require("mexpru")
local mformula = require("mformula_new")
local mformula_latex = require("mformula_latex")
local mexpr_ast = require("mexpr_ast")
local ast = require("ast")

local SZ = mexpru.DEFAULT_SIZE
local DECL_ORANGE = 0xff008cff
local DEFAULT = 0xffeeeeee
local DIFF_GREEN = 0xff50c878
local BOUND_BLUE = 0xffffaf50

local checks_run, checks_failed = 0, 0
local function check(name, cond, got)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name .. (got ~= nil and ("  (got: " .. tostring(got) .. ")") or ""))
    end
end

-- One declaration for `name_src`, the shape a definition box hands over.
local function decl_of(fs, name_src)
    local c = mformula_latex.from_latex(fs, SZ, name_src)
    local pat = mexpr_ast.parse_name(fs, c)
    return {mexpr_ast.new_decl{text = pat.text, name = pat.name, arity = pat.arity,
            tokens = pat.tokens, groups = pat.groups}}
end

-- desc -> colour, for the first symbol of each spelling in the tree.
local function colors_by_desc(node, out)
    out = out or {}
    if not node then
        return out
    end
    if node.type == vc.MEXPR_TYPE_SYMBOL then
        local entry = char.find_by_ncod(node.symb.code)
        local d = entry and entry.desc
        if d and out[d] == nil then
            out[d] = node.color
        end
    end
    for _, child in ipairs(mexpru.child_links(node)) do
        colors_by_desc(child, out)
    end
    return out
end

function run_test()
    local fs = char.load_font_set()

    -- ------------------------------------------------- only the root of a declaration wears it
    do
        local c = mformula_latex.from_latex(fs, SZ, "f(x)+a")
        local node, err = mexpr_ast.build(fs, c, decl_of(fs, "f(x)"))
        check("f(x)+a parses with f declared", node ~= nil, err)
        local colors = colors_by_desc(c.root)
        check("the callee f is orange", colors["f"] == DECL_ORANGE, colors["f"])
        check("the argument x is not", colors["x"] == DEFAULT, colors["x"])
        check("and neither is a free letter", colors["a"] == DEFAULT, colors["a"])
    end

    -- ------------------------------------------------- a bare declaration's reference wears it too
    do
        local c = mformula_latex.from_latex(fs, SZ, "a(b+f(x))")
        local node, err = mexpr_ast.build(fs, c, decl_of(fs, "f"))
        check("a(b+f(x)) parses with f declared bare", node ~= nil, err)
        local colors = colors_by_desc(c.root)
        check("the declared reference f is orange", colors["f"] == DECL_ORANGE, colors["f"])
        check("the cell's x is not", colors["x"] == DEFAULT, colors["x"])
    end

    -- ------------------------------------------------- nothing orange without a declaration
    do
        local c = mformula_latex.from_latex(fs, SZ, "f(x)")
        local node, err = mexpr_ast.build(fs, c, {})
        check("f(x) parses undeclared", node ~= nil, err)
        local colors = colors_by_desc(c.root)
        check("an undeclared f is not orange", colors["f"] == DEFAULT, colors["f"])
    end

    -- ------------------------------------------------- the paint is a parse fact, not a mark
    do
        --[[ THE RESET: the same container, parsed once with the declaration and once without, goes
        orange and back. Without the reset at the parse's start, a deleted definition would leave
        its orange behind forever - the tree is not rebuilt between parses. ]]
        local c = mformula_latex.from_latex(fs, SZ, "f(x)")
        mexpr_ast.build(fs, c, decl_of(fs, "f(x)"))
        check("orange after the declared parse",
                colors_by_desc(c.root)["f"] == DECL_ORANGE, colors_by_desc(c.root)["f"])
        mexpr_ast.build(fs, c, {})
        check("...and gone after an undeclared re-parse",
                colors_by_desc(c.root)["f"] == DEFAULT, colors_by_desc(c.root)["f"])
    end

    -- ------------------------------------------------- a differential's bar is not the parse's to touch
    do
        --[[ The reset walks SYMBOLS only: the diff bar is a rule, and a re-parse of a formula
        carrying a differential must not wash its orange. The parse here fails (an empty fraction
        is not an expression) - the reset runs before the cascade either way, which is exactly the
        moment that would have clobbered it. ]]
        local c = mformula.new_with_frac(fs, SZ)
        local frac = nil
        local function find_frac(node)
            if not node or frac then
                return
            end
            local u = mexpru.u(node)
            if u and u.kind == "frac" then
                frac = node
            end
            for _, child in ipairs(mexpru.child_links(node)) do
                find_frac(child)
            end
        end
        find_frac(c.root)
        check("the fresh fraction is found", frac ~= nil)
        if not frac then
            return checks_failed == 0
        end
        mexpru.mark_diff(frac, true)
        mexpr_ast.build(fs, c, {})
        --[[ The rule is read the way mark_diff itself reads it - the frac's third anchor - because
        it is a raw C++ child with no `u`, invisible to child_links and therefore to any u-based
        walk, including the parse's own reset (which is the point: the reset cannot reach it). ]]
        check("the diff bar keeps its green through a parse",
                frac:anchor_at(3)[1].color == DIFF_GREEN, frac:anchor_at(3)[1].color)
    end

    -- ------------------------------------------------- a distributed child keeps its orange
    do
        --[[ THE WRITTEN CHILD is born locked with no parse of its own, so nobody repaints it after
        the write - the orange has to travel with the writing itself. Two roads: a reference is
        CLONED (rescale_node carries a glyph's colour, since a copy of a declared name is a use of
        it), and a call's callee letters are BUILT by the writer and painted at the build. Both are
        the user's own workflow - distribute a formula with a declared name in it. ]]
        local transforms = require("transforms")
        local ast_mexpr = require("ast_mexpr")
        local ast = require("ast")

        -- A call: the callee letters are built, so the writer paints them.
        local c = mformula_latex.from_latex(fs, SZ, "a(b+f(x))")
        local node, err, ns = mexpr_ast.build(fs, c, decl_of(fs, "f(x)"))
        check("a(b+f(x)) parses with f declared", node ~= nil, err)
        if node then
            local opts = transforms.offers(ns, node, node[2][2][1])
            local result = #opts == 1 and transforms.apply(opts[1].id, ns, node, opts[1].params)
            local w = result and ast_mexpr.build(fs, c.root, ns, result, SZ)
            check("the distributed call-child writes", w ~= nil)
            if w then
                local colors = colors_by_desc(w)
                check("the child's callee f is orange", colors["f"] == DECL_ORANGE, colors["f"])
                check("the child's argument x is not", colors["x"] == DEFAULT, colors["x"])
                check("the child's free a is not", colors["a"] == DEFAULT, colors["a"])
            end
        end

        -- A bare declaration: the reference is cloned, so the colour rides the clone.
        local c2 = mformula_latex.from_latex(fs, SZ, "a(b+f(x))")
        local node2, err2, ns2 = mexpr_ast.build(fs, c2, decl_of(fs, "f"))
        check("a(b+f(x)) parses with f declared bare", node2 ~= nil, err2)
        if node2 then
            local opts = transforms.offers(ns2, node2, node2[2][2][1])
            local result = #opts == 1 and transforms.apply(opts[1].id, ns2, node2, opts[1].params)
            local w = result and ast_mexpr.build(fs, c2.root, ns2, result, SZ)
            check("the distributed bare-child writes", w ~= nil)
            if w then
                local colors = colors_by_desc(w)
                check("the cloned f keeps its orange", colors["f"] == DECL_ORANGE, colors["f"])
            end
        end
    end

    -- ------------------------------------------------- the integral: green d, blue linked x
    do
        --[[ THE PALETTE, ruled whole 2026-09-16: "globals get orange, green for structural", and a
        binder's variable "should be blue, indicating an linked var and it's aparitions inside the
        integral should be blue also". So the closing `d` wears the differential green, the `dx`'s
        x wears the bound blue, and the integrand's caught mention of x wears it too - while the
        `\int` sign stays default. The `\,d` spelling is what a save carries, and from_latex builds
        the pair from it, so this is the real loaded shape. ]]
        local c = mformula_latex.from_latex(fs, SZ, "\\int_{0}^{1} x \\,d x")
        local node, err = mexpr_ast.build(fs, c, {})
        check("the integral parses", node ~= nil and node.type == ast.INT, err)
        local saw_green_d, saw_int, bound_x = false, false, 0
        local function walk(n)
            if not n then
                return
            end
            if n.type == vc.MEXPR_TYPE_SYMBOL then
                local entry = char.find_by_ncod(n.symb.code)
                if entry and entry.desc == "d" and n.color == DIFF_GREEN then
                    saw_green_d = true
                end
                if entry and entry.desc == "x" and n.color == BOUND_BLUE then
                    bound_x = bound_x + 1
                end
                if entry and entry.desc == "\\int" then
                    saw_int = true
                    check("...and the \\int itself stays default", n.color == DEFAULT, n.color)
                end
            end
            for _, child in ipairs(mexpru.child_links(n)) do
                walk(child)
            end
        end
        walk(c.root)
        check("the closing d is green", saw_green_d)
        check("...and BOTH x's are blue: the dx's and the integrand's", bound_x == 2, bound_x)
        check("...with the sign present to compare against", saw_int)
    end

    -- ------------------------------------------------- a subscript is an argument, not the name
    do
        --[[ `\vec{F}_{k}` WITH `\vec{F}` DECLARED: the sub holds the name's ARGUMENT (the k), and
        only the symbol the name is wears the orange - the leaf under the sub, never the sub itself
        (reported live 2026-09-16: "the k subscript of F shouldn't be colored, only the symbol F").
        The declaration's own parameter slot uses `m` so the two spellings cannot confuse the match. ]]
        local c = mformula_latex.from_latex(fs, SZ, "\\vec{F}_{k}")
        local node, err = mexpr_ast.build(fs, c, decl_of(fs, "\\vec{F}_{m}"))
        check("the applied name parses", node ~= nil, err)
        local colors = colors_by_desc(c.root)
        check("the F is orange", colors["F"] == DECL_ORANGE, colors["F"])
        check("...and its subscript k is not", colors["k"] == DEFAULT, colors["k"])
    end

    -- ------------------------------------------------- the derivative: signs plain, linked x blue
    do
        --[[ THE SIGNS ARE NOT VARIABLES - found live 2026-09-16, reported as "the d ...
        shouldn't be blue, it shouldn't result in a linked variable because it shouldn't be passed
        downwards as such": the denominator's painting tested only `is_letter`, and `d` is also a
        letter, so the differential signs themselves went blue. The signs stay plain (the green bar
        already says what the fraction is); the linked x and its apparitions in the body go blue. ]]
        local c = mformula_latex.from_latex(fs, SZ,
                "\\frac{\\mathrm{d} }{\\mathrm{d} x}(a(x+y))")
        local node, err = mexpr_ast.build(fs, c, {})
        check("the derivative parses", node ~= nil and node.type == ast.DIFF, err)
        local bound_x, plain_d = 0, 0
        local function walk(n)
            if not n then
                return
            end
            if n.type == vc.MEXPR_TYPE_SYMBOL then
                local entry = char.find_by_ncod(n.symb.code)
                local d = entry and entry.desc
                if d == "x" and n.color == BOUND_BLUE then
                    bound_x = bound_x + 1
                end
                if d == "d" then
                    if n.color == DEFAULT then
                        plain_d = plain_d + 1
                    else
                        check("...the d signs never wear a colour", false, n.color)
                    end
                end
            end
            for _, child in ipairs(mexpru.child_links(n)) do
                walk(child)
            end
        end
        walk(c.root)
        check("both x's are blue: the denominator's and the body's", bound_x == 2, bound_x)
        check("both d signs stay plain", plain_d == 2, plain_d)
    end

    if checks_failed == 0 then
        print("PASS: declared names paint orange at their root (" .. checks_run .. " checks)")
    end
    return checks_failed == 0
end

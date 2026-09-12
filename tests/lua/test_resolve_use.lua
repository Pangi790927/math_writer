--[[
test_resolve_use.lua - matching a USE against the declarations above it.

THE ASSUMPTION: a use site cannot build its own key, and never could. It knows it has `F`, four
subscript arguments and three call arguments; only the DECLARATION knows which of those positions
are parameters and which are literal parts of the name. Author, 2026-09-10: "only the declaration
gives the shape, you should walk the variable with multiple candidates, at the end if you don't
have exactly one candidate, then you have multiple match errors".

WHAT WENT WRONG WITHOUT IT, because this file exists to stop it coming back. A use site used to
number EVERY argument position, so `F_{1,'acdefg',m,m}(1,2,3)` keyed as
`F(),(1),(2),(3),sub,(4),(5),(6),(7)` while its own declaration keyed as
`F(),1,2,3,sub,1,'acdefg',(1),(2)`. Two different strings for one text, so under exact equality the
formula could never resolve to the definition sitting right above it - and the giveaway was the
numbering running to `(7)` when the thing has two parameters. Reported as "no (6)(7) should apear".

WHY IT NEEDS AN ALARM. Every failure here is silent. A wrong match resolves to the wrong definition
and builds a tree that draws perfectly. A missed match reads as "not declared" for something plainly
declared. And an AMBIGUOUS match, if it were ever quietly resolved by picking the first, would mean
a formula whose meaning depends on document order in a way nobody wrote down.
]]

package.path = package.path .. ";./scripts/?.lua"

local char = require("char")
local mexpru = require("mexpru")
local mformula_latex = require("mformula_latex")
local mexpr_ast = require("mexpr_ast")

local checks_run, checks_failed = 0, 0
local function check(name, cond, got)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name .. (got ~= nil and ("  (got: " .. tostring(got) .. ")") or ""))
    end
end

local function decl(fs, latex)
    local c = mformula_latex.from_latex(fs, mexpru.DEFAULT_SIZE, latex)
    local pat = c and mexpr_ast.parse_name(fs, c)
    if not pat then
        error("test needs '" .. latex .. "' to declare")
    end
    --[[ Through mexpr_ast.new_decl since 2026-09-12: a declaration is a sealed type now, and
    resolve_use checks each element of the list it walks. A bare table carrying the same four
    fields is no longer one - which is the point, since what the parser walks has to BE what the
    document produced. ]]
    return mexpr_ast.new_decl{text = pat.text, name = pat.name, arity = pat.arity,
            tokens = pat.tokens}
end

local function use(fs, latex)
    local c = mformula_latex.from_latex(fs, mexpru.DEFAULT_SIZE, latex)
    return c and mexpr_ast.parse_use(fs, c)
end

function run_test()
    local fs = char.load_font_set()

    -- ------------------------------------------------- the reported case, end to end
    do
        --[[ The author's own pair: literals in the subscript, free variables after them, and three
        call parameters. Every position has to line up or this does not resolve. ]]
        local d = decl(fs, "F_{1,'acdefg',n,m}(t,v,a)")
        local u = use(fs, "F_{1,'acdefg',m,m}(1,2,3)")
        check("setup: the use parses", u ~= nil)

        local hit, err = mexpr_ast.resolve_use(u, {d})
        check("it resolves to the declaration", hit ~= nil, err)
        check("...naming the declaration's key", hit and hit.decl.text == d.text, d.text)
        --[[ FIVE arguments, not seven: the two literal positions belong to the NAME, so only the
        two subscript parameters and the three call parameters are arguments. This is the number
        that was wrong. ]]
        check("...with five arguments, not seven", hit and #hit.args == 5, hit and #hit.args)
    end

    -- ------------------------------------------------- a literal must match exactly
    do
        local d = decl(fs, "F_{1,m}")
        check("the same literal matches", mexpr_ast.resolve_use(use(fs, "F_{1,x}"), {d}) ~= nil)

        --[[ A DIFFERENT literal is a different name, not a near miss. `F_{2,x}` names nothing that
        was declared, even though `F_{1,m}` looks similar - the 1 is part of the name. ]]
        local hit, err = mexpr_ast.resolve_use(use(fs, "F_{2,x}"), {d})
        check("a different literal does not match", hit == nil, hit and hit.decl.text)
        check("...and says why", err ~= nil, err)

        --[[ Nor may a VARIABLE stand in for a declared literal: `F_{k,x}` is asking for something
        whose first index is whatever k is, which is not what was declared. ]]
        check("a variable does not match a declared literal",
                mexpr_ast.resolve_use(use(fs, "F_{k,x}"), {d}) == nil)
    end

    -- ------------------------------------------------- a parameter takes anything
    do
        --[[ The other half: where the declaration has a parameter, the use may put a literal, a
        variable or an expression. `f(34)` resolving to `f(x)` is the case that made the whole
        mechanism necessary - the key could not be built from the use alone. ]]
        local d = decl(fs, "f(x)")
        for _, latex in ipairs({"f(34)", "f(y)", "f(n+1)"}) do
            local hit, err = mexpr_ast.resolve_use(use(fs, latex), {d})
            check(latex .. " resolves to f(x)", hit ~= nil, err)
            check("...passing one argument", hit and #hit.args == 1, hit and #hit.args)
        end
    end

    -- ------------------------------------------------- shape has to agree
    do
        --[[ Arity and NOTATION both. `f(x)` and `f(x,y)` are different variables that share a base,
        and a subscript is not a call - `F_{a}` must not match `F(a)` just because both apply one
        thing to `F`. ]]
        local one, two = decl(fs, "f(x)"), decl(fs, "f(x,y)")
        check("one argument picks the one-argument declaration",
                mexpr_ast.resolve_use(use(fs, "f(a)"), {one, two}).decl.text == "f(),(1)")
        check("two arguments pick the other",
                mexpr_ast.resolve_use(use(fs, "f(a,b)"), {one, two}).decl.text == "f(),(1),(2)")

        local sub_decl = decl(fs, "F_{a}")
        check("a subscript does not match a call",
                mexpr_ast.resolve_use(use(fs, "F(a)"), {sub_decl}) == nil)
    end

    -- ------------------------------------------------- zero, and more than one
    do
        check("nothing declared is a miss", mexpr_ast.resolve_use(use(fs, "f(x)"), {}) == nil)

        --[[ AMBIGUITY IS AN ERROR, never a silent pick. Two declarations of the same shape both
        match, and resolving that by taking the first would make the formula's meaning depend on
        document order in a way nobody wrote down. The message names both so it can be fixed. ]]
        local d1, d2 = decl(fs, "f(x)"), decl(fs, "f(y)")
        local hit, err = mexpr_ast.resolve_use(use(fs, "f(a)"), {d1, d2})
        check("two matches is refused, not guessed", hit == nil, hit and hit.decl.text)
        check("...and reports how many", err and err:find("matches 2", 1, true) ~= nil, err)
    end

    if checks_failed == 0 then
        print("PASS: a use matches a declaration by walking its shape ("
                .. checks_run .. " checks)")
    end
    return checks_failed == 0
end

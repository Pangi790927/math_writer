--[[
test_declaration_rules.lua - which definitions may coexist, and what a use resolves to when several
could answer. The rules of docs/phase2_design.md 18d.

THE ASSUMPTION UNDERNEATH ALL OF IT: the set of definitions in scope is not the set that was
written. `mexpr_ast.check_declarations` refuses some, and the refusals are load-bearing rather than
courtesy - the USE site decides whether a decorated group like `n_{5}` is an argument or part of a
name by asking whether anything answers to it, and that question only has one answer while
"no definition inside a definition" holds. Break the invariant and the parser reads names wrong,
quietly.

WHY NO OVERLAP AT ALL, rather than the narrower rule that only a `()` continuation is dangerous:
this is about meaning, not parseability. Author, 2026-09-10: "if you have a_{n} defined, why would a
be allowed? it is already a name of something, what would a_n being a sequence and a+1 mean at the
same time?". It costs arity overloading, since `f(),(1)` is a prefix of `f(),(1),(2)`, and that is
the price of the rule rather than an oversight.

RESOLUTION RANKS INSTEAD OF REFUSING. "Most restrictive wins" (author, same day) replaced "exactly
one candidate or it is an error" everywhere except a genuine tie - two declarations that pinned
exactly the same positions, which no order can separate.
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
    return {text = pat.text, name = pat.name, arity = pat.arity, tokens = pat.tokens,
            groups = pat.groups}
end

-- The definitions that survive, in order, as their texts joined - so a failure prints the set.
local function accepted(fs, ...)
    local written = {}
    for _, latex in ipairs({...}) do
        written[#written + 1] = decl(fs, latex)
    end
    local out = {}
    for _, d in ipairs(mexpr_ast.check_declarations(written).accepted) do
        out[#out + 1] = d.text
    end
    return table.concat(out, " | ")
end

-- What `latex` resolves to, given `decls`, or "ERROR <reason>".
local function resolve(fs, latex, decls)
    local c = mformula_latex.from_latex(fs, mexpru.DEFAULT_SIZE, latex)
    local u = c and mexpr_ast.parse_use(fs, c, decls)
    if not u then
        return "<not a name>"
    end
    local hit, err = mexpr_ast.resolve_use(u, decls)
    return hit and hit.decl.text or ("ERROR " .. tostring(err))
end

function run_test()
    local fs = char.load_font_set()

    -- ------------------------------------------------- no overlapping definitions
    do
        --[[ Both directions, because a trie only sees one of them by walking down. Adding `a_{n}`
        after `a` finds a marked ANCESTOR; adding `a` after `a_{n}` lands on an unmarked node with a
        marked DESCENDANT, which no downward walk reports. ]]
        check("a name may not extend one already defined",
                accepted(fs, "a", "a_{n}") == "a", accepted(fs, "a", "a_{n}"))
        check("nor may one be the start of a name already defined",
                accepted(fs, "a_{n}", "a") == "a,sub,(1),end", accepted(fs, "a_{n}", "a"))

        --[[ THE PRICE OF THE RULE, asserted so it is a decision on the record rather than a
        surprise: two arities of one name are a prefix pair, so they cannot coexist. `\log(x)` and
        `\log(b,x)` is the case that will eventually argue for narrowing this. ]]
        check("arity overloading is refused too",
                accepted(fs, "f(x)", "f(x,y)") == "f(),(1)", accepted(fs, "f(x)", "f(x,y)"))

        -- Different branches are not prefixes of each other and coexist freely.
        check("a literal and a parameter branch coexist",
                accepted(fs, "a_{1,m}", "a_{n,m}") == "a,sub,1,(1),end | a,sub,(1),(2),end",
                accepted(fs, "a_{1,m}", "a_{n,m}"))
    end

    -- ------------------------------------------------- no definition inside a definition
    do
        check("a definition containing one already defined is refused",
                accepted(fs, "n_{m}", "a_{n_{m}}") == "n,sub,(1),end",
                accepted(fs, "n_{m}", "a_{n_{m}}"))

        --[[ AND THE REVERSE ORDER, which is the half a one-directional check misses: with
        `a_{n_{m}}` in place, it is `n_{m}` that must be refused. Author's own statement of what the
        check is for: "accepting a new definition should not break any of the old ones". ]]
        check("and defining the inner one afterwards is refused instead",
                accepted(fs, "a_{n_{m}}", "n_{m}") == "a,sub,n,sub,(1),end,end",
                accepted(fs, "a_{n_{m}}", "n_{m}"))

        --[[ A BARE PARAMETER IS NOT A NESTED DEFINITION. `m` in `a_{m}` is a parameter by rule and
        has no competing reading, so a declared `m` elsewhere does not poison it - the rule needs a
        group that could be read as an APPLICATION, which takes a subscript. ]]
        check("a bare parameter is unaffected by a name spelled the same",
                accepted(fs, "m", "a_{m}") == "m | a,sub,(1),end", accepted(fs, "m", "a_{m}"))
    end

    -- ------------------------------------------------- the invariant doing its job
    do
        --[[ THE CASE THE WHOLE SCHEME IS BUILT AROUND. `n_{5}` is read one way or the other
        depending only on whether anything answers to it, and the rules above are what guarantee
        exactly one of those is true. ]]
        local a_nm = decl(fs, "a_{n_{m}}")
        check("with n_{m} undefined, n_{5} is part of the name",
                resolve(fs, "a_{n_{5}}", {a_nm}) == "a,sub,n,sub,(1),end,end",
                resolve(fs, "a_{n_{5}}", {a_nm}))

        local n_m, a_x = decl(fs, "n_{m}"), decl(fs, "a_{x}")
        check("with n_{m} defined, n_{5} is an argument",
                resolve(fs, "a_{n_{5}}", {a_x, n_m}) == "a,sub,(1),end",
                resolve(fs, "a_{n_{5}}", {a_x, n_m}))

        --[[ A BARE LEAF NEVER ASKS THE QUESTION. Without that guard `5` would resolve to nothing,
        be called literal structure, and `a_{5}` would stop matching `a,sub,(1),end`. ]]
        check("a bare leaf stays an argument", resolve(fs, "a_{5}", {a_x}) == "a,sub,(1),end",
                resolve(fs, "a_{5}", {a_x}))
    end

    -- ------------------------------------------------- most restrictive wins
    do
        local general, pinned = decl(fs, "F(x)"), decl(fs, "F(0)")
        check("a pinned literal beats an open slot",
                resolve(fs, "F(0)", {general, pinned}) == "F(),0",
                resolve(fs, "F(0)", {general, pinned}))
        check("and the open one still takes everything else",
                resolve(fs, "F(9)", {general, pinned}) == "F(),(1)",
                resolve(fs, "F(9)", {general, pinned}))

        --[[ SPECIFICITY IS A PARTIAL ORDER and this is the pair that shows it: neither dominates.
        The leftmost difference decides, which makes it total. Author: "the first matching will be
        considered more exact than the second parameter matching". ]]
        local left, right = decl(fs, "a_{1,m}"), decl(fs, "a_{n,2}")
        check("leftmost breaks a specificity tie",
                resolve(fs, "a_{1,2}", {right, left}) == "a,sub,1,(1),end",
                resolve(fs, "a_{1,2}", {right, left}))

        --[[ WHAT IS LEFT OF "EXACTLY ONE OR IT IS AN ERROR": two declarations that pinned exactly
        the same positions are the same shape, and no order can choose between them. `f(x)` and
        `f(z)` differ only in a parameter's spelling, which is not part of a name. ]]
        local r = resolve(fs, "f(a)", {decl(fs, "f(x)"), decl(fs, "f(z)")})
        check("an exact tie is still an error", r:find("ERROR", 1, true) == 1, r)
    end

    if checks_failed == 0 then
        print("PASS: declaration rules and resolution ranking (" .. checks_run .. " checks)")
    end
    return checks_failed == 0
end

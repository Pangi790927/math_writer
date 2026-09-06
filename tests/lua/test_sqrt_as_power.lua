--[[
test_sqrt_as_power.lua - \sqrt is read as the power it means.

Asked for 2026-09-06, in those words: "in the specific case of sqrt I want to transform it into
()^(1/2)". There is no radical node in this model, and rather than drop \sqrt on the floor (which is
what the parser did before - see the audit that prompted this: an unknown macro vanishes AND leaves
its "{" behind as a literal glyph, breaking the brace nesting of everything after it), a root is
rewritten into nodes that already exist.

    \sqrt{x}      ->  (x)^{\frac{1}{2}}
    \sqrt[3]{x}   ->  (x)^{\frac{1}{3}}

The rewrite happens on the SOURCE TEXT, before parsing, which is the design decision worth pinning:
the parentheses are then built by the exact path a typed "(" takes, so they arrive as a real
resolved PAIR rather than two loose glyphs that merely look like brackets. That is what these checks
are mostly about - the expansion string is easy, the pairing is the part that would rot.

ONE-WAY on purpose: the power form is what the formula now IS, so that is what comes back out. It
re-reads as itself (stable), it just never turns back into a \sqrt.
]]

package.path = package.path .. ";./scripts/?.lua"

local vc = require("virt_composer")
local char = require("char")
local mexpru = require("mexpru")
local mformula_latex = require("mformula_latex")

local B = string.char(92)
local SZ = 12

local checks_run, checks_failed = 0, 0
local function check(name, cond, got)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name .. (got ~= nil and ("  (got: " .. tostring(got) .. ")") or ""))
    end
end

local function latex_of(fs, src)
    return mformula_latex.to_latex(mformula_latex.from_latex(fs, SZ, src))
end

function run_test()
    local fs = char.load_font_set()

    -- ---------------------------------------------------------------- the rewrite itself
    local HALF = ")^{" .. B .. "frac{1}{2}}"
    for _, case in ipairs({
            {B .. "sqrt{x}",                     "(x" .. HALF},
            {B .. "sqrt{a+b}",                   "(a+b" .. HALF},
            {B .. "sqrt[3]{x}",                  "(x)^{" .. B .. "frac{1}{3}}"},
            --[[ The argument keeps its own structure; only the root is rewritten. Tall content
            also proves the pair really is a pair: brackets that GREW are written \left...\right
            (node_to_latex's own rule), so this expectation cannot be met by two loose glyphs. ]]
            {B .. "sqrt{" .. B .. "frac{a}{b}}",
                    B .. "left(" .. B .. "frac{a}{b}" .. B .. "right)^{" .. B .. "frac{1}{2}}"},
            -- and it is not the whole row: what surrounds a root is untouched
            {"1+" .. B .. "sqrt{x}+2",           "1+(x" .. HALF .. "+2"},
            {B .. "frac{1}{" .. B .. "sqrt{2}}", B .. "frac{1}{(2" .. HALF .. "}"},
            -- recursive, on both the radicand and the index
            {B .. "sqrt{" .. B .. "sqrt{x}}",
                    B .. "left((x" .. HALF .. B .. "right)^{" .. B .. "frac{1}{2}}"},
    }) do
        check(case[1] .. " -> " .. case[2], latex_of(fs, case[1]) == case[2],
                latex_of(fs, case[1]))
    end

    --[[ Nothing that merely STARTS with \sqrt is touched - "\sqrtsign" is a macro of its own name,
    and a bare "\sqrt" with no argument has nothing to rewrite. Both keep whatever the ordinary
    unknown-macro path does with them; the point is only that expansion does not fire. ]]
    for _, src in ipairs({B .. "sqrtsign", B .. "sqrt"}) do
        local ok = pcall(mformula_latex.from_latex, fs, SZ, src)
        check(src .. " is left for the ordinary path, without erroring", ok)
    end

    -- ---------------------------------------------------------------- the brackets are REAL
    --[[ The whole reason the rewrite goes through text. Two glyphs that merely look like
    parentheses would render identically and then behave wrongly - no cascade delete, no
    synchronized resize - and nothing about the LaTeX output would show it. ]]
    do
        local c = mformula_latex.from_latex(fs, SZ, B .. "sqrt{x}")
        local children = mexpru.u(c.root).children
        check("the row is ( x  and the exponent-carrying )", #children == 3, #children)

        local open = mexpru.u(children[1])
        check("first atom is an opening bracket", open.bracket ~= nil and open.bracket.is_open)

        --[[ Read through slot_atom: the closing half is a supsub BASE, because "^" binds to the
        ")" exactly as it does when the same thing is typed by hand. Reading children directly
        would find a supsub and conclude there is no bracket there at all. ]]
        local closing = mexpru.u(mexpru.slot_atom(children[3]))
        check("last atom carries a closing bracket in its base",
                closing.bracket ~= nil and closing.bracket.is_open == false)

        -- Paired to EACH OTHER, both directions - a peer set on only one side is the bug shape
        -- transfer_bracket_peers exists to prevent.
        check("the two are peered to each other",
                open.bracket.peer == closing and closing.bracket.peer == open)
    end

    -- ---------------------------------------------------------------- stable, and one-way
    do
        for _, src in ipairs({B .. "sqrt{x}", B .. "sqrt[3]{a+b}",
                              B .. "sqrt{" .. B .. "sqrt{x}}"}) do
            local once = latex_of(fs, src)
            local twice = latex_of(fs, once)
            check(src .. ": re-reads as itself", once == twice, twice)
            check(src .. ": does not come back as a " .. B .. "sqrt",
                    once:find("sqrt", 1, true) == nil, once)
        end
    end

    print("checks: " .. checks_run .. ", failed: " .. checks_failed)
    if checks_failed > 0 then
        return false
    end
    print("PASS: \\sqrt reads as (x)^{1/2} with real bracket pairing")
    return true
end

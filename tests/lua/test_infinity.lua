--[[
test_infinity.lua - `\infty` is a NUMBER, and its number is one over zero.

THE REPRESENTATION, and it is the whole assumption: `(N, 1, 0, 1)`. Author, 2026-09-11: "infty
should also parse, it's a number like any other, give it a specific value in over 0 in denominator".

WHAT THAT BUYS, and why it is worth a test rather than being obvious. Infinity gets no node type,
no branch in arithmetic, and no sign handling of its own - every place that already knows what a NUM
is knows what this is. `-\infty` is the case that shows it: nothing was added for it anywhere.
build_product's ordinary negation flips a leading NUM's sign in place, and out comes (N, 1, 0, -1).
If someone ever "fixes" infinity into a node of its own, that line stops applying and the negation
silently becomes MUL(-1, INF) instead - which is a different tree for the same formula, on a project
whose identity scheme is exact structural equality.

WHERE IT ACTUALLY MATTERS is a bound: `\int_0^\infty` and `\sum_{k=1}^{\infty}` are most of why
anyone types it. Both go through the ordinary expression cascade, so both are checked here.

THE ONE PLACE THIS DELIBERATELY DOES NOT GUESS: `m/0` for m other than 1. Nothing builds one, and
glossing `0/0` as "inf" would be a viewer inventing an answer the AST was never asked for - so
ast.num_text prints the raw pair there instead. That is asserted, because "helpfully" widening it is
exactly the kind of tidying that looks like an improvement.

NOT A LEXICAL MATTER. `parse_number` reads written digits and must keep refusing "infty" - infinity
arrives as a GLYPH in the row, not as text in a literal. The last check holds that line, for the
same reason test_number_parse.lua's header refuses to let that function grow.
]]

package.path = package.path .. ";./scripts/?.lua"

local char = require("char")
local mexpru = require("mexpru")
local mformula_latex = require("mformula_latex")
local mexpr_ast = require("mexpr_ast")
local ast = require("ast")

local B = string.char(92)
local SZ = mexpru.DEFAULT_SIZE

local checks_run, checks_failed = 0, 0
local function check(name, cond, got)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name .. (got ~= nil and ("  (got: " .. tostring(got) .. ")") or ""))
    end
end

local function tree(fs, src)
    local c = mformula_latex.from_latex(fs, SZ, src)
    if not c then
        return nil, "from_latex failed"
    end
    local node, err, ns = mexpr_ast.build(fs, c, {})
    if not node then
        return nil, err
    end
    return ast.to_string(ns, node), nil, node
end

function run_test()
    local fs = char.load_font_set()

    -- ------------------------------------------------------------------ the representation
    do
        local out, err, node = tree(fs, B .. "infty ")
        check("infinity builds", out ~= nil, err)
        check("...as a NUM", node ~= nil and node.type == ast.NUM, node and node.type)
        check("...of one over zero, positive",
                node ~= nil and node[1] == 1 and node[2] == 0 and node[3] == 1, out)

        --[[ NOTHING WAS ADDED FOR THIS. The minus goes through build_product's existing "negate a
        leading NUM in place" branch - see the header for why that mattering is the point. ]]
        local out2, err2, node2 = tree(fs, "-" .. B .. "infty ")
        check("a negated infinity builds", out2 ~= nil, err2)
        check("...as the same number with the sign flipped, not as a multiplication",
                node2 ~= nil and node2.type == ast.NUM and node2[1] == 1 and node2[2] == 0
                        and node2[3] == -1, out2)
    end

    -- ------------------------------------------------------------------ where it is actually used
    do
        local out, err = tree(fs, B .. "int _{0}^{" .. B .. "infty }x" .. B .. ",dx")
        check("an integral to infinity builds", out ~= nil, err)
        check("...with infinity as its upper bound",
                out ~= nil and out:find("(N, 1, 0, 1:", 1, true) ~= nil, out)

        out, err = tree(fs, B .. "sum " .. B .. "limits^{" .. B .. "infty }_{k=1}k")
        check("a sum to infinity builds", out ~= nil, err)
        check("...with infinity in its sup",
                out ~= nil and out:find("(N, 1, 0, 1:", 1, true) ~= nil, out)
    end

    -- ------------------------------------------------------------------ it composes like a number
    do
        --[[ Not because these formulas MEAN anything - `1+\infty` is not arithmetic anyone should
        evaluate - but because the parser must not special-case where a number may stand. Deciding
        that is the algebra layer's job, and it does not exist yet. ]]
        check("it can be added to", tree(fs, "1+" .. B .. "infty ") ~= nil)
        check("it can be a relation's side", tree(fs, "x=" .. B .. "infty ") ~= nil)
    end

    -- ------------------------------------------------------------------ how it reads back
    do
        local ns = ast.new_ns()
        check("one over zero reads as inf", ast.num_text(ast.new_num(ns, 1, 0, 1)) == "inf",
                ast.num_text(ast.new_num(ns, 1, 0, 1)))
        check("...signed", ast.num_text(ast.new_num(ns, 1, 0, -1)) == "-inf",
                ast.num_text(ast.new_num(ns, 1, 0, -1)))
        check("an ordinary rational is unaffected",
                ast.num_text(ast.new_num(ns, 3, 4, -1)) == "-3/4",
                ast.num_text(ast.new_num(ns, 3, 4, -1)))
        check("a whole number drops its denominator",
                ast.num_text(ast.new_num(ns, 7, 1, 1)) == "7", ast.num_text(ast.new_num(ns, 7, 1, 1)))

        --[[ THE NON-INVENTION. Zero over zero is not infinity and this must not say it is. ]]
        check("zero over zero is shown raw, not glossed",
                ast.num_text(ast.new_num(ns, 0, 0, 1)) == "0/0",
                ast.num_text(ast.new_num(ns, 0, 0, 1)))
    end

    -- ------------------------------------------------------------------ still not a lexeme
    do
        --[[ Infinity is a GLYPH in the row. parse_number reads written digits, and widening it to
        accept a word would put two different readers in charge of what a number is. ]]
        check("parse_number still refuses the word", mexpr_ast.parse_number("infty") == nil)
        check("...and the macro", mexpr_ast.parse_number(B .. "infty") == nil)
    end

    if checks_failed == 0 then
        print("PASS: infinity is a number (" .. checks_run .. " checks)")
    end
    return checks_failed == 0
end

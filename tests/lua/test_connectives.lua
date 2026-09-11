--[[
test_connectives.lua - implication and equivalence, and the two things they forced into shape.

THREE ASSUMPTIONS, and the first is the one that makes the feature worth having at all.

1. IMPLICATION BINDS LOOSER THAN EVERY RELATION. `a=b \Rightarrow c=d` is IMPLIES(EQ, EQ). They join
   two STATEMENTS, not two expressions, which is the only thing anyone writes them for - so they
   cannot live in the RELATIONS table beside `=`, where that row counted as "more than one relation"
   and was refused outright. Added 2026-09-11: "add implies and iff, I guess those are binary,
   similar to in and the rest" - binary and plain they are; only their precedence differs.

2. A BRACKET HOLDS ANYTHING A ROW HOLDS. `(a=b) \Rightarrow c` needed the contents of a bracket to
   go through the top of the cascade rather than through build_expr, which starts below the
   relations - so before this a parenthesis could hold arithmetic and nothing else. Ruled the same
   day: "why can't you add it some precedence? that seems ok to do".

3. `\Rightarrow` IS NOT `\rightarrow`. Two different glyphs, two different nodes, two different
   digraphs: `=` then `>` gives implication, `-` then `>` gives the limit's "tends to". They are
   adjacent in every way that matters - same arrow family, same table, both binary, both asymmetric-
   looking - and getting them crossed would be invisible until a limit started meaning an
   implication. The last block holds that line.

WHY RIGHT-ASSOCIATIVE: `a => b => c` reads as `a => (b => c)`, which is how implication chains in
logic, and it also means a chain needs no special case - unlike the relations below, where `a=b=c`
is still refused for want of a shape nobody has chosen.
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

local function tree(src)
    local fs = char.load_font_set()
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
    -- ------------------------------------------------------------------ it joins two relations
    do
        local out, err, node = tree("a=b" .. B .. "Rightarrow c=d")
        check("an implication between two equations builds", out ~= nil, err)
        check("...with IMPLIES at the root",
                node ~= nil and node.type == ast.IMPLIES, node and node.type)
        --[[ BOTH SIDES ARE RELATIONS, which is the whole point: if the precedence were wrong this
        would either refuse or come back with the implication buried inside one side. ]]
        check("...and an EQ on each side",
                node ~= nil and node[1].type == ast.EQ and node[2].type == ast.EQ, out)

        out, err, node = tree("x" .. B .. "in S" .. B .. "Leftrightarrow y" .. B .. "in T")
        check("equivalence between two memberships builds", out ~= nil, err)
        check("...with IFF at the root", node ~= nil and node.type == ast.IFF, node and node.type)
        check("...over two IN nodes",
                node ~= nil and node[1].type == ast.IN and node[2].type == ast.IN, out)
    end

    -- ------------------------------------------------------------------ right-associative
    do
        local out, err, node = tree("a" .. B .. "Rightarrow b" .. B .. "Rightarrow c")
        check("a chain of implications builds", out ~= nil, err)
        --[[ a => (b => c). If it associated the other way the ROOT's second operand would be a
        reference rather than another implication. ]]
        check("...grouping to the RIGHT",
                node ~= nil and node.type == ast.IMPLIES and node[2].type == ast.IMPLIES, out)
        check("...with a plain reference on the left",
                node ~= nil and node[1].type == ast.VREF, out)
    end

    -- ------------------------------------------------------------------ brackets hold statements
    do
        local out, err, node = tree("(a=b)" .. B .. "Rightarrow c")
        check("a relation inside brackets builds", out ~= nil, err)
        check("...as the implication's left side", node ~= nil and node.type == ast.IMPLIES, out)

        -- and the bracket still does its ordinary job for arithmetic
        check("a bracket still holds an expression", tree("(a+b)c") ~= nil)
    end

    -- ------------------------------------------------------------------ not the limit arrow
    do
        --[[ THE LINE THIS FILE EXISTS TO HOLD - see the header. Both directions are asserted,
        because crossing them in either direction is silent. ]]
        local _, _, imp = tree("a" .. B .. "Rightarrow b")
        local _, _, tends = tree("x" .. B .. "rightarrow 0")
        check("\\Rightarrow is IMPLIES", imp ~= nil and imp.type == ast.IMPLIES,
                imp and imp.type)
        check("\\rightarrow is TENDS", tends ~= nil and tends.type == ast.TENDS,
                tends and tends.type)
        check("they are different node types", ast.IMPLIES ~= ast.TENDS)

        --[[ And the limit still reads the arrow it needs - the check that would fail if someone
        "unified" the two arrows into one node. ]]
        local out = tree(B .. "lim _{x" .. B .. "rightarrow 0}x")
        check("a limit still reads its arrow",
                out ~= nil and out:find("(to, ", 1, true) ~= nil, out)
    end

    -- ------------------------------------------------------------------ they round-trip
    do
        local fs = char.load_font_set()
        for _, src in ipairs({"a=b" .. B .. "Rightarrow c=d", "a" .. B .. "Leftrightarrow b"}) do
            local c = mformula_latex.from_latex(fs, SZ, src)
            check("round-trips: " .. src, c ~= nil and mformula_latex.to_latex(c) == src,
                    c and mformula_latex.to_latex(c))
        end
    end

    if checks_failed == 0 then
        print("PASS: implication and equivalence (" .. checks_run .. " checks)")
    end
    return checks_failed == 0
end

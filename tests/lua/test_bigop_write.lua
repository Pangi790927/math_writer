--[[
test_bigop_write.lua - the writer draws big operators, and everything inside a bigop formula
becomes transformable again.

THE ASSUMPTION: a written bigop and a typed one are the same tree - the operator glyph carrying
its limits over and under (display placement), the body as the rest of the term's factors (product
order). Until 2026-09-15 ast_mexpr refused bigops outright, which meant no formula CONTAINING one
could be written back, so every distribute anywhere in it refused at the draw - reported live as
"distribute doesn't work on the + inside" a formula whose only sin was owning a \sum.

ALSO HERE: the relations a bigop's limits are written with (k = 0, x \to 0) - a limit row is an
ordinary relation node, and the writer needs it flat. NEQ stays refused: it draws as an
overprinted pair this writer does not build.

@date 2026-09-15 17:00
]]

package.path = package.path .. ";./scripts/?.lua"

local char = require("char")
local mexpru = require("mexpru")
local mformula_latex = require("mformula_latex")
local mexpr_ast = require("mexpr_ast")
local ast_mexpr = require("ast_mexpr")
local ast = require("ast")
local transforms = require("transforms")

local SZ = mexpru.DEFAULT_SIZE

local checks_run, checks_failed = 0, 0
local function check(name, cond, got)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name .. (got ~= nil and ("  (got: " .. tostring(got) .. ")") or ""))
    end
end

-- Parse src, write it back through the writer, verify the round trip. Answers the container (or
-- nil and why), so a caller can also inspect the built tree.
local function roundtrip(fs, src)
    local c = mformula_latex.from_latex(fs, SZ, src)
    local node, err, ns = mexpr_ast.build(fs, c, {})
    if not node then
        return nil, "parse: " .. tostring(err)
    end
    local w, werr = ast_mexpr.build(fs, c.root, ns, node, SZ)
    if not w then
        return nil, "write: " .. tostring(werr)
    end
    local rebuilt = mexpru.new_container(w, mexpru.last_slot(w))
    local ok, want, got = ast_mexpr.verify(fs, rebuilt, {}, ns, node)
    if not ok then
        return nil, "verify: want " .. tostring(want) .. " got " .. tostring(got)
    end
    return rebuilt, nil, node, ns, c
end

function run_test()
    local fs = char.load_font_set()

    -- ------------------------------------------------------------------ the plain cases
    do
        local r, err = roundtrip(fs, "\\sum \\limits_{i=0}^{n} i")
        check("\\sum_{i=0}^{n} i writes and round-trips", r ~= nil, err)

        --[[ A two-constraint sub, written as a VERT of rows - the one shape constraint_rows reads
        back as several. A comma in the brace group (`_{i=0,j=i+1}`) does NOT make one: it parses
        as a single flat row and the relation reader refuses the second `=` before this writer is
        ever reached. ]]
        r, err = roundtrip(fs,
                "\\sum \\limits_{\\begin{matrix} i=0 \\\\ j=i+1 \\end{matrix}}^{n}(i+j)")
        check("a two-constraint sub (a vert) writes and round-trips", r ~= nil, err)

        r, err = roundtrip(fs, "\\lim \\limits_{x \\to 0} x")
        check("\\lim_{x \\to 0} x writes and round-trips (word operator)", r ~= nil, err)

        r, err = roundtrip(fs, "\\prod \\limits_{k=1}^{n} k")
        check("\\prod writes and round-trips (glyph operator)", r ~= nil, err)

        -- A body that is a whole sum needs its brackets, and gets them through the ordinary
        -- precedence path: \sum_{i=0}^{n} (i + i) has an ADD body.
        r, err = roundtrip(fs, "\\sum \\limits_{i=0}^{n} (i+i)")
        check("an add-like body round-trips through its brackets", r ~= nil, err)
    end

    -- ------------------------------------------------------------------ the report, end to end
    do
        --[[ THE LIVE REPORT'S OWN FORMULA: every distribute in it refused at the write, because
        writing ANY part of the result means writing the whole formula, and the whole formula
        contains a \sum. Offer, apply, write, verify - the full chain, on the exact input. ]]
        local src = "\\sum \\limits^{N}_{k=0}e^{-jk(\\delta t+\\beta )w}"
        local r, err, node, ns, c = roundtrip(fs, src)
        check("the reported formula writes and round-trips as-is", r ~= nil, err)
        if not r then
            return checks_failed == 0
        end

        -- Find the + inside (delta t + beta): the ADD whose second term leads with a sign NUM.
        local target = nil
        local function walk(n)
            if type(n) ~= "table" or not n.type or target then
                return
            end
            if n.type == ast.ADD then
                local t2 = n[2]
                if t2 and t2.type == ast.MUL and t2[1].type == ast.NUM then
                    target = n
                end
            end
            for i = 1, #n do
                walk(n[i])
            end
        end
        walk(node)
        check("setup: the inner sum is there to click", target ~= nil)

        local opts = transforms.offers(ns, node, target[2][1])
        check("the + inside the exponent offers distribute", #opts == 1, #opts)
        if #opts == 1 then
            local result = transforms.apply(opts[1].id, ns, node, opts[1].params)
            check("...applies", result ~= nil)
            if result then
                local w, werr = ast_mexpr.build(fs, c.root, ns, result, SZ)
                check("...and the whole formula - \\sum, exponent and all - writes back",
                        w ~= nil, werr)
                if w then
                    local rebuilt = mexpru.new_container(w, mexpru.last_slot(w))
                    local ok, want, got = ast_mexpr.verify(fs, rebuilt, {}, ns, result)
                    check("...and round-trips", ok,
                            ok or (tostring(want) .. " vs " .. tostring(got)))
                end
            end
        end
    end

    if checks_failed == 0 then
        print("PASS: big operators write (" .. checks_run .. " checks)")
    end
    return checks_failed == 0
end

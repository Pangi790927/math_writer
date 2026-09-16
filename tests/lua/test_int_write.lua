--[[
test_int_write.lua - an integral writes back as the bracket pair it is read from.

THE REPORT THIS CLOSES (2026-09-16): distribute inside `\int \sum_{k=0}^{N} e^{-jk(\delta t+\beta)w}
\,dt` offered and applied but produced no cell - the write refused with "cannot write a INT back
yet", because the writer had no INT branch. emit_int now builds the pair: the `\int` glyph with its
size boost, the bounds beside it, the integrand, the closing `d` carrying the peer link (the reparse
refuses an unpaired integral, so a d without one would round-trip as garbage), and the variable
after it - cloned from the glyph the parse tags in read_integral, which is also why the bound blue
rides along.

THE PAIR IS THE WHOLE RISK here: every other piece (sums, powers, refs) is covered by older tests.
verify() reparse is what proves the halves found each other.

@date 2026-09-16
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

function run_test()
    local fs = char.load_font_set()

    -- ------------------------------------------------- the plain round trip, bounds and all
    do
        local c = mformula_latex.from_latex(fs, SZ, "\\int_{0}^{1} x \\,d x")
        local node, err, ns = mexpr_ast.build(fs, c, {})
        check("the integral parses", node ~= nil and node.type == ast.INT, err)
        if node then
            local w, werr = ast_mexpr.build(fs, c.root, ns, node, SZ)
            check("an integral with bounds writes", w ~= nil, werr)
            if w then
                local rebuilt = mexpru.new_container(w, mexpru.last_slot(w))
                local ok, want, got = ast_mexpr.verify(fs, rebuilt, {}, ns, node)
                check("...and round-trips through its pair", ok,
                        ok or (tostring(want) .. " vs " .. tostring(got)))
            end
        end
    end

    -- ------------------------------------------------- an indefinite integral: no bounds at all
    do
        local c = mformula_latex.from_latex(fs, SZ, "\\int x \\,d x")
        local node, err, ns = mexpr_ast.build(fs, c, {})
        check("the indefinite integral parses", node ~= nil, err)
        if node then
            local w, werr = ast_mexpr.build(fs, c.root, ns, node, SZ)
            check("...writes with no sides", w ~= nil, werr)
            if w then
                local rebuilt = mexpru.new_container(w, mexpru.last_slot(w))
                local ok, want, got = ast_mexpr.verify(fs, rebuilt, {}, ns, node)
                check("...and round-trips", ok, ok or (tostring(want) .. " vs " .. tostring(got)))
            end
        end
    end

    -- ------------------------------------------------- the report, end to end
    do
        local src = "\\int \\sum \\limits^{N}_{k=0}e^{-jk(\\delta t+\\beta )w}\\,dt"
        local c = mformula_latex.from_latex(fs, SZ, src)
        local node, err, ns = mexpr_ast.build(fs, c, {})
        check("the reported formula parses", node ~= nil, err)
        local target = nil
        local function walk(n)
            if type(n) ~= "table" or not n.type or target then
                return
            end
            if n.type == ast.ADD then
                target = n
            end
            for i = 1, #n do
                walk(n[i])
            end
        end
        walk(node)
        check("the + inside the sum is found", target ~= nil)
        if target then
            local opts = transforms.offers(ns, node, target[2][1])
            check("distribute offers on the +", #opts == 1, #opts)
            if #opts == 1 then
                local result = transforms.apply(opts[1].id, ns, node, opts[1].params)
                check("...applies", result ~= nil)
                if result then
                    local w, werr = ast_mexpr.build(fs, c.root, ns, result, SZ)
                    check("...and the integral around it writes back", w ~= nil, werr)
                    if w then
                        local rebuilt = mexpru.new_container(w, mexpru.last_slot(w))
                        local ok, want, got = ast_mexpr.verify(fs, rebuilt, {}, ns, result)
                        check("...and round-trips whole", ok,
                                ok or (tostring(want) .. " vs " .. tostring(got)))
                    end
                end
            end
        end
    end

    if checks_failed == 0 then
        print("PASS: integrals write as their pair (" .. checks_run .. " checks)")
    end
    return checks_failed == 0
end

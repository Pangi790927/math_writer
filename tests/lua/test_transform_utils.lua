--[[
test_transform_utils.lua - the plugin building blocks, on hand-built trees.

THE ASSUMPTIONS:
  - swap_in_parent never mutates the source, shares every subtree off the path, and SPLICES a sum
    that lands directly in a sum.
  - product is flat, drops a unit factor, and gathers every sign onto ONE leading number.
  - peel_cells / through_cells look through CELLs and nothing else.

On hand-built trees rather than parsed ones, so a change in the parser's shapes cannot make these
pass or fail - the parse-level behaviour is test_distribute_nested's.
@date 2026-09-13 19:55
]]

package.path = package.path .. ";./scripts/?.lua"

local ast = require("ast")
local tu = require("transform_utils")

local checks_run, checks_failed = 0, 0
local function check(name, cond, got)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name .. (got ~= nil and ("  (got: " .. tostring(got) .. ")") or ""))
    end
end

function run_test()
    local ns = ast.new_ns()
    local function var()
        return ast.new_vref(ns, ast.new_var(ns, "v").id)
    end

    -- ------------------------------------------------------------------ swap_in_parent
    do
        local x, y, a, b = var(), var(), var(), var()
        local mul = ast.new_mul(ns, a, b)
        local root = ast.new_add(ns, x, mul, y)
        local parents = ast.parent_map(root)
        local new = ast.new_add(ns, var(), var())

        local out = tu.swap_in_parent(ns, root, parents, mul, new)
        check("a sum landing in a sum is spliced", out.type == ast.ADD and #out == 4, #out)
        check("siblings are shared", rawequal(out[1], x) and rawequal(out[4], y))
        check("the source is untouched", #root == 3 and rawequal(root[2], mul))

        local deep = ast.new_mul(ns, var(), ast.new_cell(ns, ast.new_add(ns, var(), var())))
        local top = ast.new_add(ns, var(), deep)
        local replaced = tu.swap_in_parent(ns, top, ast.parent_map(top), deep[2], var())
        check("a non-sum replacement goes in place", replaced[2].type == ast.MUL
                and replaced[2][2].type == ast.VREF)

        local stray = var()
        local none, reason = tu.swap_in_parent(ns, root, parents, stray, var())
        check("a node outside the tree is refused with a reason", none == nil and reason ~= nil)
    end

    -- ------------------------------------------------------------------ product
    do
        local a, b, c = var(), var(), var()
        local p = tu.product(ns, {a, ast.new_mul(ns, b, c)})
        check("a product factor is spliced", p.type == ast.MUL and #p == 3 and rawequal(p[2], b))

        p = tu.product(ns, {a, ast.new_num(ns, 1, 1, -1), b})
        check("the sign moves to the front as -1", p.type == ast.MUL and #p == 3
                and p[1].type == ast.NUM and p[1][1] == 1 and p[1][3] == -1 and rawequal(p[2], a))

        p = tu.product(ns, {ast.new_num(ns, 2), a, ast.new_num(ns, 1, 1, -1)})
        check("the sign lands on a leading number", p.type == ast.MUL and #p == 2
                and p[1][1] == 2 and p[1][3] == -1)

        p = tu.product(ns, {ast.new_num(ns, 1, 1, -1), ast.new_num(ns, 1, 1, -1), a})
        check("two signs cancel, and a lone survivor is unwrapped", rawequal(p, a))

        p = tu.product(ns, {ast.new_num(ns, 1)})
        check("nothing left is the number 1", p.type == ast.NUM and p[1] == 1 and p[3] == 1)
    end

    -- ------------------------------------------------------------------ cells
    do
        local s = ast.new_add(ns, var(), var())
        local outer = ast.new_cell(ns, ast.new_cell(ns, s))
        local m = ast.new_mul(ns, var(), outer)
        check("peel_cells reaches the sum", rawequal(tu.peel_cells(outer), s))
        check("peel_cells leaves a non-cell alone", rawequal(tu.peel_cells(s), s))
        local holder, slot = tu.through_cells(ast.parent_map(m), s)
        check("through_cells finds the product and the outer cell",
                rawequal(holder, m) and rawequal(slot, outer))
    end

    if checks_failed == 0 then
        print("PASS: transform_utils builds what it promises (" .. checks_run .. " checks)")
    end
    return checks_failed == 0
end

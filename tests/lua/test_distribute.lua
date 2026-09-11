--[[
test_distribute.lua - what a transformation copies, and what it lets travel.

THE ASSUMPTION: a subtree is copied if and only if it lands in the output MORE THAN ONCE.

That is not a performance preference, it is the whole reason a transformation can be shown at all.
The result has to become glyphs again (ast_mexpr), and the only way to draw a NAME is to copy the
glyphs it was read from - a name is stored as an assembled string, which is an identity key and not
a drawing. A node minted fresh has nothing to copy from, so every unnecessary copy is a subtree whose
decoration, size and spacing have to be re-derived, or refused.

WHAT WENT WRONG WHEN THIS WAS NOT ASSERTED: distribute copied each of the sum's own terms, though
each lands in exactly one output term. `a(b+c)` produced a `c` that nothing had ever drawn, in a
result whose other three leaves were all originals. Author, 2026-09-12, on seeing it: "there is no
point in creating a new reference". A bare letter made that look harmless; `2x` or a fraction in the
same position is a whole subtree of loss.

SO THE CHECKS BELOW ARE ABOUT NODE IDENTITY (rawequal), not about shape. Shape cannot see this: a
copy and its original have the same shape by construction, which is exactly why the defect survived
being tested from two other directions.

THE ONE THING THAT MUST BE COPIED is the factor surrounding the sum, because it lands in every term
and one node cannot sit in two places under one id (docs/phase2_design.md section 10, "the id is the
real name").
]]

package.path = package.path .. ";./scripts/?.lua"

local char = require("char")
local mexpru = require("mexpru")
local mformula_latex = require("mformula_latex")
local mexpr_ast = require("mexpr_ast")
local transforms = require("transforms")
local ast = require("ast")

local SZ = mexpru.DEFAULT_SIZE

local checks_run, checks_failed = 0, 0
local function check(name, cond, got)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name .. (got ~= nil and ("  (got: " .. tostring(got) .. ")") or ""))
    end
end

-- The first node of `want` type found anywhere under `node`.
local function find(node, want)
    if type(node) ~= "table" or not node.type then
        return nil
    end
    if node.type == want then
        return node
    end
    for i = 1, #node do
        local hit = find(node[i], want)
        if hit then
            return hit
        end
    end
    return nil
end

function run_test()
    local fs = char.load_font_set()
    local container = mformula_latex.from_latex(fs, SZ, "a(b+c)")
    local root, err, ns = mexpr_ast.build(fs, container, {})
    check("setup: a(b+c) parses", root ~= nil, err)
    if not root then
        return false
    end

    local add = find(root, ast.ADD)
    check("setup: it has a sum", add ~= nil)
    local a_node, b_node, c_node = root[1], add and add[1], add and add[2]
    check("setup: the shape is MUL(a, ADD(b, c))",
            root.type == ast.MUL and a_node ~= nil and b_node ~= nil and c_node ~= nil,
            ast.type_name(root.type))
    if not (add and a_node and b_node and c_node) then
        return false
    end

    local result, terr = transforms.distribute(ns, root, add.id)
    check("distribute produces a tree", result ~= nil, terr)
    if not result then
        return false
    end

    -- ------------------------------------------------------------------ the shape it produced
    check("the result is a sum of two products",
            result.type == ast.ADD and #result == 2
                    and result[1].type == ast.MUL and result[2].type == ast.MUL,
            ast.type_name(result.type) .. "/" .. #result)

    -- ------------------------------------------------------------------ what travelled
    --[[ Each term of the ORIGINAL sum lands in exactly one output term, so each is the very node it
    always was. This is the check the defect above would fail. ]]
    check("the first term's own factor travelled", rawequal(result[1][2], b_node))
    check("the second term's own factor travelled too", rawequal(result[2][2], c_node))

    -- ------------------------------------------------------------------ and what was copied
    check("the first output term keeps the original surrounding factor",
            rawequal(result[1][1], a_node))
    --[[ The second one CANNOT be the same node - it sits in a different place in the same tree, and
    an id names one place. It must still be the same VARIABLE, or the algebra is wrong rather than
    the bookkeeping. ]]
    check("the second term's surrounding factor is a fresh node",
            not rawequal(result[2][1], a_node))
    check("...still naming the same variable",
            result[2][1].type == ast.VREF and result[2][1][1] == a_node[1],
            tostring(result[2][1][1]) .. " vs " .. tostring(a_node[1]))

    -- ------------------------------------------------------------------ the source is untouched
    --[[ A transformation makes a new cell and leaves the old one alone (docs/phase2_design.md): the
    old mexpr is still on screen and its tree must keep describing it. ]]
    check("the source sum still holds its own terms",
            rawequal(add[1], b_node) and rawequal(add[2], c_node))
    check("the source product still holds the sum", rawequal(root[2], add))

    -- ------------------------------------------------------------------ one namespace
    --[[ SAME NAMESPACE, deliberately: shared nodes keep their ids, which is what lets "has this
    changed?" be answered by identity instead of by comparing shapes. ]]
    check("the result lives in the namespace it came from",
            rawequal(ns.by_id[result.id], result))

    if checks_failed == 0 then
        print("PASS: only what is used twice is copied (" .. checks_run .. " checks)")
    end
    return checks_failed == 0
end

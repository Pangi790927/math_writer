--[[
test_node_identity.lua - `a == b` on two mexpr handles is IDENTITY, and mexpru.same() uses it.

Until 2026-09-05 `==` between two mexpr nodes raised "attempt to perform operation on incompatible
vc objects": the shared metatable installs __eq, but it dispatches to a per-class handler and
mexpr_t had never registered one. mexpru.same() worked around that by comparing tostring() output -
which contains the node's own pointer, so it was correct, but it reached that pointer by running
std::format over it and interning the result as a Lua string, twice per comparison, on the path
index_of() walks in an O(n) loop. CLAUDE.md's Law 1 is written from exactly this.

These checks exist because the workaround is only safe to delete if `==` really behaves - including
the two cases the old spelling handled by accident: a nil operand, and two DIFFERENT handles that
name the same underlying node.
]]

package.path = package.path .. ";./scripts/?.lua"

local vc = require("virt_composer")
local char = require("char")
local mexpru = require("mexpru")
local mformula_new = require("mformula_new")

local checks_run, checks_failed = 0, 0
local function check(name, cond, got)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name .. (got ~= nil and ("  (got: " .. tostring(got) .. ")") or ""))
    end
end

local SZ = 12

function run_test()
    local fs = char.load_font_set()
    local c = mformula_new.new(fs, SZ)
    local root = c.root
    local kid = mexpru.u(root).children[1]

    -- ---------------------------------------------------------------- raw ==
    local ok, err = pcall(function() return root == kid end)
    check("comparing two mexpr handles no longer throws", ok, err)
    check("a node equals itself", root == root)
    check("two different nodes are not equal", not (root == kid))

    --[[ The case that matters most: a SECOND handle onto the same node, which is what every tree
    walk produces (anchor_at()/get_parent() each hand back a fresh ref). Identity has to follow the
    node, not the handle - a pointer comparison does, an ordinary userdata comparison would not. ]]
    local again = kid:get_parent()
    check("a second handle onto the same node compares equal", again == root)
    check("...and mexpru.same() agrees", mexpru.same(again, root))

    -- ---------------------------------------------------------------- nil operands
    check("nil == node is false, not an error", not (nil == root))
    check("same(nil, node) is false", not mexpru.same(nil, root))
    check("same(node, nil) is false", not mexpru.same(root, nil))
    check("same(nil, nil) is true - both absent IS the same absence",
            mexpru.same(nil, nil))

    -- ---------------------------------------------------------------- index_of, the hot caller
    local kids = mexpru.u(root).children
    check("index_of finds a child by identity", mexpru.index_of(kids, kids[1]) == 1,
            mexpru.index_of(kids, kids[1]))
    check("index_of returns nil for a node that isn't in the list",
            mexpru.index_of(kids, root) == nil)

    print("checks: " .. checks_run .. ", failed: " .. checks_failed)
    if checks_failed > 0 then
        return false
    end
    print("PASS: node identity - == is registered, same()/index_of ride on it")
    return true
end

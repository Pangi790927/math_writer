--[[
test_gc_hypothesis.lua - minimal, targeted regression test for the mexpr_t::~mexpr_t()
parent-pointer bug (fixed 2026-09-04, math_expr_composer.h): a rebuild that reuses an EXISTING
child (mexpr_supsub() re-parents it to the new node on construction, same as any compose call)
leaves the OLD, discarded node still referencing that same child in its own subobjs. Before the
fix, that old node's destructor unconditionally nulled every child's ->parent when it was
eventually garbage-collected - even though the child had since been correctly re-parented to the
NEW node - silently corrupting it at an unpredictable, GC-timing-dependent later point. See
test_int_crash.lua for the same bug exercised via a real, representative formula and a full click
sweep; this file isolates the exact minimal repro (from_latex()'s handling of two immediately-
adjacent sup/sub markers, e.g. "x^{2}_{3}") for a fast, direct check.
]]

package.path = package.path .. ";./scripts/?.lua"

local mexpru = require("mexpru")
local char = require("char")
local mformula_latex = require("mformula_latex")

function run_test()
    local fs = char.load_font_set()
    local SZ = 10

    local c = mformula_latex.from_latex(fs, SZ, "x^{2}_{3}")
    local S = mexpru.u(c.root).children[1]
    local base = mexpru.u(S).base

    local before = base:get_parent()
    collectgarbage("collect")
    collectgarbage("collect")
    collectgarbage("collect")
    local after = base:get_parent()

    if before == nil then
        print("FAIL: base had no parent even before GC - broken independent of this bug")
        return false
    end
    if after == nil then
        print("FAIL: base's parent pointer was wiped by GC of the discarded intermediate supsub - the destructor fix regressed")
        return false
    end
    if not mexpru.same(before, after) then
        print("FAIL: base's parent changed identity across GC (expected the same node before and after)")
        return false
    end

    print("PASS: base's parent pointer survives GC of the discarded intermediate supsub")
    return true
end

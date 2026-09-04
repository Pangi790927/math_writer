--[[
test_int_crash.lua - regression test for the mexpr_t::~mexpr_t() parent-pointer bug (fixed
2026-09-04, math_expr_composer.h): clicking (hit_test) anywhere across a real, representative
formula must never crash, regardless of garbage-collection timing. The original bug only
manifested once a discarded intermediate node (created by a "rebuild reusing an existing child"
pattern - here, from_latex()'s handling of two immediately-adjacent sup/sub markers, e.g.
"\int ^{X}_{0}") was actually garbage-collected, which could happen on ANY allocation, arbitrarily
later - hence forcing a full GC cycle before every single click below, to make the check
deterministic rather than luck-of-the-timing.
]]

package.path = package.path .. ";./scripts/?.lua"

local vc = require("virt_composer")
local char = require("char")
local mexpru = require("mexpru")
local mformula_new = require("mformula_new")
local mformula_latex = require("mformula_latex")

function run_test()
    local fs = char.load_font_set()
    local SZ = 10

    local src = "F(x) = \\int ^{X}_{0}1\\frac{x^{2}_{n+1}x_{n+2}}{2} dx (a+b)^{2} -> a^{2} + 2ab + b^{2}"
    local c = mformula_latex.from_latex(fs, SZ, src)
    print("parsed ok, root children count = " .. #mexpru.u(c.root).children)

    -- Overall extent of the whole formula, to scan a grid of click points across it.
    local rootbb = vc.mexpr_get_bb(c.root)
    print(string.format("root bb: tl=(%.1f,%.1f) br=(%.1f,%.1f)", rootbb.tl.x, rootbb.tl.y, rootbb.br.x, rootbb.br.y))

    local pad = 10
    local failures = 0
    local total = 0
    local step = 3
    for x = rootbb.tl.x - pad, rootbb.br.x + pad, step do
        for y = rootbb.tl.y - pad, rootbb.br.y + pad, step do
            total = total + 1
            collectgarbage("collect")
            local ok, err = pcall(mformula_new.hit_test, c, fs, SZ, {x = x, y = y})
            if not ok then
                failures = failures + 1
                print(string.format("CRASH at click (%.1f, %.1f): %s", x, y, tostring(err)))
            end
        end
    end
    print(string.format("scanned %d points, %d crashed", total, failures))

    if failures > 0 then
        return false
    end
    print("PASS: no crashes across the whole formula's click area")
    return true
end

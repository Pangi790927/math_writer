--[[
test_int_size.lua - \\int must render visually bigger (char.lua's own size_delta_by_desc, matching
main.lua's demo convention) WITHOUT that boost leaking into u(_).sz, which is a LOGICAL "what level
does this belong to" tag (cursor height via cursor_metrics(), and the base size any later supsub
built off this glyph sizes its own sup/sub relative to) - not a visual one. u(_).sz staying at the
surrounding NOMINAL size is what keeps a cursor parked on \\int (or a "^{X}" built on top of it)
from rendering at ~4x a normal glyph's height (found live 2026-09-04 - "the integral carries its
real size next which breaks the cursor").
]]

package.path = package.path .. ";./scripts/?.lua"

local vc = require("virt_composer")
local char = require("char")
local mexpru = require("mexpru")
local mformula_new = require("mformula_new")
local mformula_latex = require("mformula_latex")

local checks_run, checks_failed = 0, 0
local function check(name, cond)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name)
    end
end

function run_test()
    local fs = char.load_font_set()
    local SZ = 10

    local c = mformula_latex.from_latex(fs, SZ, "\\int a")
    local children = mexpru.u(c.root).children
    check("2 children (int glyph, a)", #children == 2)
    local int_glyph = children[1]
    local a_glyph = children[2]

    -- Logical level: BOTH glyphs tag u(_).sz with the surrounding nominal size - \\int's own
    -- visual boost must not leak into it.
    check("int glyph's own u(_).sz stays at the surrounding nominal size (not boosted)",
            mexpru.u(int_glyph).sz == SZ)
    check("'a' glyph stays at plain SZ too", mexpru.u(a_glyph).sz == SZ)

    -- Visual size: \\int's own real ink IS genuinely bigger than a plain glyph built at the same
    -- nominal SZ (the boost is baked into its construction, independent of u(_).sz).
    local int_bb = vc.mexpr_get_bb(int_glyph)
    local a_bb = vc.mexpr_get_bb(a_glyph)
    local int_height = int_bb.br.y - int_bb.tl.y
    local a_height = a_bb.br.y - a_bb.tl.y
    check("\\int's own real ink is taller than a plain glyph at the same nominal size ("
            .. string.format("%.1f vs %.1f", int_height, a_height) .. ")", int_height > a_height * 1.5)

    -- The cursor parked directly on \\int must render at the SAME height a plain glyph at the
    -- surrounding nominal size would - not \\int's own boosted line-height (the live bug this
    -- test guards against).
    c.cursor_pos = vc.wref_mexpr(int_glyph)
    local r_int = mformula_new.cursor_rect(c, {x = 0, y = 0}, fs)
    c.cursor_pos = vc.wref_mexpr(a_glyph)
    local r_a = mformula_new.cursor_rect(c, {x = 0, y = 0}, fs)
    local h_int, h_a = r_int.bottom - r_int.top, r_a.bottom - r_a.top
    check(string.format("cursor on \\int has the SAME height as cursor on a plain glyph (%.1f vs %.1f)", h_int, h_a),
            math.abs(h_int - h_a) < 0.01)

    -- Round-trips back to the same macro name regardless of the size it was built at.
    local latex = mformula_latex.to_latex(c)
    check("round-trip text unaffected by the size fix ('" .. latex .. "')", latex == "\\int a")

    print("checks: " .. checks_run .. ", failed: " .. checks_failed)
    if checks_failed > 0 then
        return false
    end
    print("PASS: \\int renders bigger without breaking cursor height or supsub sizing")
    return true
end

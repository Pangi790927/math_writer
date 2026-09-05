--[[
test_sprint_landmarks.lua - what Shift+Left/Right (the "sprint") is allowed to stop on.

Landmarks are brackets - either half - plus "=" and ";": the places a formula visually divides into
parts, so stopping on them lands the caret where you'd want to type far more often than a fixed
stride would. Requested 2026-09-05 ("jump to a boundry or ( inside a horiz", then "I want it on
both opens and exits and also the glyph = and the glyph ;").

The case worth pinning hardest is the LAST one below: a bracket that carries an exponent. In
"(a)^{2}" the ")" is the supsub's own BASE, so the row itself holds only the supsub - a scan that
looks at siblings alone sees no bracket there and sprints straight past the whole group. That was
live behaviour until it was fixed ("shift doesn't stop at )"), and it is the fourth place the same
blind spot has appeared, so it gets an explicit test rather than trusting the shared helper alone.
]]

package.path = package.path .. ";./scripts/?.lua"

local vc = require("virt_composer")
local char = require("char")
local mexpru = require("mexpru")
local mformula_new = require("mformula_new")

local checks_run, checks_failed = 0, 0
local function check(name, cond)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name)
    end
end

local function glyph(fs, ascii, sz)
    local entry = char.find_by_ascii(ascii)
    local g = mexpru.mexpr_symbol(fs, {size = sz, code = entry.ncod}, true)
    mexpru.u(g).sz = sz
    return g
end

function run_test()
    local fs = char.load_font_set()
    local SZ = 12
    local is_lm = mformula_new.is_sprint_landmark

    -- Ordinary content is NOT a landmark - otherwise the sprint would be an ordinary arrow.
    check("a plain letter is not a landmark", not is_lm(glyph(fs, "m", SZ)))
    check("a digit is not a landmark", not is_lm(glyph(fs, "7", SZ)))
    check("'+' is not a landmark", not is_lm(glyph(fs, "+", SZ)))

    -- The two extra glyph landmarks.
    check("'=' is a landmark", is_lm(glyph(fs, "=", SZ)))
    check("';' is a landmark", is_lm(glyph(fs, ";", SZ)))

    -- Brackets, BOTH halves - stopping only on opens would make the sprint asymmetric.
    do
        local o = glyph(fs, "(", SZ)
        mexpru.u(o).bracket = {is_open = true, type = vc.MEXPR_BRACKET_ROUND}
        local c = glyph(fs, ")", SZ)
        mexpru.u(c).bracket = {is_open = false, type = vc.MEXPR_BRACKET_ROUND, peer = mexpru.u(o)}
        mexpru.u(o).bracket.peer = mexpru.u(c)
        check("an open bracket is a landmark", is_lm(o))
        check("a close bracket is a landmark too", is_lm(c))
    end

    -- The regression: "(a)^{2}" - the ")" is the supsub's BASE, so the ROW holds only the supsub.
    do
        local c = glyph(fs, ")", SZ)
        mexpru.u(c).bracket = {is_open = false, type = vc.MEXPR_BRACKET_ROUND}
        local sup = mexpru.horiz(fs, {glyph(fs, "2", SZ - 2)}, SZ - 2)
        local compound = mexpru.supsub(fs, c, sup, nil)
        check("a supsub whose BASE is a bracket is a landmark - the row slot still 'is' that ')'",
                is_lm(compound))
    end

    -- ...and the same look-through for a glyph landmark carried as a base ("=^{2}" is odd but the
    -- rule shouldn't care which landmark it is).
    do
        local eq = glyph(fs, "=", SZ)
        local sup = mexpru.horiz(fs, {glyph(fs, "2", SZ - 2)}, SZ - 2)
        check("a supsub whose base is '=' is a landmark",
                is_lm(mexpru.supsub(fs, eq, sup, nil)))
    end

    -- A supsub over ordinary content stays ordinary - the look-through must not make EVERY
    -- compound a landmark.
    do
        local base = glyph(fs, "x", SZ)
        local sup = mexpru.horiz(fs, {glyph(fs, "2", SZ - 2)}, SZ - 2)
        check("a supsub over a plain letter is NOT a landmark",
                not is_lm(mexpru.supsub(fs, base, sup, nil)))
    end

    -- A horiz isn't a symbol and carries no bracket - must not be mistaken for one via whatever
    -- its symb field happens to default to.
    check("a horiz is not a landmark",
            not is_lm(mexpru.horiz(fs, {glyph(fs, "m", SZ)}, SZ)))

    print("checks: " .. checks_run .. ", failed: " .. checks_failed)
    if checks_failed > 0 then
        return false
    end
    print("PASS: sprint stops on brackets (both halves), '=' and ';', including ones carried as a base")
    return true
end

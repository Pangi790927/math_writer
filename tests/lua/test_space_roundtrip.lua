--[[
test_space_roundtrip.lua - a space typed inside a formula survives save and load.

It did not. to_latex() wrote the space glyph as a bare " ", and a bare space in LaTeX source is a
token separator rather than content - the parser skipped it, so every space vanished the next time
the document was opened. Reported 2026-09-05: "save does not save spaces". It is written as "\\ "
now, a LaTeX control space, which the parser's escaped-literal branch already understood.

math_writer.save IS to_latex output (content.serialize -> editor.to_text), so a to_latex/from_latex
round trip is exactly the save/load path and covers it without touching the disk.
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

-- Builds a one-row formula straight from a list of glyph descriptors: an ascii character, or
-- {desc = "\\alpha"} for anything without one. Direct construction rather than driving the editor,
-- since what is under test is purely the serialisation.
local function formula_of(fs, items)
    local kids = {}
    for _, it in ipairs(items) do
        local entry = (type(it) == "table") and char.find_by_desc(it.desc) or char.find_by_ascii(it)
        local g = mexpru.mexpr_symbol(fs, {size = mexpru.physical_sz(SZ), code = entry.ncod}, true)
        mexpru.u(g).sz = SZ
        kids[#kids + 1] = g
    end
    local root = mexpru.horiz(fs, kids, SZ)
    mexpru.update_positions(root)
    return {root = root, cursor_pos = vc.wref_mexpr(kids[#kids]), version = 0}
end

local function count_spaces(container)
    local n = 0
    for _, kid in ipairs(mexpru.u(container.root).children) do
        local e = kid.symb and char.find_by_ncod(kid.symb.code)
        if e and e.acod == " " then n = n + 1 end
    end
    return n
end

function run_test()
    local fs = char.load_font_set()

    local c = formula_of(fs, {"a", " ", "b"})
    check("the row really contains a space", count_spaces(c) == 1, count_spaces(c))

    local latex = mformula_new.to_latex(c)
    check("the space serialises as a control space, not a bare one", latex == "a\\ b", latex)

    local back = mformula_new.from_latex(fs, SZ, latex)
    check("it survives the round trip", count_spaces(back) == 1, count_spaces(back))
    check("...and re-serialises identically", mformula_new.to_latex(back) == latex,
            mformula_new.to_latex(back))

    --[[ A run at the END matters most: a trailing bare space was indistinguishable from the
    separator to_latex() emits after a macro name, so it was the first thing to be eaten. ]]
    local c2 = formula_of(fs, {"x", " ", " ", " "})
    local l2 = mformula_new.to_latex(c2)
    check("three trailing spaces all survive",
            count_spaces(mformula_new.from_latex(fs, SZ, l2)) == 3,
            l2 .. " -> " .. count_spaces(mformula_new.from_latex(fs, SZ, l2)))

    --[[ from_latex() consumes ONE space after a macro name, because to_latex() always writes one
    there as a terminator. A real space glyph following a macro must not be swallowed by that rule. ]]
    local c3 = formula_of(fs, {{desc = "\\alpha"}, " ", "z"})
    local l3 = mformula_new.to_latex(c3)
    check("a space right after a macro name is not swallowed by its separator",
            count_spaces(mformula_new.from_latex(fs, SZ, l3)) == 1, l3)

    print("checks: " .. checks_run .. ", failed: " .. checks_failed)
    if checks_failed > 0 then
        return false
    end
    print("PASS: spaces survive to_latex/from_latex - alone, in runs, and after a macro")
    return true
end

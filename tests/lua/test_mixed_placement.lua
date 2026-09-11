--[[
test_mixed_placement.lua - all FOUR sup/sub placements survive a round-trip through LaTeX.

THE ASSUMPTION: one supsub node can place its two sides independently, and the file it is saved to
can say which is which.

    sup beside,  sub beside     x^{n}_{i}                    an ordinary index and power
    sup display, sub display    \sum\limits^{n}_{i}          a sum with its limits over and under
    sup beside,  sub DISPLAY    {\sum\limits_{i}}^{n}        a sum raised to a power
    sup DISPLAY, sub beside     {\sum\limits^{n}}_{i}        the mirror of it

WHY THE LAST TWO NEED A DIFFERENT SPELLING. `\limits` is ONE WORD ABOUT THE WHOLE NODE - it cannot
say "this side over, that side beside". LaTeX composes instead: a braced group carrying the DISPLAY
side, with the BESIDE side hung on the group. Author, 2026-09-10, refusing to let mixed placement be
rounded to one or the other: "latex can express it, imagine limit raised to the power, isn't it
composed of two? maybe we should do that too".

WHAT IT WAS BEFORE. Both mixed combinations wrote `\sum ^{n}_{i}` - all beside - so a limit with its
variable underneath and a power beside it silently flattened the moment it was saved, and the four
combinations the node can hold collapsed to two. The node was always right; only the file was lossy.

THE HALF THAT IS EASY TO BREAK, and the reason this file exists rather than a line in the LaTeX
round-trip test: reading it back turns on ONE bit. `{X\limits_{i}}^{n}` and `X\limits^{n}_{i}` look
identical to the sup/sub handler - by the time the `^` is read the braces are gone and both are
"a supsub, then a sup" - so the group marks its result (group_closed) and the handler refuses to
carry placement across that mark. Delete the mark and three of these four still pass, which is
exactly the kind of silent loss the round-trip is supposed to catch.

ASSERTED ON PLACEMENT, NOT ONLY ON THE STRING. A test that compared LaTeX alone would pass if both
sides came back display, since the string would still match on a second write. The placements are
read off the rebuilt node.
]]

package.path = package.path .. ";./scripts/?.lua"

local char = require("char")
local mexpru = require("mexpru")
local mformula_latex = require("mformula_latex")

local B = string.char(92)
local SZ = mexpru.DEFAULT_SIZE

local checks_run, checks_failed = 0, 0
local function check(name, cond, got)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name .. (got ~= nil and ("  (got: " .. tostring(got) .. ")") or ""))
    end
end

-- One glyph in its own horiz - the shape a sup/sub slot always has.
local function side(fs, txt)
    local e = char.find_by_ascii(txt)
    local g = mexpru.mexpr_symbol(fs, {size = mexpru.physical_sz(SZ), code = e.ncod}, true)
    mexpru.u(g).sz = SZ
    return mexpru.horiz(fs, {g}, SZ)
end

--[[ A `\sum` carrying both sides at the placements asked for. Built directly rather than typed,
because the point is the NODE's two independent placements - there is no LaTeX for the mixed ones
that does not already depend on the thing being tested. ]]
local function sum_with(fs, sup_place, sub_place)
    local e = char.find_by_desc(B .. "sum")
    local base = mexpru.mexpr_symbol(fs, {size = mexpru.physical_sz(SZ), code = e.ncod}, true)
    mexpru.u(base).sz = SZ
    local node = mexpru.supsub(fs, base, side(fs, "n"), side(fs, "i"), SZ, sup_place, sub_place)
    return {root = mexpru.horiz(fs, {node}, SZ)}
end

function run_test()
    local fs = char.load_font_set()
    local D, E = mexpru.PLACE_DISPLAY, mexpru.PLACE_BESIDE

    local cases = {
        {name = "beside / beside",   sup = E, sub = E, tex = B .. "sum ^{n}_{i}"},
        {name = "display / display", sup = D, sub = D, tex = B .. "sum " .. B .. "limits^{n}_{i}"},
        {name = "beside / display",  sup = E, sub = D,
         tex = "{" .. B .. "sum " .. B .. "limits_{i}}^{n}"},
        {name = "display / beside",  sup = D, sub = E,
         tex = "{" .. B .. "sum " .. B .. "limits^{n}}_{i}"},
    }

    for _, case in ipairs(cases) do
        local written = mformula_latex.to_latex(sum_with(fs, case.sup, case.sub))
        check(case.name .. ": writes the expected spelling", written == case.tex, written)

        local back = mformula_latex.from_latex(fs, SZ, written)
        local u = back and mexpru.u(mexpru.u(back.root).children[1])
        check(case.name .. ": comes back as one node", u ~= nil and u.kind == "supsub",
                u and u.kind)
        --[[ THE CHECK THAT MATTERS. Both mixed cases used to arrive with both sides beside, and a
        string comparison alone would not have noticed - the flattened form is stable. ]]
        check(case.name .. ": the sup keeps its placement", u and u.sup_place == case.sup,
                u and u.sup_place)
        check(case.name .. ": the sub keeps its placement", u and u.sub_place == case.sub,
                u and u.sub_place)

        -- and writing it again is a fixed point, so a save/load cycle does not drift
        check(case.name .. ": stable on a second write",
                back ~= nil and mformula_latex.to_latex(back) == written,
                back and mformula_latex.to_latex(back))
    end

    -- ------------------------------------------------------------------ the two are told apart
    do
        --[[ The pair the group mark exists for. Same node kind, same two sides, same order on the
        page - and different placements, decided only by whether the outer side was written inside
        the braces or outside them. ]]
        local grouped = mformula_latex.from_latex(fs, SZ,
                "{" .. B .. "sum " .. B .. "limits_{i}}^{n}")
        local plain = mformula_latex.from_latex(fs, SZ,
                B .. "sum " .. B .. "limits^{n}_{i}")
        local gu = mexpru.u(mexpru.u(grouped.root).children[1])
        local pu = mexpru.u(mexpru.u(plain.root).children[1])
        check("a sup written OUTSIDE the group is beside", gu.sup_place == E, gu.sup_place)
        check("a sup written under the same \\limits is display", pu.sup_place == D, pu.sup_place)
        check("...while both subs are display",
                gu.sub_place == D and pu.sub_place == D,
                tostring(gu.sub_place) .. "/" .. tostring(pu.sub_place))
    end

    -- ------------------------------------------------------------------ one side only
    do
        --[[ A node with a single side has nothing to be mixed WITH, so it keeps the plain
        spelling - the composed form would be noise. This is what stops the writer reaching for
        braces whenever it sees a display side. ]]
        local e = char.find_by_desc(B .. "sum")
        local base = mexpru.mexpr_symbol(fs, {size = mexpru.physical_sz(SZ), code = e.ncod}, true)
        mexpru.u(base).sz = SZ
        local only_sub = mexpru.supsub(fs, base, nil, side(fs, "i"), SZ, D, D)
        local out = mformula_latex.to_latex({root = mexpru.horiz(fs, {only_sub}, SZ)})
        check("a lone display side needs no braces", out:find("{" .. B .. "sum", 1, true) == nil,
                out)
        check("...and still says \\limits", out:find(B .. "limits", 1, true) ~= nil, out)
    end

    if checks_failed == 0 then
        print("PASS: all four sup/sub placements round-trip (" .. checks_run .. " checks)")
    end
    return checks_failed == 0
end

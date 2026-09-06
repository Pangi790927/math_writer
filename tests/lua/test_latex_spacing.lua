--[[
test_latex_spacing.lua - spacing survives the LaTeX boundary, in both directions.

Three things landed together here on 2026-09-06, because they are the same seam.

1. "\," stopped becoming a comma. The escaped-literal branch asked only "is the next character a
   letter?" and took everything else at face value, so LaTeX's spacing commands were read as the
   punctuation that follows the backslash: "\int f(x)\,dx" loaded with a COMMA in it, silently, and
   the result was a perfectly valid different formula.

2. A literal space is now KEPT. LaTeX treats source whitespace as a token separator; this app is an
   editor and keeps what was typed - "especialy spaces, since I like them, I know latex kinda
   doesn't care about them, but my app will, even if loosing them when exporting".

3. Nothing is discarded. A backslash before a non-letter resolves as an escape, else as a named
   command from the catalog, else as the plain character - three routes, no fourth that drops it.

Each spacing command is the SPACE glyph (no ink) with its own advance from char.adv_by_desc, TeX's
own fractions of an em. mexpr_symbol sizes an inkless glyph from its advance, so the width IS the
atom - and each keeps its own name, so a gap comes back out as the gap it was.
]]

package.path = package.path .. ";./scripts/?.lua"

local vc = require("virt_composer")
local char = require("char")
local mexpru = require("mexpru")
local mformula_latex = require("mformula_latex")

local B = string.char(92)
local SZ = 12
local EM = 36.0   -- the default level's point size

local checks_run, checks_failed = 0, 0
local function check(name, cond, got)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name .. (got ~= nil and ("  (got: " .. tostring(got) .. ")") or ""))
    end
end

local function latex_of(fs, src)
    return mformula_latex.to_latex(mformula_latex.from_latex(fs, SZ, src))
end

local function width_of(fs, src)
    local bb = vc.mexpr_get_bb(mformula_latex.from_latex(fs, SZ, src).root)
    return bb.br.x - bb.tl.x
end

function run_test()
    local fs = char.load_font_set()

    -- ---------------------------------------------------------------- the corruption is gone
    --[[ The headline case, in the form it actually arrives in - nobody writes "\," on its own,
    they paste an integral. ]]
    do
        local out = latex_of(fs, B .. "int f(x)" .. B .. ",dx")
        check("a pasted integral keeps its thin space",
                out == B .. "int f(x)" .. B .. ",dx", out)
        check("...and grows no comma", out:find(",", 1, true) == nil
                or out:find(B .. ",", 1, true) ~= nil, out)
    end

    -- ---------------------------------------------------------------- each gap is its own width
    --[[ Measured against the same pair with no gap, so this stays honest if the font or the size
    table ever moves. TeX's own fractions: 3/18, 4/18, 5/18 of an em, then 1 and 2. ]]
    do
        local base = width_of(fs, "ab")
        for _, case in ipairs({
                {B .. ",",      3 / 18},
                {B .. ":",      4 / 18},
                {B .. ";",      5 / 18},
                {B .. "quad ",  1.0},
                {B .. "qquad ", 2.0},
        }) do
            local got = width_of(fs, "a" .. case[1] .. "b") - base
            local want = case[2] * EM
            check(string.format("%s is %.1fpx wide (TeX says %.1f)", case[1], got, want),
                    math.abs(got - want) < 0.5, got)
        end

        --[[ \! is a NEGATIVE thin space in TeX. Zero here - adv_em reads a negative value as "no
        override" - so it survives as a real, deletable, round-tripping atom that simply does not
        pull anything back. Kept rather than dropped on purpose: "I don't see why I should drop
        them". ]]
        check(B .. "! adds no width but is still an atom",
                math.abs(width_of(fs, "a" .. B .. "!b") - base) < 0.5)
        check("..." .. B .. "! is a real atom in the row",
                #mexpru.u(mformula_latex.from_latex(fs, SZ, "a" .. B .. "!b").root).children == 3)
    end

    -- ---------------------------------------------------------------- a literal space is content
    do
        local c = mformula_latex.from_latex(fs, SZ, "a b")
        check("a pasted space becomes its own atom", #mexpru.u(c.root).children == 3,
                #mexpru.u(c.root).children)
        check("...written back as a control space", latex_of(fs, "a b") == "a" .. B .. " b",
                latex_of(fs, "a b"))
        check("...and it has real width", width_of(fs, "a b") > width_of(fs, "ab"))
    end

    -- ---------------------------------------------------------------- NO leak across saves
    --[[ The check that matters most, and the one a single round trip cannot make.

    A control SYMBOL ("\," , "\;" , "\|") must be written WITHOUT a trailing space: its name ends at
    the backslash-plus-one-character, so nothing can run into it, and LaTeX needs no separator. The
    writer used to add one anyway, harmlessly - until a literal space became content, at which point
    that space was read back as a real gap and every save/load cycle added another:

        a\,b  ->  a\, b  ->  a\, \ b  ->  a\, \ \ b

    So these round-trip THREE times. Twice would have looked clean on the first comparison. ]]
    for _, src in ipairs({"a" .. B .. ",b", "a" .. B .. ":b", "a" .. B .. ";b",
                          "a" .. B .. "!b", "a" .. B .. "|b", "a b",
                          "a" .. B .. "quad b", "a" .. B .. "qquad b",
                          B .. "int f(x)" .. B .. ",dx"}) do
        local one = latex_of(fs, src)
        local two = latex_of(fs, one)
        local three = latex_of(fs, two)
        check(src .. " does not accumulate spaces (" .. one .. ")",
                one == two and two == three, three)
    end

    -- ---------------------------------------------------------------- nothing is discarded
    --[[ Route 2 of the resolution order: a backslash before a non-letter that IS a name the catalog
    knows resolves to that glyph rather than being thrown away. ]]
    do
        check(B .. "| survives as itself", latex_of(fs, "a" .. B .. "|b") == "a" .. B .. "|b",
                latex_of(fs, "a" .. B .. "|b"))
    end

    -- ---------------------------------------------------------------- escapes, both directions
    --[[ Route 1, and it has to be tried FIRST: the catalog also holds a desc "\{" for cmsy's big
    brace, so a desc-first order turned every escaped "\{" into a bracket-sized one.

    "%", "#" and "&" are the export half of the same seam - each is special to LaTeX and a bare one
    breaks the document ("%" starts a comment and swallows the closing "$"), so they must come back
    out escaped. "$" always did; these three were missed. ]]
    for _, src in ipairs({B .. "{a" .. B .. "}", B .. "$", B .. "%", B .. "#", B .. "&",
                          B .. "_", "x^{2}+" .. B .. "{y" .. B .. "}"}) do
        check(src .. " round-trips escaped", latex_of(fs, src) == src, latex_of(fs, src))
    end

    -- ---------------------------------------------------------------- our own output is unchanged
    --[[ The separator space after a control WORD is still consumed - by every branch now, not just
    the plain-glyph one. The bracket commands never consumed theirs, which went unnoticed while
    spaces were skipped anyway and produced "\lvert \ a" the moment they were not. ]]
    for _, src in ipairs({
            B .. "lvert a" .. B .. "rvert ",
            B .. "sum " .. B .. "limits^{n}_{i}x",
            B .. "alpha " .. B .. "beta ",
            B .. "frac{1}{2}",
            B .. "begin{matrix}a" .. B .. B .. "b" .. B .. "end{matrix}",
            B .. "hat{x}",
    }) do
        check(src .. " is unaffected", latex_of(fs, src) == src, latex_of(fs, src))
    end

    print("checks: " .. checks_run .. ", failed: " .. checks_failed)
    if checks_failed > 0 then
        return false
    end
    print("PASS: spacing survives both directions, and does not accumulate")
    return true
end

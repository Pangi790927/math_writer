--[[
test_latex_groups.lua - a plain "{...}" group is read as grouping, not as content.

Found 2026-09-06 while being asked to pin down what was reported as an unknown-macro bug. It is not
one. An unrecognised macro on its own loses nothing but itself:

    1+\foo+2   ->   1++2

The damage came from the BRACES, and it was not local - it silently truncated the rest of the row:

    a{b}c                              ->  a{b            the "c" simply gone
    \frac{a}{b}+\text{q}+\frac{c}{d}   ->  \frac{a}{b}+{q   the second fraction gone

Cause: the two braces were asymmetric. parse_latex_children() breaks on "}" unconditionally - it was
written for callers that had already consumed the matching "{" (a sup/sub slot, a \frac argument) -
while "{" was handled by no branch at all and fell through to the ordinary-character path as a
literal glyph. So nothing ever opened a group, and every close ended the row.

\text is merely how most people MEET this: an unknown macro is dropped and leaves its group standing
bare. Any bare group did it, with no macro anywhere in sight - which is what these checks pin, so a
future reader does not go looking in the macro table for it.
]]

package.path = package.path .. ";./scripts/?.lua"

local vc = require("virt_composer")
local char = require("char")
local mexpru = require("mexpru")
local mformula_latex = require("mformula_latex")

local B = string.char(92)
local SZ = 12

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

function run_test()
    local fs = char.load_font_set()

    -- ---------------------------------------------------------------- nothing is truncated
    --[[ The heart of it: what follows a group has to survive. Each of these lost everything after
    the closing brace, with no error and nothing on screen to suggest text had gone missing. ]]
    for _, case in ipairs({
            {"a{b}c",   "abc"},
            {"{a}",     "a"},
            {"a{b}c{d}e", "abcde"},
            {"1+" .. B .. "text{n}+2", "1+n+2"},
            {B .. "frac{a}{b}+" .. B .. "text{q}+" .. B .. "frac{c}{d}",
                    B .. "frac{a}{b}+q+" .. B .. "frac{c}{d}"},
            {B .. "frac{1}{" .. B .. "text{n}}+z", B .. "frac{1}{n}+z"},
    }) do
        check(case[1] .. " keeps everything after the group", latex_of(fs, case[1]) == case[2],
                latex_of(fs, case[1]))
    end

    -- ---------------------------------------------------------------- a group is only grouping
    --[[ Braces delimit and nothing else - LaTeX gives them no visual effect - so the contents are
    spliced into the row and the braces themselves leave no trace. If they ever came back as atoms,
    "{a}" would render with visible brackets nobody typed. ]]
    do
        local c = mformula_latex.from_latex(fs, SZ, "a{bc}d")
        check("a group leaves no atoms of its own", #mexpru.u(c.root).children == 4,
                #mexpru.u(c.root).children)
        check("...and nests", latex_of(fs, "a{b{c}d}e") == "abcde", latex_of(fs, "a{b{c}d}e"))
        check("...deeply", latex_of(fs, "{{{a}}}") == "a", latex_of(fs, "{{{a}}}"))
    end

    -- ---------------------------------------------------------------- edges that must not throw
    --[[ Malformed input arrives from paste, so none of these may error - an empty group, and one
    that is never closed. ]]
    for _, src in ipairs({"{}", "a{}b", "a{b", "{", "}"}) do
        local ok = pcall(mformula_latex.from_latex, fs, SZ, src)
        check("'" .. src .. "' parses without erroring", ok)
    end
    check("an unclosed group still keeps its contents", latex_of(fs, "a{b") == "ab",
            latex_of(fs, "a{b"))

    -- ---------------------------------------------------------------- a literal brace is "\{"
    --[[ The escaped form is what to_latex() writes for a real brace GLYPH, so it has to survive
    the new branch untouched - otherwise the fix would eat the very characters it is meant to let
    people type. ]]
    for _, src in ipairs({B .. "{a" .. B .. "}", "x^{2}+" .. B .. "{y" .. B .. "}"}) do
        check(src .. " round-trips as a literal brace", latex_of(fs, src) == src, latex_of(fs, src))
    end

    -- ---------------------------------------------------------------- everything else is untouched
    --[[ Every OTHER use of braces is consumed by its own caller before the loop ever sees it - a
    sup/sub slot, a \frac argument, an environment body. This branch must only ever catch the ones
    left over, so these are the control group. ]]
    for _, src in ipairs({
            "x^{2}_{i}",
            B .. "frac{1}{2}+z",
            B .. "hat{x}+z",
            B .. "begin{matrix}a" .. B .. B .. "b" .. B .. "end{matrix}",
            "(a+b)^{2}",
            B .. "sum " .. B .. "limits^{n}_{i}x",
            B .. "mathop{lim}" .. B .. "limits_{x}",
    }) do
        check(src .. " is unaffected", latex_of(fs, src) == src, latex_of(fs, src))
    end

    --[[ And the thing that was blamed for it: an unknown macro with no group loses only itself.
    That was always true, and stays true - it is the evidence that the braces were the bug. ]]
    check("an unknown macro with no group takes nothing with it",
            latex_of(fs, "1+" .. B .. "foo+2") == "1++2", latex_of(fs, "1+" .. B .. "foo+2"))

    print("checks: " .. checks_run .. ", failed: " .. checks_failed)
    if checks_failed > 0 then
        return false
    end
    print("PASS: bare {...} groups parse as grouping, truncating nothing")
    return true
end

--[[
test_greek_letters.lua - a Greek glyph is a LETTER: it can be a free variable, a declaration's name,
and a binder's variable, exactly as `a` can.

THE ASSUMPTION: "is this a letter" is a question about the GLYPH, and the answer for `\pi` is yes.

It was no until 2026-09-11 - `is_letter` tested `#d == 1 and d:match("%a")`, which no desc longer
than one character can satisfy - so `\pi` fell through every letter branch in the parser and came
back "not parsed yet". That is an odd thing for the alphabet mathematics keeps its variables in.
Author: "pi and the other greeks should also be a letter, meaning the glyps only are also free".

WHAT SEPARATES A LETTER FROM AN OPERATOR HERE, and it is the reason this cannot be "anything whose
desc starts with a backslash": `\sum` and `\prod` are DRAWN as Greek capitals and are not letters,
while `\Sigma` and `\Pi` are the letters and are not operators. They are different glyphs with
different descs, and char.greek_letters holds only the second pair. The last check is the one that
guards that line - if someone ever populates that set from the keyboard tables instead
(greek_alt_shift maps `s` to `\sum`), it fails.

WHY THE SET LIVES IN char.lua: it is a property of the catalog, and the parser should not carry a
second opinion about what the catalog contains.
]]

package.path = package.path .. ";./scripts/?.lua"

local char = require("char")
local mexpru = require("mexpru")
local mformula_latex = require("mformula_latex")
local mexpr_ast = require("mexpr_ast")
local ast = require("ast")

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

local function tree(fs, src)
    local c = mformula_latex.from_latex(fs, SZ, src)
    if not c then
        return nil, "from_latex failed"
    end
    local node, err, ns = mexpr_ast.build(fs, c, {})
    if not node then
        return nil, err
    end
    return ast.to_string(ns, node)
end

local function name_of(fs, src)
    local c = mformula_latex.from_latex(fs, SZ, src)
    local pat = c and mexpr_ast.parse_name(fs, c)
    return pat and pat.text or nil
end

function run_test()
    local fs = char.load_font_set()

    -- ------------------------------------------------------------------ a free variable
    do
        local out, err = tree(fs, B .. "pi ")
        check("a lone greek letter builds", out ~= nil, err)
        check("...as a reference, like any other free letter",
                out ~= nil and out:sub(1, 3) == "(&,", out)

        --[[ The case the request actually came from - a formula nobody would write with Latin
        letters. If `\pi` stopped being a letter this reads as an unparseable row again. ]]
        out, err = tree(fs, "2" .. B .. "pi r")
        check("2*pi*r is a product of three factors", out ~= nil, err)
        check("...with the greek letter as one of them",
                out ~= nil and out:sub(1, 3) == "(*,", out)

        check("an uppercase greek letter is a letter too", tree(fs, B .. "Omega ") ~= nil)
    end

    -- ------------------------------------------------------------------ a declaration's name
    do
        --[[ Identity is the token walk, so a greek base keys by its DESC - `\mu,sub,(1),end` - and
        a use of it has to build the same string. Nothing special is done for greek here, which is
        the point: it goes down the ordinary letter path. ]]
        check("a greek letter can be a whole name", name_of(fs, B .. "pi ") == B .. "pi",
                name_of(fs, B .. "pi "))
        check("...with a subscript argument",
                name_of(fs, B .. "mu _{n}") == B .. "mu,sub,(1),end", name_of(fs, B .. "mu _{n}"))
        check("...and as a called function",
                name_of(fs, B .. "Phi (x)") == B .. "Phi(),(1)", name_of(fs, B .. "Phi (x)"))
    end

    -- ------------------------------------------------------------------ a binder's variable
    do
        --[[ BOTH KINDS OF BINDER, because they find their variable in completely different places:
        a sum harvests it from the free names of its subscript constraint, an integral takes the
        unit after its differential. Each has its own letter test, and they were both ASCII-only. ]]
        local out, err = tree(fs, B .. "sum " .. B .. "limits^{N}_{" .. B .. "alpha =1}"
                .. B .. "alpha ")
        check("a sum can bind a greek variable", out ~= nil, err)
        check("...spawning it by its desc", out ~= nil and out:find("%(#, " .. B .. "alpha:") ~= nil,
                out)

        out, err = tree(fs, B .. "int x" .. B .. ",d" .. B .. "theta ")
        check("an integral can bind a greek variable", out ~= nil, err)
        check("...taken from its differential",
                out ~= nil and out:find("%(#, " .. B .. "theta:") ~= nil, out)
    end

    -- ------------------------------------------------------------------ operators are not letters
    do
        --[[ THE LINE THIS FILE EXISTS TO HOLD. `\sum` is drawn as a capital sigma and is not a
        letter; `\Sigma` is the letter and is not an operator. Same for `\prod` and `\Pi`. Getting
        this wrong in either direction breaks something loudly - a letter that parses as a big
        operator, or an operator that parses as a variable - so both directions are asserted. ]]
        check("\\sum is not a letter", char.greek_letters[B .. "sum"] == nil)
        check("\\prod is not a letter", char.greek_letters[B .. "prod"] == nil)
        check("\\int is not a letter", char.greek_letters[B .. "int"] == nil)
        check("\\partial is not a letter", char.greek_letters[B .. "partial"] == nil)
        check("\\Sigma IS a letter", char.greek_letters[B .. "Sigma"] == true)
        check("\\Pi IS a letter", char.greek_letters[B .. "Pi"] == true)

        --[[ And the set has to actually be populated - an empty table would satisfy every "is not
        a letter" check above while quietly undoing the whole change. ]]
        local n = 0
        for _ in pairs(char.greek_letters) do n = n + 1 end
        check("the set holds a full alphabet", n >= 30, n)
    end

    if checks_failed == 0 then
        print("PASS: greek glyphs are letters (" .. checks_run .. " checks)")
    end
    return checks_failed == 0
end

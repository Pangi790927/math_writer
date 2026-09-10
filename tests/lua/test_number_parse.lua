--[[
test_number_parse.lua - mexpr_ast.parse_number(): a written decimal as an exact rational.

THE ASSUMPTION THIS PINS, and it is the one most likely to be "helpfully" broken later: the result
is **not reduced**. `3.14` is 314/100, not 157/50. docs/phase2_design.md section 4.2 fixes that
representation, and the reason it matters is that reducing is a NORMALISATION - it belongs to the
equality machinery of section 9, which decides when two spellings are the same thing, not to
reading a literal. A parser that quietly reduces has already made an equality decision on the
user's behalf, before there is anything to make it with.

Second assumption: the denominator is an INTEGER. `10^#frac` in Lua 5.4 evaluates to a float, and a
float denominator would poison every rational built from the literal - so the power is built by
repeated integer multiplication. If this file starts reporting 100.0 where it wants 100, that is
what changed.

WHAT IS DELIBERATELY NOT HERE: any notion that `sqrt(2)` is a number. It is - verbatim,
2026-09-07: "remember sqrt(2) is also a number" - but it reaches the bridge as `(2)^{1/2}`
(section 6c: the radical is rewritten on input and never exists as a node), which is an EXPRESSION
with a constant value. Whether an expression is constant is a question about its free variables,
answerable only once expressions can be parsed at all. parse_number() answers the smaller, purely
lexical question, and must not be extended to guess at the larger one.
]]

package.path = package.path .. ";./scripts/?.lua"

local mexpr_ast = require("mexpr_ast")

local checks_run, checks_failed = 0, 0
local function check(name, cond, got)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name .. (got ~= nil and ("  (got: " .. tostring(got) .. ")") or ""))
    end
end

local function shows(v)
    if not v then
        return "nil"
    end
    return string.format("%s%s/%s", v.sign < 0 and "-" or "", tostring(v.m), tostring(v.n))
end

function run_test()
    -- ---- accepted, with the exact rational each must produce -------------------------------
    local ok_cases = {
        {"0",      0,   1,  1},
        {"12",     12,  1,  1},
        {"3.14",   314, 100, 1},   -- NOT 157/50: see this file's header
        {"0.5",    5,   10, 1},
        {".5",     5,   10, 1},    -- a leading dot is a legal way to write it
        {"5.",     5,   1,  1},    -- and so is a trailing one
        {"-3",     3,   1,  -1},
        {"-0.25",  25,  100, -1},
        {"007",    7,   1,  1},    -- leading zeros are spelling, not value
        --[[ An explicit "+" is spelling too, added 2026-09-10 so a name argument may be written
        `F_{+1}` as readily as `F_{-1}`. It must produce sign = 1, i.e. be indistinguishable from
        the unsigned form - a "+" that produced anything else would make `+3` and `3` two different
        constants in a pattern. ]]
        {"+3",     3,   1,  1},
        {"+0.5",   5,   10, 1},
    }
    for _, c in ipairs(ok_cases) do
        local text, m, n, sign = c[1], c[2], c[3], c[4]
        local v = mexpr_ast.parse_number(text)
        check("[" .. text .. "] parses", v ~= nil, shows(v))
        if v then
            check("[" .. text .. "] = " .. sign .. "*" .. m .. "/" .. n,
                    v.m == m and v.n == n and v.sign == sign, shows(v))
            --[[ math.type() is nil for a non-number and "float" for 100.0 - either would mean the
            denominator stopped being an exact integer. ]]
            check("[" .. text .. "] denominator is an integer",
                    math.type(v.n) == "integer", math.type(v.n))
            check("[" .. text .. "] numerator is an integer",
                    math.type(v.m) == "integer", math.type(v.m))
        end
    end

    -- ---- refused ---------------------------------------------------------------------------
    --[[ "+" and its doubles sit beside "-" and "--1": ONE sign is stripped, never two, so a
    stacked or mixed pair still has to fail the digit match rather than quietly cancelling out. ]]
    local bad_cases = {"", ".", "-", "1.2.3", "1,5", "1e3", "abc", "1a", "--1", "-",
                       "+", "++1", "+-1", "-+1"}
    for _, text in ipairs(bad_cases) do
        check("refuses [" .. text .. "]", mexpr_ast.parse_number(text) == nil,
                shows(mexpr_ast.parse_number(text)))
    end

    if checks_failed > 0 then
        print(string.format("test_number_parse: %d/%d checks failed", checks_failed, checks_run))
        return false
    end
    return true
end

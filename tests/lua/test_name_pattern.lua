--[[
test_name_pattern.lua - mexpr_ast.parse_name(): a definition's name slot -> a name, its free
variables, and the pattern that describes how it is applied.

EVERY CASE HERE IS THE USER'S OWN, from the 2026-09-07 spec, and that is the point: this file is
the spec written down as something that runs. When one of these fires, the question to ask is not
"what did the parser do" but "did the rule change" - and if it did, the rule is what needs
rewriting first, here, before the code.

THE ASSUMPTION THIS PINS, and it is the one the whole definition box rests on: **arity is DERIVED,
not entered.** `n` is the number of free variables the name pattern turns out to contain, so the
number of parameter slots a definition shows is a consequence of what was typed in its first slot.
If that stops holding - if `n` ever becomes something the user sets - then editor_definition.lua's
signature row is describing something the parser no longer decides, and these tests are the first
place it will show.

THE SECOND ASSUMPTION: **a literal is not a parameter.** A quoted string and a number are constants,
so `a_'maxlim'` has arity ZERO while `a_n` has arity one. That is what makes `v_'max'` a plain named
variable rather than a function of `max`, which is what docs/phase2_design.md section 6 left open as
question (b).

Inputs are built through LaTeX (mformula_latex.from_latex) rather than by hand-assembling mexpr
nodes, so what is parsed is a tree the real editor could actually have produced.
]]

package.path = package.path .. ";./scripts/?.lua"

local char = require("char")
local mexpru = require("mexpru")
local mformula_latex = require("mformula_latex")
local mexpr_ast = require("mexpr_ast")

local checks_run, checks_failed = 0, 0
local function check(name, cond, got)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name .. (got ~= nil and ("  (got: " .. tostring(got) .. ")") or ""))
    end
end

local BS = string.char(92)

function run_test()
    local fs = char.load_font_set()

    local function parse(latex)
        local c = mformula_latex.from_latex(fs, mexpru.DEFAULT_SIZE, latex)
        if not c then
            return nil, "from_latex returned nil"
        end
        return mexpr_ast.parse_name(fs, c)
    end

    --[[ ACCEPTED. Each entry is {latex, expected pattern text, expected arity}. ]]
    local ok_cases = {
        -- the simplest name there is
        {"a",                 "a",                    0},
        -- letter with a subscript parameter
        {"a_{b}",             "a,sub,(1)",            1},
        -- a quoted literal index is NOT a parameter - this is `v_max`, a plain named variable
        {"a_{'maxlim'}",      "a,sub,'maxlim'",       0},
        -- quotes are what make several letters ONE name instead of a product
        {"'abc'",             "abc",                  0},
        -- call notation; `a` is the name, `x` the parameter
        {"a(x)",              "a(),(1)",              1},
        -- a decorated number is a name, if a strange one
        {"1_{u}",             "1,sub,(1)",            1},
        -- two arguments, comma separated
        {"F_{m,n}",           "F,sub,(1),(2)",        2},
        -- a quoted literal as a power
        {"a^{'abcd'}",        "a,sup,'abcd'",         0},
        -- the user's own nesting example
        {"a_{n_{m}}",         "a,sub,(1),sub,(2)",    2},
        -- the user's own call example
        {"f(x,y,z)",          "f(),(1),(2),(3)",      3},
        -- a numeric literal index, still arity 0
        {"1_{1}",             "1,sub,1",              0},
    }

    for _, case in ipairs(ok_cases) do
        local latex, want_text, want_arity = case[1], case[2], case[3]
        local pat, err = parse(latex)
        if not pat then
            check("accepts [" .. latex .. "]", false, err)
        else
            check("[" .. latex .. "] pattern", pat.text == want_text, pat.text)
            check("[" .. latex .. "] arity", pat.arity == want_arity, pat.arity)
        end
    end

    --[[ REJECTED. The message is not asserted - only that it IS rejected - because the wording is
    presentation and will change; what must not change is which side of the line each case is on. ]]
    local bad_cases = {
        -- a number cannot be APPLIED (note `1_u` above is fine - the rule is not "no digits")
        {"2(whatever)",  "a number applied"},
        -- two atoms at the same level is multiplication, not a name
        {"ab",           "juxtaposition at the top level"},
        -- the same thing one level down, inside an argument
        {"F_{mn}",       "juxtaposition inside an argument"},
        -- nothing may follow the base
        {"a^{'abcd'}x",  "trailing content after the base"},
        -- a name may not start with a bracket
        {"(a)",          "leading bracket"},
    }

    for _, case in ipairs(bad_cases) do
        local latex, why = case[1], case[2]
        local pat, err = parse(latex)
        check("rejects [" .. latex .. "] - " .. why, pat == nil,
                pat and ("accepted as " .. tostring(pat.text)))
    end

    --[[ The free variables come back NAMED and in traversal order, because each one becomes a
    parameter slot and the definition has to be able to say which is which. ]]
    local pat = parse("f(x,y,z)")
    if pat then
        check("vars are named", pat.vars[1] == "x" and pat.vars[2] == "y" and pat.vars[3] == "z",
                pat.vars[1] .. "," .. pat.vars[2] .. "," .. pat.vars[3])
    end

    --[[ Two parameters spelled the same are still two parameters. They are separate positions in
    the signature, and collapsing them would silently change the arity. ]]
    pat = parse("F_{m,m}")
    if pat then
        check("repeated spelling is two parameters", pat.arity == 2, pat.arity)
    end

    if checks_failed > 0 then
        print(string.format("test_name_pattern: %d/%d checks failed", checks_failed, checks_run))
        return false
    end
    return true
end

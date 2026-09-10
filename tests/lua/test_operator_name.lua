--[[
test_operator_name.lua - `sin`, `cos`, `log`, `ln` written as a 1-tall vertical whose row holds the
letters, and read back as ONE name.

THE ASSUMPTION. Ruled 2026-09-10: a named operator "will stay as the first row in a 1 tall
vertical, containing the letters of the exact name". The container is what makes it a name at all -
`s`, `i`, `n` loose in a row is juxtaposition, which this grammar reads as multiplication, so
without the wrapper `sin` is `s*i*n` and nothing downstream can tell the difference. Section 10 of
docs/phase2_design.md reached the same place from the other direction: `sin`/`log`/`det` and
multi-letter subscripts are one problem, and TeX's own fix - make them single atoms - is the cure.

WHY IT NEEDS AN ALARM. The failure is silent in the worst way. If the recogniser stops firing, `sin`
does not error - it falls back to being three letters juxtaposed, which is a perfectly well-formed
*product*, so the formula still parses, still draws, and quietly means something else. There is no
crash to notice and no red mark to see.

The validation is the other half: only single letters may sit in that row. A vert holding anything
else is a STACK, which is a real construct that means something different, and mistaking one for a
name would let `\stack{a}{b}` become a variable called `ab`.
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

local function name_of(fs, latex)
    local c = mformula_latex.from_latex(fs, mexpru.DEFAULT_SIZE, latex)
    if not c then
        return nil, "from_latex failed"
    end
    local pat, err = mexpr_ast.parse_name(fs, c)
    if not pat then
        return nil, err
    end
    return pat
end

function run_test()
    local fs = char.load_font_set()
    local stack = function(inner) return BS .. "stack{" .. inner .. "}" end

    -- ------------------------------------------------------------------ it is one name
    do
        local pat, err = name_of(fs, stack("sin"))
        check("a 1-tall vert of letters is a name", pat ~= nil, err)
        check("...spelled by its letters", pat and pat.name == "sin", pat and pat.name)
        --[[ Arity zero: the letters are the NAME, not arguments. If this ever reads as 3, the
        recogniser has stopped firing and the letters are being counted as free variables. ]]
        check("...of arity zero", pat and pat.arity == 0, pat and pat.arity)
    end

    -- ------------------------------------------------------------------ applied like any other
    do
        --[[ THE POINT: once it is an atom, nothing downstream needs to know it was a vert. `sin(x)`
        keys exactly as `f(x)` does, which is why this representation costs no new rules. ]]
        local pat, err = name_of(fs, stack("sin") .. "(x)")
        check("sin(x) parses", pat ~= nil, err)
        check("...keyed like any other function", pat and pat.text == "sin(),(1)", pat and pat.text)
        check("...with the argument counted", pat and pat.arity == 1, pat and pat.arity)
    end

    -- ------------------------------------------------------------------ spaces, as everywhere
    do
        --[[ Spaces are layout, dropped before the recogniser sees the row - the same rule that
        makes `f (x)` and `f(x)` one name. ]]
        local pat = name_of(fs, stack("s" .. BS .. " i" .. BS .. " n"))
        check("s i n is still sin", pat and pat.name == "sin", pat and pat.name)
    end

    -- ------------------------------------------------------------------ single letters ONLY
    do
        --[[ Everything here is a vert that is NOT a name, and each must stay refused. A stack of
        two rows is the ordinary construct the container was borrowed from; a digit in the row is
        the case that would otherwise let `\stack{x1}` become a variable named `x1`, quietly
        creating a second spelling for something the letters-only rule just outlawed. ]]
        local two_rows = BS .. "stack{a}{b}"
        local pat, err = name_of(fs, two_rows)
        check("a 2-row stack is not a name", pat == nil, pat and pat.text)
        check("...and says so", err ~= nil, err)

        pat = name_of(fs, stack("s1n"))
        check("a digit in the row disqualifies it", pat == nil, pat and pat.text)

        pat = name_of(fs, stack("s+n"))
        check("...so does anything that is not a letter", pat == nil, pat and pat.text)
    end

    if checks_failed == 0 then
        print("PASS: a 1-tall vert of letters is one name (" .. checks_run .. " checks)")
    end
    return checks_failed == 0
end

--[[
test_name_use.lua - mexpr_ast.parse_use(): reading a row as a USE of a name rather than a
declaration of one.

THE ASSUMPTION: an argument never contributes to identity. A use site's key is the SIGNATURE -
`f(34)`, `f(x)` and `f(n+1)` are all `f(),(1)`, because what identifies the function is its shape,
and 34 is only what was passed to it.

SUPERSEDED, AND THE OLD VERSION IS WORTH KNOWING because it was plausible enough to be built: this
file first asserted that `f(34)` offered TWO candidate keys - the literal `f(),34` and the
placeholder `f(),(1)` - most specific first, for the declaration table to choose between. That came
from `F(0)` beside `F(n)`, which really is how a recursion is written. The correction, 2026-09-10:
"the name of `f(34)`, evaluated in expr context is still `f(),(1)`, that is the signature of the
function, it gives it it's identity, 34 is only the argument". A declared specialisation is related
to its general form by expression matching later - it does not make a reference resolve to a
different name now.

WHY IT NEEDS AN ALARM, and it is not the happy path. Three properties here are invisible if they
break:

 1. **The keys are EXACT strings.** Nothing matches a literal against a placeholder, nothing treats
    `(1)` as a wildcard. If that ever softens into "close enough", names start resolving to
    declarations that merely resemble them, and the wrong definition is silently used.
 2. **An argument is never part of the key.** Let one in and `f(34)` and `f(35)` become different
    functions - which still produces a tree, still draws, and is wrong.
 3. **Powers are allowed here and refused in a declaration.** Same parser, opposite answer. A
    default leaking from one to the other breaks a real case in one direction (`f^2(x)` stops being
    readable) and lets nonsense through in the other (`f^2` becomes a declarable name).

WHAT IS DELIBERATELY NOT ASSERTED: that resolution works. Nothing here consults declarations - that
is content.declarations_before()'s job, tested separately. This file covers only what a use site
offers.
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

local function use(fs, latex)
    local c = mformula_latex.from_latex(fs, mexpru.DEFAULT_SIZE, latex)
    if not c then
        return nil, "from_latex failed"
    end
    return mexpr_ast.parse_use(fs, c)
end

local function keys_of(u)
    return u and u.key or "<nil>"
end

function run_test()
    local fs = char.load_font_set()

    -- ------------------------------------------- the argument does not change the identity
    do
        --[[ THE POINT OF THE WHOLE FILE. Three different arguments, one key: a literal, a
        variable, and an expression all leave the signature alone. If any of these ever produces a
        key of its own, references have started depending on what was passed to them. ]]
        for _, case in ipairs({{"f(34)", "a literal"}, {"f(x)", "a variable"},
                               {"f(x,y)", "two of them"}}) do
            local u = use(fs, case[1])
            local want = (case[1] == "f(x,y)") and "f(),(1),(2)" or "f(),(1)"
            check(case[1] .. " keys as its signature (" .. case[2] .. ")",
                    u and u.key == want, u and u.key)
        end
        check("...and the argument is kept for the tree", #use(fs, "f(34)").args == 1)
    end

    -- ------------------------------------------------- an expression argument
    do
        --[[ `n+1` is juxtaposition, which a DECLARATION refuses outright. At a use site the
        whole row is handed over untouched instead, which is the difference between the two passes:
        a declaration must understand its arguments, a use only has to find where they end. ]]
        local u = use(fs, "a_{n+1}")
        check("a_{n+1} is readable as a use", u ~= nil, keys_of(u))
        check("...keyed by signature", u and u.key == "a,sub,(1),end", u and u.key)
        check("...and the expression set aside for later", u and #u.args == 1, u and #u.args)
    end

    -- ------------------------------------------------- powers: allowed here, refused in a def
    do
        --[[ THE ASYMMETRY. Both directions are asserted together, in one block, because they are
        one decision - a name has no superscript, so a power can only be an operation applied to a
        use of one. Split across two files these two drift apart. ]]
        local u = use(fs, "f^{2}(x)")
        check("a power is readable at a use site", u ~= nil, u and "ok" or "refused")
        check("...and comes back to be applied, not folded into the name",
                u and #u.sups == 1, u and #u.sups)
        check("...leaving the key free of it", u and u.key == "f(),(1)", u and u.key)

        local c = mformula_latex.from_latex(fs, mexpru.DEFAULT_SIZE, "f^{2}(x)")
        local pat, err = mexpr_ast.parse_name(fs, c)
        check("...while the SAME row is not a declarable name", pat == nil, pat and pat.text)
        check("...refused with a reason", err ~= nil, err)
    end

    -- ------------------------------------------------- not a name at all
    do
        --[[ Case 1's hard error: a formula containing something that is not a name is invalid,
        not partially understood. There is no "unknown name" node to fall back to. ]]
        local u, err = use(fs, "(a)")
        check("a leading bracket is not a use of a name", u == nil, keys_of(u))
        check("...and says why", err ~= nil, err)
    end

    if checks_failed == 0 then
        print("PASS: a use site keys by signature, arguments excluded ("
                .. checks_run .. " checks)")
    end
    return checks_failed == 0
end

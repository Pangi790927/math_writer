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
        {"a_{b}",             "a,sub,(1),end",            1},
        -- a quoted literal index is NOT a parameter - this is `v_max`, a plain named variable
        {"a_{'maxlim'}",      "a,sub,'maxlim',end",       0},
        -- quotes are what make several letters ONE name instead of a product
        {"'abc'",             "abc",                  0},
        --[[ UNDERSCORE INSIDE QUOTES, added 2026-09-10. A quoted name is the only way to spell a
        multi-character name, and `max_lim` is how one is actually written - the underscore cannot
        be typed unquoted, since "_" is the subscript key, so the quotes are what make the character
        reachable at all. Written here as \_ because a bare _ is subscript syntax in LaTeX too. ]]
        {"'max" .. BS .. "_lim'",  "max_lim",         0},
        --[[ ...and it is still a LITERAL, so arity stays zero: an underscore does not turn a
        quoted constant into a parameter any more than a letter inside quotes does. ]]
        {"a_{'x" .. BS .. "_y'}",  "a,sub,'x_y',end",     0},
        -- call notation; `a` is the name, `x` the parameter
        {"a(x)",              "a(),(1)",              1},
        -- a decorated number is a name, if a strange one - see the note in the REJECTED table
        {"1_{u}",             "1,sub,(1),end",        1},
        {"1_{1}",             "1,sub,1,end",          0},
        {"2(x)",              "2(),(1)",              1},
        -- ...and a numeral base is the whole run, so `12` is one base and not `1` applied to `2`
        {"12_{n}",            "12,sub,(1),end",       1},
        -- a decorated number is a name, if a strange one
        -- two arguments, comma separated
        {"F_{m,n}",           "F,sub,(1),(2),end",        2},
        --[[ THE USER'S OWN NESTING EXAMPLE, and the case that fired when the serialization
        changed on 2026-09-10. It asserted arity 2 - `n` and `m` both parameters - which followed
        from the old rule that ANY letter in an argument position is a slot.

        The rule now (docs/phase2_design.md 18d): a BARE letter is a free variable, a letter
        CARRYING A SUB is part of the name. `n` carries one, so it is the literal token `n`, and
        this pattern has one parameter rather than two.

        Why the change: a parameter swallows whatever is written at its position, so under the old
        rule `n_{m}` was a slot with a subscript hanging off it, and nothing in a pattern says what
        that would identify. Carrying a decoration is exactly the evidence that a letter is
        structure and not a slot.

        The `end` markers on every row here arrived with it, and for the same reason: once a sub can
        nest, its child list needs a close, or `a_{b_{c}, d}` and `a_{b_{c, d}}` serialize
        identically. ]]
        {"a_{n_{m}}",         "a,sub,n,sub,(1),end,end", 1},
        -- the user's own call example
        {"f(x,y,z)",          "f(),(1),(2),(3)",      3},
        --[[ SPACES ARE NOT PART OF A NAME (2026-09-10). Each of these produced a DIFFERENT error
        before spaces were dropped in row_units - before a call bracket it read as trailing content,
        inside a subscript as juxtaposition, before an argument as "not a name", after a comma the
        same. They are listed separately rather than as one case because that is four symptoms of
        one cause, and a future change that reintroduces any one of them should say which. ]]
        {"f" .. BS .. " (x)",      "f(),(1)",         1},
        {"a_{n" .. BS .. " }",     "a,sub,(1),end",       1},
        {"a_{" .. BS .. " n}",     "a,sub,(1),end",       1},
        {"f(x," .. BS .. " y)",    "f(),(1),(2)",     2},
        --[[ ...but NOT inside a quoted literal, where a space is CONTENT: `'max lim'` is a
        two-word name and stays one. Ruled 2026-09-10 - the first cut dropped these too and made it
        `maxlim`, which silently renamed anything a person had written with a space in it.

        Runs are preserved rather than collapsed, so `'a  b'` and `'a b'` stay different names -
        two names that LOOK different must not resolve to one string (see the exact-equality rule
        in docs/phase2_design.md). ]]
        {"'max" .. BS .. " lim'",     "max lim",      0},
        {"'a" .. BS .. " " .. BS .. " b'", "a  b",    0},
        --[[ Restored around the edges too: the spaces before a closing quote are recorded against
        the quote's own unit, which is the thing that ends the scan, so a trailing run is the easy
        one to lose. ]]
        {"'ab" .. BS .. " '",         "ab ",          0},
        {"'" .. BS .. " ab'",         " ab",          0},
        -- a numeric literal index, still arity 0
        --[[ SIGNED number arguments, added 2026-09-10. A sign is part of the literal, so these stay
        arity ZERO like any other constant - `a_{-1}` names one particular thing, it is not a
        function of anything. The "+" form has to be accepted alongside "-" or the two ways of
        writing an explicit sign would disagree about whether they are numbers at all. ]]
        {"a_{-1}",            "a,sub,-1,end",             0},
        {"a_{+1}",            "a,sub,+1,end",             0},
        {"a_{-0.5}",          "a,sub,-0.5,end",           0},
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
        --[[ A DIGIT BASE HAS BEEN LEGAL, THEN ILLEGAL, THEN LEGAL AGAIN, all on 2026-09-10, and
        the three cases that used to sit here are now in the ACCEPTED list above. The round trip is
        worth keeping because the middle position was well argued and still lost.

        It started legal (`1_{u}` was `1,sub,(1)`, the parser calling it "a name, if a strange
        one"). It was then restricted to letters - author: "all the names start at a letter or
        number... and now that I think more, a number is a bad idea, so only letters" - on the
        grounds that `1_u` as a NAME collides with `1` the literal everywhere both could appear.

        What overturned that is the resolution order, not a change of heart about the collision.
        A NUMERAL IS NOT A DEFINITION, so `2(x)` has exactly two readings and they are tried in a
        fixed order: the name parser first, the value parser only if nothing answers. Author:
        "if you define 2(),(1) it will steal the whole 2(x) as the name, not leeaving multiplication
        a change to break". The collision was real; what was missing was that something already
        decides it.

        The rule that came with it: a numeric base is the WHOLE digit run. `12` is one base, not `1`
        applied to `2` - otherwise `12(x)` could resolve against a declaration of `1`. ]]
        --[[ A SIGN IS ONLY A SIGN WITH A DIGIT BEHIND IT (2026-09-10). The number branch looks
        ahead one unit before claiming a "-"/"+", so a lone sign is still an ordinary refusal
        rather than the start of a number - which would otherwise swallow it and then fail one
        step later with a message about something else. ]]
        {"a_{-}",        "a lone sign is not a number"},
        {"a_{+}",        "a lone sign is not a number"},
        --[[ A NAME HAS NO SUPERSCRIPT (2026-09-10). This case sat in the ACCEPTED list above,
        asserting `a^{'abcd'}` -> `a,sup,'abcd'`, until the rule was reversed: author's own words,
        "I changed my mind, names don't have sups, only subs or function arguments (themselves)".

        Recorded rather than quietly deleted, because a test moving from one list to the other is
        the interesting kind of change: the old assertion was not WRONG, it described what the
        parser was asked to do at the time. What changed is the definition of a name - a power is
        now an operation ON a name, so it cannot be part of one. The second case checks the rule
        reaches nested arguments too, not just the outermost base. ]]
        --[[ A quoted name of nothing but spaces is still EMPTY. Once spaces became content they
        started counting towards "is there anything between the quotes", and `'  '` would have read
        as a two-character name - which is why read_quoted tracks real content separately from the
        text it has accumulated. ]]
        {"'" .. BS .. " " .. BS .. " '", "spaces alone are not a name"},
        {"a^{'abcd'}",   "a name may not carry a power"},
        {"a_{n^{m}}",    "...not even on a nested argument"},
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

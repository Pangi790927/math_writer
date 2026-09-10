--[[
test_decorated_names.lua - accents and primes as part of a name's identity, and quoted names as one
lexed object.

THE BUG THIS EXISTS FOR. Until 2026-09-10 every accent was silently dropped: `\hat{a}`, `\vec{a}`
and `a` all serialized as `a`, so they were the SAME NAME. Declaring two of them collided as a
duplicate, and a formula using `\hat{p}` resolved to a declaration of `p` - a well-formed tree
meaning something nobody wrote, which is the one failure mode the exact-identity scheme exists to
prevent. The cause was `mexpru.slot_atom` looking through a dress, which is correct for the cursor
and wrong for identity; nothing had ever asked the difference.

WHY THE DECORATION IS IN THE BASE TOKEN AND NOT BESIDE IT. As a separate token, `a` would be a
PREFIX of `a,\hat`, and the no-overlap rule refuses a name that extends one already defined - so `a`
and `\hat{a}` could not both be declared, which is absurd. Inside the token they are siblings in the
trie. Author, on why a decoration is never optional at the use site, 2026-09-10: "if you are defined
with a hat, you allways use the hat, no?".

A DECORATED PARAMETER IS STILL A PARAMETER. `a_{\hat{m}}` is `a,sub,(1),end`, the same as `a_{m}`: a
parameter's spelling was never identity, and an accent is part of that spelling. Decorations become
identity only where what they sit on is LITERAL - the base of a name, or a literal base inside a
descended group.
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

local function pattern(fs, latex)
    local c = mformula_latex.from_latex(fs, mexpru.DEFAULT_SIZE, latex)
    if not c then
        return "<from_latex failed>"
    end
    local pat, err = mexpr_ast.parse_name(fs, c)
    return pat and pat.text or ("ERR " .. tostring(err)), pat and pat.arity
end

function run_test()
    local fs = char.load_font_set()
    local B = string.char(92)

    -- ------------------------------------------------- an accent is part of the name
    do
        check("a plain letter is itself", pattern(fs, "a") == "a", pattern(fs, "a"))
        for _, case in ipairs({{"hat", "hat"}, {"bar", "bar"}, {"vec", "vec"}}) do
            local got = pattern(fs, B .. case[1] .. "{a}")
            check("a " .. case[1] .. " survives into the name", got == "a" .. B .. case[2], got)
        end
        --[[ Dots share the above slot with a named accent, and are counted rather than named on the
        node - so their token comes from the count, and one and two dots must not collapse. ]]
        check("one dot and two dots are different names",
                pattern(fs, B .. "dot{a}") ~= pattern(fs, B .. "ddot{a}"),
                pattern(fs, B .. "dot{a}"))
    end

    -- ------------------------------------------------- primes
    do
        --[[ A LONE QUOTE IS A PRIME, which is what packing decides: `'` and `''` have no closing
        quote and nothing that could be string content after them, so they are not names being
        typed. Author, 2026-09-10: "only when ' are alone they form prime second third". ]]
        check("one quote is a prime", pattern(fs, "a'") == "a'", pattern(fs, "a'"))
        check("two are a second, as one decoration", pattern(fs, "a''") == "a''",
                pattern(fs, "a''"))
        check("three are a third", pattern(fs, "a'''") == "a'''", pattern(fs, "a'''"))

        --[[ CANONICAL ORDER, so a doubly decorated letter has exactly one spelling: accents
        innermost-first, then primes. Without a fixed order the same name serializes two ways and
        stops identifying. ]]
        check("accents come before primes", pattern(fs, B .. "hat{a}''") == "a" .. B .. "hat''",
                pattern(fs, B .. "hat{a}''"))
    end

    -- ------------------------------------------------- decorations compose with the rest
    do
        local t, n = pattern(fs, B .. "hat{a}_{m}")
        check("a decorated base still takes a subscript", t == "a" .. B .. "hat,sub,(1),end", t)
        check("...with its arity intact", n == 1, n)

        t = pattern(fs, B .. "hat{a}(x)")
        check("and a call", t == "a" .. B .. "hat(),(1)", t)

        --[[ A SUBSCRIPT TYPED AFTER A PRIME WRAPS THE PRIME, so the decoration unit is the one the
        sub has to be read from - the same rule that makes a quoted name's CLOSING quote the unit
        that survives packing. ]]
        t = pattern(fs, "a'_{m}")
        check("a subscript after a prime is still the base's", t == "a',sub,(1),end", t)
    end

    -- ------------------------------------------------- where a decoration is NOT identity
    do
        check("a decorated parameter is just a parameter",
                pattern(fs, "a_{" .. B .. "hat{m}}") == "a,sub,(1),end",
                pattern(fs, "a_{" .. B .. "hat{m}}"))

        --[[ ...but a decorated LITERAL base inside a descended group keeps its accent, because that
        base is part of the enclosing name rather than a slot in it. ]]
        local t = pattern(fs, "a_{" .. B .. "hat{m}_{p}}")
        check("a decorated literal base does keep it",
                t == "a,sub,m" .. B .. "hat,sub,(1),end,end", t)
    end

    -- ------------------------------------------------- quoted names, packed whole
    do
        --[[ SPACES INSIDE A QUOTED NAME ARE CONTENT, and this is now true because the quotes are
        scanned BEFORE spaces are dropped, rather than by counting spaces and putting them back.
        Author: "why isn't the whole string read as a single object?". ]]
        check("a quoted name keeps its spaces", pattern(fs, "'a  bc d'") == "a  bc d",
                pattern(fs, "'a  bc d'"))
        check("and still takes a subscript", pattern(fs, "'a b'_{n}") == "a b,sub,(1),end",
                pattern(fs, "'a b'_{n}"))

        --[[ THE CALL PATH RE-LEXED ITS ARGUMENTS ONCE, and packing broke it until the call started
        carrying units instead of nodes: the quoted argument's atoms are no longer in the row's node
        list, so rebuilding from nodes reported an unterminated quote. A row is lexed exactly once. ]]
        check("a quoted call argument survives", pattern(fs, "f('a b',x)") == "f(),'a b',(1)",
                pattern(fs, "f('a b',x)"))

        --[[ AND A HALF-TYPED NAME IS STILL AN ERROR, which is the case that stops "a lone quote is
        a prime" from swallowing everything: content follows and nothing closes it, so it keeps the
        unterminated-name error and the red mark it has always had. ]]
        local t = pattern(fs, "'ab")
        check("an unclosed quote with content is not a prime", t:find("unterminated", 1, true), t)
        check("nothing but spaces is not a name",
                pattern(fs, "'  '"):find("empty quoted name", 1, true) ~= nil, pattern(fs, "'  '"))
    end

    if checks_failed == 0 then
        print("PASS: decorations belong to the name (" .. checks_run .. " checks)")
    end
    return checks_failed == 0
end

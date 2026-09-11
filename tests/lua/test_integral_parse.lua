--[[
test_integral_parse.lua - building an INT node from a typed row: where its variable comes from,
where its body ends, and what its limits mean.

WHAT THIS FILE ASSUMES, and it is the assumption the whole integral design rests on:

    the `\int` and the `d` are ALREADY a pair by the time the parser sees them.

They are made together at typing time (test_integral_pair.lua covers that half) and are carried
across a save by the "\\,d" spelling of the differential, so this parser never scans for one - it
reads `.bracket.peer` and lands on the exact `d` the user closed with.

MOST CHECKS HERE SET THE TAGS BY HAND, the way the editor would have left them, so that what is
being tested is the READING and not the loading. The last section is the exception and goes through
from_latex alone, which is the path a saved document actually takes.

If a future change makes the parser hunt for a `d` instead, the hand-tagged checks still pass while
the ambiguity the pair exists to retire comes straight back - so the one that matters is "the pair
decides, not the nesting", which pairs the OUTER of two integrals with the OUTER `d` and cannot be
satisfied by any scan.

WHY THE VARIABLE IS NOT IN THE SUB. Every other big operator declares its variable in its subscript
(`\sum_{i=1}^{n}`); an integral declares it at the END, in `dx`, and its subscript holds a VALUE
instead. That is why read_integral exists separately from read_bigop rather than as a branch in it -
see its own comment for the full list of what differs.

A NOTE ON THE BOUNDS: `\int_{0}^{1}` spawns nothing. `0` is not a constraint and declares no name,
so unlike a sum the sub side is read with build_expr and its free names stay free.
]]

package.path = package.path .. ";./scripts/?.lua"

local vc = require("virt_composer")
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

-- Every top-level atom of a row, read through slot_atom so a decorated half still reports.
local function atoms(c)
    local out = {}
    for _, ch in ipairs(mexpru.u(c.root).children) do
        out[#out + 1] = mexpru.slot_atom(ch)
    end
    return out
end

local function desc_of(a)
    if not a or a.type ~= vc.MEXPR_TYPE_SYMBOL then
        return nil
    end
    local e = char.find_by_ncod(a.symb.code)
    return e and e.desc
end

--[[ Ties two atoms together as an integral pair, exactly as open_bracket/try_close_bracket leave
them - `peer` on each side is the OTHER atom's `u` table, which is the identity the parser matches
on (mexpru's own bracket-model comment).

By hand, deliberately, even though from_latex can carry the tags now: it lets a check state the
pairing it means instead of spelling one out in LaTeX and trusting the reader to have built it, and
it is the only way to write a pairing LaTeX has no spelling for. ]]
local function pair(open_atom, close_atom)
    mexpru.u(open_atom).bracket = {is_open = true, type = char.BRACKET_INTEGRAL,
            peer = mexpru.u(close_atom)}
    mexpru.u(close_atom).bracket = {is_open = false, type = char.BRACKET_INTEGRAL,
            peer = mexpru.u(open_atom)}
end

-- The n-th atom whose glyph is `d`, 1-based.
local function nth_d(list, n)
    local seen = 0
    for _, a in ipairs(list) do
        if desc_of(a) == "d" then
            seen = seen + 1
            if seen == n then
                return a
            end
        end
    end
    return nil
end

local function nth_int(list, n)
    local seen = 0
    for _, a in ipairs(list) do
        if desc_of(a) == B .. "int" then
            seen = seen + 1
            if seen == n then
                return a
            end
        end
    end
    return nil
end

local function tree(fs, c)
    local node, err, ns = mexpr_ast.build(fs, c, {})
    if not node then
        return nil, err
    end
    return ast.to_string(ns, node), nil, ns, node
end

function run_test()
    local fs = char.load_font_set()

    -- --------------------------------------------------- an unpaired integral is refused, loudly
    do
--[[ THE OLD SPELLING - a bare `xdx`, with no "\\,". Every document saved before 2026-09-11 is
        written this way, and so is LaTeX pasted from anywhere that does not mark its differentials.

        REFUSED WITH A REASON RATHER THAN REPAIRED BY GUESSING, which is the whole argument for the
        mark: deciding here that this `d` is a differential is exactly the scan the pairing design
        was adopted to remove, and it cannot tell an integrand ending in a variable named `d` from a
        real one. The cost is that an old integral has to be retyped once.

        So if this check ever starts failing, the question to ask is whether someone taught the
        reader to guess - not how to make the message softer. ]]
        local c = mformula_latex.from_latex(fs, SZ, B .. "int _{0}^{1}xdx")
        local out, err = tree(fs, c)
        check("an integral with no pairing does not build", out == nil, out)
        check("...and says why", err ~= nil and err:find("differential", 1, true) ~= nil, err)
    end

    -- --------------------------------------------------- the variable comes from the differential
    do
        local c = mformula_latex.from_latex(fs, SZ, B .. "int _{0}^{1}xdx")
        local a = atoms(c)
        pair(nth_int(a, 1), nth_d(a, 1))
        local out, err = tree(fs, c)
        check("a paired integral builds", out ~= nil, err)
        --[[ (I, var, from, to, body). The body's `x` is a REF to the VAR the integral made - that
        is `catch_free` doing its work, and it is the whole reason ast.new_int takes a NAME and
        builds the variable itself rather than being handed one. ]]
        check("the integral declares the variable written after its d",
                out ~= nil and out:find("%(#, x:") ~= nil, out)
        check("the bounds are values, in order",
                out ~= nil and out:find("%(N, 0, 1, 1:") ~= nil
                        and out:find("%(N, 1, 1, 1:") ~= nil, out)
    end

    -- --------------------------------------------------- the body STOPS at the differential
    do
        --[[ UNLIKE A GROUP OPERATOR, whose body swallows the rest of its term. A `d` is a closing
        bracket, and a closing bracket ends a factor - so what follows the variable is a separate
        factor of the surrounding product, not part of the integrand. If this ever reads as
        `INT(..., x*y)` the integral has started behaving like `\sum` and the two have been
        merged by someone who only looked at the operator glyph. ]]
        local c = mformula_latex.from_latex(fs, SZ, B .. "int xdxy")
        local a = atoms(c)
        pair(nth_int(a, 1), nth_d(a, 1))
        local out, err = tree(fs, c)
        check("what follows the variable is outside the integral", out ~= nil, err)
        check("...so the row is a product with the integral as one factor",
                out ~= nil and out:sub(1, 3) == "(*,", out)
    end

    -- --------------------------------------------------- an indefinite integral is an integral
    do
        local c = mformula_latex.from_latex(fs, SZ, B .. "int xdx")
        local a = atoms(c)
        pair(nth_int(a, 1), nth_d(a, 1))
        local out, err = tree(fs, c)
        check("no bounds still builds", out ~= nil, err)
        check("...with the operator at the root", out ~= nil and out:sub(1, 3) == "(I,", out)
    end

    -- --------------------------------------------------- the pair decides, not the nesting
    do
        --[[ THE CHECK A SCAN CANNOT PASS. Two integrals, and the OUTER one is paired with the
        SECOND `d`. Nothing in the row's shape says so - a depth walk or a "first d wins" rule
        would pair it with the first - and reading `.bracket.peer` gets it right for free. This is
        the ambiguity the pairing design was adopted to retire, so it is the check worth keeping if
        any of the others are ever thought redundant. ]]
        local c = mformula_latex.from_latex(fs, SZ, B .. "int " .. B .. "int adubdv")
        local a = atoms(c)
        check("setup: the row has two integrals and two ds",
                nth_int(a, 2) ~= nil and nth_d(a, 2) ~= nil)
        pair(nth_int(a, 1), nth_d(a, 2))
        pair(nth_int(a, 2), nth_d(a, 1))
        local out, err = tree(fs, c)
        check("crossed-looking pairing builds", out ~= nil, err)
        check("the outer integral took the variable of the d it is paired with",
                out ~= nil and out:find("%(#, v:") ~= nil, out)
        check("and the inner one took the other",
                out ~= nil and out:find("%(#, u:") ~= nil, out)
    end

    -- --------------------------------------------------- the pair survives a save and a load
    do
        --[[ THE DIFFERENTIAL IS WRITTEN "\,d" AND READ BACK AS THE CLOSING HALF, which is what
        makes an integral survive a reload at all. Reported 2026-09-11: "integrals don't survive a
        reload"; the spelling is the author's own, "what about this: /int/,dx?".

        NOTE WHAT IS NOT PAIRED HERE. The last case is a thin space and a `d` with no integral open
        anywhere near them, and it must stay exactly that - the mark binds only while the bracket
        stack has an integral on it. Without that guard every "\,d" in a document would become
        half of a pair, and `\,` is an ordinary glyph anyone may type.

        These go through from_latex ALONE, with no hand-tagging, unlike every check above - which
        is the point: this is the path a saved document takes. ]]
        local function reload(src)
            local c = mformula_latex.from_latex(fs, SZ, src)
            local out, err = tree(fs, c)
            return out, err, mformula_latex.to_latex(c)
        end

        local out, err, back = reload(B .. "int x" .. B .. ",dx")
        check("a saved integral builds again", out ~= nil, err)
        check("...over the variable its differential named",
                out ~= nil and out:find("%(#, x:") ~= nil, out)
        check("...and is written the same way it was read", back == B .. "int x" .. B .. ",dx", back)

        --[[ NESTED, which is where the stack earns its place: the inner `\,d` must take the inner
        `\int`. That is also the only nesting the editor can produce, since try_close_bracket
        closes the innermost - so LaTeX needs no spelling for anything else. ]]
        out, err = reload(B .. "int " .. B .. "int a" .. B .. ",dub" .. B .. ",dv")
        check("nested integrals reload nested", out ~= nil, err)
        check("...the inner one taking the inner differential",
                out ~= nil and out:find("%(#, u:") ~= nil, out)
        check("...and the outer one the outer",
                out ~= nil and out:find("%(#, v:") ~= nil, out)

        local plain = "a" .. B .. ",db"
        local _, _, plain_back = reload(plain)
        check("a thin space and a d outside any integral are left alone", plain_back == plain,
                plain_back)
    end

    if checks_failed == 0 then
        print("PASS: integrals build from the pair (" .. checks_run .. " checks)")
    end
    return checks_failed == 0
end

--[[
test_integral_pair.lua - the integral as a bracket pair: `\int` opens, the differential's `d` closes.

THE IDEA, the author's, 2026-09-10: "( is /int and ) is d". An integral is NOT a bracket - it
borrows the bracket mechanism because that mechanism already does exactly what it needs, and for no
other reason: one half remembers the other, deleting either takes both, and the counter refuses to
let pairs cross. His own words: "the idea is not to use the bracket functions necesarily, but mexprs
with the symbol d and int".

WHAT THAT BUYS OVER THE ALTERNATIVE. The design this replaced had `mexpr_ast` scan forward from an
`\int` looking for a `d` followed by one letter, at the right bracket depth. Pairing at TYPING time
instead means the parser never guesses: it reads `.bracket.peer` and lands on the exact `d` the user
closed with. It also retires the one ambiguity that design had accepted - a body ending in a product
against a variable genuinely named `d` - because a typed `d` carries no bracket tag and a closing one
does. Same reason `resolve_bracket_pairs` matches by peer rather than by depth: a scan invents
pairings nobody made.

TWO THINGS THE PAIR DOES NOT INHERIT, both deliberate:

  - it never RESIZES. `char.bracket_opts` answers nil for it, so resolve_bracket_pairs leaves both
    halves exactly as typed. The two are an operator glyph and a letter; neither grows with what
    sits between them, unlike every other pair, whose halves come from one extensible family.
  - its open half MAY take sup/sub. An exponent on a `(` means nothing and is refused; limits on an
    integral are the whole point.
]]

package.path = package.path .. ";./scripts/?.lua"

local vc = require("virt_composer")
local char = require("char")
local mexpru = require("mexpru")
local mformula = require("mformula_new")

local checks_run, checks_failed = 0, 0
local function check(name, cond, got)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name .. (got ~= nil and ("  (got: " .. tostring(got) .. ")") or ""))
    end
end

local SZ = 12

-- The row as "desc<tag>" per slot, read through slot_atom so a decorated half still reports.
local function row(c)
    local parts = {}
    for _, ch in ipairs(mexpru.u(c.root).children) do
        local a = mexpru.slot_atom(ch)
        local u = mexpru.u(a)
        local e = a.type == vc.MEXPR_TYPE_SYMBOL and char.find_by_ncod(a.symb.code)
        local tag = ""
        if u.bracket then
            tag = "<" .. tostring(u.bracket.type)
                    .. (u.bracket.is_open and " open" or " close")
                    .. (u.bracket.peer and " paired" or " pending") .. ">"
        end
        parts[#parts + 1] = (e and e.desc or "?") .. tag
    end
    return table.concat(parts, " ")
end

-- A fresh formula with an integral just opened, cursor where open_bracket left it.
local function opened(fs)
    local c = mformula.new(fs, SZ)
    local t = c.cursor_pos:get_obj()
    mformula.open_bracket(c, fs, t, t:get_parent(), false, true, false, SZ, char.BRACKET_INTEGRAL)
    return c
end

function run_test()
    local fs = char.load_font_set()

    -- ------------------------------------------------- opening leaves a pending half
    do
        local c = opened(fs)
        check("the integral opens as a pending bracket",
                row(c) == "\\int<integral open pending>", row(c))
        check("...and reports itself pending", mformula.pending_integral(c) ~= nil)
    end

    -- ------------------------------------------------- closing pairs the two halves
    do
        local c = opened(fs)
        mformula.try_close_bracket(c, fs, char.BRACKET_INTEGRAL)
        --[[ The empty slot between them is the same filler `(` gets when closed immediately:
        resolve_bracket_pairs errors loudly on a pair whose span is empty, so the editor keeps one
        there. ]]
        check("closing pairs both halves with a body between them",
                row(c) == "\\int<integral open paired> ? d<integral close paired>", row(c))
        check("...and nothing is pending any more", mformula.pending_integral(c) == nil)
    end

    -- ------------------------------------------------- a `d` is only special while one is pending
    do
        local c = mformula.new(fs, SZ)
        check("with nothing open, no integral is pending", mformula.pending_integral(c) == nil)

        --[[ Which is what leaves `d` an ordinary letter the rest of the time. The rule lives at the
        one place that reads the character queue, so this is the state it tests against. ]]
        local c2 = opened(fs)
        mformula.try_close_bracket(c2, fs, char.BRACKET_INTEGRAL)
        check("and none is pending once closed either", mformula.pending_integral(c2) == nil)
    end

    -- ------------------------------------------------- limits are allowed on the open half
    do
        --[[ THE CARVE-OUT. An exponent on an ordinary `(` is refused - it means nothing, and a
        PENDING open atom wrapped in a supsub broke closing outright ("a+a(^A", stuck). Neither
        applies here: limits on an integral are what it is for, and a pending integral cannot reach
        this at all, because nothing but `d` types while one is pending. ]]
        local c = opened(fs)
        mformula.try_close_bracket(c, fs, char.BRACKET_INTEGRAL)

        local int_atom = mexpru.u(c.root).children[1]
        c.cursor_pos = vc.wref_mexpr(int_atom)
        mformula.make_bigop(c, fs, "sub")

        local first = mexpru.u(c.root).children[1]
        local u = mexpru.u(first)
        check("the integral takes a limit below", u.kind == "supsub" and u.sub ~= nil,
                u.kind)
        check("...drawn under it", u.sub_place == mexpru.PLACE_DISPLAY, u.sub_place)

        --[[ AND THE PAIR SURVIVES IT. The tag sits on the glyph now buried in the supsub's base,
        which is exactly the shape slot_atom had to learn to look through - before it did, adding a
        limit made the open half invisible and the pair came silently apart. ]]
        local found = mexpru.slot_atom(first)
        local br = mexpru.u(found).bracket
        check("the pairing survives the limit", br ~= nil and br.is_open and br.peer ~= nil,
                br and "found" or "lost")
    end

    -- ------------------------------------------------- and it survives a zoom
    do
        --[[ THE PATH THAT TURNED THE SCREEN GREY. rescale_node rebuilds every bracket half from
        its type on a zoom, and it read the ASCII tables directly - which have no entry for the
        integral, whose open half is an operator glyph with no ASCII spelling at all. `nil` went
        into find_by_ascii and the error repeated every frame.

        Both halves go through bracket_entry now, and the size boost travels with them: `\int` is
        drawn several levels above the text around it, so a zoom that re-derived it without the
        boost would shrink it to the height of a letter.

        Asserted on a PENDING integral as well as a closed one, since a pending half is redrawn
        just the same and was the state the report came from. ]]
        local c = opened(fs)
        mformula.rescale(c, fs)
        check("a pending integral survives a zoom",
                row(c) == "\\int<integral open pending>", row(c))

        local d = opened(fs)
        mformula.try_close_bracket(d, fs, char.BRACKET_INTEGRAL)
        mformula.rescale(d, fs)
        check("and so does a closed pair",
                row(d) == "\\int<integral open paired> ? d<integral close paired>", row(d))
    end

    if checks_failed == 0 then
        print("PASS: the integral opens, closes and takes limits (" .. checks_run .. " checks)")
    end
    return checks_failed == 0
end

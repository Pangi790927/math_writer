--[[
test_bracket_nesting.lua - a bracket can be opened while another is still open.

Reported 2026-09-06: "an opened { can't be closed over (, you can't get {()}, which is a wrong
limitation". It was: handle_input refused a second open bracket outright, because the editor kept
the unclosed one in a single slot, container.pending_bracket, which could hold exactly one.

The fix deleted state rather than adding it. The row already contains every bracket, so a parallel
slot was never a model of that state - only a cache of one fact about it, and a cache that could not
represent two. What replaced it is the counter rule the user stated and mexpru.bracket_count already
wrote down: walking LEFT from the cursor, a close raises the depth, an open lowers it, and the first
open met at depth zero is the one a close would pair with.

    { ( a ) |        ")" -> depth 1,  "(" -> depth 0,  finds "{"

Two properties fall out for free and are pinned below:

  - NO CROSSING. The innermost unclosed open is the only candidate, so a type mismatch refuses
    instead of reaching past it. "{(a}" cannot pair the "}" with the "{".
  - closing from INSIDE a finished pair is impossible, since a resolved open met at depth zero means
    the cursor is enclosed by it - and pairing outward from there would cross.

Read through slot_atom throughout: a ")" carrying an exponent is a supsub BASE and invisible to any
walk reading children directly. That blind spot has produced six live bugs in this area.
]]

package.path = package.path .. ";./scripts/?.lua"

local vc = require("virt_composer")
local char = require("char")
local mexpru = require("mexpru")
local mformula = require("mformula_new")
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

--[[ Builds a row from LaTeX and parks the cursor on its last atom, then asks which bracket a close
would pair with. A bare "{" is a GROUP in this parser, so a literal curly bracket is written "\{" -
see test_latex_groups.lua for that distinction. ]]
local function open_at_end(fs, src)
    local c = mformula_latex.from_latex(fs, SZ, src)
    local ch = mexpru.u(c.root).children
    c.cursor_pos = vc.wref_mexpr(ch[#ch])
    local atom = mformula.innermost_unclosed_open(c)
    if not atom then
        return nil, c
    end
    return mexpru.u(atom).bracket.type, c
end

function run_test()
    local fs = char.load_font_set()
    local ROUND, SQUARE = vc.MEXPR_BRACKET_ROUND, vc.MEXPR_BRACKET_SQUARE
    local CURLY = vc.MEXPR_BRACKET_CURLY

    -- ---------------------------------------------------------------- the reported case
    do
        --[[ "{(a" - both open, neither closed. A close typed here must pair with the "(", the
        INNERMOST, not the "{". Under the old single slot the "(" could not even be typed. ]]
        local t = open_at_end(fs, B .. "{(a")
        check("with { and ( both open, the innermost is the (", t == ROUND, t)

        -- once the "(" is closed, the "{" becomes the innermost again
        local t2 = open_at_end(fs, B .. "{(a)b")
        check("after the ( closes, the { is next in line", t2 == CURLY, t2)

        -- and with nothing open at all there is nothing to close
        local t3 = open_at_end(fs, "ab")
        check("plain text has no open bracket", t3 == nil, t3)
    end

    -- ---------------------------------------------------------------- depth, not proximity
    do
        --[[ A finished pair to the LEFT must not be mistaken for an open one - that is the whole
        job of the counter. "([a])b" is fully closed; nothing is pending after it. ]]
        check("a fully closed group leaves nothing open", open_at_end(fs, "([a])b") == nil)
        check("...nor does a nested one", open_at_end(fs, "((a))b") == nil)

        -- three deep, none closed: still the innermost
        local t = open_at_end(fs, B .. "{([a")
        check("three open brackets resolve to the innermost", t == SQUARE, t)
    end

    -- ---------------------------------------------------------------- inside a resolved pair
    --[[ The cursor sits between a resolved "(" and its ")". Pairing outward from there would cross
    the pair it is inside, so the answer is nil and a typed close is a no-op. ]]
    do
        local c = mformula_latex.from_latex(fs, SZ, B .. "{(ab)c")
        local ch = mexpru.u(c.root).children
        -- park on the "a", which is inside the resolved round pair
        local inside
        for _, n in ipairs(ch) do
            local e = n.type == vc.MEXPR_TYPE_SYMBOL and char.find_by_ncod(n.symb.code)
            if e and e.acod == "a" then inside = n end
        end
        check("setup: found a position inside the resolved pair", inside ~= nil)
        if inside then
            c.cursor_pos = vc.wref_mexpr(inside)
            check("nothing is closable from inside a finished pair",
                    mformula.innermost_unclosed_open(c) == nil)
        end
    end

    -- ---------------------------------------------------------------- through a supsub base
    --[[ "(a)^2" puts the ")" in a supsub BASE, where a walk reading children directly cannot see
    it. If that pair went uncounted the depth would come out wrong and the "(" would look open. ]]
    do
        check("a closed pair carrying an exponent is still counted as closed",
                open_at_end(fs, "(a)^{2}b") == nil)
        check("...and an OPEN bracket before one is still found",
                open_at_end(fs, B .. "{(a)^{2}b") == CURLY)
    end

    -- ---------------------------------------------------------------- nothing else moved
    do
        --[[ The parser has always handled nesting; these confirm the row it builds is what the
        scan reads, so the two agree. ]]
        for _, src in ipairs({B .. "{(a)" .. B .. "}", "([a])", "((a))", "[(a)]"}) do
            local c = mformula_latex.from_latex(fs, SZ, src)
            check(src .. " round-trips", mformula_latex.to_latex(c) == src,
                    mformula_latex.to_latex(c))
        end
    end

    print("checks: " .. checks_run .. ", failed: " .. checks_failed)
    if checks_failed > 0 then
        return false
    end
    print("PASS: brackets nest; a close pairs with the innermost unclosed open")
    return true
end

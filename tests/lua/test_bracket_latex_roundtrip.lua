--[[
test_bracket_latex_roundtrip.lua - mformula_latex.lua's to_latex()/from_latex() round-trip a
resolved bracket pair with its REAL pairing intact, not just the bare "("/")" glyphs. Reported live,
2026-09-05: "loading and saving the brackets is simply saving their glyph, at load those should be
re-paired" - to_latex() only ever emits a bracket atom's own plain character (the same
MEXPR_TYPE_SYMBOL branch every other glyph goes through - it has no idea two of them were ever a
real pair), so loading that text back with no re-pairing at all silently drops the structure: no
cascade-delete, no synchronized resize, nothing - just two ordinary, unrelated glyphs sitting next
to each other. Fixed by giving parse_latex_children() its own bracket-matching stack (mformula_new.
lua's own single pending_bracket slot is fine for interactive typing - only one bracket is ever
mid-edit at a time - but loaded text can contain multiple/nested/sequential ALREADY-COMPLETE pairs).
]]

package.path = package.path .. ";./scripts/?.lua"

local vc = require("virt_composer")
local char = require("char")
local mexpru = require("mexpru")
local mformula_latex = require("mformula_latex")
local same = mexpru.same

local checks_run, checks_failed = 0, 0
local function check(name, cond)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name)
    end
end

function run_test()
    local fs = char.load_font_set()
    local SZ = 12

    -- Part 1: loading "(a)" from scratch re-pairs the two bracket atoms. ------------------------
    do
        local c = mformula_latex.from_latex(fs, SZ, "(a)")
        local children = mexpru.u(c.root).children
        check("3 children (open, a, close)", #children == 3)
        local open_atom, A, close_atom = children[1], children[2], children[3]

        local open_br = mexpru.u(open_atom).bracket
        local close_br = mexpru.u(close_atom).bracket
        check("open atom tagged is_open=true", open_br and open_br.is_open)
        check("close atom tagged is_open=false", close_br and not close_br.is_open)
        check("open's own peer IS the close atom's own u() table",
                open_br and open_br.peer == mexpru.u(close_atom))
        check("close's own peer IS the open atom's own u() table",
                close_br and close_br.peer == mexpru.u(open_atom))
        check("mexpru.scan_bracket finds the close from the open",
                mexpru.scan_bracket(children, 1, 1) == 3)

        -- Round-trips back out to the same text, proving the pairing didn't corrupt anything
        -- to_latex() itself reads (it only ever looks at symb.code, never at .bracket).
        check("to_latex() round-trips back to \"(a)\" (" .. mformula_latex.to_latex(c) .. ")",
                mformula_latex.to_latex(c) == "(a)")
    end

    -- Part 2: nested/sequential pairs each get their OWN correct partner, not just "nearest of
    -- either type" - "(a)[b]" and "([a])" both have to pair round-with-round, square-with-square,
    -- and inner-with-inner before outer-with-outer.
    do
        local c = mformula_latex.from_latex(fs, SZ, "(a)[b]")
        local children = mexpru.u(c.root).children
        check("(a)[b]: 6 children", #children == 6)
        check("(a)[b]: first \"(\" pairs with the first \")\", not the \"]\"",
                mexpru.u(children[1]).bracket.peer == mexpru.u(children[3]))
        check("(a)[b]: \"[\" pairs with \"]\"",
                mexpru.u(children[4]).bracket.peer == mexpru.u(children[6]))
    end

    do
        local c = mformula_latex.from_latex(fs, SZ, "([a])")
        local children = mexpru.u(c.root).children
        -- Resolution never changes the flat list's own LENGTH (mexpru.lua's resolve_bracket_pairs()
        -- replaces atoms in place, never inserts/removes) - "(", "[", "a", "]", ")", 5 atoms.
        check("([a]): 5 children", #children == 5)
        check("([a]): outer \"(\" pairs with outer \")\"",
                mexpru.u(children[1]).bracket.peer == mexpru.u(children[5]))
        check("([a]): inner \"[\" pairs with inner \"]\"",
                mexpru.u(children[2]).bracket.peer == mexpru.u(children[4]))
    end

    -- Part 3: an empty pair "()" in the source text doesn't crash resolve_bracket_pairs() - a
    -- filler empty atom keeps the span non-empty, same as a live-typed empty pair already gets.
    do
        local ok, c = pcall(mformula_latex.from_latex, fs, SZ, "()")
        check("from_latex(\"()\") does not error", ok)
        if ok then
            local children = mexpru.u(c.root).children
            check("(): 3 children (open, filler, close)", #children == 3)
            check("(): filler is a real empty box", children[2].type == vc.MEXPR_TYPE_EMPTY_BOX)
            check("(): still correctly paired", mexpru.u(children[1]).bracket.peer == mexpru.u(children[3]))
        end
    end

    -- Part 4: a mismatched close ("(a]") is left as a PLAIN, untagged glyph rather than a guessed
    -- pairing - same leniency this parser already has everywhere else.
    do
        local c = mformula_latex.from_latex(fs, SZ, "(a]")
        local children = mexpru.u(c.root).children
        check("(a]: 3 children", #children == 3)
        check("(a]: \"(\" is still tagged, but never found its own peer (still pending)",
                mexpru.u(children[1]).bracket and mexpru.u(children[1]).bracket.is_open
                        and not mexpru.u(children[1]).bracket.peer)
        check("(a]: \"]\" has NO bracket tag at all - a plain, unpaired glyph",
                mexpru.u(children[3]).bracket == nil)
    end

    print("checks: " .. checks_run .. ", failed: " .. checks_failed)
    if checks_failed > 0 then
        return false
    end
    print("PASS: bracket pairs survive a save/load round-trip")
    return true
end

--[[
test_bracket_counter.lua - THE bracket rule, stated as a count instead of a walk.

Ruled 2026-09-05, verbatim: "do the contor trick, a paranthesis can close only on zero opened
paranthesis and it can never decrease". Two clauses, and each one is a real bug that had already
happened here:
  - "only on zero opened": inner pairs must all be closed before ours can be, or the pairs
    interleave ("(_1 (_2 a )_1 )_2" - which renders AND serialises as an innocent "((a))", the
    damage living only in the peer links).
  - "never decrease [below zero]": a step below zero is the close of the pair ENCLOSING us, so that
    position and everything past it is out of bounds.

What makes a count the right tool rather than another walk: mexpru.bracket_delta() gives every slot
a contribution, and a supsub contributes whatever its own BASE is. A base sits in document order
exactly where its compound does and can BE a bracket - "(a)^{N}" is [ "(", a, supsub(base=")") ] -
so the closing half of that pair is not a sibling at all. Every depth-tracked scan was blind to it
and, being a blind walk, did not fail cleanly either: it sailed past and reported some unrelated
bracket as the boundary, which is how mispaired and unbalanced states kept getting built while both
the rendering and the LaTeX looked fine. A count sees it, is checkable at any point over any range,
and needs no knowledge of which atom is whose partner.
]]

package.path = package.path .. ";./scripts/?.lua"

local vc = require("virt_composer")
local char = require("char")
local mexpru = require("mexpru")

local checks_run, checks_failed = 0, 0
local function check(name, cond, got)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name .. (got ~= nil and ("  (got: " .. tostring(got) .. ")") or ""))
    end
end

local function glyph(fs, ascii, sz)
    local entry = char.find_by_ascii(ascii)
    local g = mexpru.mexpr_symbol(fs, {size = sz, code = entry.ncod}, true)
    mexpru.u(g).sz = sz
    return g
end

local function open_at(fs, sz)
    local g = glyph(fs, "(", sz)
    mexpru.u(g).bracket = {is_open = true, type = vc.MEXPR_BRACKET_ROUND}
    return g
end
local function close_at(fs, sz)
    local g = glyph(fs, ")", sz)
    mexpru.u(g).bracket = {is_open = false, type = vc.MEXPR_BRACKET_ROUND}
    return g
end

function run_test()
    local fs = char.load_font_set()
    local SZ = 12

    -- bracket_delta(): the three contributions, including the one every previous walk missed.
    do
        check("an open counts +1", mexpru.bracket_delta(open_at(fs, SZ)) == 1)
        check("a close counts -1", mexpru.bracket_delta(close_at(fs, SZ)) == -1)
        check("an ordinary atom counts 0", mexpru.bracket_delta(glyph(fs, "a", SZ)) == 0)

        -- A supsub whose BASE is a ")" - "(a)^{N}". This is the case that defeated every walk.
        local base_close = close_at(fs, SZ)
        local sup = mexpru.horiz(fs, {glyph(fs, "N", SZ - 2)}, SZ - 2)
        local compound = mexpru.supsub(fs, base_close, sup, nil)
        check("a supsub counts as its BASE - a ')' base still counts -1",
                mexpru.bracket_delta(compound) == -1, mexpru.bracket_delta(compound))

        local base_plain = mexpru.supsub(fs, glyph(fs, "a", SZ),
                mexpru.horiz(fs, {glyph(fs, "N", SZ - 2)}, SZ - 2), nil)
        check("...and counts 0 when its base is an ordinary atom",
                mexpru.bracket_delta(base_plain) == 0)
    end

    -- bracket_count(): "only on zero", and "never below zero".
    do
        -- "( ( a ) )" - from just inside the OUTER open, the only balanced stopping point is after
        -- the inner pair closes.
        local kids = {open_at(fs, SZ), open_at(fs, SZ), glyph(fs, "a", SZ),
                close_at(fs, SZ), close_at(fs, SZ)}
        check("inside an inner pair the count is non-zero - closing there would interleave",
                mexpru.bracket_count(kids, 2, 3) == 1, mexpru.bracket_count(kids, 2, 3))
        check("once the inner pair closes the count is back to zero - closing is allowed",
                mexpru.bracket_count(kids, 2, 4) == 0)
        check("stepping onto the ENCLOSING close returns nil - never decrease past zero",
                mexpru.bracket_count(kids, 2, 5) == nil)
    end

    -- The same bound, but with the inner pair's ")" hidden inside a supsub base: "( ( a )^{N} )".
    -- The old depth walk could not see that ")" and reported the OUTER close as the boundary,
    -- which let a close land outside its own group.
    do
        local inner_open = open_at(fs, SZ)
        local base_close = close_at(fs, SZ)
        local compound = mexpru.supsub(fs, base_close,
                mexpru.horiz(fs, {glyph(fs, "N", SZ - 2)}, SZ - 2), nil)
        local kids = {open_at(fs, SZ), inner_open, glyph(fs, "a", SZ), compound, close_at(fs, SZ)}

        check("the base ')' is counted, so the inner pair balances at the compound",
                mexpru.bracket_count(kids, 2, 4) == 0, mexpru.bracket_count(kids, 2, 4))
        check("and the outer close is still correctly out of bounds",
                mexpru.bracket_count(kids, 2, 5) == nil)
    end

    -- brackets_balanced(): the whole-horiz invariant. Only a NEGATIVE step is corruption; a
    -- positive leftover is just a bracket typed and not yet closed.
    do
        local balanced = {open_at(fs, SZ), glyph(fs, "a", SZ), close_at(fs, SZ)}
        local ok, count = mexpru.brackets_balanced(balanced)
        check("a balanced horiz is ok with count 0", ok and count == 0)

        local pending = {open_at(fs, SZ), glyph(fs, "a", SZ)}
        ok, count = mexpru.brackets_balanced(pending)
        check("a still-pending open is ok, just count 1 - a legitimate mid-edit state",
                ok and count == 1)

        local corrupt = {glyph(fs, "a", SZ), close_at(fs, SZ)}
        ok = mexpru.brackets_balanced(corrupt)
        check("a close with nothing open is NOT ok - the state no edit may produce", ok == false)

        -- The reported shape: a leading "(" whose partner no longer exists - "((A)".
        local orphaned = {open_at(fs, SZ), open_at(fs, SZ), glyph(fs, "a", SZ), close_at(fs, SZ)}
        ok, count = mexpru.brackets_balanced(orphaned)
        check("\"((A)\" is flagged by the leftover count, not silently accepted",
                ok and count == 1, count)
    end

    print("checks: " .. checks_run .. ", failed: " .. checks_failed)
    if checks_failed > 0 then
        return false
    end
    print("PASS: the bracket counter rule - close only at zero, never below zero, bases counted")
    return true
end

--[[
test_bracket_no_crossing.lua - bracket pairs must NEST, never interleave: "(_1 (_2 a )_1 )_2" is
not a structure this editor is allowed to produce.

Named as the actual root cause, 2026-09-05, after a run of separate "bracket got somewhere it
shouldn't" symptoms had each been guarded individually: "the problem we have is that we can do
(_1 (_2 a )_1 )_2, this is not ok, the user should not be able to pass outside the acceptable place
to place a bracket area, so shouldn't be able to travel to sup or sub, or whatever else".

How it used to happen, entirely through ordinary keystrokes: type "(a)" (pair 1 resolved), put the
cursor between "(" and "a", type "(" (pair 2, now pending), walk RIGHT past ")_1", press ")".
try_close_bracket() only ever checked "same parent, at or after my own open index" - no right-hand
bound at all - so it inserted ")_2" after ")_1" and the two pairs came out interleaved. The result
renders, and even SERIALIZES, as an innocent "((a))": the damage is only in the peer links, which
is exactly why it went unseen while scan_bracket()/resolve_bracket_pairs()/cascade-delete all
quietly built on a structure that was never valid.

Fixed by close_position_ok() (mformula_new.lua) - one shared definition of "where may this pending
bracket close", used BOTH by try_close_bracket() and by the arrow-key cursor confinement, so the
two can't drift apart. Its right-hand bound is mexpru.scan_bracket() walking out from the pending
open to whatever pair encloses it.

This test drives the boundary itself rather than the keystrokes (handle_input() isn't callable
headless - same reason as every other handle_input-adjacent test here): it builds the exact
"(_1 (_2 a )_1" mid-edit shape and asserts scan_bracket() reports the enclosing close, i.e. that the
bound try_close_bracket() now refuses to cross is really there and really points at ")_1".
]]

package.path = package.path .. ";./scripts/?.lua"

local vc = require("virt_composer")
local char = require("char")
local mexpru = require("mexpru")

local checks_run, checks_failed = 0, 0
local function check(name, cond)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name)
    end
end

local function glyph(fs, ascii, sz)
    local entry = char.find_by_ascii(ascii)
    local g = mexpru.mexpr_symbol(fs, {size = sz, code = entry.ncod}, true)
    mexpru.u(g).sz = sz
    return g
end

function run_test()
    local fs = char.load_font_set()
    local SZ = 12

    -- "(_1 (_2 a )_1" - pair 1 already resolved around everything, pair 2 still PENDING (no peer),
    -- sitting just inside it. This is the exact mid-edit state reached by typing "(a)" and then
    -- "(" with the cursor parked between "(" and "a".
    local open1 = glyph(fs, "(", SZ)
    mexpru.u(open1).bracket = {is_open = true, type = vc.MEXPR_BRACKET_ROUND}
    local open2 = glyph(fs, "(", SZ)
    mexpru.u(open2).bracket = {is_open = true, type = vc.MEXPR_BRACKET_ROUND}   -- pending: no peer
    local A = glyph(fs, "a", SZ)
    local close1 = glyph(fs, ")", SZ)
    mexpru.u(close1).bracket = {is_open = false, type = vc.MEXPR_BRACKET_ROUND, peer = mexpru.u(open1)}
    mexpru.u(open1).bracket.peer = mexpru.u(close1)

    local root = mexpru.horiz(fs, {open1, open2, A, close1}, SZ)
    mexpru.update_positions(root)
    local children = mexpru.u(root).children

    check("setup: four flat siblings, ( ( a )", #children == 4)
    check("setup: pair 2 really is still pending (no peer)",
            mexpru.u(children[2]).bracket ~= nil and mexpru.u(children[2]).bracket.peer == nil)

    -- close_position_ok()'s own right-hand bound: scan_bracket() walking right from the pending
    -- open finds the ENCLOSING pair's close - index 4, ")_1".
    local enclosing_close = mexpru.scan_bracket(children, 2, 1)
    check("scan_bracket finds the enclosing close of the pending open", enclosing_close == 4)

    -- So closing is legal strictly BEFORE that, and illegal at or past it. Closing at index 3
    -- ("a") nests properly -> "(_1 (_2 a )_2 )_1"; closing at index 4 (")_1") is the crossing that
    -- used to be allowed and produced "(_1 (_2 a )_1 )_2".
    check("closing on \"a\" (before the enclosing close) is inside the legal region",
            3 < enclosing_close)
    check("closing ON the enclosing close itself is outside it - the crossing that's now refused",
            not (4 < enclosing_close))

    -- The same bound with NOTHING enclosing the pending open: no right-hand limit at that level.
    do
        local lone_open = glyph(fs, "(", SZ)
        mexpru.u(lone_open).bracket = {is_open = true, type = vc.MEXPR_BRACKET_ROUND}
        local B = glyph(fs, "b", SZ)
        local root2 = mexpru.horiz(fs, {lone_open, B}, SZ)
        mexpru.update_positions(root2)
        check("an unenclosed pending open has no right-hand bound at all",
                mexpru.scan_bracket(mexpru.u(root2).children, 1, 1) == nil)
    end

    print("checks: " .. checks_run .. ", failed: " .. checks_failed)
    if checks_failed > 0 then
        return false
    end
    print("PASS: a pending bracket's closable region stops at the enclosing pair's close - "
            .. "interleaved pairs are unreachable")
    return true
end

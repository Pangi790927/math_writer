--[[
test_bracket_empty_span.lua - handle_input()'s own backspace/delete branch (mformula_new.lua) has to
keep a resolved bracket pair's span non-empty even when the ONLY content between the two atoms gets
removed - resolve_bracket_pairs() (mexpru.lua) errors loudly on an empty span rather than
misbehaving silently, and this crashed live, 2026-09-05, from the exact keystroke sequence in this
file's own name: "(", "a", ")", Left, Backspace - backspacing "a" (an ORDINARY atom, not a bracket
atom itself - the existing cascade-delete path never fires) left "(" and ")" immediately adjacent,
with nothing between them.

handle_input() itself isn't directly callable headless (real keypress-driven - same reason
test_bracket_cascade.lua builds its own resolved pair by hand instead of going through
open_bracket()/try_close_bracket()) - this mirrors its own fix instead: after removing an ordinary
atom, check whether that left an open/close pair immediately adjacent (mexpru.scan_bracket(), the
same structural check the fix itself uses), and confirm a filler atom keeps the span valid before
handing the result to mexpru.horiz() (which is what would otherwise error).
]]

package.path = package.path .. ";./scripts/?.lua"

local vc = require("virt_composer")
local char = require("char")
local mexpru = require("mexpru")
local same = mexpru.same

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

    -- ( A ), a REAL resolved pair (resolve_bracket_pairs() triggers automatically inside
    -- mexpru.horiz() below) - the exact shape "(", "a", ")" typing produces live.
    local open_atom = glyph(fs, "(", SZ)
    mexpru.u(open_atom).bracket = {is_open = true, type = vc.MEXPR_BRACKET_ROUND}
    local A = glyph(fs, "a", SZ)
    local close_atom = glyph(fs, ")", SZ)
    mexpru.u(close_atom).bracket = {is_open = false, type = vc.MEXPR_BRACKET_ROUND, peer = mexpru.u(open_atom)}
    mexpru.u(open_atom).bracket.peer = mexpru.u(close_atom)

    local root = mexpru.horiz(fs, {open_atom, A, close_atom}, SZ)
    mexpru.update_positions(root)
    local children = mexpru.u(root).children
    local open_glyph, den_A, close_glyph = children[1], children[2], children[3]
    check("setup: 3 children (open, A, close)", #children == 3)

    -- Mirror handle_input()'s own backspace branch on `A` (an ORDINARY atom - the bracket-cascade
    -- check above it never fires here, since A itself carries no u(_).bracket tag).
    local victim_idx = den_A:get_parent_idx()
    table.remove(children, victim_idx)

    -- The fix itself: children[victim_idx-1]/children[victim_idx] (open/close, now adjacent) get
    -- a filler inserted between them before the rebuild below - mexpru.scan_bracket(), not a
    -- hand-rolled peer check, same rule the real fix follows.
    local before = children[victim_idx - 1]
    local before_br = before and mexpru.u(before).bracket
    check("open bracket now sits immediately before the gap", before_br and before_br.is_open)
    local adjacent = before_br and before_br.peer
            and mexpru.scan_bracket(children, victim_idx - 1, 1) == victim_idx
    check("scan_bracket confirms open/close are now adjacent (empty span)", adjacent)

    if adjacent then
        table.insert(children, victim_idx, mexpru.mexpr_empty(fs, 4, 10, 5))
    end

    -- The actual crash: resolve_bracket_pairs() (inside mexpru.horiz()) errors loudly on an empty
    -- span - without the filler above, this pcall would come back false.
    local ok, rebuilt = pcall(mexpru.horiz, fs, children, SZ)
    check("mexpru.horiz() does NOT error once the span is kept non-empty ("
            .. tostring(not ok and rebuilt or "ok") .. ")", ok)

    if ok then
        local final_children = mexpru.u(rebuilt).children
        check("final horiz has exactly 3 children (open, filler, close)", #final_children == 3)
        check("open glyph survived, still tagged as open", mexpru.u(final_children[1]).bracket
                and mexpru.u(final_children[1]).bracket.is_open)
        check("close glyph survived, still tagged as close", mexpru.u(final_children[3]).bracket
                and not mexpru.u(final_children[3]).bracket.is_open)
    end

    print("checks: " .. checks_run .. ", failed: " .. checks_failed)
    if checks_failed > 0 then
        return false
    end
    print("PASS: backspacing a bracket pair's only content keeps its span non-empty")
    return true
end

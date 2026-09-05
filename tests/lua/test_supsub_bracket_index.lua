--[[
test_supsub_bracket_index.lua - make_supsub() (mformula_new.lua, Ctrl+Shift+'='/'-') has to read
cursor_pos's own index within its parent's children list BEFORE reparenting it onto the new supsub
node, not after - mexpru.supsub() reparents cursor_pos's own ->parent as a side effect (the SAME
hazard make_supsub()'s own comment already documented for capturing original_parent, just missed
for the index), so reading it afterward silently answers cursor_pos's index WITHIN THE NEW SUPSUB
(always 1, since cursor_pos becomes its base) instead of cursor_pos's real position in the horiz it
actually came from.

This crashed nothing, but produced a visibly wrong tree - invisible whenever cursor_pos already
happened to sit at index 1 of its own horiz (the common case), which is exactly why it went
unnoticed until reported live, 2026-09-05, from this exact sequence: "(", "a", ")", Left (lands on
"a", index 2 - between the brackets), Ctrl+Shift+'=' - overwrote children[1] (the OPEN bracket) with
the new supsub instead of children[2] ("a" itself), leaving the real "a" untouched right next to it
and the "(" gone entirely.

make_supsub()/make_frac() are exported (not just local) specifically so this - and any future
one-liner repro like it - can call the REAL function directly, the same way handle_input()'s own
Ctrl+Shift+'='/'-' branch does, rather than a hand-rolled mirror of it.
]]

package.path = package.path .. ";./scripts/?.lua"

local vc = require("virt_composer")
local char = require("char")
local mexpru = require("mexpru")
local mformula_new = require("mformula_new")
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

    -- ( a ), a REAL resolved pair (resolve_bracket_pairs() triggers automatically inside
    -- mexpru.horiz() below) - "a" sits at index 2, between the two bracket atoms, the exact shape
    -- that exposed this bug (index 1 would have hidden it).
    local open_atom = glyph(fs, "(", SZ)
    mexpru.u(open_atom).bracket = {is_open = true, type = vc.MEXPR_BRACKET_ROUND}
    local A = glyph(fs, "a", SZ)
    local close_atom = glyph(fs, ")", SZ)
    mexpru.u(close_atom).bracket = {is_open = false, type = vc.MEXPR_BRACKET_ROUND, peer = mexpru.u(open_atom)}
    mexpru.u(open_atom).bracket.peer = mexpru.u(close_atom)

    local root = mexpru.horiz(fs, {open_atom, A, close_atom}, SZ)
    mexpru.update_positions(root)
    local children = mexpru.u(root).children
    check("setup: 3 children (open, a, close)", #children == 3)
    check("setup: cursor target (A) really is at index 2, between the brackets",
            same(children[2], A) and A:get_parent_idx() == 2)

    local container = {root = root, cursor_pos = vc.wref_mexpr(A), version = 0}
    mformula_new.make_supsub(container, fs, "sup")

    local final_children = mexpru.u(container.root).children
    check("final horiz still has exactly 3 children", #final_children == 3)

    local open_final, mid, close_final = final_children[1], final_children[2], final_children[3]
    check("index 1 is still an OPEN bracket atom (not overwritten by the new supsub)",
            mexpru.u(open_final).bracket and mexpru.u(open_final).bracket.is_open)
    check("index 3 is still a CLOSE bracket atom",
            mexpru.u(close_final).bracket and not mexpru.u(close_final).bracket.is_open)
    check("index 2 is the new supsub node (kind == \"supsub\")", mexpru.u(mid).kind == "supsub")
    check("the supsub's own base is the ORIGINAL \"a\" atom - not a stray duplicate",
            same(mexpru.u(mid).base, A))
    check("cursor_pos moved into the new (empty) sup slot",
            not same(container.cursor_pos:get_obj(), A))

    print("checks: " .. checks_run .. ", failed: " .. checks_failed)
    if checks_failed > 0 then
        return false
    end
    print("PASS: make_supsub() on a bracket-interior atom targets the right index")
    return true
end

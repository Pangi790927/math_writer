--[[
test_supsub_base_bracket_cascade.lua - handle_input()'s own target_is_supsub_base backspace branch
(mformula_new.lua) has to cascade a bracket atom's own peer down with it even when that atom is
serving as a supsub's OWN base, not just when it's an ordinary flat sibling (the ALREADY-existing
cascade check further down handle_input() only ever looks at the flat children list - wrapping a
bracket atom as a supsub's own base moves it OUT of that list entirely, where scan_bracket()'s own
depth-tracked walk can no longer see it).

Reported live, 2026-09-05, from this exact sequence: "(", "a", ")", Ctrl+Shift+'=', "b" (now "(a)^b",
with ")" itself wrapped as the sup's own base), navigate back onto ")", Backspace - the branch's own
"pull in the preceding sibling as the new base" logic discarded ")" (the old base) without ever
checking it was a bracket atom, leaving "(" behind, alone, with no peer.

handle_input() itself isn't directly callable headless (real keypress-driven - same reason
test_bracket_cascade.lua builds its own resolved pair by hand instead of going through open_bracket()/
try_close_bracket()) - this mirrors the fixed branch's own logic instead: find the peer via
mexpru.scan_bracket() (starting from the SUPSUB's own position, not the wrapped atom's - it's no
longer in this flat list to have a position OF its own), account for the pull-in shifting the peer's
own index, remove both, and confirm what's left is exactly "a^b" - not "(" left dangling.
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

    -- ( a ), a REAL resolved pair, then make_supsub("sup") on the CLOSE bracket itself - the exact
    -- shape "(a)^b" produces (cursor left on ")" right after typing it).
    local open_atom = glyph(fs, "(", SZ)
    mexpru.u(open_atom).bracket = {is_open = true, type = vc.MEXPR_BRACKET_ROUND}
    local A = glyph(fs, "a", SZ)
    local close_atom = glyph(fs, ")", SZ)
    mexpru.u(close_atom).bracket = {is_open = false, type = vc.MEXPR_BRACKET_ROUND, peer = mexpru.u(open_atom)}
    mexpru.u(open_atom).bracket.peer = mexpru.u(close_atom)

    local root = mexpru.horiz(fs, {open_atom, A, close_atom}, SZ)
    mexpru.update_positions(root)
    local children = mexpru.u(root).children
    local open_final, A_final, close_final = children[1], children[2], children[3]

    local container = {root = root, cursor_pos = vc.wref_mexpr(close_final), version = 0}
    mformula_new.make_supsub(container, fs, "sup")
    -- Type "b" into the fresh sup slot.
    local sup_empty = container.cursor_pos:get_obj()
    local b_glyph = glyph(fs, "b", SZ)
    container.root = mexpru.propagate_rebuild(fs, sup_empty, b_glyph)

    local outer_children = mexpru.u(container.root).children
    check("setup: (a)^b has 3 top-level children (open bracket, a, supsub)", #outer_children == 3)
    local supsub_node = outer_children[3]
    check("setup: supsub's own base is the close bracket atom", mexpru.u(supsub_node).kind == "supsub"
            and mexpru.u(mexpru.u(supsub_node).base).bracket ~= nil)

    -- Mirror handle_input()'s own (fixed) target_is_supsub_base backspace branch: target = the
    -- supsub's own base (the close bracket), about to be discarded.
    local target = mexpru.u(supsub_node).base
    local supsub_idx = supsub_node:get_parent_idx()
    local target_br = mexpru.u(target).bracket
    local peer_idx = target_br and target_br.peer
            and mexpru.scan_bracket(outer_children, supsub_idx, target_br.is_open and 1 or -1)
    check("peer (the open bracket) found via scan_bracket", peer_idx == 1)

    local new_base
    if supsub_idx > 1 then
        new_base = outer_children[supsub_idx - 1]
        table.remove(outer_children, supsub_idx - 1)
        if peer_idx and peer_idx > supsub_idx - 1 then
            peer_idx = peer_idx - 1
        end
    end
    check("new_base is \"a\" (the preceding sibling)", same(new_base, A_final))

    local cut_peer
    if peer_idx then
        cut_peer = table.remove(outer_children, peer_idx)
    end
    check("the open bracket was actually removed from outer_children", same(cut_peer, open_final))

    local u = mexpru.u(supsub_node)
    local rebuilt_supsub = mexpru.supsub(fs, new_base, u.sup, u.sub)
    outer_children[mexpru.index_of(outer_children, supsub_node)] = rebuilt_supsub
    local rebuilt_outer = mexpru.horiz(fs, outer_children, mexpru.u(container.root).sz)
    container.root = mexpru.propagate_rebuild(fs, container.root, rebuilt_outer)
    mexpru.cut(cut_peer)

    local final_children = mexpru.u(container.root).children
    check("final result is exactly 1 top-level child (\"a^b\", both brackets gone)",
            #final_children == 1)
    check("that child is a supsub with base \"a\"", mexpru.u(final_children[1]).kind == "supsub"
            and same(mexpru.u(final_children[1]).base, A_final))
    check("...and no bracket tag lingering on the new base", mexpru.u(mexpru.u(final_children[1]).base).bracket == nil)

    print("checks: " .. checks_run .. ", failed: " .. checks_failed)
    if checks_failed > 0 then
        return false
    end
    print("PASS: backspacing a bracket atom serving as a supsub's own base cascades its peer too")
    return true
end

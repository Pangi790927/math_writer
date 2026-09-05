--[[
test_cascade_cursor_landing.lua - after a bracket cascade-delete, the cursor lands just before the
atom you ACTUALLY deleted, never before its peer.

Reported live, 2026-09-05: "after the cursor deletes a bracket it shouldn't jump to the other one if
I do ((a)) and delete, it wil jump me to the left of <a> (the result)". Backspacing the CLOSE
bracket of a pair used to land the cursor at the pair's far LEFT edge - handle_input()'s cascade
branch set its landing index to `lo` (the lower of victim/peer), which is the PEER's slot whenever
the victim is the closing bracket. So you'd delete at the right-hand end of "((a))" and be teleported
across the whole group to sit left of the "a".

Deleting the OPEN bracket was always correct and is deliberately covered here too: there victim IS
`lo`, so the old and new readings agree exactly, and this test pins that down so the fix can't drift
into "moved the wrong direction instead".

handle_input() isn't callable headless (real keypress-driven - same reason as every other
handle_input-adjacent test here), so this mirrors that branch's own index arithmetic directly, the
way test_bracket_cascade.lua already does for the removal itself.
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

-- "((a))" - two REAL resolved pairs, nested, built the same way mexpru.horiz()/
-- resolve_bracket_pairs() produce them from a live close-bracket keypress.
local function build_nested(fs, sz)
    local o1, o2 = glyph(fs, "(", sz), glyph(fs, "(", sz)
    local A = glyph(fs, "a", sz)
    local c2, c1 = glyph(fs, ")", sz), glyph(fs, ")", sz)

    mexpru.u(o1).bracket = {is_open = true, type = vc.MEXPR_BRACKET_ROUND}
    mexpru.u(c1).bracket = {is_open = false, type = vc.MEXPR_BRACKET_ROUND, peer = mexpru.u(o1)}
    mexpru.u(o1).bracket.peer = mexpru.u(c1)
    mexpru.u(o2).bracket = {is_open = true, type = vc.MEXPR_BRACKET_ROUND}
    mexpru.u(c2).bracket = {is_open = false, type = vc.MEXPR_BRACKET_ROUND, peer = mexpru.u(o2)}
    mexpru.u(o2).bracket.peer = mexpru.u(c2)

    local root = mexpru.horiz(fs, {o1, o2, A, c2, c1}, sz)
    mexpru.update_positions(root)
    return root, mexpru.u(root).children
end

-- Mirrors handle_input()'s own cascade branch: remove victim + peer, then work out where the
-- cursor should land. Returns the node the cursor ends up ON (nil = the horiz itself, i.e. "before
-- everything").
local function cascade_delete(fs, root, victim_idx, sz)
    local children = mexpru.u(root).children
    local victim = children[victim_idx]
    local victim_br = mexpru.u(victim).bracket
    local peer_idx = victim_br and victim_br.peer
            and mexpru.scan_bracket(children, victim_idx, victim_br.is_open and 1 or -1)

    local lo, hi = math.min(victim_idx, peer_idx), math.max(victim_idx, peer_idx)
    table.remove(children, hi)
    table.remove(children, lo)

    local cursor_i = victim_idx
    if peer_idx and peer_idx < victim_idx then
        cursor_i = victim_idx - 1
    end

    local rebuilt = mexpru.horiz(fs, children, sz)
    mexpru.update_positions(rebuilt)
    if cursor_i > 1 and children[cursor_i - 1] then
        return children[cursor_i - 1], children
    end
    return nil, children
end

function run_test()
    local fs = char.load_font_set()
    local SZ = 12

    -- Backspace the INNER close ")_2" (index 4). Result is "(a)"; the cursor should rest on "a" -
    -- exactly where the deleted ")_2" sat - NOT on the "(" to a's left.
    do
        local root, children = build_nested(fs, SZ)
        local A = children[3]
        check("setup: ((a)) has 5 flat children", #children == 5)

        local landed, final = cascade_delete(fs, root, 4, SZ)
        check("inner pair gone, \"(a)\" left", #final == 3)
        check("cursor landed ON \"a\", where the deleted \")\" was", landed ~= nil and same(landed, A))
        check("...and NOT on the opening bracket to a's left",
                landed ~= nil and mexpru.u(landed).bracket == nil)
    end

    -- Backspace the OUTER close ")_1" (index 5). Result is "(a)" again; the cursor should rest on
    -- the remaining ")_2" - the atom that sat immediately before the deleted ")_1".
    do
        local root, children = build_nested(fs, SZ)
        local landed, final = cascade_delete(fs, root, 5, SZ)
        check("outer pair gone, \"(a)\" left", #final == 3)
        check("cursor landed on the remaining close bracket, where \")_1\" sat",
                landed ~= nil and mexpru.u(landed).bracket ~= nil
                and mexpru.u(landed).bracket.is_open == false)
    end

    -- Backspace an OPEN bracket - the direction that was always correct. Deleting "(_2" (index 2)
    -- leaves "(a)" with the cursor on "(_1", the atom right before what was deleted.
    do
        local root, children = build_nested(fs, SZ)
        local o1 = children[1]
        local landed, final = cascade_delete(fs, root, 2, SZ)
        check("inner pair gone via its OPEN side, \"(a)\" left", #final == 3)
        check("cursor landed on the outer open bracket, right before the deleted \"(_2\"",
                landed ~= nil and same(landed, o1))
    end

    print("checks: " .. checks_run .. ", failed: " .. checks_failed)
    if checks_failed > 0 then
        return false
    end
    print("PASS: cascade-delete leaves the cursor beside the bracket actually deleted, "
            .. "never jumped across to its peer")
    return true
end

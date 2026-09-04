--[[
test_bracket_cascade.lua - mexpru.cut()/mexpru.scan_bracket() and the cascade-delete logic they
back (mformula_new.lua's own backspace/delete branch, 2026-09-04 design discussion): removing a
resolved bracket atom takes its peer down with it, content between them survives unwrapped, and
whatever's cut lets go of Lua's own reference to it immediately - no lingering, no GC forcing
needed, verified directly by checking a weak ref to the cut node reads back nil right away.

open_bracket()/try_close_bracket() (mformula_new.lua) aren't exported (real keypress-driven, not
directly callable headless) - this builds an already-RESOLVED bracket pair by hand, the same shape
try_close_bracket() itself produces (a pending open + a linked close, handed to mexpru.horiz(),
which resolves the pair into real sized glyphs via resolve_bracket_pairs() the same way a live
close-bracket keypress would), then drives the cascade-delete primitives directly.
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

-- Builds Y ( A ) Z as one horiz, with a REAL, resolved bracket pair around A (own real sized
-- glyphs, via resolve_bracket_pairs() - triggered automatically inside mexpru.horiz() below, same
-- as a live close-bracket keypress triggers it via try_close_bracket()'s own final rebuild).
local function build_bracketed(fs, sz)
    local Y = glyph(fs, "Y", sz)
    local A = glyph(fs, "A", sz)
    local Z = glyph(fs, "Z", sz)

    local open_atom = glyph(fs, "(", sz)
    mexpru.u(open_atom).bracket = {is_open = true, type = vc.MEXPR_BRACKET_ROUND}
    local close_atom = glyph(fs, ")", sz)
    mexpru.u(close_atom).bracket = {is_open = false, type = vc.MEXPR_BRACKET_ROUND, peer = mexpru.u(open_atom)}
    mexpru.u(open_atom).bracket.peer = mexpru.u(close_atom)

    local root = mexpru.horiz(fs, {Y, open_atom, A, Z, close_atom}, sz)
    -- open_atom/close_atom are now STALE - resolve_bracket_pairs() (inside mexpru.horiz() above)
    -- already replaced both with real sized glyphs. Read the CURRENT ones back off the tree.
    local children = mexpru.u(root).children
    return root, children[1], children[2], children[3], children[4], children[5]
end

function run_test()
    local fs = char.load_font_set()
    local SZ = 10

    -- ============================================================
    -- Part 1: backspace on the OPEN bracket cascades to remove the CLOSE too - content (A, and Z)
    -- survives, unwrapped, as ordinary siblings of the same horiz.
    -- ============================================================
    do
        local root, Y, open_glyph, A, Z, close_glyph = build_bracketed(fs, SZ)
        mexpru.update_positions(root)
        check("setup: open glyph carries .bracket", mexpru.u(open_glyph).bracket ~= nil)
        check("setup: close glyph carries .bracket with a peer",
                mexpru.u(close_glyph).bracket and mexpru.u(close_glyph).bracket.peer ~= nil)

        local open_weak = vc.wref_mexpr(open_glyph)
        local close_weak = vc.wref_mexpr(close_glyph)

        -- Mirror handle_input()'s own backspace branch on `open_glyph`.
        local children = mexpru.u(root).children
        local victim_idx = open_glyph:get_parent_idx()
        local victim_br = mexpru.u(open_glyph).bracket
        local peer_idx = victim_br and victim_br.peer
                and mexpru.scan_bracket(children, victim_idx, victim_br.is_open and 1 or -1)
        check("scan_bracket finds the close glyph's own index", peer_idx == close_glyph:get_parent_idx())

        local lo, hi = math.min(victim_idx, peer_idx), math.max(victim_idx, peer_idx)
        local removed_hi = table.remove(children, hi)
        local removed_lo = table.remove(children, lo)

        -- mexpru.cut() has to wait until AFTER propagate_rebuild() - the OLD ancestor chain (not
        -- yet superseded) still holds its own C++-side reference to these nodes until then (see
        -- mformula_new.lua's own handle_input() comment on this exact ordering requirement).
        local rebuilt = mexpru.horiz(fs, children, SZ)
        root = mexpru.propagate_rebuild(fs, root, rebuilt)
        -- open_glyph/close_glyph are the SAME nodes as removed_lo/removed_hi - still separate LOCAL
        -- VARIABLES though, each its own live reference for as long as this `do` block's scope
        -- lasts, regardless of whether they're read again. Same discipline as everywhere else in
        -- this session: nil them out before cutting, or they count as additional owners themselves.
        open_glyph, close_glyph = nil, nil
        mexpru.cut(removed_hi)
        mexpru.cut(removed_lo)

        check("open glyph's own weak ref is nil IMMEDIATELY after cut, no GC forced",
                open_weak:get_obj() == nil)
        check("close glyph's own weak ref is nil IMMEDIATELY after cut, no GC forced",
                close_weak:get_obj() == nil)

        local final_children = mexpru.u(root).children
        check("final horiz has exactly 3 children (Y, A, Z) - both brackets gone, nothing else lost",
                #final_children == 3)
        check("A survived, now an ordinary sibling", same(final_children[2], A))
        check("A's own kind is no longer bracket-tagged", mexpru.u(A).bracket == nil)
        check("Z survived too", same(final_children[3], Z))
    end

    -- ============================================================
    -- Part 2: backspace on the CLOSE bracket (from the right side) cascades the SAME way, finding
    -- its peer by scanning LEFTWARD this time.
    -- ============================================================
    do
        local root, Y, open_glyph, A, Z, close_glyph = build_bracketed(fs, SZ)
        mexpru.update_positions(root)

        local children = mexpru.u(root).children
        local victim_idx = close_glyph:get_parent_idx()
        local victim_br = mexpru.u(close_glyph).bracket
        local peer_idx = victim_br and victim_br.peer
                and mexpru.scan_bracket(children, victim_idx, victim_br.is_open and 1 or -1)
        check("scan_bracket (leftward) finds the open glyph's own index", peer_idx == open_glyph:get_parent_idx())

        local lo, hi = math.min(victim_idx, peer_idx), math.max(victim_idx, peer_idx)
        local removed_hi = table.remove(children, hi)
        local removed_lo = table.remove(children, lo)

        local rebuilt = mexpru.horiz(fs, children, SZ)
        root = mexpru.propagate_rebuild(fs, root, rebuilt)
        mexpru.cut(removed_hi)
        mexpru.cut(removed_lo)

        local final_children = mexpru.u(root).children
        check("final horiz has exactly 3 children again", #final_children == 3)
        check("A still there", same(final_children[2], A))
    end

    -- ============================================================
    -- Part 3: a still-PENDING open bracket (never closed - no peer) has nothing to cascade to,
    -- but mexpru.cut() still makes a weak ref to it (standing in for container.pending_bracket)
    -- correctly read nil right away.
    -- ============================================================
    do
        local Y = glyph(fs, "Y", SZ)
        local pending_open = glyph(fs, "(", SZ)
        mexpru.u(pending_open).bracket = {is_open = true, type = vc.MEXPR_BRACKET_ROUND}
        local root = mexpru.horiz(fs, {Y, pending_open}, SZ)
        mexpru.update_positions(root)

        local pending_bracket = vc.wref_mexpr(pending_open)   -- stands in for container.pending_bracket
        check("setup: pending_bracket alive before removal", pending_bracket:get_obj() ~= nil)

        local children = mexpru.u(root).children
        local victim_idx = pending_open:get_parent_idx()
        local victim_br = mexpru.u(pending_open).bracket
        local peer_idx = victim_br and victim_br.peer
                and mexpru.scan_bracket(children, victim_idx, victim_br.is_open and 1 or -1)
        check("a never-closed bracket has no peer to find", peer_idx == nil)

        table.remove(children, victim_idx)
        local rebuilt = mexpru.horiz(fs, children, SZ)
        root = mexpru.propagate_rebuild(fs, root, rebuilt)
        mexpru.cut(pending_open)

        check("pending_bracket's own weak ref is nil IMMEDIATELY after cut, with zero separate bookkeeping",
                pending_bracket:get_obj() == nil)
    end

    print("checks: " .. checks_run .. ", failed: " .. checks_failed)
    if checks_failed > 0 then
        return false
    end
    print("PASS: bracket cascade-delete (mexpru.cut()/scan_bracket()) checks out")
    return true
end

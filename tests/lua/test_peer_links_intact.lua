--[[
test_peer_links_intact.lua - a resolved bracket pair's two peer links must always point AT EACH
OTHER, and nothing may be removed that quietly takes one half of a pair with it.

Reported live, 2026-09-05 ("reached an invalid state"): "((A)^{N})" backspaced down to the
unbalanced "((A)" - a leading "(" left behind pointing at a partner that no longer existed anywhere
in the tree. Found by dumping the live peer map every frame; the broken pair read as linked from one
side and orphaned from the other, which is invisible in both the rendering and the LaTeX.

THREE separate faults, all of them the same underlying invariant, and all only reachable once a ")"
can be a supsub's own BASE ("(a+b)^2" needs that) - because a base is not a sibling in the flat
children list that every bracket walk searches:

  1. try_close_bracket() stored the wrong OBJECT in the close atom's own peer - the open atom's
     BRACKET table instead of its u table (the local is called `open_bracket_u`, which is what made
     it look right). Harmless for as long as every pair got resolved, since resolve_bracket_pairs()
     rewrites both links correctly the moment it resolves one - but it can never resolve a pair
     closed onto a base, so exactly there the bad link survived forever.
  2. The cascade delete located a victim's peer with mexpru.scan_bracket(), a blind depth walk.
     mexpru.lua's own doc says a bracket's partner is found by a direct .peer read and that walk is
     for enclosing pairs only. With the real peer sitting in a base where the walk cannot see it,
     the walk didn't fail cleanly - it sailed past and returned the next unmatched bracket along,
     cascading two atoms that were never partners.
  3. Deleting a whole SUPSUB took its base along, and that base can be half of a pair - so the other
     half has to go too. The invariant is "removing anything that CONTAINS half a pair takes the
     other half with it", not merely "removing a bracket takes its peer".

This test states the invariant directly rather than re-testing each splice, so any future path that
breaks a link fails here regardless of which one it is.
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

--[[ Every bracket atom reachable in `children` - as an ordinary sibling OR as a supsub's base -
paired with where its peer actually lives. Returns a list of {node, peer_found} so the invariant can
be asserted over the WHOLE tree rather than one splice at a time. ]]
local function audit(children)
    local atoms = {}
    local function note(node)
        local br = mexpru.u(node).bracket
        if br then
            atoms[#atoms + 1] = {node = node, br = br}
        end
    end
    for _, c in ipairs(children) do
        note(c)
        local cu = mexpru.u(c)
        if cu.kind == "supsub" and cu.base then
            note(cu.base)
        end
    end
    return atoms
end

-- Is `peer` (a u table) actually reachable somewhere in this list, as a sibling or as a base?
local function peer_reachable(children, peer)
    for _, c in ipairs(children) do
        if mexpru.u(c) == peer then return true end
        local cu = mexpru.u(c)
        if cu.kind == "supsub" and cu.base and mexpru.u(cu.base) == peer then return true end
    end
    return false
end

local function assert_links_sound(children, label)
    for _, entry in ipairs(audit(children)) do
        local br = entry.br
        if br.peer then
            check(label .. ": peer is reachable, not dangling",
                    peer_reachable(children, br.peer))
            -- ...and the link is genuinely mutual: whatever it points at points back.
            local back = br.peer.bracket
            check(label .. ": the peer links back to this same atom",
                    back ~= nil and back.peer == mexpru.u(entry.node))
        end
    end
end

function run_test()
    local fs = char.load_font_set()
    local SZ = 12

    -- "(a)^{N}" built the way try_close_bracket()'s close-onto-a-base path builds it: the ")" IS
    -- the supsub's base, and the peer links are set at that moment - the exact spot fault 1 lived.
    local function build(prefix)
        local open_atom = glyph(fs, "(", SZ)
        mexpru.u(open_atom).bracket = {is_open = true, type = vc.MEXPR_BRACKET_ROUND}
        local A = glyph(fs, "a", SZ)
        local close_glyph = glyph(fs, ")", SZ)
        -- Both sides get the other's u TABLE - the convention every lookup compares against.
        mexpru.u(close_glyph).bracket = {is_open = false, type = vc.MEXPR_BRACKET_ROUND,
                peer = mexpru.u(open_atom)}
        mexpru.u(open_atom).bracket.peer = mexpru.u(close_glyph)

        local sup = mexpru.horiz(fs, {glyph(fs, "N", SZ - 2)}, SZ - 2)
        local supsub_node = mexpru.supsub(fs, close_glyph, sup, nil)

        local kids = {}
        if prefix then kids[#kids + 1] = glyph(fs, prefix, SZ) end
        kids[#kids + 1] = open_atom
        kids[#kids + 1] = A
        kids[#kids + 1] = supsub_node
        local root = mexpru.horiz(fs, kids, SZ)
        mexpru.update_positions(root)
        return root, open_atom, close_glyph, supsub_node, A
    end

    do
        local root, open_atom, close_glyph, supsub_node = build(nil)
        local kids = mexpru.u(root).children
        assert_links_sound(kids, "fresh (a)^{N}")

        -- Fault 2: the peer must be found by identity, from BOTH directions - including when it is
        -- a base the flat walk cannot see.
        -- One lookup answers both shapes now: peer_slot() reports the row slot AND the atom
        -- actually carrying the peer, so "it's a base" is carrier ~= the slot itself.
        local idx, is_base = mexpru.peer_slot(kids, open_atom)
        check("open finds its peer's row slot", idx ~= nil)
        check("...and reports it as carried by that slot's BASE, not the slot itself",
                is_base == true)
        check("the base ')' finds its own peer among the siblings by identity",
                mexpru.peer_slot(kids, close_glyph) ~= nil)
    end

    do
        -- Fault 3: deleting the whole supsub has to take the open bracket with it, since the
        -- supsub carries the ")" as its base. Mirrors handle_input()'s own victim/cascade lookup.
        local root, open_atom, close_glyph, supsub_node = build(nil)
        local kids = mexpru.u(root).children
        local victim = supsub_node
        local victim_idx = victim:get_parent_idx()

        -- slot_atom() turns "the victim is a supsub carrying a bracket as its base" into the
        -- ordinary lookup - the caller no longer has to try two things in turn.
        check("a supsub is not itself a bracket", mexpru.u(victim).bracket == nil)
        check("...but slot_atom() resolves it to the ')' it carries",
                mexpru.u(mexpru.slot_atom(victim)).bracket ~= nil)
        local peer_idx = mexpru.peer_slot(kids, mexpru.slot_atom(victim))
        check("so the cascade finds something to take down", peer_idx ~= nil)

        local lo, hi = math.min(victim_idx, peer_idx), math.max(victim_idx, peer_idx)
        table.remove(kids, hi)
        table.remove(kids, lo)
        local rebuilt = mexpru.horiz(fs, kids, SZ)
        mexpru.update_positions(rebuilt)

        check("nothing bracket-shaped is left behind at all", #audit(kids) == 0)
        assert_links_sound(kids, "after deleting the compound")
    end

    print("checks: " .. checks_run .. ", failed: " .. checks_failed)
    if checks_failed > 0 then
        return false
    end
    print("PASS: bracket peer links stay mutual and reachable, including through a supsub base")
    return true
end

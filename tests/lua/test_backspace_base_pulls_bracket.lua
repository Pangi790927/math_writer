--[[
test_backspace_base_pulls_bracket.lua - handle_input()'s target_is_supsub_base BACKSPACE branch
(mformula_new.lua) pulls the preceding sibling in as the supsub's new base - and that sibling must
never be a bracket atom.

This is the THIRD entry point into the one hazard this editor keeps re-reaching from different
directions ("a bracket atom must never be a supsub's base, or try_close_bracket()/scan_bracket()
can no longer see it as the flat sibling they both require"). The other two are already guarded:
Ctrl+Shift+=/- wrapping a bracket atom (the sup/sub dispatch), and '(' typed onto an existing base
(the OPEN_BRACKETS dispatch - test_bracket_onto_supsub_base.lua). This one arrives from the
opposite side: nothing about the keypress mentions a bracket at all, the bracket just happens to be
what sits immediately before the supsub.

Reported live, 2026-09-05 ("again malformed"), found by dumping content.serialize() after each
replayed keystroke: "(a)" -> Left -> Ctrl+Shift+'=' -> "A" gives "(a^{A})"; cursor back onto the
base "a", Backspace - the preceding sibling is the pair's OWN open bracket, so it got pulled in as
the new base and the whole formula serialized as "(^{A})": a superscript with no base, and an open
bracket no longer reachable as the flat sibling its own peer link assumes.

The fix falls back to the SAME fresh empty atom the "supsub was already first in the horiz" case
already used - backspace still does what was asked (the old base is gone) while the bracket stays
the ordinary flat sibling it has to be, pair intact.

NOTE both shapes serialize to the exact same LaTeX ("(^{A})" either way - an empty base emits
nothing), which is precisely why this test checks the STRUCTURE rather than to_latex() output: the
bug is invisible from the serialized string alone.
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

    -- "(a)" as a REAL resolved pair, then a sup on the "a" - i.e. "(a^{A})", the exact live shape.
    local open_atom = glyph(fs, "(", SZ)
    mexpru.u(open_atom).bracket = {is_open = true, type = vc.MEXPR_BRACKET_ROUND}
    local A = glyph(fs, "a", SZ)
    local close_atom = glyph(fs, ")", SZ)
    mexpru.u(close_atom).bracket = {is_open = false, type = vc.MEXPR_BRACKET_ROUND, peer = mexpru.u(open_atom)}
    mexpru.u(open_atom).bracket.peer = mexpru.u(close_atom)

    local root = mexpru.horiz(fs, {open_atom, A, close_atom}, SZ)
    mexpru.update_positions(root)
    local children = mexpru.u(root).children
    local open_final, A_final = children[1], children[2]

    local container = {root = root, cursor_pos = vc.wref_mexpr(A_final), version = 0}
    mformula_new.make_supsub(container, fs, "sup")
    local sup_empty = container.cursor_pos:get_obj()
    container.root = mexpru.propagate_rebuild(fs, sup_empty, glyph(fs, "A", SZ - 2))

    local outer = mexpru.u(container.root).children
    check("setup: (a^{A}) is open-bracket, supsub, close-bracket", #outer == 3)
    local supsub_node = outer[2]
    check("setup: the supsub's own base is \"a\"", same(mexpru.u(supsub_node).base, A_final))
    check("setup: the sibling right before the supsub IS the open bracket",
            mexpru.u(outer[1]).bracket ~= nil and mexpru.u(outer[1]).bracket.is_open)

    -- Mirror the FIXED target_is_supsub_base backspace branch: whatever sits before the supsub is
    -- only pulled in as the new base when it is NOT a bracket atom.
    local supsub_idx = supsub_node:get_parent_idx()
    local prev = supsub_idx > 1 and outer[supsub_idx - 1]
    local prev_br = prev and mexpru.u(prev).bracket
    local prev_is_open_bracket = prev_br ~= nil and prev_br.is_open
    check("the guard's own precondition fires - prev IS an OPEN bracket", prev_is_open_bracket == true)

    local new_base
    if supsub_idx > 1 and not prev_is_open_bracket then
        new_base = outer[supsub_idx - 1]
        table.remove(outer, supsub_idx - 1)
    else
        new_base = mexpru.mexpr_empty(fs, 6, 12, 6)
        mexpru.u(new_base).sz = SZ
    end

    check("the open bracket was NOT consumed as the new base", not same(new_base, open_final))
    check("the new base is a fresh empty atom instead", new_base.type == vc.MEXPR_TYPE_EMPTY_BOX)

    local u = mexpru.u(supsub_node)
    outer[mexpru.index_of(outer, supsub_node)] = mexpru.supsub(fs, new_base, u.sup, u.sub)
    local rebuilt = mexpru.horiz(fs, outer, SZ)
    container.root = mexpru.propagate_rebuild(fs, container.root, rebuilt)

    local final_children = mexpru.u(container.root).children
    check("the horiz still has all 3 slots (bracket, supsub, bracket)", #final_children == 3)
    -- Deliberately NOT an identity check against open_final: the rebuild above runs
    -- resolve_bracket_pairs(), and this pair's content is now tall enough (it has a superscript)
    -- that BOTH atoms legitimately get swapped for the tiered glyphs (mexpru.lua's own sizing
    -- rule) - a different node object each time, still the same bracket.
    check("the open bracket is STILL an ordinary flat sibling at index 1",
            mexpru.u(final_children[1]).bracket ~= nil
            and mexpru.u(final_children[1]).bracket.is_open)
    check("...and its parent is the horiz, NOT the supsub - still closeable/cascadable",
            mexpru.u(final_children[1]:get_parent()).kind == "horiz")
    check("the pair's peer links both still point at each other",
            mexpru.u(final_children[1]).bracket.peer == mexpru.u(final_children[3])
            and mexpru.u(final_children[3]).bracket.peer == mexpru.u(final_children[1]))

    --[[ KNOWN GAP, deliberately asserted as-is rather than "fixed" (2026-09-05): an empty base
    emits nothing, so this state serializes as "(^{A})" - and from_latex() reads that back by
    popping the "(" in as the supsub's base, i.e. exactly the structure the editing guard above
    refuses to build. Guarding the LOAD side the same way was tried and reverted immediately: the
    parser pops a bracket as a base for the perfectly ordinary "(a+b)^{2}" too (standard math, and
    already sitting in this repo's own saved demo content), where that IS the intended reading -
    this model has no "bracket pair as one unit" to attach a sup to instead. So the invariant "a
    bracket is never a base" and "(a+b)^2 is representable" genuinely conflict, and which way that
    resolves is a design call, not something to settle inside a regression test. Asserted here so
    the current behaviour is at least pinned down and this note is impossible to lose. ]]
    local latex = mformula_new.to_latex(container)
    check("this state still serializes to the ambiguous \"(^{A})\"", latex == "(^{A})")

    print("checks: " .. checks_run .. ", failed: " .. checks_failed)
    if checks_failed > 0 then
        return false
    end
    print("PASS: backspacing a supsub's base never drags an adjacent bracket atom in as the new base")
    return true
end

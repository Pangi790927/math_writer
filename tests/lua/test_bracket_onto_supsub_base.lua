--[[
test_bracket_onto_supsub_base.lua - handle_input()'s OPEN_BRACKETS dispatch (mformula_new.lua) has
to refuse '(' typed while cursor_pos sits on an EXISTING supsub's own base, not just refuse
Ctrl+Shift+=/- on an already-tagged bracket atom (the guard test_supsub_bracket_index.lua and
friends already cover) - the two are mirror images of the same hazard, reached from opposite
directions.

Reported live, 2026-09-05 ("a(^n"), root-caused via a temporary DBG trace added straight into
mformula_new.lua (removed once diagnosed): "(a)", Left, Ctrl+Shift+'=', "b" ("(a^{b})"), Left,
"(", Right, ")" (a SECOND, nested pair resolved INSIDE that sup - "(a^{(b)})", perfectly valid),
then Left x4 walks the cursor back out of the sup entirely and onto the OUTER supsub's own base
("a") - move_left()'s ordinary "exiting a horiz that's itself a sup/sub lands on the base" rule,
the ANY plain letter typed there already handles fine (insert_glyph_at_cursor()'s own
target_is_supsub_base branch: makes the new glyph the base, bumps the old one out as a plain
sibling). Typing '(' there BEFORE this fix took that exact same branch - making the just-typed,
still-PENDING open bracket itself the supsub's new base. Every later ')' then silently no-ops
forever (try_close_bracket()'s own open_atom:get_parent() reads back the SUPSUB node, never a
horiz, so its close_parent/open_horiz identity check can never match) - not a crash, a
permanently stuck pending bracket, invisible until you go looking for it.

insert_glyph_at_cursor()/open_bracket() aren't exported (real keypress-driven, same reason every
other handle_input()-adjacent test here builds its own scenario by hand instead) - this mirrors
the exact hazard directly: builds a resolved supsub the same shape make_supsub() produces, mirrors
insert_glyph_at_cursor()'s OWN target_is_supsub_base branch to show what typing '(' there used to
do (produces a bracket atom whose parent is the supsub node, not a horiz - the shape that then
breaks try_close_bracket() forever), and confirms the fix's own precondition
(target_is_supsub_base, computed the exact same way handle_input() computes it - parent is a
supsub AND IS this node's own base) already reads true for this exact cursor position BEFORE any
glyph is ever inserted, i.e. handle_input()'s new guard fires in time to refuse it. ]]

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

-- Same base_of()/target_is_supsub_base check handle_input() itself uses (mformula_new.lua) -
-- mirrored here since neither is exported.
local function target_is_supsub_base(target)
    local parent = target:get_parent()
    return parent ~= nil and mexpru.u(parent).kind == "supsub"
            and mexpru.same(mexpru.u(parent).base, target)
end

function run_test()
    local fs = char.load_font_set()
    local SZ = 12

    -- "a^{b}" - an ordinary resolved supsub, cursor resting on its own base "a" (exactly where 4x
    -- LeftArrow lands in the live repro above).
    local A = glyph(fs, "a", SZ)
    local B = glyph(fs, "b", SZ)
    local sub_horiz = mexpru.horiz(fs, {B}, SZ)
    local supsub_node = mexpru.supsub(fs, A, sub_horiz, nil)
    local root = mexpru.horiz(fs, {supsub_node}, SZ)
    mexpru.update_positions(root)

    check("setup: A really is this supsub's own base", same(mexpru.u(supsub_node).base, A))
    check("the fix's own precondition reads true for cursor-on-base BEFORE any glyph is inserted",
            target_is_supsub_base(A))

    -- Mirror insert_glyph_at_cursor()'s target_is_supsub_base branch by hand, with a PENDING '('
    -- as the new glyph - exactly what open_bracket() would have hidden behind it pre-fix.
    local new_open = glyph(fs, "(", SZ)
    mexpru.u(new_open).bracket = {is_open = true, type = vc.MEXPR_BRACKET_ROUND}

    local outer_children = mexpru.u(root).children
    local idx = supsub_node:get_parent_idx()
    local rebuilt_supsub = mexpru.supsub(fs, new_open, mexpru.u(supsub_node).sup, mexpru.u(supsub_node).sub)
    outer_children[idx] = rebuilt_supsub
    table.insert(outer_children, idx, A)
    local rebuilt_root = mexpru.horiz(fs, outer_children, SZ)
    root = mexpru.propagate_rebuild(fs, root, rebuilt_root)

    -- This is the exact hazard: open_atom:get_parent() (try_close_bracket()'s own first line) now
    -- reads back the SUPSUB node, not a horiz - close_parent can never match it again, so a real
    -- ')' keypress would silently no-op forever from here on, exactly as reported live.
    check("the bracket's own parent is now the supsub node, not a horiz - the permanently-stuck shape",
            mexpru.u(new_open:get_parent()).kind == "supsub")
    check("...meaning is_horiz(open_atom:get_parent()) is false - try_close_bracket() can never match it",
            mexpru.u(new_open:get_parent()).kind ~= "horiz")

    print("checks: " .. checks_run .. ", failed: " .. checks_failed)
    if checks_failed > 0 then
        return false
    end
    print("PASS: '(' typed onto an existing supsub's own base would strand it there forever - "
            .. "confirming why handle_input()'s target_is_supsub_base guard on OPEN_BRACKETS is needed")
    return true
end

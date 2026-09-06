--[[
test_empty_supsub_collapse.lua - Backspace in a sup/sub nobody typed into undoes the whole spawn.

Reported live 2026-09-06: "delete from an empty horiz no longer deletes sup when on empty horiz
x^[empty]". "No longer" is accurate - mformula.lua had collapse_if_both_empty() and the port to
mformula_new lost it, so Ctrl+Shift+= followed by Backspace left an empty superscript stuck on the
atom with no way to take it off.

It could not simply fall out of the ordinary Backspace path either: that path returns early when
the cursor is on a horiz or an empty atom ("there's no atom AT that position to act on"), and in a
still-untyped slot the cursor is on exactly those. So this is its own branch, ahead of that guard.

Both of the old rule's conditions come across, and this pins both, because each one is a way to get
it wrong:

  - BACKSPACE only, never Delete. Delete everywhere else in this file means "the thing after the
    cursor", and an empty slot has no such thing.
  - BOTH slots untyped ALREADY, at the moment the key is pressed - not merely emptied by this
    press. Otherwise backspacing the "B" out of "x^{B}" would take the whole superscript with it in
    one keystroke rather than just clearing what was typed.

Drives mformula_new.collapse_empty_supsub() rather than the keystroke, since handle_input() needs
real keypresses - the same reason every other handle_input-adjacent test here works one level down.
]]

package.path = package.path .. ";./scripts/?.lua"

local vc = require("virt_composer")
local char = require("char")
local mexpru = require("mexpru")
local mformula = require("mformula_new")

local checks_run, checks_failed = 0, 0
local function check(name, cond, got)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name .. (got ~= nil and ("  (got: " .. tostring(got) .. ")") or ""))
    end
end

local SZ = 12

local function glyph(fs, ascii)
    local entry = char.find_by_ascii(ascii)
    local g = mexpru.mexpr_symbol(fs, {size = SZ, code = entry.ncod}, true)
    mexpru.u(g).sz = SZ
    return g
end

-- A one-atom formula with the cursor on that atom, the state Ctrl+Shift+= is pressed from.
local function formula_with(fs, ascii)
    local c = mformula.new(fs, SZ)
    local g = glyph(fs, ascii)
    c.root = mexpru.propagate_rebuild(fs, c.cursor_pos:get_obj(), g)
    c.cursor_pos = vc.wref_mexpr(g)
    return c
end

local function row_len(c)
    return #mexpru.u(c.root).children
end

function run_test()
    local fs = char.load_font_set()

    -- ---------------------------------------------------------------- the reported case
    for _, slot in ipairs({"sup", "sub"}) do
        local c = formula_with(fs, "x")
        mformula.make_supsub(c, fs, slot)
        check(slot .. ": setup leaves the cursor in the new empty slot",
                c.cursor_pos:get_obj().type == vc.MEXPR_TYPE_EMPTY_BOX)
        check(slot .. ": setup made a supsub", row_len(c) == 1 and
                mexpru.u(mexpru.u(c.root).children[1]).kind == "supsub")

        check(slot .. ": Backspace there collapses it",
                mformula.collapse_empty_supsub(c, fs) == true)
        check(slot .. ": ...back to the bare base", mformula.to_latex(c) == "x",
                mformula.to_latex(c))
        check(slot .. ": ...one atom in the row again", row_len(c) == 1, row_len(c))
        check(slot .. ": ...which is no longer a supsub",
                mexpru.u(mexpru.u(c.root).children[1]).kind ~= "supsub")
        --[[ The cursor has to land somewhere real. It was inside a node that no longer exists, and
        a weak ref left pointing at the discarded tree is the dangling-cursor crash this repo
        already has a test for. ]]
        check(slot .. ": ...with the cursor on the surviving base",
                c.cursor_pos:get_obj() ~= nil
                        and mexpru.same(c.cursor_pos:get_obj(), mexpru.u(c.root).children[1]))
    end

    -- ---------------------------------------------------------------- a typed slot is not touched
    --[[ The condition that stops one Backspace from eating a whole superscript. ]]
    do
        local c = formula_with(fs, "x")
        mformula.make_supsub(c, fs, "sup")
        -- type a "B" into the fresh slot
        local b = glyph(fs, "B")
        c.root = mexpru.propagate_rebuild(fs, c.cursor_pos:get_obj(), b)
        c.cursor_pos = vc.wref_mexpr(b)
        check("setup: the sup now holds something", mformula.to_latex(c) == "x^{B}",
                mformula.to_latex(c))

        check("Backspace does NOT collapse a slot that was typed into",
                mformula.collapse_empty_supsub(c, fs) == false)
        check("...and the formula is untouched", mformula.to_latex(c) == "x^{B}",
                mformula.to_latex(c))
    end

    -- ---------------------------------------------------------------- the OTHER slot matters
    --[[ Both slots have to be untyped. An empty sup on an atom whose SUB has content is not an
    undo-the-spawn situation - collapsing there would silently delete the subscript. ]]
    do
        --[[ Built by hand rather than through make_supsub(): with the cursor on a supsub that WRAPS
        it as a new base ("(x_2)^{}"), which is a different shape entirely. What is wanted here is
        ONE supsub carrying a typed sub and an untyped sup, which is what handle_input's own
        "fill in the missing side" path produces. ]]
        local c = mformula.new(fs, SZ)
        local sub_sz = SZ - 2
        local empty_sup = mformula.build_empty_atom(fs, sub_sz)
        local sup_horiz = mexpru.horiz(fs, {empty_sup}, sub_sz)
        local sub_horiz = mexpru.horiz(fs, {glyph(fs, "2")}, sub_sz)
        local supsub = mexpru.supsub(fs, glyph(fs, "x"), sup_horiz, sub_horiz)
        c.root = mexpru.propagate_rebuild(fs, c.cursor_pos:get_obj(), supsub)
        c.cursor_pos = vc.wref_mexpr(empty_sup)
        check("setup: an empty sup over a typed sub", mformula.to_latex(c) == "x_{2}",
                mformula.to_latex(c))

        check("Backspace in the empty sup does NOT collapse - the sub would go with it",
                mformula.collapse_empty_supsub(c, fs) == false)
        check("...and the subscript is still there", mformula.to_latex(c) == "x_{2}",
                mformula.to_latex(c))
    end

    -- ---------------------------------------------------------------- everywhere else, no-op
    do
        local c = formula_with(fs, "x")
        check("on a plain atom it does nothing", mformula.collapse_empty_supsub(c, fs) == false)
        c.cursor_pos = vc.wref_mexpr(c.root)
        check("on the row itself it does nothing", mformula.collapse_empty_supsub(c, fs) == false)
    end

    print("checks: " .. checks_run .. ", failed: " .. checks_failed)
    if checks_failed > 0 then
        return false
    end
    print("PASS: Backspace undoes an untyped sup/sub spawn, and refuses once anything is in it")
    return true
end

--[[
test_undo_snapshot_clone.lua - an undo snapshot of a formula must survive the live formula being
edited underneath it.

Reported live, 2026-09-05 ("something failed bad on ctrl+z"): typing anything inside a formula and
then pressing Ctrl+Z crashed with "Expected userdata at index 1", and kept crashing every frame
afterwards because the broken container stayed in state.chars.

Cause: editor.lua snapshots with deep_copy(), which copies Lua tables but passes USERDATA straight
through - and an mexpr_t is userdata. So a snapshot's `root` was not a copy at all, it was the same
node as the live one. propagate_rebuild() then cuts every superseded node, the old root included, and
the snapshot was left pointing at freed memory. undo_or_redo()'s own comment had asserted the
invariant that quietly lapsed - "the restored chars are a fresh copy with all-new row/formula
tables" - true of the old row-based model, which was pure Lua tables, and untrue the moment a
userdata-backed tree replaced it.

The fix is mformula_new.clone(). Undo itself is keypress-driven and can't be called headless (same
reason every other handle_input-adjacent test here works one level down), so this tests the thing
that actually broke: that a clone is genuinely independent, and stays usable after the original has
been rebuilt and cut out from under it.

The weak-ref assertion in the middle matters as much as the rest - without it this test could pass
trivially if propagate_rebuild ever stopped cutting, never exercising the dangerous path at all.
]]

package.path = package.path .. ";./scripts/?.lua"

local vc = require("virt_composer")
local char = require("char")
local mexpru = require("mexpru")
local mformula_new = require("mformula_new")

local checks_run, checks_failed = 0, 0
local function check(name, cond, got)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name .. (got ~= nil and ("  (got: " .. tostring(got) .. ")") or ""))
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

    local function build(...)
        local kids = {}
        for _, a in ipairs({...}) do
            kids[#kids + 1] = glyph(fs, a, SZ)
        end
        local root = mexpru.horiz(fs, kids, SZ)
        mexpru.update_positions(root)
        return {root = root, cursor_pos = vc.wref_mexpr(kids[#kids]), version = 0}
    end

    -- ---------------------------------------------------------------------------------------
    -- The snapshot survives an edit to the live formula.
    -- ---------------------------------------------------------------------------------------
    do
        local container = build("a", "+", "b")
        local snap = mformula_new.clone(container, fs)
        check("the clone starts out matching what it copied",
                mformula_new.to_latex(snap) == "a+b", mformula_new.to_latex(snap))

        -- It must be a genuinely different tree, not the same node behind a copied table - that
        -- distinction IS the bug.
        check("the clone's root is a different node from the original",
                not mexpru.same(snap.root, container.root))

        -- Now an ordinary edit on the live one. propagate_rebuild() cuts the superseded root, which
        -- is exactly what used to take the snapshot down with it.
        local old_root_weak = vc.wref_mexpr(container.root)
        local kids = mexpru.u(container.root).children
        table.insert(kids, glyph(fs, "c", SZ))
        local rebuilt = mexpru.horiz(fs, kids, SZ)
        container.root = mexpru.propagate_rebuild(fs, container.root, rebuilt)

        check("the original root really was cut - the risky path is genuinely exercised",
                old_root_weak:get_obj() == nil)

        -- The crash was vc.mexpr_get_bb() on a freed node ("Expected userdata at index 1"), reached
        -- from measure()/content_extent() on the very next frame - so ask for exactly that.
        local ok = pcall(function() return vc.mexpr_get_bb(snap.root) end)
        check("the snapshot's root is still a live node after the original was cut", ok)

        check("the snapshot still holds the ORIGINAL content, not the edited one",
                mformula_new.to_latex(snap) == "a+b", mformula_new.to_latex(snap))
        check("...and the live formula shows the edit", mformula_new.to_latex(container) == "a+bc",
                mformula_new.to_latex(container))
    end

    -- ---------------------------------------------------------------------------------------
    -- Structure is mirrored, not flattened: nesting and brackets come through intact, and the
    -- cursor lands somewhere real on the copy.
    -- ---------------------------------------------------------------------------------------
    do
        local open_atom = glyph(fs, "(", SZ)
        mexpru.u(open_atom).bracket = {is_open = true, type = vc.MEXPR_BRACKET_ROUND}
        local A = glyph(fs, "a", SZ)
        local close_atom = glyph(fs, ")", SZ)
        mexpru.u(close_atom).bracket = {is_open = false, type = vc.MEXPR_BRACKET_ROUND,
                peer = mexpru.u(open_atom)}
        mexpru.u(open_atom).bracket.peer = mexpru.u(close_atom)
        local sup = mexpru.horiz(fs, {glyph(fs, "2", SZ - 2)}, SZ - 2)
        local root = mexpru.horiz(fs, {open_atom, A, mexpru.supsub(fs, close_atom, sup, nil)}, SZ)
        mexpru.update_positions(root)
        local container = {root = root, cursor_pos = vc.wref_mexpr(A), version = 3}

        local snap = mformula_new.clone(container, fs)
        check("a bracketed, exponent-carrying formula clones faithfully",
                mformula_new.to_latex(snap) == "(a)^{2}", mformula_new.to_latex(snap))
        check("the clone's cursor points at a real node", snap.cursor_pos:get_obj() ~= nil)
        check("the clone carries the version across", snap.version == 3)
        check("the clone's brackets are balanced in their own right",
                mexpru.brackets_balanced(mexpru.u(snap.root).children))
    end

    -- ---------------------------------------------------------------------------------------
    -- Weak refs into the OLD tree are deliberately dropped rather than copied - there are no
    -- matching nodes in a fresh copy to point them at (mformula_new.clone()'s own comment).
    -- ---------------------------------------------------------------------------------------
    do
        local container = build("x")
        container.pending_bracket = vc.wref_mexpr(container.root)
        container.sel_anchor = vc.wref_mexpr(container.root)
        local snap = mformula_new.clone(container, fs)
        check("pending_bracket is not carried into the clone", snap.pending_bracket == nil)
        check("sel_anchor is not carried into the clone", snap.sel_anchor == nil)
    end

    print("checks: " .. checks_run .. ", failed: " .. checks_failed)
    if checks_failed > 0 then
        return false
    end
    print("PASS: an undo snapshot of a formula is independent and outlives edits to the original")
    return true
end

--[[
test_undo_keeps_formula.lua - undoing an edit made INSIDE a formula must leave you inside it.

Reported live 2026-09-05: "put the cursor inside a formla, in a horiz, space, ctrl+z, the undo
operation went ok, but the cursor jumped outside the formula, I want it to stay there".

undo_or_redo() used to clear state.active_formula unconditionally, with a documented reason: the
restored chars are a fresh copy with all-new tables, so the formula that was active no longer exists
as a table to point at. True, but the POSITION survives even though the identity doesn't - so
snapshot() now records the active formula's index in chars, and the restore reads the formula back
out of that slot.

Drives editor.push_undo()/editor.undo() rather than Ctrl+Z, since handle_input() needs real
keypresses (the same reason every other handle_input-adjacent test here works one level down).
]]

package.path = package.path .. ";./scripts/?.lua"

local vc = require("virt_composer")
local char = require("char")
local mexpru = require("mexpru")
local mformula = require("mformula_new")
local editor = require("editor")

local checks_run, checks_failed = 0, 0
local function check(name, cond, got)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name .. (got ~= nil and ("  (got: " .. tostring(got) .. ")") or ""))
    end
end

-- The index in state.chars of the one item that carries a formula embed.
local function formula_index(state)
    for i, item in ipairs(state.chars) do
        if item.formula then
            return i
        end
    end
    return nil
end

function run_test()
    local fs = char.load_font_set()

    -- ------------------------------------------------------------------ the reported case
    do
        local state = editor.new()
        state._fontset = fs        -- what snapshot() clones formulas with, parked by handle_input
        editor.from_text(state, "ab$$x$$cd", fs)

        local idx = formula_index(state)
        check("setup: the text really did build a formula embed", idx ~= nil, idx)
        state.active_formula = state.chars[idx].formula
        check("setup: that formula is the active one", state.active_formula ~= nil)

        -- An edit made while the formula owns input: snapshot first, exactly as the real edit
        -- paths do, then change something.
        editor.push_undo(state, "type")
        table.insert(state.chars, {code = 1})

        editor.undo(state)

        -- a, b, the formula embed, c, d - the inserted glyph is gone again.
        check("undo restored the chars", #state.chars == 5, #state.chars)
        check("a formula is STILL active after the undo - the reported bug",
                state.active_formula ~= nil)
        check("...and it is the formula sitting in the slot that was active",
                state.active_formula == state.chars[idx].formula)
        --[[ It must be the RESTORED copy, not a stale handle into the tree undo just replaced -
        that is what test_undo_snapshot_clone.lua is about, and pointing active_formula at a
        discarded tree would resurrect exactly that crash. ]]
        check("...which is a live item of the restored chars, not a dangling one",
                state.chars[idx] ~= nil and state.chars[idx].formula ~= nil)
    end

    -- ------------------------------------------------------------------ redo comes back too
    do
        local state = editor.new()
        state._fontset = fs
        editor.from_text(state, "$$y$$", fs)
        local idx = formula_index(state)
        state.active_formula = state.chars[idx].formula

        editor.push_undo(state, "type")
        table.insert(state.chars, {code = 1})
        editor.undo(state)
        editor.redo(state)

        check("redo also lands back inside the formula", state.active_formula ~= nil)
        check("...the one in its own slot", state.active_formula == state.chars[idx].formula)
    end

    -- ------------------------------------------------------------------ nothing was active
    do
        local state = editor.new()
        state._fontset = fs
        editor.from_text(state, "plain text", fs)
        editor.push_undo(state, "type")
        table.insert(state.chars, {code = 1})
        editor.undo(state)
        check("an undo of plain editing leaves no formula active",
                state.active_formula == nil, state.active_formula)
    end

    -- ------------------------------------------------------------------ the formula is gone
    --[[ Undoing back to a state where that slot holds no formula (or holds nothing at all) has to
    fall back to plain editing rather than pointing active_formula at whatever else is there. ]]
    do
        local state = editor.new()
        state._fontset = fs
        editor.from_text(state, "$$z$$", fs)
        local idx = formula_index(state)
        state.active_formula = state.chars[idx].formula

        editor.push_undo(state, "type")
        state.chars = {}                    -- everything deleted, including the formula
        state.active_formula = nil
        editor.redo(state)                  -- forward onto the emptied state...
        editor.undo(state)                  -- ...and back, so the snapshot with no formula is used

        check("no formula in that slot means plain editing, not a bogus active_formula",
                state.active_formula == nil or state.active_formula == state.chars[idx].formula)
    end

    -- ------------------------------------------------------------------ where the caret lands
    --[[ The first fix kept you INSIDE the formula; the caret still arrived at the wrong place in
    it. Reported live straight after: "undo still jumps out, just now it jumps at the end inside the
    formula, the cursor should go to where it was before what ctrl+z removed".

    Cause: the pre-edit snapshot is CACHED and only invalidated by an edit, because rebuilding it
    every frame made the editor lag. But moving the caret does not bump version, so a baseline
    cached a few keystrokes ago holds the caret position from back then - which, right after an
    edit, is the end of whatever was just typed. The tree was always restored correctly; only the
    caret was stale.

    handle_input() needs real keypresses, so what is tested here is the mechanism that fixes it:
    a cursor position captured as a structural PATH survives being applied to a CLONE, which is
    what a snapshot holds and why a plain node reference cannot work. ]]
    do
        local fs2 = fs
        local SZ = 12
        local c = mformula.new(fs2, SZ)
        -- A row of four glyphs, so "the caret was in the middle" is distinguishable from both ends.
        local children = {}
        for _, ch in ipairs({"a", "b", "c", "d"}) do
            local e = char.find_by_ascii(ch)
            local g = mexpru.mexpr_symbol(fs2, {size = SZ, code = e.ncod}, true)
            mexpru.u(g).sz = SZ
            children[#children + 1] = g
        end
        local root = mexpru.horiz(fs2, children, SZ)
        mexpru.update_positions(root)
        mexpru.cut(c.root)
        c.root = root
        c.cursor_pos = vc.wref_mexpr(children[2])   -- the caret is in the MIDDLE, on "b"

        local path = mformula.cursor_path(c)
        check("a cursor in the row has a one-step path", path ~= nil and #path == 1,
                path and #path)
        check("...naming its own slot", path and path[1] == 2, path and path[1])

        --[[ The clone is what a snapshot actually stores. Its nodes are all new, so the live
        cursor_pos means nothing in it - resolving the PATH is what has to work. ]]
        local snap = mformula.clone(c, fs2)
        local moved = mformula.cursor_from_path(snap, path)
        check("the path resolves against a CLONE", moved == true)

        local snap_children = mexpru.u(snap.root).children
        local landed = snap.cursor_pos:get_obj()
        check("the caret lands on the same slot in the clone, not the end",
                mexpru.same(landed, snap_children[2]))
        check("...and specifically NOT on the last atom - the reported symptom",
                not mexpru.same(landed, snap_children[#snap_children]))

        -- The root itself is a legitimate cursor position, and its path is the empty one.
        c.cursor_pos = vc.wref_mexpr(c.root)
        local root_path = mformula.cursor_path(c)
        check("the root's path is empty, not nil", root_path ~= nil and #root_path == 0,
                root_path and #root_path)
    end

    -- ------------------------------------------------------------------ nested, and unresolvable
    do
        local SZ = 12
        local c = mformula.new(fs, SZ)
        local e = char.find_by_ascii("x")
        local base = mexpru.mexpr_symbol(fs, {size = SZ, code = e.ncod}, true)
        mexpru.u(base).sz = SZ
        local sup_glyph = mexpru.mexpr_symbol(fs, {size = SZ - 2, code = e.ncod}, true)
        mexpru.u(sup_glyph).sz = SZ - 2
        local sup = mexpru.horiz(fs, {sup_glyph}, SZ - 2)
        local root = mexpru.horiz(fs, {mexpru.supsub(fs, base, sup, nil)}, SZ)
        mexpru.update_positions(root)
        mexpru.cut(c.root)
        c.root = root
        c.cursor_pos = vc.wref_mexpr(sup_glyph)     -- deep inside an exponent

        local path = mformula.cursor_path(c)
        check("a caret inside an exponent gets a multi-step path", path ~= nil and #path >= 2,
                path and #path)

        local snap = mformula.clone(c, fs)
        check("...which resolves against the clone", mformula.cursor_from_path(snap, path) == true)
        check("...landing somewhere real", snap.cursor_pos:get_obj() ~= nil)

        -- A path that cannot resolve must leave the cursor alone rather than guess.
        local before = snap.cursor_pos:get_obj()
        check("an over-long path is refused", mformula.cursor_from_path(snap, {1, 1, 1, 1, 1, 1}) == false)
        check("...and the cursor is left where it was", mexpru.same(snap.cursor_pos:get_obj(), before))
        check("a nil path is refused too", mformula.cursor_from_path(snap, nil) == false)
    end

    -- ------------------------------------------------------------------ the reported sequence
    --[[ The whole thing end to end, driving the two halves of one editing frame the way
    handle_input() does - which is the only part of it that can run without real keypresses.

    The sequence that produced the report: an edit leaves the caret at the end of the formula, the
    baseline is rebuilt on the next frame with the caret THERE, the user arrows back into the middle
    and types, and Ctrl+Z restores the tree but drops the caret back at the end. The baseline is
    deliberately NOT rebuilt when the caret moves (rebuilding it per frame is what made the editor
    lag), so the fix is to stamp the caret position captured at edit time onto it. ]]
    do
        local SZ = 12
        local state = editor.new()
        state._fontset = fs
        editor.from_text(state, "$$abcd$$", fs)
        local idx = formula_index(state)
        local formula = state.chars[idx].formula
        state.active_formula = formula

        local row = mexpru.u(formula.root).children
        check("setup: four atoms in the row", #row == 4, #row)

        -- Frame 1: the caret sits at the END, as it would right after typing "abcd".
        formula.cursor_pos = vc.wref_mexpr(row[#row])
        editor.begin_formula_edit(state)
        local cached = state._undo_baseline
        check("setup: a baseline got cached", cached ~= nil)

        -- Later frames: the caret is arrowed back into the MIDDLE. No edit, so the baseline is
        -- deliberately reused - which is exactly why its own caret is now stale.
        formula.cursor_pos = vc.wref_mexpr(row[2])
        local path = editor.begin_formula_edit(state)
        check("the baseline is REUSED across cursor movement, not rebuilt",
                state._undo_baseline == cached)
        check("...but the caret path captured this frame is the CURRENT one",
                path ~= nil and path[1] == 2, path and path[1])

        -- Now a real edit, and the commit that records it.
        formula.version = (formula.version or 0) + 1
        editor.commit_formula_edit(state, path)

        editor.undo(state)

        local restored = state.active_formula
        check("undo left a formula active", restored ~= nil)
        local restored_row = mexpru.u(restored.root).children
        local caret = restored.cursor_pos:get_obj()
        check("the caret came back where the edit STARTED",
                mexpru.same(caret, restored_row[2]))
        check("...and NOT at the end of the formula - the reported symptom",
                not mexpru.same(caret, restored_row[#restored_row]))
    end

    print("checks: " .. checks_run .. ", failed: " .. checks_failed)
    if checks_failed > 0 then
        return false
    end
    print("PASS: undo/redo keep the cursor inside the formula it was in")
    return true
end

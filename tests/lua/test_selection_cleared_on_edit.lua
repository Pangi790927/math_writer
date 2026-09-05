--[[
test_selection_cleared_on_edit.lua - any tree edit drops the selection with it.

Reported live, 2026-09-05: "sometimes space selects". An insert bumped the version but left
container.sel_anchor untouched, so the caret moved on to the newly typed glyph while the anchor
stayed put - and selection_range(), which is just "the span between anchor and cursor", started
reporting a range. A keystroke that should have cleared a selection conjured one out of nothing.

The fix routes every edit through mark_edited(), which bumps the version AND drops the anchor: a
selection is a pair of positions in a particular arrangement of the tree, so the moment that
arrangement changes it no longer describes anything the user picked. There were eight edit sites and
only three clears, which is exactly the sort of count that keeps drifting - hence one helper rather
than eight remembered clears.

mark_edited() is local (and handle_input() is keypress-driven), so this drives the exported mutators
that go through it and checks the anchor afterwards.
]]

package.path = package.path .. ";./scripts/?.lua"

local vc = require("virt_composer")
local char = require("char")
local mexpru = require("mexpru")
local mformula_new = require("mformula_new")

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

    -- "a b c" with a live selection over the last two slots.
    local function build_with_selection()
        local a, b, c = glyph(fs, "a", SZ), glyph(fs, "b", SZ), glyph(fs, "c", SZ)
        local root = mexpru.horiz(fs, {a, b, c}, SZ)
        mexpru.update_positions(root)
        local kids = mexpru.u(root).children
        local container = {
            root = root,
            cursor_pos = vc.wref_mexpr(kids[3]),
            sel_anchor = vc.wref_mexpr(kids[1]),
            version = 0,
        }
        return container, kids
    end

    do
        local container = build_with_selection()
        local horiz, lo, hi = mformula_new.selection_range(container)
        check("setup: a real selection exists to begin with", horiz ~= nil and lo == 1 and hi == 3)
    end

    -- Ctrl+Shift+=: wrapping the cursor's atom into a superscript is an edit, so the selection goes.
    do
        local container = build_with_selection()
        mformula_new.make_supsub(container, fs, "sup")
        check("make_supsub clears the selection", container.sel_anchor == nil)
        check("...and selection_range agrees there is none",
                mformula_new.selection_range(container) == nil)
        check("...while still registering as an edit", (container.version or 0) > 0)
    end

    -- Ctrl+/ likewise.
    do
        local container = build_with_selection()
        mformula_new.make_frac(container, fs, SZ)
        check("make_frac clears the selection", container.sel_anchor == nil)
        check("...and selection_range agrees there is none",
                mformula_new.selection_range(container) == nil)
        check("...while still registering as an edit", (container.version or 0) > 0)
    end

    -- An anchor that survives into a tree it no longer belongs to must not report a phantom
    -- selection either - selection_range() requires both ends to sit in the SAME horiz, which is
    -- also what keeps a selection from ever spanning a sup/sub boundary.
    do
        local container = build_with_selection()
        local sup = mexpru.horiz(fs, {glyph(fs, "n", SZ - 2)}, SZ - 2)
        local elsewhere = mexpru.supsub(fs, glyph(fs, "z", SZ), sup, nil)
        local other_root = mexpru.horiz(fs, {elsewhere}, SZ)
        mexpru.update_positions(other_root)
        container.cursor_pos = vc.wref_mexpr(mexpru.u(other_root).children[1])
        check("an anchor and cursor in different horizes report NO selection",
                mformula_new.selection_range(container) == nil)
    end

    print("checks: " .. checks_run .. ", failed: " .. checks_failed)
    if checks_failed > 0 then
        return false
    end
    print("PASS: an edit always drops the selection, and a split-across-rows anchor reports none")
    return true
end

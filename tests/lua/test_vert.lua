--[[
test_vert.lua - the "vert": N slots stacked vertically, each a horiz, no divider.

Requested 2026-09-05: "similar to the fraction it holds n slots, in each slot there will be a horiz,
ctrl+'+' and ctrl+'-' add this element and add or decrease it's element count, it starts with a
single element and refusez to decrease to fewer than one element, needs delete to disapear".

Built on mexpr_merge_v, which already existed and is what a frac's own stacking uses minus the line,
so no C++ was needed. The rules pinned here are the ones with a stated reason to be exactly what
they are - the one-slot floor especially, since letting Ctrl+- take the last slot would make the
whole stack vanish under a keystroke aimed at its contents, which is what "needs delete to disapear"
rules out.

make_vert()/shrink_vert() are exported (same testability reason make_supsub()/make_frac() are);
everything else is reached through them.
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

local SZ = 12

local function fresh(fs)
    local container = mformula_new.new(fs, SZ)
    return container
end

--[[ Finds the vert in the root row - by kind, not by index, since a stack made mid-formula sits
wherever the cursor was. On a BRAND-NEW formula it must be the row's only child; see the
"no blank to its left" check below for why that's worth stating. ]]
local function find_vert(container)
    for _, child in ipairs(mexpru.u(container.root).children) do
        if mexpru.u(child).kind == "vert" then
            return child
        end
    end
    return nil
end

local function slots_of(container)
    local node = find_vert(container)
    return node and mexpru.u(node).slots, node
end

function run_test()
    local fs = char.load_font_set()

    -- ------------------------------------------------------------------ creation & growth
    do
        local c = fresh(fs)
        mformula_new.make_vert(c, fs, SZ)
        local slots, node = slots_of(c)
        check("a fresh vert starts with exactly one slot", slots and #slots == 1, slots and #slots)
        check("it is tagged as a vert", mexpru.u(node).kind == "vert")
        check("the cursor lands inside the new slot", c.cursor_pos:get_obj() ~= nil)

        --[[ On a fresh formula the cursor sits on the empty placeholder atom, so the stack must
        REPLACE it, not land after it. make_vert()/make_frac() used to splice in unconditionally
        after the cursor's atom, which left that placeholder alive as an undeleteable blank column
        to the stack's left - reported live 2026-09-05, "see how for no reason the vecotr has an
        empty space to it's left, why?". Both now route through insert_compound_at_cursor(). ]]
        check("a stack made on a fresh formula leaves no placeholder beside it",
                #mexpru.u(c.root).children == 1, #mexpru.u(c.root).children)

        -- Ctrl+= again GROWS it rather than nesting another stack inside it.
        mformula_new.make_vert(c, fs, SZ)
        slots = slots_of(c)
        check("pressing it again grows the same stack to two slots", #slots == 2, #slots)
        local vert_count = 0
        for _, ch in ipairs(mexpru.u(c.root).children) do
            if mexpru.u(ch).kind == "vert" then vert_count = vert_count + 1 end
        end
        check("...and does not nest or add a second vert", vert_count == 1, vert_count)

        mformula_new.make_vert(c, fs, SZ)
        slots = slots_of(c)
        check("and again to three", #slots == 3, #slots)
    end

    -- ------------------------------------------------------------------ spawned from plain text
    --[[ Ctrl+= in TEXT mode builds a whole formula that is already a stack, the way Ctrl+/ does for
    a fraction - "make ctrl+ spawn the vector when in text mode same as the other containers"
    (2026-09-05), so a stack stops being the one container that needs a Ctrl+M first. Same shape
    make_vert() produces, reached without any container to splice into. ]]
    do
        local c = mformula_new.new_with_vert(fs, SZ)
        local slots, node = slots_of(c)
        check("a text-mode stack is born with one slot", slots and #slots == 1, slots and #slots)
        check("its root holds the stack and nothing else", #mexpru.u(c.root).children == 1,
                #mexpru.u(c.root).children)
        check("the cursor starts inside the stack's own first cell",
                mexpru.same(c.cursor_pos:get_obj():get_parent(), mexpru.u(node).slots[1]))
        -- ...and it grows from there exactly like one made inside a formula.
        mformula_new.make_vert(c, fs, SZ)
        check("pressing it again grows that same stack", #slots_of(c) == 2, #slots_of(c))
    end

    -- ------------------------------------------------------------------ the cell SIZE floor
    --[[ A cell never renders below the box it had while empty. Without this, a row's box is exactly
    its own ink, so a slot COLLAPSED the moment anything was typed into it - an empty slot is a full
    cursor line tall, a typed "x" only its own ~17px - and rows then packed together with no leading
    at all. Requested 2026-09-05: "the cell should stay the size that it started with, at least,
    similar to how paranthesis scale". Enforced by mexpr_merge_v's min_cell argument, which
    mexpru.vert() derives from sz (see its own comment for why it derives rather than takes it). ]]
    do
        local c = fresh(fs)
        mformula_new.make_vert(c, fs, SZ)
        -- With a single slot the stack's own box IS that one cell, so measuring the vert node
        -- measures the cell.
        local _, node = slots_of(c)
        local empty_bb = vc.mexpr_get_bb(node)
        local empty_h = empty_bb.br.y - empty_bb.tl.y

        -- Type into the slot, the same way test_latex_roundtrip's own type_char does.
        local target = c.cursor_pos:get_obj()
        local entry = char.find_by_ascii("x")
        local g = mexpru.mexpr_symbol(fs, {size = mexpru.physical_sz(SZ), code = entry.ncod}, true)
        mexpru.u(g).sz = SZ
        c.root = mexpru.propagate_rebuild(fs, target, g)
        c.cursor_pos = vc.wref_mexpr(g)

        local _, filled = slots_of(c)
        local filled_bb = vc.mexpr_get_bb(filled)
        local filled_h = filled_bb.br.y - filled_bb.tl.y
        check("a typed-into cell is no shorter than it was empty", filled_h >= empty_h - 0.01,
                string.format("%.2f < %.2f", filled_h, empty_h))
        check("...and no narrower either",
                filled_bb.br.x - filled_bb.tl.x >= empty_bb.br.x - empty_bb.tl.x - 0.01)
        -- A glyph's own ink really IS shorter than the empty cell - i.e. the check above is load
        -- bearing, not trivially true because the two happen to coincide.
        local gbb = vc.mexpr_get_bb(g)
        check("(the floor is doing real work - the glyph alone is shorter than the cell)",
                gbb.br.y - gbb.tl.y < empty_h, gbb.br.y - gbb.tl.y)
    end

    -- ------------------------------------------------------------------ the one-slot floor
    do
        local c = fresh(fs)
        mformula_new.make_vert(c, fs, SZ)
        mformula_new.make_vert(c, fs, SZ)
        check("two slots before shrinking", #slots_of(c) == 2)

        mformula_new.shrink_vert(c, fs)
        check("shrink drops one slot", #slots_of(c) == 1, #slots_of(c))

        local version_before = c.version
        mformula_new.shrink_vert(c, fs)
        check("shrinking the LAST slot is refused - a stack never empties itself",
                #slots_of(c) == 1, #slots_of(c))
        check("...and the refusal isn't recorded as an edit", c.version == version_before)
    end

    -- ------------------------------------------------------------------ vertical navigation
    do
        local c = fresh(fs)
        mformula_new.make_vert(c, fs, SZ)
        mformula_new.make_vert(c, fs, SZ)
        mformula_new.make_vert(c, fs, SZ)
        local slots, node = slots_of(c)
        check("three slots to walk", #slots == 3)

        -- Which slot the cursor is in, by identity of its enclosing horiz.
        local function cursor_slot()
            local n = c.cursor_pos:get_obj()
            local h = (mexpru.u(n).kind == "horiz") and n or n:get_parent()
            return mexpru.index_of(slots_of(c), h)
        end

        -- Growth left the cursor in the LAST slot it made (slot 3 of 3).
        check("cursor is in the slot just created", cursor_slot() == 3, cursor_slot())

        mformula_new.move_up(c)
        check("Up steps one slot toward the top", cursor_slot() == 2, cursor_slot())
        mformula_new.move_up(c)
        check("Up again reaches the top slot", cursor_slot() == 1, cursor_slot())

        mformula_new.move_down(c)
        check("Down steps back toward the bottom", cursor_slot() == 2, cursor_slot())

        -- Alt+Down leaves the stack entirely rather than stepping within it - "go down, just on the
        -- alternate if it exists". The alternate here is the vert node itself.
        mformula_new.move_down_reverse(c)
        check("Alt+Down exits onto the vert itself, not the slot below",
                mexpru.same(c.cursor_pos:get_obj(), node))

        -- ...and from ON the stack, Up/Down enter the topmost/bottommost slot, like a frac's
        -- num/den ("climb to the topmost or downard most element, in the same way as fractions").
        mformula_new.move_up(c)
        check("Up from the stack itself enters the TOPMOST slot", cursor_slot() == 1, cursor_slot())
        c.cursor_pos = vc.wref_mexpr(node)
        mformula_new.move_down(c)
        check("Down from the stack itself enters the BOTTOMMOST slot", cursor_slot() == 3, cursor_slot())
    end

    -- ------------------------------------------------------------------ contour cache
    --[[ draw() reads the contour geometry from a cache keyed on the tree, because rediscovering it
    every frame - recursing every node just to ask "is this a vert" - was the single biggest item in
    draw() (2.77ms of 4.46ms, measured 2026-09-05, against 0.43ms for the whole C++ path). The risk a
    cache introduces is staleness, and a stale one here draws boxes at positions the stack no longer
    occupies, so these checks are about invalidation, not about the numbers. ]]
    do
        local c = fresh(fs)
        mformula_new.make_vert(c, fs, SZ)
        local first = mformula_new.vert_contours(c)
        check("one stack yields one contour", #first == 1, #first)
        check("...with no internal boundary while it has a single cell", #first[1].edges == 0,
                #first[1].edges)

        -- Unchanged tree: the very same table back, i.e. genuinely cached rather than rebuilt.
        check("asking again without an edit returns the cached table",
                mformula_new.vert_contours(c) == first)

        local before_h = first[1].y1 - first[1].y0
        mformula_new.make_vert(c, fs, SZ)  -- grow to two cells: a real edit, new tree
        local second = mformula_new.vert_contours(c)
        check("after an edit the cache is rebuilt, not reused", second ~= first)
        check("the grown stack is taller than it was", second[1].y1 - second[1].y0 > before_h,
                string.format("%.2f vs %.2f", second[1].y1 - second[1].y0, before_h))
        check("...and now reports one internal cell boundary", #second[1].edges == 1,
                #second[1].edges)

        --[[ rescale() replaces the whole tree WITHOUT bumping version - it is a zoom, not an edit -
        so a cache keyed on version alone would hand back the old size here. This is the case that
        put tostring(root) in the key. ]]
        local before_w = second[1].x1 - second[1].x0
        mexpru.set_zoom(-3)
        mformula_new.rescale(c, fs)
        local zoomed = mformula_new.vert_contours(c)
        check("a zoom invalidates the cache even though version did not change",
                zoomed ~= second)
        check("...and the contour follows the new size",
                math.abs((zoomed[1].x1 - zoomed[1].x0) - before_w) > 0.01,
                string.format("%.2f vs %.2f", zoomed[1].x1 - zoomed[1].x0, before_w))
        mexpru.set_zoom(0)
    end

    -- ------------------------------------------------------------------ LaTeX round trip
    do
        local c = fresh(fs)
        mformula_new.make_vert(c, fs, SZ)
        mformula_new.make_vert(c, fs, SZ)
        -- put something identifiable in the bottom slot
        local entry = char.find_by_ascii("x")
        local g = mexpru.mexpr_symbol(fs, {size = SZ, code = entry.ncod}, true)
        mexpru.u(g).sz = SZ
        c.root = mexpru.propagate_rebuild(fs, c.cursor_pos:get_obj(), g)

        local latex = mformula_new.to_latex(c)
        check("a two-slot stack serialises as \\stack with one group each",
                latex == "\\stack{}{x}", latex)

        local back = mformula_new.from_latex(fs, SZ, latex)
        check("...and parses back to the same thing", mformula_new.to_latex(back) == latex,
                mformula_new.to_latex(back))
        local reslots = slots_of(back)
        check("the reloaded stack really is a vert with two slots",
                reslots ~= nil and #reslots == 2, reslots and #reslots)
    end

    print("checks: " .. checks_run .. ", failed: " .. checks_failed)
    if checks_failed > 0 then
        return false
    end
    print("PASS: vert - creation, growth, the one-slot floor, vertical walking, and round trip")
    return true
end

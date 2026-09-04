--[[
test_frac.lua - mformula_new's fraction support (2026-09-04 design discussion): creation
(new_with_frac/make_frac via Ctrl+/), navigation (Left/Right treat a frac as one opaque atom,
Up/Down enter/jump between num and den, climbing out through nested fracs and supsub ancestors the
same way sup/sub already does), hit_test, and LaTeX round-trip.
]]

package.path = package.path .. ";./scripts/?.lua"

local vc = require("virt_composer")
local char = require("char")
local mexpru = require("mexpru")
local mformula_new = require("mformula_new")
local mformula_latex = require("mformula_latex")
local same = mexpru.same

local checks_run, checks_failed = 0, 0
local function check(name, cond)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name)
    end
end

local function at(container, node, name)
    check(name, same(container.cursor_pos:get_obj(), node))
end

function run_test()
    local fs = char.load_font_set()
    local SZ = 10

    -- ============================================================
    -- Part 1: new_with_frac() - fresh container, cursor in numerator.
    -- ============================================================
    do
        local c = mformula_new.new_with_frac(fs, SZ)
        local frac = mexpru.u(c.root).children[1]
        check("root's only child is a frac", mexpru.u(frac).kind == "frac")
        local u = mexpru.u(frac)
        check("num is a horiz", mexpru.u(u.num).kind == "horiz")
        check("den is a horiz", mexpru.u(u.den).kind == "horiz")
        at(c, mexpru.u(u.num).children[1], "cursor starts in numerator's own empty atom")
    end

    -- ============================================================
    -- Part 2: LaTeX round-trip.
    -- ============================================================
    do
        local c = mformula_latex.from_latex(fs, SZ, "a+\\frac{b}{c}+d")
        local latex = mformula_latex.to_latex(c)
        check("round-trips exactly ('" .. latex .. "')", latex == "a+\\frac{b}{c}+d")

        local empty_latex = mformula_latex.to_latex(mformula_latex.from_latex(fs, SZ, "\\frac{}{}"))
        check("empty frac round-trips as \\frac{}{} ('" .. empty_latex .. "')", empty_latex == "\\frac{}{}")
    end

    -- ============================================================
    -- Part 3: Left/Right treat a frac as one opaque atom (mirrors test_hit_test.lua's Part 3 for
    -- supsub) - never dives into num/den.
    -- ============================================================
    do
        local c = mformula_latex.from_latex(fs, SZ, "x+\\frac{a}{b}+y")
        local root_children = mexpru.u(c.root).children
        local x, frac, y = root_children[1], root_children[3], root_children[5]
        check("middle child is the frac", mexpru.u(frac).kind == "frac")

        c.cursor_pos = vc.wref_mexpr(x)
        mformula_new.move_right(c) -- x -> "+"
        mformula_new.move_right(c) -- "+" -> frac itself (lands ON it, not inside num/den)
        at(c, frac, "Right from '+' lands on the frac itself, not inside num/den")

        mformula_new.move_right(c) -- frac -> "+"
        local plus2 = root_children[4]
        at(c, plus2, "Right from the frac exits to the next sibling")

        c.cursor_pos = vc.wref_mexpr(y)
        mformula_new.move_left(c) -- y -> "+"
        mformula_new.move_left(c) -- "+" -> frac itself
        at(c, frac, "Left from '+' (after the frac) lands on the frac itself")
    end

    -- ============================================================
    -- Part 3b: Left pressed from INSIDE num/den (position 0, reached only via Up/Down, never
    -- directly by Left/Right) - regression for a real live crash (2026-09-04): exit_horiz_leftward()
    -- unconditionally read a supsub's .base off the horiz's own parent, which is nil for a frac (num/
    -- den's parent) - silently building a wref to nil, a permanently dangling cursor_pos. The whole
    -- frac reads as one opaque atom for this exit, same as Left/Right from outside it already do.
    -- ============================================================
    do
        local c = mformula_latex.from_latex(fs, SZ, "x+\\frac{a}{b}+y")
        local root_children = mexpru.u(c.root).children
        local frac = root_children[3]
        local plus1 = root_children[2]
        local a_glyph = mexpru.u(mexpru.u(frac).num).children[1]

        c.cursor_pos = vc.wref_mexpr(frac)
        mformula_new.move_up(c)
        at(c, a_glyph, "setup: Up from the frac enters numerator, landing on 'a'")

        mformula_new.move_left(c)
        local num_horiz = mexpru.u(frac).num
        at(c, num_horiz, "Left from 'a' (num's only child) lands on num's own position 0")

        mformula_new.move_left(c)
        check("cursor_pos survived a further Left out of num entirely (not dangling)",
                c.cursor_pos:get_obj() ~= nil)
        at(c, plus1, "a further Left from num's position 0 exits the whole frac, landing on the preceding '+'")
    end

    -- ============================================================
    -- Part 4: Up/Down enter num/den from resting on the frac itself, and jump directly between
    -- them (no base to route through, unlike supsub).
    -- ============================================================
    do
        local c = mformula_latex.from_latex(fs, SZ, "\\frac{a}{b}")
        local frac = mexpru.u(c.root).children[1]
        local u = mexpru.u(frac)
        local a_glyph = mexpru.u(u.num).children[1]
        local b_glyph = mexpru.u(u.den).children[1]

        c.cursor_pos = vc.wref_mexpr(frac)
        mformula_new.move_up(c)
        at(c, a_glyph, "Up from the frac itself enters numerator (at its end)")

        mformula_new.move_down(c)
        -- Lands at DENOMINATOR'S OWN START (position 0, "before b"), not on b_glyph itself - same
        -- enter_at_start() semantics already used for sup/sub's own left-approach entry (only
        -- collapses onto the child directly when that child is an empty atom).
        at(c, u.den, "Down from numerator jumps directly to denominator (its own start)")

        mformula_new.move_up(c)
        at(c, u.num, "Up from denominator jumps directly back to numerator (its own start)")

        c.cursor_pos = vc.wref_mexpr(frac)
        mformula_new.move_down(c)
        at(c, b_glyph, "Down from the frac itself enters denominator (at its end)")
    end

    -- ============================================================
    -- Part 5: Up/Down with no local meaning propagates outward through the container that "was
    -- having" the frac, per the 2026-09-04 design discussion - not a no-op, and not a blind climb
    -- that only recognizes supsub ancestors.
    -- ============================================================
    do
        -- (a/b)/c - inner frac sits in the OUTER's own NUMERATOR. Down from "b" (inner den, the
        -- LOWER register of something that's itself in the outer's UPPER register) escapes to the
        -- outer's own den "c" - mirrors supsub's exact "chain of subs nested inside a sup climbs to
        -- that sup's own bifurcation" behavior. Up from "a" (inner num) has nothing further up at
        -- all here - "a" is already at the very TOP of the whole expression (nested inside the
        -- outer's OWN numerator, not its denominator) - a true no-op, same as pressing Up while
        -- already at the top of a plain (non-nested) supsub chain would be.
        local c = mformula_latex.from_latex(fs, SZ, "\\frac{\\frac{a}{b}}{c}")
        local outer = mexpru.u(c.root).children[1]
        local ou = mexpru.u(outer)
        local inner = mexpru.u(ou.num).children[1]
        local iu = mexpru.u(inner)
        local b_glyph = mexpru.u(iu.den).children[1]
        local a_glyph = mexpru.u(iu.num).children[1]

        -- Lands at the outer den's OWN START (enter_at_start(), same as the direct num->den jump
        -- in Part 4 above), not on c_glyph itself.
        c.cursor_pos = vc.wref_mexpr(b_glyph)
        mformula_new.move_down(c)
        at(c, ou.den, "(a/b)/c: Down from inner den 'b' reaches outer den 'c' (its own start)")

        c.cursor_pos = vc.wref_mexpr(a_glyph)
        mformula_new.move_up(c)
        at(c, a_glyph, "(a/b)/c: Up from inner num 'a' has nothing further up - true no-op")

        -- Structurally-symmetric mirror: c/(a/b) - inner frac now in the outer's DENOMINATOR. Up
        -- from "a" (inner num, upper register of something in the outer's LOWER register) escapes
        -- to the outer's own num "c"; Down from "b" (inner den) has nothing further down.
        local c2 = mformula_latex.from_latex(fs, SZ, "\\frac{c}{\\frac{a}{b}}")
        local outer2 = mexpru.u(c2.root).children[1]
        local ou2 = mexpru.u(outer2)
        local inner2 = mexpru.u(ou2.den).children[1]
        local iu2 = mexpru.u(inner2)
        local a2_glyph = mexpru.u(iu2.num).children[1]
        local b2_glyph = mexpru.u(iu2.den).children[1]

        c2.cursor_pos = vc.wref_mexpr(a2_glyph)
        mformula_new.move_up(c2)
        at(c2, ou2.num, "c/(a/b): Up from inner num 'a' reaches outer num 'c' (its own start)")

        c2.cursor_pos = vc.wref_mexpr(b2_glyph)
        mformula_new.move_down(c2)
        at(c2, b2_glyph, "c/(a/b): Down from inner den 'b' has nothing further down - true no-op")

        -- e^(a/b): Down from "b" should reach the supsub's own base "e" - a frac nested inside a
        -- supsub's sup still escapes toward that supsub's base, same as a plain glyph there would.
        local c2 = mformula_latex.from_latex(fs, SZ, "e^{\\frac{a}{b}}")
        local S = mexpru.u(c2.root).children[1]
        local su = mexpru.u(S)
        local frac2 = mexpru.u(su.sup).children[1]
        local b2_glyph = mexpru.u(mexpru.u(frac2).den).children[1]
        c2.cursor_pos = vc.wref_mexpr(b2_glyph)
        mformula_new.move_down(c2)
        at(c2, su.base, "e^(a/b): Down from 'b' (inside sup's own frac) reaches base 'e'")

        -- A bare fraction with no supsub/frac ancestor at all - Down from den truly stays put.
        local c3 = mformula_latex.from_latex(fs, SZ, "\\frac{a}{b}")
        local frac3 = mexpru.u(c3.root).children[1]
        local b3_glyph = mexpru.u(mexpru.u(frac3).den).children[1]
        c3.cursor_pos = vc.wref_mexpr(b3_glyph)
        mformula_new.move_down(c3)
        at(c3, b3_glyph, "Down from a bare fraction's own den with no ancestor at all stays put")
    end

    -- ============================================================
    -- Part 6: hit_test - num/den boxes descend normally; empty space near the divider splits by
    -- the frac's own horizontal midpoint (no base, no 3-way split the way supsub has).
    -- ============================================================
    do
        local function raw_box(node)
            local pos = mexpru.u(node).pos
            local bb = vc.mexpr_get_bb(node)
            return {left = pos.x + bb.tl.x, right = pos.x + bb.br.x, top = pos.y + bb.tl.y, bottom = pos.y + bb.br.y}
        end
        local a = char.find_by_ascii("a")
        local a_sz = fs:char_get_sz({size = SZ, code = a.ncod})
        local bc = (a_sz.tr.y + a_sz.bl.y) / 2
        local function hit(c, click)
            mformula_new.hit_test(c, fs, SZ, {x = click.x, y = click.y + bc})
        end

        local c = mformula_latex.from_latex(fs, SZ, "\\frac{a}{b}")
        local frac = mexpru.u(c.root).children[1]
        local u = mexpru.u(frac)
        local a_glyph = mexpru.u(u.num).children[1]
        local b_glyph = mexpru.u(u.den).children[1]

        local abox = raw_box(a_glyph)
        c.cursor_pos = vc.wref_mexpr(c.root)
        hit(c, {x = (abox.left + abox.right) / 2, y = (abox.top + abox.bottom) / 2})
        at(c, a_glyph, "click on 'a' itself lands inside the numerator")

        local bbox = raw_box(b_glyph)
        c.cursor_pos = vc.wref_mexpr(c.root)
        hit(c, {x = (bbox.left + bbox.right) / 2, y = (bbox.top + bbox.bottom) / 2})
        at(c, b_glyph, "click on 'b' itself lands inside the denominator")

        local fbox = raw_box(frac)
        c.cursor_pos = vc.wref_mexpr(c.root)
        hit(c, {x = fbox.left + 0.1, y = (fbox.top + fbox.bottom) / 2})
        at(c, c.root, "click near the frac's own left edge (empty space) -> before it (root)")

        c.cursor_pos = vc.wref_mexpr(c.root)
        hit(c, {x = fbox.right - 0.1, y = (fbox.top + fbox.bottom) / 2})
        at(c, frac, "click near the frac's own right edge (empty space) -> the frac itself")
    end

    print("checks: " .. checks_run .. ", failed: " .. checks_failed)
    if checks_failed > 0 then
        return false
    end
    print("PASS: fraction creation, navigation, hit_test and LaTeX round-trip all check out")
    return true
end

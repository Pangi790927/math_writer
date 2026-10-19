--[[ @file tests/lua/test_term_selectors.lua
-- | @brief Checks where the term selectors sit: which sums get them, which slots each term's
-- |        selector covers, the level of each line, the rows of a wrapped formula, and the gap a
-- |        drop finds.
-- |
-- | THE SKETCH IS THE SPEC (the author, 19-10-2026): under (abc+ab^2)d+ac+2\pi, abc and ab^2 sit
-- | on the line nearest the glyphs and (abc+ab^2)d, ac and 2\pi on the line below; a term's
-- | underline covers its body - no sign, its own brackets in - and its ring starts it. A wrapped
-- | term gets one underline per row ("make the selectors wrap too"), each leaf on the row C++
-- | draws it on, which the caret's own wrap mirror (mformula_new.cursor_rect) cross-checks here.
-- |
-- | NOTHING IS DRAWN: layout and drop_at are pure geometry, so this file needs no ImGui stub. The
-- | drawing and the input routing are test_term_selectors_drag.lua's.
-- |
-- | @date 19-10-2026-20:52
--]]

package.path = package.path .. ";./scripts/?.lua"

local char = require("char")
local vc = require("virt_composer")
local mexpru = require("mexpru")
local mexpr_ast = require("mexpr_ast")
local mformula = require("mformula_new")
local mformula_latex = require("mformula_latex")
local term_selectors = require("term_selectors")

local SZ = mexpru.DEFAULT_SIZE

--[[ Gives no declarations, as layout asks for them: nothing here declares a name.
@date 19-10-2026-21:18 ]]
local NO_DECLS = function() return {} end

local checks_run, checks_failed = 0, 0
local function check(name, cond, got)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name .. (got ~= nil and ("  (got: " .. tostring(got) .. ")") or ""))
    end
end

local function near(a, b)
    return math.abs(a - b) < 0.01
end

--[[ @brief Lays a formula out at the origin {0, 0}, so a record's frame is the drawn frame itself,
-- |        with `decls` in scope, or none when it is nil. @date 19-10-2026-22:23
--]]
local function laid_out(fs, latex, wrap_width, decls)
    local c = mformula_latex.from_latex(fs, SZ, latex)
    local decls_of = decls and function() return decls end or NO_DECLS
    return c, term_selectors.layout(fs, c, SZ, wrap_width, decls_of, 0, 0)
end

--[[ @brief Gives the unwrapped box of slot k of the root row, for comparing a selector with the
-- |        glyphs it should cover. @date 19-10-2026-21:02
--]]
local function slot_box(fs, c, k)
    return mformula.node_bbox(fs, mexpru.u(c.root).children[k])
end

--[[ @brief Finds the sum with `n` terms whose first selector starts nearest to x = `x0`.
-- |        @date 19-10-2026-20:52
--]]
local function sum_of(geom, n, x0)
    local best, best_d
    for _, sum in ipairs(geom.sums) do
        local d = math.abs(sum.terms[1].segments[1].x0 - x0)
        if #sum.terms == n and (not best_d or d < best_d) then
            best, best_d = sum, d
        end
    end
    return best
end

-- ------------------------------------------------------------------ the sketch
local function the_sketch(fs)
    --[[ The root row's slots are 1 `(`, 2-4 abc, 5 `+`, 6 a, 7 b^2, 8 `)`, 9 d, 10 `+`, 11 a,
    12 c, 13 `+`, 14 2 and 15 \pi. @date 19-10-2026-21:02 ]]
    local c, rec = laid_out(fs, "(abc+ab^{2})d+ac+2\\pi", nil)
    check("the sketch has selectors", rec ~= nil)
    if not rec then
        return
    end
    local g = rec.geom
    check("two sums get selectors", #g.sums == 2, #g.sums)
    local inner, outer = sum_of(g, 2, 0), sum_of(g, 3, 0)
    check("the inner sum has two terms and the outer three", inner ~= nil and outer ~= nil)
    if not (inner and outer) then
        return
    end

    local box = function(k) return slot_box(fs, c, k) end
    local t1, t2, t3 = outer.terms[1], outer.terms[2], outer.terms[3]
    local seg = function(t) return t.segments[1] end
    check("(abc+ab^2)d starts at its own `(`", near(seg(t1).x0, box(1).left), seg(t1).x0)
    check("...and ends at the d, the `)` inside", near(seg(t1).x1, box(9).right), seg(t1).x1)
    check("ac's body leaves its + out", near(seg(t2).x0, box(11).left), seg(t2).x0)
    check("...and ends at c", near(seg(t2).x1, box(12).right), seg(t2).x1)
    check("2\\pi's body starts at the 2", near(seg(t3).x0, box(14).left), seg(t3).x0)
    check("...and ends at \\pi", near(seg(t3).x1, box(15).right), seg(t3).x1)
    local a1, a2 = inner.terms[1], inner.terms[2]
    check("abc does not take the sum's own `(`", near(seg(a1).x0, box(2).left), seg(a1).x0)
    check("...and ends at c", near(seg(a1).x1, box(4).right), seg(a1).x1)
    check("ab^2 leaves its + out", near(seg(a2).x0, box(6).left), seg(a2).x0)
    check("...and the `)` too, ending at the power", near(seg(a2).x1, box(7).right),
            seg(a2).x1)

    for _, t in ipairs({t1, t2, t3, a1, a2}) do
        check("one segment each, unwrapped", #t.segments == 1, #t.segments)
        check("the ring starts the body", near(t.ring.x - 2.5, seg(t).x0)
                and near(t.ring.y, seg(t).y))
    end
    check("the outer terms share one line", seg(t1).y == seg(t2).y and seg(t2).y == seg(t3).y)
    check("the inner terms share one line", seg(a1).y == seg(a2).y)
    check("the inner line is nearer the glyphs", seg(a1).y < seg(t1).y,
            seg(a1).y .. " / " .. seg(t1).y)
    check("both lie below the formula's ink", seg(a1).y > g.rows_bottom, seg(a1).y)
    check("the box grows to hold them", g.bottom > g.rows_bottom, g.bottom)
    check("selectors name the sum's own terms in order", t1.index == 1 and t3.index == 3
            and t1.add == outer.add and a2.add == inner.add)
end

-- ------------------------------------------------------------------ deeper, equations, exclusions
local function nesting_and_rows(fs)
    local _, rec = laid_out(fs, "a+(b+(c+d))e", nil)
    check("three nested sums get selectors", rec ~= nil and #rec.geom.sums == 3,
            rec and #rec.geom.sums)
    if rec then
        local ys = {}
        for _, sum in ipairs(rec.geom.sums) do
            ys[#ys + 1] = sum.terms[1].segments[1].y
        end
        table.sort(ys)
        check("each depth has a line of its own", ys[1] < ys[2] and ys[2] < ys[3])
        local deepest = sum_of(rec.geom, 2, 111)
        local outermost = sum_of(rec.geom, 2, 0)
        check("the innermost sum is nearest the glyphs",
                deepest.terms[1].segments[1].y == ys[1], deepest.terms[1].segments[1].y)
        check("...and the outermost lowest", outermost.terms[1].segments[1].y == ys[3])
    end

    local _, eq = laid_out(fs, "a+b=c+d", nil)
    check("both sides of an equation get selectors", eq ~= nil and #eq.geom.sums == 2)
    if eq then
        local l, r = eq.geom.sums[1].terms[1], eq.geom.sums[2].terms[1]
        check("...level, one line for the one depth", l.segments[1].y == r.segments[1].y)
    end

    local _, pow = laid_out(fs, "x^{a+b}+c", nil)
    check("a sum in an exponent gets none", pow ~= nil and #pow.geom.sums == 1
            and #pow.geom.sums[1].terms == 2)
    local _, frac = laid_out(fs, "\\frac{a+b}{c}+d", nil)
    check("a sum in a fraction gets none", frac ~= nil and #frac.geom.sums == 1)
    local _, none = laid_out(fs, "abc", nil)
    check("a formula with no sum has no record", none == nil)
end

local function folded_and_bracketed(fs)
    --[[ `+1` is a folded unit: the parse tags only its sign with the numeral it keeps, and the
    digit with the one it replaced. The digit is still the body. @date 19-10-2026-20:52 ]]
    local c, rec = laid_out(fs, "x+1", nil)
    local t = rec and rec.geom.sums[1].terms[2]
    check("a folded +1's body is its digit", t ~= nil and near(t.segments[1].x0,
            slot_box(fs, c, 3).left) and near(t.segments[1].x1, slot_box(fs, c, 3).right))

    local c2, rec2 = laid_out(fs, "(a+b)+c", nil)
    local outer = rec2 and sum_of(rec2.geom, 2, 0)
    local first = outer and outer.terms[1].segments[1]
    check("a bracketed first term takes both its brackets", first ~= nil
            and near(first.x0, slot_box(fs, c2, 1).left)
            and near(first.x1, slot_box(fs, c2, 5).right))

    local c3, rec3 = laid_out(fs, "\\int x \\,d x+1", nil)
    local int = rec3 and rec3.geom.sums[1].terms[1].segments[1]
    check("an integral's sign joins its term", int ~= nil
            and near(int.x0, slot_box(fs, c3, 1).left))
end

-- ------------------------------------------------------------------ wrapping
--[[ @brief Checks a wrapped formula's segments against the caret's wrap mirror, row by row.
-- |
-- | THE CARET AFTER A GLYPH STANDS AT ITS RIGHT EDGE, which is also what decides the glyph's row
-- | in C++, so mformula_new.cursor_rect's `row` for a caret after each plain glyph of a body is
-- | that glyph's row. Its selector must have a segment on that row covering the glyph.
-- |
-- | @date 19-10-2026-20:52
--]]
local function wrapped(fs)
    local W = 120
    local c, rec = laid_out(fs, "(abc+ab^{2})d+ac+2\\pi", W)
    check("the wrapped sketch has selectors", rec ~= nil)
    if not rec then
        return
    end
    --[[ THE ROWS ARE COMPARED, NOT THE BOTTOMS: measure floors a formula's extent at an empty
    slot's, which does not move the rows under it. @date 19-10-2026-21:02 ]]
    local g = rec.geom
    local wrapped_m, flat_m = mformula.measure(c, fs, SZ, W), mformula.measure(c, fs, SZ, nil)
    local measured_rows = (wrapped_m.bottom - flat_m.bottom) / g.row_h + 1
    local rows = (g.rows_bottom - g.top) / g.row_h
    check("the selectors' rows are measure's rows", near(rows, measured_rows) and near(rows, 3),
            rows .. " / " .. measured_rows)

    local kids = mexpru.u(c.root).children
    local saved, glyphs, astray = c.cursor_pos, 0, nil
    for _, sel in ipairs(g.selectors) do
        for k = sel.body.lo, sel.body.hi do
            local slot = kids[k]
            if slot:anchor_len() == 0 and slot.type == vc.MEXPR_TYPE_SYMBOL then
                c.cursor_pos = vc.wref_mexpr(slot)
                local row = mformula.cursor_rect(c, {x = 0, y = 0}, fs, W).row
                local bb = slot_box(fs, c, k)
                local covered = false
                for _, seg in ipairs(sel.segments) do
                    covered = covered or (seg.row == row and seg.x0 <= bb.left - row * W + 0.01
                            and seg.x1 >= bb.right - row * W - 0.01)
                end
                glyphs = glyphs + 1
                astray = astray or (not covered and k) or nil
            end
        end
    end
    c.cursor_pos = saved
    check("every plain glyph of a body is covered on its caret's row", glyphs > 10
            and astray == nil, "slot " .. tostring(astray) .. " of " .. glyphs)

    local outer, inner = sum_of(g, 3, 0), sum_of(g, 2, 7)
    local power = inner and inner.terms[2]
    check("ab^2 crosses the break: two segments", power ~= nil and #power.segments == 2,
            power and #power.segments)
    if power and #power.segments == 2 then
        c.cursor_pos = vc.wref_mexpr(kids[7])
        local row = mformula.cursor_rect(c, {x = 0, y = 0}, fs, W).row
        c.cursor_pos = saved
        check("...the power on the row its caret wraps to", power.segments[2].row == row, row)
        check("...the ring on the first", near(power.ring.y, power.segments[1].y)
                and power.segments[1].row == 0)
        check("...each row's line under its own row",
                power.segments[2].y - power.segments[1].y == g.row_h)
    end
    local pi = outer and outer.terms[3]
    check("2\\pi lands whole on the last row", pi ~= nil and #pi.segments == 1
            and pi.segments[1].row == 2, pi and pi.segments[1].row)
end

-- ------------------------------------------------------------------ pointing and dropping
local function pointing(fs)
    local _, rec = laid_out(fs, "(abc+ab^{2})d+ac+2\\pi", nil)
    if not rec then
        return
    end
    local outer, inner = sum_of(rec.geom, 3, 0), sum_of(rec.geom, 2, 7)
    local pi, abc = outer.terms[3], inner.terms[1]
    check("a press on a ring finds its selector",
            term_selectors.selector_at(rec, {x = pi.ring.x, y = pi.ring.y}) == pi)
    local line = abc.segments[1]
    check("a press on a line finds its selector", term_selectors.selector_at(rec,
            {x = (line.x0 + line.x1) / 2, y = line.y + 2}) == abc)
    check("between two levels' lines finds none", term_selectors.selector_at(rec,
            {x = (line.x0 + line.x1) / 2, y = line.y + 4}) == nil)
    check("over the glyphs finds none", term_selectors.selector_at(rec,
            {x = pi.ring.x, y = 0}) == nil)
end

--[[ @brief Drops `t` at a point and gives what drop_at finds there. @date 19-10-2026-21:02
--]]
local function dropped(fs, rec, t, x, y)
    return term_selectors.drop_at(rec, fs, t.add, t.term, {x = x, y = y})
end

local function dropping(fs)
    local _, rec = laid_out(fs, "(abc+ab^{2})d+ac+2\\pi", nil)
    if not rec then
        return
    end
    local outer, inner = sum_of(rec.geom, 3, 0), sum_of(rec.geom, 2, 7)
    local t1, t2, pi = outer.terms[1], outer.terms[2], outer.terms[3]
    local y = pi.ring.y

    local d = dropped(fs, rec, pi, -2, y)
    check("2\\pi dropped before the first term", d ~= nil and d.gap == 0 and d.option ~= nil)
    if d and d.option then
        check("...is the reorder option", d.option.id == "reorder")
        check("...moving 2\\pi in front of (abc+ab^2)d", d.option.params.term == pi.term
                and d.option.params.before == t1.term)
    end
    d = dropped(fs, rec, pi, (t1.tail.x + t2.head.x) / 2, 0)
    check("...between the first two, on the glyphs' own row", d ~= nil and d.gap == 1
            and d.option and d.option.params.before == t2.term)
    d = dropped(fs, rec, pi, pi.mid, y)
    check("2\\pi dropped on itself changes nothing", d ~= nil and d.option == nil)
    d = dropped(fs, rec, t2, pi.segments[1].x1 + 4, y)
    check("ac dropped at the end lands last", d ~= nil and d.gap == 3 and d.option
            and d.option.params.before == outer.add)
    local none, why = dropped(fs, rec, pi, pi.mid, y + 200)
    check("a drop far below the formula finds no gap", none == nil, why)
    check("...and says so", tostring(why):find("outside the formula", 1, true) ~= nil, why)

    local abc, power = inner.terms[1], inner.terms[2]
    d = dropped(fs, rec, power, abc.segments[1].x0 + 1, 0)
    check("ab^2 dropped before abc", d ~= nil and d.gap == 0 and d.option
            and d.option.params.before == abc.term)
    none, why = dropped(fs, rec, power, t1.segments[1].x1 - 2, 0)
    check("ab^2 dropped on the d is outside its sum", none == nil
            and tostring(why):find("own sum", 1, true) ~= nil, why)

    local _, eq = laid_out(fs, "a+b=c+d", nil)
    local b, dd = eq.geom.sums[1].terms[2], eq.geom.sums[2].terms[2]
    none, why = dropped(fs, eq, b, dd.mid, 0)
    check("a drop across = is refused", none == nil
            and tostring(why):find("own sum", 1, true) ~= nil, why)
end

local function wrapped_drop(fs)
    local _, rec = laid_out(fs, "(abc+ab^{2})d+ac+2\\pi", 120)
    if not rec then
        return
    end
    local outer = sum_of(rec.geom, 3, 0)
    local pi = outer.terms[3]
    local d = dropped(fs, rec, pi, 1, rec.geom.top + 2)
    check("on a wrapped formula, the first row's start is gap 0", d ~= nil and d.gap == 0
            and d.option ~= nil)
    local row1 = rec.geom.top + rec.geom.row_h * 1.5
    d = dropped(fs, rec, pi, outer.terms[2].head.x - 1, row1)
    check("...and the second row's gap before ac is gap 1", d ~= nil and d.gap == 1)
end

--[[ @brief Checks that a release along a wrapped row's selector lines lands on that row.
-- |
-- | THOSE LINES SIT INSIDE THE NEXT ROW'S BAND, since rows touch, and the click's conversion
-- | reads a point there as on the next row: before 19-10-2026 such a release found the gaps of
-- | the row below.
-- |
-- | @date 19-10-2026-22:23
--]]
local function wrapped_lines(fs)
    local _, eq = laid_out(fs, "a+b=c+d", 80)
    local a, b = eq and eq.geom.sums[1].terms[1], eq and eq.geom.sums[1].terms[2]
    check("at W=80, b's ring sits under the first row, in the second row's band", b ~= nil
            and b.segments[1].row == 0 and b.ring.y > eq.geom.top + eq.geom.row_h,
            b and b.ring.y)
    if b then
        local d = dropped(fs, eq, b, a.segments[1].x0 - 2, b.ring.y)
        check("...b dragged along its line in front of a lands at gap 0", d ~= nil and d.gap == 0
                and d.option ~= nil and d.option.params.before == a.term, d and d.gap)
    end

    local _, rec = laid_out(fs, "(abc+ab^{2})d+ac+2\\pi", 120)
    local outer = rec and sum_of(rec.geom, 3, 0)
    if outer then
        local t1, pi = outer.terms[1], outer.terms[3]
        local d = dropped(fs, rec, pi, t1.ring.x, t1.ring.y)
        check("the wrapped sketch's 2\\pi dropped on the first ring lands at gap 0", d ~= nil
                and d.gap == 0 and d.option ~= nil and d.option.params.before == t1.term,
                d and d.gap)
    end
end

-- ------------------------------------------------------------------ untagged glyphs
--[[ @brief Declares the name a formula spells, in the shape a definition box hands over.
-- |        @date 19-10-2026-22:23
--]]
local function declared(fs, latex)
    local pat = mexpr_ast.parse_name(fs, mformula_latex.from_latex(fs, SZ, latex))
    return mexpr_ast.new_decl{text = pat.text, name = pat.name, arity = pat.arity,
            tokens = pat.tokens, groups = pat.groups}
end

--[[ @brief Gives the slots a selector's underline covers as "lo..hi", nil for no selector.
-- |        @date 19-10-2026-22:23
--]]
local function body(t)
    return t and (t.body.lo .. ".." .. t.body.hi)
end

--[[ @brief Checks that the glyphs the parse reads into a term without tagging them join that
-- |        term, and that a comma or a sign never does.
-- |
-- | THE PARSE TAGS NO OPERATOR NAME, \infty, PRIME OF A DECLARED NAME OR QUOTED NAME, and before
-- | 19-10-2026 such a glyph belonged to no term: \sin(x)'s underline left its \sin out, and
-- | \infty+1 got no selectors at all.
-- |
-- | @date 19-10-2026-22:23
--]]
local function untagged_glyphs(fs)
    --[[ The root row's slots are 1 \sin, 2-4 (x), 5 `+`, 6 \cos and 7-9 (x).
    @date 19-10-2026-22:23 ]]
    local c, rec = laid_out(fs, "\\sin(x)+\\cos(x)", nil)
    local s = rec and rec.geom.sums[1]
    check("\\sin(x)'s underline takes in its name", s and body(s.terms[1]) == "1..4",
            s and body(s.terms[1]))
    check("...and \\cos(x)'s too", s and body(s.terms[2]) == "6..9", s and body(s.terms[2]))
    if s then
        local sin = slot_box(fs, c, 1)
        check("...the gap-0 marker stands before \\sin", s.marks[1].x < sin.left + 2, s.marks[1].x)
        local d = dropped(fs, rec, s.terms[2], sin.left + 2, 0)
        check("...and \\cos(x) dropped on \\sin lands in front", d ~= nil and d.gap == 0
                and d.option ~= nil, d and d.gap)
    end

    local _, inf = laid_out(fs, "x-\\infty", nil)
    local t = inf and inf.geom.sums[1].terms[2]
    check("x-\\infty's second term underlines its \\infty", body(t) == "3..3", body(t))
    local _, lead = laid_out(fs, "\\infty+1", nil)
    t = lead and lead.geom.sums[1].terms[1]
    check("\\infty+1 gets selectors, \\infty its first term", body(t) == "1..1", body(t))

    local cp, prime = laid_out(fs, "x+y'", nil, {declared(fs, "y'")})
    t = prime and prime.geom.sums[1].terms[2]
    check("with y' declared, x+y' underlines the prime", body(t) == "3..4", body(t))
    if t then
        local d = dropped(fs, prime, prime.geom.sums[1].terms[1], slot_box(fs, cp, 4).right + 3, 0)
        check("...and x dropped past the prime lands last", d ~= nil and d.gap == 2, d and d.gap)
    end
    local quoted = {declared(fs, "'ab'")}
    local _, q1 = laid_out(fs, "x+'ab'", nil, quoted)
    t = q1 and q1.geom.sums[1].terms[2]
    check("with 'ab' declared, x+'ab' underlines the whole name", body(t) == "3..6", body(t))
    local _, q2 = laid_out(fs, "'ab'+x", nil, quoted)
    t = q2 and q2.geom.sums[1].terms[1]
    check("...and 'ab'+x gets selectors, the name its first term", body(t) == "1..4", body(t))

    --[[ The rows are \gcd ( a + b , c ) and \gcd ( a , b + c ), and a - - b + c, whose first
    minus the parse leaves untagged. @date 19-10-2026-22:23 ]]
    local _, g1 = laid_out(fs, "\\gcd(a+b,c)", nil)
    t = g1 and g1.geom.sums[1].terms[2]
    check("a comma after a sum stays out of its last term", body(t) == "5..5", body(t))
    local _, g2 = laid_out(fs, "\\gcd(a,b+c)", nil)
    t = g2 and g2.geom.sums[1].terms[1]
    check("...and a comma before it out of its first", body(t) == "5..5", body(t))
    local _, runs = laid_out(fs, "a--b+c", nil)
    t = runs and runs.geom.sums[1].terms[1]
    check("an untagged sign stays out of the term before it", body(t) == "1..1", body(t))
end

-- ------------------------------------------------------------------ brackets and spaces
--[[ @brief Finds the sum whose last term's underline ends at slot k. @date 19-10-2026-22:23
--]]
local function sum_ending_at(geom, k)
    for _, sum in ipairs(geom.sums) do
        if sum.terms[#sum.terms].body.hi == k then
            return sum
        end
    end
    return nil
end

--[[ @brief Checks that a release between the brackets of a term's sibling is refused.
-- |
-- | A MOVE INTO THE SUM WITHIN IS NOT BUILT, and before 19-10-2026 such a release was committed
-- | as a move among the outer terms: y dropped between a and b made x+(a+b)+y into x+y+(a+b).
-- |
-- | @date 19-10-2026-22:23
--]]
local function into_brackets(fs)
    --[[ Each case names the slot of its `a`; the inner `+` follows it. @date 19-10-2026-22:23 ]]
    for _, case in ipairs({{"x+(a+b)+y", 4}, {"x+2(a+b)+y", 5}, {"(a+b)+y", 2}}) do
        local c, rec = laid_out(fs, case[1], nil)
        local outer = rec and sum_ending_at(rec.geom, #mexpru.u(c.root).children)
        local y = outer and outer.terms[#outer.terms]
        check(case[1] .. " has its outer sum", y ~= nil)
        if y then
            for k = case[2], case[2] + 1 do
                local bb = slot_box(fs, c, k)
                local none, why = dropped(fs, rec, y, (bb.left + bb.right) / 2, 0)
                check(case[1] .. ": y dropped on slot " .. k .. " inside the brackets is refused",
                        none == nil and tostring(why):find("inside a bracket", 1, true) ~= nil,
                        why)
            end
        end
    end

    local c, rec = laid_out(fs, "x+(a+b)+y", nil)
    local outer = rec and sum_of(rec.geom, 3, 0)
    if outer then
        local plus = slot_box(fs, c, 2)
        local d = dropped(fs, rec, outer.terms[3], (plus.left + plus.right) / 2, 0)
        check("...while y dropped on the + before the bracket lands at gap 1", d ~= nil
                and d.gap == 1 and d.option ~= nil, d and d.gap)
    end
end

--[[ @brief Checks that a space beside a sum is part of the gap there, for its marker and for a
-- |        drop.
-- |
-- | A SPACE HAS NO INK, and before 19-10-2026 it stood in for what is drawn beside the sum: the
-- | end marker sat on the last glyph and a release in the visible gap was refused.
-- |
-- | @date 19-10-2026-22:23
--]]
local function spaces_beside(fs)
    --[[ The rows are a + b, a space, \Rightarrow, c + d; \int x + 1, a space, d, a space and x;
    and c, a space, =, a space, a, a space, +, a space and b. @date 19-10-2026-22:23 ]]
    local c, rec = laid_out(fs, "a+b \\Rightarrow c+d", nil)
    local s = rec and rec.geom.sums[1]
    if s then
        local arrow = slot_box(fs, c, 5)
        local mark = s.marks[3].x
        check("a+b's end marker stands in the gap before \\Rightarrow",
                mark > s.terms[2].tail.x + 1 and mark < arrow.left, mark)
        local d = dropped(fs, rec, s.terms[1], arrow.left - 2, 0)
        check("...and a drop in that gap lands last", d ~= nil and d.gap == 2, d and d.gap)
    end

    local c2, int = laid_out(fs, "\\int x+1 \\,d x", nil)
    s = int and int.geom.sums[1]
    if s then
        local dee = slot_box(fs, c2, 6)
        local mark = s.marks[3].x
        check("x+1's end marker stands in the gap before the d", mark > s.terms[2].tail.x + 1
                and mark < dee.left, mark)
        local d = dropped(fs, int, s.terms[1], dee.left - 2, 0)
        check("...and a drop just before the d lands last", d ~= nil and d.gap == 2, d and d.gap)
    end

    local c3, eq = laid_out(fs, "c = a + b", nil)
    s = eq and eq.geom.sums[1]
    if s then
        local mark = s.marks[1].x
        check("a+b's front marker runs from a's ink, not from the space before it",
                mark > slot_box(fs, c3, 3).right and mark < slot_box(fs, c3, 5).left - 1, mark)
    end
end

-- ------------------------------------------------------------------ the cache
local function caching(fs)
    local c, rec = laid_out(fs, "a+b+c", nil)
    local asked = 0
    local counting = function() asked = asked + 1 return {} end
    local again = term_selectors.layout(fs, c, SZ, nil, counting, 10, 20)
    check("a second layout reuses the geometry", rawequal(rec.geom, again.geom))
    check("...and works out no declarations for it", asked == 0, asked)
    check("...placed at the new origin", again.x == 10 and again.y == 20)
    check("a fresh record describes its tree", term_selectors.current(again, c))
    local narrow = term_selectors.layout(fs, c, SZ, 30, counting, 0, 0)
    check("another wrap width lays out again", not rawequal(narrow.geom, rec.geom))
    check("...and asks for the declarations once", asked == 1, asked)
    c.version = (c.version or 0) + 1
    check("a record is stale once the version moves", not term_selectors.current(again, c))
    local bumped = term_selectors.layout(fs, c, SZ, nil, NO_DECLS, 0, 0)
    check("...and the next layout is new", not rawequal(bumped.geom, rec.geom))
    mformula.rescale(c, fs)
    check("a zoom's new root makes a record stale", not term_selectors.current(bumped, c))
    local zoomed = term_selectors.layout(fs, c, SZ, nil, NO_DECLS, 0, 0)
    check("...and the zoomed tree lays out", zoomed ~= nil and #zoomed.geom.sums == 1)
    check("current refuses a missing record", not term_selectors.current(nil, c)
            and not term_selectors.current(false, c))
end

function run_test()
    local fs = char.load_font_set()
    the_sketch(fs)
    nesting_and_rows(fs)
    folded_and_bracketed(fs)
    wrapped(fs)
    pointing(fs)
    dropping(fs)
    wrapped_drop(fs)
    wrapped_lines(fs)
    untagged_glyphs(fs)
    into_brackets(fs)
    spaces_beside(fs)
    caching(fs)
    if checks_failed == 0 then
        print("PASS: term selectors sit where the sketch puts them (" .. checks_run .. " checks)")
    end
    return checks_failed == 0
end

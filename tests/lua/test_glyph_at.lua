--[[
test_glyph_at.lua - the gesture's hit test answers only for a glyph the point is really on.

THE ASSUMPTION, and it is the opposite of the one next door: mformula's CARET hit test snaps. It has
to - a click must always put the cursor somewhere, so every level of that descent has a fallback
(the gap between two glyphs resolves to the nearest edge, a point past the last glyph resolves to
"after it", the space beside a fraction bar resolves to the fraction). glyph_at has none of them. It
descends by containment and returns nil the moment nothing contains the point.

WHY THE DIFFERENCE MATTERS ENOUGH TO TEST. The two were one function for a day, because "which node
is under the pointer" sounds like one question. It is not: a right-click that inherits the caret's
snapping answers for glyphs the user cannot see themselves pointing at - the whole row answers, and
then a transformation offers itself for an expression nobody aimed at. Reported 2026-09-11: "we want
the exact matching glyph's box and check it against the mouse and if no box intersects (none of the
leaf ones), then simply ignore it: right click only works on things that you can roughly see".

So the checks below are mostly NEGATIVE. Finding the glyph you are standing on is the easy half;
the half that rots silently is refusing everything else, because a fallback reintroduced anywhere in
that descent still looks correct in every screenshot.

Driven in the RAW frame (mformula_new.glyph_at, exported for exactly this) rather than through
node_at: the frame conversion needs a drawn container and a font size, and it is not what is being
asserted here.
]]

package.path = package.path .. ";./scripts/?.lua"

local vc = require("virt_composer")
local char = require("char")
local mexpru = require("mexpru")
local mformula_new = require("mformula_new")
local mformula_latex = require("mformula_latex")

local SZ = mexpru.DEFAULT_SIZE

local checks_run, checks_failed = 0, 0
local function check(name, cond, got)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name .. (got ~= nil and ("  (got: " .. tostring(got) .. ")") or ""))
    end
end

--[[ A node's drawn box, through the descent's OWN measurement rather than a second one: a node's
local bb is relative to itself and only becomes comparable once its `pos` is added, which is a trap
worth avoiding here - probes in the wrong frame do not fail loudly, they just never hit anything. ]]
local function box_of(fs, node)
    return mformula_new.node_bbox(fs, node)
end

-- The middle of that box.
local function center(fs, node)
    local b = box_of(fs, node)
    return {x = (b.left + b.right) / 2, y = (b.top + b.bottom) / 2}
end

function run_test()
    local fs = char.load_font_set()
    local function row(src)
        return mformula_latex.from_latex(fs, SZ, src)
    end
    local function at(c, point)
        return mformula_new.glyph_at(fs, c.root, point)
    end

    -- ------------------------------------------------------------------ on a glyph
    do
        local c = row("a+b")
        local kids = mexpru.u(c.root).children
        check("setup: three glyphs", #kids == 3, #kids)
        for i, kid in ipairs(kids) do
            local hit = at(c, center(fs, kid))
            check("the middle of glyph " .. i .. " finds that glyph",
                    hit ~= nil and mexpru.same(hit, kid))
        end
    end

    -- ------------------------------------------------------------------ and nowhere else
    do
        local c = row("a+b")
        local b = box_of(fs, c.root)
        local mid_y = (b.top + b.bottom) / 2

        --[[ ABOVE THE ROW. The caret descent answers here (it clamps into the row and picks an
        edge), which is exactly right for a caret and exactly wrong for a gesture. ]]
        check("far above the row is nothing",
                at(c, {x = (b.left + b.right) / 2, y = b.top - 40}) == nil)

        --[[ PAST THE END. horiz_margin_target() turns this into "after the last glyph" for a click;
        here there is no glyph, so there is no answer. ]]
        check("past the end of the row is nothing",
                at(c, {x = b.right + 30, y = mid_y}) == nil)

        check("before the start of the row is nothing",
                at(c, {x = b.left - 30, y = mid_y}) == nil)
    end

    -- ------------------------------------------------------------------ structure is not a glyph
    do
        --[[ THE FRACTION BAR. A compound answers about its children and never about itself, so the
        ink of the bar - which is drawn by the frac, not by any glyph - is not a target. The caret
        descent deliberately resolves this region to the fraction; this deliberately does not. ]]
        local c = row("\\frac{a}{b}")
        local frac = mexpru.u(c.root).children[1]
        local u = mexpru.u(frac)
        check("setup: it is a fraction", u.num ~= nil and u.den ~= nil)
        if u.num and u.den then
            local num_b, den_b = box_of(fs, u.num), box_of(fs, u.den)
            local bar = {x = (num_b.left + num_b.right) / 2,
                         y = (num_b.bottom + den_b.top) / 2}
            check("the fraction bar is not a glyph", at(c, bar) == nil)
            check("...but the numerator still is", at(c, center(fs, u.num)) ~= nil)
        end
    end

    -- ------------------------------------------------------------------ a dress owns its own ink
    do
        --[[ The arrow of a vector is drawn by the dress and belongs to the letter under it, so a
        point on the decoration answers with the dress rather than with nothing - otherwise half of
        an accented glyph would be dead to the gesture. The tag lookup unwraps it downstream
        (ast_gestures.node_at goes through slot_atom), which is why answering with the wrapper is
        enough. ]]
        local c = row("\\vec{F}")
        local dressed = mexpru.u(c.root).children[1]
        local target = mexpru.u(dressed).target
        check("setup: it is a dress", target ~= nil)
        if target then
            local whole, inner = box_of(fs, dressed), box_of(fs, target)
            check("the letter answers for itself", at(c, center(fs, target)) ~= nil)
            --[[ Only meaningful if the decoration actually pokes above the letter, which is what
            an accent is; if it ever stops doing so this check has nothing left to ask. ]]
            if whole.top < inner.top then
                local ink = {x = (inner.left + inner.right) / 2,
                             y = (whole.top + inner.top) / 2}
                check("the accent's own ink answers with the dressed glyph",
                        at(c, ink) ~= nil)
            end
        end
    end

    if checks_failed == 0 then
        print("PASS: the gesture only sees what it is on (" .. checks_run .. " checks)")
    end
    return checks_failed == 0
end

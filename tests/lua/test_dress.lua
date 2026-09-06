--[[
test_dress.lua - accents: mexpr_dress() placement and mexpr_accent()'s tier search.

Both follow TEXbook Appendix G Rule 12 (docs/texbook.pdf), and the three parts of it that are easy
to get wrong are what this pins:

  - "w(z) <- w(x)": a dressed atom is as wide as its TARGET, never as wide as the decoration, so a
    wide hat OVERHANGS instead of shoving its neighbours apart. calc_bb alone would widen it.
  - vertical clearance: the accent rides just above the target's INK, so a hat on a tall letter
    does not simply float up by the whole difference in height. Rule 12's own delta term is not
    imported - it compensates for TeX's baseline-relative accent box, which mexpr_symbol does not
    produce (see mexpr_dress's own comment); importing it literally put the accent INSIDE the
    letter, which is what the second block below would have caught.
  - the successor search: the widest accent still no wider than the target, then a DRAWN shape once
    the font runs out of tiers (cmex10 has three widehats and no more).

And the trap this codebase has fallen into repeatedly: a dress wraps an atom and IS an atom, the
same shape as a supsub base, so slot_atom() has to look through it or a dressed ")" goes missing
from bracket pairing.
]]

package.path = package.path .. ";./scripts/?.lua"

local vc = require("virt_composer")
local char = require("char")
local mexpru = require("mexpru")

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
    local e = char.find_by_ascii(ascii)
    local g = mexpru.mexpr_symbol(fs, {size = mexpru.physical_sz(SZ), code = e.ncod}, true)
    mexpru.u(g).sz = SZ
    return g
end

local function box(n)
    local b = vc.mexpr_get_bb(n)
    return b.br.x - b.tl.x, b.br.y - b.tl.y, b
end

function run_test()
    local fs = char.load_font_set()

    -- ---------------------------------------------------------------- width comes from the target
    do
        local x = glyph(fs, "x")
        local xw, xh = box(x)
        local hat = mexpru.accent(fs, char.hat_accent, x, SZ)
        local dressed = mexpru.dress(fs, x, hat, nil, SZ)
        local dw, dh = box(dressed)
        check("a dressed atom is exactly as wide as its target", math.abs(dw - xw) < 0.01,
                string.format("%.2f vs %.2f", dw, xw))
        check("...and taller than it, since the accent sits above", dh > xh,
                string.format("%.2f vs %.2f", dh, xh))
        check("it is tagged as a dress", mexpru.u(dressed).kind == "dress")
        check("...and remembers its target", mexpru.same(mexpru.u(dressed).target, x))
    end

    -- ---------------------------------------------------------------- short vs tall letter
    --[[ The accent clears the target's INK, so dressing a tall letter and a short one does not
    change the accent's relationship to either. This is the check that caught the first attempt,
    where Rule 12's delta was imported literally and the hat landed inside the glyph. ]]
    do
        local short_g, tall_g = glyph(fs, "x"), glyph(fs, "b")
        local _, sh = box(short_g)
        local _, th = box(tall_g)
        check("the two test letters really differ in height", th > sh + 1, th - sh)

        local acc_s = mexpru.accent(fs, char.hat_accent, short_g, SZ)
        local acc_t = mexpru.accent(fs, char.hat_accent, tall_g, SZ)
        local _, ash = box(acc_s)
        local _, ath = box(acc_t)
        local ds = mexpru.dress(fs, short_g, acc_s, nil, SZ)
        local dt = mexpru.dress(fs, tall_g, acc_t, nil, SZ)
        local _, dsh = box(ds)
        local _, dth = box(dt)
        --[[ The two accents are allowed to differ in height themselves: a drawn one keeps the tier
        aspect ratio, so the WIDER of two letters gets a proportionally taller hat (2026-09-06).
        What this still pins is the original point - the accent clears the target's ink and adds
        nothing beyond that, so the dressed pair cannot grow by more than the letters and their own
        two hats already differ. A hat landing INSIDE the glyph, which is what this check was
        written for, still fails it. ]]
        check("a hat on a tall letter does not simply ride the letter up",
                (dth - dsh) < (th - sh) + (ath - ash) + 0.01,
                string.format("dressed grew %.2f, letters differ by %.2f, hats by %.2f",
                        dth - dsh, th - sh, ath - ash))
    end

    -- ---------------------------------------------------------------- a drawn accent keeps shape
    --[[ Past the widest tier the accent is DRAWN, and it has to keep growing in both directions.
    It used to widen at the last tier's fixed height, so a hat over a stack came out as very nearly
    a straight line - at size 12 the widest hat glyph is 15.00 x 3.00, so a 320-wide target drew a
    320 x 3 sliver: aspect 0.009 against the glyph's own 0.200. Reported live 2026-09-06: "large
    hats ^ look like lines almost, they must also rise in height and keep the aspect ratio".

    Checked as a RATIO held across a wide span rather than against fixed numbers, since that is
    what "keep the aspect ratio" actually asserts, and it stays true if the tier glyphs are ever
    re-cut. ]]
    do
        for _, recipe in ipairs({{"hat", char.hat_accent}, {"tilde", char.tilde_accent}}) do
            local widths = {40, 80, 160, 320}
            local first_ratio
            for _, w in ipairs(widths) do
                local a = mexpru.mexpr_accent(fs, recipe[2](mexpru.physical_sz(SZ)), w)
                local _, h = box(a)
                check(recipe[1] .. " at width " .. w .. " has real height, not a sliver",
                        h > 1, h)
                local ratio = h / w
                first_ratio = first_ratio or ratio
                check(recipe[1] .. " keeps its aspect ratio at width " .. w,
                        math.abs(ratio - first_ratio) < 0.01,
                        string.format("%.4f vs %.4f", ratio, first_ratio))
            end
            --[[ And no STEP where the glyphs run out: at the boundary the drawn shape has to
            continue the last tier, which is what makes the scaling factor exactly 1.0 there. ]]
            local wide = mexpru.mexpr_accent(fs, recipe[2](mexpru.physical_sz(SZ)), 320)
            local _, wh = box(wide)
            check(recipe[1] .. ": a very wide one is much taller than the widest glyph",
                    wh > 20, wh)
        end
    end

    -- ---------------------------------------------------------------- the successor search
    do
        local narrow = mexpru.mexpr_accent(fs, char.hat_accent(mexpru.physical_sz(SZ)), 1)
        local wide = mexpru.mexpr_accent(fs, char.hat_accent(mexpru.physical_sz(SZ)), 400)
        local nw = box(narrow)
        local ww = box(wide)
        check("a wider target selects a wider accent", ww > nw, string.format("%.2f vs %.2f", ww, nw))
        check("past the last tier the accent is DRAWN, not a glyph",
                wide.type == vc.MEXPR_TYPE_LINE_STRIP, tostring(wide.type))
        check("...and the drawn one really spans what was asked for", math.abs(ww - 400) < 2, ww)
        check("a narrow target still gets a real glyph",
                narrow.type == vc.MEXPR_TYPE_SYMBOL, tostring(narrow.type))
    end

    -- ---------------------------------------------------------------- bar and dots
    do
        local x = glyph(fs, "x")
        local xw = box(x)
        local bar = mexpru.accent(fs, char.bar_accent, x, SZ)
        check("a bar is always drawn - these fonts have no macron glyph",
                bar.type == vc.MEXPR_TYPE_LINE_STRIP, tostring(bar.type))
        check("...at the target's width", math.abs(box(bar) - xw) < 2, box(bar))

        local one, three = mexpru.dots(fs, 1, SZ), mexpru.dots(fs, 3, SZ)
        check("three dots are wider than one", box(three) > box(one),
                string.format("%.2f vs %.2f", box(three), box(one)))
    end

    -- ---------------------------------------------------------------- the look-through
    do
        local close = glyph(fs, ")")
        mexpru.u(close).bracket = {is_open = false, type = vc.MEXPR_BRACKET_ROUND}
        local dressed = mexpru.dress(fs, close, mexpru.accent(fs, char.hat_accent, close, SZ), nil, SZ)
        check("slot_atom sees the bracket through the dress",
                mexpru.same(mexpru.slot_atom(dressed), close))
        local sup = mexpru.supsub(fs, dressed, nil, nil)
        check("...and through a supsub wrapping a dress too",
                mexpru.same(mexpru.slot_atom(sup), close))
    end

    -- ---------------------------------------------------------------- the accent RIDES the letter
    --[[ A decoration sits just clear of the target's ink - a unit or so - not floating above it.

    mexpr_dress takes the clearance from the HEIGHT of the metrics char it is handed, and its own
    comment asks for "the pen width, which is font-derived and already the thickness a drawn accent
    is stroked at". mexpru.dress() was passing {code = 0}, which is not a pen width but char.lua's
    first table entry - 26 units tall at size 12, against a letter 17 tall. Every accent floated a
    letter and a half above its own letter, and the row grew to fit that gap. Reported live
    2026-09-05, alongside a stale main.exe that was drawing them below the letter entirely.

    Stated as a RATIO of the target's own height rather than in absolute units, so it keeps meaning
    the same thing at any size, and checked for each accent kind - they build their decoration
    differently (a font glyph, a drawn strip, merged dots) and only share the placement. ]]
    do
        local a = char.find_by_ascii("a")
        local recipes = {
            {"hat", char.hat_accent}, {"tilde", char.tilde_accent}, {"bar", char.bar_accent},
        }
        for _, r in ipairs(recipes) do
            local target = mexpru.mexpr_symbol(fs, {size = SZ, code = a.ncod}, true)
            mexpru.u(target).sz = SZ
            local tb = vc.mexpr_get_bb(target)
            local th = tb.br.y - tb.tl.y

            local dressed = mexpru.dress(fs, target,
                    mexpru.accent(fs, r[2], target, SZ), nil, SZ)
            local db = vc.mexpr_get_bb(dressed)
            local dh = db.br.y - db.tl.y

            check(r[1] .. ": a dressed atom is not wildly taller than the letter",
                    dh < th * 2, string.format("%.1f vs letter %.1f", dh, th))
            -- The decoration's own bottom edge, in the dress's coordinates.
            local anch = dressed:anchor_at(2)
            local gap = tb.tl.y - (anch[2].y + vc.mexpr_get_bb(anch[1]).br.y)
            check(r[1] .. ": it clears the ink by a hair, not by a letter-height",
                    gap > 0 and gap < th / 2, string.format("gap %.1f, letter %.1f", gap, th))
        end

        -- Dots take the other branch of build_dress(); same placement, so the same must hold.
        for n = 1, 3 do
            local target = mexpru.mexpr_symbol(fs, {size = SZ, code = a.ncod}, true)
            mexpru.u(target).sz = SZ
            local tb = vc.mexpr_get_bb(target)
            local th = tb.br.y - tb.tl.y
            local dressed = mexpru.dress(fs, target, mexpru.dots(fs, n, SZ), nil, SZ)
            local db = vc.mexpr_get_bb(dressed)
            check(n .. " dots: not wildly taller than the letter",
                    (db.br.y - db.tl.y) < th * 2,
                    string.format("%.1f vs letter %.1f", db.br.y - db.tl.y, th))
            local anch = dressed:anchor_at(2)
            local gap = tb.tl.y - (anch[2].y + vc.mexpr_get_bb(anch[1]).br.y)
            check(n .. " dots: sit just above the ink", gap > 0 and gap < th / 2,
                    string.format("gap %.1f", gap))
        end
    end

    print("checks: " .. checks_run .. ", failed: " .. checks_failed)
    if checks_failed > 0 then
        return false
    end
    print("PASS: dress - target width, Rule 12 delta, tier search, drawn fallback, look-through")
    return true
end

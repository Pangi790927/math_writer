--[[
test_bigop_size.lua - the cmex10 display operators must render VISIBLY bigger than ordinary text.

This has now regressed twice, both times reported live and both times by eye, so it is pinned here
by measurement instead.

fonts/cmex10.ttf carries a much larger em box than the metrics it was converted from, so its big
operators arrive at roughly a quarter of their proper ink: at the default level a summation sign is
14px where a capital 'A' is 26px - SMALLER than a capital letter, when TeX sets it at about twice
one. char.size_delta_by_desc corrects that at construction, and the whole family shares one delta
because they were only ever off by the same constant.

The two failures this guards:

  1. "the sum sign should be twice as big" -> -4, which doubles 14 to 27, i.e. exactly cap height.
     Came straight back as "sigma is the same size" - and it was, to the pixel. A delta that merely
     doubles a broken baseline is still broken, so a ratio-to-cap-height check is the only kind
     that catches it. Bare "is it bigger than it was" would have passed.
  2. m_font_sizes growing under a delta. Two levels were once inserted mid-table for Ctrl+MouseWheel
     zoom, which silently shortened every delta's real reach - \int went from 4x to 2.67x without
     one line of its own code changing. These checks are in PIXELS against a measured capital, so
     they fail if the table moves again, which is exactly when someone needs to know.

The separation test_int_size.lua pins - real ink boosted, u(_).sz left LOGICAL - is re-checked here
for the rest of the family, since a delta added without that care breaks cursor height.
]]

package.path = package.path .. ";./scripts/?.lua"

local vc = require("virt_composer")
local char = require("char")
local mexpru = require("mexpru")
local mformula_latex = require("mformula_latex")

local B = string.char(92)

local checks_run, checks_failed = 0, 0
local function check(name, cond, got)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name .. (got ~= nil and ("  (got: " .. tostring(got) .. ")") or ""))
    end
end

local SZ = 12   -- the default level, which is what the user actually looks at

local function height(node)
    local bb = vc.mexpr_get_bb(node)
    return bb.br.y - bb.tl.y
end

--[[ Every operator is measured through the REAL parse path, not by building a glyph by hand - the
delta lives in the callers, so a table that is right while no caller reads it is still a bug. ]]
local function parse_first(fs, src)
    local c = mformula_latex.from_latex(fs, SZ, src)
    return mexpru.u(c.root).children[1]
end

function run_test()
    local fs = char.load_font_set()

    -- The yardstick: a capital letter at the same level. Measured, never hardcoded, so this
    -- survives any change to m_font_sizes - which is the point.
    local cap = height(parse_first(fs, "A"))
    check("sanity: a capital letter has real height", cap > 5, cap)

    --[[ TeX sets a display integral at about 3x the cap height and a display sum at about 2x. The
    bounds are wide on purpose: this is guarding "did it silently collapse back to text size", not
    pinning a particular font's exact metrics. The LOWER bound is the one that matters - 1.6x is
    comfortably above the 1.04x that -4 produced and was reported as too small. ]]
    local EXPECTED = {
        {name = "int",    min = 2.4, max = 4.5},
        {name = "oint",   min = 2.4, max = 4.5},
        {name = "sum",    min = 1.6, max = 3.0},
        {name = "prod",   min = 1.6, max = 3.0},
        {name = "bigcup", min = 1.6, max = 3.0},
        {name = "bigcap", min = 1.6, max = 3.0},
    }

    for _, e in ipairs(EXPECTED) do
        local node = parse_first(fs, B .. e.name .. " ")
        local ratio = height(node) / cap
        check(string.format("%s%s stands %.2fx the cap height (want %.1f-%.1fx)",
                        B, e.name, ratio, e.min, e.max),
                ratio >= e.min and ratio <= e.max, string.format("%.2fx", ratio))

        --[[ The boost is real ink only. u(_).sz is a LOGICAL level - cursor height reads it, and a
        supsub built on this glyph sizes its limits from it - so a big operator that let its visual
        delta leak here would park a 4x-tall cursor on itself. ]]
        check(B .. e.name .. ": u(_).sz stays at the surrounding nominal level",
                mexpru.u(node).sz == SZ, mexpru.u(node).sz)
    end

    --[[ The failure mode by name: dead level with a capital is the bug, not the fix. A sum has to
    stand clear of one, not merely match it. ]]
    do
        local sum = height(parse_first(fs, B .. "sum "))
        check("a sum is not 'the same size as a sigma' - it clears a capital by half again",
                sum > cap * 1.5, string.format("sum=%.0f cap=%.0f", sum, cap))
    end

    --[[ The family shares ONE delta, so its members stay in proportion to each other. If someone
    tunes a single glyph by eye later, this is what says the set drifted apart. ]]
    do
        local sum = height(parse_first(fs, B .. "sum "))
        for _, name in ipairs({"prod", "bigcup", "bigcap"}) do
            local other = height(parse_first(fs, B .. name .. " "))
            check(B .. name .. " matches " .. B .. "sum (one shared correction, not per-glyph tuning)",
                    math.abs(other - sum) < 1.0, string.format("%.0f vs %.0f", other, sum))
        end
        local int_h = height(parse_first(fs, B .. "int "))
        check("an integral still stands taller than a sum, as TeX sets them",
                int_h > sum, string.format("int=%.0f sum=%.0f", int_h, sum))
    end

    -- ---------------------------------------------------------------- and where they SIT
    --[[ Reported 2026-09-06, immediately after the sizing was fixed: "it is the right size, not the
    right placement, you forgot some ofset".

    TeX centres a big operator on the math axis - a quarter em above the baseline - so it straddles
    the line instead of resting on it. fonts/cmex10.ttf reports no depth at all (every glyph in it
    comes back with the same flattened ascent), so before char.y_offset_by_desc existed the sum
    family sat ENTIRELY above the baseline: its lowest ink ended 8.5 units above the line it was
    supposed to straddle, and the integrals hung about 10 too high.

    Measuring the centre against the axis is the check that catches this, and a height check cannot:
    the glyphs were already exactly the right size when this was reported. ]]
    do
        local a = parse_first(fs, "A")
        local a_bb = vc.mexpr_get_bb(a)
        local baseline = a_bb.br.y            -- a capital sits ON the baseline
        local axis = baseline - 0.25 * 36.0   -- cmsy10's axis height, at the default level's 36pt

        local function centre_of(node)
            local bb = vc.mexpr_get_bb(node)
            return (bb.tl.y + bb.br.y) / 2
        end

        for _, name in ipairs({"sum", "prod", "bigcup", "bigcap", "int", "oint"}) do
            local off = centre_of(parse_first(fs, B .. name .. " ")) - axis
            check(string.format("%s%s is centred on the math axis (off by %+.2f)", B, name, off),
                    math.abs(off) < 1.0, string.format("%+.2f", off))
        end

        --[[ A LETTER must not move. The correction is per-glyph precisely so it can apply to the
        operators without disturbing anything else - if it ever leaked to the whole font, every
        capital would float. \Sigma is the sharpest case: same letterform as \sum, must still sit
        on the baseline like the letter it is. ]]
        for _, name in ipairs({"Sigma", "Pi", "Delta", "Omega"}) do
            local bb = vc.mexpr_get_bb(parse_first(fs, B .. name .. " "))
            check(B .. name .. " is a letter and still rests on the baseline",
                    math.abs(bb.br.y - baseline) < 1.0, bb.br.y - baseline)
        end

        --[[ The correction is stored as a FRACTION of the font size, so it has to survive a zoom on
        its own. A pixel constant would pass every check above and then drift the moment anyone
        touched Ctrl+MouseWheel - the exact failure mode size_delta_by_desc already hit once when
        m_font_sizes grew underneath it. ]]
        for _, zoom in ipairs({3, -3}) do
            mexpru.set_zoom(zoom)
            -- Re-derive both from the capital at THIS zoom: the axis is a quarter em above the
            -- baseline, and the em scales with the text, so cap height is the ruler.
            local z_bb = vc.mexpr_get_bb(parse_first(fs, "A"))
            local z_axis = z_bb.br.y - 0.25 * 36.0 * ((z_bb.br.y - z_bb.tl.y) / cap)
            for _, name in ipairs({"sum", "int"}) do
                local off = centre_of(parse_first(fs, B .. name .. " ")) - z_axis
                check(string.format("%s%s stays on the axis at zoom %+d (off by %+.2f)",
                                B, name, zoom, off),
                        math.abs(off) < 1.5, string.format("%+.2f", off))
            end
            mexpru.set_zoom(0)
        end
    end

    -- ---------------------------------------------------------------- the keys that produce them
    --[[ Reported 2026-09-06 as "I do alt+shift+s and it's the same as F, that's not good", and it
    was: Alt+Shift+S gave Greek capital Sigma, a LETTER, correctly sized like a capital F. Sigma and
    the summation sign are the same letterform, so the key looked broken every time it worked as
    designed. The size fix above could never have helped - it boosts \sum, and the key was not
    producing \sum at all.

    So the sizing and the keys have to be checked together: an operator key must yield the OPERATOR
    glyph, from cmex10, carrying the display-size correction - not the Greek capital it resembles.
    A regression here reads to the user exactly like the sizing regression this file already
    guards, which is why it is pinned in the same place.

    The handler cannot be pressed headlessly (this harness binds no ImGuiKey constants at all), but
    char.greek_alt_shift is the single table both it and F2's legend read, so what the table says is
    what the key does. ]]
    do
        local OPERATOR_KEYS = {s = "sum", p = "prod", q = "int"}
        for key, name in pairs(OPERATOR_KEYS) do
            local desc = char.greek_alt_shift[key]
            check("Alt+Shift+" .. key:upper() .. " produces " .. B .. name,
                    desc == B .. name, desc)

            local entry = desc and char.find_by_desc(desc)
            check("Alt+Shift+" .. key:upper() .. ": that name resolves to a glyph", entry ~= nil)
            if entry then
                --[[ The operator lives in cmex10; the Greek capital it resembles does not. This is
                the check that actually distinguishes them - the descs could be right while the
                catalog pointed at the wrong font. ]]
                check("Alt+Shift+" .. key:upper() .. ": it is the cmex operator, not a letter",
                        entry.fnum == char.FONT_MATH_EX, entry.fnum)
                check("Alt+Shift+" .. key:upper() .. ": it carries the display-size correction",
                        char.size_delta_by_desc[entry.desc] ~= nil)

                -- And the property the user actually sees: taller than the capital it resembles.
                local ratio = height(parse_first(fs, desc .. " ")) / cap
                check(string.format("Alt+Shift+%s stands clear of a capital (%.2fx, not ~1x)",
                                key:upper(), ratio),
                        ratio > 1.5, string.format("%.2fx", ratio))
            end
        end

        --[[ The letters genuinely used AS variables must stay letters. Taking a Greek capital is
        only justified where it shadows an operator; doing it to \Delta would be a straight loss. ]]
        for _, key in ipairs({"g", "d", "h", "l", "x", "u", "f", "y", "w"}) do
            local desc = char.greek_alt_shift[key]
            check("Alt+Shift+" .. key:upper() .. " is still a Greek capital",
                    desc ~= nil and char.find_by_desc(desc) ~= nil
                            and char.find_by_desc(desc).fnum ~= char.FONT_MATH_EX, desc)
        end

        --[[ The displaced letters are not lost - command entry still reaches them, which is what
        makes the trade acceptable at all. ]]
        for _, desc in ipairs({B .. "Sigma", B .. "Pi"}) do
            check(desc .. " is still reachable by name", char.find_by_desc(desc) ~= nil)
        end
    end

    -- The boost must not disturb what any of these serialize back to.
    for _, name in ipairs({"int", "sum", "prod", "bigcup", "bigcap", "oint"}) do
        local src = B .. name .. " a"
        local c = mformula_latex.from_latex(fs, SZ, src)
        check(src .. ": round-trips unchanged", mformula_latex.to_latex(c) == src,
                mformula_latex.to_latex(c))
    end

    print("checks: " .. checks_run .. ", failed: " .. checks_failed)
    if checks_failed > 0 then
        return false
    end
    print("PASS: cmex display operators - TeX proportions, centred on the axis, ink only")
    return true
end

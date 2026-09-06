--[[
test_bracket_survives_rescale.lua - a TALL bracket pair has to stay tall across a rescale.

Reported live 2026-09-05: "scrolling breaks paranthesis, they become small, for some reason, see my
last run, for some reason re-pasting them solves them but, they break on scrol". The flight recorder
(input_history.log) showed the run's wheel events were Ctrl+wheel - i.e. ZOOM, not scroll - which is
the one input that sends the whole tree back through mformula_new.rescale().

Root cause: rescale_node()'s bracket branch rebuilds each bracket atom back to a small plain
un-resolved glyph on purpose (is_open/type preserved, peer dropped) and relies on the mexpru.horiz()
call on the way back up to re-tier it. But resolve_bracket_pairs() finds a pair's close by reading
the open atom's own `.peer`, and the rebuilt atoms had none - so the `br.peer` test failed for every
pair, resolve_bracket_pairs() treated both halves as still-pending ordinary glyphs, and the pair was
left at exactly that small plain glyph. rescale_node()'s own comment already asserted horiz()
"re-links peers itself"; mexpru.lua's relink_bracket_pairs() is what makes that actually true.

Re-pasting looked like a cure because paste rebuilds through try_close_bracket(), which sets peers
the ordinary way - it was restoring the link the rescale had thrown away, not fixing any sizing.

The decisive check here is the SAME-ZOOM rescale: a rescale that changes no size at all must be
geometrically invisible, so any difference in the pair's height is the bug and nothing else. The
zoom-change cases then confirm the pair is still re-tiered against its content at a size it has
never been built at before.
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
        print("FAIL: " .. name .. (got and ("  (got: " .. tostring(got) .. ")") or ""))
    end
end

local SZ = 12

local function glyph(fs, ascii, sz)
    local entry = char.find_by_ascii(ascii)
    local g = mexpru.mexpr_symbol(fs, {size = sz, code = entry.ncod}, true)
    mexpru.u(g).sz = sz
    return g
end

local function height(node)
    local bb = vc.mexpr_get_bb(node)
    return bb.br.y - bb.tl.y
end

-- The plain typed "(" at the CURRENT zoom - resolve_bracket_pairs()'s own threshold, and therefore
-- the yardstick for "did this pair come back tiered, or did it collapse to an ordinary paren".
local function plain_paren_height(fs, sz)
    local entry = char.find_by_ascii("(")
    local s = fs:char_get_sz({size = mexpru.physical_sz(sz), code = entry.ncod})
    return math.abs(s.tr.y - s.bl.y)
end

-- A resolved pair around `inner`, exactly the shape try_close_bracket() produces - the same helper
-- test_tall_bracket_latex.lua uses, and for the same reason: horiz() itself decides plain vs tiered.
local function bracketed(fs, inner, sz)
    local open_atom = glyph(fs, "(", sz)
    mexpru.u(open_atom).bracket = {is_open = true, type = vc.MEXPR_BRACKET_ROUND}
    local close_atom = glyph(fs, ")", sz)
    mexpru.u(close_atom).bracket = {is_open = false, type = vc.MEXPR_BRACKET_ROUND,
            peer = mexpru.u(open_atom)}
    mexpru.u(open_atom).bracket.peer = mexpru.u(close_atom)

    local list = {open_atom}
    for _, n in ipairs(inner) do
        list[#list + 1] = n
    end
    list[#list + 1] = close_atom
    return list
end

-- "(a^{i})" - tall enough to be over resolve_bracket_pairs()'s plain-paren threshold, in a real
-- container so mformula_new.rescale() (not rescale_node() directly) is what gets exercised.
local function tall_pair_container(fs)
    local c = mformula_new.new(fs, SZ)
    local base = glyph(fs, "a", SZ)
    local sup = mexpru.horiz(fs, {glyph(fs, "i", SZ - 2)}, SZ - 2)
    local root = mexpru.horiz(fs, bracketed(fs, {mexpru.supsub(fs, base, sup, nil)}, SZ), SZ)
    mexpru.update_positions(root)
    mexpru.cut(c.root)
    c.root = root
    c.cursor_pos = vc.wref_mexpr(mexpru.u(root).children[2])
    return c
end

function run_test()
    local fs = char.load_font_set()
    mexpru.set_zoom(0)

    -- ------------------------------------------------------------ same-zoom rescale is invisible
    do
        local c = tall_pair_container(fs)
        local children = mexpru.u(c.root).children
        check("setup: the row is open/content/close", #children == 3, #children)

        local before_open_h = height(children[1])
        local before_close_h = height(children[3])
        check("setup: the pair really is TALLER than a plain paren (i.e. tiered)",
                before_open_h > plain_paren_height(fs, SZ) * 1.05,
                string.format("%.2f vs plain %.2f", before_open_h, plain_paren_height(fs, SZ)))

        mformula_new.rescale(c, fs)

        local after = mexpru.u(c.root).children
        check("the row still is open/content/close after a rescale", #after == 3, #after)
        check("a same-zoom rescale leaves the OPEN bracket exactly as tall",
                math.abs(height(after[1]) - before_open_h) < 0.01,
                string.format("%.2f -> %.2f", before_open_h, height(after[1])))
        check("...and the CLOSE bracket exactly as tall",
                math.abs(height(after[3]) - before_close_h) < 0.01,
                string.format("%.2f -> %.2f", before_close_h, height(after[3])))

        --[[ The mechanism itself, not just its visible effect: both rebuilt atoms have to come back
        peer-linked to each other, since that link is what every LATER rebuild (any edit, the next
        zoom) reads to find the pair at all. A pair that renders right but comes back unlinked would
        simply collapse one rescale later. ]]
        local open_br, close_br = mexpru.u(after[1]).bracket, mexpru.u(after[3]).bracket
        check("the OPEN bracket is peer-linked after the rescale", open_br.peer ~= nil)
        check("the CLOSE bracket is peer-linked after the rescale", close_br.peer ~= nil)
        check("...and they point at EACH OTHER, not at nodes of the discarded tree",
                open_br.peer == mexpru.u(after[3]) and close_br.peer == mexpru.u(after[1]))
    end

    -- ------------------------------------------------------------ a real zoom change re-tiers
    for _, z in ipairs({3, -3}) do
        local c = tall_pair_container(fs)
        mexpru.set_zoom(z)
        mformula_new.rescale(c, fs)

        local after = mexpru.u(c.root).children
        local plain = plain_paren_height(fs, SZ)
        check("zoom " .. z .. ": the pair is re-tiered against its content, not collapsed to a paren",
                height(after[1]) > plain * 1.05,
                string.format("%.2f vs plain %.2f", height(after[1]), plain))
        check("zoom " .. z .. ": both halves came back the same height",
                math.abs(height(after[1]) - height(after[3])) < 0.01,
                string.format("%.2f vs %.2f", height(after[1]), height(after[3])))
        mexpru.set_zoom(0)
    end

    -- ------------------------------------------------------------ repeated zooming stays stable
    --[[ The reported symptom was cumulative - the brackets did not come back on the way out of the
    zoom either. Each rescale feeds the NEXT one its own output, so a link dropped once is gone for
    good; returning to zoom 0 has to land back on the original geometry exactly. ]]
    do
        local c = tall_pair_container(fs)
        local before = height(mexpru.u(c.root).children[1])
        for _, z in ipairs({1, 2, 3, 2, 1, 0}) do
            mexpru.set_zoom(z)
            mformula_new.rescale(c, fs)
        end
        local after = height(mexpru.u(c.root).children[1])
        check("zooming in and back out again returns the pair to its original height",
                math.abs(after - before) < 0.01, string.format("%.2f -> %.2f", before, after))
        mexpru.set_zoom(0)
    end

    -- ------------------------------------------------------------ nesting survives too
    --[[ "((a^{i}))": the inner pair stays short/plain, the outer goes tiered. relink_bracket_pairs()
    is a depth-stack scan, so this is where a stack that matched greedily (outer "(" to inner ")")
    would show up - as an inner pair that suddenly went tiered and an outer one that went plain. ]]
    do
        local c = mformula_new.new(fs, SZ)
        local base = glyph(fs, "a", SZ)
        local sup = mexpru.horiz(fs, {glyph(fs, "i", SZ - 2)}, SZ - 2)
        local inner_list = bracketed(fs, {mexpru.supsub(fs, base, sup, nil)}, SZ)
        local root = mexpru.horiz(fs, bracketed(fs, inner_list, SZ), SZ)
        mexpru.update_positions(root)
        mexpru.cut(c.root)
        c.root = root
        c.cursor_pos = vc.wref_mexpr(root)

        local before = mformula_new.to_latex(c)
        check("setup: nested pairs serialize with both pairs grown",
                before == "\\left(\\left(a^{i}\\right)\\right)", before)
        local before_outer = height(mexpru.u(root).children[1])

        mexpru.set_zoom(2)
        mformula_new.rescale(c, fs)
        mexpru.set_zoom(0)
        mformula_new.rescale(c, fs)

        local after_children = mexpru.u(c.root).children
        check("nested pairs still serialize the same after a zoom round trip",
                mformula_new.to_latex(c) == "\\left(\\left(a^{i}\\right)\\right)",
                mformula_new.to_latex(c))
        check("the OUTER pair is back at its original height",
                math.abs(height(after_children[1]) - before_outer) < 0.01,
                string.format("%.2f -> %.2f", before_outer, height(after_children[1])))
        -- bracketed() splices its content in FLAT, so the row here is [ "(", "(", supsub, ")", ")" ]
        -- - one horiz holding both pairs, which is exactly the nesting relink_bracket_pairs() has to
        -- get right by depth rather than by first-match.
        check("the row is the flat 5-slot nesting", #after_children == 5, #after_children)
        check("the outer pair is still the taller of the two",
                height(after_children[1]) > height(after_children[2]),
                string.format("%.2f vs %.2f", height(after_children[1]), height(after_children[2])))
    end

    print("checks: " .. checks_run .. ", failed: " .. checks_failed)
    if checks_failed > 0 then
        return false
    end
    print("PASS: bracket pairs stay resolved and correctly sized across rescale()")
    return true
end

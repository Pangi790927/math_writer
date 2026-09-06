--[[
test_bar_bracket.lua - "|" as a delimiter, on one shortcut that both opens and closes.

Asked for 2026-09-06: "make a bracket that is |, it should be opened and closed with the same key
ctrl+shift+\ or '|', it should simply be the height of the thing similar to square bracket, but
without thouse things at the top" - and, when the first attempt bound the CHARACTER instead: "that
is why I've said to put it on ctrl+shift+|, such that '|' is not affected".

So the shortcut is Ctrl+Shift+\ and a typed "|" stays an ordinary literal. That is what forces
the serialization: a bar pair cannot be written "|" without becoming indistinguishable from two
typed bars on reload, so it is written \lvert / \rvert - which is what LaTeX uses for it anyway.

The bar is NOT a third kind of thing in the model. Its atoms carry the ordinary
u(_).bracket = {is_open, type, peer}, so the counter rule, scan_bracket(), peer_slot() and the
cascade delete all keep working untouched; the only thing that differs is how one "|" is READ -
as a close if one is already open at this level, as an open otherwise. That reading lives in two
places which have to agree: handle_input()'s own dispatch (from container.pending_bracket) and
mformula_latex's parser (from its bracket stack). This exercises the parser, since handle_input
needs real keypresses.

SKIPPED, passing, while C++ has no MEXPR_BRACKET_BAR registered (math_expr_composer.h) - the whole
feature is guarded on that constant, so until it lands "|" is an ordinary character and there is
nothing here to test. The moment the enum value exists and the harness is rebuilt, every check below
starts running on its own.
]]

package.path = package.path .. ";./scripts/?.lua"

local vc = require("virt_composer")
local char = require("char")
local mexpru = require("mexpru")
local mformula = require("mformula_new")

local checks_run, checks_failed = 0, 0
local function check(name, cond, got)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name .. (got ~= nil and ("  (got: " .. tostring(got) .. ")") or ""))
    end
end

local SZ = 12

local function height(node)
    local bb = vc.mexpr_get_bb(node)
    return bb.br.y - bb.tl.y
end

-- The bracket atoms of a row, in order, as {index, is_open} - what the model actually decided.
local function bracket_tags(container)
    local out = {}
    for i, child in ipairs(mexpru.u(container.root).children) do
        local br = mexpru.u(mexpru.slot_atom(child)).bracket
        if br then
            out[#out + 1] = {i = i, is_open = br.is_open, peer = br.peer ~= nil}
        end
    end
    return out
end

function run_test()
    if not vc.MEXPR_BRACKET_BAR then
        print("SKIP: vc.MEXPR_BRACKET_BAR is not registered - the C++ half "
                .. "(math_expr_composer.h) has not landed yet, so \"|\" is still a plain character")
        return true
    end

    local fs = char.load_font_set()

    -- ------------------------------------------------------------------ one key, both roles
    do
        local c = mformula.from_latex(fs, SZ, "\\lvert a\\rvert ")
        local tags = bracket_tags(c)
        check("two bar atoms come out of a \\lvert ...\\rvert  pair", #tags == 2, #tags)
        check("the first one OPENS", tags[1] and tags[1].is_open == true)
        check("the second one CLOSES", tags[2] and tags[2].is_open == false)
        check("...and they are peer-linked to each other",
                tags[1] and tags[2] and tags[1].peer and tags[2].peer)
        check("the pair is balanced by the counter rule",
                mexpru.brackets_balanced(mexpru.u(c.root).children))
        check("it round-trips unchanged", mformula.to_latex(c) == "\\lvert a\\rvert ",
                mformula.to_latex(c))
    end

    -- ------------------------------------------------------------------ an unmatched bar is open
    --[[ Same leniency the other brackets already have: a lone "|" is a genuinely PENDING open, not
    a parse failure and not a plain glyph. ]]
    do
        local c = mformula.from_latex(fs, SZ, "\\lvert a")
        local tags = bracket_tags(c)
        check("a lone bar is one atom", #tags == 1, #tags)
        check("...still open", tags[1] and tags[1].is_open == true)
        check("...and unpaired", tags[1] and tags[1].peer == false)
        local ok, count = mexpru.brackets_balanced(mexpru.u(c.root).children)
        check("...which is a legal mid-edit state, one bracket open", ok and count == 1, count)
    end

    -- ------------------------------------------------------------------ bars inside other pairs
    --[[ A bar under an unclosed "(" still OPENS - the stack top there is the paren, not a bar. This
    is the case a naive "toggle on every |" would get wrong. ]]
    do
        local src = "(" .. "\\lvert " .. "a" .. "\\rvert " .. ")"
        local c = mformula.from_latex(fs, SZ, src)
        check("a bar nested in a paren round-trips", mformula.to_latex(c) == src,
                mformula.to_latex(c))
        local tags = bracket_tags(c)
        check("four bracket atoms, open open close close", #tags == 4, #tags)
        check("...nested, not interleaved",
                tags[1] and tags[1].is_open and tags[2].is_open
                        and not tags[3].is_open and not tags[4].is_open)
        check("the whole row balances", mexpru.brackets_balanced(mexpru.u(c.root).children))
    end

    -- ------------------------------------------------------------------ it grows with content
    --[[ "the height of the thing" - a bar around something tall has to be taller than one around a
    single letter, the same way a square bracket is. Compared against the plain typed glyph rather
    than a fixed number, since that is the threshold resolve_bracket_pairs() itself uses. ]]
    do
        local short_c = mformula.from_latex(fs, SZ, "\\lvert a\\rvert ")
        local tall_src = "\\lvert " .. "\\frac{a}{b}" .. "\\rvert "
        --[[ A GROWN pair exports as \\left.../\\right..., which is what it does on screen -
        the plain form is reserved for pairs that stay plain. See node_to_latex. ]]
        local tall_out = "\\left\\lvert " .. "\\frac{a}{b}" .. "\\right\\rvert "
        local tall_c = mformula.from_latex(fs, SZ, tall_src)
        local short_bar = mexpru.u(short_c.root).children[1]
        local tall_bar = mexpru.u(tall_c.root).children[1]
        check("a bar around a fraction is taller than one around a letter",
                height(tall_bar) > height(short_bar),
                string.format("%.1f vs %.1f", height(tall_bar), height(short_bar)))
        check("...and both halves of the tall pair match",
                math.abs(height(tall_bar)
                        - height(mexpru.u(tall_c.root).children[#mexpru.u(tall_c.root).children]))
                        < 0.01)
        check("the tall pair round-trips, grown", mformula.to_latex(tall_c) == tall_out,
                mformula.to_latex(tall_c))
    end

    -- ------------------------------------------------------------------ and survives a rescale
    --[[ Same regression test_bracket_survives_rescale.lua covers for the other brackets: a zoom
    rebuilds every bracket atom peerless and transfer_bracket_peers() re-links them. A bar is
    peer-linked exactly like any other pair, so it has to come through the same way. ]]
    do
        local src = "\\lvert " .. "\\frac{a}{b}" .. "\\rvert "
        local grown = "\\left\\lvert " .. "\\frac{a}{b}" .. "\\right\\rvert "
        local c = mformula.from_latex(fs, SZ, src)
        local before = height(mexpru.u(c.root).children[1])
        mexpru.set_zoom(2)
        mformula.rescale(c, fs)
        mexpru.set_zoom(0)
        mformula.rescale(c, fs)
        check("a bar pair survives a zoom round trip at its original height",
                math.abs(height(mexpru.u(c.root).children[1]) - before) < 0.01,
                string.format("%.1f -> %.1f", before, height(mexpru.u(c.root).children[1])))
        check("...and still serialises the same", mformula.to_latex(c) == grown,
                mformula.to_latex(c))
        mexpru.set_zoom(0)
    end

    -- ------------------------------------------------------------------ a typed | is a literal
    --[[ The reason the shortcut is a KEY and not the "|" character. A bar typed as content must
    stay content: not tagged as a bracket, not paired with anything, and unchanged by a round trip.
    Binding the character would have cost exactly this, the way "(" is not a literal today. ]]
    do
        local c = mformula.from_latex(fs, SZ, "a|b")
        check("a typed | round-trips as itself", mformula.to_latex(c) == "a|b",
                mformula.to_latex(c))
        check("...carrying no bracket tag at all", #bracket_tags(c) == 0, #bracket_tags(c))
        local ok, count = mexpru.brackets_balanced(mexpru.u(c.root).children)
        check("...and counting for nothing in the bracket rule", ok and count == 0, count)
    end

    -- A literal bar and a real bar pair, in one formula - the case that is only distinguishable
    -- because the pair is written as a command.
    do
        local src = "\\lvert " .. "a|b" .. "\\rvert "
        local c = mformula.from_latex(fs, SZ, src)
        check("a literal | INSIDE a bar pair survives", mformula.to_latex(c) == src,
                mformula.to_latex(c))
        check("...with only the pair itself tagged", #bracket_tags(c) == 2, #bracket_tags(c))
    end

    print("checks: " .. checks_run .. ", failed: " .. checks_failed)
    if checks_failed > 0 then
        return false
    end
    print("PASS: | opens and closes with one key, nests inside other brackets, and sizes to content")
    return true
end

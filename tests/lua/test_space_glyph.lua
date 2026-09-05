--[[
test_space_glyph.lua - a space must take horizontal room and NO vertical room.

Two halves of the same rule, each broken once:

  * WIDTH. A space has no ink, so char_get_bb() hands back an empty box and the node laid out
    zero-wide - "a", Space, "b" rendered as "ab". mexpr_symbol falls back to the font's own advance
    when there is no ink to measure.

  * HEIGHT. Fixing the width left the box a zero-HEIGHT one parked wherever the 'a'-centring
    symb_off put it - y = -21.5 at size 12, a full 12 units above the tallest ordinary glyph. It
    unioned into its row from up there and dragged the row's top edge with it, so a row holding
    "1" and a space came out 29 units tall instead of 17, all of the extra above the digit. Inside
    a vert, whose rows are centred in their cells, that pushed the "1" down by half the difference.
    Reported live 2026-09-05: "after adding space the 1 seems to go down for some reason... it is a
    posibility that space may be malformed". mexpr_symbol now flattens an inkless glyph's box onto
    y = 0, the centre line every real glyph's box already straddles.

The vert case is kept here rather than in test_vert.lua on purpose: the defect is the space glyph's,
and a stack is only where it became visible.
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

local function glyph(fs, ascii)
    local e = char.find_by_ascii(ascii)
    local g = mexpru.mexpr_symbol(fs, {size = mexpru.physical_sz(SZ), code = e.ncod}, true)
    mexpru.u(g).sz = SZ
    return g
end

local function box(node)
    local b = vc.mexpr_get_bb(node)
    return b, b.br.x - b.tl.x, b.br.y - b.tl.y
end

function run_test()
    local fs = char.load_font_set()

    -- ---------------------------------------------------------------- the glyph itself
    do
        local b, w, h = box(glyph(fs, " "))
        check("a space is as wide as the font's own advance", w > 0, w)
        check("a space has no height of its own", math.abs(h) < 0.01, h)
        check("...and that empty box sits ON the centre line, not above everything",
                math.abs(b.tl.y) < 0.01 and math.abs(b.br.y) < 0.01,
                string.format("tl.y=%.2f br.y=%.2f", b.tl.y, b.br.y))
    end

    -- ---------------------------------------------------------------- a row containing one
    do
        local _, w1, h1 = box(mexpru.horiz(fs, {glyph(fs, "1")}, SZ))
        local _, w2, h2 = box(mexpru.horiz(fs, {glyph(fs, "1"), glyph(fs, " ")}, SZ))
        check("adding a space makes its row wider", w2 > w1, string.format("%.2f vs %.2f", w2, w1))
        check("adding a space does NOT make its row taller", math.abs(h2 - h1) < 0.01,
                string.format("%.2f vs %.2f", h2, h1))
    end

    -- ---------------------------------------------------------------- and inside a vert cell
    --[[ The symptom as actually reported: the glyph itself moves. Its offset within the stack is
    what the eye reads as "the 1 went down", so that is what gets compared - not just the row box. ]]
    do
        local function digit_offset(with_space)
            local c = mformula_new.new(fs, SZ)
            mformula_new.make_vert(c, fs, SZ)
            local g = glyph(fs, "1")
            c.root = mexpru.propagate_rebuild(fs, c.cursor_pos:get_obj(), g)
            c.cursor_pos = vc.wref_mexpr(g)
            if with_space then
                local horiz = g:get_parent()
                local kids = mexpru.u(horiz).children
                kids[#kids + 1] = glyph(fs, " ")
                c.root = mexpru.propagate_rebuild(fs, horiz, mexpru.horiz(fs, kids, SZ))
            end
            local vert
            for _, ch in ipairs(mexpru.u(c.root).children) do
                if mexpru.u(ch).kind == "vert" then vert = ch end
            end
            local _, off = table.unpack(vert:anchor_at(1))
            -- Where the digit's own ink lands, in the stack's frame.
            local slot = mexpru.u(vert).slots[1]
            return off.y + vc.mexpr_get_bb(slot).tl.y
        end
        local without, with = digit_offset(false), digit_offset(true)
        check("a space does not move the digit beside it inside a cell",
                math.abs(with - without) < 0.01, string.format("%.2f vs %.2f", with, without))
    end

    print("checks: " .. checks_run .. ", failed: " .. checks_failed)
    if checks_failed > 0 then
        return false
    end
    print("PASS: space glyph - takes width, takes no height, moves nothing beside it")
    return true
end

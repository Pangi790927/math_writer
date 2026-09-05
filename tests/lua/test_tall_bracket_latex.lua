--[[
test_tall_bracket_latex.lua - to_latex() has to round-trip a bracket pair whose content is TALL,
not just a short one.

Reported live, 2026-09-05 ("reached an invalid state and reproduced it in a separate box"), found
by dumping content.serialize() after each replayed keystroke rather than screenshotting: typing
"((a))" and then giving the "a" a superscript came back out of to_latex() as "!(a^{i}!)" - the
OUTER pair's two atoms both serialized as "!", the inner pair's (still short) came out fine.

Root cause: resolve_bracket_pairs() (mexpru.lua) only keeps a pair's PLAIN typed "("/")" glyphs
while its content stays short enough for one (its own pixel-identical sizing rule, 2026-09-05) -
the moment the content grows taller it swaps BOTH atoms for the TIERED glyphs
mexpr_bracket_left()/_right() build (math_expr_composer.h). Those carry no meaningful
node.symb.code, and node_to_latex()'s MEXPR_TYPE_SYMBOL branch read it back as 0 - char.lua's very
FIRST table entry, "!". Purely a serialization bug (the on-screen tree was always correct and
still rendered fine), but to_latex() is what BOTH math_writer.save and Ctrl+C are built on, so it
silently corrupted on SAVE - reloading gave back a formula full of "!" with no brackets at all.

The fix reads u(_).bracket's own is_open/type tag instead of reverse-mapping the glyph - which is
what makes it representation-independent, so this test deliberately checks BOTH regimes: the short
pair (plain glyphs, worked before) AND the tall one (tiered glyphs, the actual regression), since
only checking the short case is exactly what let this slip through in the first place.
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

local function glyph(fs, ascii, sz)
    local entry = char.find_by_ascii(ascii)
    local g = mexpru.mexpr_symbol(fs, {size = sz, code = entry.ncod}, true)
    mexpru.u(g).sz = sz
    return g
end

-- A resolved pair around `inner`, exactly the shape try_close_bracket() produces (a pending open +
-- a peer-linked close, handed to mexpru.horiz(), whose resolve_bracket_pairs() then picks plain vs
-- tiered glyphs itself based on how tall `inner` actually is - the whole point of this test).
local function bracketed(fs, inner, sz)
    local open_atom = glyph(fs, "(", sz)
    mexpru.u(open_atom).bracket = {is_open = true, type = vc.MEXPR_BRACKET_ROUND}
    local close_atom = glyph(fs, ")", sz)
    mexpru.u(close_atom).bracket = {is_open = false, type = vc.MEXPR_BRACKET_ROUND, peer = mexpru.u(open_atom)}
    mexpru.u(open_atom).bracket.peer = mexpru.u(close_atom)

    local list = {open_atom}
    for _, n in ipairs(inner) do
        list[#list + 1] = n
    end
    list[#list + 1] = close_atom
    return list
end

function run_test()
    local fs = char.load_font_set()
    local SZ = 12

    -- SHORT content: one plain letter. resolve_bracket_pairs() keeps the plain "("/")" glyphs -
    -- the regime that already worked before the fix.
    do
        local root = mexpru.horiz(fs, bracketed(fs, {glyph(fs, "a", SZ)}, SZ), SZ)
        mexpru.update_positions(root)
        local latex = mformula_new.to_latex({root = root})
        check("short pair round-trips as (a)", latex == "(a)", latex)
    end

    -- TALL content: "a" with a superscript, which pushes the pair over resolve_bracket_pairs()'s
    -- own plain-paren height threshold and into the TIERED glyphs - the exact regression.
    do
        local base = glyph(fs, "a", SZ)
        local sup = mexpru.horiz(fs, {glyph(fs, "i", SZ - 2)}, SZ - 2)
        local supsub_node = mexpru.supsub(fs, base, sup, nil)

        local root = mexpru.horiz(fs, bracketed(fs, {supsub_node}, SZ), SZ)
        mexpru.update_positions(root)

        local children = mexpru.u(root).children
        check("setup: the pair is still exactly open/content/close", #children == 3)
        check("setup: both atoms still carry their own bracket tag",
                mexpru.u(children[1]).bracket ~= nil and mexpru.u(children[3]).bracket ~= nil)

        local latex = mformula_new.to_latex({root = root})
        check("tall pair round-trips as (a^{i}) - NOT \"!\"", latex == "(a^{i})", latex)
        check("no stray '!' anywhere in the output", not latex:find("!", 1, true), latex)
    end

    -- Nested, both regimes at once - the shape actually reported ("((a^{i}))"): the INNER pair
    -- stays short/plain, the OUTER one goes tiered. Before the fix this came out "!(a^{i}!)".
    do
        local base = glyph(fs, "a", SZ)
        local sup = mexpru.horiz(fs, {glyph(fs, "i", SZ - 2)}, SZ - 2)
        local supsub_node = mexpru.supsub(fs, base, sup, nil)

        local inner_list = bracketed(fs, {supsub_node}, SZ)
        local inner_horiz_children = bracketed(fs, inner_list, SZ)
        local root = mexpru.horiz(fs, inner_horiz_children, SZ)
        mexpru.update_positions(root)

        local latex = mformula_new.to_latex({root = root})
        check("nested pairs round-trip as ((a^{i}))", latex == "((a^{i}))", latex)
    end

    print("checks: " .. checks_run .. ", failed: " .. checks_failed)
    if checks_failed > 0 then
        return false
    end
    print("PASS: bracket pairs round-trip through to_latex() in BOTH the plain-glyph and "
            .. "tiered-glyph regimes")
    return true
end

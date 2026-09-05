--[[
test_wrap_supsub_base.lua - closing a PENDING bracket while the cursor sits on a supsub's own base
puts the ")" in AS that base, bumping the old base out in front of it: "(a^{N}" closed there
becomes "(a)^{N}", not "(a^{N})".

Reported live, 2026-09-05: "(a)^N can't be written after the exponent was added so from a^N".
Measured first, by replaying a^{N} three ways and dumping the serialized result after each keystroke:
  - "(" with the cursor on the base   -> "a^{N}"    (refused - an open bracket may never be a base)
  - "(" at the start, then ")"        -> "(a^{N})"  (exponent INSIDE the parens - a different formula)
  - "(" "a" ")" typed BEFORE the sup  -> "(a)^{N}"  (the only route that ever worked)
so the shape was reachable only if you happened to bracket before adding the exponent.

Scope is deliberately the CLOSING half only - verbatim, on exactly this point: "I want only to be
able to close after base, not to open there". Nothing here ever conjures an opening bracket: you
open where you always could (before the whole compound), walk to the base, and close there, and the
two brackets you end up with are the two you typed. An earlier attempt at this made ")" on a base
insert BOTH brackets at once, which is what that correction rejected.

The distinction being tested is that LEGALITY and PLACEMENT differ for this cursor position.
base_of()'s "a base reads as occupying its supsub's slot" convention is right for deciding whether
the close is allowed at all (the supsub is what really sits in the flat list next to the open
bracket) but wrong for deciding where the glyph GOES - following it there is what used to drop the
")" after the whole compound.

try_close_bracket() isn't exported (real keypress-driven, same as every other handle_input-adjacent
test here), so this mirrors that branch's own splice.
]]

package.path = package.path .. ";./scripts/?.lua"

local vc = require("virt_composer")
local char = require("char")
local mexpru = require("mexpru")
local mformula_new = require("mformula_new")
local same = mexpru.same

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

--[[ "<prefix>( a^{N}" - a genuinely PENDING open bracket (no peer) sitting before a supsub, i.e.
exactly the mid-edit state you reach by having a^{N}, walking to the very start and typing "(". ]]
local function build_pending(fs, sz, prefix_ascii)
    local A = glyph(fs, "a", sz)
    local sup = mexpru.horiz(fs, {glyph(fs, "N", sz - 2)}, sz - 2)
    local supsub_node = mexpru.supsub(fs, A, sup, nil)

    local open_atom = glyph(fs, "(", sz)
    mexpru.u(open_atom).bracket = {is_open = true, type = vc.MEXPR_BRACKET_ROUND}   -- pending

    local kids = {}
    if prefix_ascii then
        kids[#kids + 1] = glyph(fs, prefix_ascii, sz)
    end
    kids[#kids + 1] = open_atom
    kids[#kids + 1] = supsub_node

    local root = mexpru.horiz(fs, kids, sz)
    mexpru.update_positions(root)
    return {root = root, cursor_pos = vc.wref_mexpr(A), version = 0}, supsub_node, A, open_atom
end

-- Mirrors try_close_bracket()'s own closing_onto_base splice: the ")" becomes the supsub's base and
-- the old base moves out to the slot the supsub used to occupy.
local function close_onto_base(fs, container, supsub_node, open_atom, sz)
    local outer_horiz = supsub_node:get_parent()
    local children = mexpru.u(outer_horiz).children
    local idx = supsub_node:get_parent_idx()
    local old_base = mexpru.u(supsub_node).base

    local c = glyph(fs, ")", sz)
    mexpru.u(c).bracket = {is_open = false, type = vc.MEXPR_BRACKET_ROUND,
            peer = mexpru.u(open_atom)}
    mexpru.u(open_atom).bracket.peer = mexpru.u(c)

    local u = mexpru.u(supsub_node)
    children[idx] = mexpru.supsub(fs, c, u.sup, u.sub)
    table.insert(children, idx, old_base)

    local rebuilt = mexpru.horiz(fs, children, mexpru.u(outer_horiz).sz)
    container.root = mexpru.propagate_rebuild(fs, outer_horiz, rebuilt)
    mexpru.update_positions(container.root)
    return c, old_base
end

function run_test()
    local fs = char.load_font_set()
    local SZ = 12

    -- The reported case: "(a^{N}" with the cursor on the base, closed -> "(a)^{N}".
    do
        local container, supsub_node, A, open_atom = build_pending(fs, SZ, nil)
        check("setup: starts as the pending \"(a^{N}\"",
                mformula_new.to_latex(container) == "(a^{N}", mformula_new.to_latex(container))

        local c, old_base = close_onto_base(fs, container, supsub_node, open_atom, SZ)
        check("old base really was the \"a\"", same(old_base, A))

        local latex = mformula_new.to_latex(container)
        check("closes to (a)^{N} - NOT (a^{N})", latex == "(a)^{N}", latex)

        local kids = mexpru.u(container.root).children
        check("three flat slots: \"(\", \"a\", supsub", #kids == 3)
        check("the \")\" is the supsub's own BASE, not a flat sibling",
                mexpru.u(kids[3]).kind == "supsub"
                and mexpru.u(mexpru.u(kids[3]).base).bracket ~= nil
                and mexpru.u(mexpru.u(kids[3]).base).bracket.is_open == false)
        check("\"a\" moved out to be an ordinary flat sibling",
                same(kids[2], A) and mexpru.u(kids[2]).bracket == nil)
        check("both brackets peer-link to each other - a real pair, not two loose glyphs",
                mexpru.u(open_atom).bracket.peer == mexpru.u(c)
                and mexpru.u(c).bracket.peer == mexpru.u(open_atom))
        check("the sup survived untouched", mexpru.u(kids[3]).sup ~= nil)
    end

    -- Only the base is enclosed, not whatever precedes the open bracket: "x(a^{N}" -> "x(a)^{N}".
    do
        local container, supsub_node, _, open_atom = build_pending(fs, SZ, "x")
        check("setup: starts as \"x(a^{N}\"",
                mformula_new.to_latex(container) == "x(a^{N}", mformula_new.to_latex(container))
        close_onto_base(fs, container, supsub_node, open_atom, SZ)
        local latex = mformula_new.to_latex(container)
        check("x stays outside the pair", latex == "x(a)^{N}", latex)
    end

    print("checks: " .. checks_run .. ", failed: " .. checks_failed)
    if checks_failed > 0 then
        return false
    end
    print("PASS: closing on a supsub's base lands the \")\" as that base - (a)^{N} from a^{N}")
    return true
end

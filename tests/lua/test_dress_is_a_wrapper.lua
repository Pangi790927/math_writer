--[[
test_dress_is_a_wrapper.lua - a dress forwards navigation to what it holds; it is not an atom.

The original design made a dress opaque - "a dressed element simply takes the place of the target
glyph and is else considered an atom itself". That is indistinguishable from wrapping for as long as
the target is a GLYPH, since a glyph is one cursor position either way, which is why it held up
until a stack got dressed. "\hat{\stack{AB}{CD}}" then put a whole navigable structure behind a
single atom: no click could reach a row, and Up/Down would not enter it.

Reported live 2026-09-06, first as "clicking inside a vector does not seem to recurse for cursor
positioning" and then, correctly, as the deeper thing: "a ^ can't be considered as a glyph, that is
the problem, ok, we need to work this in reverse, a dress should act as a wrapper, it should forward
most of the navigation to the held value".

"Most" is the important word, and this pins both halves of it:

  - DOWNWARD (descent) the dress is transparent - a click and Up/Down pass straight through to the
    held value, whatever it is.
  - UPWARD it is still the atom occupying its slot: the row holds the dress, Left/Right step over
    the whole thing as one unit, and slot_atom() reports a bracket or a sprint landmark through it.
    The decoration itself is never a cursor destination in either direction, which is the part of
    the original design that does not change.

The regression guard that matters most is the dressed GLYPH: forwarding must not alter it, or every
existing accent behaves differently than it did.
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
local BS = string.char(92)

-- What the cursor is sitting on, as something readable.
local function where(c)
    local n = c.cursor_pos and c.cursor_pos:get_obj()
    if not n then
        return "nil"
    end
    if n.type == vc.MEXPR_TYPE_SYMBOL then
        local e = char.find_by_ncod(n.symb.code)
        return "glyph:" .. (e and e.desc or "?")
    end
    return tostring(mexpru.u(n).kind or ("type" .. tostring(n.type)))
end

-- Is `node` inside `ancestor` (or is it)? Ancestry, rather than an exact glyph, is what a click
-- test should assert here: which ROW it reached is the question, and pinning the precise landing
-- would just re-test hit_test's own within-a-row rules, which test_hit_test.lua already owns.
local function is_within(node, ancestor)
    while node do
        if mexpru.same(node, ancestor) then
            return true
        end
        node = node:get_parent()
    end
    return false
end

local function root_child(c)
    return mexpru.u(c.root).children[1]
end

function run_test()
    local fs = char.load_font_set()

    -- ---------------------------------------------------------------- Up/Down enter the held value
    do
        local c = mformula.from_latex(fs, SZ, BS .. "hat{" .. BS .. "stack{AB}{CD}}")
        mexpru.update_positions(c.root)
        local dress = root_child(c)
        check("setup: the row holds a dress", mexpru.u(dress).kind == "dress",
                mexpru.u(dress).kind)
        check("setup: it wraps a vert", mexpru.u(mexpru.u(dress).target).kind == "vert",
                mexpru.u(mexpru.u(dress).target).kind)

        --[[ Resting ON the dressed stack. Down has to enter the stack's bottom row, exactly as it
        would for an undressed one - before the wrapper change it went nowhere, because the dress
        matched none of the "can I descend into this" branches. ]]
        c.cursor_pos = vc.wref_mexpr(dress)
        mformula.move_down(c)
        check("Down enters the dressed stack's BOTTOM row", where(c) == "glyph:D", where(c))

        c.cursor_pos = vc.wref_mexpr(dress)
        mformula.move_up(c)
        check("Up enters its TOP row", where(c) == "glyph:B", where(c))
    end

    -- ---------------------------------------------------------------- and so does a click
    --[[ hit_test()'s entry point wants the click relative to draw()'s own pos, i.e. before the
    baseline correction node_bbox() already carries - the same conversion test_hit_test.lua does. ]]
    do
        local a = char.find_by_ascii("a")
        local a_sz = fs:char_get_sz({size = SZ, code = a.ncod})
        local bc = (a_sz.tr.y + a_sz.bl.y) / 2

        local c = mformula.from_latex(fs, SZ, BS .. "hat{" .. BS .. "stack{AB}{CD}}")
        mexpru.update_positions(c.root)
        local dress = root_child(c)
        local slots = mexpru.u(mexpru.u(dress).target).slots
        check("setup: two rows", #slots == 2, #slots)

        for i = 1, 2 do
            --[[ Aimed at each row's own middle, taken from the row's real box rather than guessed
            from the dress's - the dress's box includes the hat, so a fraction of ITS height would
            not name a row. ]]
            local bb = vc.mexpr_get_bb(slots[i])
            local pos = mexpru.u(slots[i]).pos
            local click = {
                x = pos.x + bb.tl.x + 1,
                y = pos.y + (bb.tl.y + bb.br.y) / 2 + bc,
            }
            c.cursor_pos = vc.wref_mexpr(c.root)
            mformula.hit_test(c, fs, SZ, click)
            check("a click in row " .. i .. " lands inside the dressed stack, not on the dress",
                    where(c) ~= "dress", where(c))
            check("...specifically inside that row",
                    is_within(c.cursor_pos:get_obj(), slots[i]), where(c))
        end
    end

    -- ---------------------------------------------------------------- a dressed GLYPH is unchanged
    --[[ The regression guard. Forwarding to a glyph has to be indistinguishable from the old opaque
    behaviour, since a glyph is a single position either way - otherwise every accent that already
    worked starts behaving differently. ]]
    do
        local c = mformula.from_latex(fs, SZ, "x" .. BS .. "hat{y}z")
        mexpru.update_positions(c.root)
        local children = mexpru.u(c.root).children
        check("setup: three atoms, the middle one dressed", #children == 3
                and mexpru.u(children[2]).kind == "dress", #children)

        -- Left/Right step OVER it as one unit: from the dress, one Left is "x", not its target.
        c.cursor_pos = vc.wref_mexpr(children[2])
        mformula.move_left(c)
        check("Left from a dressed glyph steps over the whole thing", where(c) == "glyph:x",
                where(c))
        mformula.move_right(c)
        check("...and Right comes back to the dress itself", where(c) == "dress", where(c))
    end

    -- ---------------------------------------------------------------- no dressing a dress
    --[[ A consequence of the cursor being able to rest INSIDE a dress now: an accent pressed there
    must toggle the one the atom already wears, not wrap it again into "\hat{\hat{x}}". ]]
    do
        local c = mformula.from_latex(fs, SZ, BS .. "hat{x}")
        mexpru.update_positions(c.root)
        local dress = root_child(c)
        c.cursor_pos = vc.wref_mexpr(mexpru.u(dress).target)   -- inside it, on the "x"

        mformula.toggle_accent(c, fs, "hat")
        check("an accent from inside toggles the existing one OFF, not a second one on",
                mformula.to_latex(c) == "x", mformula.to_latex(c))

        -- And a different accent from inside replaces rather than nesting.
        local d = mformula.from_latex(fs, SZ, BS .. "hat{x}")
        mexpru.update_positions(d.root)
        d.cursor_pos = vc.wref_mexpr(mexpru.u(root_child(d)).target)
        mformula.toggle_accent(d, fs, "tilde")
        check("...and a different one replaces it", mformula.to_latex(d) == BS .. "tilde{x}",
                mformula.to_latex(d))
    end

    print("checks: " .. checks_run .. ", failed: " .. checks_failed)
    if checks_failed > 0 then
        return false
    end
    print("PASS: a dress forwards descent to what it holds, and is still one atom from outside")
    return true
end

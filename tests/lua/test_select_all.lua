--[[
test_select_all.lua - Ctrl+A inside a formula covers the WHOLE top-level row.

THE ASSUMPTION, and it is a structural one rather than a behavioural one: anchoring ON the horiz
itself means "before everything". Slot numbering in a row runs 0..#children, where 0 is the horiz
node standing for the position before the first child (slot_of()'s own convention, shared by the
cursor, by extend_selection and by selection_range). So anchor-at-the-horiz plus cursor-at-the-last
child is the full range 1..#children, and select_all does not count anything itself.

WHY THAT IS WORTH A TRIPWIRE. If slot 0 ever stops meaning "before everything" - say the horiz starts
reading as slot 1, or an empty row grows a placeholder child - this keeps returning a range and the
range is quietly short by one. Nothing visible breaks; a select-all just stops including the first
glyph, which is the kind of defect that gets blamed on the mouse for a week. The assertion is
therefore about the RANGE, not about "a selection exists".

THE ROOT ROW, NOT THE CARET'S ROW. A selection may never leave its horiz, so with the caret inside a
sup "all" has two readings; the one implemented is the formula, and the caret moves out to the root
row to make it expressible. Asked for that way, 2026-09-11: "mace ctrl+a select all text in a formula
box" - a box, not a row.

Driving it through the exported mutator rather than the keypress: handle_input() needs a live ImGui
for keymap.pressed(), which no test has.
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

function run_test()
    local fs = char.load_font_set()
    local function row(src)
        return mformula_latex.from_latex(fs, SZ, src)
    end

    -- ------------------------------------------------------------------ the whole row
    do
        local c = row("a+bc")
        local kids = mexpru.u(c.root).children
        check("setup: four slots", #kids == 4, #kids)

        --[[ The caret starts somewhere in the middle, so "all" cannot come from where it was. ]]
        c.cursor_pos = vc.wref_mexpr(kids[2])
        check("select_all reports it did something", mformula_new.select_all(c) == true)

        local horiz, lo, hi = mformula_new.selection_range(c)
        check("the range is the whole row", horiz ~= nil and lo == 0 and hi == #kids,
                tostring(lo) .. ".." .. tostring(hi))
        check("...and it is the root row it covers",
                horiz ~= nil and mexpru.same(horiz, c.root))
    end

    -- ------------------------------------------------------------------ from inside a sup
    do
        --[[ `a^{b+c}` with the caret in the exponent. The selection cannot span both rows, so the
        answer is the formula and the caret leaves the sup - which is what makes it expressible at
        all. Were this to select the sup's own row instead, the range below would be 2 wide. ]]
        local c = row("a^{b+c}")
        local kids = mexpru.u(c.root).children
        local sup = mexpru.u(kids[#kids])
        local inner = sup.sup and mexpru.u(sup.sup).children
        check("setup: the exponent is a row of its own", inner ~= nil and #inner >= 3,
                inner and #inner)
        if inner then
            c.cursor_pos = vc.wref_mexpr(inner[2])
            mformula_new.select_all(c)
            local horiz, lo, hi = mformula_new.selection_range(c)
            check("a caret in a sup still selects the formula",
                    horiz ~= nil and mexpru.same(horiz, c.root) and lo == 0 and hi == #kids,
                    tostring(lo) .. ".." .. tostring(hi))
        end
    end

    -- ------------------------------------------------------------------ the empty formula
    do
        --[[ A formula is never a row with NO slots - an empty one holds a placeholder atom, which
        mexpr_merge_h insists on ("can't use mexpr_merge_h without at least one node"). So the
        degenerate case is one slot, not zero, and selecting it is the right answer rather than a
        refusal: the run is what a Ctrl+A then Backspace would clear. The `not last` guard in
        select_all stays as a guard, not as behaviour anything asserts. ]]
        local c = row("")
        local kids = mexpru.u(c.root).children
        check("an empty formula still has a slot", #kids >= 1, #kids)
        check("select_all takes it", mformula_new.select_all(c) == true)
        local horiz, lo, hi = mformula_new.selection_range(c)
        check("...as the whole row", horiz ~= nil and lo == 0 and hi == #kids,
                tostring(lo) .. ".." .. tostring(hi))
    end

    if checks_failed == 0 then
        print("PASS: ctrl+a covers the formula (" .. checks_run .. " checks)")
    end
    return checks_failed == 0
end

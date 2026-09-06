--[[
test_formula_line_fit.lua - a formula must never be handed a zero-or-negative content column.

Reported live 2026-09-05 as "too large of a zoom out crashes the application". It is not a crash and
not the integral: it is a HANG, and it is reproducible from a 21-byte document. Save
"$$x+y$$$$a+b$$$$c+d$$" as one box and press Ctrl+MouseWheel eleven times towards the big end - at
that size the first formula fills the column, so the second is laid out at an x that is already past
the wrap edge, and the app wedges at 100% of one core with flat memory and no error line.

The wedge is in mexpr_draw_rec() (math_expr_composer.h): it wraps a node by stepping it left one
column width per row until it lands inside the column, and when that width is zero or negative the
step is zero or positive, so the node never moves in and the loop never ends.

editor.lua's draw() had no line-break rule for formulas at all - plain glyphs had one, formulas were
simply drawn wherever the line had got to. formula_line_fit() is now that rule, shared by both of
draw()'s passes (they must agree about which line a formula lands on), and it also floors the column
it hands back so even a box too narrow for one is not degenerate.

draw() itself needs a real ImGui frame, so this tests the rule rather than the drawing: the floor is
what makes the hang unreachable, and it is a property that holds for every position on the line, not
just the one that happened to be reported.

The C++ loop should ALSO refuse to run on a non-positive column - a layout bug must not be able to
hang the whole app - but that is a change to math_expr_composer.h, and this repo's rule is that
those get suggested rather than written here. This test guards the Lua half.
]]

package.path = package.path .. ";./scripts/?.lua"

local editor = require("editor")

local checks_run, checks_failed = 0, 0
local function check(name, cond, got)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name .. (got ~= nil and ("  (got: " .. tostring(got) .. ")") or ""))
    end
end

-- The one field formula_line_fit() reads off draw()'s metrics table.
local function metrics(line_height)
    return {line_height = line_height}
end

function run_test()
    local m = metrics(20)

    -- ------------------------------------------------------------------ the hang, as a property
    --[[ Every position the layout can actually reach on a line, including the ones past the wrap
    edge that used to produce a zero or negative column. There is no position at which a formula may
    be handed a column that mexpr_draw_rec() cannot escape. ]]
    for _, width_limit in ipairs({40, 120, 500, 1000}) do
        for used = 0, width_limit + 60, 5 do
            local _, column = editor.formula_line_fit(m, width_limit, used)
            check(string.format("width_limit=%d used=%d yields a POSITIVE column",
                    width_limit, used), column > 0, column)
        end
    end

    -- A box narrower than the floor itself - the case a line break cannot rescue, since there is no
    -- roomier line to move to. Still must not come back degenerate.
    do
        local _, column = editor.formula_line_fit(metrics(20), 5, 0)
        check("a box narrower than the floor still yields a positive column", column > 0, column)
    end

    -- ------------------------------------------------------------------ the line-break rule
    do
        local width_limit = 500
        local broke, column = editor.formula_line_fit(m, width_limit, 0)
        check("at the START of a line a formula never breaks", broke == false, broke)
        check("...and gets the whole column", column == width_limit - 2 * 4, column)

        broke = editor.formula_line_fit(m, width_limit, 100)
        check("with plenty of room left it does not break", broke == false, broke)

        broke, column = editor.formula_line_fit(m, width_limit, width_limit - 4)
        check("with no usable room left it breaks to the next line", broke == true, broke)
        check("...and is then measured against a full line, not the sliver it broke out of",
                column == width_limit - 2 * 4, column)

        --[[ The break is decided against the SAME floor the column is granted, so a formula can
        never break onto a line that would immediately break again - which would be a second way to
        hang, in Lua this time. ]]
        local at_threshold = width_limit - 2 * 4 - m.line_height
        check("just above the threshold: no break", editor.formula_line_fit(m, width_limit, at_threshold - 1) == false)
        check("just below it: break", editor.formula_line_fit(m, width_limit, at_threshold + 1) == true)
    end

    -- ------------------------------------------------------------------ unlimited width
    do
        local broke, column = editor.formula_line_fit(m, nil, 300)
        check("with no width limit there is nothing to break against", broke == false, broke)
        check("...and no column is imposed", column == nil, column)
    end

    -- ------------------------------------------------------------------ the floor tracks the font
    --[[ A pixel constant would stop being a usable column the moment the zoom changed, which is the
    exact circumstance the hang was reported from. ]]
    do
        local _, small = editor.formula_line_fit(metrics(10), 5, 0)
        local _, large = editor.formula_line_fit(metrics(80), 5, 0)
        check("the floor scales with the line height", large > small,
                string.format("%.1f vs %.1f", large, small))
    end

    print("checks: " .. checks_run .. ", failed: " .. checks_failed)
    if checks_failed > 0 then
        return false
    end
    print("PASS: a formula is never handed a column mexpr_draw_rec() cannot wrap out of")
    return true
end

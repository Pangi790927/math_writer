--[[
test_click_line_first.lua - a click in the text editor picks its LINE before it picks its column,
and nothing about the column can change which line it picked.

THE ASSUMPTION. editor_text.nearest_position() answers a click in two strictly ordered steps: the
line whose vertical band the point is in (or nearest to), then the nearest gap on that line alone.
Requested 2026-09-09: "when you click your cursor goes to the nearest line first, nearest column
after, this is different of how it works and should work inside formulas".

WHAT IT REPLACED, and why the replacement needs an alarm rather than just a diff. The old rule was
one blended number - |dx| + dy, plus a big penalty once dy passed a single global line height - and
it was WRONG IN TWO WAYS THAT LOOK LIKE ROUNDING. A line grown to hold a formula is taller than
that one global height, so a click low inside it scored as belonging to a different line. And a
large enough horizontal difference outvoted a small vertical one, so a click just below a short
line could land on the short line because some gap up there sat nearer the pointer. Both produce a
caret one line away from where somebody aimed - the kind of thing that reads as the app being
slightly drunk rather than as a bug worth reporting, and the kind of thing a future refactor could
reintroduce by "simplifying" the two loops back into one.

This is deliberately NOT the rule inside a formula, where the cursor walks a tree and "the line
above" names nothing - mformula.hit_test() owns that and is untouched. A test that starts asserting
line-first behaviour for formula internals is asserting the wrong thing.

The positions here are handmade rather than produced by draw(), which needs a real ImGui frame.
That is the point: the geometry is chosen to make the two failure modes above fire, which real
typing only does by accident.
]]

package.path = package.path .. ";./scripts/?.lua"

local editor = require("editor_text")

local checks_run, checks_failed = 0, 0
local function check(name, cond, got)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name .. (got ~= nil and ("  (got: " .. tostring(got) .. ")") or ""))
    end
end

--[[ One line's worth of recorded gaps. `top` is the text top (what draw() calls line_top), and the
band runs from top - up to top + down, the same way a line carrying a formula reaches past its own
text on both sides. `xs` are the gap positions along it, `base` the char index the first one has. ]]
local function line(out, top, up, down, xs, base)
    for k, x in ipairs(xs) do
        out[#out + 1] = {x = x, y = top, i = base + k - 1,
                         y0 = top - up, y1 = top + down}
    end
    return out
end

function run_test()
    local at = editor.nearest_position

    -- ------------------------------------------------- two plain lines, 20 tall, no overhang
    do
        local ps = {}
        line(ps, 100, 0, 20, {0, 50, 100, 150}, 0)     -- indices 0..3
        line(ps, 120, 0, 20, {0, 50, 100, 150}, 10)    -- indices 10..13
        local state = {last_positions = ps}

        check("a click inside the first line lands on it", at(state, {x = 52, y = 105}) == 1)
        check("a click inside the second lands on that one", at(state, {x = 52, y = 125}) == 11)

        --[[ THE OUTVOTING CASE. The point sits in line one, but line two has a gap FAR nearer
        horizontally. Under a blended distance that gap wins; under line-first it cannot even be
        considered. ]]
        local ps2 = {}
        line(ps2, 100, 0, 20, {0}, 0)                  -- line one: one gap, far left
        line(ps2, 120, 0, 20, {0, 300}, 10)            -- line two: one gap right under the click
        local state2 = {last_positions = ps2}
        check("a gap on another line cannot win on x alone",
                at(state2, {x = 300, y = 105}) == 0, at(state2, {x = 300, y = 105}))

        --[[ ...and the column still decides once the line is settled, so this is not just
        "always answer the first line". ]]
        check("within the chosen line, the nearest column wins",
                at(state, {x = 149, y = 105}) == 3)
        check("...and the nearest is by distance, not by rounding down",
                at(state, {x = 26, y = 105}) == 1)
    end

    -- ------------------------------ a line grown to hold a formula owns its whole height
    do
        --[[ THE TALL-LINE CASE. Line two carries something 60px tall reaching ABOVE its text top,
        exactly as line_extra_top does for a formula. A click up in that overhang is inside line
        two's band and outside line one's, so it belongs to line two - even though line one's text
        top is numerically nearer to it, which is what the old |p.y - mpos.y| measured. ]]
        local ps = {}
        line(ps, 100, 0, 20, {0, 50}, 0)               -- plain line, band 100..120
        line(ps, 180, 60, 20, {0, 50}, 10)             -- tall line, band 120..200
        local state = {last_positions = ps}

        check("a click in the overhang belongs to the tall line",
                at(state, {x = 1, y = 130}) == 10, at(state, {x = 1, y = 130}))
        check("a click low in the tall line still belongs to it",
                at(state, {x = 1, y = 195}) == 10)
        check("a click in the plain line above is unaffected",
                at(state, {x = 1, y = 110}) == 0)
    end

    -- ------------------------------------------------------------- clicks outside every line
    do
        local ps = {}
        line(ps, 100, 0, 20, {0, 50}, 0)
        line(ps, 120, 0, 20, {0, 50}, 10)
        local state = {last_positions = ps}

        --[[ Above everything and below everything must still answer, and answer with the nearest
        end rather than nothing: a click in a box's padding is an ordinary way to place a caret,
        and returning nil there would make the click do nothing at all. ]]
        check("far above lands on the first line", at(state, {x = 49, y = -500}) == 1)
        check("far below lands on the last line", at(state, {x = 49, y = 5000}) == 11)

        --[[ Far off to the side does not change which line, only which end of it. ]]
        check("far right of the second line stays on it", at(state, {x = 9999, y = 125}) == 11)
        check("far left of the second line stays on it", at(state, {x = -9999, y = 125}) == 10)
    end

    -- ------------------------------------------------------------------------ nothing recorded
    do
        --[[ draw() has not run yet - the first frame, or a box that has never been visible. The
        caller treats nil as "no answer" and leaves the caret alone; anything else would move it
        somewhere arbitrary on the first click into a fresh box. ]]
        check("no recorded positions answers nil", at({}, {x = 10, y = 10}) == nil)
    end

    if checks_failed == 0 then
        print("PASS: a text click picks its line before its column (" .. checks_run .. " checks)")
    end
    return checks_failed == 0
end

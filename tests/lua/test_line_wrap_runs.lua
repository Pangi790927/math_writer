--[[
test_line_wrap_runs.lua - a thing that has to stay whole moves to the next line only when the next
line can actually hold it.

THE ASSUMPTION, and it is one assumption serving two features asked for on 2026-09-09: "if a
formula fits on the next line, it should try to jump there (but only if it fits on the new line)"
and "it would be great if words wrapped fully, not cut in the middle at the border". A formula and
a word are the same shape of problem - a run of layout the editor may not split - so editor_text
answers both with one predicate, run_moves_down(), and this file is the alarm on that predicate.

WHY IT NEEDS AN ALARM. The "only if it fits" half is not a nicety, it is what keeps draw()
terminating. Drop it and a run wider than the whole column moves down, still does not fit, moves
down again: an infinite supply of empty lines, or - since both of draw()'s passes run the rule
independently - the two disagreeing about how many lines there are, which is the older and worse
bug (see pass 1's own comment). Neither failure prints anything. Both are invisible to every other
test here, because nothing else runs the text layout at all.

The declining case is therefore the one worth the most assertions, and it is asserted as a
PROPERTY over a spread of widths rather than at the one point that happened to be tried by hand -
same reasoning as test_formula_line_fit.lua's own sweep, which guards the neighbouring hang.

WHAT IS DELIBERATELY NOT ASSERTED: where any particular line breaks in a real document. That needs
draw(), which needs a real ImGui frame, and pinning it would assert today's font metrics rather
than the rule. The rule is the thing that has to keep holding.
]]

package.path = package.path .. ";./scripts/?.lua"

local char = require("char")
local mexpru = require("mexpru")
local mformula = require("mformula_new")
local editor = require("editor_text")

local checks_run, checks_failed = 0, 0
local function check(name, cond, got)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name .. (got ~= nil and ("  (got: " .. tostring(got) .. ")") or ""))
    end
end

-- A char-stream item, the shape editor_text.insert_ncod() builds.
local function glyph(ascii)
    local e = char.find_by_ascii(ascii)
    if not e then
        error("test needs an ascii glyph for '" .. tostring(ascii) .. "'")
    end
    return {code = e.ncod}
end

local function chars_of(text)
    local items = {}
    for i = 1, #text do
        items[#items + 1] = glyph(text:sub(i, i))
    end
    return items
end

function run_test()
    local moves = editor.run_moves_down

    -- ------------------------------------------------------------------ 1. the rule itself
    do
        --[[ The three answers, at one concrete size, spelled out before the properties below so a
        reader can see what the rule IS without decoding a loop. Line is 100 wide, 70 already used,
        so 30 is left. ]]
        check("a run that fits where it is stays there", moves(100, 70, 25) == false)
        check("a run that does not fit here but fits on a fresh line moves down",
                moves(100, 70, 60) == true)
        check("a run that fits on NO line stays put and is cut in place",
                moves(100, 70, 140) == false)

        --[[ Exactly-fits is not a break. Off-by-one here would move a run that was already
        touching the edge perfectly, costing a line for nothing, on every such run. ]]
        check("a run filling the remainder exactly does not move", moves(100, 70, 30) == false)
        check("a run filling a whole line exactly may still move down", moves(100, 70, 100) == true)
        check("one unit wider than a line, and it can never move", moves(100, 70, 101) == false)
    end

    -- ------------------------------------ 2. the two termination guards, as properties
    do
        --[[ GUARD ONE: never at the start of a line. If this ever answers true at used == 0, the
        caller breaks a line, lands at used == 0 again, and asks again - draw() stops returning.
        Asserted for every run width, including the ones far too wide to fit, because it is the
        too-wide ones that would trigger it. ]]
        for _, width_limit in ipairs({40, 120, 500, 1000}) do
            local bad = nil
            for w = 0, width_limit * 3, 7 do
                if moves(width_limit, 0, w) ~= false then
                    bad = w
                end
            end
            check("width_limit=" .. width_limit .. ": nothing ever moves down from the line start",
                    bad == nil, bad)
        end

        --[[ GUARD TWO: a run wider than the whole line never moves, from ANY position on it. This
        is the same loop from the other side - such a run would move down forever, one empty line
        per frame, and the document would grow without anything being typed. ]]
        for _, width_limit in ipairs({40, 120, 500, 1000}) do
            local bad = nil
            for used = 1, width_limit, 3 do
                if moves(width_limit, used, width_limit + 1) ~= false then
                    bad = used
                end
            end
            check("width_limit=" .. width_limit .. ": an over-wide run never moves, wherever it sits",
                    bad == nil, bad)
        end

        --[[ Unknown is not a reason to move anything. width_limit is nil for an unbounded editor
        (no wrapping at all) and run_width is nil for every item that does not START a run - which
        is most of them, since measure_runs only keys a run's first item. A stray true here would
        break a line in the middle of a word. ]]
        check("no width limit: nothing moves", moves(nil, 50, 90) == false)
        check("no run width: nothing moves", moves(100, 50, nil) == false)
    end

    -- --------------------------------------------------- 3. what counts as one word
    do
        local fs = char.load_font_set()
        local SZ = mexpru.DEFAULT_SIZE
        local function runs_for(text)
            return editor.measure_runs({chars = chars_of(text)}, fs, SZ)
        end

        --[[ A run is keyed on its FIRST item and on nothing else. Both passes look up runs[i] at
        every item and expect nil to mean "not a run start" - a width sitting on a middle letter
        would re-ask the question mid-word and break exactly where this feature exists to stop. ]]
        do
            local runs = runs_for("ab cd")
            check("the first letter of a word carries the run", runs[1] ~= nil)
            check("...and no letter inside it does", runs[2] == nil)
            check("a space carries none", runs[3] == nil)
            check("the next word starts a new one", runs[4] ~= nil)
            check("...also only on its first letter", runs[5] == nil)
        end

        --[[ THE PUNCTUATION CASE, which is why a word is "a run with no whitespace in it" and not
        a run of is_alnum(). Split any finer and "end." puts the full stop alone on the next line,
        which is the same defect this feature was asked to remove, just smaller. ]]
        do
            local runs = runs_for("end. next")
            local plain = runs_for("end next")
            check("a trailing full stop travels with its word", runs[4] == nil)
            check("...and makes the word wider than the bare letters",
                    runs[1] > plain[1], tostring(runs[1]) .. " vs " .. tostring(plain[1]))
        end

        --[[ Widths are real advances summed in order, so a longer word is a wider run. Asserted as
        a relation rather than a number: the numbers are font metrics and would make this test fire
        on a font change, which is not the assumption being guarded. ]]
        do
            local short_run = runs_for("ab")
            local long_run = runs_for("abcdefgh")
            check("a longer word measures wider", long_run[1] > short_run[1])
        end

        --[[ A formula is its own run and ENDS the word beside it, so "x" and "z" around one are
        three runs rather than one. It has to be: the layout can move a formula independently, and
        a word glued to it would drag it around. ]]
        do
            local state = {chars = {glyph("x"), {formula = mformula.new(fs, SZ)}, glyph("z")}}
            local runs = editor.measure_runs(state, fs, SZ)
            check("the glyph before a formula is its own run", runs[1] ~= nil)
            check("the formula is its own run", runs[2] ~= nil)
            check("the glyph after it starts another", runs[3] ~= nil)
        end

        --[[ A newline is not a run and does not join the words on either side of it. ]]
        do
            local runs = editor.measure_runs({chars = {glyph("a"), {newline = true}, glyph("b")}},
                    fs, SZ)
            check("a newline carries no run", runs[2] == nil)
            check("the word after a newline starts its own", runs[3] ~= nil)
        end
    end

    -- ------------------------------------------- 4. the formula path agrees with the rule
    do
        local m = {line_height = 20}

        --[[ formula_line_fit() must break for EITHER reason - the old too-narrow-to-be-a-column
        guard, or the new fit rule - and the two must not have eaten each other. 500 wide, 300
        used, so ~192 is left after both margins: far more than a legal column, so the old rule is
        silent here and only the new one can answer. ]]
        check("a formula that fits where it is does not break",
                editor.formula_line_fit(m, 500, 300, 100) == false)
        check("one too wide for the remainder, but not for a line, breaks",
                editor.formula_line_fit(m, 500, 300, 300) == true)
        check("one too wide for any line does not break",
                editor.formula_line_fit(m, 500, 300, 900) == false)

        --[[ nil run_width is the pre-2026-09-09 behaviour exactly. This is what
        test_formula_line_fit.lua's whole sweep is written against, so if this stops holding that
        file is testing something it no longer describes - the two are pinned together here on
        purpose rather than each assuming it about the other. ]]
        check("nil run width leaves the old rule alone: no break with room to spare",
                editor.formula_line_fit(m, 500, 300, nil) == false)
        check("nil run width still breaks when the column would be degenerate",
                editor.formula_line_fit(m, 500, 495, nil) == true)

        --[[ Breaking hands back a WHOLE line's column, never the scrap that was left. A formula
        moved down to get room and then given the old room would have moved for nothing. ]]
        local broke, column = editor.formula_line_fit(m, 500, 300, 300)
        local _, stay_column = editor.formula_line_fit(m, 500, 300, 100)
        check("a break grants the full line's column", broke and column > stay_column,
                tostring(column) .. " vs " .. tostring(stay_column))
    end

    -- --------------------------------------- 5. a wrapped formula clears the text it left
    do
        --[[ THE ASSUMPTION: a formula that wraps lands MORE than one row down, and a word lands
        exactly one.

        Why it needs saying out loud, rather than being left as an obvious constant. A formula's
        drawn border is bigger than the line height reserved for it - pass 1 measures box.top /
        box.bottom, pass 2 draws around formula_click_rect() plus a margin on each side - so two
        formulas a single row apart overlap on screen. Reported live 2026-09-09: "the gray boxes
        intersect if you look at them after the wrap". The extra row is the author's own spacing
        rule ("formulas should be spaced two spaces away from other things"), and while that
        reserve gap exists it is also the only thing keeping a wrapped formula clear of the line
        it came from.

        So this is an alarm on a constant, which is normally worth little - it is worth something
        here because dropping it back to one is a one-character edit that looks like tidying,
        changes nothing any other test can see, and quietly brings the overlap back. If somebody
        fixes the reserve properly (pass 1 measuring the same rect pass 2 draws), this assertion
        is the right place to argue about whether the spacing rule still wants its extra row -
        which is the conversation that should happen, rather than the row vanishing unnoticed. ]]
        check("a wrapping formula drops more than one row",
                editor.FORMULA_WRAP_ROWS > 1, editor.FORMULA_WRAP_ROWS)
    end

    -- ------------------------------------ 6. a moved formula is parked against the right margin
    do
        local place = editor.wrapped_formula_x

        --[[ THE ASSUMPTION: a formula the wrapper moved sits at the RIGHT end of its row, and its
        right margin lands on the column's right margin.

        It carries meaning, which is why it is asserted rather than left to look after itself. A
        formula alone on a row is otherwise ambiguous - typed there deliberately, or pushed there
        by the wrapper - and the two read identically at the left margin. Author's own words,
        2026-09-09: "you can't really tell if a formulas is by itself, or it was moved by the
        wrapper, so, it would be way more visible at the right end". Left means placed, right
        means moved; flatten this to 0 and the document silently stops saying which. ]]
        check("a moved formula's right edge lands on the margin", place(500, 120) == 380)
        check("a wider one is pushed further left", place(500, 300) == 200)

        --[[ Clamped, because formula_line_fit() also breaks for a reason the fit rule declines:
        a remainder too narrow to be a legal column at all. That break can carry a formula wider
        than the whole line, and a negative offset would park it off the left edge of the box
        where no click could ever reach it. It starts at the left and wraps in place instead. ]]
        check("one wider than the line starts at the left, not off it", place(500, 900) == 0)
        check("exactly a line wide starts at the left", place(500, 500) == 0)

        --[[ Same nil-safety the rest of this path has: an unbounded editor, or an item that does
        not start a run, must not shift anything sideways. ]]
        check("no width limit: no offset", place(nil, 300) == 0)
        check("no run width: no offset", place(500, nil) == 0)
    end

    if checks_failed == 0 then
        print("PASS: unbreakable runs move down only when the next line can hold them ("
                .. checks_run .. " checks)")
    end
    return checks_failed == 0
end

--[[
test_cursor_survives_rebuild.lua - a tree rebuild keeps the caret where it was, INCLUDING when the
rebuild replaces the very node the caret was on.

THE ASSUMPTION THIS GUARDS. rescale_node() rebuilds a formula through the ordinary constructors and
hands back "the node standing in for cursor_target". That is a promise about every node kind, and
one kind used to break it silently: a bracket is rebuilt as a small un-paired glyph, and the horiz
branch then calls mexpru.horiz(), whose resolve_bracket_pairs() swaps that glyph for a taller tier
when the span needs one. The answer was recorded BEFORE the swap, so it named a node that no longer
existed by the time the caller stored it.

WHY IT HAD NO ALARM, and why this file exists: nothing failed. cursor_pos is a WEAK ref, so it came
back nil rather than throwing, and live_cursor() recovered to the formula root exactly as designed.
The whole symptom was a caret that had quietly moved - typing "(a/b)", zooming, then "Z" produced
"Z(a/b)" instead of "(a/b)Z" - one keystroke after the operation that caused it, which is far enough
away that the zoom does not look like the culprit. It ran for as long as it did because a recovered
cursor is indistinguishable from a legitimately dropped one unless something asserts WHERE it went.
Found 2026-09-13 from `WARN cursor_pos was dangling` in the flight recorder, six per undo.

BOTH REBUILDERS ARE CHECKED because both take the same path and only one of them is undo: clone()
is the undo snapshot, rescale() is the zoom. The zoom case needs no undo stack to reproduce.

If this fires, the question is not "where should the caret go" but "what replaced the node it was
on, and did the rebuild notice" - the mapping is recorded in rescale_node's horiz branch.
@date 2026-09-13 00:40
]]

package.path = package.path .. ";./scripts/?.lua"

local char = require("char")
local mexpru = require("mexpru")
local mformula = require("mformula_new")
local mformula_latex = require("mformula_latex")

local BS = string.char(92)

local checks_run, checks_failed = 0, 0
local function check(name, cond, got)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name .. (got ~= nil and ("  (got: " .. tostring(got) .. ")") or ""))
    end
end

--[[ A bracket around a fraction, which is the smallest span that forces a re-tier: the brackets
have to grow taller than a typed "(" to hold it, so resolve_bracket_pairs replaces both atoms. A
bracket around a plain letter does NOT reproduce this - it needs no taller tier and the atom it was
built with survives. ]]
local function bracketed_frac(fs)
    return mformula_latex.from_latex(fs, mexpru.DEFAULT_SIZE,
            BS .. "left(" .. BS .. "frac{a}{b}" .. BS .. "right)")
end

-- The closing bracket, which is where the caret sits after someone types the ")".
local function closing_bracket(container)
    for _, child in ipairs(mexpru.u(container.root).children) do
        local u = mexpru.u(mexpru.slot_atom(child))
        if u.bracket and not u.bracket.is_open then
            return child
        end
    end
end

local function caret_is_still_the_bracket(container, what)
    local node = container.cursor_pos and container.cursor_pos:get_obj()
    check(what .. ": the caret still resolves to a live node", node ~= nil)
    if not node then
        return
    end

    --[[ REACHABLE FROM THIS CONTAINER'S ROOT, which is the assertion that actually bites, and the
    first version of this test did not make it. A replaced node is merely DROPPED here - the
    reference goes away and the collector gets to it eventually - so `get_obj()` on the discarded
    bracket still handed back a live node, and a check for "not nil" passed against the very bug it
    was written for. It is the running app that turns dropped into dangling: mexpru.cut() force-
    releases a superseded tree, which a test never calls. cursor_path() answers nil for a node the
    root cannot reach, which is the same question in a form that does not depend on WHEN the old
    node dies. ]]
    check(what .. ": ...and it belongs to the rebuilt tree, not the one it was copied from",
            mformula.cursor_path(container) ~= nil)

    --[[ NOT just reachable, either: recovering to the root is reachable too, and that IS the
    symptom - the caret at the front of the formula. It has to still be the CLOSING BRACKET. ]]
    local u = mexpru.u(mexpru.slot_atom(node))
    check(what .. ": ...and it is still the closing bracket, not the formula root",
            u.bracket ~= nil and u.bracket.is_open == false,
            u.bracket and "open" or mexpru.u(node).kind or "root")
end

function run_test()
    local fs = char.load_font_set()

    -- ---------------------------------------------------------------- setup
    local src = bracketed_frac(fs)
    check("setup: the latex parses", src ~= nil)
    if not src then
        return false
    end
    local close = closing_bracket(src)
    check("setup: it has a closing bracket to put the caret on", close ~= nil)
    if not close then
        return false
    end

    -- ---------------------------------------------------------------- clone: the undo snapshot
    do
        local container = mexpru.new_container(src.root, close, 0)
        local copy = mformula.clone(container, fs)
        caret_is_still_the_bracket(copy, "clone")
    end

    -- ---------------------------------------------------------------- rescale: the zoom
    do
        local other = bracketed_frac(fs)
        local container = mexpru.new_container(other.root, closing_bracket(other), 0)
        mformula.rescale(container, fs)
        caret_is_still_the_bracket(container, "rescale")
    end

    print("checks: " .. checks_run .. ", failed: " .. checks_failed)
    if checks_failed > 0 then
        return false
    end
    print("PASS: a rebuild keeps the caret on a node it had to replace")
    return true
end

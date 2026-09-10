--[[
test_keymap_filter.lua - the F2 customiser's search box: which bindings answer a partial
combination, and which deliberately do not.

THE ASSUMPTION. Requested 2026-09-09, author's own words: "I want to filter only those with
maching cotrol and key, if key is missing, match only by contor and in reverse the same". So the
filter's own shape decides what gets compared - both halves, modifiers only, or key only - and the
half the filter left out is not consulted at all.

WHY THIS NEEDS AN ALARM RATHER THAN A GLANCE. Every one of those three cases is a plausible place
to "simplify" later, and each simplification is silent. Make the modifier test a SUBSET test and
"Ctrl+" quietly returns every Ctrl-anything binding, which is not narrower than the unfiltered
table by much. Make a missing key mean "no key", rather than "do not ask", and "Ctrl+" matches
nothing at all - a search box that always comes back empty reads as a broken keymap rather than as
a broken filter. Neither shows up anywhere else: the filter has no output but a table that got
shorter, and a table that got too short looks exactly like a table that got correctly short.

The wildcard case is the subtle one and is asserted on purpose: a bind carrying "+All" has said it
does not care about modifiers, so hiding it from a modifier search would hide precisely the
bindings hardest to recall - the ones whose modifiers are not fixed.

Filters are built through keymap.parse_filter() rather than as hand-written tables, so this also
pins the parser's tolerance for a trailing "+" - which is what a half-typed combination looks like
every single frame it is being typed.
]]

package.path = package.path .. ";./scripts/?.lua"

local keymap = require("keymap")

local checks_run, checks_failed = 0, 0
local function check(name, cond, got)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name .. (got ~= nil and ("  (got: " .. tostring(got) .. ")") or ""))
    end
end

local function bind(text)
    local b, why = keymap.parse(text)
    if not b then
        error("test needs '" .. text .. "' to parse: " .. tostring(why))
    end
    return b
end

local function filter(text)
    return (keymap.parse_filter(text))
end

function run_test()
    -- ------------------------------------------------- what counts as "no filter" at all
    do
        --[[ nil, not an error, and distinct from a typo: the box is empty most of the time, and
        every empty frame must mean "show everything" rather than "show nothing" or "complain". ]]
        check("empty text is no filter", filter("") == nil)
        check("whitespace is no filter", filter("   ") == nil)
        check("a bare + is no filter", filter("+") == nil)
        check("no filter matches everything", keymap.filter_matches(bind("Ctrl+S"), nil) == true)

        --[[ A typo is NOT "no filter" - it has to be reportable, or the box silently ignores what
        was typed and looks broken. parse_filter returns nil plus a reason there. ]]
        local b, why = keymap.parse_filter("Ctrl+Nonsuchkey")
        check("an unknown key is refused with a reason", b == nil and why ~= nil, why)
    end

    -- ------------------------------------------------- modifiers only: the key is not consulted
    do
        local f = filter("Ctrl+")
        check("'Ctrl+' parses to a keyless filter", f ~= nil and f.key == nil and f.ctrl == true)
        check("...and matches a Ctrl binding on any key", keymap.filter_matches(bind("Ctrl+S"), f))
        check("...on a different key too", keymap.filter_matches(bind("Ctrl+M"), f))
        check("...but not an unmodified one", keymap.filter_matches(bind("F1"), f) == false)

        --[[ EXACT, not subset. This is the decision worth defending: a Ctrl search that also
        returned every Ctrl+Shift binding has not narrowed the table enough to be worth typing. ]]
        check("Ctrl does not match Ctrl+Shift", keymap.filter_matches(bind("Ctrl+Shift+Z"), f) == false)
        local fs = filter("Ctrl+Shift+")
        check("...and Ctrl+Shift does match it", keymap.filter_matches(bind("Ctrl+Shift+Z"), fs))
        check("...while refusing plain Ctrl", keymap.filter_matches(bind("Ctrl+S"), fs) == false)
    end

    -- ------------------------------------------------- key only: the modifiers are not consulted
    do
        local f = filter("S")
        check("'S' parses to a modifier-less filter",
                f ~= nil and f.key == "ImGuiKey_S" and f.ctrl == false)
        check("...matches Ctrl+S", keymap.filter_matches(bind("Ctrl+S"), f))
        check("...matches a bare S if one exists", keymap.filter_matches(bind("S"), f))
        check("...and refuses another key", keymap.filter_matches(bind("Ctrl+M"), f) == false)
    end

    -- ------------------------------------------------- both halves given
    do
        local f = filter("Ctrl+S")
        check("both halves match exactly", keymap.filter_matches(bind("Ctrl+S"), f))
        check("...wrong key, no match", keymap.filter_matches(bind("Ctrl+M"), f) == false)
        check("...wrong modifiers, no match", keymap.filter_matches(bind("Ctrl+Shift+S"), f) == false)
    end

    -- ------------------------------------------------- the +All wildcard
    do
        --[[ "Escape+All" fires whatever is held, so it belongs in the answer to ANY modifier
        search - it is one of the bindings a person is least able to recall exactly, which is when
        a search box is worth having. ]]
        local w = bind("Escape+All")
        check("a wildcard answers a Ctrl search", keymap.filter_matches(w, filter("Ctrl+")))
        check("a wildcard answers a Ctrl+Shift search", keymap.filter_matches(w, filter("Ctrl+Shift+")))
        check("...but is still pinned by its KEY", keymap.filter_matches(w, filter("F1")) == false)
        check("...and answers its own key", keymap.filter_matches(w, filter("Escape")))
    end

    -- ------------------------------------------------- against the live registry
    do
        --[[ End to end, on the real DEFAULTS rather than hand-made binds: filter_ids is what the
        panel actually calls, and "did any real action survive" is the property that matters. A
        filter matching nothing real would leave an empty table on screen. ]]
        local all = keymap.filter_ids(nil)
        local ctrl = keymap.filter_ids(filter("Ctrl+"))
        local n_all, n_ctrl = 0, 0
        for _ in pairs(all) do n_all = n_all + 1 end
        for _ in pairs(ctrl) do n_ctrl = n_ctrl + 1 end
        check("no filter lets every action through", n_all > 40, n_all)
        check("a Ctrl filter lets some through", n_ctrl > 0, n_ctrl)
        check("...and strictly fewer than everything", n_ctrl < n_all, n_ctrl .. " of " .. n_all)

        --[[ doc.save is Ctrl+S in DEFAULTS, so it is a fair end-to-end probe: if this stops
        holding, either the binding moved (fine, update it) or the filter stopped working (not
        fine) - and the comment is here so the next reader can tell those apart. ]]
        check("doc.save answers a Ctrl+S search", keymap.filter_ids(filter("Ctrl+S"))["doc.save"])
    end

    if checks_failed == 0 then
        print("PASS: the keymap search box filters by the halves it was given ("
                .. checks_run .. " checks)")
    end
    return checks_failed == 0
end

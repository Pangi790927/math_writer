--[[
test_help_placeholders.lua - every {action.id} written into an F1 chapter names a real action.

THE ASSUMPTION: the help page's prose and keymap.lua's registry agree about what the actions are
called. They are, again, two sets of string literals in two files with nothing connecting them.

WHY IT NEEDS AN ALARM. panel_help.lua resolves an unknown placeholder by leaving it in braces
rather than blanking it - a deliberate choice, so a typo is visible instead of vanishing. But
"visible" means visible TO SOMEONE WHO OPENS THAT CHAPTER, and there are fourteen of them. A
mistyped {math.acccent_hat} would sit in the accents chapter reading literally "{math.acccent_hat}
is a hat" until somebody happened to look. Nothing else in the suite reads this file at all.

It also guards the reverse direction of the same drift: the registry is not frozen, and renaming an
action - which the customiser makes tempting, since the id is what the F2 table shows - silently
breaks every sentence in the help that mentioned it. This test fires on the rename, at the moment
the decision is being made, rather than months later.

Deliberately NOT asserted: that every action APPEARS in the help. Plenty are ordinary enough to
need no explanation, and the help is prose, not a reference table - demanding coverage would push
it back towards the flat key list it was written to replace.
]]

package.path = package.path .. ";./scripts/?.lua"

local keymap = require("keymap")
local panel_help = require("panel_help")
local char = require("char")
local mformula = require("mformula_new")
local mexpru = require("mexpru")

function run_test()
    local ok = true
    local known = {}
    keymap.each(function(id) known[id] = true end)

    local chapters = panel_help.chapters()
    if #chapters == 0 then
        print("FAIL: no chapters at all - panel_help.chapters() returned an empty list")
        return false
    end

    local total, bad = 0, 0
    for _, ch in ipairs(chapters) do
        if not ch.title or ch.title == "" then
            print("FAIL: a chapter has no title")
            ok = false
        end
        --[[ Line by line, skipping "@fig" lines: those are LaTeX, and LaTeX braces (x^{2},
        \\mathbb{N}) are not placeholders. Scanning the whole body at once reported every one of
        them as an unknown action - which is how this exemption got written, in panel_help's
        resolve() as well as here. The two must agree, or the page would substitute somewhere this
        test does not look. ]]
        for line in (ch.body or ""):gmatch("[^\n]+") do
            if not line:match("^@fig") then
                for id in line:gmatch("{([%w_.]+)}") do
                    total = total + 1
                    if not known[id] then
                        print("FAIL: chapter '" .. tostring(ch.title)
                                .. "' references unknown action: " .. id)
                        bad = bad + 1
                        ok = false
                    end
                end
            end
        end
    end

    --[[ The scan has to be finding placeholders at all. If the brace syntax ever changes and this
    pattern stops matching, every check above passes vacuously and the test becomes decoration -
    which is precisely how the earlier keymap test managed to stay green while the app would not
    start. ]]
    if total < 30 then
        print("FAIL: only " .. total .. " placeholders found across " .. #chapters
                .. " chapters; the scan looks broken rather than the help being short")
        ok = false
    end

    -- And every one of them must actually RESOLVE - label() returning the braces back would mean
    -- the page renders "{edit.undo}" to the reader even though the id checked out above.
    for _, ch in ipairs(chapters) do
        for line in (ch.body or ""):gmatch("[^\n]+") do
        if not line:match("^@fig") then
        for id in line:gmatch("{([%w_.]+)}") do
            local label = keymap.label(id)
            if type(label) ~= "string" or label == "" or label:find("[{}]") then
                print("FAIL: " .. id .. " does not render to a usable key name: " .. tostring(label))
                ok = false
            end
        end
        end
        end
    end

    --[[ EVERY "@fig <latex>" IN THE HELP MUST ACTUALLY BUILD.

    The page renders these through the same mformula.from_latex() the editor uses, so a figure is
    the editor's own output rather than a picture of it - which is the point, and also the risk:
    LaTeX that this parser does not accept produces no formula, and panel_help deliberately
    swallows that (a help page must never be what crashes the app, so a bad figure is skipped).
    Swallowed means invisible, so the alarm has to be here instead.

    Note what this does NOT claim: that the figure LOOKS right. Only that it parses and lays out.
    Whether \\frac{a+b}{c} renders as a readable fraction is a thing for eyes, not for a test. ]]
    local fs = char.load_font_set()
    local figs, broken = 0, 0
    for _, ch in ipairs(chapters) do
        for line in (ch.body or ""):gmatch("[^\n]+") do
            local latex = line:match("^@fig%s+(.+)$")
            if latex then
                figs = figs + 1
                local built_ok, container = pcall(mformula.from_latex, fs,
                        mexpru.DEFAULT_SIZE - 3, latex)
                if not built_ok or not container then
                    print("FAIL: figure does not build in chapter '" .. tostring(ch.title)
                            .. "': " .. latex .. "  (" .. tostring(container) .. ")")
                    broken = broken + 1
                    ok = false
                end
            end
        end
    end

    if ok then
        print("checked " .. total .. " placeholders and " .. figs .. " figures across "
                .. #chapters .. " chapters, all resolve")
    end
    return ok
end

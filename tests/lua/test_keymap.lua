--[[
test_keymap.lua - tripwires over keymap.lua's ASSUMPTIONS, not over its output.

What each check is guarding, and why it would matter if it ever fired:

1. EVERY DEFAULT PARSES. keymap.lua errors at load on a bad default, so this mostly pins that the
   error is real rather than swallowed. The failure it guards is specific and nasty: a typo in a
   default bind means that shortcut silently never fires, and nothing about using the app would
   tell you which one - the same invisible-failure class test_no_use_before_define.lua exists for.

2. PARSE AND FORMAT ROUND-TRIP. The customiser writes what format() produces and reads it back
   through parse(); if the two ever disagree, a saved keymap decays a little on every load, which
   is the kind of corruption nobody notices until their bindings are gone.

3. MODIFIER ORDER IS NORMALISED. "Shift+Ctrl+Z" and "Ctrl+Shift+Z" are the same bind. This is
   assumed by serialize(), which decides "has the user changed this?" by comparing FORMATTED text -
   without normalisation it would write divergence lines for bindings nobody touched, and those
   lines would then freeze today's defaults into the user's file forever.

4. TWO NON-MODIFIER KEYS ARE REFUSED. Ruled 2026-09-07: "not allowed". Asserted here because it is
   a DECISION, not a mechanism - "last key wins" was the alternative and was rejected, so if this
   ever starts passing two keys, someone changed the rule and should say so.

5. SERIALIZE WRITES ONLY DIVERGENCE. The point of the file format: an untouched action must not
   appear, so improving a default later still reaches a user who has opened the customiser. If this
   fires, the file has started freezing defaults.

6. AN UNKNOWN ACTION ID RAISES. pressed("typo") returning false would mean a mistyped id is a
   shortcut that quietly never works. It must be loud.

7. IT WORKS WITH NO IMGUI AT ALL. The harness registers only charc and mexpr - imgui_composer is
   not registered here, so vc.ImGuiKey_* and vc.ImGui_key_names are nil. keymap.lua is built to
   fall back to name strings for exactly this reason (char.lua:894 does the same). If that fallback
   breaks, every test in this file stops being runnable, which is why this is asserted first.
]]

package.path = package.path .. ";./scripts/?.lua"

local vc = require("virt_composer")
local keymap = require("keymap")

local function check(cond, msg)
    if not cond then
        print("FAIL: " .. msg)
        return false
    end
    return true
end

function run_test()
    local ok = true

    -- 7: the environment this test itself depends on.
    ok = check(vc.ImGui_key_names == nil, "expected no imgui_composer under the harness") and ok

    -- 1: every default survived install_defaults() - require() would have errored otherwise.
    local n = 0
    keymap.each(function(id, action)
        n = n + 1
        ok = check(action ~= nil, "action missing: " .. id) and ok
        ok = check(action.desc and action.desc ~= "", "no description: " .. id) and ok
    end)
    ok = check(n > 50, "expected a populated registry, got " .. n) and ok

    -- 2 and 3: round-trip, and modifier order normalised on the way through.
    local cases = {
        {"Ctrl+Z",            "Ctrl+Z"},
        {"ctrl+shift+z",      "Ctrl+Shift+Z"},
        {"Shift+Ctrl+Z",      "Ctrl+Shift+Z"},   -- order normalised
        {"Alt+Up",            "Alt+Up"},
        {"Ctrl+/",            "Ctrl+/"},
        {"Ctrl+Shift+\\",     "Ctrl+Shift+\\"},
        {"F1",                "F1"},
        {"Shift+Enter",       "Shift+Enter"},
        {"Ctrl+Left",         "Ctrl+Left"},
        {"Backspace",         "Backspace"},
        {"Ctrl+`",            "Ctrl+`"},
        -- The "+All" wildcard (ruled 2026-09-07). It renders AFTER the key, and "any" is accepted
        -- as a synonym on the way in but normalises to "All" on the way out - so a keymap saved
        -- by someone who typed "any" reloads identically.
        {"Enter+All",         "Enter+All"},
        {"space+all",         "Space+All"},
        {"Backspace+any",     "Backspace+All"},
    }
    for _, case in ipairs(cases) do
        local bind, why = keymap.parse(case[1])
        if check(bind ~= nil, "did not parse: " .. case[1] .. " (" .. tostring(why) .. ")") then
            local got = keymap.format(bind)
            ok = check(got == case[2], "format(" .. case[1] .. ") = " .. got
                    .. ", expected " .. case[2]) and ok
            -- The round trip proper: what format() writes must parse back to the same thing.
            local again = keymap.parse(got)
            ok = check(again ~= nil and keymap.format(again) == got,
                    "round-trip broke on " .. got) and ok
        else
            ok = false
        end
    end

    -- The wildcard is a DIFFERENT bind from the bare key, or conflict marking would call them
    -- the same thing and the customiser would report collisions that are not.
    local plain, wild = keymap.parse("Enter"), keymap.parse("Enter+All")
    ok = check(plain.any_mods == false and wild.any_mods == true,
            "Enter and Enter+All must not parse to the same bind") and ok

    --[[ 8. AN UNKNOWN KEY NAME IS REFUSED.

    This is the check that was MISSING, and its absence let a broken DEFAULTS table ship: parse()
    used to fall back to "ImGuiKey_" .. token:upper() and, whenever ImGui was not registered - i.e.
    in every test run - accept the result without confirming it existed. "Delete" resolved to
    "ImGuiKey_DELETE", which is not a real key, and the real app died on startup parsing its own
    defaults while the whole suite stayed green.

    So the assertion is not "parse works". It is that parse REFUSES a name it cannot resolve, with
    no ImGui present to help it - because that is the condition under which it silently stopped
    checking. ]]
    for _, bogus in ipairs({"Frobnicate", "ImGuiKey_DELETE", "Ctrl+Nope", "Deleet", "Arrow"}) do
        local b, reason = keymap.parse(bogus)
        ok = check(b == nil, "must refuse unknown key name: " .. bogus
                .. (b and (" (accepted as " .. keymap.format(b) .. ")") or "")) and ok
        ok = check(reason == nil or reason:find("unknown key") ~= nil,
                "refusal reason for " .. bogus .. " should name the problem, got "
                .. tostring(reason)) and ok
    end

    --[[ 9. EVERY DEFAULT RESOLVES TO A REAL KEY NAME, not merely to something parse() tolerated.

    Same failure, caught from the other side: the registry's own strings must survive the same
    resolution the customiser's field uses. Checked against the ALIASES/structural rule rather than
    against ImGui, so it holds headless - which is where it has to hold, since that is where it
    previously did not. ]]
    keymap.each(function(id, action)
        for i, bind in ipairs(action.binds) do
            -- Digits are real key names too (ImGuiKey_6 is the hat accent's key), so the
            -- pattern must not demand a leading letter - it did, and this assertion failed on the
            -- accents before the code did anything wrong.
            local ok_name = bind.key and bind.key:match("^ImGuiKey_[%w]+$") ~= nil
            ok = check(ok_name, "default bind " .. i .. " of " .. id
                    .. " resolved to a suspicious key name: " .. tostring(bind.key)) and ok
            -- Round-trip the default through format/parse: what the customiser will show for it
            -- must be re-readable, or editing any other row would rewrite this one wrong on save.
            local shown = keymap.format(bind)
            local back = keymap.parse(shown)
            ok = check(back ~= nil and back.key == bind.key,
                    "default of " .. id .. " does not survive format/parse: " .. shown) and ok
        end
    end)

    -- 4: two non-modifier keys are refused, and say why.
    local bad, why = keymap.parse("Ctrl+E+R")
    ok = check(bad == nil, "two keys in one bind must be refused") and ok
    ok = check(type(why) == "string" and why:find("two keys"),
            "refusal must explain itself, got " .. tostring(why)) and ok
    -- Modifiers alone are not a bind either.
    ok = check(keymap.parse("Ctrl+Shift") == nil, "modifiers-only must be refused") and ok

    -- 5: an untouched registry writes nothing at all.
    ok = check(keymap.serialize() == "",
            "untouched keymap must serialise empty, got:\n" .. keymap.serialize()) and ok

    keymap.set_bind("edit.undo", 1, "Ctrl+Shift+Alt+U")
    local text = keymap.serialize()
    ok = check(text:find("edit.undo"), "a changed action must appear in the file") and ok
    ok = check(not text:find("edit.redo"), "an unchanged action must NOT appear in the file") and ok
    ok = check(keymap.label("edit.undo") == "Ctrl+Shift+Alt+U",
            "label must follow the edit, got " .. keymap.label("edit.undo")) and ok

    -- ...and reading it back reproduces it.
    keymap.deserialize(text)
    ok = check(keymap.label("edit.undo") == "Ctrl+Shift+Alt+U",
            "deserialize lost the edit, got " .. keymap.label("edit.undo")) and ok
    ok = check(keymap.label("edit.redo") == "Ctrl+Shift+Z",
            "deserialize disturbed an untouched action") and ok

    -- A file that no longer mentions an action leaves it at FACTORY, not at the previous value.
    keymap.deserialize("")
    ok = check(keymap.label("edit.undo") == "Ctrl+Z",
            "an absent line must fall back to the default, got " .. keymap.label("edit.undo")) and ok

    -- An emptied bind list reads as (unbound) rather than blank - ruled 2026-09-07.
    keymap.remove_bind("edit.undo", 1)
    ok = check(keymap.label("edit.undo") == "(unbound)",
            "empty bind list must render (unbound), got " .. keymap.label("edit.undo")) and ok
    ok = check(keymap.serialize():find("edit.undo\t%(unbound%)") ~= nil,
            "an emptied action must persist as unbound, not vanish") and ok
    keymap.reset("edit.undo")
    ok = check(keymap.label("edit.undo") == "Ctrl+Z", "reset must restore the factory bind") and ok

    -- 6: a mistyped id is loud.
    ok = check(pcall(keymap.pressed, "no.such.action") == false,
            "an unknown action id must raise, not return false") and ok

    -- Conflicts are REPORTED, never refused - two actions may share a bind (see set_bind's
    -- comment on why refusing would make swapping two shortcuts impossible).
    keymap.set_bind("box.new", 1, "Ctrl+M")
    local hits = keymap.conflicts(keymap.parse("Ctrl+M"), "box.new")
    ok = check(#hits >= 1, "Ctrl+M on box.new must be reported as conflicting with formula.new") and ok
    keymap.reset()

    return ok
end

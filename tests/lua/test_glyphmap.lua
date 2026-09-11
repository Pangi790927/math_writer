--[[
test_glyphmap.lua - what a letter key produces, and the two things that were wrong about it.

THE ASSUMPTIONS, each of which was a real report before it was a check:

1. A CELL ACCEPTS A PLAIN CHARACTER, not only a glyph name. Names like "\alpha" live in the
   catalogue by name; ordinary characters live in it by their character code and have no name at
   all. Accepting only names meant typing "b" was turned into "\b" and refused with "no glyph
   called \b" - so there was no way whatsoever to say "this key should type b". Reported
   2026-09-07 as exactly that message.

2. "DEFAULT" RESTORES THE WHOLE ROW, its key included. Reset used to restore the glyphs and leave
   the row on whatever key it had been moved to, on the reasoning that those are separate edits.
   In use that reads as a button that does nothing, because where a row sits is the visible thing
   about a moved row. Reported 2026-09-07: "default doesn't reset the row".

WHY A ROW IS A KEY AND NOT A LETTER, which the third case pins: char.lua's tables are written
letter -> glyph, which assumes the key labelled Q types "q". That holds on a US layout and on
almost nothing else - AZERTY has A there, QWERTZ swaps Z and Y - so a row is an ImGuiKey position
and is re-pointed by PRESSING the key rather than by naming a letter. If rows ever become letters
again, someone has decided non-US keyboards are not supported, and this file should say so loudly.

Drives glyphmap directly rather than the panel, for the reason every UI-adjacent test here gives:
the panel needs a real frame, so these work one level down.
]]

package.path = package.path .. ";./scripts/?.lua"

local char = require("char")
local glyphmap = require("glyphmap")

local function check(cond, msg)
    if not cond then
        print("FAIL: " .. msg)
        return false
    end
    return true
end

function run_test()
    local ok = true
    glyphmap.reset()          -- start from factory whatever ran before

    local A = "ImGuiKey_A"

    -- 1. A NAME and A CHARACTER are both acceptable, and nonsense is not.
    ok = check(glyphmap.set(A, "alt", "\\beta") == true, "a glyph name must be accepted") and ok
    ok = check(glyphmap.name(A, "alt") == "\\beta", "the name must stick") and ok

    ok = check(glyphmap.set(A, "plain", "b") == true,
            "a single character must be accepted - this is the reported bug") and ok
    ok = check(glyphmap.name(A, "plain") ~= "", "the character must resolve to something") and ok
    --[[ Stored as whatever the catalogue calls it, so everything downstream deals in one kind of
    value. What matters is that it resolves back to the same glyph, not what it is spelled as. ]]
    local entry = glyphmap.entry(A, false, false)
    ok = check(entry ~= nil and entry.ncod == char.find_by_ascii("b").ncod,
            "typing that key must produce the character that was asked for") and ok

    local bad, why = glyphmap.set(A, "alt", "\\notaglyph")
    ok = check(bad == false, "a name with no glyph must be refused") and ok
    ok = check(type(why) == "string" and why ~= "", "the refusal must say why") and ok

    -- 2. DEFAULT restores the glyphs AND the key.
    glyphmap.reset()
    ok = check(glyphmap.rekey(A, "ImGuiKey_F13") == true,
            "a row must be movable to a free key - this is how a non-US layout is described") and ok
    glyphmap.set("ImGuiKey_F13", "alt", "\\beta")
    ok = check(glyphmap.reset("ImGuiKey_F13") == true, "reset must report success") and ok
    ok = check(glyphmap.name(A, "alt") == "\\alpha",
            "reset must put the row back on its own key with its own glyphs") and ok
    ok = check(glyphmap.slots("ImGuiKey_F13") == nil,
            "reset must leave nothing behind on the key the row had been moved to") and ok

    -- 3. Moving onto an OCCUPIED key is refused rather than merging two rows into one.
    glyphmap.reset()
    local moved, reason = glyphmap.rekey(A, "ImGuiKey_B")
    ok = check(moved == false, "moving onto an occupied key must be refused, not merged") and ok
    ok = check(type(reason) == "string" and reason ~= "", "and must say why") and ok

    --[[ The row count is the invariant behind all of the above: no operation may create or lose
    one. MEASURED, not written down as 26.

    It was 26 until 2026-09-11, when a digit key was given a row (glyphmap's own LETTERS comment -
    `8` carries infinity on its Alt slot). The alarm this check exists to raise is "an operation
    duplicated or dropped a row", and a literal count could not tell that apart from "the default
    set changed on purpose" - it fired for the second while claiming the first. Taking the baseline
    from a clean reset asks the real question, and keeps asking it whatever the default set becomes.

    What is deliberately NOT asserted here is which keys have rows. That belongs with the defaults,
    not with the move/reset machinery this file is about. ]]
    glyphmap.reset()
    local baseline = 0
    glyphmap.each(function() baseline = baseline + 1 end)
    ok = check(baseline > 0, "a reset must leave rows behind, got " .. baseline) and ok

    -- 4. A saved map round-trips, including a row that has only MOVED.
    glyphmap.rekey(A, "ImGuiKey_F13")
    local text = glyphmap.serialize()
    ok = check(text:find("ImGuiKey_F13") ~= nil,
            "a moved row is a divergence and must be saved even with untouched glyphs") and ok
    glyphmap.deserialize(text)
    ok = check(glyphmap.name("ImGuiKey_F13", "alt") == "\\alpha",
            "the moved row must come back on the key it was saved on") and ok
    local n2 = 0
    glyphmap.each(function() n2 = n2 + 1 end)
    ok = check(n2 == baseline, "loading must not duplicate a moved row; got " .. n2
            .. " rows against a baseline of " .. baseline) and ok

    glyphmap.reset()
    if ok then
        print("letters take names and characters; default restores glyphs and key; moves persist")
    end
    return ok
end

--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | THE LOOKUP
-- | entry(key: string, alt: boolean, shift: boolean) -> char entry | nil
-- |     Which glyph this key produces with these modifiers. What the
-- |     editors call.
-- | name(key: string, which: string)        -> text
-- |     One slot's value, "" when empty. `which` is "from_letter",
-- |     "plain", "alt" or "alt_shift".
-- | slots(key: string)                      -> row | nil
-- |     The live {plain, alt, alt_shift, from_letter} of one key's row.
-- | key_label(name: string)                 -> text
-- |     "ImGuiKey_Q" as a person reads it: "Q".
-- |
-- | EDITING
-- | set(key: string, which: string, name: string) -> ok, reason
-- |     VALIDATED against the glyph catalogue, not merely stored - a name
-- |     the editor cannot draw is refused with a reason to display.
-- | rekey(old_key: string, new_key: string) -> ok, reason
-- |     Moves a whole row onto another key, which is how a row is
-- |     identified on a keyboard that does not have the original.
-- | reset(letter: string | nil)             -> ok
-- |     One row - named by its KEY, despite the parameter - or the WHOLE
-- |     map when given nothing.
-- | each(fn: function(key, row))            -> nothing
-- |     Every row in a FIXED order - the customiser's row order and the
-- |     file's line order at once.
-- |
-- | PERSISTENCE
-- | serialize() / deserialize(text: string, warn: function | nil)
-- | dirty() / clear_dirty()
-- |     One line per row that differs from the factory map. deserialize
-- |     starts from clean defaults, so a row the file no longer
-- |     mentions goes back to factory rather than keeping a stale value.
-- |
-- | --- internal, not on the module table ---------------------------------------------------------
-- |     the factory map, the live table and its order
-- |
-- | @date 2026-09-13 18:00
-- | ===============================================================================================
--]]

--[[
glyphmap.lua - what each LETTER KEY produces, and the one place that decides it.

The keymap next door answers "did this key mean an action". This file answers the other half:
"this key is a letter, so which glyph does it put on the page". They are deliberately separate.
An action is one id with a list of key combinations; a letter is one key with a glyph per modifier,
and forcing 26 letters x 3 modifiers into the action registry would have produced 78 entries whose
descriptions all read "the letter a", buried among the shortcuts they have nothing to do with.

THREE SLOTS PER LETTER, which is exactly what the editor already distinguished before any of this
was customisable:

    plain        what typing the bare key inserts    - normally the letter itself
    alt          Alt + the key                       - the Greek letter, by default
    alt_shift    Alt + Shift + the key               - the Greek capital, or an operator

Every slot holds a LaTeX name (`\alpha`, `\int`), which is the same currency char.find_by_desc()
and the `\name`-then-Space command entry already speak - so anything typeable by name is bindable
to a key, and a binding can never name a glyph the editor cannot draw.

`plain` is nil by default and means "the letter itself". It is a slot rather than a special case
because there is no reason the bare key should be the one thing that cannot be moved: someone
typing a lot of set theory may well want `\cup` on a key. When it is nil the ordinary character
path handles the key and nothing here is consulted at all.

DEFAULTS LIVE IN char.lua and are never mutated - greek_alt/greek_alt_shift stay the factory
setting, this file holds the live copy, and "back to default" is a copy from one to the other.
@date 2026-09-08 08:45
]]

local char = require("char")

local glyphmap = {}

--[[ The keys this file gives a row to. Kept as a string so the order is fixed and obvious: the
customiser lists them alphabetically, which is the only order anyone would look for a letter in.

MOSTLY LETTERS, and it was only letters until 2026-09-11, when `8` was added to carry infinity on
its Alt slot (char.greek_alt's own note for why that key). Nothing here ever required a letter - a
row is an ImGuiKey name and `("8"):upper()` is "8" - so a digit needed no new machinery, only
admission. Digits keep their `plain` slot nil, so typing one is unaffected: the ordinary character
path handles it and this file is never consulted.

Appended rather than inserted, because order is the customiser's row order and the saved file's
line order, and both have to stay stable across runs. ]]
local LETTERS = "abcdefghijklmnopqrstuvwxyz8"

--[[ ROWS ARE KEYS, NOT LETTERS - and that distinction is the whole point of this file being
customisable at all.

char.lua's tables are written as letter -> glyph, which quietly assumes the physical key labelled Q
produces "q". On a US layout it does; on AZERTY it is where A sits, on QWERTZ the Z and Y keys are
swapped, and on Dvorak almost nothing lines up. Keying this by letter would mean a French keyboard
could never be described here at all.

So a row is an ImGuiKey NAME - the position ImGui reports, which is what the editor actually polls
- and the letter is only how the DEFAULTS were written. Which key a row refers to is changed by
pressing it (the customiser's record button), never by guessing which letter matches it.
@date 2026-09-08 08:45 ]]
local function key_name_for(letter)
    return "ImGuiKey_" .. letter:upper()
end

-- How a key is shown to a person. Kept here rather than pulled from keymap so this file has no
-- dependency on the shortcut registry; the two happen to agree because both strip the prefix.
local function key_label(name)
    return (name or "?"):gsub("^ImGuiKey_", "")
end

--[[ @brief The label a person reads for a key, for the customiser's own rows.
-- |
-- | STRIPS THE `ImGuiKey_` PREFIX and nothing else. Kept here rather than pulled from keymap, so
-- | this file has no dependency on the shortcut registry; the two agree because both strip it.
-- |
-- | @param name  string | nil - an ImGuiKey name
-- | @return string - "ImGuiKey_Q" -> "Q"; "?" for nil
-- |
-- | @date 2026-09-13 18:00
--]]
function glyphmap.key_label(name)
    return key_label(name)
end

--[[ letter -> {plain=, alt=, alt_shift=}. Built from char.lua's tables, which stay the factory
copy. A missing slot is nil rather than "", so "unset" and "set to nothing" cannot be confused -
the difference matters for `plain`, where nil means "insert the letter" and would otherwise be
indistinguishable from "insert nothing".
@date 2026-09-08 08:45 ]]
local live = {}

--[[ Row order, kept explicitly: a table keyed by key name has no order of its own, and the
customiser's rows and the saved file's lines both have to be stable between runs. New rows are
appended, so a key added by hand does not reshuffle the ones above it.
@date 2026-09-08 08:45 ]]
local order = {}

--[[ Builds the live table from char.lua's factory tables, one row per letter key. Each row
remembers which LETTER its slots came from, because a row can later be moved to another key and
"back to default" still has to know what its default was. @date 2026-09-08 08:45 ]]
local function install_defaults()
    live, order = {}, {}
    for i = 1, #LETTERS do
        local letter = LETTERS:sub(i, i)
        local key = key_name_for(letter)
        order[#order + 1] = key
        local greek_plain, greek_shift = char.greek_for_key(letter)
        live[key] = {
            plain = nil,
            alt = greek_plain,
            alt_shift = greek_shift,
            -- What this row's slots came from, so reset() can restore them after the row has been
            -- moved to a different key. The DEFAULTS are per letter; the row is per key.
            from_letter = letter,
        }
    end
end

install_defaults()

--[[ Set by every edit, cleared by whoever writes the file - the same arrangement keymap.lua uses,
and for the same reason: the customiser saves when it CLOSES, not per keystroke, so a half-typed
name must never reach disk. install_defaults() deliberately does not set it; loading is not an
edit.
@date 2026-09-08 08:45 ]]
local dirty = false

--[[ @brief Whether the map has changed since it was last written.
-- |
-- | Watched by main.lua, so glyphmap.save is written when the customiser closes and not once per
-- | frame. Set by set, rekey and reset; NOT by deserialize, because loading is not an edit.
-- |
-- | @return boolean
-- |
-- | @date 2026-09-13 18:00
--]]
function glyphmap.dirty()   return dirty end
--[[ @brief Declares the map written.
-- |
-- | Called by whoever did the writing - main.lua, after writing the file and after loading it.
-- |
-- | @note Clearing it without writing loses the change silently.
-- |
-- | @date 2026-09-13 18:00
--]]
function glyphmap.clear_dirty() dirty = false end

--[[ @brief Every row with its live slots, in a FIXED order.
-- |
-- | THE ORDER IS THE CUSTOMISER'S ROW ORDER AND THE SAVE FILE'S LINE ORDER at once, so both stay
-- | stable across runs and a diff of the file shows only what actually changed. A moved row keeps
-- | its place; a row created by deserialize for a new key is appended.
-- |
-- | @param fn  function(key: string, row: table) - called once per row. `row` is the LIVE table:
-- |            writing it changes the map without marking it dirty; use set instead
-- |
-- | @date 2026-09-13 18:00
--]]
function glyphmap.each(fn)
    for _, key in ipairs(order) do
        fn(key, live[key])
    end
end

--[[ @brief One key's live row, or nil for a key with no row.
-- |
-- | @param key  string - an ImGuiKey name
-- | @return table | nil - the LIVE {plain, alt, alt_shift, from_letter}, not a copy: read it
-- |
-- | @date 2026-09-13 18:00
--]]
function glyphmap.slots(key)
    return live[key]
end

--[[ @brief Moves a whole row onto another key.
-- |
-- | HOW A ROW IS IDENTIFIED on a keyboard this file knows nothing about: the person presses the key
-- | they mean. The row keeps its place in the order and its `from_letter`, so reset can still send
-- | it home.
-- |
-- | REFUSES IF THAT KEY ALREADY HAS A ROW, rather than merging two sets of glyphs into one and
-- | losing whichever lost. The caller shows the reason.
-- |
-- | @param old_key  string - the key the row is on now
-- | @param new_key  string - the key it moves to; the same key is a successful no-op
-- | @return boolean, string | nil - true; or false and a reason ("no such row", "Q already has a
-- |         row")
-- |
-- | @date 2026-09-13 18:00
--]]
function glyphmap.rekey(old_key, new_key)
    if not live[old_key] then
        return false, "no such row"
    end
    if old_key == new_key then
        return true
    end
    if live[new_key] then
        return false, key_label(new_key) .. " already has a row"
    end
    live[new_key] = live[old_key]
    live[old_key] = nil
    for i, k in ipairs(order) do
        if k == old_key then
            order[i] = new_key
            break
        end
    end
    dirty = true
    return true
end

--[[ @brief Which glyph this key produces with these modifiers. THE LOOKUP the editors use.
-- |
-- | NIL MEANS "NOT OURS - HANDLE IT THE ORDINARY WAY". An unset `plain` is the normal case and is
-- | what keeps typing fast: the character queue handles the key exactly as it always did.
-- |
-- | A NAME THAT NO LONGER RESOLVES RETURNS NIL rather than erroring. A saved map can outlive the
-- | glyph catalogue it was written against, and losing one binding is a far better outcome than an
-- | editor that cannot start.
-- |
-- | @param key    string - an ImGuiKey name
-- | @param alt    boolean - Alt is held; without it, the `plain` slot is read and `shift` ignored
-- | @param shift  boolean - Shift is held; with Alt, reads `alt_shift`
-- | @return char entry | nil - ready to insert, via char.find_by_desc
-- |
-- | @date 2026-09-13 18:00
--]]
function glyphmap.entry(key, alt, shift)
    local slot = live[key]
    if not slot then
        return nil
    end
    local desc
    if alt then
        desc = shift and slot.alt_shift or slot.alt
    else
        desc = slot.plain
    end
    if not desc then
        return nil
    end
    return char.find_by_desc(desc)
end

--[[ @brief What the customiser shows in one cell: the slot's value, or "" when it is empty.
-- |
-- | EMPTY STRING RATHER THAN NIL, because every caller is putting it in a text field.
-- |
-- | @param key    string - an ImGuiKey name; a key with no row gives ""
-- | @param which  string - "plain", "alt" or "alt_shift" for a LaTeX name; "from_letter" for the
-- |               letter the row's defaults came from. Not validated: any other name gives ""
-- | @return string
-- |
-- | @date 2026-09-13 18:00
--]]
function glyphmap.name(key, which)
    local slot = live[key]
    return (slot and slot[which]) or ""
end

--[[ @brief Puts a LaTeX name into one slot, or clears it when given an empty string.
-- |
-- | VALIDATED AGAINST THE GLYPH CATALOGUE, not merely stored: a name the editor cannot draw would
-- | otherwise sit in the table looking correct and simply do nothing when pressed. It is the same
-- | lookup the `\name`-then-Space entry uses, so anything typeable by name is bindable, and
-- | nothing else is.
-- |
-- | @details Surrounding spaces are trimmed. A SINGLE CHARACTER means itself, looked up by its
-- |          ASCII code and stored under the catalogue's name for it. Anything longer gets a
-- |          leading backslash if it lacks one - no catalogue name lacks one, so "alpha" cannot
-- |          be ambiguous.
-- |
-- | @param key    string - an ImGuiKey name
-- | @param which  string - "plain", "alt" or "alt_shift"
-- | @param name   string | nil - the name; nil or blank clears the slot
-- | @return boolean, string | nil - true, marking the map dirty; or false and a reason the
-- |         customiser can display ("no such key", "no such slot", "no glyph called \foo")
-- |
-- | @date 2026-09-13 18:00
--]]
function glyphmap.set(key, which, name)
    local slot = live[key]
    if not slot then
        return false, "no such key"
    end
    if which ~= "plain" and which ~= "alt" and which ~= "alt_shift" then
        return false, "no such slot"
    end
    name = name and name:match("^%s*(.-)%s*$") or ""
    if name == "" then
        slot[which] = nil
        dirty = true
        return true
    end
    -- A leading backslash is how every name in the catalogue is written; adding it for someone who
    -- typed "alpha" is a kindness that costs nothing and cannot be ambiguous - no catalogue name
    -- lacks one.
    --[[ A SINGLE CHARACTER means itself. Typing "b" into a cell used to be prefixed into "\\b",
    which is not a name in the catalogue, so it was refused with "no glyph called \\b" - and there
    was no other way to say "this key should type b". Plain characters live in the catalogue by
    their ASCII code, not by a name, so they need their own lookup.

    Stored as the name the catalogue knows it by, so everything downstream still deals in one kind
    of value; only the way it was ENTERED differs. ]]
    if #name == 1 then
        local by_char = char.find_by_ascii(name)
        if not by_char then
            return false, "nothing types " .. name
        end
        slot[which] = by_char.desc or name
        dirty = true
        return true
    end
    if name:sub(1, 1) ~= "\\" then
        name = "\\" .. name
    end
    if not char.find_by_desc(name) then
        return false, "no glyph called " .. name
    end
    slot[which] = name
    dirty = true
    return true
end

--[[ @brief Puts one row back to the factory map - glyphs and home key - or the WHOLE map when given
-- |        nothing.
-- |
-- | THE FACTORY IS char.lua, which is never mutated, so a reset is a copy from there. One row is
-- | restored completely, including a move back to the key its letter defaults to, unless another
-- | row occupies that key - see the comment inside.
-- |
-- | @param letter  string | nil - the row's KEY name ("ImGuiKey_Q"), despite the parameter's name;
-- |                nil resets every row
-- | @return boolean - true, marking the map dirty; false for a key with no row
-- |
-- | @note The no-argument form is the customiser's "default all", armed behind two clicks there
-- |       because it is not undoable from inside the panel.
-- |
-- | @date 2026-09-13 18:00
--]]
function glyphmap.reset(letter)
    if not letter then
        install_defaults()
        dirty = true
        return true
    end
    local slot = live[letter]
    if not slot then
        return false
    end
    --[[ Restores the row COMPLETELY: its glyphs and the key it belongs on.

    It used to restore only the glyphs and leave the row wherever it had been moved to, on the
    reasoning that the two are separate edits. In use that reads as the button not working at all -
    move a row, press default, and nothing appears to change, because the visible thing about a
    moved row is where it is. Reported 2026-09-07: "default doesn't reset the row". A button called
    "default" should leave nothing behind.

    The move back is skipped when the row's home key is occupied by some OTHER row, since taking it
    would silently destroy that one. The glyphs are still restored in that case, so the button
    always does something, and the row can be moved by hand once the occupant is dealt with. ]]
    local from = slot.from_letter
    local home = from and key_name_for(from)
    local greek_plain, greek_shift = char.greek_for_key(from)
    live[letter] = {
        plain = nil,
        alt = greek_plain,
        alt_shift = greek_shift,
        from_letter = from,
    }
    if home and home ~= letter and not live[home] then
        live[home] = live[letter]
        live[letter] = nil
        for i, k in ipairs(order) do
            if k == letter then
                order[i] = home
                break
            end
        end
    end
    dirty = true
    return true
end

--[[ @brief The map as text: one line per row that differs from the factory setting.
-- |
-- | ONLY DIVERGENCES, for the reason keymap.lua's own serialize gives: a file listing every row
-- | would freeze today's defaults into it forever, so improving one later would never reach anyone
-- | who had opened the customiser once.
-- |
-- | A MOVED ROW IS A DIVERGENCE even when its glyphs are untouched, and `from_letter` rides along
-- | so it can still be reset to what it started as.
-- |
-- | @return string - "key<TAB>from_letter|plain|alt|alt_shift" lines in row order, joined by
-- |         newlines; empty when everything is at factory
-- |
-- | @date 2026-09-13 18:00
--]]
function glyphmap.serialize()
    local lines = {}
    for _, key in ipairs(order) do
        local now = live[key]
        local from = now.from_letter
        local default_key = from and key_name_for(from)
        local same_place = (key == default_key)
        local greek_plain, greek_shift = char.greek_for_key(from)
        local same_glyphs = now.plain == nil
                and now.alt == greek_plain
                and now.alt_shift == greek_shift
        if not (same_place and same_glyphs) then
            lines[#lines + 1] = key .. "\t" .. (from or "") .. "|" .. (now.plain or "")
                    .. "|" .. (now.alt or "") .. "|" .. (now.alt_shift or "")
        end
    end
    return table.concat(lines, "\n")
end

--[[ @brief Replaces the live map with what serialize wrote.
-- |
-- | STARTS FROM A CLEAN SET OF DEFAULTS, so a row the file no longer mentions returns to factory
-- | rather than keeping whatever the previous load left behind.
-- |
-- | A NAME THAT NO LONGER RESOLVES IS DROPPED and reported rather than kept: keeping it would leave
-- | a key that looks bound and does nothing. An unreadable line is skipped, for the same reason a
-- | bad save never stops the app starting.
-- |
-- | @details A line naming a key with no row CREATES one - moving a row there is the point. It
-- |          takes its original letter's place in the order when that letter's row is still at
-- |          home, and is appended otherwise.
-- |
-- | @param text  string | nil - anything but a string leaves the factory map in place
-- | @param warn  function(msg: string) | nil - told about each dropped name and unreadable line
-- |
-- | @note Does not touch the dirty flag; main.lua clears it after loading.
-- |
-- | @date 2026-09-13 18:00
--]]
function glyphmap.deserialize(text, warn)
    install_defaults()
    if type(text) ~= "string" then
        return
    end
    for line in text:gmatch("[^\n]+") do
        local key, rest = line:match("^(%S+)\t(.*)$")
        local from, p, a, as = nil, nil, nil, nil
        if rest then
            from, p, a, as = rest:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
        end
        if key and as then
            --[[ A row may name a key that had no default row of its own - that is the whole point
            of being able to move one - so it is CREATED rather than skipped. Its place in the
            order follows where its original letter sat, when it has one. ]]
            if not live[key] then
                local home = (from ~= "" and key_name_for(from)) or nil
                if home and live[home] then
                    live[home] = nil
                    for i, k in ipairs(order) do
                        if k == home then order[i] = key break end
                    end
                else
                    order[#order + 1] = key
                end
                live[key] = {}
            end
            local slot = live[key]
            slot.plain, slot.alt, slot.alt_shift = nil, nil, nil
            slot.from_letter = (from ~= "" and from) or slot.from_letter
            for which, name in pairs({plain = p, alt = a, alt_shift = as}) do
                if name and name ~= "" then
                    if char.find_by_desc(name) then
                        slot[which] = name
                    elseif warn then
                        warn("glyphmap: dropping unknown glyph for " .. key
                                .. " " .. which .. ": " .. name)
                    end
                end
            end
        elseif warn then
            warn("glyphmap: unreadable line: " .. line)
        end
    end
end

return glyphmap

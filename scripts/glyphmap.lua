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

--[[ The label a person reads for a key, for the customiser's own rows. @date 2026-09-08 08:45 ]]
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
        live[key] = {
            plain = nil,
            alt = char.greek_alt[letter],
            alt_shift = char.greek_alt_shift[letter],
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

function glyphmap.dirty()   return dirty end
function glyphmap.clear_dirty() dirty = false end

-- The letters, in a fixed order, with their live slots. Iteration order is the customiser's row
-- order and the file's line order, so both stay stable across runs.
function glyphmap.each(fn)
    for _, key in ipairs(order) do
        fn(key, live[key])
    end
end

--[[ One key's live slots, or nil for a key with no row. @date 2026-09-08 08:45 ]]
function glyphmap.slots(key)
    return live[key]
end

--[[ Moves a whole row onto another key - which is how a row is identified on a keyboard this file
knows nothing about: the person presses the key they mean.

Refuses if that key already has a row, rather than merging two sets of glyphs into one and losing
whichever lost. The caller shows the reason.
@date 2026-09-08 08:45 ]]
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

--[[ THE LOOKUP the editors use: which glyph does this key produce with these modifiers, as a
char.lua entry ready to insert, or nil to mean "not ours - handle it the ordinary way".

`plain` returning nil is the normal case and is what keeps typing fast: the character queue
handles the key exactly as it always did, and nothing in this file is consulted per keystroke.

A name that no longer resolves returns nil rather than erroring. A saved map can outlive the glyph
catalogue it was written against, and losing one binding is a far better outcome than an editor
that cannot start.
@date 2026-09-08 08:45 ]]
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

-- What the customiser shows in a cell: the name, or "" when the slot is unset.
function glyphmap.name(key, which)
    local slot = live[key]
    return (slot and slot[which]) or ""
end

--[[ Accepts a LaTeX name into one slot, or clears it when given an empty string. Returns true, or
false plus a reason the customiser can display.

VALIDATED AGAINST THE GLYPH CATALOGUE, not merely stored: a name the editor cannot draw would
otherwise sit in the table looking correct and simply do nothing when pressed, which is the worst
of both. char.find_by_desc() is the same lookup the `\name`-then-Space entry uses, so anything you
can type by name is bindable, and nothing else is.
@date 2026-09-08 08:45 ]]
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

-- Back to the factory tables, for one letter or (with no argument) all of them.
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
    live[letter] = {
        plain = nil,
        alt = from and char.greek_alt[from] or nil,
        alt_shift = from and char.greek_alt_shift[from] or nil,
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

--[[ One line per letter that differs from the factory setting, "letter<TAB>plain|alt|alt_shift".
Only divergences, for the reason keymap.lua's own serialize gives: a file listing every letter
would freeze today's defaults into it forever, so improving one later would never reach anyone who
had opened the customiser once. ]]
--[[ "key<TAB>from_letter|plain|alt|alt_shift", one line per row that differs from the factory
setting - including a row that has simply MOVED to another key, which is a divergence even when its
glyphs are untouched. `from_letter` rides along so a moved row can still be reset to what it
started as.
@date 2026-09-08 08:45 ]]
function glyphmap.serialize()
    local lines = {}
    for _, key in ipairs(order) do
        local now = live[key]
        local from = now.from_letter
        local default_key = from and key_name_for(from)
        local same_place = (key == default_key)
        local same_glyphs = now.plain == nil
                and now.alt == (from and char.greek_alt[from])
                and now.alt_shift == (from and char.greek_alt_shift[from])
        if not (same_place and same_glyphs) then
            lines[#lines + 1] = key .. "\t" .. (from or "") .. "|" .. (now.plain or "")
                    .. "|" .. (now.alt or "") .. "|" .. (now.alt_shift or "")
        end
    end
    return table.concat(lines, "\n")
end

--[[ Reads one back, starting from a clean set of defaults so a letter the file no longer mentions
returns to factory rather than keeping whatever the previous load left behind.

A name that no longer resolves is DROPPED and reported rather than kept: keeping it would leave a
key that looks bound and does nothing. An unreadable line is skipped for the same reason a bad
save never stops the app starting.
@date 2026-09-08 08:45 ]]
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

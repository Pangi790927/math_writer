--[[
panel_keymap.lua - the F2 screen: the keybind table.

One row per action. The bind column holds a box per binding, and each box offers two ways to change
it, because the two suit different moments:

  TYPE IT      Click the text and write "Ctrl+Shift+K". Good when you know exactly what you want,
               and the only way to enter a key this keyboard cannot conveniently press.
  RECORD IT    Click the round button and press the combination. Good when you know the shape of
               the chord in your hands but not its name.

Recording ACCUMULATES and never auto-commits (ruled 2026-09-07). Every key pressed while recording
is added; releasing changes nothing; clicking the record button again clears the attempt and starts
over; the tick saves and the cross abandons. That is deliberately different from the usual
"press-and-release commits" design: with an explicit tick, a mis-press costs one click instead of a
wrongly-saved binding, and - the reason that matters most here - EVERY key becomes bindable,
including Escape, which would otherwise have to stay reserved as the cancel gesture.

A second non-modifier key is REFUSED rather than replacing the first. Also ruled.

Saving happens when the panel CLOSES, not per keystroke - see main.lua, which watches
keymap.dirty(). A half-typed binding must never reach disk.
@date 2026-09-08 08:45
]]

local vc = require("virt_composer")
local keymap = require("keymap")
local glyphmap = require("glyphmap")

local panel_keymap = {}

--[[ Twice ImGui's normal size (asked for 2026-09-07), same as the help page. The column widths
below are UNSCALED and multiplied on use, so the table grows with the text instead of the text
outgrowing its columns. At this window width the three columns plus the key controls are a tight
fit - the id and description columns are deliberately narrower than they would be at 1x, because
the Keys column is the one that must not clip.
@date 2026-09-08 08:45 ]]
local FONT_SCALE  = 2
-- Sized against the LONGEST entry each column actually holds, at the doubled size:
-- "app.profiler_record" (19 chars) and "Record slow frames to perf_spikes.log" (37).
local COL_ACTION  = 145
local COL_DESC    = 215
local BG_COLOR    = 0xee1a1a1a
local WARN_COLOR  = 0xffff8080
-- ABGR, as every ImGui colour here is: opaque, full red, a little green and blue so it does not
-- vibrate against the dark background.
local REC_COLOR   = 0xff4040ff

--[[ Per-frame recording state. Deliberately NOT per binding: only one box can be recording at a
time, and making that structural means there is no way to leave a second box quietly capturing in
the background. `accum` is the set of modifiers plus the single non-modifier key gathered so far.
@date 2026-09-08 08:45 ]]
local rec = nil      -- {id=, index=, ctrl=, shift=, alt=, key=, note=}

--[[ Which keys count as MODIFIERS rather than as the binding's main key.

The ReservedForMod* entries are not decoration and their absence was a real bug, found the first
time the recorder was actually driven (2026-09-07): ImGui reports a modifier press on BOTH the
physical key (ImGuiKey_LeftCtrl) and an internal synthetic one (ImGuiKey_ReservedForModCtrl), and
both sit inside the NamedKey range that keys_pressed() scans. Without them here the synthetic key
was taken for the main key and Ctrl+Shift+K recorded as "Ctrl+Shift+ReservedForModCtrl" - after
which the real K was refused as a second key.
@date 2026-09-08 08:45 ]]
local MODIFIER_KEYS = {
    ImGuiKey_LeftCtrl = "ctrl",   ImGuiKey_RightCtrl = "ctrl",
    ImGuiKey_LeftShift = "shift", ImGuiKey_RightShift = "shift",
    ImGuiKey_LeftAlt = "alt",     ImGuiKey_RightAlt = "alt",
    ImGuiKey_LeftSuper = "super", ImGuiKey_RightSuper = "super",
    ImGuiKey_ReservedForModCtrl  = "ctrl",
    ImGuiKey_ReservedForModShift = "shift",
    ImGuiKey_ReservedForModAlt   = "alt",
    ImGuiKey_ReservedForModSuper = "super",
}

--[[ The panel's own state, created with the content state and living there.

  section     which half is on screen: "keys" or "letters"
  editing     which cell is being typed into, as an id-and-index key, or nil
  buffer      what has been typed into it so far - always a string, see buffer_of()
  error       why the current cell will not commit; panel_error the same for the panel
  focus_next  ask ImGui for keyboard focus on the next frame, after a cell has just been opened
  confirm_all the two-click arm on "default all", see draw_letters()
@date 2026-09-08 08:45 ]]
function panel_keymap.new_state()
    -- `section` is which category is on screen: "keys" or "letters".
    return {section = "keys", editing = nil, buffer = "", error = nil, panel_error = nil,
            focus_next = false, confirm_all = false}
end

-- The buffer is a STRING, always. A nil reaching ImGui_InputText's const char* parameter is not a
-- bad frame, it is an abort (see the InputText call below), so this is checked rather than assumed.
local function buffer_of(kstate)
    if type(kstate.buffer) ~= "string" then
        kstate.buffer = ""
    end
    return kstate.buffer
end

-- Turns the accumulator into the same text the field would accept, so both routes converge on
-- keymap.parse() and there is exactly one definition of what a binding string means.
local function rec_text()
    if not rec then
        return ""
    end
    local parts = {}
    if rec.ctrl  then parts[#parts + 1] = "Ctrl"  end
    if rec.shift then parts[#parts + 1] = "Shift" end
    if rec.alt   then parts[#parts + 1] = "Alt"   end
    parts[#parts + 1] = rec.key and rec.key:gsub("^ImGuiKey_", "") or "_"
    return table.concat(parts, "+")
end

--[[ One frame of recording. Every key that went DOWN this frame is folded in - a press, not a held
state, which is what lets you press and release Ctrl and then press E and still get Ctrl+E.
@date 2026-09-08 08:45 ]]
local function poll_recording()
    if not rec then
        return
    end
    --[[ A GLYPH row records a bare key, not a chord: the row already means "with Alt" and "with
    Alt+Shift" in its own columns, so a modifier pressed while choosing the key would be recorded
    into a combination that has nowhere to go. Modifiers are ignored here rather than refused,
    since holding one on the way to a key is easy to do by accident. ]]
    if rec.id == "glyph" then
        local pressed = vc.ImGui_keys_pressed and vc.ImGui_keys_pressed() or {}
        for _, id in ipairs(pressed) do
            local name = keymap.key_name(id)
            if name and not MODIFIER_KEYS[name] then
                --[[ ONE key finishes it. A glyph row is identified by a single key, so the moment
                one arrives there is nothing further to wait for - staying armed only means the
                next key pressed silently replaces the choice just made, and the button sitting lit
                afterwards reads as "still recording" when it is really "done, now click the tick".
                Reported 2026-09-07: "recording is not deselected after I enter my character".

                The row it belongs to applies it and clears the recorder; this only says which key
                and that it is settled. (The SHORTCUT recorder above is deliberately different: a
                chord is not finished by its first key, so it accumulates until the tick.) ]]
                rec.key = name
                rec.done = true
            end
        end
        return
    end
    local pressed = vc.ImGui_keys_pressed and vc.ImGui_keys_pressed() or {}
    for _, id in ipairs(pressed) do
        local name = keymap.key_name(id)
        if name then
            local mod = MODIFIER_KEYS[name]
            if mod then
                rec[mod] = true
            elseif rec.key and rec.key ~= name then
                -- Ruled 2026-09-07: "not allowed". Refused rather than replacing, and said out
                -- loud - a box that silently swapped the key would be worse than one that stops.
                rec.note = "one key only - press o to restart"
            else
                rec.key = name
                rec.note = nil
            end
        end
    end
end

--[[ Accepts whatever is in the buffer into the cell being edited, and closes it on success.

The one place a typed binding or a typed glyph name becomes real, so both routes - typing and
recording - end here and there is one definition of what is acceptable. A refusal leaves the cell
open with the reason in it rather than discarding what was typed.
@date 2026-09-08 08:45 ]]
local function commit(kstate)
    if not rec or not rec.key then
        return
    end
    local ok, why = keymap.set_bind(rec.id, rec.index, rec_text())
    kstate.error = ok and nil or (rec.id .. ": " .. tostring(why))
    rec = nil
end

--[[ The record control: a "Rec" button with a red dot beside it, HOLLOW when idle and FILLED
while this slot is recording.

A drawn circle rather than a character, because the indicator has to be red and ImGui's default
font gives no way to colour one glyph of a label - and because a hollow ring and a solid disc read
as "armed" and "recording" at a glance in a way that "o" and "O" never did.

It sits AFTER the binding it belongs to (moved there 2026-09-07): the key is what the eye is
looking for when scanning the column, so it comes first and the control follows it.

Returns true when the button was pressed this frame. The circle is drawn on the window draw list in
absolute coordinates, which is why it needs GetCursorScreenPos - the layout cursor is
window-relative and would put the dot in the wrong place inside a scrolled table.
@date 2026-09-08 08:45 ]]
local function rec_button(active, line_h)
    local pressed = vc.ImGui_SmallButton("Rec##rec")
    vc.ImGui_SameLine(0, 6)
    local r = math.max(4, math.floor(line_h * 0.28))
    local p = vc.ImGui_GetCursorScreenPos()
    local cx, cy = p.x + r, p.y + line_h * 0.5
    if active then
        vc.ImGui_AddCircleFilled({x = cx, y = cy}, r, REC_COLOR)
    else
        vc.ImGui_AddCircle({x = cx, y = cy}, r, REC_COLOR, 1.5)
    end
    -- Nothing was submitted for the circle, so the cursor has to be walked past it by hand or the
    -- next widget draws on top of the dot.
    vc.ImGui_SameLine(0, r * 2 + 6)
    return pressed
end

--[[ The two halves of the binding editor, separated because they now sit in different COLUMNS -
the field with the bindings, the tick and cross with the other controls. Kept as two functions
rather than one with a flag so each column's pass reads as one thing, and so the two can never
disagree about how many lines they draw (which is what keeps the columns aligned).

edit_box() below still draws both together, for the letters table, whose cells are self-contained.
@date 2026-09-08 08:45 ]]
local function edit_box_field(kstate)
    --[[ Focus the field on the frame it appears, and only that frame - see edit_box()'s own note:
    the click that opened this focused the BUTTON, not the field that replaced it, and re-focusing
    every frame would make the field impossible to leave. ]]
    if kstate.focus_next then
        vc.ImGui_SetKeyboardFocusHere(0)
        kstate.focus_next = false
    end
    local res = vc.ImGui_InputText("##edit", buffer_of(kstate), 48)
    if res and res[1] then
        kstate.buffer = res[2] or ""
    end
end

--[[ The tick and cross beside a cell being edited: commit, or abandon and leave the binding as it
was. Split out of the field itself because the two now sit in different COLUMNS. @date 2026-09-08 08:45 ]]
local function edit_box_buttons(kstate, id, index)
    if vc.ImGui_SmallButton("v##save") then
        local ok, why = keymap.set_bind(id, index, kstate.buffer)
        if ok then
            kstate.editing, kstate.error = nil, nil
        else
            kstate.error = id .. ": " .. tostring(why)
        end
    end
    vc.ImGui_SameLine(0, 4)
    if vc.ImGui_SmallButton("x##cancel") then
        kstate.editing, kstate.error = nil, nil
    end
end

--[[ The text field for ONE binding slot, plus its accept and cancel buttons.

Factored out because it is needed from two places and used to exist in only one: inside the loop
over an action's EXISTING bindings. The "+" button sets the edit target to index #binds+1, which
that loop never reaches - so "+" set a state nothing rendered, and the button looked dead. It is
called below both for an existing slot and for the pending new one.

`index` beyond the end appends: keymap.set_bind() clamps to #binds+1, so the same call serves both.
@date 2026-09-08 08:45 ]]
local function edit_box(kstate, id, index)
    --[[ ImGui_InputText returns a std::pair, and virt_composer pushes a pair as ONE Lua table
    {changed, text} - not as two values. Written as `local changed, text = ...` it binds the TABLE
    to `changed` and nil to `text`, which then went back in as the string parameter on the next
    frame and threw "failed conversion to string from [nil]" - taking the whole app down, because
    the error unwound out of the table before EndTable() and ImGui aborts on the imbalance. ]]
    --[[ Focus the field on the frame it appears, and only that frame. Without this the box is drawn
    but nothing typed reaches it - ImGui routes characters to the focused item, and the click that
    opened this focused the BUTTON, not the field that replaced it. Re-focusing every frame would
    instead make the field impossible to leave. ]]
    if kstate.focus_next then
        vc.ImGui_SetKeyboardFocusHere(0)
        kstate.focus_next = false
    end
    local res = vc.ImGui_InputText("##edit", buffer_of(kstate), 48)
    if res and res[1] then
        kstate.buffer = res[2] or ""
    end
    vc.ImGui_SameLine(0, 6)
    if vc.ImGui_SmallButton("v##save") then
        local ok, why = keymap.set_bind(id, index, kstate.buffer)
        if ok then
            kstate.editing, kstate.error = nil, nil
        else
            kstate.error = id .. ": " .. tostring(why)
        end
    end
    vc.ImGui_SameLine(0, 4)
    if vc.ImGui_SmallButton("x##cancel") then
        kstate.editing, kstate.error = nil, nil
    end
end

--[[ The LETTERS section: what each letter key produces, per modifier.

Every letter is listed, Greek or not, because "customisable" with a fixed list of exceptions is not
customisable - a key that happens to have no Greek letter today (q, and every capital that looks
like its Latin counterpart) is exactly the key someone will want to put something else on.

Cells hold LaTeX names, validated on commit against the same catalogue the `\name`-then-Space entry
uses, so anything typeable by name is bindable and nothing else is. An empty PLAIN cell means "the
letter itself", which is why it reads as blank rather than as an error.

Reuses edit_box() and the same kstate.editing convention as the keys table, so the two sections
behave identically: click a cell, type, tick to save, cross to abandon. The edit key is prefixed so
a letter cell and an action row can never collide on it.
@date 2026-09-08 08:45 ]]
local LETTER_COLUMNS = {
    {which = "plain",     title = "Types"},
    {which = "alt",       title = "With Alt"},
    {which = "alt_shift", title = "With Alt+Shift"},
}

local function draw_letters(kstate, line_h)
    --[[ "Default all", in two clicks.

    One click arms it and the label says so; the second does it. A single-click version would be a
    stray mouse away from discarding a whole layout - and for the person this table exists for,
    someone who has moved rows key by key to match a non-US keyboard, that is a long evening
    thrown away with no undo behind it (this is configuration, not the document).

    Anything else disarms it: switching section, editing a cell, starting a recording. So it only
    fires when two deliberate clicks happen in a row on this one button. ]]
    vc.ImGui_SetCursorPos({x = 24, y = 20 + line_h * 3})
    if kstate.confirm_all then
        if vc.ImGui_SmallButton("really reset every letter?##dall") then
            glyphmap.reset()
            kstate.confirm_all = false
            kstate.editing, kstate.error = nil, nil
        end
        vc.ImGui_SameLine(0, 8)
        if vc.ImGui_SmallButton("no##dallno") then
            kstate.confirm_all = false
        end
    elseif vc.ImGui_SmallButton("default all##dall") then
        kstate.confirm_all = true
    end

    vc.ImGui_SetCursorPos({x = 24, y = 20 + line_h * 4})
    local flags = vc.ImGuiTableFlags_Borders + vc.ImGuiTableFlags_RowBg
            + vc.ImGuiTableFlags_ScrollY + vc.ImGuiTableFlags_Resizable
    local size = vc.ImGui_GetDisplaySize()
    if not vc.ImGui_BeginTable("letters_table_v1", 5, flags,
            {x = size.x - 48, y = size.y - 20 - line_h * 4 - 20}, 0) then
        return
    end
    -- Sized so the stretch column at the end still fits a "default" button at the doubled font:
    -- it was clipped to "defaul" when these were wider.
    vc.ImGui_TableSetupColumn("Key", vc.ImGuiTableColumnFlags_WidthFixed, 60 * FONT_SCALE, 0)
    for _, col in ipairs(LETTER_COLUMNS) do
        vc.ImGui_TableSetupColumn(col.title, vc.ImGuiTableColumnFlags_WidthFixed,
                125 * FONT_SCALE, 0)
    end
    vc.ImGui_TableSetupColumn("", vc.ImGuiTableColumnFlags_WidthStretch, 0, 0)
    vc.ImGui_TableHeadersRow()

    local rows_ok, rows_err = pcall(function()
    glyphmap.each(function(letter, slots)
        vc.ImGui_TableNextRow(0, 0)
        vc.ImGui_PushID("letter_" .. letter)

        --[[ The KEY column, and the record button that changes which key this row is.

        The label is only what the key is called on a US layout; on any other, the key that types
        the Greek letters is somewhere else entirely. There is no way to work that out from here -
        so the answer is to press it. Rec arms the row, the next key pressed becomes its key, and
        the glyphs move with it. That is the whole reason the map is keyed by physical key rather
        than by letter. ]]
        vc.ImGui_TableNextColumn()
        local recording = rec and rec.id == "glyph" and rec.index == letter
        --[[ A finished recording is applied here rather than in poll_recording(), which has no
        row context and no place to report a refusal - moving onto an occupied key has to say so
        somewhere the person is looking. ]]
        if recording and rec.done then
            local target = rec.key
            rec = nil
            recording = false
            if target then
                local ok, why = glyphmap.rekey(letter, target)
                kstate.error = ok and nil or (letter .. ": " .. tostring(why))
            end
        end
        vc.ImGui_Text(recording and (rec.key and glyphmap.key_label(rec.key) or "press a key")
                or glyphmap.key_label(letter))
        vc.ImGui_SameLine(0, 6)
        if rec_button(recording, line_h) then
            rec = {id = "glyph", index = letter}
            kstate.editing, kstate.error = nil, nil
            kstate.confirm_all = false
        end
        if recording then
            -- Only a way out: the key itself is the confirmation, so there is nothing for a tick
            -- to do that pressing the key has not already done.
            if vc.ImGui_SmallButton("x##kreccancel") then
                rec = nil
            end
        end

        for _, col in ipairs(LETTER_COLUMNS) do
            vc.ImGui_TableNextColumn()
            vc.ImGui_PushID(col.which)
            local key = "L:" .. letter .. ":" .. col.which
            if kstate.editing == key then
                --[[ Committed through glyphmap.set(), which validates the name and reports why it
                refused - the cell keeps the text and the error so it can be corrected rather than
                silently discarded. ]]
                if kstate.focus_next then
                    vc.ImGui_SetKeyboardFocusHere(0)
                    kstate.focus_next = false
                end
                local res = vc.ImGui_InputText("##ledit", buffer_of(kstate), 32)
                if res and res[1] then
                    kstate.buffer = res[2] or ""
                end
                vc.ImGui_SameLine(0, 6)
                if vc.ImGui_SmallButton("v##lsave") then
                    local ok, why = glyphmap.set(letter, col.which, kstate.buffer)
                    if ok then
                        kstate.editing, kstate.error = nil, nil
                    else
                        kstate.error = letter .. ": " .. tostring(why)
                    end
                end
                vc.ImGui_SameLine(0, 4)
                if vc.ImGui_SmallButton("x##lcancel") then
                    kstate.editing, kstate.error = nil, nil
                end
            else
                -- An unset PLAIN cell shows the letter it inserts, in brackets, so the row reads
                -- as "a types a" rather than as a hole.
                local shown = slots[col.which]
                if not shown then
                    --[[ An unset PLAIN cell shows the character the key types on its own, in
                    brackets. Derived from the key's own name rather than from the row's original
                    letter, so a row moved to another key says what THAT key types - and a key
                    whose name is not a single character says so plainly instead of printing
                    "(ImGuiKey_A)" at somebody. ]]
                    local suffix = (letter:gsub("^ImGuiKey_", "")):lower()
                    shown = (col.which == "plain")
                            and ((#suffix == 1) and ("(" .. suffix .. ")") or "(itself)")
                            or "-"
                end
                if vc.ImGui_SmallButton(shown .. "##lcell") then
                    kstate.editing = key
                    kstate.buffer = slots[col.which] or ""
                    kstate.focus_next = true
                    kstate.error = nil
                    kstate.confirm_all = false
                end
            end
            vc.ImGui_PopID()
        end

        vc.ImGui_TableNextColumn()
        --[[ Matched on the whole key name, not two characters. sub(1, 2) was left over from when
        a row was a single letter; against "ImGuiKey_A:" it never matched, so a row's own error was
        never shown next to it. ]]
        local tag = letter .. ":"
        if kstate.error and kstate.error:sub(1, #tag) == tag then
            vc.ImGui_Text(kstate.error:sub(#tag + 2))
            vc.ImGui_SameLine(0, 10)
        end
        if vc.ImGui_SmallButton("default##lreset") then
            glyphmap.reset(letter)
            kstate.editing, kstate.error = nil, nil
        end

        vc.ImGui_PopID()
    end)
    end)
    vc.ImGui_EndTable()
    if not rows_ok then
        kstate.panel_error = "letters: " .. tostring(rows_err)
    end
end

--[[ Draws the whole screen. Called from content.draw() while the panel is open; content's
handle_input has already returned early, so this owns the frame.

Returns nothing - every effect goes through keymap, which is also what makes this panel testable
without a display: the registry can be driven directly and asked what it now holds.
@date 2026-09-08 08:45 ]]
function panel_keymap.draw(kstate)
    local size = vc.ImGui_GetDisplaySize()
    vc.ImGui_AddRectFilled({x = 0, y = 0}, {x = size.x, y = size.y}, BG_COLOR, 0)

    poll_recording()

    local base = vc.ImGui_GetFontSize and vc.ImGui_GetFontSize() or 13
    vc.ImGui_PushFont(base * FONT_SCALE)
    local line_h = base * FONT_SCALE + 2

    vc.ImGui_SetCursorPos({x = 24, y = 20})
    vc.ImGui_Text("Keys    (" .. keymap.label("app.customiser") .. " or "
            .. keymap.label("panel.close") .. " closes and saves,  "
            .. keymap.label("app.help") .. " is the help)")
    --[[ The category selector: a row of buttons, the active one bracketed. Buttons rather than
    ImGui's own tab bar because the whole panel is drawn at a pushed font size and these follow it
    with no styling work - and a "tab" that is really one section of one screen reads the same
    either way. Switching abandons any edit in progress: the cell being typed into is about to
    stop existing. ]]
    vc.ImGui_SetCursorPos({x = 24, y = 20 + line_h})
    for _, sec in ipairs({{id = "keys", label = "Shortcuts"},
                          {id = "letters", label = "Letters"}}) do
        local active = (kstate.section == sec.id)
        if vc.ImGui_SmallButton((active and ("[" .. sec.label .. "]") or sec.label)
                .. "##sec" .. sec.id) then
            kstate.section = sec.id
            kstate.editing, kstate.error = nil, nil
            kstate.confirm_all = false
            rec = nil
        end
        vc.ImGui_SameLine(0, 10)
    end
    -- Kept short enough to fit the window at the doubled size - the long form ran off the edge.
    vc.ImGui_Text(kstate.section == "letters"
            and "A glyph name like \\alpha, or one character. Rec picks the key."
            or "Type a binding, or press the record button. Suffix +All ignores modifiers.")

    if kstate.panel_error then
        vc.ImGui_SetCursorPos({x = 24, y = 20 + line_h * 2})
        vc.ImGui_Text("! " .. kstate.panel_error)
    end

    if kstate.section == "letters" then
        draw_letters(kstate, line_h)
        vc.ImGui_PopFont()
        return
    end

    vc.ImGui_SetCursorPos({x = 24, y = 20 + line_h * (kstate.panel_error and 4 or 3)})
    local flags = vc.ImGuiTableFlags_Borders + vc.ImGuiTableFlags_RowBg
            + vc.ImGuiTableFlags_ScrollY + vc.ImGuiTableFlags_Resizable
    --[[ "_v2", and the suffix earns its keep. The table is Resizable, so ImGui stores its column
    widths in imgui.ini against this id and TableSetupColumn's widths apply only the FIRST time the
    table is ever seen. When the font doubled, the columns had to grow with it - but anyone who had
    already opened this panel kept the old narrow widths out of their ini and saw the description
    column clipped. Changing the id makes ImGui treat it as a new table and take the new defaults
    once. Column widths remain draggable and are remembered from then on. ]]
    --[[ FOUR columns now (the controls moved into their own), and "_v3" because of it: ImGui stores
    a table's column layout against its id, and a stored 3-column layout does not describe a
    4-column table. The count in BeginTable and the number of TableSetupColumn calls must agree or
    it asserts outright - which is exactly what happened when only one of the two was updated. ]]
    if vc.ImGui_BeginTable("keymap_table_v3", 4, flags,
            {x = size.x - 48,
             y = size.y - 20 - line_h * (kstate.panel_error and 4 or 3) - 20}, 0) then
        vc.ImGui_TableSetupColumn("Action", vc.ImGuiTableColumnFlags_WidthFixed,
                COL_ACTION * FONT_SCALE, 0)
        vc.ImGui_TableSetupColumn("Description", vc.ImGuiTableColumnFlags_WidthFixed,
                COL_DESC * FONT_SCALE, 0)
        --[[ The four widths have to fit the window between them: the three fixed ones plus room for
        the controls. They did not, and the controls column was squeezed off the right edge - which
        is worse than the misalignment it was meant to fix. ]]
        vc.ImGui_TableSetupColumn("Keys", vc.ImGuiTableColumnFlags_WidthFixed, 150 * FONT_SCALE, 0)
        --[[ The controls get a COLUMN of their own rather than trailing each binding inline.
        Flowed after the key text they started at a different x on every row, because a binding's
        width is whatever its name happens to be - "F1" against "Ctrl+Shift+Left" - so the buttons
        staggered down the table and there was nothing to aim at. In a column they line up.
        Requested 2026-09-07. ]]
        vc.ImGui_TableSetupColumn("", vc.ImGuiTableColumnFlags_WidthStretch, 0, 0)
        vc.ImGui_TableHeadersRow()

        --[[ The row loop runs inside a pcall so that EndTable() ALWAYS runs.

        main.lua already wraps draw in a pcall, but that is not enough here and the difference cost
        an abort: a Lua error thrown between BeginTable and EndTable unwinds past EndTable, ImGui is
        left with an unbalanced window stack, and the next End() fails an assertion - killing the
        process outright rather than losing a frame. Catching it here keeps ImGui balanced, so a bug
        in this panel degrades into an error message in the panel instead of taking the app down. ]]
        local rows_ok, rows_err = pcall(function()
        keymap.each(function(id, action)
            local line_h = line_h
            vc.ImGui_TableNextRow(0, 0)
            -- One id per ROW, so every widget inside is distinct even though the labels repeat.
            -- Without this the first row's field would receive every row's typing.
            vc.ImGui_PushID(id)

            vc.ImGui_TableNextColumn()
            vc.ImGui_Text(id)

            --[[ Notes are gathered BEFORE any column is drawn, because they belong in the
            Description column and that column is rendered first - but the facts they report
            (which bindings clash, what the recorder is complaining about) are only discovered
            while walking the bindings, which happens in the Keys column afterwards. Collecting
            first is what lets the message sit next to the description instead of cluttering the
            Keys column, which should hold controls and nothing else. ]]
            local notes = {}
            for _, bind in ipairs(action.binds) do
                local clash = keymap.conflicts(bind, id)
                if #clash > 0 then
                    local who = clash[1] .. (#clash > 1 and (" +" .. (#clash - 1)) or "")
                    notes[#notes + 1] = (#action.binds > 1 and (keymap.format(bind) .. " ") or "")
                            .. "also " .. who
                end
            end
            if rec and rec.id == id and rec.note then
                notes[#notes + 1] = rec.note
            end
            -- The panel keeps one error string, tagged with the action it came from, so only the
            -- row that actually failed shows it.
            if kstate.error and kstate.error:sub(1, #id + 1) == id .. ":" then
                notes[#notes + 1] = kstate.error:sub(#id + 3)
            end

            vc.ImGui_TableNextColumn()
            vc.ImGui_Text(action.desc)
            for _, note in ipairs(notes) do
                vc.ImGui_Text(note)
            end

            vc.ImGui_TableNextColumn()
            --[[ TWO PASSES over the bindings, one per column. ImGui fills a table cell
            top-to-bottom, so writing every binding into the Keys cell and every binding's controls
            into the next produces two stacks of the same height whose lines meet - which is what
            "align" means here. Interleaving them in one cell cannot align, because each line's
            width depends on the binding's own name.

            The two passes must agree about how many lines they draw, or the columns drift apart:
            each is exactly one line per binding, plus one final line that the Keys side leaves
            blank and the controls side spends on "+" and "default". ]]
            for i, bind in ipairs(action.binds) do
                vc.ImGui_PushID("k" .. i)
                local recording = rec and rec.id == id and rec.index == i
                if recording then
                    vc.ImGui_Text(rec_text())
                elseif kstate.editing == id .. "#" .. i then
                    edit_box_field(kstate)
                else
                    -- The label IS the button: clicking the text starts editing it, which is how
                    -- the typed route is reached.
                    if vc.ImGui_SmallButton(keymap.format(bind) .. "##text") then
                        kstate.editing = id .. "#" .. i
                        kstate.buffer = keymap.format(bind)
                        kstate.error = nil
                        kstate.focus_next = true
                        rec = nil
                    end
                end
                vc.ImGui_PopID()
            end
            if #action.binds == 0 then
                vc.ImGui_Text("(unbound)")
            end
            local new_index = #action.binds + 1
            if kstate.editing == id .. "#" .. new_index then
                vc.ImGui_PushID("knew")
                edit_box_field(kstate)
                vc.ImGui_PopID()
            end

            -- ---- the controls column ------------------------------------------------------
            vc.ImGui_TableNextColumn()
            for i, bind in ipairs(action.binds) do
                vc.ImGui_PushID("c" .. i)
                local recording = rec and rec.id == id and rec.index == i

                --[[ Pressing Rec while this slot is already recording CLEARS the attempt and
                starts over - "you redo the box init" - rather than stopping, which is the only way
                to back out of a mis-press without abandoning the edit entirely. ]]
                local function start_recording()
                    rec = {id = id, index = i}
                    kstate.editing = nil
                    kstate.error = nil
                end

                if recording then
                    if rec_button(true, line_h) then
                        start_recording()
                    end
                    if vc.ImGui_SmallButton("v##ok") then
                        commit(kstate)
                    end
                    vc.ImGui_SameLine(0, 4)
                    if vc.ImGui_SmallButton("x##no") then
                        rec = nil
                    end
                elseif kstate.editing == id .. "#" .. i then
                    edit_box_buttons(kstate, id, i)
                else
                    if rec_button(false, line_h) then
                        start_recording()
                    end
                    if vc.ImGui_SmallButton("-##del") then
                        keymap.remove_bind(id, i)
                    end
                end
                vc.ImGui_PopID()
            end

            --[[ The slot one past the end: this is where "+" points, and it exists only while a
            new binding is being typed. Its own PushID, or it would collide with the last existing
            slot's widgets and the two would fight over the same field. ]]
            local new_index2 = #action.binds + 1
            if kstate.editing == id .. "#" .. new_index2 then
                vc.ImGui_PushID("cnew")
                edit_box_buttons(kstate, id, new_index2)
                vc.ImGui_PopID()
            elseif vc.ImGui_SmallButton("+##add") then
                kstate.editing = id .. "#" .. new_index2
                kstate.buffer = ""
                kstate.focus_next = true
                kstate.error = nil
                rec = nil
            end
            vc.ImGui_SameLine(0, 6)
            if vc.ImGui_SmallButton("default##reset") then
                keymap.reset(id)
                kstate.editing, kstate.error = nil, nil
            end

            vc.ImGui_PopID()
        end)
        end)
        vc.ImGui_EndTable()
        if not rows_ok then
            -- NOT kstate.error: that one is tagged with an action id and shown on that action's
            -- row. A failure of the panel itself belongs to no row - and the rows may not even
            -- have drawn - so it gets the banner above the table instead.
            kstate.panel_error = "panel error: " .. tostring(rows_err)
        end
    end
    -- Always popped, including on the BeginTable-returned-false path above - an unbalanced font
    -- stack corrupts every window drawn after this one, not just this panel.
    vc.ImGui_PopFont()
end

--[[ Escape, offered to the panel BEFORE it is allowed to close the panel.

Returns true when it was used up here. A recording in progress and a half-typed binding are both
things Escape should abandon on their own - closing the whole panel because someone backed out of
one field would lose every other edit they had not committed yet. Only when there is nothing to
back out of does Escape mean "close".

Recording is checked first: it is the more modal of the two, and the recorder can be armed while a
different row still holds a stale edit target.
@date 2026-09-08 08:45 ]]
function panel_keymap.escape(kstate)
    if rec then
        rec = nil
        return true
    end
    if kstate.editing then
        kstate.editing, kstate.error = nil, nil
        return true
    end
    return false
end

-- Called when the panel closes, so an abandoned recording cannot survive into the next opening.
function panel_keymap.closed(kstate)
    rec = nil
    kstate.editing, kstate.error, kstate.panel_error = nil, nil, nil
end

return panel_keymap

--[[
keymap.lua - the one place that decides whether a key press means an ACTION.

Everything that used to ask ImGui directly ("is Ctrl down and was Z just pressed") asks this module
instead ("did edit.undo just fire"), so a binding lives in exactly one place and can be changed at
runtime by the F2 customiser. The editors keep their own dispatch ORDER and their own
return-consumes-the-frame structure untouched - this module replaces the TEST, never the decision
about what happens next.

THE MATCHING RULE, and why it is what it is
-------------------------------------------
A bind is EXACT by default: it names Ctrl/Shift/Alt and fires only when exactly those are down.
The one exception is the "+All" token - "Enter+All" means Enter with ANY combination of modifiers,
including none.

That wildcard exists because the pre-keymap code was loose everywhere by accident. It tested only
the modifiers it happened to name, so Shift+Enter inserted a newline, Ctrl+Alt+letter produced Greek
and Ctrl+Shift+S saved, none of it deliberately - just modifiers nobody checked. Two designs were
tried and dropped before this one: three-state modifiers (required-down / required-up / don't-care),
which hid the looseness in a field nobody reads; and listing every loose case as extra binds
("Enter, Shift+Enter, ..."), which is correct but turns one idea into a list that has to be kept in
sync by hand. "+All" is the user's own answer, 2026-09-07 - a single bind, and the looseness is
TYPED, so it shows up in the customiser's box where it can be read and removed like anything else.

Deliberately NOT applied everywhere it would preserve old behaviour. Backspace and Delete are exact
now, and Alt+letter Greek no longer answers to Ctrl+Alt - both ruled 2026-09-07, both real
behaviour changes, both wanted.

An action holds a LIST of binds and fires if any of them matches. F1's help renders only the first -
a rebind should not reflow a paragraph - and the customiser shows them all.
]]

local vc = require("virt_composer")

local keymap = {}

--[[ ImGuiKey name <-> id, both directions, from the C++ side's own imgui_key_from_str (exposed
2026-09-07 as vc.ImGui_key_names() for exactly this). Reading it from there rather than writing a
second list here is the point: the names are authoritative and cannot drift.

The fallback matters and is not defensive padding. tests/harness/test_harness.cpp registers only
charc and mexpr - imgui_composer is NOT registered under the test harness - so vc.ImGui_key_names
is nil there and every vc.ImGuiKey_* constant is nil too. char.lua:894 already lives with this via
`vc[name] or name`. Under the harness this module therefore resolves ids to the NAME STRING, which
is still a stable, comparable, serialisable key: parsing, formatting, conflict detection and the
whole registry stay testable headlessly. Only the actual ImGui poll needs a real integer, and
nothing polls under the harness. ]]
local name_to_id, id_to_name = {}, {}

do
    local listed = vc.ImGui_key_names and vc.ImGui_key_names() or nil
    if listed then
        for _, pair in ipairs(listed) do
            name_to_id[pair[1]] = pair[2]
            id_to_name[pair[2]] = pair[1]
        end
    end
end

--[[ Resolve a "ImGuiKey_X" name to whatever this build can poll with. Integer where ImGui is
registered, the name string itself where it is not (see the fallback note above). ]]
local function key_id(name)
    return name_to_id[name] or name
end

--[[ Lower-cased index of every real ImGuiKey name, both in full and by its suffix, so the field
accepts "delete", "Delete", "GraveAccent" and "ImGuiKey_Delete" alike. Empty when ImGui is not
registered (the test harness), which is exactly why parse() cannot depend on it alone. ]]
local lower_to_name = {}
for name in pairs(name_to_id) do
    lower_to_name[name:lower()] = name
    lower_to_name[name:gsub("^ImGuiKey_", ""):lower()] = name
end

--[[ What a person types in the customiser's field, mapped to the ImGuiKey name behind it.

Only the ones whose typed form is not simply the suffix. "K" -> ImGuiKey_K and "F1" -> ImGuiKey_F1
need no entry; "Left" -> ImGuiKey_LeftArrow and "/" -> ImGuiKey_Slash do. Written the way a person
would actually type a shortcut, since this table IS the input language of the F2 field. ]]
local ALIASES = {
    ["left"]      = "ImGuiKey_LeftArrow",
    ["right"]     = "ImGuiKey_RightArrow",
    ["up"]        = "ImGuiKey_UpArrow",
    ["down"]      = "ImGuiKey_DownArrow",
    ["esc"]       = "ImGuiKey_Escape",
    ["escape"]    = "ImGuiKey_Escape",
    ["return"]    = "ImGuiKey_Enter",
    ["enter"]     = "ImGuiKey_Enter",
    ["kpenter"]   = "ImGuiKey_KeypadEnter",
    ["delete"]    = "ImGuiKey_Delete",
    ["del"]       = "ImGuiKey_Delete",
    ["insert"]    = "ImGuiKey_Insert",
    ["pageup"]    = "ImGuiKey_PageUp",
    ["pagedown"]  = "ImGuiKey_PageDown",
    ["keypadenter"] = "ImGuiKey_KeypadEnter",
    ["capslock"]  = "ImGuiKey_CapsLock",
    ["menu"]      = "ImGuiKey_Menu",
    ["ins"]       = "ImGuiKey_Insert",
    ["pgup"]      = "ImGuiKey_PageUp",
    ["pgdn"]      = "ImGuiKey_PageDown",
    ["/"]         = "ImGuiKey_Slash",
    ["\\"]        = "ImGuiKey_Backslash",
    ["="]         = "ImGuiKey_Equal",
    ["-"]         = "ImGuiKey_Minus",
    [","]         = "ImGuiKey_Comma",
    ["."]         = "ImGuiKey_Period",
    [";"]         = "ImGuiKey_Semicolon",
    ["'"]         = "ImGuiKey_Apostrophe",
    ["`"]         = "ImGuiKey_GraveAccent",
    ["["]         = "ImGuiKey_LeftBracket",
    ["]"]         = "ImGuiKey_RightBracket",
    ["space"]     = "ImGuiKey_Space",
    ["tab"]       = "ImGuiKey_Tab",
    ["backspace"] = "ImGuiKey_Backspace",
    ["bksp"]      = "ImGuiKey_Backspace",
    ["home"]      = "ImGuiKey_Home",
    ["end"]       = "ImGuiKey_End",
}

-- The reverse, for rendering a bind back into the same language it is typed in. Built from
-- ALIASES so the two can never disagree; first spelling of each key wins, which is why the
-- friendly forms are listed before the abbreviations above.
local PRETTY = {}
for typed, name in pairs(ALIASES) do
    if not PRETTY[name] then
        PRETTY[name] = typed
    end
end
-- ...except these, where the alias table's key is not the nicest label to READ.
PRETTY["ImGuiKey_LeftArrow"]  = "Left"
PRETTY["ImGuiKey_RightArrow"] = "Right"
PRETTY["ImGuiKey_UpArrow"]    = "Up"
PRETTY["ImGuiKey_DownArrow"]  = "Down"
PRETTY["ImGuiKey_Escape"]     = "Escape"
PRETTY["ImGuiKey_Enter"]      = "Enter"
PRETTY["ImGuiKey_KeypadEnter"] = "KpEnter"
PRETTY["ImGuiKey_Delete"]     = "Delete"
PRETTY["ImGuiKey_Backspace"]  = "Backspace"
PRETTY["ImGuiKey_Space"]      = "Space"
-- The rest of the multi-letter names, for the same reason: PRETTY is built from ALIASES, whose
-- keys are lower-cased for lookup, so without an override these render as "home"/"end"/"tab" in
-- the customiser while every neighbouring key is capitalised.
PRETTY["ImGuiKey_Home"]       = "Home"
PRETTY["ImGuiKey_End"]        = "End"
PRETTY["ImGuiKey_Tab"]        = "Tab"
PRETTY["ImGuiKey_Insert"]     = "Insert"
PRETTY["ImGuiKey_PageUp"]     = "PageUp"
PRETTY["ImGuiKey_PageDown"]   = "PageDown"

--[[ "Ctrl+Shift+K" -> {ctrl=true, shift=true, alt=false, key="ImGuiKey_K"}, or nil plus a reason.

Case-insensitive on the modifiers and on named keys; a single printable character keeps its own
case for the alias lookup ("/" and "." are keys, not letters). Returns the REASON on failure
because the customiser shows it in the box rather than just refusing silently - a field that
rejects without saying why is the thing that makes a settings screen infuriating. ]]
function keymap.parse(text)
    if type(text) ~= "string" then
        return nil, "not text"
    end
    local bind = {ctrl = false, shift = false, alt = false, any_mods = false, key = nil}
    local seen_key = nil
    -- Trailing "+" is how a half-typed combo looks ("Ctrl+"), so an empty final token is not an
    -- error, just an unfinished bind - reported as such.
    for token in text:gmatch("[^+]+") do
        token = token:match("^%s*(.-)%s*$")
        if token ~= "" then
            local low = token:lower()
            if low == "ctrl" or low == "control" then
                bind.ctrl = true
            elseif low == "shift" then
                bind.shift = true
            elseif low == "alt" then
                bind.alt = true
            elseif low == "all" or low == "any" then
                -- The wildcard: this bind stops caring about modifiers entirely. See the header.
                -- "any" accepted as a synonym because it is what the behaviour is called in
                -- conversation, and a field that rejects the obvious word is a field that annoys.
                bind.any_mods = true
            else
                if seen_key then
                    -- Deliberately refused rather than "last one wins": ruled 2026-09-07, two
                    -- non-modifier keys in one bind are not allowed. The recorder enforces the
                    -- same rule on its own accumulation.
                    return nil, "two keys: " .. seen_key .. " and " .. token
                end
                --[[ Resolution order, and why it is not just "upper-case it and hope".

                The first version built "ImGuiKey_" .. token:upper() and accepted it whenever ImGui
                was not registered - which is every test run. "Delete" became "ImGuiKey_DELETE",
                which is not a real name (it is ImGuiKey_Delete), and the app refused to start on
                its own DEFAULTS table while every test passed. The blind-accept was the actual
                defect: it made the headless path validate nothing at all.

                So: aliases first, then the real name table when ImGui is there (case-insensitively,
                so "gravaccent" spellings and exact "ImGuiKey_Delete" both work), then a NARROW
                structural rule for the two shapes whose capitalisation is unambiguous - a single
                letter or digit, and a function key. Anything else is unknown, headless or not. ]]
                local name = ALIASES[low] or ALIASES[token]
                if not name then
                    name = lower_to_name[low]
                end
                if not name then
                    -- "k" -> ImGuiKey_K, "7" -> ImGuiKey_7, "f11" -> ImGuiKey_F11. These are the
                    -- only names where upper-casing is guaranteed correct.
                    if #token == 1 and token:match("^[%a%d]$") then
                        name = "ImGuiKey_" .. token:upper()
                    elseif low:match("^f%d+$") then
                        name = "ImGuiKey_F" .. low:sub(2)
                    end
                    -- With ImGui present the guess is CONFIRMED rather than trusted; without it
                    -- the rule above is narrow enough to stand on its own.
                    if name and next(name_to_id) ~= nil and not name_to_id[name] then
                        name = nil
                    end
                end
                if not name then
                    return nil, "unknown key: " .. token
                end
                seen_key = token
                bind.key = name
            end
        end
    end
    if not bind.key then
        return nil, "no key, only modifiers"
    end
    return bind
end

--[[ The inverse. Modifier order is fixed at Ctrl+Shift+Alt regardless of how it was typed, so the
same bind always reads the same way and two spellings of one combo cannot look different in the
customiser. ]]
function keymap.format(bind)
    if not bind or not bind.key then
        return "(unbound)"
    end
    local parts = {}
    if bind.ctrl  then parts[#parts + 1] = "Ctrl"  end
    if bind.shift then parts[#parts + 1] = "Shift" end
    if bind.alt   then parts[#parts + 1] = "Alt"   end
    parts[#parts + 1] = PRETTY[bind.key] or bind.key:gsub("^ImGuiKey_", "")
    -- "+All" trails the key rather than leading like a modifier: it reads as "Enter, with
    -- anything", and it is how the user wrote it. A wildcard bind never carries explicit
    -- modifiers as well - parse() allows the combination, but it would mean nothing.
    if bind.any_mods then parts[#parts + 1] = "All" end
    return table.concat(parts, "+")
end

--[[ Live modifier state, sampled once per frame rather than per binding.

Left and right collapse into one: no binding here has ever distinguished them, and a customiser
that let you bind RightCtrl separately would produce shortcuts that work on one half of the
keyboard. cache_frame keeps a frame's worth of answers, since pressed() is called dozens of times
per frame and each of these is a C++ round trip (char.lua's own greek_key_ids comment measured the
string-form call at 180us against 0.22us for the integer form - the same reason this file resolves
ids once at load). ]]
local mod_state = {ctrl = false, shift = false, alt = false}
local mod_frame = -1

local function refresh_mods(frame)
    if frame == mod_frame then
        return
    end
    mod_frame = frame
    mod_state.ctrl = vc.ImGui_IsKeyDown(key_id("ImGuiKey_LeftCtrl"))
            or vc.ImGui_IsKeyDown(key_id("ImGuiKey_RightCtrl"))
    mod_state.shift = vc.ImGui_IsKeyDown(key_id("ImGuiKey_LeftShift"))
            or vc.ImGui_IsKeyDown(key_id("ImGuiKey_RightShift"))
    mod_state.alt = vc.ImGui_IsKeyDown(key_id("ImGuiKey_LeftAlt"))
            or vc.ImGui_IsKeyDown(key_id("ImGuiKey_RightAlt"))
end

-- Bumped by keymap.begin_frame(); only used to invalidate the modifier cache above.
local frame_counter = 0

function keymap.begin_frame()
    frame_counter = frame_counter + 1
end

--[[ Does this ONE bind match right now. `repeat_` is ImGui's own key-repeat flag, carried per
ACTION rather than per bind - whether a held Backspace should keep deleting is a property of what
the action does, not of which key reaches it. ]]
local function bind_matches(bind, repeat_)
    if not bind or not bind.key then
        return false
    end
    if not bind.any_mods then
        refresh_mods(frame_counter)
        if bind.ctrl ~= mod_state.ctrl or bind.shift ~= mod_state.shift
                or bind.alt ~= mod_state.alt then
            return false
        end
    end
    return vc.ImGui_IsKeyPressed(key_id(bind.key), repeat_ and true or false)
end

-- #############################################################################################
-- The registry
-- #############################################################################################

--[[ Every action, its description (which F1's help renders and F2's table lists) and its default
binds. This table is the FACTORY setting - keymap.reset() and the customiser's per-row default
button both come back to it, so it is never mutated; the live binds live in `actions` below.

Where a default list has more than one entry, the extra ones are not decoration. They are the
pre-keymap behaviour that the exact-matching rule would otherwise have retired silently - see this
file's header. Each is deletable in F2.

`repeat_` is true where holding the key should keep firing (typing, navigation, deletion) and false
where it must fire once per press (anything structural, or a panel toggle). ]]
local DEFAULTS = {
    -- Panels and application ------------------------------------------------------------------
    {id = "app.help",             desc = "Toggle the help panel",                    binds = {"F1"}},
    {id = "app.customiser",       desc = "Toggle the keybind customiser",            binds = {"F2"}},
    --[[ Escape closes whichever panel is open. "+All" like the other leave/cancel gestures, and a
    SEPARATE action from formula.exit even though both are Escape today: they can never both be
    live (content.handle_input returns early while a panel is open), and binding them together
    would mean rebinding one silently rebinds the other. ]]
    {id = "panel.close",          desc = "Close the open panel",                     binds = {"Escape+All"}},
    {id = "app.profiler",         desc = "Toggle the profiler overlay",              binds = {"F3"}},
    {id = "app.profiler_reset",   desc = "Clear the profiler's worst frame",         binds = {"Shift+F3"}},
    {id = "app.profiler_record",  desc = "Record slow frames to perf_spikes.log",    binds = {"Ctrl+F3"}},
    {id = "doc.save",             desc = "Save the document",                        binds = {"Ctrl+S"}},

    --[[ Chapter navigation on the help page. Real actions rather than the panel reading Up/Down
    directly, so they are rebindable like everything else - and separately from nav.up/nav.down,
    which they deliberately do NOT reuse: moving a cursor a line and moving to another chapter are
    different intentions that merely happen to share a key today.

    They DO share it, though, so nav.up and radial.text will list these in their conflict notes.
    That is the honest reading - the keys are the same - and the two can never fire at once, since
    content.handle_input() returns early while a panel is open. ]]
    --[[ Two pairs, because they do different things. Left/Right JUMP to the neighbouring chapter
    outright; Up/Down scroll the page and only turn it once there is nothing left to scroll that
    way. Ruled 2026-09-07: "left/right in f1 jumps in between chapters, not scroll" - a long
    chapter was otherwise only navigable by holding an arrow through all of it. ]]
    {id = "help.prev_chapter",    desc = "Previous help chapter",  repeat_ = true,   binds = {"Left"}},
    {id = "help.next_chapter",    desc = "Next help chapter",      repeat_ = true,   binds = {"Right"}},
    {id = "help.scroll_up",       desc = "Scroll the help page up",   repeat_ = true, binds = {"Up"}},
    {id = "help.scroll_down",     desc = "Scroll the help page down", repeat_ = true, binds = {"Down"}},

    -- Boxes ------------------------------------------------------------------------------------
    -- Ctrl+Up/Down only. Ctrl+SHIFT+Up/Down also switches boxes today - content.lua:826 tests just
    -- Ctrl, so the Shift rides along unnoticed - and it is NOT carried over: ruled 2026-09-07,
    -- "keep only ctrl+up as the default for now". A deliberate behaviour change, and one an alt
    -- bind can restore in the customiser at any time.
    {id = "box.prev",             desc = "Go to the previous box",                   binds = {"Ctrl+Up"}},
    {id = "box.next",             desc = "Go to the next box",                       binds = {"Ctrl+Down"}},
    --[[ Ctrl+Shift+Up/Down MOVES the box rather than the caret. These chords used to switch boxes
    by accident (content.lua tested only Ctrl, so the Shift rode along unnoticed) and were freed
    deliberately on 2026-09-07; this is what they were freed for. ]]
    {id = "box.move_up",          desc = "Move this box up the stack",               binds = {"Ctrl+Shift+Up"}},
    {id = "box.move_down",        desc = "Move this box down the stack",             binds = {"Ctrl+Shift+Down"}},
    {id = "box.new",              desc = "New box after this one",                   binds = {"Ctrl+N"}},
    {id = "box.close",            desc = "Close the current box",                    binds = {"Ctrl+W"}},
    --[[ Ctrl+D: derive a new formula box from this one by the identity - it holds the same thing
    and records where it came from. Ctrl+D is otherwise unused across every binding here. ]]
    {id = "formula.derive",       desc = "Derive a formula box from this one",       binds = {"Ctrl+D"}},

    -- The radial new-box menu ------------------------------------------------------------------
    -- Escape takes "+All" everywhere it means LEAVE or CANCEL. Ruled 2026-09-07 for formula.exit
    -- ("this will be escape+all"); the other two are the same gesture and are loose today for the
    -- same accidental reason, so the wildcard preserves them rather than quietly tightening them.
    {id = "radial.cancel",        desc = "Close the new-box menu",                   binds = {"Escape+All"}},
    {id = "radial.text",          desc = "Pick a text box",                          binds = {"Up"}},
    {id = "radial.formula",       desc = "Pick a formula box",                       binds = {"Left"}},
    {id = "radial.definition",    desc = "Pick a definition box",                    binds = {"Right"}},
    {id = "radial.dismiss",       desc = "Pick the cancel target",                   binds = {"Down"}},
    {id = "radial.commit",        desc = "Create the selected box",                  binds = {"Enter+All", "KpEnter+All", "Space+All"}},

    -- Clipboard and history --------------------------------------------------------------------
    {id = "edit.undo",            desc = "Undo",                                     binds = {"Ctrl+Z"}},
    {id = "edit.redo",            desc = "Redo",                                     binds = {"Ctrl+Shift+Z"}},
    {id = "edit.select_all",      desc = "Select everything in the box",             binds = {"Ctrl+A"}},
    {id = "edit.copy",            desc = "Copy",                                     binds = {"Ctrl+C"}},
    {id = "edit.cut",             desc = "Cut",                                      binds = {"Ctrl+X"}},
    {id = "edit.paste",           desc = "Paste",                                    binds = {"Ctrl+V"}},

    -- Typing -----------------------------------------------------------------------------------
    -- Space and newline take the "+All" wildcard: they answer to any modifier today, nobody asked
    -- for that to stop, and one wildcard bind says so more honestly than three explicit ones.
    -- Backspace and Delete deliberately do NOT - ruled 2026-09-07: "those would be exact, no 'any'
    -- added, I don't like all those modifiers on deletes". That IS an intentional behaviour change,
    -- and the asymmetry between the two pairs is the point, not an oversight.
    {id = "text.space",           desc = "Insert a space",         repeat_ = true,   binds = {"Space+All"}},
    {id = "text.newline",         desc = "New line",               repeat_ = true,   binds = {"Enter+All", "KpEnter+All"}},
    {id = "text.backspace",       desc = "Delete before the cursor", repeat_ = true, binds = {"Backspace"}},
    {id = "text.delete",          desc = "Delete after the cursor",  repeat_ = true, binds = {"Delete"}},

    -- Moving the cursor ------------------------------------------------------------------------
    {id = "nav.left",             desc = "Move left",              repeat_ = true,   binds = {"Left"}},
    {id = "nav.right",            desc = "Move right",             repeat_ = true,   binds = {"Right"}},
    {id = "nav.up",               desc = "Move up a line",         repeat_ = true,   binds = {"Up"}},
    {id = "nav.down",             desc = "Move down a line",       repeat_ = true,   binds = {"Down"}},
    {id = "nav.home",             desc = "Start of the line",      repeat_ = true,   binds = {"Home"}},
    {id = "nav.end",              desc = "End of the line",        repeat_ = true,   binds = {"End"}},
    {id = "nav.select_left",      desc = "Extend selection left",  repeat_ = true,   binds = {"Shift+Left"}},
    {id = "nav.select_right",     desc = "Extend selection right", repeat_ = true,   binds = {"Shift+Right"}},
    {id = "nav.select_up",        desc = "Extend selection up",    repeat_ = true,   binds = {"Shift+Up"}},
    {id = "nav.select_down",      desc = "Extend selection down",  repeat_ = true,   binds = {"Shift+Down"}},
    {id = "nav.select_home",      desc = "Select to line start",   repeat_ = true,   binds = {"Shift+Home"}},
    {id = "nav.select_end",       desc = "Select to line end",     repeat_ = true,   binds = {"Shift+End"}},
    {id = "nav.word_left",        desc = "Skip a word left",       repeat_ = true,   binds = {"Ctrl+Left"}},
    {id = "nav.word_right",       desc = "Skip a word right",      repeat_ = true,   binds = {"Ctrl+Right"}},
    {id = "nav.select_word_left", desc = "Select a word left",     repeat_ = true,   binds = {"Ctrl+Shift+Left"}},
    {id = "nav.select_word_right",desc = "Select a word right",    repeat_ = true,   binds = {"Ctrl+Shift+Right"}},

    -- Formula embeds ---------------------------------------------------------------------------
    {id = "formula.new",          desc = "Insert a formula here",                    binds = {"Ctrl+M"}},
    {id = "formula.new_frac",     desc = "Insert a formula with a fraction",         binds = {"Ctrl+/"}},
    {id = "formula.new_stack",    desc = "Insert a formula with a stack",            binds = {"Ctrl+="}},
    {id = "formula.wrap_sub",     desc = "Subscript the character before",           binds = {"Ctrl+Shift+-"}},
    {id = "formula.wrap_sup",     desc = "Superscript the character before",         binds = {"Ctrl+Shift+="}},
    {id = "formula.exit",         desc = "Leave the formula",                        binds = {"Escape+All"}},
    {id = "definition.exit_slot", desc = "Leave a definition's shorthand",            binds = {"Escape+All"}},
    {id = "formula.exit_left",    desc = "Leave the formula to the left",            binds = {"Ctrl+Left"}},
    {id = "formula.exit_right",   desc = "Leave the formula to the right",           binds = {"Ctrl+Right"}},

    -- Inside a formula -------------------------------------------------------------------------
    {id = "math.sup",             desc = "Superscript",                              binds = {"Ctrl+Shift+="}},
    {id = "math.sub",            desc = "Subscript",                                 binds = {"Ctrl+Shift+-"}},
    {id = "math.frac",           desc = "Insert a fraction",                         binds = {"Ctrl+/"}},
    {id = "math.stack_grow",     desc = "Start a stack, or add a cell",              binds = {"Ctrl+="}},
    {id = "math.stack_shrink",   desc = "Drop a cell from the stack",                binds = {"Ctrl+-"}},
    {id = "math.limit_above",    desc = "Limit above (makes a big operator)",        binds = {"Ctrl+Shift+["}},
    {id = "math.limit_below",    desc = "Limit below (makes a big operator)",        binds = {"Ctrl+Shift+]"}},
    {id = "math.bar_bracket",    desc = "Open or close a | delimiter",               binds = {"Ctrl+Shift+\\"}},
    {id = "math.accent_bar",     desc = "Bar above (press again to remove)",         binds = {"Ctrl+G"}},
    {id = "math.accent_hat",     desc = "Hat above",                                 binds = {"Ctrl+6"}},
    {id = "math.accent_tilde",   desc = "Tilde above",                               binds = {"Ctrl+`"}},
    {id = "math.accent_bar_below",   desc = "Bar below",                             binds = {"Ctrl+Shift+G"}},
    {id = "math.accent_hat_below",   desc = "Hat below",                             binds = {"Ctrl+Shift+6"}},
    {id = "math.accent_tilde_below", desc = "Tilde below",                           binds = {"Ctrl+Shift+`"}},
    {id = "math.dot_add",        desc = "Add a dot above (up to three)",             binds = {"Ctrl+."}},
    {id = "math.dot_remove",     desc = "Remove a dot",                              binds = {"Ctrl+,"}},
    {id = "math.vec",            desc = "Vector arrow, pointing right",              binds = {"Ctrl+Shift+."}},
    {id = "math.vec_left",       desc = "Vector arrow, pointing left",               binds = {"Ctrl+Shift+,"}},
    {id = "math.sprint_left",    desc = "Sprint to the previous landmark", repeat_ = true, binds = {"Shift+Left"}},
    {id = "math.sprint_right",   desc = "Sprint to the next landmark",     repeat_ = true, binds = {"Shift+Right"}},
    {id = "math.select_left",    desc = "Select within the row, left",     repeat_ = true, binds = {"Ctrl+Shift+Left"}},
    {id = "math.select_right",   desc = "Select within the row, right",    repeat_ = true, binds = {"Ctrl+Shift+Right"}},
    {id = "math.back_up",        desc = "Go back up the way you came",     repeat_ = true, binds = {"Alt+Up"}},
    {id = "math.back_down",      desc = "Go back down the way you came",   repeat_ = true, binds = {"Alt+Down"}},
}

--[[ The LIVE table: id -> {desc=, repeat_=, binds={parsed, ...}}. Separate from DEFAULTS so the
factory setting survives every edit and "back to default" is a copy rather than a reload. ]]
local actions = {}

--[[ Set by every edit, cleared by whoever writes the file. The customiser saves on CLOSE rather
than on each keystroke (ruled 2026-09-07: "on any change the settings should be saved when the f2
pannel closes") - which is why this is a flag rather than a save-callback: a half-typed rebind, or
one abandoned with the x, must never reach disk, and a flag lets the writer decide when "settled"
is. install_defaults() deliberately does NOT set it: loading is not an edit. ]]
local dirty = false

function keymap.dirty()
    return dirty
end

function keymap.clear_dirty()
    dirty = false
end

local function install_defaults()
    actions = {}
    for _, entry in ipairs(DEFAULTS) do
        local parsed = {}
        for _, text in ipairs(entry.binds) do
            local bind, why = keymap.parse(text)
            if not bind then
                -- A broken DEFAULTS entry is a programming error, not user input, and it must not
                -- fail quietly into "this shortcut simply never fires" - the exact class of
                -- invisible breakage test_no_use_before_define.lua exists to catch.
                error("keymap: bad default bind '" .. tostring(text) .. "' for "
                        .. entry.id .. ": " .. tostring(why))
            end
            parsed[#parsed + 1] = bind
        end
        actions[entry.id] = {desc = entry.desc, repeat_ = entry.repeat_, binds = parsed}
    end
end

install_defaults()

-- #############################################################################################
-- The API the editors use
-- #############################################################################################

--[[ THE call. True when any of this action's binds matches this frame.

An unknown id is an error rather than a silent false: a typo'd id would otherwise mean "this
shortcut quietly never works again", which is invisible in a way a missing key press is not. ]]
function keymap.pressed(id)
    local action = actions[id]
    if not action then
        error("keymap: no such action '" .. tostring(id) .. "'")
    end
    for _, bind in ipairs(action.binds) do
        if bind_matches(bind, action.repeat_) then
            return true
        end
    end
    return false
end

-- The live modifier state, for the few places that genuinely need to ask (the Alt+letter Greek
-- loop, which is a whole family of keys rather than one action).
function keymap.mods()
    refresh_mods(frame_counter)
    return mod_state.ctrl, mod_state.shift, mod_state.alt
end

--[[ What F1 substitutes into its prose. The FIRST bind only - a rebind should never reflow a
paragraph - and "(unbound)" rather than blank when the list has been emptied, so the sentence
around it still reads. ]]
function keymap.label(id)
    local action = actions[id]
    if not action or not action.binds[1] then
        return "(unbound)"
    end
    return keymap.format(action.binds[1])
end

--[[ Integer ImGuiKey id -> its name, for the F2 recorder: vc.ImGui_keys_pressed() hands back ids
and the recorder needs names to build a binding out of them. Nil for an id this build does not know,
which the caller must handle - it is the only sane answer, and silently inventing a name would put
an unresolvable key into somebody's saved keymap. ]]
function keymap.key_name(id)
    return id_to_name[id]
end

--[[ The reverse, and the label a person reads for a key. Both are needed by the glyph customiser,
which is keyed by physical key rather than by letter: it has to poll the key (id) and show which
key a row is (label). PRETTY is the same spelling the binding fields accept, so a key reads the
same everywhere in the customiser. ]]
function keymap.key_of(name)
    return key_id(name)
end

function keymap.key_label(name)
    return PRETTY[name] or (name and name:gsub("^ImGuiKey_", "")) or "?"
end

function keymap.describe(id)
    local action = actions[id]
    return action and action.desc or id
end

-- Every action, in DEFAULTS order rather than a random hash walk, so the customiser's table and
-- the help are stable between runs.
function keymap.each(fn)
    for _, entry in ipairs(DEFAULTS) do
        fn(entry.id, actions[entry.id])
    end
end

function keymap.binds_of(id)
    local action = actions[id]
    return action and action.binds or {}
end

-- #############################################################################################
-- Editing, which is what the F2 customiser drives
-- #############################################################################################

--[[ Accept a typed bind into slot `index` of `id` (index beyond the end appends). Returns
true, or false plus the reason - the customiser puts that reason in the box.

Conflicts do NOT refuse. Two actions may hold the same bind, and the customiser marks both:
refusing would make swapping two shortcuts impossible without clearing one first, and the dispatch
order in the editors already decides which of a colliding pair wins. ]]
function keymap.set_bind(id, index, text)
    local action = actions[id]
    if not action then
        return false, "no such action"
    end
    local bind, why = keymap.parse(text)
    if not bind then
        return false, why
    end
    action.binds[math.min(index, #action.binds + 1)] = bind
    dirty = true
    return true
end

function keymap.remove_bind(id, index)
    local action = actions[id]
    if action and action.binds[index] then
        table.remove(action.binds, index)
        dirty = true
        return true
    end
    return false
end

--[[ Every action currently holding this exact bind, so the customiser can mark a collision. Order
follows DEFAULTS, same as each(). ]]
function keymap.conflicts(bind, except_id)
    local hits = {}
    for _, entry in ipairs(DEFAULTS) do
        if entry.id ~= except_id then
            for _, other in ipairs(actions[entry.id].binds) do
                if other.key == bind.key and other.any_mods == bind.any_mods
                        and (other.any_mods or (other.ctrl == bind.ctrl
                            and other.shift == bind.shift and other.alt == bind.alt)) then
                    hits[#hits + 1] = entry.id
                    break
                end
            end
        end
    end
    return hits
end

-- Back to factory, for one action or (with no id) all of them.
function keymap.reset(id)
    if not id then
        install_defaults()
        dirty = true
        return true
    end
    for _, entry in ipairs(DEFAULTS) do
        if entry.id == id then
            local parsed = {}
            for _, text in ipairs(entry.binds) do
                parsed[#parsed + 1] = keymap.parse(text)
            end
            actions[id].binds = parsed
            dirty = true
            return true
        end
    end
    return false
end

-- #############################################################################################
-- Persistence
-- #############################################################################################

--[[ One line per action, "id<TAB>bind, bind, ...", and ONLY for actions that differ from the
factory setting. That last part is the whole design: a file listing every action would freeze
today's defaults forever, so a default improved later would never reach anyone who had opened the
customiser once. What is written is the user's DIVERGENCE, and everything else follows the code. ]]
function keymap.serialize()
    local lines = {}
    for _, entry in ipairs(DEFAULTS) do
        local live = actions[entry.id]
        local current = {}
        for _, bind in ipairs(live.binds) do
            current[#current + 1] = keymap.format(bind)
        end
        local factory = table.concat(entry.binds, ", ")
        local now = table.concat(current, ", ")
        -- Compared as FORMATTED text, not as the raw default strings: format() normalises modifier
        -- order, so "Shift+Ctrl+Z" typed back in equals "Ctrl+Shift+Z" and does not write a line
        -- claiming a divergence that is only a spelling.
        local factory_norm = {}
        for _, text in ipairs(entry.binds) do
            local b = keymap.parse(text)
            factory_norm[#factory_norm + 1] = b and keymap.format(b) or text
        end
        if now ~= table.concat(factory_norm, ", ") then
            lines[#lines + 1] = entry.id .. "\t" .. (now ~= "" and now or "(unbound)")
        end
    end
    return table.concat(lines, "\n")
end

--[[ Read one back. Starts from a clean set of defaults, so a file that no longer mentions an
action leaves that action at factory rather than at whatever the previous load left behind.

An id the code no longer has is SKIPPED, not an error: an old file must not stop the app from
starting, and the line is reported so it is not silently lost. Same for a bind that no longer
parses. ]]
function keymap.deserialize(text, warn)
    install_defaults()
    if type(text) ~= "string" then
        return
    end
    for line in text:gmatch("[^\n]+") do
        local id, rest = line:match("^([^\t]+)\t(.*)$")
        if id then
            if not actions[id] then
                if warn then warn("keymap: unknown action in saved keymap: " .. id) end
            else
                local parsed = {}
                if rest ~= "(unbound)" then
                    for chunk in rest:gmatch("[^,]+") do
                        local bind, why = keymap.parse(chunk)
                        if bind then
                            parsed[#parsed + 1] = bind
                        elseif warn then
                            warn("keymap: dropping unreadable bind for " .. id .. ": "
                                    .. chunk .. " (" .. tostring(why) .. ")")
                        end
                    end
                end
                actions[id].binds = parsed
            end
        end
    end
end

return keymap

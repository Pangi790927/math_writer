--[[
A flat text/glyph-stream editor - a Lua port of old/comments.h's comment_box_t, adapted to the
current char.lua glyph catalog and rendered directly through fontset:char_draw (now that
fontset:char_get_sz gives real glyph metrics, there's no need to route through the mexpr_*
composer just to get working layout).

Model: state.chars is a flat array of items, each either {code=<ncod>} (a glyph) or
{newline=true} (a hard line break). state.cursor_pos is an index 0..#state.chars: cursor_pos == N
means the cursor sits immediately before chars[N+1] (or at the very end, if N == #chars).

state.selection_anchor, when set, is a second such index - the selection covers chars[lo+1..hi]
where lo/hi are min/max(selection_anchor, cursor_pos). selection_anchor == cursor_pos (or nil)
means no selection.

A chars item can also be {formula=<mformula state>} - an embedded structured expression (see
mformula.lua), inline in the flow like one wide glyph. Ctrl+M inserts one at the cursor and enters
it. Clicking one enters it (state.active_formula); while a formula is active, ALL input goes to it
exclusively (Escape, or clicking outside it, leaves) - this is what keeps arrow keys unambiguous:
outside a formula they still mean what they meant before (Up/Down = switch line), inside one
they're reinterpreted by mformula.lua (Up/Down = enter superscript/subscript).
]]

local vc = require("virt_composer")
local char = require("char")
local mformula = require("mformula")

local editor = {}

-- #################################################################################################
-- Model
-- #################################################################################################

function editor.new()
    return {
        chars = {},
        cursor_pos = 0,
        selection_anchor = nil,
        mouse_selecting = false, -- true while a click+drag selection is in progress
        mouse_click_origin = nil, -- position of the click that started the current drag, if any
        last_positions = nil,   -- filled in by draw(), read by handle_input() next frame
        last_line_height = nil,
        last_cursor_y = nil,    -- filled in by draw(): absolute screen y of the caret right now
        last_cursor_h = nil,    -- (plain text or an active formula's own - see draw()'s comment),
                                 -- read by content.lua to keep it scrolled into view
        last_formula_boxes = nil, -- filled in by draw(): {x,y,w,h,formula=<mformula state>}[]
        active_formula = nil,   -- the mformula state currently owning input, if any
        frame = 0,              -- os.clock() isn't available (virt_composer sandboxes os/io by
                                 -- default), so the caret blinks on a frame count instead of wall time
        undo_stack = {},        -- {chars=, cursor_pos=, selection_anchor=}[], oldest first - see
                                 -- push_undo()/commit_undo()
        redo_stack = {},
        undo_coalesce_key = nil, -- lets consecutive same-kind edits merge into one undo step
                                  -- instead of one per keystroke - see push_undo()'s comment
    }
end

local function is_newline(item)
    return item ~= nil and item.newline == true
end

local function is_whitespace(item)
    if item == nil or is_newline(item) then
        return false
    end
    local entry = char.find_by_ncod(item.code)
    return entry ~= nil and entry.acod ~= '\0' and entry.acod:match("%s") ~= nil
end

local function is_alnum(item)
    if item == nil or is_newline(item) then
        return false
    end
    local entry = char.find_by_ncod(item.code)
    return entry ~= nil and entry.acod ~= '\0' and entry.acod:match("%w") ~= nil
end

-- #################################################################################################
-- Selection
-- #################################################################################################

--[[ Returns lo, hi (0-indexed cursor positions, lo < hi) covering the selected chars, or nil if
there is no active (non-empty) selection. ]]
local function selection_range(state)
    local a = state.selection_anchor
    if not a or a == state.cursor_pos then
        return nil, nil
    end
    if a < state.cursor_pos then
        return a, state.cursor_pos
    end
    return state.cursor_pos, a
end

--[[ Deletes the active selection (if any), moves the cursor to its start, and clears it.
@return true if there was a selection to delete. ]]
local function delete_selection(state)
    local lo, hi = selection_range(state)
    if not lo then
        return false
    end
    for i = hi, lo + 1, -1 do
        table.remove(state.chars, i)
    end
    state.cursor_pos = lo
    state.selection_anchor = nil
    return true
end

--[[ Called at the start of every cursor-moving key handler: with `extend` (Shift held), starts a
selection at the current cursor if one isn't already active; otherwise drops any selection. ]]
local function update_selection_for_move(state, extend)
    if extend then
        if not state.selection_anchor then
            state.selection_anchor = state.cursor_pos
        end
    else
        state.selection_anchor = nil
    end
end

--[[ Plain-text rendering of chars[lo+1..hi], for the clipboard. Glyphs with no ascii form (e.g.
greek) fall back to their LaTeX-ish desc (e.g. "\alpha "); a formula embed becomes a LaTeX $$...$$
span (mformula.to_latex() - see its own comment for exactly what it covers). A literal "$" or "\"
typed as plain text is backslash-escaped so insert_text() can always tell it apart from a $$ span
or one of ITS escapes on the way back in. ]]
local function selection_to_text(state, lo, hi)
    local parts = {}
    for i = lo + 1, hi do
        local item = state.chars[i]
        if item.newline then
            parts[#parts+1] = "\n"
        elseif item.formula then
            parts[#parts+1] = "$$" .. mformula.to_latex(item.formula) .. "$$"
        else
            local entry = char.find_by_ncod(item.code)
            if entry and entry.acod ~= '\0' then
                if entry.acod == "$" or entry.acod == "\\" then
                    parts[#parts+1] = "\\" .. entry.acod
                else
                    parts[#parts+1] = entry.acod
                end
            elseif entry then
                parts[#parts+1] = entry.desc .. " "
            end
        end
    end
    return table.concat(parts)
end

--[[ Inserts text (e.g. from the clipboard) at the cursor - selection_to_text()'s own inverse. A
"$$...$$" span is parsed as a formula embed (mformula.from_latex()); everywhere else, "\name" (e.g.
"\alpha") is looked up the same way a formula's own macros are (selection_to_text()'s plain-text
greek/symbol fallback, undone), "\$"/"\\" unescape back to a literal "$"/"\", and anything else
unmapped - an unrecognized macro included - is skipped, the same leniency plain paste always had. ]]
local function insert_text(state, text)
    local i = 1
    while i <= #text do
        local c = text:sub(i, i)
        if text:sub(i, i + 1) == "$$" then
            -- plain=true: "$$" would otherwise be read as a Lua pattern (end-of-string anchors),
            -- not a literal substring.
            local close = text:find("$$", i + 2, true)
            local inner = text:sub(i + 2, close and (close - 1) or #text)
            local formula = mformula.from_latex(inner)
            table.insert(state.chars, state.cursor_pos + 1, {formula = formula})
            state.cursor_pos = state.cursor_pos + 1
            i = close and (close + 2) or (#text + 1)
        elseif c == '\n' then
            table.insert(state.chars, state.cursor_pos + 1, {newline=true})
            state.cursor_pos = state.cursor_pos + 1
            i = i + 1
        elseif c == '\r' then
            i = i + 1
        elseif c == '\\' then
            local nc = text:sub(i + 1, i + 1)
            if nc:match("%a") then
                local start = i + 1
                local j = start
                while text:sub(j, j):match("%a") do
                    j = j + 1
                end
                local entry = char.find_by_desc("\\" .. text:sub(start, j - 1))
                if entry then
                    table.insert(state.chars, state.cursor_pos + 1,
                            {code=entry.ncod, size_off=char.size_delta_by_desc[entry.desc]})
                    state.cursor_pos = state.cursor_pos + 1
                end
                -- selection_to_text() always emits one trailing space after a macro name -
                -- consume it so round-tripping our own output doesn't leave a stray space behind.
                i = (text:sub(j, j) == " ") and (j + 1) or j
            elseif nc == '$' or nc == '\\' then
                local entry = char.find_by_ascii(nc)
                if entry then
                    table.insert(state.chars, state.cursor_pos + 1, {code=entry.ncod})
                    state.cursor_pos = state.cursor_pos + 1
                end
                i = i + 2
            else
                i = i + 1
            end
        else
            local entry = char.find_by_ascii(c)
            if entry then
                table.insert(state.chars, state.cursor_pos + 1, {code=entry.ncod})
                state.cursor_pos = state.cursor_pos + 1
            end
            i = i + 1
        end
    end
end

--[[ The whole buffer as text (selection_to_text() over every char) - content.lua's own save
format is exactly this, one per box, so a save is indistinguishable from "select all, copy" and a
load from "select all, delete, paste" (undo history included, since it goes through the same
push_undo() call sites paste already does). ]]
function editor.to_text(state)
    return selection_to_text(state, 0, #state.chars)
end

--[[ Replaces the ENTIRE buffer with `text` (insert_text()'s own $$.../escape handling included) -
content.lua's own load, and this file's own undo/redo's restore path (see undo_or_redo()) both
go through wholesale state.chars replacement already; this is that same operation exposed for a
fresh (or about to be cleared) editor.new() instead of a snapshot table. Does NOT go through
push_undo() itself - loading a save file replaces the state a box STARTS with, there's nothing
before it to undo back to. ]]
function editor.from_text(state, text)
    state.chars = {}
    state.cursor_pos = 0
    state.selection_anchor = nil
    insert_text(state, text)
end

--[[ Nearest recorded glyph-gap position (index into state.chars) to a screen point, using the
positions the previous frame's draw() recorded. Used by both click-to-place and drag-to-select. ]]
local function nearest_position(state, mpos)
    if not state.last_positions then
        return nil
    end
    local line_height = state.last_line_height or 20
    local best_i, best_dist = nil, math.huge
    for _, p in ipairs(state.last_positions) do
        local dy = math.abs(p.y - mpos.y)
        local same_line_penalty = (dy > line_height) and 1e6 or 0
        local dist = same_line_penalty + math.abs(p.x - mpos.x) + dy
        if dist < best_dist then
            best_dist = dist
            best_i = p.i
        end
    end
    return best_i
end

-- #################################################################################################
-- Undo / redo
-- #################################################################################################

-- Bounded so a very long session doesn't grow this without limit - generous enough that normal
-- use never gets anywhere near it (typing coalesces into one step per run; only backspace/delete
-- runs, paste, formula creation, and each individual keystroke INSIDE a formula count separately -
-- see push_undo()'s comment). Only ever trims from the OLDEST end, one entry at a time, so nothing
-- recent is ever at risk of being dropped.
local UNDO_STACK_LIMIT = 500

--[[ Recursive copy that's safe on this model's cyclic structure (row.parent_row points back up
the tree, forming real cycles with base/sup/sub pointing back down) - `seen` maps an original table
to its copy, registered BEFORE recursing into it, so a cycle resolves to the same in-progress copy
instead of looping forever or duplicating a shared node.

Keys starting with "_" are skipped - this codebase's own convention for a derived/cache field
(mformula's _layout_cache/_graph_cache), which would otherwise drag a real mexpr_p/vc object into
the snapshot for nothing: cheap to drop, and everything that reads a cache already handles it being
absent by rebuilding from scratch. ]]
local function deep_copy(t, seen)
    if type(t) ~= "table" then
        return t
    end
    seen = seen or {}
    if seen[t] then
        return seen[t]
    end
    local copy = {}
    seen[t] = copy
    for k, v in pairs(t) do
        if type(k) ~= "string" or k:sub(1, 1) ~= "_" then
            copy[k] = deep_copy(v, seen)
        end
    end
    return copy
end

local function snapshot(state)
    return {
        chars = deep_copy(state.chars),
        cursor_pos = state.cursor_pos,
        selection_anchor = state.selection_anchor,
    }
end

--[[ Records `snap` (already captured BEFORE the edit it's about to record - see call sites in
handle_input) as a new undo step, unless `coalesce_key` is non-nil and matches the key the last
recorded step used - then this edit just extends that same step instead of starting a new one
(e.g. every character in one typing run shares "type", so one Ctrl+Z undoes the whole run, not one
letter at a time; a formula-internal edit always passes nil, so - per this session's own request -
every keystroke inside a formula is its own step). Any real edit clears the redo stack - it's only
valid for redoing exactly what was just undone, not a copy of the past made stale by a genuinely
new edit branching off from it. ]]
local function commit_undo(state, snap, coalesce_key)
    if coalesce_key and coalesce_key == state.undo_coalesce_key then
        return
    end
    table.insert(state.undo_stack, snap)
    if #state.undo_stack > UNDO_STACK_LIMIT then
        table.remove(state.undo_stack, 1)
    end
    state.redo_stack = {}
    state.undo_coalesce_key = coalesce_key
end

--[[ Convenience for the common case: snapshot state right now, then commit it. The one call site
that needs to know whether an edit actually happened BEFORE deciding to commit (the active-formula
case in handle_input, keyed off mformula's own state.version) builds the snapshot up front instead
and calls commit_undo() directly. ]]
local function push_undo(state, coalesce_key)
    commit_undo(state, snapshot(state), coalesce_key)
end

--[[ Ctrl+Z / Ctrl+Shift+Z. Always exits any active formula on restore - the restored chars are a
fresh copy with all-new row/formula tables, so there's no single "same" formula left to stay
inside even if one was active before; the user can click or arrow back into whichever one they
want. A no-op (not even clearing undo_coalesce_key) when the relevant stack is empty. ]]
local function undo_or_redo(state, is_redo)
    local from_stack = is_redo and state.redo_stack or state.undo_stack
    local to_stack = is_redo and state.undo_stack or state.redo_stack
    local snap = table.remove(from_stack)
    if not snap then
        return
    end
    table.insert(to_stack, snapshot(state))
    state.chars = snap.chars
    state.cursor_pos = snap.cursor_pos
    state.selection_anchor = snap.selection_anchor
    state.active_formula = nil
    state.undo_coalesce_key = nil
end

-- #################################################################################################
-- Input handling
-- #################################################################################################

--[[ `fontset`/`sz` are only needed for the one thing keyboard-only input handling never needed
before: hit-testing a click against an active formula's own drawn geometry (mformula.hit_test()
has to rebuild/measure rows to know where they land on screen, same as draw() does). ]]
function editor.handle_input(state, fontset, sz)
    -- Ctrl+Z/Ctrl+Shift+Z: checked first, ahead of even the active-formula dispatch below, so
    -- undo/redo works the same way regardless of whether a formula currently owns input - see
    -- undo_or_redo()'s own comment on why it always exits back to plain editing on restore.
    if (vc.ImGui_IsKeyDown("ImGuiKey_LeftCtrl") or vc.ImGui_IsKeyDown("ImGuiKey_RightCtrl"))
            and vc.ImGui_IsKeyPressed("ImGuiKey_Z", false) then
        undo_or_redo(state, vc.ImGui_IsKeyDown("ImGuiKey_LeftShift") or vc.ImGui_IsKeyDown("ImGuiKey_RightShift"))
        return
    end

    -- A formula embed being edited captures ALL input exclusively - see the model comment at the
    -- top of this file for why. Escape, or a click outside it, leaves it - and a click is left
    -- unconsumed when it's the one doing the leaving, so it falls through to the normal handling
    -- below and places the outer cursor right there in the same action (or enters a different
    -- formula, if that's what was clicked), rather than needing a second click to start writing
    -- normally again. A click INSIDE it, instead, hit-tests into the formula's own geometry and
    -- moves ITS cursor there - see mformula.hit_test()'s comment for how "which glyph" is
    -- decided. -----------------------------------------------------------------------
    if state.active_formula then
        local ctrl_down = vc.ImGui_IsKeyDown("ImGuiKey_LeftCtrl") or vc.ImGui_IsKeyDown("ImGuiKey_RightCtrl")
        local escaped = vc.ImGui_IsKeyPressed("ImGuiKey_Escape", false)
        -- Ctrl+Left/Right always leave the formula, regardless of where the cursor is inside it -
        -- plain Left/Right staying parked at the formula's own start/end (mformula.lua's move_left/
        -- move_right do nothing further once there) is intentional, not something arrow keys
        -- should escape on their own.
        local ctrl_left = ctrl_down and vc.ImGui_IsKeyPressed("ImGuiKey_LeftArrow", false)
        local ctrl_right = ctrl_down and vc.ImGui_IsKeyPressed("ImGuiKey_RightArrow", false)
        local ctrl_arrow_exit = ctrl_left or ctrl_right
        local clicked_outside, clicked_inside_fb = false, nil
        if vc.ImGui_IsMouseClicked("ImGuiMouseButton_Left", false) then
            local mpos = vc.ImGui_GetMousePos()
            for _, fb in ipairs(state.last_formula_boxes or {}) do
                if fb.formula == state.active_formula
                        and mpos.x >= fb.x and mpos.x <= fb.x + fb.w
                        and mpos.y >= fb.y and mpos.y <= fb.y + fb.h then
                    clicked_inside_fb = fb
                    break
                end
            end
            clicked_outside = not clicked_inside_fb
        end
        if escaped or ctrl_arrow_exit or clicked_outside then
            -- The outer cursor_pos is never touched while a formula owns input (see the model
            -- comment at the top of this file), so without this it just sits wherever it was
            -- when the formula was entered, no matter which direction you exit with - meaning
            -- only the SAME direction you entered from reads as having moved anywhere; the other
            -- key leaves you stranded at that same spot. Ctrl+Left/Right on exit should always
            -- continue moving in the pressed direction, same as they would outside a formula.
            if ctrl_left or ctrl_right then
                for i, it in ipairs(state.chars) do
                    if it.formula == state.active_formula then
                        state.cursor_pos = ctrl_left and (i - 1) or i
                        break
                    end
                end
            end
            state.active_formula = nil
            -- Must return here: without it, this same Ctrl+Left/Right keypress falls through to
            -- the plain arrow-key handling below and gets processed a SECOND time in this same
            -- call (IsKeyPressed isn't "consumed" by reading it once) - it would word-skip an
            -- extra step past where the cursor was just placed above.
            if ctrl_left or ctrl_right then
                return
            end
        else
            if clicked_inside_fb then
                local mpos = vc.ImGui_GetMousePos()
                local local_click = {x = mpos.x - clicked_inside_fb.draw_x, y = mpos.y - clicked_inside_fb.draw_y}
                state.active_formula.cursor = mformula.hit_test(state.active_formula, fontset, sz, local_click)
            end
            -- One undo step per keystroke INSIDE a formula (not coalesced, unlike plain typing
            -- outside one) - but only when this keystroke actually changed the tree, not for pure
            -- cursor movement (Left/Right/Up/Down, or the click above) - mformula's own
            -- state.version (bumped by every real tree edit) is exactly that signal, so there's
            -- no need to re-derive "was this an edit" by hand here.
            local formula = state.active_formula
            local pre_version = formula.version
            local pre_snapshot = snapshot(state)
            mformula.handle_input(formula)
            if formula.version ~= pre_version then
                commit_undo(state, pre_snapshot, nil)
            end
            return
        end
    end

    -- size_off (size-table steps, negative = bigger - see char.size_delta_by_desc's comment) is
    -- only ever non-nil for the handful of glyphs (currently just "\\int") that need to render
    -- bigger than the text around them; omitted from the item table entirely otherwise, so a
    -- normal glyph is just {code=}.
    local function insert_ncod(ncod, size_off)
        table.insert(state.chars, state.cursor_pos + 1, {code=ncod, size_off=size_off})
        state.cursor_pos = state.cursor_pos + 1
    end

    local is_ctrl = vc.ImGui_IsKeyDown("ImGuiKey_LeftCtrl") or vc.ImGui_IsKeyDown("ImGuiKey_RightCtrl")
    local is_alt = vc.ImGui_IsKeyDown("ImGuiKey_LeftAlt") or vc.ImGui_IsKeyDown("ImGuiKey_RightAlt")
    local is_shift = vc.ImGui_IsKeyDown("ImGuiKey_LeftShift") or vc.ImGui_IsKeyDown("ImGuiKey_RightShift")

    -- Ctrl+M: insert a new formula embed at the cursor and enter it straight away. -------------
    if is_ctrl and vc.ImGui_IsKeyPressed("ImGuiKey_M", false) then
        push_undo(state, nil)
        local formula = mformula.new()
        table.insert(state.chars, state.cursor_pos + 1, {formula = formula})
        state.cursor_pos = state.cursor_pos + 1
        state.active_formula = formula
        return
    end

    -- Ctrl+/: insert a new formula embed here, already containing an empty fraction, and enter
    -- it - mirrors Ctrl+M above, just starting with a frac instead of a blank formula (see
    -- mformula.new_with_frac()'s own comment for why it doesn't wrap anything). -------------
    if is_ctrl and not is_shift and vc.ImGui_IsKeyPressed("ImGuiKey_Slash", false) then
        push_undo(state, nil)
        local formula = mformula.new_with_frac()
        table.insert(state.chars, state.cursor_pos + 1, {formula = formula})
        state.cursor_pos = state.cursor_pos + 1
        state.active_formula = formula
        return
    end

    -- Ctrl+Shift+'_'/'+': turn the character the cursor is sitting right after (the one "with
    -- the blinker on it") directly into a subscript/superscript base, in one step - no need to
    -- Ctrl+M first. That character is pulled out of the plain text and becomes the new formula's
    -- base, so what you see reads as a continuation of what you were already writing (same size,
    -- same baseline) with just a margin box around the new formula. No preceding character (start
    -- of text, or it's a newline/another formula) still works - the base is just left empty. -----
    if is_ctrl and is_shift then
        local slot = nil
        if vc.ImGui_IsKeyPressed("ImGuiKey_Minus", false) then
            slot = "sub"
        elseif vc.ImGui_IsKeyPressed("ImGuiKey_Equal", false) then
            slot = "sup"
        end
        if slot then
            push_undo(state, nil)
            state.selection_anchor = nil
            local base_item = nil
            local prev = state.cursor_pos > 0 and state.chars[state.cursor_pos]
            if prev and not prev.newline and not prev.formula then
                base_item = prev
                table.remove(state.chars, state.cursor_pos)
                state.cursor_pos = state.cursor_pos - 1
            end
            local formula = mformula.new_from_base(base_item, slot)
            table.insert(state.chars, state.cursor_pos + 1, {formula = formula})
            state.cursor_pos = state.cursor_pos + 1
            state.active_formula = formula
            return
        end
    end

    -- Ctrl+A/C/X/V: select all, copy, cut, paste -----------------------------------------------
    if is_ctrl then
        if vc.ImGui_IsKeyPressed("ImGuiKey_A", false) then
            state.selection_anchor = 0
            state.cursor_pos = #state.chars
        end
        local copy = vc.ImGui_IsKeyPressed("ImGuiKey_C", false)
        local cut = vc.ImGui_IsKeyPressed("ImGuiKey_X", false)
        if copy or cut then
            local lo, hi = selection_range(state)
            if lo then
                vc.ImGui_SetClipboardText(selection_to_text(state, lo, hi))
                if cut then
                    push_undo(state, nil)
                    delete_selection(state)
                end
            end
        end
        if vc.ImGui_IsKeyPressed("ImGuiKey_V", false) then
            local text = vc.ImGui_GetClipboardText()
            if selection_range(state) or (text and #text > 0) then
                push_undo(state, nil)
            end
            delete_selection(state)
            if text then
                insert_text(state, text)
            end
        end
    end

    -- Space, handled explicitly rather than trusting it to show up via
    -- vc.ImGui_input_queue_chars() below (it doesn't always). ------------------------------------
    if not is_ctrl and vc.ImGui_IsKeyPressed("ImGuiKey_Space", true) then
        push_undo(state, "type")
        delete_selection(state)
        insert_ncod(char.find_by_ascii(" ").ncod)
    end

    -- Typing -------------------------------------------------------------------------------------
    if is_alt then
        for key_name, letter in pairs(char.greek_keys) do
            if vc.ImGui_IsKeyPressed(key_name, true) then
                local desc = is_shift and char.greek_alt_shift[letter] or char.greek_alt[letter]
                local entry = desc and char.find_by_desc(desc)
                if not entry then
                    -- No distinct greek glyph for this letter (or none mapped) - fall back to
                    -- the plain/uppercase Latin letter, same as old/comments.h did.
                    entry = char.find_by_ascii(is_shift and letter:upper() or letter)
                end
                if entry then
                    push_undo(state, "type")
                    delete_selection(state)
                    insert_ncod(entry.ncod, char.size_delta_by_desc[entry.desc])
                end
            end
        end
    else
        local codepoints = vc.ImGui_input_queue_chars()
        for _, cp in ipairs(codepoints) do
            -- > 32, not >= : space is handled explicitly above (the char queue doesn't always
            -- carry it), so skip it here to avoid inserting it twice on a frame where it does.
            if cp > 32 and cp < 256 then
                local entry = char.find_by_ascii(string.char(cp))
                if entry then
                    push_undo(state, "type")
                    delete_selection(state)
                    insert_ncod(entry.ncod)
                end
            end
        end
    end

    -- Deletion -------------------------------------------------------------------------------------
    if vc.ImGui_IsKeyPressed("ImGuiKey_Backspace", true) then
        -- Consecutive backspaces coalesce into one undo step (deleting a whole word this way
        -- comes back in one Ctrl+Z), but not with typing before them - a plain key mismatch
        -- against "type" already ensures that, no extra bookkeeping needed.
        if selection_range(state) or state.cursor_pos > 0 then
            push_undo(state, "backspace")
        end
        if not delete_selection(state) and state.cursor_pos > 0 then
            table.remove(state.chars, state.cursor_pos)
            state.cursor_pos = state.cursor_pos - 1
        end
    end
    if vc.ImGui_IsKeyPressed("ImGuiKey_Delete", true) then
        if selection_range(state) or state.cursor_pos < #state.chars then
            push_undo(state, "delete")
        end
        if not delete_selection(state) and state.cursor_pos < #state.chars then
            table.remove(state.chars, state.cursor_pos + 1)
        end
    end

    -- Enter ----------------------------------------------------------------------------------------
    if vc.ImGui_IsKeyPressed("ImGuiKey_Enter", true) or vc.ImGui_IsKeyPressed("ImGuiKey_KeypadEnter", true) then
        push_undo(state, nil)
        delete_selection(state)
        table.insert(state.chars, state.cursor_pos + 1, {newline=true})
        state.cursor_pos = state.cursor_pos + 1
    end

    -- Left/Right, with Ctrl word-skip (port of old/comments.h's whitespace-then-alnum scan).
    -- A plain (non-shift) arrow with an active selection collapses to that selection's edge,
    -- same as most editors, instead of moving one char from the current cursor. -----------------
    if vc.ImGui_IsKeyPressed("ImGuiKey_LeftArrow", true) then
        local lo = selection_range(state)
        local adjacent_formula = state.cursor_pos > 0 and state.chars[state.cursor_pos].formula
        if lo and not is_shift then
            state.cursor_pos = lo
            state.selection_anchor = nil
        elseif is_ctrl and not is_shift and adjacent_formula then
            -- Ctrl+Left right after a formula enters it (at its own end, since we're arriving
            -- from its right side) instead of word-skipping straight over it as a single unit -
            -- the symmetric counterpart to Ctrl+Left/Right already leaving a formula FROM inside
            -- (see mformula's own handle_input caller in this file).
            state.selection_anchor = nil
            state.active_formula = adjacent_formula
            state.active_formula.cursor = {row = state.active_formula.root, pos = #state.active_formula.root.items}
        else
            update_selection_for_move(state, is_shift)
            local function on_ws()    return is_whitespace(state.chars[state.cursor_pos]) end
            local function on_alnum() return is_alnum(state.chars[state.cursor_pos]) end
            local function move()     if state.cursor_pos > 0 then state.cursor_pos = state.cursor_pos - 1 end end
            if not is_ctrl then
                move()
            else
                while state.cursor_pos ~= 0 and on_ws() do move() end
                repeat
                    move()
                until state.cursor_pos == 0 or not on_alnum()
            end
        end
    end
    if vc.ImGui_IsKeyPressed("ImGuiKey_RightArrow", true) then
        local _, hi = selection_range(state)
        local adjacent_formula = state.cursor_pos < #state.chars and state.chars[state.cursor_pos+1].formula
        if hi and not is_shift then
            state.cursor_pos = hi
            state.selection_anchor = nil
        elseif is_ctrl and not is_shift and adjacent_formula then
            -- Mirror of the Left case above: Ctrl+Right right before a formula enters it at its
            -- own start.
            state.selection_anchor = nil
            state.active_formula = adjacent_formula
            state.active_formula.cursor = {row = state.active_formula.root, pos = 0}
        else
            update_selection_for_move(state, is_shift)
            local function on_ws()    return is_whitespace(state.chars[state.cursor_pos+1]) end
            local function on_alnum() return is_alnum(state.chars[state.cursor_pos+1]) end
            local function move()     if state.cursor_pos < #state.chars then state.cursor_pos = state.cursor_pos + 1 end end
            if not is_ctrl then
                move()
            else
                while state.cursor_pos ~= #state.chars and on_ws() do move() end
                repeat
                    move()
                until state.cursor_pos == #state.chars or not on_alnum()
            end
        end
    end

    -- Home/End (not in old, cheap to add) -----------------------------------------------------------
    if vc.ImGui_IsKeyPressed("ImGuiKey_Home", true) then
        update_selection_for_move(state, is_shift)
        while state.cursor_pos ~= 0 and not is_newline(state.chars[state.cursor_pos]) do
            state.cursor_pos = state.cursor_pos - 1
        end
    end
    if vc.ImGui_IsKeyPressed("ImGuiKey_End", true) then
        update_selection_for_move(state, is_shift)
        while state.cursor_pos ~= #state.chars and not is_newline(state.chars[state.cursor_pos+1]) do
            state.cursor_pos = state.cursor_pos + 1
        end
    end

    -- Up/Down: preserve column distance across the nearest newline markers (port of
    -- old/comments.h's algorithm) ----------------------------------------------------------------
    if vc.ImGui_IsKeyPressed("ImGuiKey_UpArrow", true) then
        update_selection_for_move(state, is_shift)
        local dist = 0
        while state.cursor_pos ~= 0 and not is_newline(state.chars[state.cursor_pos]) do
            state.cursor_pos = state.cursor_pos - 1
            dist = dist + 1
        end
        if state.cursor_pos ~= 0 and is_newline(state.chars[state.cursor_pos]) then
            state.cursor_pos = state.cursor_pos - 1
        end
        local maxdist = 0
        while state.cursor_pos ~= 0 and not is_newline(state.chars[state.cursor_pos]) do
            state.cursor_pos = state.cursor_pos - 1
            maxdist = maxdist + 1
        end
        state.cursor_pos = state.cursor_pos + math.min(dist, maxdist)
    end
    if vc.ImGui_IsKeyPressed("ImGuiKey_DownArrow", true) then
        update_selection_for_move(state, is_shift)
        local dist = 0
        while state.cursor_pos ~= 0 and not is_newline(state.chars[state.cursor_pos]) do
            state.cursor_pos = state.cursor_pos - 1
            dist = dist + 1
        end
        while state.cursor_pos ~= #state.chars and not is_newline(state.chars[state.cursor_pos+1]) do
            state.cursor_pos = state.cursor_pos + 1
        end
        if state.cursor_pos ~= #state.chars then
            state.cursor_pos = state.cursor_pos + 1
        end
        while dist > 0 and state.cursor_pos ~= #state.chars and not is_newline(state.chars[state.cursor_pos+1]) do
            state.cursor_pos = state.cursor_pos + 1
            dist = dist - 1
        end
    end

    -- Mouse: a plain click just places the cursor - no selection yet (selection_anchor stays
    -- nil, not "anchor == cursor_pos", otherwise the next unrelated cursor move, e.g. typing a
    -- character, would suddenly turn that zero-width non-selection into a real one). Only an
    -- actual drag (the mouse moving to a different position while still held) lazily starts a
    -- selection, anchored at the click's origin. Shift+click extends from the current cursor
    -- instead of starting fresh. -------------------------------------------------------------
    local clicked = vc.ImGui_IsMouseClicked("ImGuiMouseButton_Left", false)
    local down = vc.ImGui_IsMouseDown("ImGuiMouseButton_Left")
    if clicked then
        local mpos = vc.ImGui_GetMousePos()
        for _, fb in ipairs(state.last_formula_boxes or {}) do
            if mpos.x >= fb.x and mpos.x <= fb.x + fb.w and mpos.y >= fb.y and mpos.y <= fb.y + fb.h then
                -- Entering a formula, like re-activating a content.lua box, shouldn't also do
                -- the normal click-places-cursor thing - it just brings it into edit mode.
                state.active_formula = fb.formula
                return
            end
        end
    end
    if clicked then
        local nearest = nearest_position(state, vc.ImGui_GetMousePos())
        if nearest then
            if is_shift then
                if not state.selection_anchor then
                    state.selection_anchor = state.cursor_pos
                end
            else
                state.selection_anchor = nil
            end
            state.cursor_pos = nearest
            state.mouse_click_origin = nearest
            state.mouse_selecting = true
        end
    elseif down and state.mouse_selecting then
        local nearest = nearest_position(state, vc.ImGui_GetMousePos())
        if nearest and nearest ~= state.cursor_pos then
            if not state.selection_anchor then
                state.selection_anchor = state.mouse_click_origin
            end
            state.cursor_pos = nearest
        end
    elseif not down then
        state.mouse_selecting = false
    end
end

-- #################################################################################################
-- Layout / render
-- #################################################################################################

-- Line height + baseline offset, derived once per font size from real glyph metrics (measuring
-- 'G' for the cap top and 'g' for the descender bottom - same trick old/comments.h used).
local metrics_cache = {}
local function get_metrics(fontset, sz)
    local cached = metrics_cache[sz]
    if cached then
        return cached
    end
    local G, g = char.find_by_ascii("G"), char.find_by_ascii("g")
    local G_sz = fontset:char_get_sz({size=sz, code=G.ncod})
    local g_sz = fontset:char_get_sz({size=sz, code=g.ncod})
    local m = {
        line_height = g_sz.bl.y - G_sz.tr.y,
        baseline_shift = G_sz.tr.y,
    }
    metrics_cache[sz] = m
    return m
end

--[[ For a glyph rendered at a boosted size (item.size_off - see insert_ncod()'s comment),
char_draw's raw font-baseline convention (unlike mexpr_symbol's, which recenters letters on their
own "middle of a") gives no guarantee the glyph's visual center lands anywhere near the
surrounding text's. True in particular for "\\int" (see char.size_delta_by_desc's comment):
cmex10's integral glyph is designed for EXTERNAL vertical centering (the way mexpr_bigop positions
it against its operands), not standalone inline use, so its raw baseline sits far from where plain
letters expect it - and the gap grows right along with the size boost. Centering the glyph's own
bounding box on the line's vertical center, instead of trying to align baselines at all, sidesteps
needing to know that font's specific metrics. Only ever applied to a size_off'd item - a normal
glyph's own raw baseline already IS the right place to draw it, so this must come out as 0 for
those (untested here - callers only invoke this under an `item.size_off` check to begin with). ]]
local function boosted_glyph_yshift(m, item_sz)
    local glyph_center = (item_sz.tr.y + item_sz.bl.y) / 2
    local line_center = m.baseline_shift + m.line_height / 2
    return line_center - glyph_center
end

local CURSOR_COLOR = 0xff00ffff
local TEXT_COLOR = 0xffeeeeee
local SELECTION_COLOR = 0x55cc6622 -- translucent, drawn on top of already-drawn text
local FORMULA_MARGIN = 4
local FORMULA_BORDER_COLOR = 0xff777777
local FORMULA_ACTIVE_BORDER_COLOR = 0xff00ffff
-- Muted green for the debug cursor-travel track drawn under the active formula - low-contrast
-- against the editor background so it reads as a guide rather than another foreground element
-- competing with the text/border. Half the opacity of a fully-solid line/dot (twice as faded),
-- offset by drawing it twice as thick (see the AddLine/AddCircleFilled calls below) so it stays
-- readable rather than just fainter.
local CURSOR_TRACK_COLOR = 0x8055cc55
-- Faint outline marking an empty sup/sub slot's clickable area - visible enough to show there's
-- something there to click, subdued enough not to read as actual content.
local EMPTY_SLOT_COLOR = 0xff888844

--[[ Draws state onto the current ImGui window, starting at `pos`, using font size `sz`,
soft-wrapping lines wider than `width_limit` (pass nil/false to disable soft-wrap). The blinking
caret is only drawn when `show_cursor` is true (or omitted) - a caller managing several editors
(e.g. content.lua's boxes) should pass false for every editor that isn't the active one.
@return the total content height in pixels (bottom of the last line, relative to pos.y) - lets a
caller (e.g. content.lua's boxes) size itself to fit. ]]
function editor.draw(state, fontset, pos, sz, width_limit, show_cursor)
    if show_cursor == nil then
        show_cursor = true
    end
    local m = get_metrics(fontset, sz)

    -- Pass 1 (measure only, nothing drawn): a normal line spans [baseline_shift, baseline_shift
    -- + line_height] relative to its own baseline. Find how far past that envelope the tallest
    -- item on each line reaches - above and below - so a line holding a formula taller than
    -- plain text (e.g. a nested exponent tower) can grow to fit it in pass 2, instead of it
    -- clipping out of its line/box. Must make exactly the same line-break decisions as pass 2
    -- below (same width_limit check, same order) or the two would disagree about which line is
    -- which. ---------------------------------------------------------------------------------
    local line_extra_top, line_extra_bottom = {[1] = 0}, {[1] = 0}
    do
        local line_idx = 1
        local lx = 0
        for i = 0, #state.chars do
            local item = state.chars[i+1]
            if item then
                if item.newline then
                    line_idx = line_idx + 1
                    line_extra_top[line_idx], line_extra_bottom[line_idx] = 0, 0
                    lx = 0
                elseif item.formula then
                    local box = mformula.measure(item.formula, fontset, sz)
                    local extra_top = math.max(0, m.baseline_shift - box.top)
                    local extra_bottom = math.max(0, box.bottom - (m.baseline_shift + m.line_height))
                    line_extra_top[line_idx] = math.max(line_extra_top[line_idx], extra_top)
                    line_extra_bottom[line_idx] = math.max(line_extra_bottom[line_idx], extra_bottom)
                    -- +2*margin: pass 2 reserves a margin's worth of gap on EACH side of the box
                    -- (see its own comment) so the border never touches neighboring text - must
                    -- match here too, or this pass's line-break decisions would disagree with
                    -- pass 2's.
                    lx = lx + box.width + 2 * FORMULA_MARGIN
                else
                    -- item.size_off (see insert_ncod()'s comment) renders this ONE glyph at a
                    -- bigger/smaller size than the rest of the line - "\\int" is the only glyph
                    -- that currently sets it. A bigger glyph reaches further above/below the
                    -- normal line band than plain text does, same idea as a formula's
                    -- extra_top/extra_bottom above - without this, a bigger integral sign would
                    -- clip into the line above/below it instead of the line growing to fit.
                    local eff_sz = math.max(1, math.min(16, sz + (item.size_off or 0)))
                    local item_sz = fontset:char_get_sz({size=eff_sz, code=item.code})
                    if item.size_off then
                        local yshift = boosted_glyph_yshift(m, item_sz)
                        line_extra_top[line_idx] = math.max(line_extra_top[line_idx],
                                math.max(0, m.baseline_shift - (item_sz.tr.y + yshift)))
                        line_extra_bottom[line_idx] = math.max(line_extra_bottom[line_idx],
                                math.max(0, (item_sz.bl.y + yshift) - (m.baseline_shift + m.line_height)))
                    end
                    if width_limit and lx + item_sz.adv > width_limit then
                        line_idx = line_idx + 1
                        line_extra_top[line_idx], line_extra_bottom[line_idx] = 0, 0
                        lx = 0
                    end
                    lx = lx + item_sz.adv
                end
            end
        end
    end

    -- Pass 2: the actual draw. ------------------------------------------------------------------
    local x, line_idx = pos.x, 1
    local line_top = pos.y + line_extra_top[1]
    local y = line_top - m.baseline_shift
    local positions = {}
    local formula_boxes = {}
    local cursor_screen_pos = nil
    -- Set only if the active formula's own draw() reports a caret position this frame (see its
    -- comment) - the plain outer cursor_screen_pos above doesn't move while a formula owns input,
    -- so it can't stand in for "where's the caret right now" in that case.
    local formula_cursor_top, formula_cursor_h = nil, nil

    local function newline()
        local finished_extra_bottom = line_extra_bottom[line_idx] or 0
        line_idx = line_idx + 1
        x = pos.x
        line_top = line_top + m.line_height + finished_extra_bottom + (line_extra_top[line_idx] or 0)
        y = line_top - m.baseline_shift
    end

    for i = 0, #state.chars do
        local item = state.chars[i+1]
        local item_sz = nil
        local eff_sz = sz
        if item and not item.newline and not item.formula then
            eff_sz = math.max(1, math.min(16, sz + (item.size_off or 0)))
            item_sz = fontset:char_get_sz({size=eff_sz, code=item.code})
            if width_limit and (x - pos.x) + item_sz.adv > width_limit then
                newline()
            end
        end

        positions[#positions+1] = {x=x, y=line_top, i=i}
        if i == state.cursor_pos then
            cursor_screen_pos = {x=x, y=line_top}
        end

        if item then
            if item.newline then
                newline()
            elseif item.formula then
                -- Inline embed: rendered through mformula/mexpr, not char_draw. "Made to fit" -
                -- the margin box below is sized exactly to this frame's actual bounding box, so
                -- it always hugs the formula's current content, growing/shrinking live as it's
                -- edited, the same way content.lua's boxes fit editor.lua's text.
                local is_active_formula = (item.formula == state.active_formula)
                local margin = FORMULA_MARGIN
                -- Content starts a margin's width in from `x` (where the preceding text/box
                -- border ended) - so the border (drawn at content_x - margin, i.e. back at `x`
                -- itself) never touches it, and symmetrically the final advance below leaves the
                -- same gap before whatever comes next. Without this, the border - not just the
                -- content - visually overlapped neighboring text, since `x` only ever advanced by
                -- box.width, not the margin around it.
                local content_x = x + margin

                -- Debug: a graph of every position ANY navigation key can reach - Left/Right
                -- within a row, Up/Down into a node's sup/sub - so navigation fixes can be
                -- checked by eye, not just the left-right chain. Drawn through the text itself
                -- (mformula.reachable_graph() places each node exactly where that position's own
                -- blinker would sit, sup/sub included), not below the box - it needs to cross the
                -- glyphs' own bounding boxes to read as "these are the gaps between them", not as
                -- a separate strip underneath. Drawn BEFORE the formula itself so the glyphs (and
                -- the real blinker, also drawn by mformula.draw below) layer on top of the track,
                -- not the other way around. Active formula only - it'd just be clutter for the
                -- others.
                local markers = nil
                if is_active_formula then
                    local graph = mformula.reachable_graph(item.formula, fontset, sz)
                    for _, e in ipairs(graph.edges) do
                        local na, nb = graph.nodes[e.a], graph.nodes[e.b]
                        vc.ImGui_AddLine({x = content_x + na.x, y = y + na.y},
                                {x = content_x + nb.x, y = y + nb.y}, CURSOR_TRACK_COLOR, 2)
                    end
                    for _, n in ipairs(graph.nodes) do
                        vc.ImGui_AddCircleFilled({x = content_x + n.x, y = y + n.y}, 4, CURSOR_TRACK_COLOR)
                    end

                    -- Every row (root included - "after A_B", past the whole formula, needs a
                    -- marker too, or that position is only reachable by arrow keys, never by
                    -- clicking) gets a marker right after its own content (its only position if
                    -- it's empty, right after its last glyph if it isn't) - real, clickable there
                    -- either way, but otherwise invisible (mexpr_empty() only paints under a
                    -- whole-tree debug flag draw() doesn't use). Outline it so an empty slot
                    -- ("click here to start") and a filled one ("room to keep typing") read the
                    -- same way instead of only the empty one showing anything.
                    markers = mformula.slot_markers(item.formula, fontset, sz)
                    for _, mk in ipairs(markers) do
                        vc.ImGui_AddRect({x = content_x + mk.x, y = y + mk.y},
                                {x = content_x + mk.x + mk.w, y = y + mk.y + mk.h}, EMPTY_SLOT_COLOR, 2, 1)
                    end
                end

                local box = mformula.draw(item.formula, fontset, {x=content_x, y=y}, sz, is_active_formula)
                if is_active_formula and box.cursor_top then
                    formula_cursor_top, formula_cursor_h = y + box.cursor_top, box.cursor_h
                end

                -- The click-routing rect (is a click "inside" this formula, or does it deactivate
                -- it?) has to cover every marker too, not just the formula's own content bbox -
                -- root's trailing marker in particular sticks out past box.width on purpose (see
                -- the comment above). Without this, clicking on a marker that pokes past the
                -- border would read as "outside" and deactivate the formula instead of
                -- hit-testing into it.
                local rect_l, rect_r, rect_t, rect_b = 0, box.width, box.top, box.bottom
                if markers then
                    for _, mk in ipairs(markers) do
                        rect_l = math.min(rect_l, mk.x)
                        rect_r = math.max(rect_r, mk.x + mk.w)
                        rect_t = math.min(rect_t, mk.y)
                        rect_b = math.max(rect_b, mk.y + mk.h)
                    end
                end

                formula_boxes[#formula_boxes+1] = {
                    x = content_x + rect_l - margin, y = y + rect_t - margin,
                    w = (rect_r - rect_l) + 2 * margin, h = (rect_b - rect_t) + 2 * margin,
                    formula = item.formula,
                    draw_x = content_x, draw_y = y, -- the raw origin mformula.draw()/hit_test()
                                                     -- use - NOT the margin-inset box above
                }
                -- Same rect as formula_boxes above, not just box.top/width/bottom - the border
                -- has to visually grow to actually contain a marker that sticks out past the
                -- formula's own content (root's trailing one especially), not just let the
                -- click-routing rect quietly cover a spot the border doesn't reach.
                vc.ImGui_AddRect(
                    {x = content_x + rect_l - margin, y = y + rect_t - margin},
                    {x = content_x + rect_r + margin, y = y + rect_b + margin},
                    is_active_formula and FORMULA_ACTIVE_BORDER_COLOR or FORMULA_BORDER_COLOR,
                    3, is_active_formula and 2 or 1)

                x = content_x + rect_r + margin
            else
                local draw_y = y
                if item.size_off then
                    draw_y = y + boosted_glyph_yshift(m, item_sz)
                end
                fontset:char_draw({size=eff_sz, code=item.code}, {x=x, y=draw_y}, TEXT_COLOR, false, 0)
                x = x + item_sz.adv
            end
        end
    end

    state.last_positions = positions
    state.last_formula_boxes = formula_boxes
    state.last_line_height = m.line_height
    state.frame = state.frame + 1

    -- Where the caret ACTUALLY is right now, screen-space, regardless of which of the two carets
    -- (this editor's own, or an active formula's - only one is ever showing at a time, see
    -- show_cursor below) is the real one this frame - content.lua reads this every frame to keep
    -- it scrolled into view, the same way it already does for a box switch (scroll_into_view) but
    -- continuously, since typing/arrow-key movement/a formula growing can all move the caret
    -- without any of those already having scrolled for it. nil when there's nothing to track yet
    -- (an empty box with no active formula has no caret at all).
    if state.active_formula then
        state.last_cursor_y, state.last_cursor_h = formula_cursor_top, formula_cursor_h
    elseif cursor_screen_pos then
        state.last_cursor_y, state.last_cursor_h = cursor_screen_pos.y, m.line_height
    else
        state.last_cursor_y, state.last_cursor_h = nil, nil
    end

    -- Selection highlight: one translucent rect per glyph cell (so it naturally handles
    -- multi-line selections), drawn on top of the text just drawn above.
    if state.selection_anchor and state.selection_anchor ~= state.cursor_pos then
        local lo = math.min(state.selection_anchor, state.cursor_pos)
        local hi = math.max(state.selection_anchor, state.cursor_pos)
        for i = lo, hi - 1 do
            local cell_start = positions[i+1]
            local cell_end = positions[i+2]
            if cell_start and cell_end then
                local end_x = (cell_end.y == cell_start.y) and cell_end.x or (cell_start.x + 8)
                vc.ImGui_AddRectFilled(
                    {x=cell_start.x, y=cell_start.y},
                    {x=end_x, y=cell_start.y + m.line_height},
                    SELECTION_COLOR, 0)
            end
        end
    end

    -- Blinking caret: a real drawn line (vc.ImGui_AddLine), not stored in the model - a faithful
    -- port of old/comments.h's draw_blinker, now that AddLine is actually exposed to Lua.
    -- (~30 frames/half-period, roughly a 0.5s blink at 60fps.) Suppressed while a formula embed
    -- is active - its own caret (drawn above, inside mformula.draw) is the one that should show.
    if show_cursor and not state.active_formula and cursor_screen_pos
            and (math.floor(state.frame / 30) % 2 == 0) then
        -- cursor_screen_pos.y is the TOP of the current line (line_top), so the caret spans
        -- downward across it, not upward into the line above.
        vc.ImGui_AddLine(
            {x=cursor_screen_pos.x, y=cursor_screen_pos.y},
            {x=cursor_screen_pos.x, y=cursor_screen_pos.y + m.line_height},
            CURSOR_COLOR, 2)
    end

    return (line_top - pos.y) + m.line_height + (line_extra_bottom[line_idx] or 0)
end

return editor

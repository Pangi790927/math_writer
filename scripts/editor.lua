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
local mexpru = require("mexpru")
local mformula = require("mformula_new")
local prof = require("prof")

local editor = {}

-- char.lua's own m_font_sizes table length - mexpru's own canonical copy (2026-09-04's Ctrl+
-- MouseWheel zoom levels). Used below to clamp a boosted glyph's (item.size_off) effective size
-- into the valid table range.
local MAX_SIZE_INDEX = mexpru.MAX_SIZE_INDEX

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
local function insert_text(state, text, fontset)
    local i = 1
    while i <= #text do
        local c = text:sub(i, i)
        if text:sub(i, i + 1) == "$$" then
            -- plain=true: "$$" would otherwise be read as a Lua pattern (end-of-string anchors),
            -- not a literal substring.
            local close = text:find("$$", i + 2, true)
            local inner = text:sub(i + 2, close and (close - 1) or #text)
            -- mexpru.DEFAULT_SIZE, not a live outer size - same reasoning as Ctrl+M's own formula
            -- construction above (mexpru.DEFAULT_SIZE's own comment).
            local formula = mformula.from_latex(fontset, mexpru.DEFAULT_SIZE, inner)
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
function editor.from_text(state, text, fontset)
    state.chars = {}
    state.cursor_pos = 0
    state.selection_anchor = nil
    insert_text(state, text, fontset)
end

--[[ Rescales every formula embed in state.chars at the CURRENT global zoom (mexpru.set_zoom(), set
by content.lua just before calling this) - content.lua's own Ctrl+MouseWheel handler calls this for
every box any time the zoom actually changes, so already-typed formula content visibly
catches up (mformula_new.rescale()'s own comment - plain text needs no equivalent call here, it's
never baked into anything, always measured/drawn fresh from the live `sz` passed to draw() itself). ]]
function editor.rescale(state, fontset)
    for _, item in ipairs(state.chars) do
        if item.formula then
            mformula.rescale(item.formula, fontset)
        end
    end
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

--[[ deep_copy() alone is NOT enough for a formula embed: it copies Lua tables but passes userdata
straight through, and an mexpr_t is userdata - so a snapshot's formula shared the LIVE tree, which
propagate_rebuild() then cuts out from under it (mformula_new.clone()'s own comment). Every formula
item therefore gets a real, independent copy here, which is exactly what undo_or_redo() below
already claims to be restoring.

`fontset` comes off state._fontset, stashed by handle_input each frame: snapshot() is reached from
a dozen push_undo() call sites that have no reason to know about fonts, and deep_copy() skips
"_"-prefixed keys, so parking it there costs nothing and can't leak into a snapshot. ]]
local function snapshot(state)
    local chars = deep_copy(state.chars)
    if state._fontset then
        for _, item in ipairs(chars) do
            if item.formula then
                item.formula = mformula.clone(item.formula, state._fontset)
            end
        end
    end
    --[[ Which formula owned input, by its INDEX in chars rather than by the table itself: the
    restore hands back all-new item tables, so the identity is gone but the position is not. This
    is what lets undo_or_redo() put the user back inside the formula they were editing (reported
    live: "space, ctrl+z, the undo operation went ok, but the cursor jumped outside the
    formula, I want it to stay there"). The formula's own internal cursor rides along on its clone,
    which mformula.clone() maps across for exactly this reason. ]]
    local active_idx
    if state.active_formula then
        for i, item in ipairs(state.chars) do
            if item.formula == state.active_formula then
                active_idx = i
                break
            end
        end
    end
    return {
        chars = chars,
        cursor_pos = state.cursor_pos,
        selection_anchor = state.selection_anchor,
        active_formula_idx = active_idx,
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
    -- Any real edit outdates the cached pre-edit snapshot (see its own comment in handle_input) -
    -- invalidated here rather than at each call site, since this is the one place every edit passes
    -- through.
    state._undo_baseline = nil
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
    --[[ Every mutating action in this file funnels through here, which makes it the one place worth
    tagging the frame from (prof.lua / perf_composer.h). A spike frame's report then reads
    "events: edit:backspace" instead of leaving the cause to be inferred from the timings - which is
    the entire difference between "draw took 40ms" and knowing what to go and look at. The
    coalesce_key already names the action for undo's own purposes; nil means one of the structural
    edits that never coalesces. ]]
    prof.event("edit:" .. (coalesce_key or "structural"))
    commit_undo(state, snapshot(state), coalesce_key)
end

--[[ Ctrl+Z / Ctrl+Shift+Z. Restores the formula that owned input too, by the index snapshot()
recorded - the restored chars are all-new tables, so the old active_formula reference cannot be
reused, but the item at that index is the same formula and undoing an edit made INSIDE one should
leave you still inside it. Falls back to plain editing when that index holds no formula any more
(the undone edit deleted it, say). A no-op when the relevant stack is empty. ]]
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
    local restored = snap.active_formula_idx and state.chars[snap.active_formula_idx]
    state.active_formula = restored and restored.formula or nil
    state.undo_coalesce_key = nil
    state._undo_baseline = nil      -- the state just changed wholesale; any cached one is stale
end

--[[ The two halves of one frame of editing INSIDE a formula, called by handle_input() around
mformula.handle_input() and exported so a test can drive the same sequence (that branch itself needs
real keypresses).

begin: make sure a pre-edit baseline exists - CACHED, not rebuilt per frame, because rebuilding it
means cloning every formula tree and that made the editor visibly lag - and return where the caret
is RIGHT NOW, as a path.

The split exists because those two have different lifetimes, which is the bug that produced it: the
baseline stays valid until an edit changes the tree, but the caret moves freely without bumping
version, so the caret position inside a cached baseline goes stale immediately. commit stamps the
freshly-captured path onto the baseline before recording it, so Ctrl+Z restores the tree AND puts
the caret back where the undone edit started, not where the previous one left it. ]]
function editor.begin_formula_edit(state)
    if not state._undo_baseline then
        state._undo_baseline = snapshot(state)
    end
    return mformula.cursor_path(state.active_formula)
end

function editor.commit_formula_edit(state, cursor_path)
    local snap = state._undo_baseline
    if not snap then
        return
    end
    local idx = snap.active_formula_idx
    local snap_item = idx and snap.chars[idx]
    if snap_item and snap_item.formula then
        mformula.cursor_from_path(snap_item.formula, cursor_path)
    end
    commit_undo(state, snap, nil)
end

--[[ Exported for tests only (the convention mformula_new's make_supsub()/make_frac() already use).
handle_input()'s own Ctrl+Z branch is the real entry point, and it needs real keypresses, so a test
that wants to undo something has to reach the machinery directly. ]]
editor.push_undo = push_undo
function editor.undo(state) undo_or_redo(state, false) end
function editor.redo(state) undo_or_redo(state, true) end

-- #################################################################################################
-- Input handling
-- #################################################################################################

--[[ `fontset`/`sz` are only needed for the one thing keyboard-only input handling never needed
before: hit-testing a click against an active formula's own drawn geometry (mformula.hit_test()
has to rebuild/measure rows to know where they land on screen, same as draw() does). ]]
function editor.handle_input(state, fontset, sz)
    -- Parked for snapshot()'s benefit (see its own comment) - "_"-prefixed, so deep_copy() never
    -- carries it into a snapshot.
    state._fontset = fontset
    -- Ctrl+Z/Ctrl+Shift+Z: checked first, ahead of even the active-formula dispatch below, so
    -- undo/redo works the same way regardless of whether a formula currently owns input - see
    -- undo_or_redo()'s own comment on why it always exits back to plain editing on restore.
    if (vc.ImGui_IsKeyDown(vc.ImGuiKey_LeftCtrl) or vc.ImGui_IsKeyDown(vc.ImGuiKey_RightCtrl))
            and vc.ImGui_IsKeyPressed(vc.ImGuiKey_Z, false) then
        undo_or_redo(state, vc.ImGui_IsKeyDown(vc.ImGuiKey_LeftShift) or vc.ImGui_IsKeyDown(vc.ImGuiKey_RightShift))
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
        local ctrl_down = vc.ImGui_IsKeyDown(vc.ImGuiKey_LeftCtrl) or vc.ImGui_IsKeyDown(vc.ImGuiKey_RightCtrl)
        local escaped = vc.ImGui_IsKeyPressed(vc.ImGuiKey_Escape, false)
        -- Ctrl+Left/Right always leave the formula, regardless of where the cursor is inside it -
        -- plain Left/Right staying parked at the formula's own start/end (mformula.lua's move_left/
        -- move_right do nothing further once there) is intentional, not something arrow keys
        -- should escape on their own.
        -- ...but NOT with Shift also held: Ctrl+Shift+Left/Right is the formula's own selection
        -- gesture (mformula_new's own extend_selection()), so intercepting it here would exit the
        -- formula on the very first attempt to select inside one.
        local shift_here = vc.ImGui_IsKeyDown(vc.ImGuiKey_LeftShift) or vc.ImGui_IsKeyDown(vc.ImGuiKey_RightShift)
        local ctrl_left = ctrl_down and not shift_here and vc.ImGui_IsKeyPressed(vc.ImGuiKey_LeftArrow, false)
        local ctrl_right = ctrl_down and not shift_here and vc.ImGui_IsKeyPressed(vc.ImGuiKey_RightArrow, false)
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
            --[[ A fresh click places the caret; HOLDING the button and moving drags a selection out
            of it (mformula's own hit_test(extend) keeps the anchor and moves only the far end,
            clamped to the row the drag started in). Tracked with the same click/hold/release shape
            state.mouse_selecting already uses for plain text, just aimed at the active formula. ]]
            local dragging_here = state.formula_dragging
                    and vc.ImGui_IsMouseDown("ImGuiMouseButton_Left")
            if clicked_inside_fb or dragging_here then
                local fb = clicked_inside_fb or state.formula_dragging
                local mpos = vc.ImGui_GetMousePos()
                local local_click = {x = mpos.x - fb.draw_x, y = mpos.y - fb.draw_y}
                -- RELATIVE (hit_test()'s own wrap_width comment) - fb.wrap_edge is ABSOLUTE
                -- (draw()'s own cache, above), same conversion cursor_rect()/draw() do internally,
                -- done here since hit_test() never receives draw_x itself (local_click is already
                -- draw_x-relative by the time it gets there).
                local wrap_width = fb.wrap_edge and (fb.wrap_edge - fb.draw_x)
                -- hit_test() mutates cursor_pos directly, the same convention move_*() uses,
                -- rather than returning a position for the caller to assign.
                mformula.hit_test(state.active_formula, fontset, sz, local_click, wrap_width,
                        dragging_here and not clicked_inside_fb)
                state.formula_dragging = fb
            end
            if not vc.ImGui_IsMouseDown("ImGuiMouseButton_Left") then
                state.formula_dragging = nil
            end
            -- One undo step per keystroke INSIDE a formula (not coalesced, unlike plain typing
            -- outside one) - but only when this keystroke actually changed the tree, not for pure
            -- cursor movement (Left/Right/Up/Down, or the click above) - mformula's own
            -- state.version (bumped by every real tree edit) is exactly that signal, so there's
            -- no need to re-derive "was this an edit" by hand here.
            --[[ The pre-edit snapshot is CACHED (state._undo_baseline), not rebuilt each frame.
            An undo step has to be captured before the edit that it undoes, but this branch runs on
            every frame a formula is active - so taking one unconditionally meant snapshotting
            continuously, ~60 times a second, to throw all but a handful away.

            That was merely wasteful while a snapshot was a shallow deep_copy; once snapshot() began
            cloning each formula's whole tree (it had to - see mformula_new.clone()) it became a
            full structural rebuild of every formula, every frame, and the editor visibly lagged.
            Reported live: "it lags a lot".

            A baseline stays valid until something actually changes the state, so it is invalidated
            in commit_undo() and undo_or_redo() - the two places that ever do. The cost is back to
            about one clone per edit instead of one per frame. ]]
            local formula = state.active_formula
            local pre_version = formula.version
            -- The caret path has to be taken BEFORE the edit - afterwards it has already moved with
            -- it. See editor.begin_formula_edit()'s comment for why it isn't read off the baseline.
            local pre_cursor_path = editor.begin_formula_edit(state)
            mformula.handle_input(formula, fontset, sz)
            if formula.version ~= pre_version then
                editor.commit_formula_edit(state, pre_cursor_path)
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

    local is_ctrl = vc.ImGui_IsKeyDown(vc.ImGuiKey_LeftCtrl) or vc.ImGui_IsKeyDown(vc.ImGuiKey_RightCtrl)
    local is_alt = vc.ImGui_IsKeyDown(vc.ImGuiKey_LeftAlt) or vc.ImGui_IsKeyDown(vc.ImGuiKey_RightAlt)
    local is_shift = vc.ImGui_IsKeyDown(vc.ImGuiKey_LeftShift) or vc.ImGui_IsKeyDown(vc.ImGuiKey_RightShift)

    -- Ctrl+M: insert a new formula embed at the cursor and enter it straight away. -------------
    if is_ctrl and vc.ImGui_IsKeyPressed(vc.ImGuiKey_M, false) then
        push_undo(state, nil)
        -- mexpru.DEFAULT_SIZE (a fixed LOGICAL baseline), NOT the live `sz` - `sz` is content.lua's
        -- CURRENT, possibly-already-zoomed state.font_size; baking that in directly here would
        -- double-count the zoom the moment mexpru.physical_sz() maps it again (2026-09-04's Ctrl+
        -- MouseWheel zoom - see mexpru.DEFAULT_SIZE's own comment). A brand-new formula still
        -- renders at the CURRENT zoom immediately either way - physical_sz() applies it fresh at
        -- construction regardless of which logical baseline was used.
        local formula = mformula.new(fontset, mexpru.DEFAULT_SIZE)
        table.insert(state.chars, state.cursor_pos + 1, {formula = formula})
        state.cursor_pos = state.cursor_pos + 1
        state.active_formula = formula
        return
    end

    -- Ctrl+/: insert a new formula embed here, already containing an empty fraction, and enter
    -- it - mirrors Ctrl+M above, just starting with a frac instead of a blank formula (see
    -- mformula.new_with_frac()'s own comment for why it doesn't wrap anything). -------------
    if is_ctrl and not is_shift and vc.ImGui_IsKeyPressed(vc.ImGuiKey_Slash, false) then
        push_undo(state, nil)
        -- mexpru.DEFAULT_SIZE, not the live `sz` - same reasoning as Ctrl+M just above.
        local formula = mformula.new_with_frac(fontset, mexpru.DEFAULT_SIZE)
        table.insert(state.chars, state.cursor_pos + 1, {formula = formula})
        state.cursor_pos = state.cursor_pos + 1
        state.active_formula = formula
        return
    end

    -- Ctrl+=: the same again for a stack - a new formula embed already holding a one-slot vert,
    -- cursor inside it. The third of the three containers reachable straight from plain text
    -- (Ctrl+M blank, Ctrl+/ fraction, Ctrl+= stack); asked for precisely so the stack
    -- stops being the odd one out that needs a Ctrl+M first. Ctrl+SHIFT+= is superscript and is
    -- handled in the block below - the `not is_shift` guard here is what keeps the two apart, the
    -- same split mformula_new.handle_input() makes for these keys INSIDE a formula. -------------
    if is_ctrl and not is_shift and vc.ImGui_IsKeyPressed(vc.ImGuiKey_Equal, false) then
        push_undo(state, nil)
        -- mexpru.DEFAULT_SIZE, not the live `sz` - same reasoning as Ctrl+M/Ctrl+/ above.
        local formula = mformula.new_with_vert(fontset, mexpru.DEFAULT_SIZE)
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
        if vc.ImGui_IsKeyPressed(vc.ImGuiKey_Minus, false) then
            slot = "sub"
        elseif vc.ImGui_IsKeyPressed(vc.ImGuiKey_Equal, false) then
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
            -- mexpru.DEFAULT_SIZE, not the live `sz` - same reasoning as Ctrl+M/Ctrl+/ above: a
            -- fixed LOGICAL baseline, never content.lua's already-zoomed state.font_size.
            local formula = mformula.new_from_base(fontset, mexpru.DEFAULT_SIZE, base_item, slot)
            table.insert(state.chars, state.cursor_pos + 1, {formula = formula})
            state.cursor_pos = state.cursor_pos + 1
            state.active_formula = formula
            return
        end
    end

    -- Ctrl+A/C/X/V: select all, copy, cut, paste -----------------------------------------------
    if is_ctrl then
        if vc.ImGui_IsKeyPressed(vc.ImGuiKey_A, false) then
            state.selection_anchor = 0
            state.cursor_pos = #state.chars
        end
        local copy = vc.ImGui_IsKeyPressed(vc.ImGuiKey_C, false)
        local cut = vc.ImGui_IsKeyPressed(vc.ImGuiKey_X, false)
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
        if vc.ImGui_IsKeyPressed(vc.ImGuiKey_V, false) then
            local text = vc.ImGui_GetClipboardText()
            if selection_range(state) or (text and #text > 0) then
                push_undo(state, nil)
            end
            delete_selection(state)
            if text then
                insert_text(state, text, fontset)
            end
        end
    end

    -- Space, handled explicitly rather than trusting it to show up via
    -- vc.ImGui_input_queue_chars() below (it doesn't always). ------------------------------------
    if not is_ctrl and vc.ImGui_IsKeyPressed(vc.ImGuiKey_Space, true) then
        push_undo(state, "type")
        delete_selection(state)
        insert_ncod(char.find_by_ascii(" ").ncod)
    end

    -- Typing -------------------------------------------------------------------------------------
    if is_alt then
        for key_id, letter in pairs(char.greek_key_ids) do
            if vc.ImGui_IsKeyPressed(key_id, true) then
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
    if vc.ImGui_IsKeyPressed(vc.ImGuiKey_Backspace, true) then
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
    if vc.ImGui_IsKeyPressed(vc.ImGuiKey_Delete, true) then
        if selection_range(state) or state.cursor_pos < #state.chars then
            push_undo(state, "delete")
        end
        if not delete_selection(state) and state.cursor_pos < #state.chars then
            table.remove(state.chars, state.cursor_pos + 1)
        end
    end

    -- Enter ----------------------------------------------------------------------------------------
    if vc.ImGui_IsKeyPressed(vc.ImGuiKey_Enter, true) or vc.ImGui_IsKeyPressed(vc.ImGuiKey_KeypadEnter, true) then
        push_undo(state, nil)
        delete_selection(state)
        table.insert(state.chars, state.cursor_pos + 1, {newline=true})
        state.cursor_pos = state.cursor_pos + 1
    end

    -- Left/Right, with Ctrl word-skip (port of old/comments.h's whitespace-then-alnum scan).
    -- A plain (non-shift) arrow with an active selection collapses to that selection's edge,
    -- same as most editors, instead of moving one char from the current cursor. -----------------
    if vc.ImGui_IsKeyPressed(vc.ImGuiKey_LeftArrow, true) then
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
            mformula.cursor_to_end(state.active_formula)
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
    if vc.ImGui_IsKeyPressed(vc.ImGuiKey_RightArrow, true) then
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
            mformula.cursor_to_start(state.active_formula)
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
    if vc.ImGui_IsKeyPressed(vc.ImGuiKey_Home, true) then
        update_selection_for_move(state, is_shift)
        while state.cursor_pos ~= 0 and not is_newline(state.chars[state.cursor_pos]) do
            state.cursor_pos = state.cursor_pos - 1
        end
    end
    if vc.ImGui_IsKeyPressed(vc.ImGuiKey_End, true) then
        update_selection_for_move(state, is_shift)
        while state.cursor_pos ~= #state.chars and not is_newline(state.chars[state.cursor_pos+1]) do
            state.cursor_pos = state.cursor_pos + 1
        end
    end

    -- Up/Down: preserve column distance across the nearest newline markers (port of
    -- old/comments.h's algorithm) ----------------------------------------------------------------
    if vc.ImGui_IsKeyPressed(vc.ImGuiKey_UpArrow, true) then
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
    if vc.ImGui_IsKeyPressed(vc.ImGuiKey_DownArrow, true) then
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

--[[ The narrowest CONTENT column a formula may be handed, as a multiple of the line height (so it
scales with the font instead of being a pixel constant).

Not cosmetic. mexpr_draw_rec() (math_expr_composer.h) wraps a node by stepping it left by exactly
one column width per row until it lands inside the column - and when that width is zero or negative
the step is zero or positive, so the node never moves in and the loop never ends. That is a hard
hang: 100% of one core, flat memory, no error, the window simply stops responding.

Reproduced from the report "too large of a zoom out crashes the application", minimally
as the 21-byte document "$$x+y$$$$a+b$$$$c+d$$" plus eleven Ctrl+MouseWheel steps: at that size the
first formula fills the column, and the second one is then laid out at an x already past the wrap
edge. Nothing to do with the integral or with any font size being missing - the size index is
clamped to the table's own bounds long before this (mexpru.physical_sz()).

Two things keep it from happening now: a formula with less than this much room left starts a new
line, the same rule plain glyphs already followed, and the column actually passed down is clamped to
at least this much so even a box narrower than one is never a degenerate column. The C++ loop should
still refuse to run on a non-positive column - a layout bug must not be able to hang the app - but
that belongs in math_expr_composer.h, not here. ]]
local MIN_FORMULA_COLUMN_LINES = 1

--[[ Where a formula goes on the line it is currently on. `used` is how far along that line the
layout has already advanced (pass 1's lx, pass 2's x - pos.x); returns (break_line, column):

  break_line - start a new line before drawing it, the same rule a glyph that doesn't fit follows.
               Never true at the start of a line, where breaking would gain nothing and could
               repeat forever.
  column     - the CONTENT width to hand down, floored at MIN_FORMULA_COLUMN_LINES worth so it is positive
               even in a box too narrow to hold one - see MIN_FORMULA_COLUMN_LINES.

Both passes call this rather than each doing the arithmetic, because a disagreement between them
about which line a formula lands on is its own class of bug (see pass 1's own comment). ]]
local function formula_line_fit(m, width_limit, used)
    if not width_limit then
        return false, nil
    end
    local min_col = m.line_height * MIN_FORMULA_COLUMN_LINES
    local remaining = width_limit - used - 2 * FORMULA_MARGIN
    if used > 0 and remaining < min_col then
        -- Break: the column becomes the whole line's worth, measured from its start.
        return true, math.max(min_col, width_limit - 2 * FORMULA_MARGIN)
    end
    return false, math.max(min_col, remaining)
end

-- Exported for tests only (the convention mformula_new's make_supsub()/make_frac() already use):
-- the passes that call it live inside draw(), which needs a real ImGui frame to run.
editor.formula_line_fit = formula_line_fit
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
`show_wireframe` (default false) is forwarded to every inline formula's own mformula.draw() - the
debug bounding-box overlay (vc.mexpr_draw's draw_bb), off by default so it's only on when actually
visually debugging (content.lua's own wireframe-toggle button).
`show_graph` (default false) gates the ACTIVE formula's own reachable-position graph (mformula.
reachable_graph() - ported from the old row-based mformula.lua) - off by default, same
reasoning as show_wireframe, content.lua's own graph-toggle button flips it on.
@return the total content height in pixels (bottom of the last line, relative to pos.y), and the
widest any single line's own content actually reached (relative to pos.x - may exceed width_limit,
see max_x's own comment below) - lets a caller (e.g. content.lua's boxes) size itself to fit both. ]]
function editor.draw(state, fontset, pos, sz, width_limit, show_cursor, show_wireframe, show_graph)
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
                    local break_line, wrap_width = formula_line_fit(m, width_limit, lx)
                    if break_line then
                        line_idx = line_idx + 1
                        line_extra_top[line_idx], line_extra_bottom[line_idx] = 0, 0
                        lx = 0
                    end
                    -- Mirrors pass 2's own content_x = x + margin (x here IS pos.x + lx at this
                    -- exact point, same reasoning as the width_limit line-break check just below) -
                    -- an ESTIMATE of how much room this formula will actually have once pass 2 gets
                    -- to it, so measure()'s own wrap-aware height (content_extent()'s own comment)
                    -- already reserves enough line height in THIS pass, not one frame late.
                    -- 2 * margin, not one: pass 2 reserves a margin on EACH side of the box, and
                    -- its final advance adds the trailing one - so a formula allowed the full
                    -- width_limit - lx - margin ends up occupying width_limit + margin once that
                    -- advance lands. See pass 2's own wrap_edge comment for why that mattered.
                    local box = mformula.measure(item.formula, fontset, sz, wrap_width)
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
                    local eff_sz = math.max(1, math.min(MAX_SIZE_INDEX, sz + (item.size_off or 0)))
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
    -- Widest any line's own content actually reaches, relative to pos.x - width_limit only
    -- controls WHERE plain text wraps; a single formula wider than width_limit can't be split, so
    -- it renders at its own real width regardless and can end up past width_limit anyway (e.g.
    -- right after a Ctrl+MouseWheel zoom-in - reported live, "zooming makes it exit
    -- the box"). content.lua's own box border only grows to fit content_h automatically, never
    -- width, so it needs this to know how wide it actually has to be too - see this function's own
    -- return value/content.lua's own box-sizing comment.
    local max_x = pos.x
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
        --[[ The line break happens HERE, before positions/cursor_screen_pos are recorded below,
        so both agree with where the item actually lands. A formula follows the same rule as a
        glyph - no usable room left, start a new line - which pass 1 above applies identically. ]]
        if item and not item.newline then
            if item.formula then
                if (formula_line_fit(m, width_limit, x - pos.x)) then
                    newline()
                end
            else
                eff_sz = math.max(1, math.min(MAX_SIZE_INDEX, sz + (item.size_off or 0)))
                item_sz = fontset:char_get_sz({size=eff_sz, code=item.code})
                if width_limit and (x - pos.x) + item_sz.adv > width_limit then
                    newline()
                end
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

                -- ABSOLUTE x (mformula.draw()'s own wrap_edge comment) - the box's own right edge,
                -- not this formula's own content_x, so a formula starting partway through a line
                -- (after preceding plain text) correctly gets LESS room, same as plain glyphs'
                -- own width_limit check just above already gives it. Computed here (not just below,
                -- by mformula.draw()'s own call site) since reachable_graph() now needs it too, to
                -- place its own nodes on whichever wrapped row they actually land on.
                --[[ -margin: the right edge a formula's CONTENT may reach, which is a margin short
                of the column's own edge, because the advance just below adds a trailing margin on
                top of whatever the content occupies. Without that subtraction a wrapped formula
                filled the column exactly and then advanced one margin PAST it, so max_x came back
                as width_limit + margin - i.e. asking for a wider box than it was just given, every
                single time. content.lua then granted it, and the whole thing repeated: a width
                demand that grew by one margin per round and only ever stopped at the max-width cap.
                That is the "converging in steps" resize reported live - it was never
                converging at all, just creeping until it hit the cap. With this, a wrapped formula
                plus BOTH its margins fits inside width_limit, so the width is a real fixed point
                and content.lua's own measure loop settles on the first round. ]]
                -- content_x + the column formula_line_fit() grants, so [content_x, wrap_edge]
                -- is never degenerate - see MIN_FORMULA_COLUMN_LINES for what a zero one does.
                -- Identical to pos.x + width_limit - FORMULA_MARGIN whenever there is real room.
                local _, formula_column = formula_line_fit(m, width_limit, x - pos.x)
                local wrap_edge = formula_column and (content_x + formula_column)

                -- Debug: a graph of every position ANY navigation key can reach - Left/Right
                -- within a row, Up/Down into a node's sup/sub - so navigation fixes can be
                -- checked by eye, not just the left-right chain. Drawn through the text itself
                -- (mformula.reachable_graph() places each node exactly where that position's own
                -- blinker would sit, sup/sub included), not below the box - it needs to cross the
                -- glyphs' own bounding boxes to read as "these are the gaps between them", not as
                -- a separate strip underneath. Drawn BEFORE the formula itself so the glyphs (and
                -- the real blinker, also drawn by mformula.draw below) layer on top of the track,
                -- not the other way around. Active formula only - it'd just be clutter for the
                -- others. show_graph (content.lua's own graph-toggle button, same
                -- pattern as show_wireframe) gates this specifically - ported live from the old
                -- (row-based) mformula.lua, off by default so it doesn't clutter ordinary editing.
                --[[ The cursor highlight, FIRST - before the graph, which is itself before the
                formula, so this ends up beneath everything: graph, vert contours, glyphs, blinker
                ("under walk graph and under the mexpr drawing and under the blinker and anything
                else"). Draw order is the only thing that makes that true, which is why this sits
                here rather than inside mformula.draw() - anything drawn in there is already on top
                of the graph.

                Active formula only: a soft pulse under every box's cursor at once would read as
                clutter, and only one of them is where you are actually typing. mformula.cursor_box()
                returns the rect relative to the same {content_x, y} origin the formula is drawn at,
                with wrapping and baseline correction already applied. ]]
                local markers = nil
                if is_active_formula then
                    -- A list, outermost/faintest first - drawn in order, the overlap is what
                    -- feathers the edge (cursor_box()'s own comment; ImGui has no blur).
                    for _, hl in ipairs(mformula.cursor_box(item.formula, fontset, sz,
                            wrap_edge and (wrap_edge - content_x))) do
                        vc.ImGui_AddRectFilled({x = content_x + hl.x, y = y + hl.y},
                                {x = content_x + hl.x + hl.w, y = y + hl.y + hl.h},
                                hl.color, hl.rounding)
                    end
                    if show_graph then
                        -- RELATIVE width, not the absolute wrap_edge: the graph is built in the
                        -- formula's own root-relative frame (its nodes are added to content_x/y
                        -- below), so it needs the usable column, not a screen coordinate - see
                        -- reachable_graph()'s own comment on the two frames.
                        local graph = mformula.reachable_graph(item.formula, fontset, sz,
                                wrap_edge and (wrap_edge - content_x))
                        --[[ Only an edge whose two ends really wrapped onto DIFFERENT rows gets
                        split - a stub off the right edge of the earlier row, another entering at
                        the left edge of the later one, the way a text selection spanning a line
                        break reads. Everything else is the plain straight line it always was.

                        The test is the nodes' own wrap ROW (reachable_graph() carries it, from the
                        same wrap_point() call that placed them), NOT their y. Keying off y instead
                        was flatly wrong: a superscript sits at a different y from its own base on
                        the SAME row, so every base<->sup edge - each "2", both integral limits -
                        was treated as a row crossing and shot a stub out to the column edge.
                        Reported live: "lines that wouldn't normaly intersect the edge now
                        pass through to the edge".

                        The column is [content_x, wrap_edge] - the same startx/edge the C++ wrap loop
                        uses, since mformula.draw() is handed exactly this content_x as its origin.
                        Without wrapping every node has row 0 and only the straight branch runs. ]]
                        local col_l = content_x
                        local col_r = wrap_edge or (content_x + max_x)
                        for _, e in ipairs(graph.edges) do
                            local na, nb = graph.nodes[e.a], graph.nodes[e.b]
                            -- Earlier ROW first, so the stubs read in reading order.
                            local a, b = na, nb
                            if (b.row or 0) < (a.row or 0) then a, b = b, a end
                            if (a.row or 0) == (b.row or 0) then
                                vc.ImGui_AddLine({x = content_x + a.x, y = y + a.y},
                                        {x = content_x + b.x, y = y + b.y}, CURSOR_TRACK_COLOR, 2)
                            else
                                -- Two ends of one connection, each clamped to its own row.
                                -- Intermediate rows are deliberately not filled: these edges only
                                -- ever join positions adjacent in reading order, at most one row
                                -- apart.
                                vc.ImGui_AddLine({x = content_x + a.x, y = y + a.y},
                                        {x = col_r, y = y + a.y}, CURSOR_TRACK_COLOR, 2)
                                vc.ImGui_AddLine({x = col_l, y = y + b.y},
                                        {x = content_x + b.x, y = y + b.y}, CURSOR_TRACK_COLOR, 2)
                            end
                        end
                        for _, n in ipairs(graph.nodes) do
                            vc.ImGui_AddCircleFilled({x = content_x + n.x, y = y + n.y}, 4, CURSOR_TRACK_COLOR)
                        end
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

                local box = mformula.draw(item.formula, fontset, {x=content_x, y=y}, sz,
                        is_active_formula, show_wireframe, wrap_edge)
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
                    wrap_edge = wrap_edge, -- ABSOLUTE - handle_input()'s own click routing turns
                                           -- this into hit_test()'s RELATIVE wrap_width itself
                                           -- (draw_x, cached right above, is what it's relative to)
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
        max_x = math.max(max_x, x)
    end

    state.last_positions = positions
    state.last_formula_boxes = formula_boxes
    state.last_line_height = m.line_height

    -- Restart the blink cycle whenever the caret moves (or the buffer changes under it) so it is ON
    -- immediately and you can see where it landed, rather than possibly arriving mid-dark-phase.
    -- Same reasoning, and the same one-place-catches-every-path approach, as mformula_new.draw()'s
    -- own blink reset - see its comment.
    local blink_key = state.cursor_pos .. "/" .. #state.chars
    if state.blink_key ~= blink_key then
        state.blink_key = blink_key
        state.frame = 0
    end
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

    return (line_top - pos.y) + m.line_height + (line_extra_bottom[line_idx] or 0), max_x - pos.x
end

--[[ Profiler instrumentation - same bottom-of-file placement as mexpru.lua/mformula_new.lua.
editor.draw()/handle_input() are the per-BOX phases sitting between content.lua's per-frame totals
and mformula_new's per-formula ones, which is what makes "cost grows with the number of boxes"
distinguishable from "cost grows with what is in one box". rescale_all() is per zoom step and
rebuilds every formula in the document, so it is a prime suspect for a one-frame spike. ]]
local prof_ = require("prof")
editor.draw         = prof_.wrap("lua.editor.draw", editor.draw)
editor.handle_input = prof_.wrap("lua.editor.handle_input", editor.handle_input)
if editor.rescale_all then
    editor.rescale_all = prof_.wrap("lua.editor.rescale_all", editor.rescale_all)
end

return editor

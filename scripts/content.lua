--[[
content.lua - the box-management shell around editor.lua, a Lua port of old/content.h's
cbox_t/content_draw system: independent text boxes stacked vertically, connected to a left rail
of nodes, with click-to-activate (only the active box receives keyboard input) and click-in-the-
margin to add a new box. Each box currently holds one editor.lua buffer - old's cbox_i was a
generic interface (comment/formula/definition boxes); this only implements the one box kind that
exists so far, but content.add_box is the seam where other kinds would plug in later.
]]

local vc = require("virt_composer")
local editor = require("editor")
local char = require("char")

local content = {}

local RAIL_OFFSET = 40   -- rail x, relative to pos.x
local BOX_LEFT    = 80   -- box left edge, relative to pos.x
local BOX_GAP     = 24   -- vertical gap between boxes
local BOX_PADDING = 12
local BOX_WIDTH   = 760
local NODE_RADIUS = 6
local FONT_SZ      = 10
local CLOSE_SIZE  = 16   -- close ("x") button, sits just above each box's top-right corner
local RAIL_CLICK_RADIUS = 16 -- how close to the rail line counts as "clicking the rail"

local RAIL_COLOR         = 0xff777777
local BOX_BORDER_COLOR   = 0xff777777
local BOX_ACTIVE_COLOR   = 0xffffffff
local BOX_FILL_COLOR     = 0x33ffffff
local CLOSE_COLOR        = 0xffaaaaaa
local HOVER_COLOR        = 0xff66ff66

local SCROLL_SPEED = 44 -- pixels per wheel notch

-- #################################################################################################
-- Model
-- #################################################################################################

--[[ The empty shell shared by content.new() (which adds one empty box on top of this) and
content.deserialize() (which populates `boxes` itself instead) - kept in one place so the two
can't drift apart on what a freshly-built state actually looks like. ]]
local function new_shell()
    return {
        boxes = {},
        active_index = nil,
        last_layout = nil,    -- filled by draw(), read by handle_input() next frame
        last_rail_x = nil,
        show_help = false,     -- F1 toggles a full-screen keybinding panel in place of the boxes
        show_alt_help = false, -- F2 toggles the Alt+letter/Alt+Shift+letter glyph reference
        scroll_y = 0,          -- how far the whole stack is scrolled up (0 = pinned to the top)
        last_total_height = 0, -- filled by draw(), used to clamp scroll_y in handle_input()
    }
end

function content.new()
    local state = new_shell()
    content.add_box(state)
    state.active_index = 1
    return state
end

--[[ Inserts a new (empty) box at `index` (1..#boxes+1), fixing up active_index if it was at or
after the insertion point, and returns `index`. The seam for adding other box kinds later: right
now every box is just {editor = editor.new()}. ]]
function content.insert_box(state, index)
    table.insert(state.boxes, index, {editor = editor.new()})
    if state.active_index and state.active_index >= index then
        state.active_index = state.active_index + 1
    end
    return index
end

--[[ Appends a new (empty) box at the end and returns its index. ]]
function content.add_box(state)
    return content.insert_box(state, #state.boxes + 1)
end

--[[ Removes box i, fixing up active_index to still point at the same logical box (or nil, if the
removed box was the active one). ]]
function content.remove_box(state, i)
    table.remove(state.boxes, i)
    if state.active_index == i then
        state.active_index = nil
    elseif state.active_index and state.active_index > i then
        state.active_index = state.active_index - 1
    end
    -- Indices shifted - drop the stale layout so a same-frame click can't mis-hit-test against
    -- last frame's positions; draw() rebuilds it before the next handle_input() runs anyway.
    state.last_layout = nil
end

--[[ Every box's full text (editor.to_text() - the same $$LaTeX$$-for-formulas format Ctrl+C
already produces, so a save is exactly "select all, copy" done to every box in turn), one after
another. Each box is length-prefixed ("<byte length>\n<that many bytes>") rather than separated by
some delimiter line, since a box's own text can itself legitimately contain any character
including newlines - there's no delimiter string that's actually guaranteed not to collide with
real content, so this sidesteps that question entirely instead of picking one and hoping. ]]
function content.serialize(state)
    local parts = {}
    for _, box in ipairs(state.boxes) do
        local text = editor.to_text(box.editor)
        parts[#parts + 1] = tostring(#text) .. "\n" .. text
    end
    return table.concat(parts)
end

--[[ Inverse of serialize(): parses the length-prefixed box list back into a fresh state (same
shell new() itself builds - see new_shell()). Silently stops at the first malformed length prefix
(a corrupt/truncated/foreign file) rather than erroring, same leniency insert_text() itself already
has for content it can't make sense of - whatever boxes parsed cleanly before that point are kept
rather than losing everything. Always ends up with at least one box, even from an empty/unreadable
string, so the caller never has to special-case "the file had nothing usable in it". ]]
function content.deserialize(text)
    local state = new_shell()
    local pos = 1
    while pos <= #text do
        local nl = text:find("\n", pos, true)
        local len = nl and tonumber(text:sub(pos, nl - 1))
        if not len then
            break
        end
        local box_text = text:sub(nl + 1, nl + len)
        local ed = editor.new()
        editor.from_text(ed, box_text)
        table.insert(state.boxes, {editor = ed})
        pos = nl + 1 + len
    end
    if #state.boxes == 0 then
        content.add_box(state)
    end
    state.active_index = 1
    return state
end

local function point_in_rect(px, py, x, y, w, h)
    return px >= x and px <= x + w and py >= y and py <= y + h
end

--[[ Where a new box clicked-in at screen y `click_y` should land: after every existing box whose
vertical midpoint is above the click, i.e. "insert nearest the gap you clicked" - so clicking
between two boxes inserts between them, above the first inserts at the top, below the last
appends. ]]
local function insertion_index_for_y(state, click_y)
    local idx = 1
    for i, r in ipairs(state.last_layout) do
        if click_y > r.y + r.h / 2 then
            idx = i + 1
        else
            break
        end
    end
    return idx
end

--[[ Scrolls (if needed) so box `index`'s own TOP edge is visible - used when Ctrl+Up/Down
switches the active box to one that might currently be scrolled out of view, so "switching"
doesn't leave you looking at a box you can't actually see. Reads LAST frame's own layout (like the
mouse-wheel handling below already does) - a frame of lag on box positions is imperceptible here
too. A silent no-op before the very first draw() has ever run (last_layout still nil). ]]
local function scroll_into_view(state, pos, index)
    local r = state.last_layout and state.last_layout[index]
    if not r then
        return
    end
    local display_size = vc.ImGui_GetDisplaySize()
    local viewport_top = pos.y
    local viewport_bottom = display_size and display_size.y or (pos.y + 700)
    if r.y < viewport_top then
        state.scroll_y = state.scroll_y - (viewport_top - r.y)
    elseif r.y > viewport_bottom - 60 then
        -- Not "the whole box" (it may be taller than the viewport) - just enough of its top
        -- that switching here visibly did something, rather than requiring a full box height.
        state.scroll_y = state.scroll_y + (r.y - (viewport_bottom - 60))
    end
    local max_scroll = math.max(0, state.last_total_height - (viewport_bottom - viewport_top))
    state.scroll_y = math.max(0, math.min(max_scroll, state.scroll_y))
end

--[[ A cheap 3-part identity for "where the caret is right now" in editor_state - the plain outer
cursor_pos (in the 3rd slot, with the first two nil), or (while a formula owns input) that
formula's own identity + its internal row/pos - comparing this frame's 3 values against last
frame's (see the cursor-follow block in handle_input, which stores them in the editor's own
"_"-prefixed fields, the same convention editor.lua's undo snapshots already use for a derived/
transient field that isn't part of the model) is how that block tells "the caret actually moved"
apart from "nothing changed, some OTHER frame just ran" without a real equality check on the whole
editor state. ]]
local function cursor_sig(editor_state)
    local f = editor_state.active_formula
    if f then
        return f, f.cursor and f.cursor.row, f.cursor and f.cursor.pos
    end
    return nil, nil, editor_state.cursor_pos
end

-- #################################################################################################
-- Input handling
-- #################################################################################################

--[[ Pass 1 (mirrors old/content.h's content_draw Pass1): a click on a box's close button removes
it; a click inside a box activates it (and only it); a click on/near the rail line inserts a new
box right there - ordering included, so clicking between two boxes' connector nodes inserts
between them - and activates it. Pass 2: keyboard/mouse for this frame is forwarded only to the
active box's editor - inactive boxes see no input, so they can't be typed into by accident.

A click that *activates* a previously-inactive box is consumed here and not forwarded to that
box's editor this frame - each box remembers its own cursor/selection from when it was last
active, and the click that brings focus back to it shouldn't also yank the cursor to wherever was
clicked. Only once a box is already active does clicking inside it move the cursor there.

`fontset` is only threaded through for editor.handle_input()'s benefit (hit-testing a click
against an active formula's own geometry - see its own comment). `pos` is the same draw origin
draw() itself takes - needed here only to size/clamp the scroll range against the current viewport
(see the mouse-wheel handling below). ]]
function content.handle_input(state, fontset, pos)
    -- F1/F2 each toggle their own full-screen panel on/off; while either is showing, every other
    -- input this frame is swallowed here (nothing forwarded to any box) so it can't be typed into
    -- or clicked through from behind the panel. Opening one closes the other, rather than letting
    -- them stack - only one overlay makes sense on screen at a time.
    if vc.ImGui_IsKeyPressed("ImGuiKey_F1", false) then
        state.show_help = not state.show_help
        state.show_alt_help = false
        return
    end
    if vc.ImGui_IsKeyPressed("ImGuiKey_F2", false) then
        state.show_alt_help = not state.show_alt_help
        state.show_help = false
        return
    end
    if state.show_help or state.show_alt_help then
        return
    end

    -- Ctrl+Up/Down switches which box is active (previous/next in the stack, stopping at either
    -- end rather than wrapping) - each box already remembers its own cursor/selection from when
    -- it was last active (same as clicking a different box does), so switching this way doesn't
    -- need to touch either box's own editor state at all, just scroll the newly-active one into
    -- view if it wasn't already. Checked here, ahead of any box-specific handling (including
    -- whether a formula inside the active box currently owns input), so it's always available as
    -- a global shortcut, not something a formula's own plain Up/Down could ever shadow.
    local ctrl_down = vc.ImGui_IsKeyDown("ImGuiKey_LeftCtrl") or vc.ImGui_IsKeyDown("ImGuiKey_RightCtrl")
    if ctrl_down and vc.ImGui_IsKeyPressed("ImGuiKey_UpArrow", false) then
        if state.active_index and state.active_index > 1 then
            state.active_index = state.active_index - 1
            scroll_into_view(state, pos, state.active_index)
        end
        return
    end
    if ctrl_down and vc.ImGui_IsKeyPressed("ImGuiKey_DownArrow", false) then
        if state.active_index and state.active_index < #state.boxes then
            state.active_index = state.active_index + 1
            scroll_into_view(state, pos, state.active_index)
        end
        return
    end

    -- Ctrl+N: a new empty box right after the current one (or at the end, if none is active),
    -- activated straight away - the keyboard equivalent of clicking the rail just below it.
    if ctrl_down and vc.ImGui_IsKeyPressed("ImGuiKey_N", false) then
        local index = (state.active_index or #state.boxes) + 1
        state.active_index = content.insert_box(state, index)
        return
    end

    -- Mouse wheel scrolls the whole stack. Clamped against LAST frame's own total height (this
    -- frame's real one isn't known until draw() runs) and the CURRENT viewport - a frame of lag
    -- on the clamp bound itself is imperceptible, and self-corrects continuously every frame
    -- scrolling actually happens, so it never drifts. Positive wheel (away from the user) is the
    -- usual "scroll up" gesture - it should reveal content ABOVE, i.e. decrease scroll_y.
    local wheel = vc.ImGui_GetMouseWheel()
    if wheel ~= 0 then
        local viewport_h = math.max(0, vc.ImGui_GetDisplaySize().y - pos.y)
        local max_scroll = math.max(0, state.last_total_height - viewport_h)
        state.scroll_y = math.max(0, math.min(max_scroll, state.scroll_y - wheel * SCROLL_SPEED))
    end

    local clicked = vc.ImGui_IsMouseClicked("ImGuiMouseButton_Left", false)
    local activating = false
    if clicked and state.last_layout then
        local mpos = vc.ImGui_GetMousePos()

        for i, r in ipairs(state.last_layout) do
            if r.close and point_in_rect(mpos.x, mpos.y, r.close.x, r.close.y, r.close.w, r.close.h) then
                content.remove_box(state, i)
                return
            end
        end

        local hit = nil
        for i, r in ipairs(state.last_layout) do
            if point_in_rect(mpos.x, mpos.y, r.x, r.y, r.w, r.h) then
                hit = i
                break
            end
        end
        if hit then
            activating = state.active_index ~= hit
            state.active_index = hit
        elseif state.last_rail_x and math.abs(mpos.x - state.last_rail_x) <= RAIL_CLICK_RADIUS then
            state.active_index = content.insert_box(state, insertion_index_for_y(state, mpos.y))
            activating = true -- a fresh box has nothing to place a cursor from anyway
        else
            state.active_index = nil
        end
    end

    local active = state.active_index and state.boxes[state.active_index]
    if active and not activating then
        editor.handle_input(active.editor, fontset, FONT_SZ)
    end

    -- Whenever the active box's own caret actually MOVED this frame - typing/Enter growing the
    -- box, arrow-key movement, or a formula's internal cursor stepping through it - and its new
    -- position sits outside the viewport, scroll just enough to bring it back in. Gated on an
    -- actual move (via cursor_sig() below), not run unconditionally every frame: otherwise this
    -- would fight a deliberate manual scroll-away (mouse wheel, or just leaving a box active while
    -- looking at another one further down) every single frame even though the caret itself never
    -- moved - only a real move should ever pull the view back to it.
    if active and active.editor.last_cursor_y then
        local a, b, c = cursor_sig(active.editor)
        local ed = active.editor
        local had_prior = ed._cursor_sig_c ~= nil
        local moved = had_prior and (a ~= ed._cursor_sig_a or b ~= ed._cursor_sig_b or c ~= ed._cursor_sig_c)
        ed._cursor_sig_a, ed._cursor_sig_b, ed._cursor_sig_c = a, b, c
        if moved then
            local display_size = vc.ImGui_GetDisplaySize()
            local viewport_top = pos.y
            local viewport_bottom = display_size and display_size.y or (pos.y + 700)
            local cy, ch = active.editor.last_cursor_y, active.editor.last_cursor_h or 0
            if cy < viewport_top then
                state.scroll_y = state.scroll_y - (viewport_top - cy)
            elseif cy + ch > viewport_bottom then
                state.scroll_y = state.scroll_y + (cy + ch - viewport_bottom)
            end
            local max_scroll = math.max(0, state.last_total_height - (viewport_bottom - viewport_top))
            state.scroll_y = math.max(0, math.min(max_scroll, state.scroll_y))
        end
    end
end

-- #################################################################################################
-- Layout / render
-- #################################################################################################

-- F1's keybinding panel - kept as plain lines (a blank one is a section gap) rather than a table
-- of {key, description} pairs since a couple of entries (the formula-mode block) read better as
-- an indented sub-list than as a strict two-column layout.
local HELP_LINES = {
    "Math Writer - Controls  (F1 to close)",
    "",
    "General",
    "  F1                       Toggle this panel",
    "  Click inside a box       Activate it / place the cursor",
    "  Click the left rail      Insert a new box there",
    "  Click a box's x          Close that box",
    "  Ctrl+Up / Ctrl+Down       Switch to the previous / next box",
    "  Ctrl+N                   New box right after the current one",
    "",
    "Plain text",
    "  Type                     Insert a character",
    "  Alt+letter                Greek lowercase (a=alpha, b=beta, g=gamma, d=delta, ...)",
    "  Alt+Shift+letter           Greek uppercase where it exists / Alt+Shift+Q = integral",
    "  Space / Enter             Space / newline",
    "  Backspace / Delete         Delete before / after the cursor",
    "  Left / Right               Move (Ctrl+Left/Right = word skip, or enter a formula)",
    "  Up / Down                 Move by line",
    "  Home / End                 Start / end of line",
    "",
    "Formula embeds",
    "  Ctrl+M                   Insert a formula here and enter it",
    "  Ctrl+Shift+-              Wrap the character before the cursor into a subscript",
    "  Ctrl+Shift+=              Wrap the character before the cursor into a superscript",
    "  Ctrl+/                   Insert an empty fraction here and enter its numerator",
    "  Click a formula            Enter it",
    "  Inside a formula:",
    "    Type / Alt+letter          Same as plain text, inside the formula",
    "    Left / Right                Walk through it, including sup/sub bases",
    "    Up / Down                  Jump into/between superscript & subscript, or numerator & denominator",
    "    Ctrl+/                     Insert an empty fraction at the cursor",
    "    Ctrl+Left/Right, Escape,     Exit the formula",
    "      or click outside",
    "    Click inside                Place the cursor there",
    "",
    "Clipboard & undo",
    "  Ctrl+A                   Select all",
    "  Ctrl+C / Ctrl+X            Copy / cut (a formula becomes $$LaTeX$$)",
    "  Ctrl+V                   Paste ($$...$$ spans become formulas)",
    "  Ctrl+Z / Ctrl+Shift+Z      Undo / redo",
}

local HELP_LINE_HEIGHT = 17
local HELP_BG_COLOR = 0xee1a1a1a
local HELP_TEXT_COLOR = 0xffe0e0e0

local function draw_help()
    local size = vc.ImGui_GetDisplaySize()
    vc.ImGui_AddRectFilled({x=0, y=0}, {x=size.x, y=size.y}, HELP_BG_COLOR, 0)
    for i, line in ipairs(HELP_LINES) do
        vc.ImGui_AddText({x=40, y=16 + (i - 1) * HELP_LINE_HEIGHT}, HELP_TEXT_COLOR, line)
    end
end

-- a, b, c, ..., z - built once rather than typed out as a literal list, so this can't itself get
-- out of sync with the alphabet.
local ALT_LETTERS = {}
for c = string.byte("a"), string.byte("z") do
    ALT_LETTERS[#ALT_LETTERS + 1] = string.char(c)
end

local ALT_GLYPH_SZ = 10 -- twice the size of the 18pt this used to be (index 13) - same size real
                         -- formula content itself renders at (matches FONT_SZ)

--[[ Real line-height/baseline metrics at font size `sz`, same G/g-measuring trick editor.lua's
own get_metrics() uses (see that file's comment) - char_draw()'s `pos` is a BASELINE, not a
top-left corner the way ImGui_AddText()'s is, so a row whose visual top is `row_top` needs its
char_draw calls at `row_top - baseline_shift` to land in the same place a same-y AddText call
would. This is what was actually missing before: mixing an untranslated `y` between the two
conventions is why the symbol and its name/row landed at different heights. ]]
local function glyph_metrics(fontset, sz)
    local G, g = char.find_by_ascii("G"), char.find_by_ascii("g")
    local G_sz = fontset:char_get_sz({size=sz, code=G.ncod})
    local g_sz = fontset:char_get_sz({size=sz, code=g.ncod})
    return {line_height = g_sz.bl.y - G_sz.tr.y, baseline_shift = G_sz.tr.y}
end

--[[ Draws `text` (ASCII only - macro names like "\alpha" and the "(plain)" fallback) one glyph at
a time via char_draw(), at the SAME size/baseline the math symbol next to it uses - rather than
ImGui_AddText()'s fixed-size UI font, which is a different size AND a different (top-left, not
baseline) convention, so pairing the two directly is exactly what left the name and its symbol
misaligned. Returns the x just past the last glyph drawn. ]]
local function draw_label(fontset, sz, x, baseline_y, text, color)
    local cx = x
    for i = 1, #text do
        local entry = char.find_by_ascii(text:sub(i, i))
        if entry then
            fontset:char_draw({size=sz, code=entry.ncod}, {x=cx, y=baseline_y}, color, false, 0)
            cx = cx + fontset:char_get_sz({size=sz, code=entry.ncod}).adv
        end
    end
    return cx
end

--[[ F2's panel: what Alt+letter and Alt+Shift+letter actually produce, letter by letter - reads
straight from char.greek_alt/greek_alt_shift (the same tables editor.lua/mformula.lua's own Alt
handling looks up), with the SAME fallback rule they use for a letter that has no entry there
(plain lowercase for Alt, plain uppercase for Alt+Shift) - so this can never drift from what the
keys actually do, only from char.lua's own tables changing (which is exactly what should update
it). Draws the real glyph (not just its "\name") since "what does this key actually produce" is
the question a legend like this exists to answer. ]]
local function draw_alt_help(fontset)
    local size = vc.ImGui_GetDisplaySize()
    vc.ImGui_AddRectFilled({x=0, y=0}, {x=size.x, y=size.y}, HELP_BG_COLOR, 0)
    vc.ImGui_AddText({x=40, y=16}, HELP_TEXT_COLOR,
            "Math Writer - Alt+letter / Alt+Shift+letter  (F2 to close)")

    local gm = glyph_metrics(fontset, ALT_GLYPH_SZ)
    local row_h = gm.line_height + 10

    local col_key, col_glyph, col_name = 40, 90, 160
    local col_key2, col_glyph2, col_name2 = 660, 710, 780
    local row0_top = 56

    vc.ImGui_AddText({x=col_key, y=row0_top - 20}, HELP_TEXT_COLOR, "Alt+")
    vc.ImGui_AddText({x=col_key2, y=row0_top - 20}, HELP_TEXT_COLOR, "Alt+Shift+")

    for i, letter in ipairs(ALT_LETTERS) do
        local row = (i - 1) % 13
        local col = (i - 1) < 13 and 0 or 1
        local row_top = row0_top + row * row_h
        local baseline = row_top - gm.baseline_shift
        local kx, gx, nx = (col == 0) and col_key or col_key2,
                (col == 0) and col_glyph or col_glyph2,
                (col == 0) and col_name or col_name2

        vc.ImGui_AddText({x=kx, y=row_top}, HELP_TEXT_COLOR, letter)

        local lo_desc = char.greek_alt[letter]
        local lo_entry = (lo_desc and char.find_by_desc(lo_desc)) or char.find_by_ascii(letter)
        if lo_entry then
            fontset:char_draw({size=ALT_GLYPH_SZ, code=lo_entry.ncod}, {x=gx, y=baseline},
                    HELP_TEXT_COLOR, false, 0)
        end
        draw_label(fontset, ALT_GLYPH_SZ, nx, baseline, lo_desc or "(plain)", HELP_TEXT_COLOR)

        local hi_desc = char.greek_alt_shift[letter]
        local hi_entry = (hi_desc and char.find_by_desc(hi_desc)) or char.find_by_ascii(letter:upper())
        if hi_entry then
            fontset:char_draw({size=ALT_GLYPH_SZ, code=hi_entry.ncod}, {x=gx + 260, y=baseline},
                    HELP_TEXT_COLOR, false, 0)
        end
        draw_label(fontset, ALT_GLYPH_SZ, nx + 260, baseline, hi_desc or "(plain)", HELP_TEXT_COLOR)
    end
end

--[[ Draws every box, stacked vertically from `pos`, each connected to a left rail - or, while
state.show_help/show_alt_help is set (F1/F2), that panel instead, covering the whole display so
nothing underneath shows or can be mistaken for still being interactive (handle_input() already
backs that up by swallowing input while either is up). ]]
function content.draw(state, fontset, pos)
    if state.show_help then
        draw_help()
        return
    end
    if state.show_alt_help then
        draw_alt_help(fontset)
        return
    end

    local display_size = vc.ImGui_GetDisplaySize()
    local viewport_top = pos.y
    local viewport_bottom = display_size and display_size.y or (pos.y + 700)

    local layout = {}
    local content_start_y = pos.y - state.scroll_y
    local y = content_start_y
    local rail_x = pos.x + RAIL_OFFSET
    local box_x = pos.x + BOX_LEFT
    local content_w = BOX_WIDTH - 2 * BOX_PADDING

    for i, box in ipairs(state.boxes) do
        local box_y = y
        local is_active = (state.active_index == i)

        local cached = state.last_layout and state.last_layout[i]
        local cached_h = cached and cached.h
        -- A box entirely outside the viewport, that also isn't the active one (so its content
        -- can't be changing without a click that requires it to be visible first), doesn't need
        -- re-measuring/re-drawing this frame - the glyph work in editor.draw() is the expensive
        -- part this is meant to skip, not the bookkeeping of a cached height. That cached height
        -- is trusted as-is while culled (nothing else could have changed it), so the boxes
        -- stacked below don't jump around the moment this one re-enters view and gets its first
        -- fresh measurement again.
        local out_of_view = cached_h
                and (box_y + cached_h < viewport_top or box_y > viewport_bottom)

        if is_active or not out_of_view then
            local content_h = editor.draw(box.editor, fontset,
                    {x=box_x + BOX_PADDING, y=box_y + BOX_PADDING}, FONT_SZ, content_w, is_active)
            local box_h = math.max((content_h or 0) + 2 * BOX_PADDING, 50)

            -- Fill/border drawn after the text (translucent, same trick as the selection
            -- highlight - stays legible on top) so this frame's actual content height is used,
            -- not last frame's.
            vc.ImGui_AddRectFilled({x=box_x, y=box_y}, {x=box_x + BOX_WIDTH, y=box_y + box_h},
                    BOX_FILL_COLOR, 6)
            vc.ImGui_AddRect({x=box_x, y=box_y}, {x=box_x + BOX_WIDTH, y=box_y + box_h},
                    is_active and BOX_ACTIVE_COLOR or BOX_BORDER_COLOR, 6, is_active and 2 or 1)

            -- Connector: a node on the rail, and a line from it to the box.
            local node_y = box_y + 20
            vc.ImGui_AddCircle({x=rail_x, y=node_y}, NODE_RADIUS, RAIL_COLOR, 1)
            vc.ImGui_AddLine({x=rail_x, y=node_y}, {x=box_x, y=node_y}, RAIL_COLOR, 1)

            -- Close button: a small "x" sitting just above the box's top-right corner.
            local close = {x=box_x + BOX_WIDTH - CLOSE_SIZE, y=box_y - CLOSE_SIZE - 2,
                    w=CLOSE_SIZE, h=CLOSE_SIZE}
            vc.ImGui_AddRect({x=close.x, y=close.y}, {x=close.x+close.w, y=close.y+close.h},
                    RAIL_COLOR, 3, 1)
            local pad = 4
            vc.ImGui_AddLine({x=close.x+pad, y=close.y+pad},
                    {x=close.x+close.w-pad, y=close.y+close.h-pad}, CLOSE_COLOR, 2)
            vc.ImGui_AddLine({x=close.x+close.w-pad, y=close.y+pad},
                    {x=close.x+pad, y=close.y+close.h-pad}, CLOSE_COLOR, 2)

            layout[i] = {x=box_x, y=box_y, w=BOX_WIDTH, h=box_h, close=close}
            y = box_y + box_h + BOX_GAP
        else
            -- Culled: nothing drawn this frame - just carry its own last-known height forward so
            -- everything stacked below it still lands in the right place.
            layout[i] = {x=box_x, y=box_y, w=BOX_WIDTH, h=cached_h, close=nil}
            y = box_y + cached_h + BOX_GAP
        end
    end

    local rail_bottom = math.max(y, viewport_bottom)
    vc.ImGui_AddLine({x=rail_x, y=0}, {x=rail_x, y=rail_bottom}, RAIL_COLOR, 1)

    -- Hover preview: while the mouse sits in the "click to insert a box" zone (mirrors old/
    -- content.h's own hover affordance there), mark exactly where a click would land - a circle
    -- on the rail with a small cross through it, at the mouse's own y.
    local mpos = vc.ImGui_GetMousePos()
    if mpos and math.abs(mpos.x - rail_x) <= RAIL_CLICK_RADIUS then
        vc.ImGui_AddCircle({x=rail_x, y=mpos.y}, NODE_RADIUS + 3, HOVER_COLOR, 2)
        local arm = 7
        vc.ImGui_AddLine({x=rail_x-arm, y=mpos.y}, {x=rail_x+arm, y=mpos.y}, HOVER_COLOR, 2)
        vc.ImGui_AddLine({x=rail_x, y=mpos.y-arm}, {x=rail_x, y=mpos.y+arm}, HOVER_COLOR, 2)
    end

    state.last_layout = layout
    state.last_rail_x = rail_x
    state.last_total_height = y - content_start_y
end

return content

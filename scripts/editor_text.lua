--[[ ==================================== WHAT THIS FILE OFFERS ====================================
new()                                   -> state_text
to_text(state_text: editor_text.state_text) / from_text(state_text: editor_text.state_text,
        text: string, fontset: fontset)
rescale(state_text: editor_text.state_text, fontset: fontset) -> nothing
    A text box: a flat stream of characters with FORMULAS EMBEDDED in
    it. The stream is this file's half; each embed is an mformula
    container driven through editor.lua.

THE FRAME
draw(state_text: editor_text.state_text, fontset: fontset, pos: {x,y}, sz: size,
     width_limit: number, show_cursor: boolean, show_wireframe: boolean, show_graph: boolean)
     -> height
handle_input(state_text: editor_text.state_text, fontset: fontset, sz: size) -> changed
nearest_position(state_text: editor_text.state_text, mpos: {x,y}) -> index
formula_at(state_text: editor_text.state_text, pos: {x,y}, only: node|nil) -> {container, hb} | nil
    `only` restricts the search to ONE formula - "did this click land
    inside the formula that currently has input", as against "which
    formula is here". Both questions are asked in this file.

ENTERING AND LEAVING A FORMULA
begin_formula_edit(state_text: editor_text.state_text) -> nothing
commit_formula_edit(state_text: editor_text.state_text, cursor_path: path) -> nothing
    A formula edit is ONE undo step, not one per keystroke: begin
    takes a baseline, commit turns it into a step if the tree moved.

UNDO
push_undo(state_text: editor_text.state_text, coalesce_key: string)
undo(state_text: editor_text.state_text) / redo(state_text: editor_text.state_text)
    The whole char stream is snapshotted, formulas included - which is
    why undo lives here and not in editor.lua, where a definition box
    has no stream to snapshot.

LAYOUT, EXPORTED FOR TESTS ONLY
formula_line_fit(m: metrics, width_limit: number, used: number, run_width: number) -> boolean
run_moves_down(width_limit: number, used: number, run_width: number) -> boolean
measure_runs(state_text: editor_text.state_text, fontset: fontset, sz: size) -> {run}
wrapped_formula_x(width_limit: number, run_width: number) -> number
FORMULA_WRAP_ROWS                       constant
    The passes that call these live inside draw(), which needs a real
    ImGui frame - the same convention mformula_new's make_supsub uses.

--- internal, not on the module table --------------------------------------------------------------
    the char stream, the wrapping passes and the embed layout
@date 2026-09-12 04:10
================================================================================================= ]]

--[[
editor_text.lua - THE FLAT TEXT EDITOR. Renamed from editor.lua 2026-09-06, when `editor.lua`
became the shared half: the formula HOST that both this file and editor_definition.lua need (the
caret/selection highlight, the reachable-position graph, slot markers, click hit-testing). See
editor.lua's own header for what lives there and why.

A flat text/glyph-stream editor, rendered directly through fontset:char_draw: char_get_sz gives
real glyph metrics, so there is no need to route plain text through the mexpr_* composer just to
get working layout. (It began as a port of the C++ comment box the project grew out of, deleted
2026-09-06 along with the rest of old/ - nothing there is followable any more.)

Model: state_text.chars is a flat array of items, each either {code=<ncod>} (a glyph) or
{newline=true} (a hard line break). state_text.cursor_pos is an index 0..#state_text.chars: cursor_pos == N
means the cursor sits immediately before chars[N+1] (or at the very end, if N == #chars).

state_text.selection_anchor, when set, is a second such index - the selection covers chars[lo+1..hi]
where lo/hi are min/max(selection_anchor, cursor_pos). selection_anchor == cursor_pos (or nil)
means no selection.

A chars item can also be {formula=<mformula state_text>} - an embedded structured expression
(mformula_new.lua), inline in the flow like one wide glyph. `formula.new` inserts one at the cursor
and enters it; clicking one enters it (state_text.active_formula). While a formula is active,
        ALL input
goes to it exclusively (`formula.exit`, or a click outside it, leaves), which is what keeps the
arrow keys unambiguous: outside a formula they mean what they always meant (Up/Down = change line),
inside one mformula_new reinterprets them (Up/Down = into the superscript/subscript).

@date 2026-09-08 08:20
]]

local vc = require("virt_composer")
local char = require("char")
local mexpru = require("mexpru")
local mformula = require("mformula_new")
local prof = require("prof")
local editor = require("editor")
local sealed = require("sealed")  -- the shared formula host; see its header
local keymap = require("keymap")
local glyphmap = require("glyphmap")

local editor_text = {}

-- char.lua's own m_font_sizes table length - mexpru's own canonical copy (2026-09-04's Ctrl+
-- MouseWheel zoom levels). Used below to clamp a boosted glyph's (item.size_off) effective size
-- into the valid table range.
local MAX_SIZE_INDEX = mexpru.MAX_SIZE_INDEX

-- #################################################################################################
-- Model
-- #################################################################################################

--[[ THE `state_text` CONTAINER - one text box. Declared through sealed.lua; see that file for the
rule.

SEVEN FIELDS WERE NEVER IN new() when this was written - _fontset, _suppress_chars, _undo_baseline,
blink_key, font_size, formula_dragging, version. They were created on first write elsewhere in the
file and nothing named them anywhere. Declared here, still starting nil.

THE UNDERSCORE PREFIX marks a field this file alone touches; it is not enforced, and it is kept
because those four read as scratch at their call sites, which is what they are.
@date 2026-09-12 06:20 ]]
local STATE_FIELDS = {
    chars              = "the flat character stream; a formula is one entry carrying a container",
    cursor_pos         = "index into `chars`; 0 is before everything",
    selection_anchor   = "the far end of a selection, or nil",
    version            = "bumped by every real edit - what a caller watches to see a change",

    mouse_selecting    = "true while a click-drag selection is in progress",
    mouse_click_origin = "where the drag started, for deciding what it selected",
    formula_dragging   = "the embedded formula a drag is currently inside, or nil",

    last_positions     = "filled by draw(), read by handle_input() next frame",
    last_cursor_y      = "absolute screen y of the caret, for content.lua's scroll-into-view",
    last_cursor_h      = "its height - plain text's, or the active formula's own",
    last_formula_boxes = "the embeds the last draw left behind; every hit test is against these",
    active_formula     = "the embedded formula that currently has input, or nil",

    undo_stack         = "{chars, cursor_pos, selection_anchor}[], oldest first",
    redo_stack         = "what undo popped",
    undo_coalesce_key  = "lets consecutive same-kind edits merge into ONE undo step",
    _undo_baseline     = "the snapshot begin_formula_edit() opened; commit turns it into a step",

    frame              = "this box's own frame counter",
    blink_key          = "what the caret's blink phase is keyed on, so it restarts on a move",
    font_size          = "a char.lua size-table INDEX, not a pixel size",
    _fontset           = "stashed by handle_input for the paths that need one and are not given it",
    _suppress_chars    = "a depth count: while positive, typed characters are swallowed",

    --[[ WRITTEN BY content.lua, NOT BY THIS FILE, which is why they were missed when this list was
    first written from a scan of this file alone: the scroll-into-view logic lives with the document
    because only the document knows where the box is on screen, but the state it keeps per box has
    to live on the box. Found 2026-09-12 by the seal itself, on the author's real document. ]]
    _cursor_sig_a      = "part of the caret's position signature, for spotting that it moved",
    _cursor_sig_b      = "the second part",
    _cursor_sig_c      = "the third; nil until the first frame that has one",
    _scroll_to_caret   = "set when the caret moved, so the next draw scrolls it into view",
}
local STATE_SHAPE = sealed.declare("editor_text", "state_text", STATE_FIELDS)

--[[ THE `item` CONTAINER - one entry in the character stream, and the thing `chars` is a list of.

THREE KINDS, ONE TABLE, and which kind it is shows in which field is set: a glyph carries `code`, a
hard line break carries `newline`, a formula embed carries `formula`. That is why the field list
below reads as an either/or rather than as a record - there is no `kind` field, and adding one would
mean two ways to ask the same question.

IT DOES NOT LEAVE THIS FILE, and that is now true rather than merely mostly true. It used to: the
Ctrl+Shift+=/- path handed a whole item to `mformula_new.new_from_base`, which read `size_off` and
`code` off it - a module the text editor is built ON, knowing the shape of a text item. That module
takes its own `base_glyph` as of 2026-09-12 and this file converts at the call, so the declaration
below is a statement about this file alone.

WHAT EARNS IT A SEAL WITHOUT CROSSING FILES: eleven inline literals wrote it and nothing said what
one could hold, so the field list was whatever the eleven happened to agree on. It is also the spine
of the stream - every glyph, break and embed in a text box is one of these - and it survives a round
trip through `deep_copy` into an undo snapshot and back into the editor, which is a longer life than
most tables here get. `new_item` below is the one creator now, and it uses `check_keys` rather than
the seal alone because the literal arrives fully built - see that function.
@date 2026-09-13 00:10 ]]
local ITEM_FIELDS = {
    code     = "the glyph's ncod (char.lua's catalogue code). A GLYPH item.",
    size_off = "steps of per-glyph size boost, negative = bigger; only on a glyph, usually absent",
    newline  = "true on a HARD LINE BREAK item, which carries nothing else",
    formula  = "the mformula.container of an EMBEDDED formula. A FORMULA item.",
}
local ITEM_SHAPE = sealed.declare("editor_text", "item", ITEM_FIELDS)

--[[ The one creator for a `chars` entry.

Core: every item in the stream is built here, so the declaration above is the whole truth about what
one may hold. It takes the table the caller already writes rather than named arguments, because the
three kinds share no argument list and a creator per kind would be three creators.

Detail: CHECK_KEYS, NOT JUST THE SEAL. The literal arrives fully built, and both metamethods fire
only while a key is absent - so `{cdoe = ncod}` would be sealed with the typo already inside it and
read back as an item with no code. Same split the transform spec needed.

Params: `t` the literal, {code=} or {newline=true} or {formula=}. Returns it, sealed, so the call
can stand inside a table.insert.
@date 2026-09-12 23:10 ]]
local function new_item(t)
    ITEM_SHAPE.check_keys(t, "item")
    return ITEM_SHAPE.wrap(t)
end

--[[ A fresh, empty text box.

Core: the state_text is a FLAT CHARACTER STREAM (`chars`) with a cursor index into it. A formula is one
entry in that stream carrying its own mformula container, which is what lets text and mathematics
share one caret and one undo history.

Detail: several fields are filled in by draw() and read by handle_input() on the NEXT frame -
`last_positions`, `last_cursor_y`, `last_cursor_h`. Every hit test here is therefore against what
was last drawn, which is correct: that is what the user actually clicked on.
@date 2026-09-12 04:15 ]]
function editor_text.new()
    return STATE_SHAPE.wrap{
        chars = {},
        cursor_pos = 0,
        selection_anchor = nil,
        mouse_selecting = false, -- true while a click+drag selection is in progress
        mouse_click_origin = nil, -- position of the click that started the current drag, if any
        last_positions = nil,   -- filled in by draw(), read by handle_input() next frame
        last_cursor_y = nil,    -- filled in by draw(): absolute screen y of the caret right now
        last_cursor_h = nil,    -- (plain text or an active formula's own - see draw()'s comment),
                                 -- read by content.lua to keep it scrolled into view
        last_formula_boxes = nil, -- filled in by draw(): {x,y,w,h,formula=<mformula state_text>}[]
        active_formula = nil,   -- the mformula state_text currently owning input, if any
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
there is no active (non-empty) selection. @date 2026-09-08 08:20 ]]
local function selection_range(state_text)
    local a = state_text.selection_anchor
    if not a or a == state_text.cursor_pos then
        return nil, nil
    end
    if a < state_text.cursor_pos then
        return a, state_text.cursor_pos
    end
    return state_text.cursor_pos, a
end

--[[ Deletes the active selection (if any), moves the cursor to its start, and clears it.
@return true if there was a selection to delete. @date 2026-09-08 08:20 ]]
local function delete_selection(state_text)
    local lo, hi = selection_range(state_text)
    if not lo then
        return false
    end
    for i = hi, lo + 1, -1 do
        table.remove(state_text.chars, i)
    end
    state_text.cursor_pos = lo
    state_text.selection_anchor = nil
    return true
end

--[[ Called at the start of every cursor-moving key handler: with `extend` (Shift held), starts a
selection at the current cursor if one isn't already active; otherwise drops any selection.
@date 2026-09-08 08:20 ]]
local function update_selection_for_move(state_text, extend)
    if extend then
        if not state_text.selection_anchor then
            state_text.selection_anchor = state_text.cursor_pos
        end
    else
        state_text.selection_anchor = nil
    end
end

--[[ Plain-text rendering of chars[lo+1..hi], for the clipboard. Glyphs with no ascii form (e.g.
greek) fall back to their LaTeX-ish desc (e.g. "\alpha "); a formula embed becomes a LaTeX $$...$$
span (mformula.to_latex() - see its own comment for exactly what it covers). A literal "$" or "\"
typed as plain text is backslash-escaped so insert_text() can always tell it apart from a $$ span
or one of ITS escapes on the way back in.
@date 2026-09-08 08:20 ]]
local function selection_to_text(state_text, lo, hi)
    local parts = {}
    for i = lo + 1, hi do
        local item = state_text.chars[i]
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
unmapped - an unrecognized macro included - is skipped, the same leniency plain paste always had.
@date 2026-09-08 08:20 ]]
local function insert_text(state_text, text, fontset)
    local i = 1
    while i <= #text do
        local c = text:sub(i, i)
        if text:sub(i, i + 1) == "$$" then
            -- plain=true: "$$" would otherwise be read as a Lua pattern (end-of-string anchors),
            -- not a literal substring.
            local close = text:find("$$", i + 2, true)
            local inner = text:sub(i + 2, close and (close - 1) or #text)
            -- mexpru.DEFAULT_SIZE, not a live outer size - the same reasoning as the
            -- `formula.new` branch in handle_input (mexpru.DEFAULT_SIZE's own comment).
            local formula = mformula.from_latex(fontset, mexpru.DEFAULT_SIZE, inner)
            table.insert(state_text.chars, state_text.cursor_pos + 1, new_item{formula = formula})
            state_text.cursor_pos = state_text.cursor_pos + 1
            i = close and (close + 2) or (#text + 1)
        elseif c == '\n' then
            table.insert(state_text.chars, state_text.cursor_pos + 1, new_item{newline=true})
            state_text.cursor_pos = state_text.cursor_pos + 1
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
                    table.insert(state_text.chars, state_text.cursor_pos + 1, new_item{code=entry.ncod,
                            size_off=char.size_delta(entry.desc)})
                    state_text.cursor_pos = state_text.cursor_pos + 1
                end
                -- selection_to_text() always emits one trailing space after a macro name -
                -- consume it so round-tripping our own output doesn't leave a stray space behind.
                i = (text:sub(j, j) == " ") and (j + 1) or j
            elseif nc == '$' or nc == '\\' then
                local entry = char.find_by_ascii(nc)
                if entry then
                    table.insert(state_text.chars, state_text.cursor_pos + 1, new_item{code=entry.ncod})
                    state_text.cursor_pos = state_text.cursor_pos + 1
                end
                i = i + 2
            else
                i = i + 1
            end
        else
            local entry = char.find_by_ascii(c)
            if entry then
                table.insert(state_text.chars, state_text.cursor_pos + 1, new_item{code=entry.ncod})
                state_text.cursor_pos = state_text.cursor_pos + 1
            end
            i = i + 1
        end
    end
end

--[[ The whole buffer as text (selection_to_text() over every char) - content.lua's own save
format is exactly this, one per box, so a save is indistinguishable from "select all, copy" and a
load from "select all, delete, paste" (undo history included, since it goes through the same
push_undo() call sites paste already does).
@date 2026-09-08 08:20 ]]
function editor_text.to_text(state_text)
    STATE_SHAPE.check(state_text)
    return selection_to_text(state_text, 0, #state_text.chars)
end

--[[ Replaces the ENTIRE buffer with `text` (insert_text()'s own $$.../escape handling included) -
content.lua's own load, and this file's own undo/redo's restore path (see undo_or_redo()) both
go through wholesale state_text.chars replacement already; this is that same operation exposed for a
fresh (or about to be cleared) editor_text.new() instead of a snapshot table. Does NOT go through
push_undo() itself - loading a save file replaces the state_text a box STARTS with, there's nothing
before it to undo back to.
@date 2026-09-08 08:20 ]]
function editor_text.from_text(state_text, text, fontset)
    STATE_SHAPE.check(state_text)
    state_text.chars = {}
    state_text.cursor_pos = 0
    state_text.selection_anchor = nil
    insert_text(state_text, text, fontset)
end

--[[ Rescales every formula embed in state_text.chars at the CURRENT global zoom (mexpru.set_zoom(), set
by content.lua just before calling this) - content.lua's own Ctrl+MouseWheel handler calls this for
every box any time the zoom actually changes, so already-typed formula content visibly
catches up (mformula_new.rescale()'s own comment - plain text needs no equivalent call here, it's
never baked into anything, always measured/drawn fresh from the live `sz` passed to draw() itself).
@date 2026-09-08 08:20 ]]
function editor_text.rescale(state_text, fontset)
    STATE_SHAPE.check(state_text)
    for _, item in ipairs(state_text.chars) do
        if item.formula then
            mformula.rescale(item.formula, fontset)
        end
    end
end

--[[ Nearest recorded glyph-gap position (index into state_text.chars) to a screen point, using the
positions the previous frame's draw() recorded. Used by both click-to-place and drag-to-select.

LINE FIRST, THEN COLUMN, and strictly in that order - never one blended distance. Pick the line
whose band the click is in (or the nearest band), then the nearest gap ON THAT LINE, with the
horizontal distance unable to influence the first choice at all.

It used to be a weighted sum: |dx| + dy, plus a large penalty once dy passed one line height. Two
things are wrong with that and only the second is obvious. The penalty compares against ONE line
height for the whole box, so a line grown to hold a formula reaches outside its own threshold and a
click low in it scores as "some other line". And even between two lines both inside the threshold,
a big enough |dx| difference outvotes dy - so clicking just under a short line, above a long one,
lands on the short line because there was a gap nearer the pointer up there. Requested 2026-09-09:
"when you click your cursor goes to the nearest line first, nearest column after".

THIS IS THE TEXT EDITOR'S RULE ONLY. Inside a formula the cursor moves through a tree, where "the
line above" is not a meaningful place and a click means the nearest NODE - mformula.hit_test() owns
that and is deliberately untouched. Author's own words, same day: "this is different of how it
works and should work inside formulas".

Line identity is compared with ==, which is exact rather than lucky: every position on one line is
handed the same `line_top` upvalue by draw(), so they carry bit-identical numbers.
@date 2026-09-09 23:05 ]]
local function nearest_position(state_text, mpos)
    if not state_text.last_positions then
        return nil
    end

    -- 1. THE LINE. Distance to the band, so anywhere inside a tall line scores zero and ties are
    -- broken by the topmost - never by how far along the line the pointer happens to be.
    local best_y, best_dy = nil, math.huge
    for _, p in ipairs(state_text.last_positions) do
        local dy = 0
        if mpos.y < p.y0 then
            dy = p.y0 - mpos.y
        elseif mpos.y > p.y1 then
            dy = mpos.y - p.y1
        end
        if dy < best_dy then
            best_dy, best_y = dy, p.y
        end
    end

    -- 2. THE COLUMN, among that line's own gaps and no others.
    local best_i, best_dx = nil, math.huge
    for _, p in ipairs(state_text.last_positions) do
        if p.y == best_y then
            local dx = math.abs(p.x - mpos.x)
            if dx < best_dx then
                best_dx, best_i = dx, p.i
            end
        end
    end
    return best_i
end

-- Exported for tests only (same convention as formula_line_fit below): it is a pure function of
-- draw()'s recorded positions, so it can be checked without an ImGui frame - which is the whole
-- reason the line/column split lives in here rather than inline in handle_input().
editor_text.nearest_position = nearest_position

-- #################################################################################################
-- Undo / redo
-- #################################################################################################

-- Bounded so a very long session doesn't grow this without limit - generous enough that normal
-- use never gets anywhere near it (typing coalesces into one step per run; only backspace/delete
-- runs, paste, formula creation, and each individual keystroke INSIDE a formula count separately -
-- see push_undo()'s comment). Only ever trims from the OLDEST end, one entry at a time, so nothing
-- recent is ever at risk of being dropped.
-- @date 2026-09-08 08:20
local UNDO_STACK_LIMIT = 500

--[[ Recursive copy that's safe on this model's cyclic structure (row.parent_row points back up
the tree, forming real cycles with base/sup/sub pointing back down) - `seen` maps an original table
to its copy, registered BEFORE recursing into it, so a cycle resolves to the same in-progress copy
instead of looping forever or duplicating a shared node.

Keys starting with "_" are skipped - this codebase's own convention for a derived/cache field
(mformula's _layout_cache/_graph_cache), which would otherwise drag a real mexpr_p/vc object into
the snapshot for nothing: cheap to drop, and everything that reads a cache already handles it being
absent by rebuilding from scratch.
@date 2026-09-08 08:20 ]]
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
    --[[ THE COPY OF A SEALED CONTAINER IS STILL THAT CONTAINER. Without this the metatable was
    dropped and a snapshot held a formula that had every field of an mformula.container and was not
    one - which worked only for as long as nothing asked. Found 2026-09-12, when mformula_new's
    public functions started checking: undo restores these tables straight back into the editor, so
    the plain copy was on its way to every function that takes a container.

    Set at the END, not before the loop: __newindex fires on an absent key, so sealing first would
    route every copied field through the check on its way in. They came off a table that was already
    sealed, so they have been through it once already.

    nil for a plain table, which setmetatable accepts, so this stays a no-op for everything that was
    not sealed to begin with. ]]
    return setmetatable(copy, getmetatable(t))
end

--[[ deep_copy() alone is NOT enough for a formula embed: it copies Lua tables but passes userdata
straight through, and an mexpr_t is userdata - so a snapshot's formula shared the LIVE tree, which
propagate_rebuild() then cuts out from under it (mformula_new.clone()'s own comment). Every formula
item therefore gets a real, independent copy here, which is exactly what undo_or_redo() below
already claims to be restoring.

`fontset` comes off state_text._fontset,
        stashed by handle_input each frame: snapshot() is reached from
a dozen push_undo() call sites that have no reason to know about fonts, and deep_copy() skips
"_"-prefixed keys, so parking it there costs nothing and can't leak into a snapshot.
@date 2026-09-08 08:20 ]]
local function snapshot(state_text)
    local chars = deep_copy(state_text.chars)
    if state_text._fontset then
        for _, item in ipairs(chars) do
            if item.formula then
                item.formula = mformula.clone(item.formula, state_text._fontset)
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
    if state_text.active_formula then
        for i, item in ipairs(state_text.chars) do
            if item.formula == state_text.active_formula then
                active_idx = i
                break
            end
        end
    end
    return {
        chars = chars,
        cursor_pos = state_text.cursor_pos,
        selection_anchor = state_text.selection_anchor,
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
new edit branching off from it.
@date 2026-09-08 08:20 ]]
local function commit_undo(state_text, snap, coalesce_key)
    -- Any real edit outdates the cached pre-edit snapshot (see its own comment in handle_input) -
    -- invalidated here rather than at each call site, since this is the one place every edit passes
    -- through.
    state_text._undo_baseline = nil
    if coalesce_key and coalesce_key == state_text.undo_coalesce_key then
        return
    end
    table.insert(state_text.undo_stack, snap)
    if #state_text.undo_stack > UNDO_STACK_LIMIT then
        table.remove(state_text.undo_stack, 1)
    end
    state_text.redo_stack = {}
    state_text.undo_coalesce_key = coalesce_key
end

--[[ Convenience for the common case: snapshot state_text right now, then commit it. The one call site
that needs to know whether an edit actually happened BEFORE deciding to commit (the active-formula
case in handle_input,
        keyed off mformula's own state_text.version) builds the snapshot up front instead
and calls commit_undo() directly.
@date 2026-09-08 08:20 ]]
local function push_undo(state_text, coalesce_key)
    --[[ Every mutating action in this file funnels through here, which makes it the one place worth
    tagging the frame from (prof.lua / perf_composer.h). A spike frame's report then reads
    "events: edit:backspace" instead of leaving the cause to be inferred from the timings - which is
    the entire difference between "draw took 40ms" and knowing what to go and look at. The
    coalesce_key already names the action for undo's own purposes; nil means one of the structural
    edits that never coalesces. ]]
    prof.event("edit:" .. (coalesce_key or "structural"))
    commit_undo(state_text, snapshot(state_text), coalesce_key)
end

--[[ One step of `edit.undo` / `edit.redo`. Restores the formula that owned input too, by the index
snapshot()
recorded - the restored chars are all-new tables, so the old active_formula reference cannot be
reused, but the item at that index is the same formula and undoing an edit made INSIDE one should
leave you still inside it. Falls back to plain editing when that index holds no formula any more
(the undone edit deleted it, say). A no-op when the relevant stack is empty.
@date 2026-09-08 08:20 ]]
local function undo_or_redo(state_text, is_redo)
    local from_stack = is_redo and state_text.redo_stack or state_text.undo_stack
    local to_stack = is_redo and state_text.undo_stack or state_text.redo_stack
    local snap = table.remove(from_stack)
    if not snap then
        return
    end
    table.insert(to_stack, snapshot(state_text))

    --[[ UNDO RESTORES CONTENT, NOT MODE. Whether a formula currently owns input is left exactly as
    it was, and only WHICH formula is taken from the snapshot.

    Reported live 2026-09-07: "undo from text after putting a hat jumps the cursor around". Applying
    an accent inside a formula snapshots a state_text in which that formula was active; leaving it and
    pressing Ctrl+Z out in the text then restored that flag too, and the caret teleported from where
    you were typing into the middle of the formula. Undoing while you are STILL inside a formula has
    the opposite requirement - being ejected into the text on every undo would be just as wrong - so
    the rule cannot be "always enter" or "always exit". It is "do not change modes".

    (An older comment on this function claimed it "always exits back to plain editing on restore".
    It never did - the line below has always taken the flag from the snapshot. The comment was
    describing an intent the code did not have.) ]]
    local was_in_formula = state_text.active_formula ~= nil
    state_text.chars = snap.chars
    state_text.cursor_pos = snap.cursor_pos
    state_text.selection_anchor = snap.selection_anchor
    if was_in_formula then
        local restored = snap.active_formula_idx and state_text.chars[snap.active_formula_idx]
        state_text.active_formula = restored and restored.formula or nil
    else
        state_text.active_formula = nil
    end
    state_text.undo_coalesce_key = nil
    state_text._undo_baseline = nil      -- the state_text just changed wholesale; any cached one is stale
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
the caret back where the undone edit started, not where the previous one left it.
@date 2026-09-08 08:20 ]]
function editor_text.begin_formula_edit(state_text)
    STATE_SHAPE.check(state_text)
    if not state_text._undo_baseline then
        state_text._undo_baseline = snapshot(state_text)
    end
    return mformula.cursor_path(state_text.active_formula)
end

--[[ Closes the undo step that begin_formula_edit opened.

Core - ONE FORMULA EDIT IS ONE UNDO STEP, not one per keystroke. begin takes a baseline snapshot and
this turns it into a step, so undoing after typing inside a formula returns to before you entered it
rather than unpicking it character by character.

Params: `cursor_path` is where the caret was in the formula, restored onto the SNAPSHOT's copy of it
- the snapshot holds different node objects, so a raw cursor reference would point into the live
tree and the undone state_text would open with the caret somewhere it never was.

Does nothing when no baseline is open, which is the ordinary case for anything that was not a
formula edit.
@date 2026-09-12 04:15 ]]
function editor_text.commit_formula_edit(state_text, cursor_path)
    STATE_SHAPE.check(state_text)
    local snap = state_text._undo_baseline
    if not snap then
        return
    end
    local idx = snap.active_formula_idx
    local snap_item = idx and snap.chars[idx]
    if snap_item and snap_item.formula then
        mformula.cursor_from_path(snap_item.formula, cursor_path)
    end
    commit_undo(state_text, snap, nil)
end

--[[ Exported for tests only (the convention mformula_new's make_supsub()/make_frac() already use).
handle_input()'s own Ctrl+Z branch is the real entry point, and it needs real keypresses, so a test
that wants to undo something has to reach the machinery directly.
@date 2026-09-08 08:20 ]]
editor_text.push_undo = push_undo
--[[ Steps the undo history back, and forward.

THE WHOLE CHAR STREAM IS SNAPSHOTTED, formulas included, which is why undo lives in this file rather
than in editor.lua: a definition box has no stream to snapshot, so what a step even IS differs per
owner. A formula edit counts as one step - see commit_formula_edit above.
@date 2026-09-12 04:15 ]]
function editor_text.undo(state_text) undo_or_redo(state_text, false) end
--[[ The same history, stepped forward. Cleared by any new edit, so a branch is never re-entered.
@date 2026-09-12 04:15 ]]
function editor_text.redo(state_text) undo_or_redo(state_text, true) end

--[[ The formula embed under a screen point, as {container, hb}, or nil.

WHAT A POINTER CAN LAND ON in this box, asked once. The boxes come from the last draw
(`last_formula_boxes`), which is what every click here has always hit-tested against.

`only` restricts the search to ONE formula - the caret-owning one, when the question is "did this
click land inside the formula that currently has input" rather than "which formula is here". Both
questions are asked in this file and they used to be two copies of the same loop.
@date 2026-09-11 21:40 ]]
function editor_text.formula_at(state_text, pos, only)
    STATE_SHAPE.check(state_text)
    for _, fb in ipairs(state_text.last_formula_boxes or {}) do
        if (not only or fb.formula == only) and editor.point_in_box(pos, fb) then
            return {container = fb.formula, hb = fb}
        end
    end
    return nil
end

-- #################################################################################################
-- Input handling
-- #################################################################################################

--[[ `fontset`/`sz` are only needed for the one thing keyboard-only input handling never needed
before: hit-testing a click against an active formula's own drawn geometry (mformula.hit_test()
has to rebuild/measure rows to know where they land on screen, same as draw() does).
@date 2026-09-08 08:20 ]]
function editor_text.handle_input(state_text, fontset, sz)
    STATE_SHAPE.check(state_text)
    -- Parked for snapshot()'s benefit (see its own comment) - "_"-prefixed, so deep_copy() never
    -- carries it into a snapshot.
    state_text._fontset = fontset
    -- Ctrl+Z/Ctrl+Shift+Z: checked first, ahead of even the active-formula dispatch below, so
    -- undo/redo works the same way regardless of whether a formula currently owns input - see
    -- undo_or_redo()'s own comment on why it restores content without changing modes.
    -- Two actions now, not one key with a Shift test: edit.undo and edit.redo are separately
    -- rebindable, and redo is checked FIRST because it is the more specific of the two - with
    -- exact matching they cannot both match, but the order makes that independent of the rule.
    if keymap.pressed("edit.redo") then
        undo_or_redo(state_text, true)
        return
    end
    if keymap.pressed("edit.undo") then
        undo_or_redo(state_text, false)
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
    if state_text.active_formula then
        local escaped = keymap.pressed("formula.exit")
        -- Ctrl+Left/Right always leave the formula, regardless of where the cursor is inside it -
        -- plain Left/Right staying parked at the formula's own start/end (mformula_new's
        -- move_left/move_right do nothing further once there) is intentional, not something arrow keys
        -- should escape on their own.
        -- ...but NOT with Shift also held: Ctrl+Shift+Left/Right is the formula's own SPRINT
        -- (mformula_new's sprint_horizontal(); it was the selection gesture until the two were
        -- swapped 2026-09-10), so intercepting it here would leave the formula on the very first
        -- attempt to use it. Nothing here has to arrange that any more - `bind_matches` compares
        -- modifiers EXACTLY unless a bind says "+All", so "Ctrl+Left" simply does not answer to
        -- Ctrl+Shift+Left. The note stays because the hazard is real if that ever loosens.
        local ctrl_left = keymap.pressed("formula.exit_left")
        local ctrl_right = keymap.pressed("formula.exit_right")
        local ctrl_arrow_exit = ctrl_left or ctrl_right
        local clicked_outside, clicked_inside_fb = false, nil
        if vc.ImGui_IsMouseClicked("ImGuiMouseButton_Left", false) then
            local target = editor_text.formula_at(state_text, vc.ImGui_GetMousePos(),
                    state_text.active_formula)
            clicked_inside_fb = target and target.hb
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
                for i, it in ipairs(state_text.chars) do
                    if it.formula == state_text.active_formula then
                        state_text.cursor_pos = ctrl_left and (i - 1) or i
                        break
                    end
                end
            end
            state_text.active_formula = nil
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
            state_text.mouse_selecting already uses for plain text,
                    just aimed at the active formula. ]]
            local dragging_here = state_text.formula_dragging
                    and vc.ImGui_IsMouseDown("ImGuiMouseButton_Left")
            if clicked_inside_fb or dragging_here then
                local fb = clicked_inside_fb or state_text.formula_dragging
                local mpos = vc.ImGui_GetMousePos()
                -- The host owns the ABSOLUTE-wrap_edge -> RELATIVE-wrap_width conversion and the
                -- screen -> draw-origin conversion, and mutates cursor_pos directly (the same
                -- convention move_*() uses) rather than returning a position to assign.
                editor.formula_hit_test(state_text.active_formula, fontset, sz, mpos, fb.draw_x,
                        fb.draw_y, fb.wrap_edge,
                        dragging_here and not clicked_inside_fb)
                state_text.formula_dragging = fb
            end
            if not vc.ImGui_IsMouseDown("ImGuiMouseButton_Left") then
                state_text.formula_dragging = nil
            end
            -- One undo step per keystroke INSIDE a formula (not coalesced, unlike plain typing
            -- outside one) - but only when this keystroke actually changed the tree, not for pure
            -- cursor movement (Left/Right/Up/Down, or the click above) - mformula's own
            -- state_text.version (bumped by every real tree edit) is exactly that signal, so there's
            -- no need to re-derive "was this an edit" by hand here.
            --[[ The pre-edit snapshot is CACHED (state_text._undo_baseline), not rebuilt each frame.
            An undo step has to be captured before the edit that it undoes, but this branch runs on
            every frame a formula is active - so taking one unconditionally meant snapshotting
            continuously, ~60 times a second, to throw all but a handful away.

            That was merely wasteful while a snapshot was a shallow deep_copy; once snapshot() began
            cloning each formula's whole tree (it had to - see mformula_new.clone()) it became a
            full structural rebuild of every formula, every frame, and the editor visibly lagged.
            Reported live: "it lags a lot".

            A baseline stays valid until something actually changes the state_text,
                    so it is invalidated
            in commit_undo() and undo_or_redo() - the two places that ever do. The cost is back to
            about one clone per edit instead of one per frame. ]]
            local formula = state_text.active_formula
            -- The caret path has to be taken BEFORE the edit - afterwards it has already moved with
            -- it. See editor_text.begin_formula_edit()'s comment for why it isn't read off the baseline.
            local pre_cursor_path = editor_text.begin_formula_edit(state_text)
            -- edit_bracket() runs the frame's input and reports whether the TREE changed, as
            -- opposed to the cursor merely moving - which is exactly the condition an undo step
            -- should be taken on, and is why the version bookkeeping now lives in the host.
            if editor.edit_bracket(formula, fontset, sz) then
                editor_text.commit_formula_edit(state_text, pre_cursor_path)
            end
            return
        end
    end

    -- size_off (size-table steps, negative = bigger - see char.size_delta_by_desc's comment) is
    -- only ever non-nil for the handful of glyphs (currently just "\\int") that need to render
    -- bigger than the text around them; omitted from the item table entirely otherwise, so a
    -- normal glyph is just {code=}.
    local function insert_ncod(ncod, size_off)
        table.insert(state_text.chars, state_text.cursor_pos + 1, new_item{code=ncod, size_off=size_off})
        state_text.cursor_pos = state_text.cursor_pos + 1
    end

    -- Still needed as raw state_text for the Alt+letter Greek family and the selection-extending
    -- arrows, which are whole families of keys rather than single actions.
    local is_ctrl, is_shift, is_alt = keymap.mods()

    -- Ctrl+M: insert a new formula embed at the cursor and enter it straight away. -------------
    if keymap.pressed("formula.new") then
        push_undo(state_text, nil)
        -- mexpru.DEFAULT_SIZE (a fixed LOGICAL baseline), NOT the live `sz` - `sz` is content.lua's
        -- CURRENT, possibly-already-zoomed state_text.font_size; baking that in directly here would
        -- double-count the zoom the moment mexpru.physical_sz() maps it again (2026-09-04's Ctrl+
        -- MouseWheel zoom - see mexpru.DEFAULT_SIZE's own comment). A brand-new formula still
        -- renders at the CURRENT zoom immediately either way - physical_sz() applies it fresh at
        -- construction regardless of which logical baseline was used.
        local formula = mformula.new(fontset, mexpru.DEFAULT_SIZE)
        table.insert(state_text.chars, state_text.cursor_pos + 1, new_item{formula = formula})
        state_text.cursor_pos = state_text.cursor_pos + 1
        state_text.active_formula = formula
        return
    end

    -- Ctrl+/: insert a new formula embed here, already containing an empty fraction, and enter
    -- it - mirrors Ctrl+M above, just starting with a frac instead of a blank formula (see
    -- mformula.new_with_frac()'s own comment for why it doesn't wrap anything). -------------
    if keymap.pressed("formula.new_frac") then
        push_undo(state_text, nil)
        -- mexpru.DEFAULT_SIZE, not the live `sz` - same reasoning as Ctrl+M just above.
        local formula = mformula.new_with_frac(fontset, mexpru.DEFAULT_SIZE)
        table.insert(state_text.chars, state_text.cursor_pos + 1, new_item{formula = formula})
        state_text.cursor_pos = state_text.cursor_pos + 1
        state_text.active_formula = formula
        return
    end

    -- Ctrl+=: the same again for a stack - a new formula embed already holding a one-slot vert,
    -- cursor inside it. The third of the three containers reachable straight from plain text
    -- (Ctrl+M blank, Ctrl+/ fraction, Ctrl+= stack); asked for precisely so the stack
    -- stops being the odd one out that needs a Ctrl+M first. Ctrl+SHIFT+= is superscript and is
    -- handled in the block below - the `not is_shift` guard here is what keeps the two apart, the
    -- same split mformula_new.handle_input() makes for these keys INSIDE a formula. -------------
    if keymap.pressed("formula.new_stack") then
        push_undo(state_text, nil)
        -- mexpru.DEFAULT_SIZE, not the live `sz` - same reasoning as Ctrl+M/Ctrl+/ above.
        local formula = mformula.new_with_vert(fontset, mexpru.DEFAULT_SIZE)
        table.insert(state_text.chars, state_text.cursor_pos + 1, new_item{formula = formula})
        state_text.cursor_pos = state_text.cursor_pos + 1
        state_text.active_formula = formula
        return
    end

    -- Ctrl+Shift+'_'/'+': turn the character the cursor is sitting right after (the one "with
    -- the blinker on it") directly into a subscript/superscript base, in one step - no need to
    -- Ctrl+M first. That character is pulled out of the plain text and becomes the new formula's
    -- base, so what you see reads as a continuation of what you were already writing (same size,
    -- same baseline) with just a margin box around the new formula. No preceding character (start
    -- of text, or it's a newline/another formula) still works - the base is just left empty. -----
    do
        local slot = nil
        if keymap.pressed("formula.wrap_sub") then
            slot = "sub"
        elseif keymap.pressed("formula.wrap_sup") then
            slot = "sup"
        end
        if slot then
            push_undo(state_text, nil)
            state_text.selection_anchor = nil
            local base_item = nil
            local prev = state_text.cursor_pos > 0 and state_text.chars[state_text.cursor_pos]
            if prev and not prev.newline and not prev.formula then
                base_item = prev
                table.remove(state_text.chars, state_text.cursor_pos)
                state_text.cursor_pos = state_text.cursor_pos - 1
            end
            -- mexpru.DEFAULT_SIZE, not the live `sz` - same reasoning as Ctrl+M/Ctrl+/ above: a
            -- fixed LOGICAL baseline, never content.lua's already-zoomed state_text.font_size.
            --[[ TRANSLATED AT THE BOUNDARY, 2026-09-12: mformula_new used to take this chars item
            whole and read two fields off it, which made the formula module depend on the shape of a
            text item - and unable to check it, since the require only goes the other way. It takes
            its own `base_glyph` now, and converting to it is this file's job because this is the
            file that knows what an item holds. ]]
            local base = base_item
                    and mformula.base_glyph(base_item.code, base_item.size_off) or nil
            local formula = mformula.new_from_base(fontset, mexpru.DEFAULT_SIZE, base, slot)
            table.insert(state_text.chars, state_text.cursor_pos + 1, new_item{formula = formula})
            state_text.cursor_pos = state_text.cursor_pos + 1
            state_text.active_formula = formula
            return
        end
    end

    -- Ctrl+A/C/X/V: select all, copy, cut, paste -----------------------------------------------
    do
        if keymap.pressed("edit.select_all") then
            state_text.selection_anchor = 0
            state_text.cursor_pos = #state_text.chars
        end
        local copy = keymap.pressed("edit.copy")
        local cut = keymap.pressed("edit.cut")
        if copy or cut then
            local lo, hi = selection_range(state_text)
            if lo then
                vc.ImGui_SetClipboardText(selection_to_text(state_text, lo, hi))
                if cut then
                    push_undo(state_text, nil)
                    delete_selection(state_text)
                end
            end
        end
        if keymap.pressed("edit.paste") then
            local text = vc.ImGui_GetClipboardText()
            if selection_range(state_text) or (text and #text > 0) then
                push_undo(state_text, nil)
            end
            delete_selection(state_text)
            if text then
                insert_text(state_text, text, fontset)
            end
        end
    end

    -- Space, handled explicitly rather than trusting it to show up via
    -- vc.ImGui_input_queue_chars() below (it doesn't always). ------------------------------------
    --[[ The "not Ctrl" guard is gone (2026-09-07). text.space is bound "Space+All", and a bind
    that says ALL while the code still refuses one modifier is a bind that lies to whoever reads it
    in the customiser. Consequence, flagged rather than hidden: Ctrl+Space now inserts a space,
    where before it did nothing. Nothing else binds Ctrl+Space. ]]
    if keymap.pressed("text.space") then
        push_undo(state_text, "type")
        delete_selection(state_text)
        insert_ncod(char.find_by_ascii(" ").ncod)
    end

    -- Typing -------------------------------------------------------------------------------------
    --[[ `not is_ctrl`, added 2026-09-07. Alt+letter is Greek; Ctrl+Alt+letter is NOT, and used to
    be only because this branch tested Alt and never looked at Ctrl. Ruled: "let's not, only
    alt+letter greek". The practical effect is that AltGr+letter (AltGr reports as Ctrl+Alt on
    Windows and Linux) no longer inserts a Greek letter on layouts that have one.

    Still a raw ImGui poll rather than keymap actions: this is a FAMILY of 24 keys sharing one
    meaning, and it becomes F2's own glyph-binding section rather than 24 entries in the shortcut
    registry - see keymap.lua's header. ]]
    if is_alt and not is_ctrl then
                --[[ Iterated from the GLYPH MAP, not from char.greek_key_ids, and keyed by the
                physical key rather than by a letter. char.lua's table assumes the key labelled Q
                types "q", which is only true on a US layout - keying by position is what lets a
                row be moved onto whatever key a person actually has. char.greek_key_ids remains
                the source of the DEFAULTS, one layer down in glyphmap.lua. ]]
        local handled = false
        glyphmap.each(function(key_name, _)
            if handled then return end
            if vc.ImGui_IsKeyPressed(keymap.key_of(key_name), true) then
                local letter = (key_name:gsub("^ImGuiKey_", "")):lower()
                --[[ glyphmap, not char.lua's tables directly: what a letter key produces is
                customisable now (F2's Letters section), and char.greek_alt/greek_alt_shift stay
                the FACTORY copy that "back to default" restores from. The fallback below is
                unchanged and still matters - a letter with no glyph mapped falls back to the
                plain Latin one rather than inserting nothing. ]]
                local entry = glyphmap.entry(key_name, true, is_shift)
                if not entry then
                    -- No distinct greek glyph for this letter (or none mapped) - fall back to
                    -- the plain/uppercase Latin letter, the same fallback the C++ comment box had.
                    entry = char.find_by_ascii(is_shift and letter:upper() or letter)
                end
                if entry then
                    push_undo(state_text, "type")
                    delete_selection(state_text)
                    insert_ncod(entry.ncod, char.size_delta(entry.desc))
                    -- One key per press: without this the walk carries on and a second row bound
                    -- to the same key would insert twice.
                    handled = true
                end
            end
        end)
    else
        --[[ KEYS WITH A `plain` OVERRIDE, checked before the character queue.

        Ordinary typing arrives as CHARACTERS from ImGui's queue, not as key presses, and a
        character carries no idea of which key produced it - so a key remapped to type something
        else could never be noticed there. That is why setting the Types column appeared to do
        nothing at all: the Alt columns are polled per key and worked, while plain typing went
        straight past the map. Reported 2026-09-07: "writing didn't respect the new configuration".

        A key that fired here SUPPRESSES the queue for this frame. The queue would otherwise also
        deliver the character that same key produced, and inserting both is worse than the rare
        cost of a second character typed within one frame having to wait for the next one. Only
        rows that actually carry an override are polled, so an unmodified setup pays one table
        walk over an empty set. ]]
        local overridden = false
        glyphmap.each(function(key_name, slots)
            if overridden or not slots.plain then
                return
            end
            if vc.ImGui_IsKeyPressed(keymap.key_of(key_name), true) then
                local entry = glyphmap.entry(key_name, false, false)
                if entry then
                    push_undo(state_text, "type")
                    delete_selection(state_text)
                    insert_ncod(entry.ncod, char.size_delta(entry.desc))
                    --[[ COUNT the character this key is about to produce, do not skip a frame.

                    The first attempt suppressed the queue for the frame the key fired in, which is
                    wrong because a key event and the character it produces need not arrive in the
                    same frame - ImGui queues them separately, and on a real keyboard the character
                    routinely lands a frame later. The override inserted, the character arrived
                    afterwards, and the key produced BOTH glyphs. Reported 2026-09-07.

                    A count is exact where a frame window is a guess: one override fires, one
                    character is swallowed, whenever it turns up. Nothing typed afterwards is at
                    risk, which a two-frame window could not promise. ]]
                    state_text._suppress_chars = (state_text._suppress_chars or 0) + 1
                    overridden = true
                end
            end
        end)

        local codepoints = vc.ImGui_input_queue_chars()
        for _, cp in ipairs(codepoints) do
            -- > 32, not >= : space is handled explicitly above (the char queue doesn't always
            -- carry it), so skip it here to avoid inserting it twice on a frame where it does.
            if cp > 32 and cp < 256 and (state_text._suppress_chars or 0) > 0 then
                -- This character belongs to a key an override already handled. Swallow exactly
                -- one per override, whichever frame it arrives in.
                state_text._suppress_chars = state_text._suppress_chars - 1
            elseif cp > 32 and cp < 256 then
                local entry = char.find_by_ascii(string.char(cp))
                if entry then
                    push_undo(state_text, "type")
                    delete_selection(state_text)
                    insert_ncod(entry.ncod)
                end
            end
        end
    end

    -- Deletion -------------------------------------------------------------------------------------
    if keymap.pressed("text.backspace") then
        -- Consecutive backspaces coalesce into one undo step (deleting a whole word this way
        -- comes back in one Ctrl+Z), but not with typing before them - a plain key mismatch
        -- against "type" already ensures that, no extra bookkeeping needed.
        if selection_range(state_text) or state_text.cursor_pos > 0 then
            push_undo(state_text, "backspace")
        end
        if not delete_selection(state_text) and state_text.cursor_pos > 0 then
            table.remove(state_text.chars, state_text.cursor_pos)
            state_text.cursor_pos = state_text.cursor_pos - 1
        end
    end
    if keymap.pressed("text.delete") then
        if selection_range(state_text) or state_text.cursor_pos < #state_text.chars then
            push_undo(state_text, "delete")
        end
        if not delete_selection(state_text) and state_text.cursor_pos < #state_text.chars then
            table.remove(state_text.chars, state_text.cursor_pos + 1)
        end
    end

    -- Enter ----------------------------------------------------------------------------------------
    if keymap.pressed("text.newline") then
        push_undo(state_text, nil)
        delete_selection(state_text)
        table.insert(state_text.chars, state_text.cursor_pos + 1, new_item{newline=true})
        state_text.cursor_pos = state_text.cursor_pos + 1
    end

    -- Left/Right, with Ctrl word-skip (the whitespace-then-alnum scan carried over from the C++
    -- comment box this file grew out of).
    -- A plain (non-shift) arrow with an active selection collapses to that selection's edge,
    -- same as most editors, instead of moving one char from the current cursor. -----------------
    if keymap.pressed("nav.left") or keymap.pressed("nav.select_left")
            or keymap.pressed("nav.word_left") or keymap.pressed("nav.select_word_left") then
        local lo = selection_range(state_text)
        local adjacent_formula = state_text.cursor_pos > 0 and state_text.chars[state_text.cursor_pos].formula
        if lo and not is_shift then
            state_text.cursor_pos = lo
            state_text.selection_anchor = nil
        elseif is_ctrl and not is_shift and adjacent_formula then
            -- Ctrl+Left right after a formula enters it (at its own end, since we're arriving
            -- from its right side) instead of word-skipping straight over it as a single unit -
            -- the symmetric counterpart to Ctrl+Left/Right already leaving a formula FROM inside
            -- (see mformula's own handle_input caller in this file).
            state_text.selection_anchor = nil
            state_text.active_formula = adjacent_formula
            mformula.cursor_to_end(state_text.active_formula)
        else
            update_selection_for_move(state_text, is_shift)
            local function on_ws()    return is_whitespace(state_text.chars[state_text.cursor_pos]) end
            local function on_alnum() return is_alnum(state_text.chars[state_text.cursor_pos]) end
            local function move()     if state_text.cursor_pos > 0 then state_text.cursor_pos = state_text.cursor_pos - 1 end end
            if not is_ctrl then
                move()
            else
                while state_text.cursor_pos ~= 0 and on_ws() do move() end
                repeat
                    move()
                until state_text.cursor_pos == 0 or not on_alnum()
            end
        end
    end
    if keymap.pressed("nav.right") or keymap.pressed("nav.select_right")
            or keymap.pressed("nav.word_right") or keymap.pressed("nav.select_word_right") then
        local _, hi = selection_range(state_text)
        local adjacent_formula = state_text.cursor_pos < #state_text.chars and state_text.chars[state_text.cursor_pos+1].formula
        if hi and not is_shift then
            state_text.cursor_pos = hi
            state_text.selection_anchor = nil
        elseif is_ctrl and not is_shift and adjacent_formula then
            -- Mirror of the Left case above: Ctrl+Right right before a formula enters it at its
            -- own start.
            state_text.selection_anchor = nil
            state_text.active_formula = adjacent_formula
            mformula.cursor_to_start(state_text.active_formula)
        else
            update_selection_for_move(state_text, is_shift)
            local function on_ws()    return is_whitespace(state_text.chars[state_text.cursor_pos+1]) end
            local function on_alnum() return is_alnum(state_text.chars[state_text.cursor_pos+1]) end
            local function move()     if state_text.cursor_pos < #state_text.chars then state_text.cursor_pos = state_text.cursor_pos + 1 end end
            if not is_ctrl then
                move()
            else
                while state_text.cursor_pos ~= #state_text.chars and on_ws() do move() end
                repeat
                    move()
                until state_text.cursor_pos == #state_text.chars or not on_alnum()
            end
        end
    end

    -- Home/End (not in old, cheap to add) -----------------------------------------------------------
    if keymap.pressed("nav.home") or keymap.pressed("nav.select_home") then
        update_selection_for_move(state_text, is_shift)
        while state_text.cursor_pos ~= 0 and not is_newline(state_text.chars[state_text.cursor_pos]) do
            state_text.cursor_pos = state_text.cursor_pos - 1
        end
    end
    if keymap.pressed("nav.end") or keymap.pressed("nav.select_end") then
        update_selection_for_move(state_text, is_shift)
        while state_text.cursor_pos ~= #state_text.chars and not is_newline(state_text.chars[state_text.cursor_pos+1]) do
            state_text.cursor_pos = state_text.cursor_pos + 1
        end
    end

    -- Up/Down: preserve column distance across the nearest newline markers (the C++ comment box's
    -- own algorithm) ------------------------------------------------------------------------------
    if keymap.pressed("nav.up") or keymap.pressed("nav.select_up") then
        update_selection_for_move(state_text, is_shift)
        local dist = 0
        while state_text.cursor_pos ~= 0 and not is_newline(state_text.chars[state_text.cursor_pos]) do
            state_text.cursor_pos = state_text.cursor_pos - 1
            dist = dist + 1
        end
        if state_text.cursor_pos ~= 0 and is_newline(state_text.chars[state_text.cursor_pos]) then
            state_text.cursor_pos = state_text.cursor_pos - 1
        end
        local maxdist = 0
        while state_text.cursor_pos ~= 0 and not is_newline(state_text.chars[state_text.cursor_pos]) do
            state_text.cursor_pos = state_text.cursor_pos - 1
            maxdist = maxdist + 1
        end
        state_text.cursor_pos = state_text.cursor_pos + math.min(dist, maxdist)
    end
    if keymap.pressed("nav.down") or keymap.pressed("nav.select_down") then
        update_selection_for_move(state_text, is_shift)
        local dist = 0
        while state_text.cursor_pos ~= 0 and not is_newline(state_text.chars[state_text.cursor_pos]) do
            state_text.cursor_pos = state_text.cursor_pos - 1
            dist = dist + 1
        end
        while state_text.cursor_pos ~= #state_text.chars and not is_newline(state_text.chars[state_text.cursor_pos+1]) do
            state_text.cursor_pos = state_text.cursor_pos + 1
        end
        if state_text.cursor_pos ~= #state_text.chars then
            state_text.cursor_pos = state_text.cursor_pos + 1
        end
        while dist > 0 and state_text.cursor_pos ~= #state_text.chars and not is_newline(state_text.chars[state_text.cursor_pos+1]) do
            state_text.cursor_pos = state_text.cursor_pos + 1
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
        local target = editor_text.formula_at(state_text, vc.ImGui_GetMousePos())
        if target then
            -- Entering a formula, like re-activating a content.lua box, shouldn't also do
            -- the normal click-places-cursor thing - it just brings it into edit mode.
            state_text.active_formula = target.container
            return
        end
    end
    if clicked then
        local nearest = nearest_position(state_text, vc.ImGui_GetMousePos())
        if nearest then
            if is_shift then
                if not state_text.selection_anchor then
                    state_text.selection_anchor = state_text.cursor_pos
                end
            else
                state_text.selection_anchor = nil
            end
            state_text.cursor_pos = nearest
            state_text.mouse_click_origin = nearest
            state_text.mouse_selecting = true
        end
    elseif down and state_text.mouse_selecting then
        local nearest = nearest_position(state_text, vc.ImGui_GetMousePos())
        if nearest and nearest ~= state_text.cursor_pos then
            if not state_text.selection_anchor then
                state_text.selection_anchor = state_text.mouse_click_origin
            end
            state_text.cursor_pos = nearest
        end
    elseif not down then
        state_text.mouse_selecting = false
    end
end

-- #################################################################################################
-- Layout / render
-- #################################################################################################

-- Line height + baseline offset, derived once per font size from real glyph metrics: 'G' gives the
-- cap top and 'g' the descender bottom, which is the trick the C++ comment box used before this.
-- @date 2026-09-08 08:20
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
cmex10's integral glyph is designed for EXTERNAL vertical centering (the way a DISPLAY side positions
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
that belongs in math_expr_composer.h, not here.
@date 2026-09-08 08:20 ]]
local MIN_FORMULA_COLUMN_LINES = 1

--[[ How many rows a WRAPPING FORMULA drops, where a word drops one. Two, so a formula that
moved always lands with a clear row between it and the text it left behind.

WHY A FORMULA IS DIFFERENT from a word, and this is a real defect underneath a preference: what a
formula DRAWS is bigger than the line height reserved for it. Pass 1 reserves from the formula's
own box.top/box.bottom, but pass 2 draws its border around formula_click_rect(), which is already
grown to cover any slot marker poking out, and then adds a further margin on each side. So a
formula's visible box is at least one margin taller than the room the line kept for it, top and
bottom, and two of them on adjacent rows overlap. Reported live 2026-09-09: "the gray boxes
intersect if you look at them after the wrap".

TWO ROWS DOES NOT FIX THAT DEFECT, and is not meant to - it is the author's own spacing rule,
verbatim: "either way, formulas should be spaced two spaces away from other things". The overlap
survives everywhere formulas are vertically adjacent WITHOUT a wrap having moved one, which this
never touches. Fixing it properly means pass 1 reserving from the same rect pass 2 draws, margin
included; that is a behaviour change nobody has asked for yet.

Words deliberately stay at one row - author's own words, same day: "in the new formulation, words
dont jump multiple rows".
@date 2026-09-09 22:05 ]]
local FORMULA_WRAP_ROWS = 2

--[[ Where on its own row a formula that WAS MOVED by the wrapper sits: hard against the right
margin, not at the left where everything else starts.

It is a signal, not decoration. A formula alone on a row is ambiguous - it reads exactly the same
whether somebody typed it there on purpose or the wrapper pushed it down out of the line above,
and those mean different things to whoever is reading the document back. Author's own words,
2026-09-09: "you can't really tell if a formulas is by itself, or it was moved by the wrapper, so,
it would be way more visible at the right end". Left edge therefore means "this is where it was
put", right edge means "this was moved".

`run_width` is the formula's whole advance, margins included, so the returned offset puts its right
margin on the column's right margin. Clamped at zero because the caller also breaks for a formula
too wide for any line at all (the MIN_FORMULA_COLUMN_LINES guard, not the fit rule) - that one
starts at the left and wraps inside its own column, which is the only thing it can do.
@date 2026-09-09 22:40 ]]
local function wrapped_formula_x(width_limit, run_width)
    if not width_limit or not run_width then
        return 0
    end
    return math.max(0, width_limit - run_width)
end

--[[ THE RULE BOTH KINDS OF UNBREAKABLE RUN FOLLOW: a run that does not fit in what is left of
this line moves to the next one - but ONLY if the next line can actually hold it.

A run is anything the layout must keep whole: a formula, or a word (see measure_runs). `used` is
how far along the line the layout has already advanced, `run_width` how much the run will advance
it by, both in the same units.

The "only if it fits" half is what stops the rule eating itself. A run WIDER than a whole line
fits nowhere, so moving it down gains nothing and would repeat on every line forever; it stays
put and is cut the way it always was - a word by the per-glyph check that follows this one, a
formula by wrapping inside its own column. False at the start of a line for that same reason.

Answering false is always safe: it means "leave it where it is", which is what this editor did
before the rule existed.
@date 2026-09-09 21:51 ]]
local function run_moves_down(width_limit, used, run_width)
    if not width_limit or not run_width or used <= 0 then
        return false
    end
    if run_width <= width_limit - used then
        return false                    -- it fits right here
    end
    return run_width <= width_limit     -- ...and the next line is only better if it fits there
end

--[[ Where a formula goes on the line it is currently on. `used` is how far along that line the
layout has already advanced (pass 1's lx, pass 2's x - pos.x); returns (break_line, column):

  break_line - start a new line before drawing it, FORMULA_WRAP_ROWS of them (see there - a
               formula lands two rows down, not one). Two independent reasons, either one
               enough: what is left of the line is too narrow to be a legal column at all (the
               hang guard above), or run_moves_down() says the formula would sit better on the
               next line. Never true at the start of a line.
  column     - the CONTENT width to hand down, floored at MIN_FORMULA_COLUMN_LINES worth so it is positive
               even in a box too narrow to hold one - see MIN_FORMULA_COLUMN_LINES.

`run_width` is this formula's whole advance - its natural, UNWRAPPED width plus both margins, as
measure_runs() reports it. Natural, not wrapped: the question being asked is "how much room does
it want", and a formula measured inside the column it is trying to escape has already answered
"exactly the column", which would make the rule a no-op. Pass nil and the fit rule is skipped,
leaving the pre-2026-09-09 behaviour.

Both passes call this rather than each doing the arithmetic, because a disagreement between them
about which line a formula lands on is its own class of bug (see pass 1's own comment).
@date 2026-09-09 21:51 ]]
local function formula_line_fit(m, width_limit, used, run_width)
    if not width_limit then
        return false, nil
    end
    local min_col = m.line_height * MIN_FORMULA_COLUMN_LINES
    local remaining = width_limit - used - 2 * FORMULA_MARGIN
    if used > 0 and (remaining < min_col
            or run_moves_down(width_limit, used, run_width)) then
        -- Break: the column becomes the whole line's worth, measured from its start.
        return true, math.max(min_col, width_limit - 2 * FORMULA_MARGIN)
    end
    return false, math.max(min_col, remaining)
end

--[[ How wide is everything that has to stay whole on one line, measured ONCE for both of draw()'s
passes. Keyed by the item's own index in state_text.chars, set only on the item that STARTS a run:

  a formula - its natural width plus both margins, i.e. exactly what lx/x advance by.
  a word    - a maximal run of items with no whitespace, no newline and no formula in it, summed
              over each glyph's own advance at its own effective size (item.size_off).

WHY A WORD IS A NON-WHITESPACE RUN and not a run of is_alnum(): "end." has to travel as one thing.
Splitting on anything finer orphans the punctuation onto the next line by itself, which is the
same defect this rule was asked to remove, in a smaller size.

WHY MEASURED HERE rather than inside each pass: the two passes have to agree about which line
every item lands on, and pass 1's own comment records what happens when they don't. Both reading
one table makes them agree by construction, instead of by both doing the same arithmetic right.

Costs one extra mformula.measure() per formula per draw - the passes still measure again, at the
column they are granted, for the height. Against the profiler's own lua.ce.total that is noise; if
it ever stops being noise, this natural measure can be reused whenever the formula turns out to
fit its column, because content_extent() returns the same numbers in that case.
@date 2026-09-09 21:51 ]]
local function measure_runs(state_text, fontset, sz)
    local runs, i, n = {}, 1, #state_text.chars
    while i <= n do
        local item = state_text.chars[i]
        if item.newline or is_whitespace(item) then
            i = i + 1
        elseif item.formula then
            runs[i] = mformula.measure(item.formula, fontset, sz, nil).width + 2 * FORMULA_MARGIN
            i = i + 1
        else
            local start, total = i, 0
            while i <= n do
                local it = state_text.chars[i]
                if it.newline or it.formula or is_whitespace(it) then
                    break
                end
                local eff_sz = math.max(1, math.min(MAX_SIZE_INDEX, sz + (it.size_off or 0)))
                total = total + fontset:char_get_sz({size = eff_sz, code = it.code}).adv
                i = i + 1
            end
            runs[start] = total
        end
    end
    return runs
end

-- Exported for tests only (the convention mformula_new's make_supsub()/make_frac() already use):
-- the passes that call them live inside draw(), which needs a real ImGui frame to run.
editor_text.formula_line_fit = formula_line_fit
editor_text.run_moves_down = run_moves_down
editor_text.measure_runs = measure_runs
editor_text.FORMULA_WRAP_ROWS = FORMULA_WRAP_ROWS
editor_text.wrapped_formula_x = wrapped_formula_x
local FORMULA_BORDER_COLOR = 0xff777777
local FORMULA_ACTIVE_BORDER_COLOR = 0xff00ffff
-- The cursor-travel track and the empty-slot outline moved to editor.lua with the drawing that
-- used them, so all three editors share one look instead of drifting apart. Their local copies
-- here went with them; nothing in this file draws either any more. -- @date 2026-09-08 08:20

--[[ Draws state_text onto the current ImGui window, starting at `pos`, using font size `sz`,
soft-wrapping lines wider than `width_limit` (pass nil/false to disable soft-wrap). The blinking
caret is only drawn when `show_cursor` is true (or omitted) - a caller managing several editors
(e.g. content.lua's boxes) should pass false for every editor that isn't the active one.
`show_wireframe` (default false) is forwarded to every inline formula's own mformula.draw() - the
debug bounding-box overlay (vc.mexpr_draw's draw_bb), off by default so it's only on when actually
visually debugging (content.lua's own wireframe-toggle button).
`show_graph` (default false) gates the ACTIVE formula's own reachable-position graph (mformula.
reachable_graph(), carried over from the old row-based editor) - off by default, same
reasoning as show_wireframe, content.lua's own graph-toggle button flips it on.
@return the total content height in pixels (bottom of the last line, relative to pos.y), and the
widest any single line's own content actually reached (relative to pos.x - may exceed width_limit,
see max_x's own comment below) - lets a caller (e.g. content.lua's boxes) size itself to fit both.
@date 2026-09-08 08:20 ]]
function editor_text.draw(state_text, fontset, pos, sz, width_limit, show_cursor, show_wireframe,
        show_graph)
    STATE_SHAPE.check(state_text)
    if show_cursor == nil then
        show_cursor = true
    end
    local m = get_metrics(fontset, sz)
    -- Every formula's and every word's own width, measured once and read by BOTH passes below so
    -- they cannot disagree about which line one lands on - see measure_runs' own comment.
    local runs = measure_runs(state_text, fontset, sz)

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
        for i = 0, #state_text.chars do
            local item = state_text.chars[i+1]
            if item then
                if item.newline then
                    line_idx = line_idx + 1
                    line_extra_top[line_idx], line_extra_bottom[line_idx] = 0, 0
                    lx = 0
                elseif item.formula then
                    local break_line, wrap_width = formula_line_fit(m, width_limit, lx, runs[i+1])
                    if break_line then
                        -- FORMULA_WRAP_ROWS rows, not one - pass 2 skips exactly as many, or the
                        -- two would disagree about which line everything after this sits on.
                        for _ = 1, FORMULA_WRAP_ROWS do
                            line_idx = line_idx + 1
                            line_extra_top[line_idx], line_extra_bottom[line_idx] = 0, 0
                        end
                        -- NOT zero: a moved formula lands against the RIGHT margin, and pass 2
                        -- puts it in the same place. See wrapped_formula_x.
                        lx = wrapped_formula_x(width_limit, runs[i+1])
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
                    --[[ Reserve from the rect pass 2 actually DRAWS, not from the formula's own
                    content box. Pass 2 borders it around formula_click_rect() - already grown to
                    cover a slot marker poking out - and then a margin further out on each side.
                    Reserving from box.top/box.bottom alone left the visible border taller than
                    its own line by at least that margin, top and bottom, so two formulas on
                    neighbouring rows overlapped on screen: reported live 2026-09-09, "the gray
                    boxes intersect". Calling the same function pass 2 does is what keeps the two
                    from drifting apart again.

                    Markers exist for the ACTIVE formula only (editor.draw_formula computes them
                    inside its active-only block), so only that one pays for slot_markers here. ]]
                    local markers = (item.formula == state_text.active_formula)
                            and mformula.slot_markers(item.formula, fontset, sz) or nil
                    local _, _, rect_t, rect_b = editor.formula_click_rect(box, markers)
                    local extra_top = math.max(0,
                            m.baseline_shift - (rect_t - FORMULA_MARGIN))
                    local extra_bottom = math.max(0,
                            (rect_b + FORMULA_MARGIN) - (m.baseline_shift + m.line_height))
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
                        line_extra_top[line_idx] = math.max(line_extra_top[line_idx], math.max(0,
                                m.baseline_shift - (item_sz.tr.y + yshift)))
                        line_extra_bottom[line_idx] = math.max(line_extra_bottom[line_idx],
                                math.max(0,
                                        (item_sz.bl.y + yshift) - (m.baseline_shift + m.line_height)))
                    end
                    --[[ Two checks, in this order, and both are needed. The first moves a
                    whole WORD down when it would fit better there (run_moves_down); runs[i+1] is
                    set only on a word's first glyph, so this asks the question once per word
                    rather than once per letter. The second is the original per-glyph cut, which
                    still has to be here: it is what renders a word too long for any line at all,
                    the case the first check deliberately declines. Pass 2 does the same two in
                    the same order. ]]
                    if run_moves_down(width_limit, lx, runs[i+1]) then
                        line_idx = line_idx + 1
                        line_extra_top[line_idx], line_extra_bottom[line_idx] = 0, 0
                        lx = 0
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

    for i = 0, #state_text.chars do
        local item = state_text.chars[i+1]
        local item_sz = nil
        local eff_sz = sz
        --[[ The column this formula is granted, taken from the SAME call that decides whether it
        moves. It used to be re-derived further down, which worked only while a moved formula
        restarted at x = pos.x: the second call then saw used == 0 and answered "a whole line",
        the same as the first. Right-aligning broke that - the second call sees a nearly-full line
        and answers "exactly your own width", and content_extent() tests wrapping against the RAW
        bounding box while reporting the baseline-converted one, so a column of exactly the
        reported width can still wrap by a hair. It did: "a+b+c+d+e+" with the "f" dropped onto a
        row of its own. Asking once and remembering removes the second question rather than
        tuning an epsilon into it. ]]
        local formula_column = nil
        --[[ The line break happens HERE, before positions/cursor_screen_pos are recorded below,
        so both agree with where the item actually lands. A formula follows the same rule as a
        glyph - no usable room left, start a new line - which pass 1 above applies identically. ]]
        if item and not item.newline then
            if item.formula then
                local break_line
                break_line, formula_column = formula_line_fit(m, width_limit, x - pos.x, runs[i+1])
                if break_line then
                    -- Same count, then the same offset, as pass 1's own loop - both halves have
                    -- to match or the two passes disagree about where this formula is.
                    for _ = 1, FORMULA_WRAP_ROWS do
                        newline()
                    end
                    --[[ A moved formula is granted a WHOLE line's column (formula_column, above,
                    from before this move) and is then pushed right by however much of it it did
                    not need. Keeping the column whole is what makes the push purely horizontal:
                    the formula lays out exactly as it would have at the left margin. ]]
                    x = pos.x + wrapped_formula_x(width_limit, runs[i+1])
                end
            else
                eff_sz = math.max(1, math.min(MAX_SIZE_INDEX, sz + (item.size_off or 0)))
                item_sz = fontset:char_get_sz({size=eff_sz, code=item.code})
                -- The whole word first, then the single glyph - pass 1 runs the same two in the
                -- same order, and its comment says why both are needed.
                if run_moves_down(width_limit, x - pos.x, runs[i+1]) then
                    newline()
                end
                if width_limit and (x - pos.x) + item_sz.adv > width_limit then
                    newline()
                end
            end
        end

        --[[ y is the line's TEXT top, which is what the caret is drawn from; y0/y1 are its whole
        VISUAL band, which is what a click has to be measured against. They differ whenever a line
        holds something taller than plain text - a formula, a boosted integral - because line_top
        already has that line's extra_top folded in by newline(), so the tall part lives ABOVE y.
        Clicking on the top half of a big formula has to pick that formula's line, not the one
        whose text top happens to be nearer. Same reasoning downwards for extra_bottom. ]]
        positions[#positions+1] = {
            x = x, y = line_top, i = i,
            y0 = line_top - (line_extra_top[line_idx] or 0),
            y1 = line_top + m.line_height + (line_extra_bottom[line_idx] or 0),
        }
        if i == state_text.cursor_pos then
            cursor_screen_pos = {x=x, y=line_top}
        end

        if item then
            if item.newline then
                newline()
            elseif item.formula then
                -- Inline embed: rendered through mformula/mexpr, not char_draw. "Made to fit" -
                -- the margin box below is sized exactly to this frame's actual bounding box, so
                -- it always hugs the formula's current content, growing/shrinking live as it's
                -- edited, the same way content.lua's boxes fit editor_text.lua's text.
                local is_active_formula = (item.formula == state_text.active_formula)
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
                -- pattern as show_wireframe) gates this specifically - carried over from the old
                -- row-based editor, off by default so it doesn't clutter ordinary editing.
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
                --[[ Everything that goes around a formula - the caret highlight, the
                reachable-position graph, the slot markers - plus the formula itself, in the one
                order that layers them correctly. All of it lives in editor.lua now, shared with
                editor_definition.lua, because none of it was ever about a character stream. See
                that file's header for the draw-order argument and the two coordinate conventions.

                wrap_edge is passed ABSOLUTE, as it is computed here; the host does the conversion
                to the RELATIVE width cursor_box()/hit_test() want. ]]
                local drawn = editor.draw_formula(item.formula, fontset, sz, {x = content_x,
                        y = y}, {
                            active = is_active_formula,
                            show_wireframe = show_wireframe,
                            show_graph = show_graph,
                            wrap_edge = wrap_edge,
                        })
                local box, markers = drawn.box, drawn.markers
                if is_active_formula and box.cursor_top then
                    formula_cursor_top, formula_cursor_h = y + box.cursor_top, box.cursor_h
                end

                -- The click-routing rect (is a click "inside" this formula, or does it deactivate
                -- it?) has to cover every marker too, not just the formula's own content bbox -
                -- root's trailing marker in particular sticks out past box.width on purpose (see
                -- the comment above). Without this, clicking on a marker that pokes past the
                -- border would read as "outside" and deactivate the formula instead of
                -- hit-testing into it.
                local rect_l, rect_r, rect_t, rect_b = editor.formula_click_rect(box, markers)

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

    state_text.last_positions = positions
    state_text.last_formula_boxes = formula_boxes

    -- Restart the blink cycle whenever the caret moves (or the buffer changes under it) so it is ON
    -- immediately and you can see where it landed, rather than possibly arriving mid-dark-phase.
    -- Same reasoning, and the same one-place-catches-every-path approach, as mformula_new.draw()'s
    -- own blink reset - see its comment.
    local blink_key = state_text.cursor_pos .. "/" .. #state_text.chars
    if state_text.blink_key ~= blink_key then
        state_text.blink_key = blink_key
        state_text.frame = 0
    end
    state_text.frame = state_text.frame + 1

    -- Where the caret ACTUALLY is right now, screen-space, regardless of which of the two carets
    -- (this editor's own, or an active formula's - only one is ever showing at a time, see
    -- show_cursor below) is the real one this frame - content.lua reads this every frame to keep
    -- it scrolled into view, the same way it already does for a box switch (scroll_into_view) but
    -- continuously, since typing/arrow-key movement/a formula growing can all move the caret
    -- without any of those already having scrolled for it. nil when there's nothing to track yet
    -- (an empty box with no active formula has no caret at all).
    if state_text.active_formula then
        state_text.last_cursor_y, state_text.last_cursor_h = formula_cursor_top, formula_cursor_h
    elseif cursor_screen_pos then
        state_text.last_cursor_y, state_text.last_cursor_h = cursor_screen_pos.y, m.line_height
    else
        state_text.last_cursor_y, state_text.last_cursor_h = nil, nil
    end

    -- Selection highlight: one translucent rect per glyph cell (so it naturally handles
    -- multi-line selections), drawn on top of the text just drawn above.
    if state_text.selection_anchor and state_text.selection_anchor ~= state_text.cursor_pos then
        local lo = math.min(state_text.selection_anchor, state_text.cursor_pos)
        local hi = math.max(state_text.selection_anchor, state_text.cursor_pos)
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

    -- Blinking caret: a real drawn line (vc.ImGui_AddLine), not stored in the model - the same
    -- blinker the C++ comment box drew, now that AddLine is exposed to Lua.
    -- (~30 frames/half-period, roughly a 0.5s blink at 60fps.) Suppressed while a formula embed
    -- is active - its own caret (drawn above, inside mformula.draw) is the one that should show.
    if show_cursor and not state_text.active_formula and cursor_screen_pos
            and (math.floor(state_text.frame / 30) % 2 == 0) then
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
editor_text.draw()/handle_input() are the per-BOX phases sitting between content.lua's per-frame totals
and mformula_new's per-formula ones, which is what makes "cost grows with the number of boxes"
distinguishable from "cost grows with what is in one box". rescale_all() is per zoom step and
rebuilds every formula in the document, so it is a prime suspect for a one-frame spike. ]]
local prof_ = require("prof")
editor_text.draw         = prof_.wrap("lua.editor_text.draw", editor_text.draw)
editor_text.handle_input = prof_.wrap("lua.editor_text.handle_input", editor_text.handle_input)
if editor_text.rescale_all then
    editor_text.rescale_all = prof_.wrap("lua.editor_text.rescale_all", editor_text.rescale_all)
end

return editor_text

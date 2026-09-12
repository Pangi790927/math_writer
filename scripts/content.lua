--[[ ==================================== WHAT THIS FILE OFFERS ====================================
new()                                   -> state_doc
deserialize(text: string, fontset: fontset) -> state_doc | nil, reason
serialize(state_doc: content.state_doc) -> text
    A document. THE SAVE FORMAT is every box in order, each as
    "<kind> <byte length>
<that many bytes>", so a box's own text can
    contain anything without escaping.

BOXES
insert_box(state_doc: content.state_doc, index: number, kind: string) -> index
add_box(state_doc: content.state_doc, kind: string) -> index
remove_box(state_doc: content.state_doc, i: number) -> nothing
move_box(state_doc: content.state_doc, i: number, dir) -> nothing
    Each fixes up active_index so the caret stays on the same LOGICAL
    box rather than the same slot.
box_kinds()                             -> {kind, ...}
    In the order the radial menu offers them.

DERIVATION
derive_identity(state_doc: content.state_doc, i: number) -> index
prune_descendants(state_doc: content.state_doc, id: id) -> nothing
    A derived box and everything derived from it, however deep - the
    whole subtree, not one level.
declarations_before(state_doc: content.state_doc, index: number) -> {order, by_text}
    Every name declared ABOVE a box, which is what it may resolve a
    reference against.

FRAME
draw(state_doc: content.state_doc, fontset: fontset, pos: {x,y}, opts: table) -> nothing
handle_input(state_doc: content.state_doc, fontset: fontset, pos: {x,y}) -> nothing
    The panels swallow the frame first; then box routing, the radial
    menu and the right-click transform menu.
customiser_open(state_doc: content.state_doc) -> boolean
FOR THE HELP PAGE
draw_box_chrome(box_x, box_y, box_w, box_h, kind: string, is_active, rail_x)
draw_demo_radial(cx, cy, hover)         -> nothing
radial_extent()                         -> extent
    The same chrome and the same menu, drawn at an arbitrary point so
    F1 shows the real thing rather than a picture of it.

--- internal, not on the module table --------------------------------------------------------------
    new_shell()    THE ONE creator for the document `state_doc`, and where its seal is
                   attached; STATE_FIELDS beside it declares the shape
    declarations_before() is public above and is THE ONE creator of the `decls`
    container every parse and gesture downstream receives
    the rail, the transform menu, the AST overlays and box layout
@date 2026-09-12 03:45
================================================================================================= ]]

--[[
content.lua - THE DOCUMENT: a stack of boxes hanging off a rail, and the shell that manages them.

A box is one of three kinds - text, formula, definition - and each kind is a separate editor module
(editor_text, editor_formula, editor_definition). This file knows only that all three expose the
same shape: new / draw / handle_input / rescale / to_text / from_text. It never learns what any of
them holds, which is what keeps a new kind from rippling through here: adding one means a colour, a
radial sector, and a branch in the three places that build a box.

What this file owns is everything AROUND the boxes: the rail and its insertion points, the radial
menu that picks a kind, which box is active (only that one receives keyboard input), the derivation
curves between formula boxes, scrolling, zoom, and the save format the whole document is written in.
It also dispatches the two full-screen panels (panel_help on F1, panel_keymap on F2), which own the
frame outright while either is open.

@date 2026-09-08 08:30
]]

local vc = require("virt_composer")
local editor = require("editor_text")
local prof = require("prof")
local char = require("char")
local mexpru = require("mexpru")
local sealed = require("sealed")
--[[ One editor module per box kind. content.lua knows only that each exposes the same shape -
new/draw/handle_input/rescale/to_text/from_text - and never what any of them does inside. ]]
local editor_definition = require("editor_definition")
local mexpr_ast = require("mexpr_ast")
--[[ What a gesture can DO where it landed, and what running one produces. The transformations
themselves are NOT required here: ast_gestures owns the dispatch from an option to the function that
performs it, so this file never names one. ]]
local ast_gestures = require("ast_gestures")
--[[ The way back: a transformed tree, as the glyphs that draw it. A result is not delivered until
it is a formula again - the mexpr is the artifact and the ast is scratch. ]]
local ast_mexpr = require("ast_mexpr")
local mformula_latex = require("mformula_latex")
local ast = require("ast")
local keymap = require("keymap")
local panel_help = require("panel_help")
local panel_keymap = require("panel_keymap")
local editor_formula = require("editor_formula")
--[[ The shared formula host the three box editors sit on - `editor` above is editor_text, which is
a historic name, so this one cannot have it. Only its READING half is used here: which node a screen
point is over, without moving anybody's caret. ]]
local editor_common = require("editor")
--[[ The flight recorder. A gesture that declines is invisible on screen by design, so it says why
HERE - which is the log that gets read when "it does nothing" is reported. ]]
local input_recorder = require("input_recorder")

local content = {}

local RAIL_OFFSET = 40   -- rail x, relative to pos.x
local BOX_LEFT    = 80   -- box left edge, relative to pos.x
-- Extra room kept beyond the caret in the direction a box was just moved, so the move visibly
-- goes somewhere instead of parking the caret against the edge it arrived at.
local MOVE_FOLLOW_LEAD = 90
local BOX_GAP     = 24   -- vertical gap between boxes
local BOX_PADDING = 12
local BOX_WIDTH   = 760
-- Height of a box with nothing in it: the floor for a text box, and the whole height of a
-- formula/definition placeholder, which has no content to measure at all.
local EMPTY_BOX_HEIGHT = 50
local NODE_RADIUS = 6
-- state_doc.font_size (below, new_shell()) starts here - a char.lua m_font_sizes table index (1 =
-- biggest/360pt, 18 = smallest/8pt - see that table's own comment), not a pixel size. mexpru's own
-- DEFAULT_SIZE (36pt) - the same nominal size this used to be a plain constant at before Ctrl+
-- MouseWheel zoom made it live, adjustable state_doc instead - single source of truth
-- since editor_text.lua's own brand-new-formula construction (formula.new, paste) needs that value
-- (mexpru.DEFAULT_SIZE's own comment: a fixed LOGICAL baseline, not this live state_doc.font_size).
local DEFAULT_FONT_SIZE = mexpru.DEFAULT_SIZE
local MIN_FONT_SIZE, MAX_FONT_SIZE = 1, mexpru.MAX_SIZE_INDEX -- char.lua's own table bounds
local CLOSE_SIZE  = 16   -- close ("x") button, sits just above each box's top-right corner
local WIREFRAME_SIZE = 16 -- wireframe-toggle button, sits just left of the close button
local GRAPH_SIZE = 16    -- graph-toggle button, sits just left of the wireframe button
local RAIL_CLICK_RADIUS = 16 -- how close to the rail line counts as "clicking the rail"

--[[ The three box kinds, chosen from the radial menu (RADIAL_* below) when a box is made and never
converted afterwards. The kind decides which editor module the box carries - `editor`, `fml` or
`def` - and its colour; nothing else here branches on it.

Text is the ordinary editor. Formula and definition are the first two cells of
docs/phase2_design.md section 1: a formula box holds one immutable expression and records what it
was derived from, a definition box declares a name and its type. Both are real editors now - they
were coloured placeholders when the radial menu first needed something to spawn.
@date 2026-09-08 08:30 ]]
local KIND_TEXT       = "text"
local KIND_FORMULA    = "formula"
local KIND_DEFINITION = "definition"

--[[ Colours are ImGui's IM_COL32 packing, which is 0xAABBGGRR - alpha, then BLUE, green, red.
Easy to get backwards (0xff66ccff below is orange, not the light blue it reads as), so the RGB is
spelled out in a comment next to each one. ]]
local KIND_COLORS = {
    -- fill  = the box background, translucent so the page shows through, as it always was.
    -- menu  = the radial wedge. FULLY OPAQUE, and it has to be: the wedges are drawn as
    --         half-overlapping quads to hide antialiasing seams (see draw_radial), and any alpha
    --         below ff makes each overlap blend twice and show up as a BRIGHTER spoke instead -
    --         which is exactly what 0xee looked like when this was tried.
    -- hover = the same wedge while hovered, brighter.
    [KIND_TEXT] = {                                              -- gray
        fill = 0x33ffffff, menu = 0xff888888, hover = 0xffcccccc },
    [KIND_FORMULA] = {                                           -- blue  ( 68,136,255)
        fill = 0x33ff8844, menu = 0xffcc6622, hover = 0xffff9955 },
    [KIND_DEFINITION] = {                                        -- green ( 68,204, 85)
        fill = 0x3355cc44, menu = 0xff339922, hover = 0xff66dd55 },
}

--[[ The radial menu that picks a kind, replacing the old "insert a text box immediately" on both
Ctrl+N and a rail click. Geometry settled 2026-09-06 (see TODO.md, which carries the full spec):
a centre circle, three 120-degree sectors radiating out of it to 3x the centre radius, growing to
3.2x when hovered. The first sector is centred on the UP direction - straight up, not the up-right
diagonal - and since all three are 120 wide that fixes the other two at 210 and 330, i.e.
lower-left and lower-right, with boundaries at 30/150/270.

Angles here are ordinary maths angles: 0 = right, 90 = up, counter-clockwise. Screen y grows
DOWNWARD, so every conversion below is (cx + r*cos, cy - r*sin) - the minus is not a typo. ]]
--[[ One number scales the whole selector. Everything below is derived from RADIAL_INNER, so the
proportions the geometry was specced at (3x, 3.2x) survive any change to it. Dropped to a third of
the original size 2026-09-06 - at full size it covered most of a box. ]]
local RADIAL_SCALE       = 1 / 3
local RADIAL_INNER       = 50 * RADIAL_SCALE  -- centre circle radius; also the "cancel" zone
local RADIAL_OUTER       = RADIAL_INNER * 3.0
local RADIAL_OUTER_HOVER = RADIAL_INNER * 3.2
local RADIAL_SPAN        = 120           -- degrees per sector
--[[ Drawn slightly narrower than the span so neighbouring sectors read as separate wedges instead
of one disc. HIT TESTING USES THE FULL SPAN - the gap is ink, not a dead zone, so there is no thin
strip between sectors where a click does nothing. ]]
local RADIAL_DRAW_GAP    = 2             -- degrees trimmed from each side, drawing only
local RADIAL_STEPS       = 18            -- quads per sector: no arc/convex-poly fill is exposed to
                                         -- Lua (imgui_composer.h has lines, rects, circles,
                                         -- triangles, quads), so an annular sector is built from a
                                         -- strip of AddQuadFilled - which is what ImGui's own
                                         -- convex fill does internally anyway.
--[[ How far the mouse must travel from the button-down point before a rail press counts as a
drag rather than a click. See radial_handle_input()'s own comment - it is measured from the press
point, not the menu centre, because the two differ whenever the menu gets clamped on screen. ]]
local RADIAL_ARM_DIST    = 24 * RADIAL_SCALE
--[[ The centre circle as a SELECTABLE thing, for the keyboard: Down selects it and Enter/Space
then cancels. Deliberately a sentinel rather than nil, so "nothing is selected yet" and "cancel is
selected" stay distinguishable - only the second one draws the centre highlighted. ]]
local RADIAL_CANCEL      = "cancel"
local RADIAL_CENTER_FILL = 0xdd1a1a1a
--[[ The centre while it is the thing about to be picked - see draw_radial's own comment on why it
grows its X instead of growing outward like a wedge. ]]
-- Neutral lighter gray (85,85,85), deliberately not tinted: the wedges are gray/blue/green, and a
-- coloured centre reads as one of them. Remember the packing is 0xAABBGGRR - the first attempt at
-- a warm tint here came out navy.
local RADIAL_CENTER_FILL_ON = 0xff555555
local RADIAL_CENTER_EDGE_ON = 0xffffffff
local RADIAL_X_COLOR_ON     = 0xffffffff
local RADIAL_X_ARM          = 10 * RADIAL_SCALE
local RADIAL_X_ARM_ON       = 22 * RADIAL_SCALE
local RADIAL_EDGE_COLOR  = 0xff000000

--[[ Order matters only for reading; each entry carries its own centre angle. ]]
local RADIAL_SECTORS = {
    {kind = KIND_TEXT,       angle = 90},   -- up
    {kind = KIND_FORMULA,    angle = 210},  -- lower-left
    {kind = KIND_DEFINITION, angle = 330},  -- lower-right
}

--[[ The derivation curve: a bezier joining a formula box to the box it was derived FROM.

Requested 2026-09-07: "formula boxes will be linked by a beziere curve, the curve will show what
boxes come from what boxes, the beziere will be positioned on the boxes perpendicular on the boxes,
on their outsides, the other part than the line on their left".

So it attaches on the RIGHT - the rail and its connector own the left - and leaves each box
PERPENDICULAR to the edge it leaves, which for a vertical right edge means horizontally. That is
what the control points do: both are pushed straight out to the right, so the curve leaves the
parent and enters the child at a right angle to the boxes rather than cutting across them.

Drawn as line segments because no bezier primitive is exposed to Lua (imgui_composer.h has lines,
rects, circles, triangles, quads) - the same reason the radial menu builds its wedges by hand. ]]
local CURVE_COLOR        = 0xffb0b0b0
local CURVE_SEGMENTS     = 24
local CURVE_OUT_MIN      = 24    -- how far the curve reaches out even for boxes that are adjacent
local CURVE_OUT_FACTOR   = 0.45  -- ... and how much further per pixel of vertical separation
--[[ The gutter reserved down the RIGHT of the page for these curves - the mirror of the rail on the
left, and for the same reason: the links need somewhere of their own to live. Without it the boxes
run out to the window edge and a curve leaving a box perpendicular has nowhere to go but off
screen, which is exactly what the first version did. ]]
local CURVE_GUTTER       = 96

local RAIL_COLOR         = 0xff777777
local BOX_BORDER_COLOR   = 0xff777777
local BOX_ACTIVE_COLOR   = 0xffffffff
local CLOSE_COLOR        = 0xffaaaaaa
local HOVER_COLOR        = 0xff66ff66
local GRAPH_OFF_COLOR    = 0xff888888
local GRAPH_ON_COLOR     = 0xff55cc55
local WIREFRAME_OFF_COLOR = 0xff888888
local WIREFRAME_ON_COLOR  = 0xff66ccff

local SCROLL_SPEED = 44 -- pixels per wheel notch

--[[ Spike recording (Ctrl+F3, prof.lua / perf_composer.h).

8ms, and it is a WORK threshold, not a wall-clock one (perf_composer.h's PROF_IDLE_SCOPE): half the
16.7ms budget at 60Hz, i.e. the point at which a frame is at real risk of missing its vsync. It was
25ms while the threshold still measured wall time, where anything smaller just counted frames that
had already missed a vsync and were sitting idle waiting for the next one.

For reference, measured with page heap off (see below): the app does a whole keystroke,
including the undo clone, in ~0.5ms of work - about 3% of the budget - so this should fire only when
something is genuinely wrong.

If it fires on EVERY frame, check Windows Page Heap before believing it. It was enabled for main.exe
via Image File Execution Options on this machine, which made every allocation ~8us and inflated
every measurement here by roughly 100x (clone: 22ms with it, 0.92ms without). ]]
local PROF_SPIKE_PATH = ((vc.app_data_prefix and vc.app_data_prefix()) or "") .. "perf_spikes.log"
local PROF_SPIKE_MS   = 8.0

-- #################################################################################################
-- Model
-- #################################################################################################

--[[ The empty shell shared by content.new() (which adds one empty box on top of this) and
content.deserialize() (which populates `boxes` itself instead) - kept in one place so the two
can't drift apart on what a freshly-built state_doc actually looks like.
@date 2026-09-08 08:30 ]]
--[[ THE `state_doc` CONTAINER - the whole document, and everything the editor keeps about it.

Declared and sealed for the same reason mexpru's `u` is: `state_doc` is created here but read and
written by editor_text, editor_definition, editor_formula, the two panels and main.lua, so a typo in
any of them used to make a new field instead of an error.

SIX FIELDS WERE ALREADY BEING CREATED OUTSIDE new_shell when this was written - show_ast,
show_ast_result, show_ast_string, follow_caret, transform_menu, transform_pick. They worked, because
Lua lets any field appear; nothing named them anywhere, which is exactly the drift being stopped.
They are declared below and still start nil.

A DECLARED FIELD THAT IS NIL IS NORMAL - `radial` is nil whenever the menu is closed. An undeclared
name is refused on read and on write, and a refusal means this list is out of date.
@date 2026-09-12 05:15 ]]
local STATE_FIELDS = {
    boxes             = "the document: every box, in order",
    active_index      = "which box has the caret, or nil",

    last_layout       = "filled by draw(), read by handle_input() next frame",
    last_rail_x       = "the same, for the rail's x",
    last_total_height = "filled by draw(), used to clamp scroll_y",
    scroll_y          = "how far the stack is scrolled up; 0 is pinned to the top",
    follow_caret      = "scroll to bring the caret back into view on the next draw",

    show_help         = "F1: the full-screen help page, in place of the boxes",
    show_alt_help     = "F2: the keybind customiser",
    help_state        = "panel_help's own state_doc, living here",
    keymap_state      = "panel_keymap's own state_doc, living here",
    keymap_rev        = "bumped when the customiser closes - the help's substitution cache key",

    show_wireframe    = "global: mexpr's debug bounding boxes, off by default",
    show_graph        = "global: the active formula's reachable-position graph",
    show_ast          = "F4: the parse of the expression you are on",
    show_ast_string   = "F5: its ast.lua serialization",
    show_ast_result   = "F6: what the transformation here would produce; replaces F4",

    font_size         = "a char.lua size-table INDEX, not a pixel size. Ctrl+Wheel moves it.",
    radial            = "the open new-box menu, or nil. While set it owns all input for the frame.",
    transform_menu    = "the open right-click transform menu, or nil",
    transform_pick    = "which row of that menu is under the pointer",
}

--[[ Declared through sealed.lua, like every other container here. @date 2026-09-12 05:45 ]]
local STATE_SHAPE = sealed.declare("content", "state_doc", STATE_FIELDS)

local function new_shell()
    return STATE_SHAPE.wrap({
        boxes = {},
        active_index = nil,
        last_layout = nil,    -- filled by draw(), read by handle_input() next frame
        last_rail_x = nil,
        show_help = false,     -- F1 toggles the full-screen help page in place of the boxes
        show_alt_help = false, -- F2 toggles the keybind customiser
        help_state = panel_help.new_state(),
        keymap_state = panel_keymap.new_state(),
        -- Bumped whenever the customiser closes. The help page caches each chapter with its key
        -- names already substituted in, and this is the cache key - without it a rebinding would
        -- not show up in the help until the chapter was switched away from and back.
        keymap_rev = 0,
        show_wireframe = false, -- toggled by the small button next to each box's close ("x") button -
                                 -- global, not per-box: whether mexpr drawing shows its debug bounding
                                 -- boxes (vc.mexpr_draw's own draw_bb) everywhere, off by default so
                                 -- it's only on when actually visually debugging.
        show_graph = false,     -- toggled by its own button next to the wireframe one - global, same
                                 -- reasoning as show_wireframe: whether the ACTIVE formula's own
                                 -- reachable-position graph (mformula_new.reachable_graph(),
                                 -- carried over from the old row-based editor) is drawn, off by
                                 -- default so it doesn't clutter ordinary editing.
        font_size = DEFAULT_FONT_SIZE, -- Ctrl+MouseWheel (handle_input()) adjusts this - global, same
                                 -- reasoning as show_wireframe just above. A char.lua size-table
                                 -- index, not a pixel size (DEFAULT_FONT_SIZE's own comment).
        radial = nil,          -- the open "which kind of box?" menu, or nil - see radial_open().
                               -- While non-nil it owns all input for the frame.
        scroll_y = 0,          -- how far the whole stack is scrolled up (0 = pinned to the top)
        last_total_height = 0, -- filled by draw(), used to clamp scroll_y in handle_input()
    })
end

--[[ A fresh document: one empty text box, with the caret in it.

NOT AN EMPTY DOCUMENT. A document with no boxes has nowhere to type and no way to make the first
one, so `new` is "the smallest document somebody can start working in" rather than "nothing". The
empty shell is internal for exactly that reason - deserialize needs it, and nothing else should.
@date 2026-09-12 03:45 ]]
function content.new()
    local state_doc = new_shell()
    content.add_box(state_doc)
    state_doc.active_index = 1
    return state_doc
end

--[[ Inserts a new (empty) box of `kind` at `index` (1..#boxes+1), fixing up active_index if it was
at or after the insertion point, and returns `index`. `kind` defaults to KIND_TEXT, so every
existing caller keeps its old behaviour unchanged.

Each kind carries its editor state_doc under its OWN field - `editor`,
        `fml` or `def` - and everything
downstream dispatches on which field is present rather than on `box.kind`. That is what keeps the
kind test in one place: a box that gained a field gained its controls with it, and nothing has to
be told twice. Guard on the field when adding code here, not on the kind.

A formula box is also given an id at birth, so a box derived from it can name it as its parent.
@date 2026-09-08 08:30 ]]
function content.insert_box(state_doc, index, kind)
    STATE_SHAPE.check(state_doc)
    kind = kind or KIND_TEXT
    local box = {kind = kind}
    if kind == KIND_TEXT then
        box.editor = editor.new()
    elseif kind == KIND_DEFINITION then
        box.def = editor_definition.new()
    elseif kind == KIND_FORMULA then
        --[[ Every formula box gets an id, so a box derived from it can name it as its parent. The
        counter is derived from what is already in the document rather than stored, so a loaded file
        cannot hand out an id that is already in use. ]]
        local next_id = 1
        for _, b in ipairs(state_doc.boxes) do
            if b.fml and b.fml.id and b.fml.id >= next_id then
                next_id = b.fml.id + 1
            end
        end
        box.fml = editor_formula.new(next_id)
    end
    table.insert(state_doc.boxes, index, box)
    if state_doc.active_index and state_doc.active_index >= index then
        state_doc.active_index = state_doc.active_index + 1
    end
    return index
end

--[[ Appends a new (empty) box at the end and returns its index. @date 2026-09-08 08:30 ]]
function content.add_box(state_doc, kind)
    STATE_SHAPE.check(state_doc)
    return content.insert_box(state_doc, #state_doc.boxes + 1, kind)
end

--[[ Removes box i, fixing up active_index to still point at the same logical box (or nil, if the
removed box was the active one). @date 2026-09-08 08:30 ]]
function content.remove_box(state_doc, i)
    STATE_SHAPE.check(state_doc)
    table.remove(state_doc.boxes, i)
    if state_doc.active_index == i then
        state_doc.active_index = nil
    elseif state_doc.active_index and state_doc.active_index > i then
        state_doc.active_index = state_doc.active_index - 1
    end
    -- Indices shifted - drop the stale layout so a same-frame click can't mis-hit-test against
    -- last frame's positions; draw() rebuilds it before the next handle_input() runs anyway.
    state_doc.last_layout = nil
end

--[[ Moves the box at `i` one place up (dir -1) or down (dir +1), taking the caret with it.

Returns the box's new index, or nil when it could not move (already at an end). The caller uses the
return to keep the active box active - the point of the gesture is to carry a box somewhere, so
focus follows the box rather than staying at the position.

Reordering is SAFE with respect to derivations, and not by luck: a derived box points at its parent
by `fml.id`, never by position, and content.prune_descendants() is a fixpoint over that relation
rather than a walk in document order - as its own comment says, "a box can be moved anywhere in the
list and its lineage still holds". A parent may therefore end up below its child; the curve between
them simply draws the other way.

Not undoable, exactly like content.remove_box(): undo lives inside a box and knows nothing about
the document's shape. Moving is reversible by moving back, which is a good deal cheaper than
teaching undo about it.
@date 2026-09-08 08:30 ]]
function content.move_box(state_doc, i, dir)
    STATE_SHAPE.check(state_doc)
    local j = i + dir
    if not state_doc.boxes[i] or not state_doc.boxes[j] then
        return nil
    end
    state_doc.boxes[i], state_doc.boxes[j] = state_doc.boxes[j], state_doc.boxes[i]
    -- Same reason remove_box() drops it: the indices this frame's layout was built against no
    -- longer describe the stack, so a click arriving before the next draw() must not hit-test
    -- against it.
    state_doc.last_layout = nil
    return j
end

--[[ Derives a new formula box from the one at `i` by the IDENTITY transformation: the new box
holds exactly what the old one holds, and records that it came from it.

The identity is a real derivation, not a placeholder for one - "this follows from that, unchanged"
is a legitimate step, and it is the only transformation that needs no machinery at all: because the
input and the output are the same expression, there is nothing to convert. No mexpr -> ast ->
transform -> ast -> mexpr round trip happens here, and none is needed; the LaTeX is copied and the
parent recorded. Every later transformation will differ from this one only in what it does between
those two points.

The new box goes directly BELOW its source, which is where a derivation reads. Returns its index,
or nil when the box at `i` is not a formula box with content to derive from.

The id comes from content.insert_box(), which derives the next one from what is already in the
document - so a derived box can never collide with an id already in use.
@date 2026-09-08 08:30 ]]
function content.derive_identity(state_doc, i)
    STATE_SHAPE.check(state_doc)
    local src = state_doc.boxes[i]
    if not (src and src.fml and src.fml.latex and src.fml.latex ~= "") then
        return nil
    end
    content.insert_box(state_doc, i + 1, KIND_FORMULA)
    local made = state_doc.boxes[i + 1]
    made.fml.latex = src.fml.latex
    made.fml.parent = src.fml.id
    return i + 1
end

--[[ Removes every box DERIVED from `id`, however far down the chain - the whole subtree, not just
the immediate children.

Called when a formula box is pasted into, which replaces its content and makes it a root
(editor_formula.lua). Everything below it was derived from what used to be there, so those steps no
longer follow from anything: leaving them would leave a derivation whose premise had been swapped
out underneath it, which is the exact failure docs/phase2_design.md section 1's immutability exists
to prevent. Requested 2026-09-07: "also should remove all childs".

A fixpoint over the parent relation rather than a recursive walk, so it does not depend on children
appearing after their parents in the document - a box can be moved anywhere in the list and its
lineage still holds.

DESTRUCTIVE AND NOT UNDOABLE: undo lives inside each editor, and this removes whole boxes. A paste
into a box with a long derivation under it discards all of it.
@date 2026-09-08 08:30 ]]
function content.prune_descendants(state_doc, id)
    STATE_SHAPE.check(state_doc)
    if not id then
        return 0
    end
    local doomed, growing = {}, true
    while growing do
        growing = false
        for _, b in ipairs(state_doc.boxes) do
            local f = b.fml
            if f and f.id and not doomed[f.id] and f.parent
                    and (f.parent == id or doomed[f.parent]) then
                doomed[f.id] = true
                growing = true
            end
        end
    end

    -- Backwards, so each removal cannot shift an index still to be visited.
    local removed = 0
    for i = #state_doc.boxes, 1, -1 do
        local f = state_doc.boxes[i].fml
        if f and f.id and doomed[f.id] then
            content.remove_box(state_doc, i)
            removed = removed + 1
        end
    end
    return removed
end

--[[ THE SAVE FORMAT: every box in order, each as "<kind> <byte length>\n<that many bytes>".

Length-prefixed rather than delimited, because a box's own text can legitimately contain any
character, newlines included - there is no delimiter guaranteed not to collide with real content,
so this sidesteps the question instead of picking one and hoping.

A text box's body is the same $$LaTeX$$ form edit.copy produces, so saving is exactly "select all,
copy" done to every box in turn, and the file stays readable without this program.
@date 2026-09-08 08:30 ]]
function content.serialize(state_doc)
    STATE_SHAPE.check(state_doc)
    local parts = {}
    for _, box in ipairs(state_doc.boxes) do
        --[[ Whatever the box's own editor makes of itself. The body is opaque here on purpose:
        this layer stays "kind, length, bytes" and never learns what a definition or a formula is,
        so a new box kind changes nothing in this function. A kind that has no editor state_doc yet
        writes an empty body and is still carried across the save by its kind alone - skipping it
        would have been simpler and would silently drop boxes, which is the kind of thing found out
        later, by losing work. ]]
        local text = ""
        if box.editor then
            text = editor.to_text(box.editor)
        elseif box.def then
            text = editor_definition.to_text(box.def)
        elseif box.fml then
            text = editor_formula.to_text(box.fml)
        end
        --[[ The kind prefix is NEW. Files written before box kinds existed start each record with
        a bare length ("42\n..."), so deserialize() accepts both and treats a bare length as a text
        box - old saves keep loading unchanged. ]]
        parts[#parts + 1] = (box.kind or KIND_TEXT) .. " " .. tostring(#text) .. "\n" .. text
    end
    return table.concat(parts)
end

--[[ Inverse of serialize(): parses the length-prefixed box list back into a fresh state_doc (same
shell new() itself builds - see new_shell()). Silently stops at the first malformed length prefix
(a corrupt/truncated/foreign file) rather than erroring, same leniency insert_text() itself already
has for content it can't make sense of - whatever boxes parsed cleanly before that point are kept
rather than losing everything. Always ends up with at least one box, even from an empty/unreadable
string, so the caller never has to special-case "the file had nothing usable in it". `fontset` is
only needed for editor.from_text()'s benefit (building any $$...$$ formula embeds a box's saved
text contains - always at mexpru.DEFAULT_SIZE, the same fixed LOGICAL baseline every other new
formula gets, regardless of state_doc.font_size - see mexpru.DEFAULT_SIZE's own comment).
@date 2026-09-08 08:30 ]]
function content.deserialize(text, fontset)
    local state_doc = new_shell()
    local pos = 1
    while pos <= #text do
        local nl = text:find("\n", pos, true)
        if not nl then
            break
        end
        local header = text:sub(pos, nl - 1)
        --[[ Two accepted headers, see serialize(): "<kind> <len>" (current) and a bare "<len>"
        (written before box kinds existed, read back as a text box). An unrecognised kind is also
        read as a text box rather than rejected - same leniency the length parse already has. ]]
        local kind, len = header:match("^(%a+) (%d+)$")
        if kind then
            len = tonumber(len)
            if not KIND_COLORS[kind] then
                kind = KIND_TEXT
            end
        else
            len = tonumber(header)
            kind = KIND_TEXT
        end
        if not len then
            break
        end
        local box_text = text:sub(nl + 1, nl + len)
        local box = {kind = kind}
        if kind == KIND_TEXT then
            box.editor = editor.new()
            editor.from_text(box.editor, box_text, fontset)
        elseif kind == KIND_DEFINITION then
            box.def = editor_definition.new()
            editor_definition.from_text(box.def, box_text, fontset)
        elseif kind == KIND_FORMULA then
            box.fml = editor_formula.new()
            editor_formula.from_text(box.fml, box_text, fontset)
        end
        table.insert(state_doc.boxes, box)
        pos = nl + 1 + len
    end
    if #state_doc.boxes == 0 then
        content.add_box(state_doc)
    end
    state_doc.active_index = 1
    return state_doc
end

local function point_in_rect(px, py, x, y, w, h)
    return px >= x and px <= x + w and py >= y and py <= y + h
end

--[[ Where a new box clicked-in at screen y `click_y` should land: after every existing box whose
vertical midpoint is above the click, i.e. "insert nearest the gap you clicked" - so clicking
between two boxes inserts between them, above the first inserts at the top, below the last
appends. ]]
local function insertion_index_for_y(state_doc, click_y)
    local idx = 1
    for i, r in ipairs(state_doc.last_layout) do
        if click_y > r.y + r.h / 2 then
            idx = i + 1
        else
            break
        end
    end
    return idx
end

--[[ Scrolls the least amount that brings the span y..y+h inside the viewport, with `lead` pixels
of extra room on the side being travelled towards (negative = upwards, positive = downwards, 0 =
none). The lead is what makes a move feel like it went somewhere: landing the caret exactly on the
edge it entered from tells you nothing about what is beyond it.

Shared by the caret-follow at the end of handle_input and by the box-move follow, so "bring this
into view" has one definition and one clamp.
@date 2026-09-08 08:30 ]]
local function scroll_span_into_view(state_doc, pos, y, h, lead)
    local display_size = vc.ImGui_GetDisplaySize()
    local viewport_top = pos.y
    local viewport_bottom = display_size and display_size.y or (pos.y + 700)
    lead = lead or 0
    local want_top = y - (lead < 0 and -lead or 0)
    local want_bottom = y + h + (lead > 0 and lead or 0)
    if want_top < viewport_top then
        state_doc.scroll_y = state_doc.scroll_y - (viewport_top - want_top)
    elseif want_bottom > viewport_bottom then
        state_doc.scroll_y = state_doc.scroll_y + (want_bottom - viewport_bottom)
    end
    local max_scroll = math.max(0, state_doc.last_total_height - (viewport_bottom - viewport_top))
    state_doc.scroll_y = math.max(0, math.min(max_scroll, state_doc.scroll_y))
end

--[[ Scrolls (if needed) so box `index`'s own TOP edge is visible - used when the active box
changes to one that is currently out of view, so "switching" does not leave you looking at a box
you cannot see. Enough of the top to show the move happened, never the whole box: one may be taller
than the viewport.

Reads LAST frame's layout, like every other mouse-facing helper here, and is a silent no-op before
the first draw() has run.
@date 2026-09-08 08:30 ]]
local function scroll_into_view(state_doc, pos, index)
    local r = state_doc.last_layout and state_doc.last_layout[index]
    if not r then
        return
    end
    local display_size = vc.ImGui_GetDisplaySize()
    local viewport_top = pos.y
    local viewport_bottom = display_size and display_size.y or (pos.y + 700)
    if r.y < viewport_top then
        state_doc.scroll_y = state_doc.scroll_y - (viewport_top - r.y)
    elseif r.y > viewport_bottom - 60 then
        -- Not "the whole box" (it may be taller than the viewport) - just enough of its top
        -- that switching here visibly did something, rather than requiring a full box height.
        state_doc.scroll_y = state_doc.scroll_y + (r.y - (viewport_bottom - 60))
    end
    local max_scroll = math.max(0, state_doc.last_total_height - (viewport_bottom - viewport_top))
    state_doc.scroll_y = math.max(0, math.min(max_scroll, state_doc.scroll_y))
end

-- #################################################################################################
-- The radial "which kind of box?" menu
-- #################################################################################################

--[[ Where box `index` would START, in screen y - i.e. where a box inserted at that index lands.
Reads LAST frame's layout, like every other mouse-facing helper here; nil before the first draw().
For an index past the end this is the bottom of the stack, which is exactly where Ctrl+N at the end
should put its menu. ]]
local function insertion_y(state_doc, index)
    local L = state_doc.last_layout
    if not L or #L == 0 then
        return nil
    end
    if index <= 1 then
        return L[1].y
    end
    local r = L[math.min(index - 1, #L)]
    return r.y + r.h + BOX_GAP
end

--[[ Opens the menu for an insertion at `index`, centred as close to (cx, cy) as it can be while
staying fully on screen.

The clamp is not cosmetic: the rail sits RAIL_OFFSET (40px) from the left edge and a box starts at
BOX_LEFT (80px), while the menu needs RADIAL_OUTER_HOVER (160px) of room in every direction. Centred
literally on the rail, the whole lower-left sector - formula - would be off screen and unclickable.
So the menu drifts right/down/up as needed and the caller's (cx, cy) is a preference, not a
promise. ]]
local function radial_open(state_doc, index, cx, cy, from_drag, press_x, press_y)
    local disp = vc.ImGui_GetDisplaySize()
    local margin = RADIAL_OUTER_HOVER + 8
    if disp then
        cx = math.max(margin, math.min(cx, math.max(margin, disp.x - margin)))
        cy = math.max(margin, math.min(cy, math.max(margin, disp.y - margin)))
    else
        cx = math.max(margin, cx)
        cy = math.max(margin, cy)
    end
    --[[ press_x/press_y are where the button actually went down, which after the clamp above is
    NOT the menu's centre - see radial_handle_input's arming, which needs the real press point and
    got this wrong once by assuming the two were the same. ]]
    state_doc.radial = {cx = cx, cy = cy, index = index, from_drag = from_drag or false,
            press_x = press_x, press_y = press_y, armed = false,
            selected = nil}  -- keyboard selection; mouse hover is `hover`, set per frame
end

--[[ Smallest absolute angular distance between two degree values, 0..180. ]]
local function angle_delta(a, b)
    local d = math.abs((a - b) % 360)
    if d > 180 then
        d = 360 - d
    end
    return d
end

--[[ Which sector the point (mx, my) is over, or nil for the centre circle / outside the disc.
Hit testing uses the FULL RADIAL_SPAN, ignoring RADIAL_DRAW_GAP - the drawn gap is there to make
the wedges read as separate, and turning it into a dead zone the click can fall into would be a
worse menu than one with no gap at all.

`math.atan(y, x)` is Lua 5.4's two-argument form (atan2 in older Lua) - and the y it is handed is
negated, because screen y grows downward while the sector angles are ordinary maths angles. ]]
local function radial_sector_at(radial, mx, my)
    local dx, dy = mx - radial.cx, my - radial.cy
    local dist = math.sqrt(dx * dx + dy * dy)
    if dist < RADIAL_INNER or dist > RADIAL_OUTER_HOVER then
        return nil
    end
    local ang = math.deg(math.atan(-dy, dx)) % 360
    for _, sec in ipairs(RADIAL_SECTORS) do
        if angle_delta(ang, sec.angle) <= RADIAL_SPAN / 2 then
            return sec
        end
    end
    return nil
end

--[[ Creates the chosen kind at the menu's insertion index, closes the menu, and leaves the caret
in the new box - every kind has an editor to receive it.
@date 2026-09-08 08:30 ]]
local function radial_choose(state_doc, kind)
    local index = content.insert_box(state_doc, state_doc.radial.index, kind)
    --[[ Asks which editor field the box got rather than which kind it is, for the same reason
    everything else here does - a kind that gains an editor starts being activated on creation with
    no change to this line, and one with none would take focus away from wherever it was and give
    it to something that cannot use it. ]]
    local box = state_doc.boxes[index]
    if box.editor or box.def or box.fml then
        state_doc.active_index = index
    end
    state_doc.radial = nil
end

--[[ Runs while the menu is open, and swallows the whole frame's input either way - the caller
returns immediately after, so nothing types into a box behind it or clicks one.

Two ways in, and they end differently. `box.new` opens a menu that STAYS: it is a click-then-click
menu, since there is no button held down to release. A press on the rail opens one that lives only
as long as the button - drag out to a sector, release to pick it - which is the "drag-clicking"
half of the gesture. `radial.cancel` and a click on the centre both cancel.
@date 2026-09-08 08:30 ]]
local function radial_handle_input(state_doc)
    local radial = state_doc.radial
    local mpos = vc.ImGui_GetMousePos()
    local sec = mpos and radial_sector_at(radial, mpos.x, mpos.y) or nil
    radial.hover = sec and sec.kind or nil

    --[[ The centre is hoverable in its own right, not just "not a sector" - it is the cancel
    target, and it lights up like one. ]]
    radial.over_center = false
    if mpos then
        local dx, dy = mpos.x - radial.cx, mpos.y - radial.cy
        radial.over_center = (dx * dx + dy * dy) <= RADIAL_INNER * RADIAL_INNER
    end

    if keymap.pressed("radial.cancel") then
        state_doc.radial = nil
        return
    end

    --[[ KEYBOARD SELECTION. The arrows point at where each wedge actually is on screen: Up is the
    gray text wedge (centred straight up), Left the blue formula one (lower-left), Right the green
    definition one (lower-right), and Down is the centre "x", i.e. cancel. Enter, keypad Enter or
    Space commits whatever is selected.

    Moving the MOUSE drops the keyboard selection, so hover takes back over - otherwise a stale
    arrow-key choice would sit lit up while the pointer is somewhere else entirely. Checked before
    the arrows below, so pressing an arrow in the same frame as a mouse twitch still wins. ]]
    if mpos and radial.last_mx and (mpos.x ~= radial.last_mx or mpos.y ~= radial.last_my) then
        radial.selected = nil
    end
    if mpos then
        radial.last_mx, radial.last_my = mpos.x, mpos.y
    end

    local pick
    if keymap.pressed("radial.text") then
        pick = KIND_TEXT
    elseif keymap.pressed("radial.formula") then
        pick = KIND_FORMULA
    elseif keymap.pressed("radial.definition") then
        pick = KIND_DEFINITION
    elseif keymap.pressed("radial.dismiss") then
        pick = RADIAL_CANCEL
    end
    if pick then
        radial.selected = pick
    end

    if keymap.pressed("radial.commit") then
        local sel = radial.selected
        if sel and sel ~= RADIAL_CANCEL then
            radial_choose(state_doc, sel)
        else
            -- Nothing selected, or the "x" selected: both mean close without creating anything.
            state_doc.radial = nil
        end
        return
    end

    if state_doc.radial.from_drag then
        --[[ ARMING. A drag only counts as a drag once the mouse has moved RADIAL_ARM_DIST from
        where the button went DOWN. Until then a release means "that was a click, not a drag" and
        the menu stays open in click-then-click mode, so a plain rail click still gets you
        somewhere instead of looking like it did nothing.

        Measured from the press point, NOT from the menu centre, and that distinction is the whole
        reason this exists: radial_open() clamps the menu on screen, so pressing on the rail (x=64)
        puts the centre at x=168 and leaves the cursor 104px away - already deep inside the
        lower-left wedge. Testing against the centre made a bare click on the rail spawn a formula
        box instantly. ]]
        if not state_doc.radial.armed and mpos and state_doc.radial.press_x then
            local dx = mpos.x - state_doc.radial.press_x
            local dy = mpos.y - state_doc.radial.press_y
            if dx * dx + dy * dy > RADIAL_ARM_DIST * RADIAL_ARM_DIST then
                state_doc.radial.armed = true
            end
        end
        -- Nothing reads as hovered until the drag is armed, so the wedge the clamp happens to put
        -- under the cursor does not light up as if it were about to be chosen.
        if not state_doc.radial.armed then
            state_doc.radial.hover = nil
        end

        if vc.ImGui_IsMouseReleased("ImGuiMouseButton_Left") then
            if not state_doc.radial.armed then
                state_doc.radial.from_drag = false
            elseif sec then
                radial_choose(state_doc, sec.kind)
            else
                state_doc.radial = nil
            end
        end
        return
    end

    if vc.ImGui_IsMouseClicked("ImGuiMouseButton_Left", false) then
        if sec then
            radial_choose(state_doc, sec.kind)
        else
            state_doc.radial = nil
        end
    end
end

--[[ Draws the menu: the centre circle, then one annular wedge per sector.

Each wedge is a strip of RADIAL_STEPS quads between RADIAL_INNER and the outer radius, because no
arc or convex-polygon fill is exposed to Lua (see RADIAL_STEPS' own comment). The hovered wedge
simply uses the larger outer radius - that IS the grow-on-hover,
        with no animation state_doc anywhere.

Takes the RADIAL TABLE rather than the whole state_doc (2026-09-07), so the F1 help can hand it a
made-up one and get the real menu - same wedges, same colours, same geometry - instead of a copy of
this code living in the help page. content.draw_demo_radial() below is that entry point.
@date 2026-09-08 08:30 ]]
local function draw_radial_at(radial)
    local cx, cy = radial.cx, radial.cy

    --[[ What reads as active: the keyboard selection if there is one, otherwise the mouse hover.
    RADIAL_CANCEL is the centre, not a wedge, so it leaves every wedge unlit. ]]
    local active_kind = radial.selected
    if active_kind == RADIAL_CANCEL then
        active_kind = nil
    end
    active_kind = active_kind or radial.hover

    for _, sec in ipairs(RADIAL_SECTORS) do
        local hovered = (active_kind == sec.kind)
        local outer = hovered and RADIAL_OUTER_HOVER or RADIAL_OUTER
        local colors = KIND_COLORS[sec.kind]
        local color = hovered and colors.hover or colors.menu
        local a_start = sec.angle - RADIAL_SPAN / 2 + RADIAL_DRAW_GAP
        local a_end   = sec.angle + RADIAL_SPAN / 2 - RADIAL_DRAW_GAP
        local step = (a_end - a_start) / RADIAL_STEPS
        for k = 0, RADIAL_STEPS - 1 do
            --[[ Each quad is stretched half a step past its neighbour's start (except the last,
            which stops square on the sector edge). Without the overlap the strip shows thin radial
            seams: ImGui antialiases every filled shape's edge, so two quads meeting exactly on a
            shared edge blend to slightly-transparent along it and the background shows through as
            a spoke. Overlapping hides that, and costs nothing visually because these colours are
            opaque - it WOULD show, as a brighter spoke, if they were translucent. ]]
            local a0 = math.rad(a_start + step * k)
            local a1_deg = a_start + step * (k + 1)
            if k < RADIAL_STEPS - 1 then
                a1_deg = a1_deg + step * 0.5
            end
            local a1 = math.rad(a1_deg)
            -- cy MINUS the sine: screen y grows downward, sector angles do not.
            local i0 = {x = cx + RADIAL_INNER * math.cos(a0), y = cy - RADIAL_INNER * math.sin(a0)}
            local i1 = {x = cx + RADIAL_INNER * math.cos(a1), y = cy - RADIAL_INNER * math.sin(a1)}
            local o0 = {x = cx + outer * math.cos(a0),        y = cy - outer * math.sin(a0)}
            local o1 = {x = cx + outer * math.cos(a1),        y = cy - outer * math.sin(a1)}
            vc.ImGui_AddQuadFilled(i0, o0, o1, i1, color)
        end
        -- A thin outline on the hovered wedge only, so the grown one reads as picked rather than
        -- just bigger.
        if hovered then
            local a0, a1 = math.rad(a_start), math.rad(a_end)
            vc.ImGui_AddLine({x = cx + RADIAL_INNER * math.cos(a0), y = cy - RADIAL_INNER * math.sin(a0)},
                    {x = cx + outer * math.cos(a0), y = cy - outer * math.sin(a0)}, RADIAL_EDGE_COLOR, 2)
            vc.ImGui_AddLine({x = cx + RADIAL_INNER * math.cos(a1), y = cy - RADIAL_INNER * math.sin(a1)},
                    {x = cx + outer * math.cos(a1), y = cy - outer * math.sin(a1)}, RADIAL_EDGE_COLOR, 2)
        end
    end

    --[[ The centre is the cancel target and gets the same "you are about to pick this" feedback the
    wedges do - it just cannot grow outward the way they do, since its size is what the wedges start
    from. So instead the X ITSELF grows and lights up: longer arms, thicker strokes, a brighter
    circle and a white cross. Active when the mouse is inside it, or when Down has selected it. ]]
    local center_active = radial.over_center or (radial.selected == RADIAL_CANCEL)
    vc.ImGui_AddCircleFilled({x = cx, y = cy}, RADIAL_INNER,
            center_active and RADIAL_CENTER_FILL_ON or RADIAL_CENTER_FILL)
    vc.ImGui_AddCircle({x = cx, y = cy}, RADIAL_INNER,
            center_active and RADIAL_CENTER_EDGE_ON or RAIL_COLOR, center_active and 3 or 2)
    local arm       = center_active and RADIAL_X_ARM_ON or RADIAL_X_ARM
    local thickness = center_active and 4 or 2
    local x_color   = center_active and RADIAL_X_COLOR_ON or CLOSE_COLOR
    vc.ImGui_AddLine({x = cx - arm, y = cy - arm}, {x = cx + arm, y = cy + arm}, x_color, thickness)
    vc.ImGui_AddLine({x = cx + arm, y = cy - arm}, {x = cx - arm, y = cy + arm}, x_color, thickness)
end

--[[ A cheap three-part identity for "where the caret is right now": the plain outer cursor_pos
(third slot, first two nil), or - while a formula owns input - that formula's identity plus its own
row and position.

Comparing this frame's three values against last frame's is how the caret-follow block in
handle_input tells "the caret actually moved" from "nothing changed, another frame just ran",
without an equality check over the whole editor state_doc. It parks them in the editor's own
"_"-prefixed fields, the convention this codebase uses for a transient that is not part of the
model.
@date 2026-09-08 08:30 ]]
local function cursor_sig(editor_state)
    local f = editor_state.active_formula
    if f then
        --[[ A CONTAINER HAS NO `cursor` FIELD, and never has: it keeps `cursor_pos`, a weak ref to
        the node the caret sits after. So `f.cursor and f.cursor.row` was nil on every frame this
        has ever run, and the two values below have always been nil - which means caret movement
        INSIDE a formula has never been detected here. What this actually reports is "the active
        formula changed", nothing finer.

        Found 2026-09-12 by the container seal, which refused the read. Left returning nil rather
        than repaired, because making it track the caret would change what the document does -
        scroll-into-view would start following moves it has never followed. That is a behaviour
        decision, not a typo fix.

        To repair it: compare the RESOLVED node, not `cursor_pos` itself - vc.wref_mexpr() hands
        back a new wrapper each call, so two wrefs to one node are not equal. ]]
        return f, nil, nil
    end
    return nil, nil, editor_state.cursor_pos
end

-- #################################################################################################
-- Input handling
-- #################################################################################################

--[[ Whether the F2 customiser is on screen. Exists for main.lua, which saves the keymap, the glyph
map and the plugin list only once the panel is closed (see its own comment) - it needs to ask
without reaching into this module's state_doc table for a field name that is nobody else's business.
@date 2026-09-12 03:50 ]]
function content.customiser_open(state_doc)
    STATE_SHAPE.check(state_doc)
    return state_doc.show_alt_help == true
end

--[[ ONE FRAME OF INPUT for the whole document, in two passes.

Pass 1 is the mouse against the chrome: a click on a box's close button removes it, a click inside
a box activates it and only it, a click on or near the rail inserts a new box right there - in the
order clicked, so clicking between two connector nodes inserts between them.

Pass 2 forwards the frame to the ACTIVE box's editor alone. Inactive boxes see no input at all, so
nothing can be typed into one by accident.

A click that ACTIVATES a previously-inactive box is consumed here and never reaches that box's
editor: each box remembers its own cursor and selection from when it was last active, and the click
that brings focus back should not also yank the caret to wherever it landed. Once a box is already
active, clicking inside it moves the caret as usual.

Panels come first and take the whole frame - while F1 or F2 is open this returns before any of the
above, which is what lets those panels use real widgets and read the arrow keys themselves.

  fontset  threaded through for the editors' benefit: hit-testing a click needs a formula's real
           drawn geometry
  pos      the same draw origin draw() takes, needed here only to size and clamp the scroll range
           against the current viewport
@date 2026-09-08 08:30 ]]
-- #################################################################################################
-- Transformation gestures
-- #################################################################################################

--[[ A right-click asks what can be done where the pointer is; the answer is a menu; choosing from
it names a transformation and its parameters. Three small steps, and the reason they are three is
that only the middle one is about menus at all - `ast_gestures` decides what applies and `transforms`
does it, neither of them knowing a pointer exists.

WHY A MENU RATHER THAN A DIRECT ACTION. Distribute is the only option today, so a right-click could
just do it - and that shape would have to be unbuilt the moment the second transformation applies in
the same place.

AN EMPTY LIST IS STILL DRAWN, and this is the one rule here that was learned rather than designed.
It was built the other way first - no options, no menu - on the reasoning that a menu with nothing in
it says nothing. What it actually says is "the gesture was understood and there is nothing here",
and the alternative says nothing at all: the report was "right click does not open a menu" on a
document whose every sum was a bare one. Silence is indistinguishable from a broken feature, and the
user cannot tell which they are looking at. Author, 2026-09-11, deciding it: "YES, AND IF NONE
AVAILABLE, DRAW THE LIST EMPTY".

So: over a formula cell, always a menu. Anywhere else, nothing.
@date 2026-09-11 23:10 ]]
local MENU_ROW_H   = 18
local MENU_PAD     = 6
--[[ Half the alpha it opened with (0xee -> 0x77), on request, 2026-09-11: "make that menu a bit
more translucid, make twice as so". The edge and the text keep theirs - what is wanted is to see the
formula through the box, not to make the box itself hard to read. ]]
local MENU_BG      = 0x771c1c1c
local MENU_EDGE    = 0xff606060
local MENU_TEXT    = 0xffe8e8e8
local MENU_HOVER   = 0xff4a3a2a
local MENU_MIN_W   = 96

--[[ The FORMULA CELL under a screen point, as {container, hb, index}, or nil.

FORMULA CELLS ONLY, which is a rule about what a transformation is for rather than about what can be
hit-tested. A cell is a step in a derivation - immutable, with a parent link, the thing the proof DAG
is made of - and a transformation produces the next one. Prose with formulas in it is not a step, and
a definition is not derived from anything: it is configured, the way its slots and domains already
are. Author, 2026-09-11: "formula only, definitions don't get transformations, those are simply
configurable like we did".

The same question could be asked of a text box's embeds or a definition's slots - both editors can
answer it - and deliberately is not. Right-clicking those is silent, and the recorder says so.

ANY CELL, not just the focused one: a question does not need focus to be answerable, and requiring it
killed the gesture on a cell the caret had left, which looks exactly like a dead feature. `index`
travels with the answer because the declarations in scope are the ones BEFORE that cell.
@date 2026-09-11 23:40 ]]
local function formula_under(state_doc, pos)
    if not pos then
        return nil
    end
    for i, box in ipairs(state_doc.boxes or {}) do
        local found = box.fml and editor_formula.formula_at(box.fml, pos)
        if found then
            found.index = i
            return found
        end
    end
    return nil
end

--[[ Opens the gesture menu at the pointer. Empty, when nothing applies there.

NOTHING IS MUTATED on the way: the node is resolved with editor_common.formula_node_at, the half of
the click path that does not move the caret. Asking "what is here" must not answer by moving the
cursor out from under whatever the user was doing.

THE TWO WAYS OUT WITHOUT A MENU are the pointer not being over a formula CELL - text, prose with
formulas in it, and definitions are all refused rather than answered emptily - and the pointer not
being over a GLYPH inside one. Every other outcome - a glyph that names no node, a row that does not
parse, a node nothing applies to - opens the menu with the list it has, which is usually empty. See
the section comment above for why that is not the same as opening nothing.

WHY IT REPORTS ITSELF. Each of those outcomes looks identical on screen, so the reason goes to the
flight recorder, where a "it does nothing" report gets read.
@date 2026-09-11 23:10 ]]
local function open_transform_menu(state_doc, fontset)
    state_doc.transform_menu = nil
    local mpos = vc.ImGui_GetMousePos()
    local target = formula_under(state_doc, mpos)
    if not target then
        -- Names the RULE, not just the miss: a formula inside a text row is under the pointer and
        -- still refused, so "no formula here" would read as a bug from where the user is sitting.
        input_recorder.log_event("gesture: not over a formula cell")
        return
    end

    --[[ ON A GLYPH, OR NOWHERE. A point inside the cell but not on any glyph - the space past the
    end of the row, the gap beside a fraction bar - opens nothing at all, because the gesture has
    nothing to be about. That is a different silence from "nothing applies", which still draws its
    empty list: there the user pointed at something and the answer is empty. ]]
    local at = editor_common.formula_node_at(target.container, fontset, state_doc.font_size, mpos,
            target.hb.draw_x, target.hb.draw_y, target.hb.wrap_edge)
    if not at then
        input_recorder.log_event("gesture: no glyph under the pointer")
        return
    end

    local decls = content.declarations_before(state_doc, target.index)
    local options = ast_gestures.options(fontset, target.container, decls.order, at)
    if #options == 0 then
        input_recorder.log_event("gesture: nothing applies at that glyph")
    end

    --[[ WIDE ENOUGH TO BE A MENU even with nothing in it: an empty list still has to read as a list
    that is empty rather than as a smear on the screen, so the box keeps a minimum size instead of
    collapsing to the width of its widest entry, which is zero. ]]
    local width = MENU_MIN_W
    for _, o in ipairs(options) do
        width = math.max(width, vc.ImGui_CalcTextSize(o.label).x + 2 * MENU_PAD + 12)
    end
    state_doc.transform_menu = {x = mpos.x, y = mpos.y, w = width, options = options,
            container = target.container, index = target.index,
            version = target.container.version or 0}
end

--[[ Which row of an open menu a point is on, or nil for none. ]]
local function menu_row_at(menu, pos)
    if not pos or pos.x < menu.x or pos.x > menu.x + menu.w then
        return nil
    end
    local row = math.floor((pos.y - menu.y) / MENU_ROW_H) + 1
    if row < 1 or row > #menu.options then
        return nil
    end
    return row
end

--[[ Runs the chosen transformation and lands its result as a NEW CELL below the one it came from.

A NEW CELL, NEVER AN EDIT. A formula cell is a step in a derivation, immutable, with a link to what
it came from (docs/phase2_design.md section 1) - so a transformation adds a step rather than changing
one. The source stays exactly as it was, on screen, above its own consequence.

THE CELL CARRIES BOTH ITS TREE AND ITS TEXT. `latex` is a cell's committed truth - editor_formula
rebuilds from it whenever an edit has to be discarded - but the freshly BUILT formula is handed over
too, because that one copied its names' glyphs from the source and a rebuild from text would
re-render them. Both agree at this instant; the built one is simply the better of the two.

FOCUS MOVES WITH IT. The interaction ends where its result is, which is also what stops the menu's
own click reaching the cell it was opened over.

Returns true when a cell was made. A refusal - the tree cannot be written back yet - leaves the
document alone, keeps the pick so F6 can still show what WOULD have come out, and says why in the
recorder. That combination is deliberate: the transformation succeeded and only the drawing did not,
and those are worth telling apart.
@date 2026-09-12 03:00 ]]
local function commit_transform(state_doc, fontset, menu, option)
    local container = menu.container
    local decls = content.declarations_before(state_doc, menu.index)
    local new_root, ns, err = ast_gestures.preview(fontset, container, decls.order, option)
    if not new_root then
        input_recorder.log_event("transform: " .. option.id .. " refused: " .. tostring(err))
        return false
    end

    local sz = mexpru.u(container.root).sz or mexpru.DEFAULT_SIZE
    local built, werr = ast_mexpr.container(fontset, container.root, ns, new_root, sz)
    if not built then
        input_recorder.log_event("transform: " .. option.id
                .. " cannot be drawn yet: " .. tostring(werr))
        return false
    end

    local index = content.insert_box(state_doc, menu.index + 1, KIND_FORMULA)
    local box = state_doc.boxes[index]
    box.fml.formula = built
    box.fml.latex = mformula_latex.to_latex(built)
    --[[ THE DERIVATION LINK, and the reason the gesture is confined to formula cells: a cell knows
    which cell it came from, and prune_descendants follows that relation when the source is replaced.
    A source without an id would make an orphan, which is a root - something derived from nothing. ]]
    local source = state_doc.boxes[menu.index]
    box.fml.parent = source and source.fml and source.fml.id
    state_doc.active_index = index
    return true
end

--[[ One frame of input while the menu is open - it owns the frame, exactly as the radial does.

A CHOICE ENDS THE INTERACTION, which is the point of the menu owning the frame: the click that picks
a row must not also reach the formula underneath and move the caret there. Author, 2026-09-11: "a
click persists until a choice is made, after the choice is made the tree transform is executed".

WHAT A CHOICE DOES TODAY is record the pick and open F6 on it. The step after - building the new cell
out of the transformed tree and moving focus into it - needs `ast -> mexpr`, which does not exist yet
and was explicitly left until this half was finished. So the pick is carried as far as it can
currently go, and the panel is where it shows.
@date 2026-09-11 21:45 ]]
local function transform_menu_input(state_doc, fontset)
    local menu = state_doc.transform_menu
    menu.hover = menu_row_at(menu, vc.ImGui_GetMousePos())

    --[[ RE-AIM. The same button again does not close the menu, it asks again where the pointer is
    NOW - open_transform_menu drops the old one first, so a second click on nothing closes it and a
    second click on another glyph moves it there. Asked for that way, 2026-09-11: "re-right clocking
    should imediately reatempt to intersect a glyph/visual".

    It matters because the aim is exact: glyph boxes have real gaps between them (a subscript row
    sits below its line, a tall bracket's column is mostly empty), and a miss must cost one more
    click rather than two. ]]
    if keymap.pressed("math.transform_menu") then
        open_transform_menu(state_doc, fontset)
        return
    end

    -- Escape closes it, and so does a click that lands on no row.
    if keymap.pressed("panel.close") then
        state_doc.transform_menu = nil
        return
    end
    if vc.ImGui_IsMouseClicked("ImGuiMouseButton_Left", false) then
        local pick = menu.hover and menu.options[menu.hover]
        state_doc.transform_menu = nil
        if pick then
            --[[ The container AND its version travel with the pick: the option holds ast IDS, and
            those name nodes in the tree parsed from this container at this version. An edit moves
            the version, the ast is reparsed, and the ids no longer mean anything - so the pick is
            dropped rather than applied to a tree it was not chosen from. ]]
            state_doc.transform_pick = {container = menu.container, index = menu.index,
                    option = pick, version = menu.container.version or 0}
            --[[ The result arrives as a cell. F6 is opened only when it could NOT - there the pick
            is all there is to show, and a panel saying what would have come out beats nothing
            happening at all. ]]
            if not commit_transform(state_doc, fontset, menu, pick) then
                state_doc.show_ast_result = true
                state_doc.show_ast = false
            end
        end
    end
end

--[[ The open menu: one box, one row per option, the row under the pointer lit.
@date 2026-09-11 21:45 ]]
local function draw_transform_menu(menu)
    -- An empty list is one row tall and holds nothing - see the section comment on why it is drawn.
    local h = math.max(#menu.options, 1) * MENU_ROW_H + 2 * MENU_PAD
    vc.ImGui_AddRectFilled({x = menu.x, y = menu.y - MENU_PAD}, {x = menu.x + menu.w,
            y = menu.y + h - MENU_PAD}, MENU_BG, 3)
    vc.ImGui_AddRect({x = menu.x, y = menu.y - MENU_PAD}, {x = menu.x + menu.w,
            y = menu.y + h - MENU_PAD}, MENU_EDGE, 3, 1)
    for i, o in ipairs(menu.options) do
        local ry = menu.y + (i - 1) * MENU_ROW_H
        if menu.hover == i then
            vc.ImGui_AddRectFilled({x = menu.x + 2, y = ry - 2}, {x = menu.x + menu.w - 2,
                    y = ry + MENU_ROW_H - 2}, MENU_HOVER, 2)
        end
        vc.ImGui_AddText({x = menu.x + MENU_PAD + 6, y = ry}, MENU_TEXT, o.label)
    end
end

--[[ One frame of input for the whole document.

Core - THE PANELS COME FIRST AND SWALLOW EVERYTHING. While F1 or F2 is up, no input reaches any box
this frame, so nothing can be typed into or clicked through from behind a full-screen overlay.
Opening one closes the other rather than stacking them.

Core: after that, this decides WHICH box has the caret and hands the frame to it - box-level
routing - and owns the gestures that are about the document rather than about a formula: the radial
new-box menu, box movement, derivation, and the right-click transform menu.

Params: `pos` is where the document was last drawn, needed because every hit test here is against
the boxes the previous frame left on screen. Returns nothing; everything it does is to `state_doc`.
@date 2026-09-12 03:45 ]]
function content.handle_input(state_doc, fontset, pos)
    STATE_SHAPE.check(state_doc)
    -- F1/F2 each toggle their own full-screen panel on/off; while either is showing, every other
    -- input this frame is swallowed here (nothing forwarded to any box) so it can't be typed into
    -- or clicked through from behind the panel. Opening one closes the other, rather than letting
    -- them stack - only one overlay makes sense on screen at a time.
    if keymap.pressed("app.help") then
        state_doc.show_help = not state_doc.show_help
        state_doc.show_alt_help = false
        return
    end
    if keymap.pressed("app.customiser") then
        state_doc.show_alt_help = not state_doc.show_alt_help
        state_doc.show_help = false
        if not state_doc.show_alt_help then
            --[[ Closing drops any half-finished recording so it cannot reappear next time, and
            bumps the revision so the help page re-resolves its key names. The SAVE itself is
            main.lua's job - it watches keymap.dirty() - because this file owns no file paths, and
            because saving on close rather than per keystroke is the point: a half-typed binding
            must never reach disk. ]]
            panel_keymap.closed(state_doc.keymap_state)
            state_doc.keymap_rev = state_doc.keymap_rev + 1
        end
        return
    end
    --[[ F3 toggles the profiler (prof.lua / perf_composer.h); Shift+F3 clears its worst-frame
    record. Deliberately NOT one of the full-screen panels above and deliberately NOT `return`ing:
    the overlay has to be readable WHILE the app is being used, since the whole point is to catch a
    spike as it happens. Everything else this frame carries on as normal. ]]
    --[[ Three separate actions now (app.profiler / app.profiler_reset / app.profiler_record)
    rather than one key plus modifier tests. Each is independently rebindable, and the order below
    is unchanged from when Ctrl and Shift were read off F3 directly: record first, then reset, then
    the plain toggle. With exact matching they can no longer overlap anyway, but the order is kept
    so behaviour does not depend on that. ]]
    --[[ F4 and F6 are one slot: turning either on turns the other off. Not a general panel
    manager - just these two, because they are the pair that share a corner. ]]
    if keymap.pressed("app.ast_result") then
        state_doc.show_ast_result = not state_doc.show_ast_result
        if state_doc.show_ast_result then
            state_doc.show_ast = false
        end
        return
    end
    if keymap.pressed("app.ast") then
        state_doc.show_ast = not state_doc.show_ast
        if state_doc.show_ast then
            state_doc.show_ast_result = false
        end
        return
    end
    if keymap.pressed("app.ast_string") then
        state_doc.show_ast_string = not state_doc.show_ast_string
        return
    end
    if keymap.pressed("app.profiler_record") or keymap.pressed("app.profiler_reset")
            or keymap.pressed("app.profiler") then
        if keymap.pressed("app.profiler_record") then
            --[[ Ctrl+F3 - spike RECORDING, the mode for actually hunting a lag: it keeps running
            with the overlay hidden, so watching costs nothing and the numbers aren't the watcher's.
            Every frame over the threshold lands in PROF_SPIKE_PATH with its full breakdown and its
            event tags, flushed immediately, appended across runs. ]]
            if prof.recording() then
                prof.record_stop()
            else
                prof.record_start(PROF_SPIKE_PATH, PROF_SPIKE_MS)
            end
        elseif keymap.pressed("app.profiler_reset") then
            prof.reset()
        else
            prof.set_enabled(not prof.enabled())
        end
    end
    --[[ Escape closes whichever panel is open, as well as its own F-key. The customiser gets
    first refusal (panel_keymap.escape): while a binding is being recorded or typed, Escape means
    "abandon that", not "throw away the panel and every other uncommitted edit with it".

    Closing here does the same bookkeeping the F2 toggle does - drop any abandoned recording, bump
    the revision so the help re-resolves its key names - because main.lua's save watches
    content.customiser_open(), and a panel closed by Escape has to look exactly like one closed by
    its own key or the keymap would never reach disk. ]]
    if state_doc.show_help or state_doc.show_alt_help then
        if keymap.pressed("panel.close") then
            if state_doc.show_alt_help then
                if not panel_keymap.escape(state_doc.keymap_state) then
                    state_doc.show_alt_help = false
                    panel_keymap.closed(state_doc.keymap_state)
                    state_doc.keymap_rev = state_doc.keymap_rev + 1
                end
            else
                state_doc.show_help = false
            end
        end
        return
    end

    --[[ While the radial menu is open it owns the frame - checked here, after the F1/F2/F3 panels
    (which are more global still) but ahead of every box-facing shortcut and the whole mouse block,
    so nothing types into or clicks the box sitting behind it. ]]
    if state_doc.radial then
        radial_handle_input(state_doc)
        return
    end

    --[[ The gesture menu owns the frame the same way, and for the same reason: the click that
    chooses from it must not also reach the formula it is sitting over. Checked after the radial
    (two menus are never open at once - the radial is modal too) and ahead of every box-facing
    shortcut. ]]
    if state_doc.transform_menu then
        transform_menu_input(state_doc, fontset)
        return
    end
    if keymap.pressed("math.transform_menu") then
        open_transform_menu(state_doc, fontset)
        return
    end

    -- Ctrl+Up/Down switches which box is active (previous/next in the stack, stopping at either
    -- end rather than wrapping) - each box already remembers its own cursor/selection from when
    -- it was last active (same as clicking a different box does), so switching this way doesn't
    -- need to touch either box's own editor state_doc at all, just scroll the newly-active one into
    -- view if it wasn't already. Checked here, ahead of any box-specific handling (including
    -- whether a formula inside the active box currently owns input), so it's always available as
    -- a global shortcut, not something a formula's own plain Up/Down could ever shadow.
    --[[ Ctrl+MouseWheel zoom is a MODIFIER-GATED MOUSE gesture, not a key binding, so it asks
    keymap for the live modifier state_doc rather than owning an action of its own - there is no key
    here to rebind. keymap.mods() is the same cached read every binding match uses. ]]
    local ctrl_down = keymap.mods()
    if keymap.pressed("box.prev") then
        if state_doc.active_index and state_doc.active_index > 1 then
            state_doc.active_index = state_doc.active_index - 1
            scroll_into_view(state_doc, pos, state_doc.active_index)
        end
        return
    end
    if keymap.pressed("box.next") then
        if state_doc.active_index and state_doc.active_index < #state_doc.boxes then
            state_doc.active_index = state_doc.active_index + 1
            scroll_into_view(state_doc, pos, state_doc.active_index)
        end
        return
    end

    --[[ Ctrl+N opens the radial menu at the place the new box would appear, rather than inserting
    a text box outright the way it used to - there are three kinds now and the key cannot say which.
    Click-then-click, not drag: no mouse button is held down when it opens, so there is nothing to
    release. The menu is placed on the rail at the insertion point, then clamped on screen by
    radial_open(). Before the first draw() there is no layout to place it against, so it falls back
    to the middle of the display. ]]
    --[[ Moving a box within the stack, as opposed to moving the caret between boxes. Placed
    with the other box-level shortcuts and ahead of anything box-specific, so it works wherever
    the caret happens to be - including inside a formula, which owns input for every other key. ]]
    if keymap.pressed("box.move_up") then
        if state_doc.active_index then
            local moved = content.move_box(state_doc, state_doc.active_index, -1)
            if moved then
                state_doc.active_index = moved
                -- Followed next frame, once draw() has put the box in its new slot - see the
                -- caret-follow block at the end of this function.
                state_doc.follow_caret = -1
            end
        end
        return
    end
    if keymap.pressed("box.move_down") then
        if state_doc.active_index then
            local moved = content.move_box(state_doc, state_doc.active_index, 1)
            if moved then
                state_doc.active_index = moved
                -- Followed next frame, once draw() has put the box in its new slot - see the
                -- caret-follow block at the end of this function.
                state_doc.follow_caret = 1
            end
        end
        return
    end

    --[[ Derive a new formula box from this one. Sits with the other box-level shortcuts, and
    does nothing at all on a box that is not a formula - there is no expression to derive from. ]]
    if keymap.pressed("formula.derive") then
        if state_doc.active_index then
            local made = content.derive_identity(state_doc, state_doc.active_index)
            if made then
                state_doc.active_index = made
                state_doc.follow_caret = 1
            end
        end
        return
    end

    if keymap.pressed("box.new") then
        local index = (state_doc.active_index or #state_doc.boxes) + 1
        local disp = vc.ImGui_GetDisplaySize()
        local cx = state_doc.last_rail_x or (pos.x + RAIL_OFFSET)
        local cy = insertion_y(state_doc, index) or (disp and disp.y / 2) or pos.y
        radial_open(state_doc, index, cx, cy, false)
        return
    end

    --[[ box.close (Ctrl+W) - the keyboard counterpart of clicking a box's own "x".

    Goes through content.remove_box() rather than removing the box here, so the two routes cannot
    disagree about what closing means (the active_index fixup, dropping the stale layout).

    Focus then moves to whatever box slid into that slot - the one after it, or the last one if the
    closed box was at the end - instead of the nil remove_box() leaves behind. Clicking an "x" can
    afford to leave nothing active, because the pointer is already somewhere and the user is looking
    at it; a keyboard close has no pointer, and landing with no active box means the next keystroke
    goes nowhere at all.

    NOT undoable, exactly like the "x" button: undo lives inside each editor, so removing a whole
    box takes its history with it. ]]
    if keymap.pressed("box.close") and state_doc.active_index then
        local closing = state_doc.active_index
        content.remove_box(state_doc, closing)
        if #state_doc.boxes > 0 then
            state_doc.active_index = math.min(closing, #state_doc.boxes)
        end
        return
    end

    -- Mouse wheel scrolls the whole stack, UNLESS Ctrl is held, in which case it zooms instead
    -- (state_doc.font_size - a char.lua size-table INDEX, not a pixel size, see DEFAULT_FONT_SIZE's own
    -- comment) - global, same as show_wireframe, not tied to whichever box the mouse happens to be
    -- over. One size-table step per wheel notch, not scaled by SCROLL_SPEED - these are
    -- discrete levels, not pixels, and a raw multi-unit wheel event (e.g. a fast trackpad flick)
    -- would otherwise jump several steps at once. Positive wheel (away from the user, the usual
    -- "scroll up"/"zoom in" gesture) should make text BIGGER, i.e. walk the table towards index 1 -
    -- opposite sign from the scroll case just below, where positive wheel decreases scroll_y.
    local wheel = vc.ImGui_GetMouseWheel()
    if wheel ~= 0 and ctrl_down then
        local step = wheel > 0 and -1 or 1
        local new_size = math.max(MIN_FONT_SIZE, math.min(MAX_FONT_SIZE,
                state_doc.font_size + step))
        if new_size ~= state_doc.font_size then
            state_doc.font_size = new_size
            -- mexpru.set_zoom() first (mexpru.physical_sz()'s own comment: one global value the
            -- whole app reads) - THEN rescale every box's every formula so already-typed content
            -- visually catches up too, not just brand-new typing (editor.rescale()'s own comment).
            -- Global, not just the active box - confirmed.
            mexpru.set_zoom(state_doc.font_size - DEFAULT_FONT_SIZE)
            for _, box in ipairs(state_doc.boxes) do
                -- Every box kind that holds formulas has to catch up, not just text boxes -
                -- a definition box's slots are formulas too.
                if box.editor then
                    editor.rescale(box.editor, fontset)
                end
                if box.def then
                    editor_definition.rescale(box.def, fontset)
                end
                if box.fml then
                    editor_formula.rescale(box.fml, fontset)
                end
            end
        end
        return
    end

    -- Mouse wheel scrolls the whole stack. Clamped against LAST frame's own total height (this
    -- frame's real one isn't known until draw() runs) and the CURRENT viewport - a frame of lag
    -- on the clamp bound itself is imperceptible, and self-corrects continuously every frame
    -- scrolling actually happens, so it never drifts. Positive wheel (away from the user) is the
    -- usual "scroll up" gesture - it should reveal content ABOVE, i.e. decrease scroll_y.
    if wheel ~= 0 then
        local viewport_h = math.max(0, vc.ImGui_GetDisplaySize().y - pos.y)
        local max_scroll = math.max(0, state_doc.last_total_height - viewport_h)
        state_doc.scroll_y = math.max(0, math.min(max_scroll,
                state_doc.scroll_y - wheel * SCROLL_SPEED))
    end

    local clicked = vc.ImGui_IsMouseClicked("ImGuiMouseButton_Left", false)
    if clicked and state_doc.last_layout then
        local mpos = vc.ImGui_GetMousePos()

        for i, r in ipairs(state_doc.last_layout) do
            if r.close and point_in_rect(mpos.x, mpos.y, r.close.x, r.close.y, r.close.w, r.close.h) then
                content.remove_box(state_doc, i)
                return
            end
            if r.wireframe_btn and point_in_rect(mpos.x, mpos.y, r.wireframe_btn.x,
                    r.wireframe_btn.y, r.wireframe_btn.w, r.wireframe_btn.h) then
                state_doc.show_wireframe = not state_doc.show_wireframe
                return
            end
            if r.graph_btn and point_in_rect(mpos.x, mpos.y, r.graph_btn.x, r.graph_btn.y,
                    r.graph_btn.w, r.graph_btn.h) then
                state_doc.show_graph = not state_doc.show_graph
                return
            end
        end

        local hit = nil
        for i, r in ipairs(state_doc.last_layout) do
            if point_in_rect(mpos.x, mpos.y, r.x, r.y, r.w, r.h) then
                hit = i
                break
            end
        end
        if hit then
            state_doc.active_index = hit
        elseif state_doc.last_rail_x and math.abs(mpos.x - state_doc.last_rail_x) <= RAIL_CLICK_RADIUS then
            --[[ A press on the rail opens the radial menu instead of inserting a text box outright.
            from_drag = true, so the gesture is press-drag-release: the menu lives exactly as long as
            the button is held. Releasing without leaving the centre cancels, which makes a plain
            click on the rail a no-op rather than a surprise box. ]]
            radial_open(state_doc, insertion_index_for_y(state_doc, mpos.y), mpos.x, mpos.y, true,
                    mpos.x, mpos.y)
            return
        else
            state_doc.active_index = nil
        end
    end

    --[[ `active.editor` rather than just `active`: a formula/definition placeholder CAN become the
    active box by being clicked (it is a box like any other for selection purposes), and it has no
    editor to forward input to. That is what "no controls for now" means in practice - it takes
    focus and then does nothing with it.

    THE CLICK THAT ACTIVATES A BOX IS ALSO THE CLICK THAT PLACES ITS CARET. These three branches
    were guarded by `not activating`, so a click landing on a box that was not already active
    selected the box and THREW THE CLICK AWAY - the editor never saw it, and the caret stayed
    wherever that box had left it. The screen then appeared to jump, because the draw scrolls the
    caret into view and the caret was not where the click was.

    It reproduced most obviously right after Ctrl+R, since a reloaded state_doc has no active box at
    all, which makes the FIRST click on anything an activation. Reported live, 2026-09-10: "click on
    the bottom side of the screen moves the screen something else and the cursor doesn't get placed
    where I've clicked it".

    Nothing was being protected by the guard. It arrived undocumented with the original port of the
    editor into Lua and was never explained; the box's chrome (close, wireframe, graph) returns
    before this point, `active` already names the newly clicked box rather than the old one, and a
    click on empty space clears the selection instead of reaching here. What is left is exactly the
    case that should be forwarded. ]]
    local active = state_doc.active_index and state_doc.boxes[state_doc.active_index]
    if active and active.editor then
        editor.handle_input(active.editor, fontset, state_doc.font_size)
    elseif active and active.def then
        editor_definition.handle_input(active.def, fontset, state_doc.font_size)
    elseif active and active.fml then
        --[[ A true return means the box was pasted into: its content was replaced and its parent
        link dropped. Everything derived from it followed from the OLD content, so it goes. ]]
        if editor_formula.handle_input(active.fml, fontset, state_doc.font_size) then
            content.prune_descendants(state_doc, active.fml.id)
        end
    end

    -- Whenever the active box's own caret actually MOVED this frame - typing/Enter growing the
    -- box, arrow-key movement, or a formula's internal cursor stepping through it - and its new
    -- position sits outside the viewport, scroll just enough to bring it back in. Gated on an
    -- actual move (via cursor_sig() below), not run unconditionally every frame: otherwise this
    -- would fight a deliberate manual scroll-away (mouse wheel, or just leaving a box active while
    -- looking at another one further down) every single frame even though the caret itself never
    -- moved - only a real move should ever pull the view back to it.
    --[[ A formula or definition box has no text caret to follow, so a move of one falls back to
    its own top edge. Checked before the caret branch, which would otherwise leave follow_caret
    set forever on a box that can never satisfy it. ]]
    if state_doc.follow_caret and not (active and active.editor and active.editor.last_cursor_y) then
        if state_doc.active_index then
            scroll_into_view(state_doc, pos, state_doc.active_index)
        end
        state_doc.follow_caret = nil
    end

    if active and active.editor and active.editor.last_cursor_y then
        local a, b, c = cursor_sig(active.editor)
        local ed = active.editor
        local had_prior = ed._cursor_sig_c ~= nil
        local moved = had_prior and (a ~= ed._cursor_sig_a or b ~= ed._cursor_sig_b or c ~= ed._cursor_sig_c)
        ed._cursor_sig_a, ed._cursor_sig_b, ed._cursor_sig_c = a, b, c
        --[[ `follow_caret` is a box MOVE asking to be followed, and it is honoured even though
        the caret itself did not move: the box moved out from under it. It cannot be done at the
        moment of the move, because the caret's screen position then still describes the slot the
        box just left - draw() has to run once before last_cursor_y means anything again. One
        frame of lag, which is the same bargain scroll_into_view() and the mouse wheel already
        make with last_layout. ]]
        --[[ A CARET MOVE IS FOLLOWED ONE FRAME LATER, never on the frame it happens.

        `last_cursor_y` is written by draw(), so during handle_input it still describes where the
        caret WAS. Scrolling to it the moment the caret moves therefore scrolls to the old position
        - which is invisible for an arrow key, where old and new are one line apart, and violent for
        a click, where they can be the whole document apart.

        That is what this looked like live, 2026-09-10: a box whose caret sat at its end, off the
        bottom of the screen; a click near the top of it scrolled the view to the END instead, and
        then - because the button was still held - the drag branch mapped the unmoved pointer onto
        the newly scrolled text and dragged out a selection from one to the other. "it jumps my
        window down, selects a bunch of text and the cursor gets near the unions at the end".

        The rule was already written down for the OTHER case that hits it: `follow_caret` (a box
        MOVE) is deliberately deferred, "because the caret's screen position then still describes
        the slot the box just left - draw() has to run once before last_cursor_y means anything
        again". A caret move needs the same treatment for the same reason.

        SCROLL FIRST, THEN ARM. Reading the flag before setting it is what keeps a held arrow key
        scrolling every frame: each frame follows the PREVIOUS frame's move against a
        `last_cursor_y` that has since been redrawn, which is the one-frame bargain this file makes
        everywhere else. Setting first would leave a continuous move never satisfying its own flag.
        @date 2026-09-11 00:40 ]]
        local follow = state_doc.follow_caret
        if follow then
            scroll_span_into_view(state_doc, pos, active.editor.last_cursor_y,
                    active.editor.last_cursor_h or 0, follow * MOVE_FOLLOW_LEAD)
        elseif ed._scroll_to_caret then
            scroll_span_into_view(state_doc, pos, active.editor.last_cursor_y,
                    active.editor.last_cursor_h or 0, 0)
        end
        ed._scroll_to_caret = moved or nil
        state_doc.follow_caret = nil
    end
end

-- #################################################################################################
-- Layout / render
-- #################################################################################################

--[[ The profiler overlay (F3 - prof.lua / perf_composer.h). A translucent panel in the top-right
corner, NOT one of the full-screen panels below: the whole reason it exists is to be readable while
the app is being used, since a lag spike is over before anyone can switch views to look at it.

Text comes back from C++ already formatted and sorted (prof_report()) and is just split on newlines
here - the overlay never does arithmetic of its own, so there is only one place where "what a
millisecond means" is decided.
@date 2026-09-08 08:30 ]]
local PROF_BG_COLOR   = 0xdd101010
local PROF_TEXT_COLOR = 0xffd0ffd0
local PROF_LINE_H     = 15
local PROF_WIDTH      = 430

--[[ The formula the caret is actually in, whichever kind of box holds it - or nil.

Each box kind keeps its live container somewhere different, which is why this exists rather than
the viewer reaching in: a formula box holds one outright, a text box holds whichever embedded
formula currently owns input (nil while typing plain text), and a definition box holds a list of
slots with `current` saying which has the caret. `current` is negative while the caret is on a
DERIVED row - the shorthand or the computed name - which is not an editable expression, hence the
`> 0`.
@date 2026-09-10 05:10 ]]
local function active_expression(state_doc)
    local box = state_doc.active_index and state_doc.boxes[state_doc.active_index]
    if not box then
        return nil
    end
    if box.fml then
        return box.fml.formula
    end
    if box.editor then
        return box.editor.active_formula
    end
    if box.def and box.def.slots and box.def.current and box.def.current > 0 then
        return box.def.slots[box.def.current]
    end
    return nil
end

--[[ F4: what the parser made of the expression the caret is in, as a cascade.

An instrument for building the expression parser, not a feature for reading documents - which is
why it shows the parse rather than the formula, and why it says `<expr>` for anything not parsed
yet instead of a shape that has not been earned (mexpr_ast.describe's own comment).

Anchored BOTTOM-RIGHT rather than top-right like the profiler: boxes grow downward from the top
left, so this is the corner least likely to sit over what is being edited. With F3 also on the two
do not overlap for the same reason.
@date 2026-09-10 05:10 ]]
local AST_BG_COLOR   = 0xdd101010
local AST_TEXT_COLOR = 0xffd0d0ff
local AST_LINE_H     = 15
local AST_WIDTH      = 430

--[[ WHAT EACH PIECE OF AN F5 LINE IS PAINTED. 0xAABBGGRR, like every colour in this file, so the
literals read back-to-front: 0xff60e060 is a GREEN, 0xff5050ff a RED, 0xffffb050 a BLUE.

    op_sym     the ^, +, *, =, I, S ...             red
    bind_sym   the # of a declaration, & of a ref   blue
    var_name   the name a declaration declares      green
    ref_name   what a reference resolves to         green
    num_value  what a number cell actually is       yellow

Blue and green are the VARIABLES, red is what is done to them, yellow is a constant - see
to_string_lines, which is where the roles are assigned and where that reasoning lives. This table
only says what a role LOOKS like, which is the one part of it that belongs to a debug overlay.

SHARED BY BOTH VIEWS. F4 tags its lines with the same roles (mexpr_ast's `render`), so the two
debug panels cannot drift into meaning different things by the same colour - asked for 2026-09-11:
"miror those colors (those for the operator into f4)". ]]
local AST_INDENT = 16

local AST_ROLE_COLOR = {
    op_sym    = 0xff5050ff,
    bind_sym  = 0xffffb050,
    var_name  = 0xff60e060,
    ref_name  = 0xff60e060,
    num_value = 0xff40e0ff,
}

--[[ Paints one line's coloured pieces left to right, measuring as it goes. Shared by F4 and F5,
which is the point: one layout, one colour table, two panels. A line with no pieces - the "no
expression here" and "no tree" messages - is drawn whole in the ordinary text colour.
@date 2026-09-11 06:00 ]]
local function draw_ast_line(l, lx, ly)
    if not l.parts then
        vc.ImGui_AddText({x = lx, y = ly}, AST_TEXT_COLOR, l.text)
        return
    end
    --[[ Measured rather than padded to columns: the pieces vary in width by a lot (a "(" against a
    name), and any fixed column would either overlap the long ones or strand the short ones. ]]
    local px = lx
    for _, piece in ipairs(l.parts) do
        vc.ImGui_AddText({x = px, y = ly}, AST_ROLE_COLOR[piece.role] or AST_TEXT_COLOR, piece.text)
        px = px + vc.ImGui_CalcTextSize(piece.text).x
    end
end

--[[ One debug panel: a backing rectangle, a title, and the lines under it, anchored to the
BOTTOM of the screen so it grows upward as it gets longer.

THE THREE OF THEM WERE THE SAME CODE - F4, F5 and F6 each computed the same rectangle, drew the same
title and ran the same loop, differing only in where they sit and what they list. Author,
2026-09-11: "more small functions not repeated the better". Three copies of a layout is three places
to fix a spacing change, and the third copy was added the same afternoon as the note.

WHAT STAYS WITH THE CALLER: its own `x` and `width`. F5 measures its widest line because its tuples
have no fixed column, while F4 and F6 sit in a fixed one - that is a real difference between them
and folding it in here would need a flag, which is the thing this is trying not to grow.
@date 2026-09-11 20:40 ]]
local function draw_ast_panel(x, width, title, lines)
    local size = vc.ImGui_GetDisplaySize()
    local h = (size and size.y or 720)
    local y = h - (#lines + 2) * AST_LINE_H - 12

    vc.ImGui_AddRectFilled({x = x - 8, y = y - 8}, {x = x + width,
            y = y + (#lines + 1) * AST_LINE_H + 4}, AST_BG_COLOR, 4)
    vc.ImGui_AddText({x = x, y = y}, AST_TEXT_COLOR, title)
    for i, l in ipairs(lines) do
        draw_ast_line(l, x + l.depth * AST_INDENT, y + i * AST_LINE_H)
    end
end

local function draw_ast_overlay(state_doc, fontset)
    local container = active_expression(state_doc)
    local lines
    if not container then
        lines = {{depth = 0, text = "no expression here - put the caret in a formula"}}
    else
        local decls = content.declarations_before(state_doc, state_doc.active_index)
        -- .order, not .by_text: resolution WALKS the candidates, since a use site cannot build
        -- the key it would otherwise be looked up by (mexpr_ast.match_use).
        lines = mexpr_ast.describe(fontset, container, decls.order)
    end

    local size = vc.ImGui_GetDisplaySize()
    local w = (size and size.x or 1280)
    draw_ast_panel(w - AST_WIDTH - 12, AST_WIDTH, "F4  parse of the current expression", lines)
end

--[[ WHAT F6 IS LOOKING AT: the expression, the box it sits in, and the transformation chosen for
it - or the caret's expression and no transformation when no choice stands.

THE CHOICE CARRIES ITS OWN EXPRESSION, and that is the whole point of returning all three together.
A gesture does not need the caret: it can be made on a formula the caret left, or in another box
entirely. Reading the subject off the caret instead is what made a successful pick display "no
expression here - put the caret in a formula", which reads exactly like the gesture having failed.

A PICK EXPIRES when the expression it was chosen from changes: its ast ids name nodes in the tree as
it was parsed then, and an edit reparses it into different ones. Clearing rather than merely ignoring
it means a stale choice cannot come back to life later - it was made about a tree that no longer
exists.
@date 2026-09-11 22:30 ]]
local function result_subject(state_doc)
    local pick = state_doc.transform_pick
    if pick then
        if pick.container and pick.version == (pick.container.version or 0) then
            return pick.container, pick.index, pick.option
        end
        state_doc.transform_pick = nil
    end
    return active_expression(state_doc), state_doc.active_index, nil
end

--[[ F6: the tree a transformation would produce HERE, drawn like F5's.

WHY A PREVIEW RATHER THAN A HISTORY. There is nowhere yet to apply a transformation from - the
right-click menu is not wired - so this answers the same question one step earlier: given where the
caret is, what WOULD come out. That makes it useful while transforms are being written, which is
what it is for, and it becomes the result panel unchanged once a menu can set one.

SHARES F5's RENDERER, deliberately: the same one-node-per-line split, the same colours, so the two
trees are compared by reading rather than by translating between two formats. Only the source of the
tree differs.

WHICH transformation: the one a right-click CHOSE, while that choice still names the expression on
screen; otherwise the first one `ast_gestures` offers at the caret. The fallback is what makes the
panel useful with no gesture at all - it previews what a click where the caret is would do - and the
choice takes precedence because it is the more specific answer to the same question.
@date 2026-09-11 21:45 ]]
local function draw_ast_result_overlay(state_doc, fontset)
    local lines
    local container, index, option = result_subject(state_doc)
    if not container then
        lines = {{depth = 0, text = "no expression here - put the caret in a formula"}}
    else
        local decls = content.declarations_before(state_doc, index)
        local root, _, err = ast_gestures.ast_for(fontset, container, decls.order)
        if not root then
            lines = {{depth = 0, text = "no tree: " .. tostring(err)}}
        else
            if not option then
                --[[ THE CARET, not the mouse: with no choice made this is a keyboard panel, so the
                place it asks about is where the cursor is. The same resolution a click uses, just
                given a different node. ]]
                local at = container.cursor_pos and container.cursor_pos:get_obj()
                local opts = at and ast_gestures.options(fontset, container, decls.order, at) or {}
                option = opts[1]
            end
            if not option then
                lines = {{depth = 0, text = "no transformation applies where the caret is"}}
            else
                local new_root, ns, terr = ast_gestures.preview(fontset, container, decls.order,
                        option)
                if not new_root then
                    lines = {{depth = 0, text = option.id .. " refused: " .. tostring(terr)}}
                else
                    lines = ast.to_string_lines(ns, new_root)
                    table.insert(lines, 1, {depth = 0, text = "-- " .. option.label})
                end
            end
        end
    end

    local size = vc.ImGui_GetDisplaySize()
    local w = (size and size.x or 1280)
    draw_ast_panel(w - AST_WIDTH - 12, AST_WIDTH,
            "F6  what a transformation would produce", lines)
end

--[[ F5: the RAW ast.lua serialization of the same expression F4 parses - ast.to_string's own
`(symbol, child1, child2, ...:id)` tuple text, not the indented tree `render()` builds for F4. Where
F4 is a reading aid, F5 is the ground truth it is read FROM - the tool for exactly the question F4
cannot answer, like whether a name is showing up somewhere it should be an id instead (a CALL's own
callee, today - see docs/phase2_design.md section 10, "The id is the real name").

Hard-wrapped by character count rather than measured text width: this is a debug instrument, not
typeset output, and `ast.to_string`'s tuples have no natural break points to wrap on anyway.

Anchored BOTTOM-LEFT, the one corner F3 (top-right) and F4 (bottom-right) leave free.
@date 2026-09-10 ]]
local AST_STR_WIDTH = 480

local function draw_ast_string_overlay(state_doc, fontset)
    local container = active_expression(state_doc)
    local lines
    if not container then
        lines = {{depth = 0, text = "no expression here - put the caret in a formula"}}
    else
        local decls = content.declarations_before(state_doc, state_doc.active_index)
        local node, err, ns = mexpr_ast.build(fontset, container, decls.order)
        if not node then
            lines = {{depth = 0, text = "no tree: " .. tostring(err)}}
        else
            --[[ One node per line, indented by depth, rather than one hard-wrapped run of tuple
            text. The flat form was unreadable the moment a tree had any depth at all - a wrap could
            land anywhere, including mid-id - and it hid the very structure the view is consulted
            for. ast.to_string_lines is the split, and lives beside to_string so the two agree. ]]
            lines = ast.to_string_lines(ns, node)
        end
    end

    --[[ Wide enough for the deepest line, since the tuples no longer wrap to a fixed column.
    Measured off `text`, which is every piece concatenated - so this stays one measurement however
    many colours a line ends up in. ]]
    local width = AST_STR_WIDTH
    for _, l in ipairs(lines) do
        local w = l.depth * AST_INDENT + vc.ImGui_CalcTextSize(l.text).x + 24
        if w > width then
            width = w
        end
    end

    -- Bottom-LEFT, the one corner F3 (top-right) and F4/F6 (bottom-right) leave free.
    draw_ast_panel(12, width, "F5  ast.lua serialization", lines)
end

local function draw_prof_overlay()
    --[[ The overlay measures ITSELF. prof_report() formats a few dozen lines in C++ and this then
    issues an AddText per line, every frame it is visible - not free, and a profiler that quietly
    charged its own cost to whatever it was sitting inside would misattribute exactly the spikes it
    exists to find. Reported as lua.prof_overlay so it can be subtracted by eye. ]]
    prof.begin("lua.prof_overlay")
    local report = prof.report()
    local lines = {}
    for line in (report .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = line
    end

    local size = vc.ImGui_GetDisplaySize()
    local x = (size and size.x or 1280) - PROF_WIDTH - 12
    local y = 12
    vc.ImGui_AddRectFilled({x = x - 8, y = y - 8}, {x = x + PROF_WIDTH,
            y = y + #lines * PROF_LINE_H + 8}, PROF_BG_COLOR, 4)
    for i, line in ipairs(lines) do
        vc.ImGui_AddText({x = x, y = y + (i - 1) * PROF_LINE_H}, PROF_TEXT_COLOR, line)
    end
    local rec = prof.recording()
            and string.format("REC -> %s  (%d spikes >%.0fms)", PROF_SPIKE_PATH,
                    prof.spike_count(), PROF_SPIKE_MS)
            or "Ctrl+F3 record spikes to file"
    vc.ImGui_AddText({x = x, y = y + #lines * PROF_LINE_H - PROF_LINE_H + 2}, PROF_TEXT_COLOR,
            "F3 off   Shift+F3 clear worst   " .. rec)
    prof.stop("lua.prof_overlay")
end

--[[ A box's own CHROME: the coloured fill, the focus border, the connector out to the rail and
the close "x". Everything about a box that is not its content.

Split out of content.draw()'s layout loop 2026-09-07 so the F1 help can draw a real example box
rather than a hand-made imitation of one. That is the whole point of it being a function: the help
shows what the editor actually paints, so a change to the box style reaches the documentation on
the same commit and cannot silently drift out of date.

`rail_x` nil draws no connector (the help's standalone examples), otherwise the node and the line
to it are drawn as in the document. Returns the close button's rect, which the real caller stores
in its layout for hit-testing and the help simply ignores.
@date 2026-09-08 08:30 ]]
function content.draw_box_chrome(box_x, box_y, box_w, box_h, kind, is_active, rail_x)
    local kind_colors = KIND_COLORS[kind or KIND_TEXT] or KIND_COLORS[KIND_TEXT]
    vc.ImGui_AddRectFilled({x=box_x, y=box_y}, {x=box_x + box_w, y=box_y + box_h},
            kind_colors.fill, 6)
    vc.ImGui_AddRect({x=box_x, y=box_y}, {x=box_x + box_w, y=box_y + box_h},
            is_active and BOX_ACTIVE_COLOR or BOX_BORDER_COLOR, 6, is_active and 2 or 1)

    -- Connector: a node on the rail, and a line from it to the box.
    if rail_x then
        local node_y = box_y + 20
        vc.ImGui_AddCircle({x=rail_x, y=node_y}, NODE_RADIUS, RAIL_COLOR, 1)
        vc.ImGui_AddLine({x=rail_x, y=node_y}, {x=box_x, y=node_y}, RAIL_COLOR, 1)
    end

    -- Close button: a small "x" sitting just above the box's top-right corner.
    local close = {x=box_x + box_w - CLOSE_SIZE, y=box_y - CLOSE_SIZE - 2, w=CLOSE_SIZE,
            h=CLOSE_SIZE}
    vc.ImGui_AddRect({x=close.x, y=close.y}, {x=close.x+close.w, y=close.y+close.h}, RAIL_COLOR, 3,
            1)
    local pad = 4
    vc.ImGui_AddLine({x=close.x+pad, y=close.y+pad}, {x=close.x+close.w-pad,
            y=close.y+close.h-pad}, CLOSE_COLOR, 2)
    vc.ImGui_AddLine({x=close.x+close.w-pad, y=close.y+pad}, {x=close.x+pad,
            y=close.y+close.h-pad}, CLOSE_COLOR, 2)
    return close
end

--[[ Draws the radial new-box menu at an arbitrary point, for the F1 help.

Goes through the SAME draw_radial_at() the live menu uses - the fields it reads are exactly the
four this builds, and nothing about the wedges, colours or geometry is restated here. If the menu
gains a fourth sector or changes colour, the help picture changes with it.

`hover` names a sector to light up (content.box_kinds() supplies the names), or nil for none. The
result is inert by construction: this only draws, and the menu's behaviour lives entirely in
radial_handle_input(), which the help never calls.
@date 2026-09-08 08:30 ]]
function content.draw_demo_radial(cx, cy, hover)
    draw_radial_at({cx = cx, cy = cy, hover = hover, selected = nil, over_center = false})
end

--[[ How much room a drawn menu needs around its centre - the help uses it to reserve space
without knowing the geometry. @date 2026-09-08 08:30 ]]
function content.radial_extent()
    return RADIAL_OUTER_HOVER
end

--[[ The kinds, in the order the radial menu offers them, for the help's own example. Exposed
rather than duplicated so a fourth kind appears in the documentation automatically. @date 2026-09-08 08:30 ]]
function content.box_kinds()
    return {KIND_TEXT, KIND_FORMULA, KIND_DEFINITION}
end

--[[ THE `decls` CONTAINER - what names are in scope at a box, and THE ONE CREATOR for it.

WHERE `decls` COMES FROM, since it is passed through four files and created in none of them: here.
Everything downstream - mexpr_ast.build, ast_gestures, the transform menu - receives `.order` from
this call and never builds one. Each entry is editor_definition.declaration()'s table:

    text     the pattern as serialized text, which is the KEY a use resolves against
    name     the declared name on its own
    arity    how many arguments it takes
    tokens   the pattern's token list, carried rather than re-split from `text` - resolving a use
             walks two token lists position by position, and splitting the string again would be a
             second, drifting definition of what a token is
    groups   its argument groups, carried for the same reason
    box_index which box declared it, added here

The container itself is {by_text, order}: the same accepted declarations twice, keyed for lookup
and ordered for iteration, because a resolver wants the lookup and a person reading the document
wants the sequence.

SCOPE IS DOCUMENT POSITION, and that is the whole rule: a box sees the definitions above it and
nothing else. Author, 2026-09-10: "the definition module should know to provide all the definitions
for the boxes above an i'th box, the idea is that later definitions will be unknown". So a document
reads top to bottom the way a proof does - a name means what it meant where it was used, and
inserting a definition cannot silently change the meaning of everything above it.

STRICTLY above: box `index` does not see its own declaration. A definition that could refer to
itself is a different feature (recursion) and needs to be asked for deliberately rather than falling
out of an off-by-one here.

REDECLARATION: a later box wins, because the walk goes downward and overwrites. That makes the
answer well-defined rather than correct - whether shadowing should be allowed at all, or reported as
a conflict the way keymap.conflicts() reports one, is open. It is written down here so the next
reader knows it was chosen rather than stumbled into.

WHAT WAS WRITTEN IS NOT WHAT IS IN SCOPE - see the note inside.
@date 2026-09-12 05:10 ]]
function content.declarations_before(state_doc, index)
    STATE_SHAPE.check(state_doc)
    local by_text, order = {}, {}
    local written = {}
    for i = 1, math.min((index or (#state_doc.boxes + 1)) - 1, #state_doc.boxes) do
        local box = state_doc.boxes[i]
        local decl = box and box.def and editor_definition.declaration(box.def)
        if decl then
            decl.box_index = i
            written[#written + 1] = decl
        end
    end

    --[[ WHAT WAS WRITTEN IS NOT WHAT IS IN SCOPE. A definition that overlaps an earlier one, or
    contains one, is refused rather than added (mexpr_ast.check_declarations) - and the refusal
    matters to everything downstream, not only to the person who wrote it: the use site decides
    whether a decorated group is an argument or part of a name by asking whether anything answers
    to it, and that answer is only reliable while those rules hold.

    The earlier definition wins, which is the same rule as this function's own: a name means what
    was said above it. ]]
    local checked = mexpr_ast.check_declarations(written)
    for _, decl in ipairs(checked.accepted) do
        by_text[decl.text] = decl
        order[#order + 1] = decl
    end
    return {by_text = by_text, order = order}
end

--[[ Draws the whole document: every box stacked down from `pos`, each connected to the rail, with
the derivation curves between formula boxes - or, while a panel is open, that panel instead.

A panel covers the whole display, so nothing underneath shows or can be mistaken for something
still live; handle_input() backs that up by having already returned for the frame. The profiler
overlay is drawn on top of either, because a lag spike is over before anyone could switch views.

Records the layout it drew (`state_doc.last_layout`, `last_rail_x`,
        `last_total_height`) for the next
frame's hit-testing and scroll clamping - one frame of lag, which is the bargain every mouse-facing
helper here already makes.

  pos   the document's top-left, before scrolling
  opts  {max_width = n} to lay out narrower than the window, which the F1 help's examples use
@date 2026-09-08 08:30 ]]
function content.draw(state_doc, fontset, pos, opts)
    STATE_SHAPE.check(state_doc)
    --[[ Drawn LAST, on top of everything, including the F1/F2 panels - so opening one of those
    doesn't take the numbers away mid-investigation. Hence the flag rather than a straight call:
    the early returns below would otherwise skip it. ]]
    local function overlay()
        if prof.overlay_visible() then
            draw_prof_overlay()
        end
        if state_doc.show_ast then
            --[[ pcall: this runs the PARSER every frame on whatever is being typed, which is
            half-written by definition. A throw here would take the document's draw with it, and an
            inspection tool that can crash the thing it inspects is worse than no tool. ]]
            local ok, err = pcall(draw_ast_overlay, state_doc, fontset)
            if not ok then
                vc.ImGui_AddText({x = 24, y = 4}, 0xaa3c3cff, "F4: " .. tostring(err))
            end
        end
        if state_doc.show_ast_result then
            -- Same pcall reasoning as F4/F5: this builds a tree AND runs a transform on it, either
            -- of which may be mid-edit and incomplete.
            local ok, err = pcall(draw_ast_result_overlay, state_doc, fontset)
            if not ok then
                vc.ImGui_AddText({x = 24, y = 36}, 0xaa3c3cff, "F6: " .. tostring(err))
            end
        end
        if state_doc.show_ast_string then
            -- Same reasoning as F4's own pcall - ast.to_string walks a freshly-built, possibly
            -- half-typed tree every frame this is open.
            local ok, err = pcall(draw_ast_string_overlay, state_doc, fontset)
            if not ok then
                vc.ImGui_AddText({x = 24, y = 20}, 0xaa3c3cff, "F5: " .. tostring(err))
            end
        end
    end

    --[[ F1 is the help page, F2 the keybind customiser. They swapped roles 2026-09-07: F2 used to
    be the Alt+glyph legend, which is now a chapter of the help instead, and F1 used to be the flat
    key list, which the help page replaces by resolving key names out of the registry as it draws.

    Both own the whole screen, and handle_input() has already returned early for this frame, so the
    panels can use real ImGui widgets without the editor underneath reacting to the same clicks.
    The profiler overlay still goes on top of either - it has to stay readable while the app is in
    use, which is the whole reason it exists. ]]
    if state_doc.show_help then
        panel_help.draw(state_doc.help_state, state_doc.keymap_rev, fontset)
        overlay()
        return
    end
    if state_doc.show_alt_help then
        panel_keymap.draw(state_doc.keymap_state)
        overlay()
        return
    end

    local display_size = vc.ImGui_GetDisplaySize()
    local viewport_top = pos.y
    local viewport_bottom = display_size and display_size.y or (pos.y + 700)

    local layout = {}
    local content_start_y = pos.y - state_doc.scroll_y
    local y = content_start_y
    local rail_x = pos.x + RAIL_OFFSET
    local box_x = pos.x + BOX_LEFT
    -- A box spans the full width available to it, stopping RIGHT_MARGIN short of the display's own
    -- right edge - and that margin MATCHES the gap on the left between the rail and the box
    -- (BOX_LEFT - RAIL_OFFSET), so the content sits in an evenly inset column rather than being
    -- noticeably tighter on one side. Reported live: "the content box stopped extending
    -- to the end of the window (not glued, but with a space (similar to the space from the content
    -- box to the vertical line))".
    local RIGHT_MARGIN = BOX_LEFT - RAIL_OFFSET
    --[[ ... plus the derivation-curve gutter, so a curve leaving a box's right edge has room to
    bow out and come back without leaving the window. ]]
    --[[ `opts.max_width` caps how wide a box may get. The document itself never passes it - a box
    is as wide as the column allows, which is the whole point of the width rule above - but the F1
    help draws a real miniature document inside its own page, where "as wide as the display" would
    run straight off the edge of the text column it sits in. ]]
    local max_box_w = display_size
            and math.max(BOX_WIDTH, display_size.x - box_x - RIGHT_MARGIN - CURVE_GUTTER)
            or BOX_WIDTH
    if opts and opts.max_width then
        max_box_w = math.min(max_box_w, opts.max_width)
    end

    for i, box in ipairs(state_doc.boxes) do
        local box_y = y
        local is_active = (state_doc.active_index == i)

        local cached = state_doc.last_layout and state_doc.last_layout[i]
        local cached_h = cached and cached.h
        --[[ Every box is simply as wide as the column allows - the full width out to RIGHT_MARGIN,
        never sized to its own content.

        It used to grow from the content instead, fed by LAST frame's measured need. Two things were
        wrong with that at once. The width was a feedback loop (the width granted becomes
        editor.draw()'s width_limit, which decides where things WRAP, which decides the width
        needed), and editor.lua was reporting one FORMULA_MARGIN more than it had been given, so the
        loop had no fixed point at all: it climbed a margin per round until it hit this same cap.
        That is the "converging to the new size" resize - and also why boxes LOOKED full-width, which
        is what stopping the climb then took away ("the content box stopped extending to the end of
        the window"). The margin bug is fixed in editor.lua either way; taking the width straight
        from the column makes the loop moot, since the answer never depended on the content.

        Content wider than the column is not a reason to widen the box - it wraps (mformula's own
        wrap_edge), and the box grows DOWNWARD via content_h below. ]]
        local box_w = max_box_w
        local content_w = box_w - 2 * BOX_PADDING
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
            --[[ A box with no editor (formula/definition, for now) has no content to measure and
            nothing to draw inside it - it is a fixed-height coloured rectangle. See
            content.insert_box's own comment on why the check is `box.editor` and not `box.kind`. ]]
            local box_h
            if box.editor then
                local content_h = editor.draw(box.editor, fontset, {x=box_x + BOX_PADDING,
                        y=box_y + BOX_PADDING}, state_doc.font_size,
                                content_w, is_active,
                        state_doc.show_wireframe, state_doc.show_graph)
                box_h = math.max((content_h or 0) + 2 * BOX_PADDING, EMPTY_BOX_HEIGHT)
            elseif box.def then
                local content_h = editor_definition.draw(box.def, fontset,
                        {x = box_x + BOX_PADDING, y = box_y + BOX_PADDING}, state_doc.font_size,
                        content_w, is_active, state_doc.show_wireframe, state_doc.show_graph)
                box_h = math.max((content_h or 0) + 2 * BOX_PADDING, EMPTY_BOX_HEIGHT)
            elseif box.fml then
                local content_h = editor_formula.draw(box.fml, fontset, {x = box_x + BOX_PADDING,
                        y = box_y + BOX_PADDING}, state_doc.font_size,
                        content_w, is_active, state_doc.show_wireframe, state_doc.show_graph)
                box_h = math.max((content_h or 0) + 2 * BOX_PADDING, EMPTY_BOX_HEIGHT)
            else
                box_h = EMPTY_BOX_HEIGHT
            end

            -- Fill/border drawn after the text (translucent, same trick as the selection
            -- highlight - stays legible on top) so this frame's actual content height is used,
            -- not last frame's. Only the FILL varies by kind; the border keeps its
            -- active/inactive meaning across all three, so "which box has focus" still reads the
            -- same way it always did.
            local close = content.draw_box_chrome(box_x, box_y, box_w, box_h,
                    box.kind or KIND_TEXT, is_active, rail_x)

            --[[ The wireframe and graph buttons are formula debugging aids - mexpr bounding
            boxes, and a formula's reachable-position graph. Any box that HOLDS formulas gets them,
            which today is a text box (inline embeds) or a definition box (its slots); a formula
            box has nothing yet and gets the close button alone. `wf`/`gr` stay nil in that case and
            go into the layout as nil, which the click handling in handle_input() already guards for
            (culled boxes have always produced nil buttons). ]]
            local wf, gr
            if box.editor or box.def or box.fml then
            -- Wireframe-toggle button: sits just left of the close button, same row. Global (all
            -- boxes share state_doc.show_wireframe - see new_shell()'s own comment), drawn per-box just
            -- so there's always one within reach, same as the close button - toggling any one of
            -- them flips it everywhere.
            wf = {x=close.x - WIREFRAME_SIZE - 4, y=box_y - WIREFRAME_SIZE - 2, w=WIREFRAME_SIZE,
                    h=WIREFRAME_SIZE}
            local wf_color = state_doc.show_wireframe and WIREFRAME_ON_COLOR or WIREFRAME_OFF_COLOR
            vc.ImGui_AddRect({x=wf.x, y=wf.y}, {x=wf.x+wf.w, y=wf.y+wf.h}, wf_color, 3, 1)
            -- A small dashed-box glyph (a smaller inset rect) standing in for "wireframe" - filled
            -- when on, outline-only when off, so the state_doc reads at a glance without needing text.
            local wf_pad = 4
            if state_doc.show_wireframe then
                vc.ImGui_AddRectFilled({x=wf.x+wf_pad, y=wf.y+wf_pad}, {x=wf.x+wf.w-wf_pad,
                        y=wf.y+wf.h-wf_pad}, wf_color, 1)
            else
                vc.ImGui_AddRect({x=wf.x+wf_pad, y=wf.y+wf_pad}, {x=wf.x+wf.w-wf_pad,
                        y=wf.y+wf.h-wf_pad}, wf_color, 1, 1)
            end

            -- Graph-toggle button: sits just left of the wireframe button, same row - same global/
            -- per-box-button reasoning (this file's own new_shell() comment on show_graph).
            gr = {x=wf.x - GRAPH_SIZE - 4, y=box_y - GRAPH_SIZE - 2,
                    w=GRAPH_SIZE, h=GRAPH_SIZE}
            local gr_color = state_doc.show_graph and GRAPH_ON_COLOR or GRAPH_OFF_COLOR
            vc.ImGui_AddRect({x=gr.x, y=gr.y}, {x=gr.x+gr.w, y=gr.y+gr.h}, gr_color, 3, 1)
            -- Two dots joined by a line standing in for "graph" - filled dots when on, hollow when
            -- off, mirroring the wireframe button's own filled-vs-outline convention.
            local gr_p1 = {x=gr.x+4, y=gr.y+gr.h-4}
            local gr_p2 = {x=gr.x+gr.w-4, y=gr.y+4}
            vc.ImGui_AddLine(gr_p1, gr_p2, gr_color, 1)
            if state_doc.show_graph then
                vc.ImGui_AddCircleFilled(gr_p1, 2, gr_color)
                vc.ImGui_AddCircleFilled(gr_p2, 2, gr_color)
            else
                vc.ImGui_AddCircle(gr_p1, 2, gr_color, 1)
                vc.ImGui_AddCircle(gr_p2, 2, gr_color, 1)
            end
            end -- box.editor: wireframe/graph buttons

            layout[i] = {x=box_x, y=box_y, w=box_w, h=box_h, close=close, wireframe_btn=wf,
                    graph_btn=gr}
            y = box_y + box_h + BOX_GAP
        else
            -- Culled: nothing drawn this frame - just carry its own last-known height forward so
            -- everything stacked below it still lands in the right place. Width needs no carrying
            -- (every box is the full column - see box_w above), only the height it last measured.
            layout[i] = {x=box_x, y=box_y, w=box_w, h=cached_h, close=nil, wireframe_btn=nil,
                    graph_btn=nil}
            y = box_y + cached_h + BOX_GAP
        end
    end

    --[[ DERIVATION CURVES, drawn after every box so they lie on top of the page rather than under
    a box that happens to overlap them. Both endpoints come from THIS frame's layout, so a curve can
    only be drawn when both of its boxes were laid out - a parent scrolled out of view is culled and
    has no rect, and the curve is simply skipped rather than drawn to a stale position. ]]
    local by_id = {}
    for i, box in ipairs(state_doc.boxes) do
        if box.fml and box.fml.id then
            by_id[box.fml.id] = i
        end
    end
    for i, box in ipairs(state_doc.boxes) do
        local parent_i = box.fml and box.fml.parent and by_id[box.fml.parent]
        local a = parent_i and layout[parent_i]
        local b = layout[i]
        if a and b and a.h and b.h then
            -- Right edge of each, at its vertical middle: the side away from the rail.
            local ax, ay = a.x + a.w, a.y + a.h / 2
            local bx, by = b.x + b.w, b.y + b.h / 2
            --[[ Clamped to the gutter: a long jump between distant boxes would otherwise bow out
            past the window edge. The curve goes flatter rather than off screen. ]]
            local reach = math.min(CURVE_OUT_MIN + math.abs(by - ay) * CURVE_OUT_FACTOR,
                    CURVE_GUTTER - 8)
            -- Control points straight out to the right: perpendicular to the edges they leave.
            local c1x, c1y = ax + reach, ay
            local c2x, c2y = bx + reach, by
            local px, py = ax, ay
            for step = 1, CURVE_SEGMENTS do
                local t = step / CURVE_SEGMENTS
                local u = 1 - t
                local qx = u*u*u*ax + 3*u*u*t*c1x + 3*u*t*t*c2x + t*t*t*bx
                local qy = u*u*u*ay + 3*u*u*t*c1y + 3*u*t*t*c2y + t*t*t*by
                vc.ImGui_AddLine({x = px, y = py}, {x = qx, y = qy}, CURVE_COLOR, 2)
                px, py = qx, qy
            end
            -- A dot at each end, so which boxes a curve joins reads even where several overlap.
            vc.ImGui_AddCircleFilled({x = ax, y = ay}, 3, CURVE_COLOR)
            vc.ImGui_AddCircleFilled({x = bx, y = by}, 3, CURVE_COLOR)
        end
    end

    local rail_bottom = math.max(y, viewport_bottom)
    vc.ImGui_AddLine({x=rail_x, y=0}, {x=rail_x, y=rail_bottom}, RAIL_COLOR, 1)

    -- Hover preview: while the mouse sits in the "click to insert a box" zone (the C++ content
    -- shell had the same affordance), mark exactly where a click would land - a circle
    -- on the rail with a small cross through it, at the mouse's own y.
    local mpos = vc.ImGui_GetMousePos()
    if mpos and math.abs(mpos.x - rail_x) <= RAIL_CLICK_RADIUS then
        vc.ImGui_AddCircle({x=rail_x, y=mpos.y}, NODE_RADIUS + 3, HOVER_COLOR, 2)
        local arm = 7
        vc.ImGui_AddLine({x=rail_x-arm, y=mpos.y}, {x=rail_x+arm, y=mpos.y}, HOVER_COLOR, 2)
        vc.ImGui_AddLine({x=rail_x, y=mpos.y-arm}, {x=rail_x, y=mpos.y+arm}, HOVER_COLOR, 2)
    end

    state_doc.last_layout = layout
    state_doc.last_rail_x = rail_x
    state_doc.last_total_height = y - content_start_y

    --[[ Drawn after every box so it sits on top of the one it was opened over, and after
    last_layout is stored so opening it never disturbs hit testing for the frame after. ]]
    if state_doc.radial then
        draw_radial_at(state_doc.radial)
    end
    if state_doc.transform_menu then
        draw_transform_menu(state_doc.transform_menu)
    end

    overlay()
end

return content

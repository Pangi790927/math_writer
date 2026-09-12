--[[ ==================================== WHAT THIS FILE OFFERS ====================================
THE CONTAINER
new(fontset: fontset, sz: size) / clone(container: mformula.container,
    fontset: fontset) / clone_node(fontset: fontset, node: node)
build_empty_atom(fontset: fontset, sz: size) -> node
rescale(container: mformula.container, fontset: fontset) -> nothing
set_warn_sink(fn: function)             -> nothing
SUB_SIZE_DELTA                          constant
    A container is {root, cursor_pos, version}. `version` is bumped by
    every real TREE edit and by nothing else, which is how a caller
    tells an edit from a cursor move.

DRAWING AND MEASURING
check_box(box: mformula_new.box)        -> box
draw(container: mexpru.container, fontset: fontset, pos: {x,y}, sz: size, show_cursor: boolean,
     draw_wireframe, wrap_edge: number) -> box
measure(container: mexpru.container, fontset: fontset, sz: size, wrap_width: number) -> box
    The SAME box draw() returns, with the caret fields unset.
cursor_rect(container: mformula.container, pos: {x, y}, fontset: fontset, wrap_edge: number) -> {rect}
cursor_box(container: mformula.container, fontset: fontset, sz: size, wrap_width: number) -> {highlight}
vert_contours(container: mformula.container) -> {contour}
slot_markers(container: mformula.container, fontset: fontset, sz: size) -> {marker}
node_bbox(fontset: fontset, node: node) / node_rects(fontset: fontset, nodes)
reachable_graph(container: mformula.container, fontset: fontset, sz: size, wrap_width: number)

POINTING
hit_test(container: mformula.container, fontset: fontset, sz: size, click: {x,y},
         wrap_width: number, extend: boolean)
glyph_at(fontset: fontset, node: node, click: {x,y}) -> node | nil
node_at(container: mformula.container, fontset: fontset, sz: size, click: {x,y}, wrap_width: number)
        -> node | nil
    hit_test SNAPS to the nearest caret position and always lands;
    node_at answers only for a glyph the point is really on. Different
    questions, not halves of one.

THE CURSOR
cursor_to_start(container: mformula.container) -> nothing
cursor_to_end(container: mformula.container) -> nothing
cursor_path(container: mformula.container) / cursor_from_path(container: mformula.container,
            path: string)
move_left(container: mformula.container) -> moved
move_right(container: mformula.container) -> moved
move_up(container: mformula.container)  -> moved
move_down(container: mformula.container) -> moved
move_up_reverse(container: mformula.container) -> moved
move_down_reverse(container: mformula.container) -> moved
is_sprint_landmark(node: node)          -> boolean
selection_range(container: mformula.container) -> horiz, lo, hi
select_all(container: mformula.container) -> ok
    A selection may never leave its horiz, which is why select_all
    takes the ROOT row and moves the caret out to it.

EDITING
handle_input(container: mformula.container, fontset: fontset, sz: size) -> nothing
make_supsub(container: mformula.container, fontset: fontset, slot: node, place: place) -> node
make_frac(container: mformula.container, fontset: fontset, target_sz: size) -> node
make_bigop(container: mformula.container, fontset: fontset, slot: node) -> node
make_vert(container: mformula.container, fontset: fontset, target_sz: size) -> node
shrink_vert(container: mformula.container, fontset: fontset) -> ok
base_glyph(code: number, size_off: number | nil) -> mformula_new.base_glyph
    The glyph a formula can be started from. Convert whatever you
    are holding into one of these; it is all new_from_base takes.

new_from_base(fontset: fontset, sz: size, base_glyph: mformula_new.base_glyph | nil,
              slot: string) -> container
new_with_frac(fontset: fontset, sz: size) -> container
new_with_vert(fontset: fontset, sz: size) -> container
toggle_accent(container: mformula.container, fontset: fontset, kind: string, where: string) -> ok
adjust_dots(container: mformula.container, fontset: fontset, delta: number) -> ok
collapse_empty_supsub(container: mformula.container, fontset: fontset) -> ok
try_digraph(container: mformula.container, fontset: fontset, target: node, target_is_supsub_base: boolean, ch: string) -> ok
try_resolve_command(container: mformula.container, fontset: fontset) -> ok
delete_overprint_unit(container: mformula.container, fontset: fontset, target: node, target_parent: node, backspace: boolean) -> ok
span_is_lone_placeholder(children: {node}, lo, hi) -> boolean

BRACKETS
open_bracket(container: mformula.container, fontset: fontset, bracket_type: string)
try_close_bracket(container: mformula.container, fontset: fontset, bracket_type: string)
innermost_unclosed_open(container: mformula.container) -> node | nil
pending_integral(container: mformula.container) -> node | nil

LATEX
to_latex(container: mformula.container, subst) / nodes_to_latex(nodes, subst)
from_latex(fontset: fontset, sz: size, text: string)
    Thin passes to mformula_latex, so a caller holding a container
    does not have to know which module renders it.

--- internal, not on the module table --------------------------------------------------------------
    the node constructors, the wrap passes, the navigation graph and
    the bracket pairing
@date 2026-09-12 04:10
================================================================================================= ]]

--[[
mformula_new.lua - the structured expression editor. Holds mexpr_t itself (via mexpru.lua) as the
live edited tree, rather than a separate Lua row/item model re-derived into mexpr on every change,
which is what the superseded row-based editor did.

Model: a container = {root=<mexpr_p>, cursor_pos=<wref_t<mexpr_t>>}.

root is always a "horiz" (mexpru.horiz - a left-to-right mexpr_merge_h sequence), never a bare
atom. EMPTY_BOX and SYMBOL ("atoms") are the only leaves this file builds, and an atom always sits
inside some horiz's children list. A horiz cannot be mutated in place - mexpr_merge_h recomputes
every child's offset - so an edit rebuilds the affected horiz and mexpru.propagate_rebuild()
splices it into its own parent, all the way to the root.

The composite kinds are supsub (base/sup/sub - base is exactly one atom, sup/sub are horizes),
frac (num/den, both horizes), vert (N horiz slots) and dress (a decoration around a target - see
unwrap(): a wrapper, not an atom). Each sits in a horiz's children list like any other slot,
distinguishable only by u(_).kind.

cursor_pos is a WEAK ref, so the cursor can never be what keeps a node alive. What it means to be
anchored to a node depends on the node's kind, and each key's behaviour follows from that - the
authority is cursor_target() and handle_input()'s own branches rather than a summary here, which
drifted from them once already. The short version: on a horiz the cursor is at position 0 (a gap,
not a slot); on an empty atom it IS that atom; on a glyph it sits immediately after it. Whatever
changes the tree moves cursor_pos to the newly relevant atom.

WHAT THE EDITORS CALL, and nothing else needs to:

    new / new_with_frac / new_with_vert / new_from_base   build a container
    from_latex / to_latex / nodes_to_latex                the interchange format, in both directions
    measure                                               how big it is, without drawing
    draw                                                  draw it, and say how big it was
    cursor_rect / hit_test / slot_markers                 caret out, click in, and the clickable
                                                          spots that have no ink of their own
    handle_input                                          one frame of keys
    rescale / clone                                       after a zoom, and for undo
    reachable_graph / vert_contours                       what the debug overlays draw

Everything else in this file is reached through those.

@date 2026-09-08 09:30
]]

local vc = require("virt_composer")
local char = require("char")
local mexpru = require("mexpru")
local sealed = require("sealed")

-- Set by main.lua to input_recorder.log_event, so live_cursor() can report a recovery without this
-- file depending on the recorder (which would be a require cycle through char/prof). The local is
-- declared here, above every user; the setter lives just below mformula_new itself.
local input_recorder_warn = nil
-- Profiler (prof.lua / perf_composer.h). Required at the TOP, not beside the instrumentation block
-- at the bottom of this file: draw() calls prof.begin/stop directly, and a local declared below a
-- function is not in that function's scope - it would read a nil global instead.
local prof = require("prof")
local keymap = require("keymap")
local glyphmap = require("glyphmap")

local mformula_new = {}

--[[ Where a recovered-from-dangling warning goes. main.lua points it at the flight recorder; left
unset (every test), a recovery is silent. Kept as a sink rather than a require so this file does not
depend on the recorder - that would be a cycle through char and prof. @date 2026-09-08 09:30 ]]
function mformula_new.set_warn_sink(fn) input_recorder_warn = fn end

local CURSOR_COLOR = 0xff00ffff
-- Cursor color while a bracket is open and unclosed - "you're in bracket-closing mode, waiting
-- for the matching )/]/}". A visibly different hue (purple, vs. CURSOR_COLOR's yellow) rather than
-- a blink-rate/shape change, so it reads at a glance without having to watch it blink first.
local PENDING_BRACKET_CURSOR_COLOR = 0xffff00cc

--[[ Forward declaration. The real definition is far below (it needs is_horiz/base_of/slot_atom),
but the cursor is drawn ABOVE it and asks every frame which colour to use.

Without this the reference up there is not the local at all - Lua resolves it to a GLOBAL, which is
nil, so the draw threw once per frame. The whole test suite still passed: the headless harness never
runs the draw path, so nothing caught it. It showed up only as the running app visibly pulsing.
2026-09-06. ]]
local innermost_unclosed_open

--[[ The integral whose differential has not been typed yet, or nil.

`d` means "close this" only while one is open, and is an ordinary letter otherwise - so every place
that asks about typing has to be able to tell which moment it is in.
@date 2026-09-10 23:40 ]]
local function pending_integral(container)
    mexpru.check_container(container)
    local open_atom = innermost_unclosed_open(container)
    if not open_atom then
        return nil
    end
    local br = mexpru.u(open_atom).bracket
    if br and br.type == char.BRACKET_INTEGRAL then
        return open_atom
    end
    return nil
end
-- Translucent, drawn UNDER the glyphs, same idea as editor_text.lua's own plain-text selection.
local SELECTION_COLOR = 0x553399ff
--[[ A vert's box and the tick between its cells: muted blue, 0.75 of the way toward the
background, so a stack's extent is visible without competing with the glyphs inside it.

Two things to know before changing it. ImGui packs colours ABGR (0xAABBGGRR), so blue is the HIGH
byte pair and the RGBA spelling comes out red. And the background to mix toward is the RAW one:
content.lua composites BOX_FILL_COLOR (0x33ffffff) over everything in a box, so a colour rendered
here is one 20%-white veil lighter than it is written. Mixing a raw constant toward the VEILED
background mixes two spaces and lands ~0.55 of the way rather than 0.75, which is what the first
attempt did. The veil is affine and commutes with the blend, so blending entirely in raw space
agrees with the screen - both give (89,110,140), checked against real pixels.

The separator is a short centred DASH rather than a full rule: a rule across the stack reads as a
table.
@date 2026-09-08 09:30 ]]
local VERT_CONTOUR_COLOR = 0xff704a30
-- 2, not 1: the muted colour above needs the extra weight to stay legible against the fill it is
-- three-quarters of the way toward.
local VERT_LINE_THICKNESS = 2
-- Dash length as a fraction of the stack's width, centred - so the same padding either side.
local VERT_DIVIDER_FRACTION = 0.2

-- How much smaller a sup/sub renders than its base, in font-size-table STEPS. char.lua's table is
-- sorted biggest to smallest and sz is a discrete 1..18 index, not a pixel size, so this ADDS to sz
-- rather than scaling it: +1 is the next size down (36pt -> 24pt). MAX_SIZE_INDEX comes from mexpru
-- rather than being duplicated here, so char.lua's table edits do not need tracking by hand.
local SUB_SIZE_DELTA = 1
local MAX_SIZE_INDEX = mexpru.MAX_SIZE_INDEX

--[[ mexpr_symbol(is_char=true)/mexpr_draw re-centre every glyph on the vertical middle of 'a' at
its own size - a convention mexpr composition relies on - which is NOT the baseline plain text sits
on, nor the one cursor_target() reads off a node's bb. This is the one-time-per-size correction
added to a true baseline y before handing it to mexpr_draw, so mexpr content lands exactly where
plain text at the same pos would.
@date 2026-09-08 09:00 ]]
local baseline_correction_cache = {}

-- Cached per size: this is asked for on every draw, measure and caret, and the answer only depends
-- on the size.
local function baseline_correction(fs, sz)
    local c = baseline_correction_cache[sz]
    if c then
        return c
    end
    local a = char.find_by_ascii("a")
    local a_sz = fs:char_get_sz({size = sz, code = a.ncod})
    c = (a_sz.tr.y + a_sz.bl.y) / 2
    baseline_correction_cache[sz] = c
    return c
end

--[[ G/g-based line_height/baseline_shift at font size sz - the SAME metrics a real plain-text
cursor is sized/positioned from (the old editor's get_metrics() used this exact trick). An empty
atom's own tl.y..br.y is built to match this exactly (see build_empty_atom() below) - not 'a's own
ink extent - so it IS a real text cursor's size/position, not just something proportional to it.
@date 2026-09-08 09:00 ]]
local function cursor_metrics(fs, sz)
    local G, g = char.find_by_ascii("G"), char.find_by_ascii("g")
    local G_sz = fs:char_get_sz({size = sz, code = G.ncod})
    local g_sz = fs:char_get_sz({size = sz, code = g.ncod})
    return {line_height = g_sz.bl.y - G_sz.tr.y, baseline_shift = G_sz.tr.y}
end

--[[ A raw mexpr bounding box, converted into the true-baseline frame everything in this file
measures in.

mexpr_symbol builds each SYMBOL's tl/br already shifted (symb_off) so the glyph lands centred on
'a's own middle when it is drawn - which is not the baseline plain text sits on, and not the frame
cursor_metrics() reports in. Adding baseline_correction() undoes that shift, and it is what makes a
vc.mexpr_get_bb() reading comparable with a cursor measurement at all.

draw() applies the same correction to its own draw position; content_extent() and cursor_target()
do their bb maths without going through mexpr_draw, so they have to apply it themselves - which is
what this is for. Only y moves: symb_off's x is always 0.
@date 2026-09-08 09:30 ]]
local function to_baseline_frame(fontset, sz, bb)
    local bc = baseline_correction(fontset, sz)
    return {tl = {x = bb.tl.x, y = bb.tl.y + bc}, br = {x = bb.br.x, y = bb.br.y + bc}}
end

--[[ The size of an empty typing slot at font size sz: one 'H' wide, and exactly as tall as a
plain-text caret (cursor_metrics()' own baseline_shift..+line_height band).

It is both what build_empty_atom() builds an atom from and the FLOOR content_extent() clamps to, so
a formula never renders smaller than one empty slot however little is in it - a lone "." would
otherwise draw a box barely taller than the dot.
@date 2026-09-08 09:30 ]]
local function min_extent(fs, sz)
    local cm = cursor_metrics(fs, sz)
    local H = char.find_by_ascii("H")
    local width = fs:char_get_sz({size = sz, code = H.ncod}).adv
    return {width = width, top = cm.baseline_shift, bottom = cm.baseline_shift + cm.line_height}
end

--[[ One fresh empty atom at logical size sz - the typing slot a new formula starts as, and the one
an emptied-out row falls back to.

Sized from min_extent(), so it reads as somewhere to type rather than as a sliver, and tagged with
its own sz: cursor_pos often names an atom directly, and cursor_target() has to know which level to
draw the caret at. Every horiz records its size the same way.

Two conventions collide here and cancel. The geometry is built at the PHYSICAL size (zoom applied)
while u(_).sz stays LOGICAL, which is the rule everywhere in this file. And the raw tl/br are built
with the baseline correction taken OUT in advance (above_bl = bc - ext.top), because every reader
puts them back IN through to_baseline_frame() - so the atom reads back at exactly ext.top/bottom.
An empty atom does not need that conversion the way a symbol does; baking it out is what lets both
kinds flow through one path instead of the readers asking which kind they hold.
@date 2026-09-08 09:30 ]]
--[[ THE TWO WRAPPERS a base can carry, and the one predicate that must never tell them apart.

A big operator carrying limits is a supsub in every way except how it DRAWS: the same base/sup/sub
slots, so Left/Right step over it as one atom, Up/Down enter its limits, and the cascade and the
sprint see what they already understand. Only the two places that REBUILD a node look at `kind` to
choose a constructor.

DEFINED HERE, AT THE TOP, because that is what went wrong before. This predicate was widened to
cover bigop on 2026-09-08 with a comment saying "this predicate widening needs no other change" -
and it was true of everything that CALLED it. Five places did not call it: four hand-rolled
`kind == "supsub"` to compute `target_is_supsub_base`, and make_supsub hand-rolled the size fallback
because the helper was declared further down the file. A base under a bigop answered `false` at all
five, so a typed character replaced the row slot instead of the base. A helper that half the file
cannot reach is not a helper, so both live above every caller now.
@date 2026-09-10 14:10 ]]
local function is_supsub(node)
    return mexpru.u(node).kind == "supsub"
end

--[[ Is `target` the BASE of the wrapper it sits in, rather than an ordinary sibling in a row?

The question every insert/paste path asks before writing into a slot: replacing a base means
rebuilding the wrapper around it, while replacing a row slot is an ordinary splice. Both wrapper
kinds answer the same, which is the whole point.

`parent` is passed rather than read from `target` because callers already hold it - and because
get_parent() answers differently once a rebuild is in flight (make_supsub's own note).
@date 2026-09-10 14:10 ]]
local function is_wrapper_base(target, parent)
    if not target or not parent then
        return false
    end
    local pu = mexpru.u(parent)
    return pu ~= nil and pu.kind == "supsub" and mexpru.same(pu.base, target)
end

--[[ Writes a new side into a wrapper that is already there, REBUILDING IT AS ITS OWN KIND.

The kind is the whole reason this is a function. The sup/sub key used to rebuild whatever it found
with `mexpru.supsub()` - correct for as long as the only thing it could find was a supsub, and wrong
the moment a bigop's base started answering is_wrapper_base: pressing sup on a big operator's base
would have rebuilt the operator as a supsub, silently moving its limits from over-and-under to
beside it.
@date 2026-09-10 15:00 ]]
local function fill_wrapper_slot(container, fontset, wrapper, slot, new_horiz, place)
    local u = mexpru.u(wrapper)
    local sup = (slot == "sup") and new_horiz or u.sup
    local sub_ = (slot == "sub") and new_horiz or u.sub
    --[[ The side being written gets the placement the key asked for; the other keeps its own, which
    is what lets one node hold a limit under an operator and a power beside it at once. ]]
    local sup_place = (slot == "sup") and place or u.sup_place
    local sub_place = (slot == "sub") and place or u.sub_place
    local rebuilt = mexpru.supsub(fontset, u.base, sup, sub_, u.sz, sup_place, sub_place)
    container.root = mexpru.propagate_rebuild(fontset, wrapper, rebuilt)
end

--[[ THE WRAPPER STACK over whatever atom `node` ultimately decorates: the base at the bottom, and
the wrappers standing on it, innermost first.

Both directions are walked because `node` can be either end of the same stack - the cursor rests on
the base while typing, and on the wrapper node itself after leaving a limit.
@date 2026-09-10 15:00 ]]
local function wrapper_stack(node)
    local base = node
    while is_supsub(base) and mexpru.u(base).base do
        base = mexpru.u(base).base
    end

    local chain, n = {}, base
    while true do
        local parent = n:get_parent()
        if not is_wrapper_base(n, parent) then
            break
        end
        chain[#chain + 1] = parent
        n = parent
    end
    return base, chain
end

--[[ What adding a `slot` ("sup"/"sub") over `node` should do: {action = "fill", wrapper} to write
into the wrapper already there, {action = "wrap", around} to build one - or nil plus the reason.

BOTH OF THE AUTHOR'S RULES ARE NOW ARITHMETIC RATHER THAN POLICY, and that is what merging the two
node kinds bought. He asked for "max wrap level is 2" and for the two wrappers to be "mutual
exclusive on their sup/sub levels" - and once a big operator IS a supsub, with per-side placement
instead of a kind of its own, there is one node with one sup slot and one sub slot. There is nowhere
to put a second sup, and no second wrapper to want.

What is left for this function is the ordinary question: is that side free.
@date 2026-09-10 16:20 ]]
local function plan_decoration(node, slot)
    local base, chain = wrapper_stack(node)
    local wrapper = chain[1]
    if not wrapper then
        return {action = "wrap", around = base, base = base}
    end
    if mexpru.u(wrapper)[slot] then
        return nil, "that side of this base is already taken"
    end
    return {action = "fill", wrapper = wrapper, base = base}
end

--[[ The size a decoration hung on `target` should be built at: the target's own, or - when target is
a bare wrapper node with no size of its own (a resting spot) - its base's.
@date 2026-09-10 14:10 ]]
local function wrapper_base_sz(target)
    return mexpru.u(target).sz
            or (is_supsub(target) and mexpru.u(mexpru.u(target).base).sz)
end

--[[ The empty placeholder atom - a real, selectable node standing for "nothing here yet".

Core: A SLOT IS NEVER TRULY EMPTY. An exponent with nothing in it, a fresh formula, a numerator
waiting to be typed - each holds one of these, because a row with no children has no position to put
a caret in and nothing to click on. That is why an empty formula is still navigable.

Exported because from_latex needs one for input it could not read at all, and a test builds them
directly.
@date 2026-09-12 04:15 ]]
local function build_empty_atom(fontset, sz)
    -- sz is LOGICAL (u(_).sz's own meaning, untouched by zoom - mexpru.rescale()'s own comment);
    -- the actual geometry below has to be built at the CURRENT PHYSICAL size (mexpru.physical_sz()
    -- - content.lua's Ctrl+MouseWheel zoom), while u(ret).sz keeps recording sz itself
    -- (logical), same as every other atom this file builds.
    local phys = mexpru.physical_sz(sz)
    local ext = min_extent(fontset, phys)
    local bc = baseline_correction(fontset, phys)
    local ret = mexpru.mexpr_empty(fontset, ext.width, ext.bottom - ext.top, bc - ext.top)
    mexpru.u(ret).sz = sz
    return ret
end

-- Exported for tests only (the convention make_supsub()/make_frac() already use): building
-- a slot that is still UNTYPED by hand needs the same empty atom the editor puts there.
mformula_new.build_empty_atom = build_empty_atom

--[[ A brand new, empty container: a root horiz holding one empty atom, with the cursor ON that
atom.

On the ATOM, not on the horiz, and the difference is visible the first time anything is typed: a
cursor on a horiz INSERTS alongside what is there, so the empty atom would survive and the first
glyph would land beside it; a cursor on an atom REPLACES it, which is the one that gives a single
glyph. Root is never a bare atom - see the model at the top of this file.

update_positions() primes the position cache for a tree nothing has edited yet; every later edit
refreshes it through propagate_rebuild(), so this is the only place it is seeded from nothing.
@date 2026-09-08 09:30 ]]
function mformula_new.new(fontset, sz)
    local empty_atom = build_empty_atom(fontset, sz)
    local root = mexpru.horiz(fontset, {empty_atom}, sz)
    mexpru.update_positions(root)
    return mexpru.new_container(root, empty_atom)
end

--[[ Parks the cursor at the formula's own start - what editor_text.lua uses when the caret walks
into an adjacent formula from the left.

Root itself, which is position 0 of the root row and always a valid resting spot. It does NOT dive
any further in, for the same reason move_left/move_right never enter a compound uninvited: arriving
at a formula is not the same as choosing a place inside it.
@date 2026-09-08 09:30 ]]
function mformula_new.cursor_to_start(container)
    mexpru.check_container(container)
    container.cursor_pos = vc.wref_mexpr(container.root)
end

--[[ Parks the cursor after the last thing in the root row - where typing continues. Used when a
formula is entered from the right, and after building one from LaTeX. @date 2026-09-08 09:10 ]]
function mformula_new.cursor_to_end(container)
    mexpru.check_container(container)
    container.cursor_pos = vc.wref_mexpr(mexpru.last_slot(container.root))
end

--[[ How much room the formula actually occupies: {width, top, bottom} in the baseline frame,
never smaller than one empty slot.

The ONE answer measure() and draw() both use, so the two cannot disagree about the box - draw()'s
return is what the caller borders the formula with, which is why the min_extent clamp has to reach
both rather than only measure()'s line-growing pass. Root is a horiz, so its bb is already relative
to its own origin: no position lookup here, unlike cursor_target() below.

WRAPPING. `wrap_width` is the room this formula has before it wraps, measured from where IT starts
rather than as an absolute x - a formula partway along a line gets less than the box's full width,
the same way a plain glyph's own width check already gives it. nil means it never wraps.

When content needs more than that, width is capped at wrap_width (it cannot be wider on screen - it
wraps back instead) and bottom grows by one raw root height per extra row. The row count is worked
out the same analytical way vc.mexpr_draw works it out - total width against the usable column, not
a counter threaded through the recursion - so pass 1 and pass 2 agree on the height with no frame
of lag. draw()'s own returned height is a different number, used where which row content really
landed on matters: cursor_rect() and hit_test().
@date 2026-09-08 09:30 ]]
local function content_extent(container, fontset, sz, wrap_width)
    prof.begin("lua.ce.total")
    prof.begin("lua.ce.get_bb")
    local raw_bb = vc.mexpr_get_bb(container.root)
    prof.stop("lua.ce.get_bb")
    prof.begin("lua.ce.baseline")
    local bb = to_baseline_frame(fontset, sz, raw_bb)
    prof.stop("lua.ce.baseline")
    prof.begin("lua.ce.min_extent")
    local min = min_extent(fontset, sz)
    prof.stop("lua.ce.min_extent")
    local width = math.max(bb.br.x - bb.tl.x, min.width)
    local top = math.min(bb.tl.y, min.top)
    local bottom = math.max(bb.br.y, min.bottom)

    if wrap_width and wrap_width > 0 then
        local skipy = raw_bb.br.y - raw_bb.tl.y
        local total_w = raw_bb.br.x - raw_bb.tl.x
        local wraps = math.floor(math.max(0, total_w - 1e-3) / wrap_width)
        if wraps > 0 then
            width = math.min(width, wrap_width)
            bottom = bottom + wraps * skipy
        end
    end

    prof.stop("lua.ce.total")
    return {width = width, top = top, bottom = bottom}
end

--[[ Where the caret belongs for a cursor anchored to `node`, as a root-relative rect.

`node` can be any descendant, arbitrarily deep, so its own bb is not enough on its own: the
position cache (mexpru.u(node).pos, refreshed by every edit) says where it sits relative to root,
and its baseline-converted local bb says how big it is there.

THE SIZE COMES FROM THE NODE, never from the caller - a caret inside a sup renders at the sup's own
level, not the outer formula's. Only x differs by kind: a horiz or an EMPTY atom has nothing to sit
after, so the caret goes at its left edge; a SYMBOL atom puts it at the right edge, which is the
"where does the next thing go" convention. Height is ALWAYS real cursor metrics rather than the
node's own ink, or a row holding one tall glyph - or a "." with almost no ink - would give a caret
the wrong height in either direction.

KNOWN GAP, flagged rather than fixed: top/bottom are true-baseline numbers and are NOT put through
baseline_correction() into the frame every other root-relative reading here is already in. It is
invisible whenever the node's size equals the size the caller re-anchors at - every plain in-line
atom, which is why it went unnoticed - and a real error for a nested, differently-sized one.
cursor_rect() below needs the numbers actually right for the live blinker, so it applies the
correction itself. slot_markers() has the same gap for a marker on nested content and does not,
because fixing it there means changing what editor.lua does with the result too.
@date 2026-09-08 09:30 ]]
local function cursor_target(fontset, node)
    -- Only a horiz or an atom has its own u(_).sz - a supsub node itself never does (it spans
    -- several sizes at once via base/sup/sub, none of which is uniquely "its own"). cursor_pos
    -- CAN legitimately be a supsub directly ("after the whole compound" - see move_left()/
    -- move_right()'s own comments), so this has to fall back to that supsub's own base's size -
    -- the level the compound reads as continuing at, matching how it's anchored to base's baseline.
    -- LOGICAL (u(_).sz's own meaning) mapped to PHYSICAL right here, before it touches any real
    -- font metric - mexpru.rescale()'s own comment on why u(_).sz itself always stays logical.
    local sz = mexpru.physical_sz(mexpru.u(node).sz or mexpru.u(mexpru.u(node).base).sz)
    local pos = mexpru.u(node).pos
    local bb = to_baseline_frame(fontset, sz, vc.mexpr_get_bb(node))
    local cm = cursor_metrics(fontset, sz)

    local is_start = (node.type == vc.MEXPR_TYPE_EMPTY_BOX) or (mexpru.u(node).kind == "horiz")
    local x = is_start and (pos.x + bb.tl.x) or (pos.x + bb.br.x)
    return {x = x, top = pos.y + cm.baseline_shift, bottom = pos.y + cm.baseline_shift + cm.line_height}
end

--[[ A point in the tree's own UNWRAPPED space, moved to where wrapping actually puts it on
screen. Returns x, y and the ROW it landed on.

Mirrors vc.mexpr_draw's `while` loop step for step rather than dividing, so it cannot disagree with
what was really drawn - including the rough edge where a composite straddling the edge wraps its
leaves a different number of times. It only ever has to be right for ONE x (whatever is being
placed - a caret, here), never the whole tree at once, so iterating costs nothing.

The ROW is the loop count, and it is the only honest way to ask whether two points share a row: y
cannot answer that, because a sup and its base sit at different y ON the same row. Anything keying
off y treats an ordinary superscript as a row crossing - which is exactly what it did, in the
graph-edge drawing that reads this.

unwrap_point() below is the inverse, for a click coming the other way. A nil or non-positive
wrap_width means "never wraps" and returns the point unchanged.
@date 2026-09-08 09:30 ]]
local function wrap_point(x, y, wrap_width, skipy)
    if not wrap_width or wrap_width <= 0 then
        return x, y, 0
    end
    local row = 0
    while x > wrap_width do
        x = x - wrap_width
        y = y + skipy
        row = row + 1
    end
    return x, y, row
end

--[[ Inverse of wrap_point() above - maps a click that landed on some WRAPPED row back to where
that same point sits in "formula space", so hit_test_node()'s plain space-partitioning descent
(which only ever knows about unwrapped positions - mexpru.u(_).pos is never touched by wrapping,
that's purely a vc.mexpr_draw-time visual shift) can be reused as-is regardless of whether the
formula currently wraps.

Row number recovered from Y alone, not X: post-wrap x is always <= wrap_width regardless of which
row a point came from (that's the whole point of wrapping), so only y can disambiguate - each
wrapped row occupies its own [row0_top + N*skipy, row0_top + (N+1)*skipy) band, non-overlapping,
since every wrap step drops content by EXACTLY skipy. `row0_top` is root's own raw bb.tl.y - row 0's
own top edge, before any wrap shift.
@date 2026-09-08 09:00 ]]
local function unwrap_point(x, y, wrap_width, skipy, row0_top)
    if not wrap_width or wrap_width <= 0 then
        return x, y
    end
    local n = math.floor((y - row0_top) / skipy)
    if n < 0 then
        n = 0
    end
    return x + n * wrap_width, y - n * skipy
end

--[[ THE CARET'S RECT ON SCREEN: cursor_target()'s root-relative answer, shifted by the origin the
formula is drawn at and put through the wrap transform.

It also applies the correction cursor_target() deliberately leaves out. That function's height
comes from G/g's true-baseline metrics, while the position cache it is added to lives in the "a's
own middle, at the NODE's own size" frame - the frame draw() converts into before calling
mexpr_draw. Bridging the two is one subtraction: baseline_correction(outer) minus
baseline_correction(node). Zero whenever the two sizes match, which is every plain in-line caret,
and a real correction inside a sup or sub.

wrap_edge is an ABSOLUTE x in the same frame as `pos`, not a width. Both ends of the caret go
through wrap_point() with the same x, so the whole band lands on one row - the row the node really
wrapped onto rather than its unwrapped spot.
@date 2026-09-08 09:30 ]]
function mformula_new.cursor_rect(container, pos, fontset, wrap_edge)
    mexpru.check_container(container)
    local node = container.cursor_pos:get_obj()
    local t = cursor_target(fontset, node)
    -- Both LOGICAL (u(_).sz's own meaning), mapped to PHYSICAL before touching real font metrics -
    -- mexpru.rescale()'s own comment. A uniform +zoom shift on both sides cancels out of the delta
    -- exactly as the unmapped values always did (same reasoning content_extent()'s own outer `sz`
    -- gets left alone for - see this file's own model comment on logical vs. physical).
    local node_sz = mexpru.physical_sz(mexpru.u(node).sz or mexpru.u(mexpru.u(node).base).sz)
    local outer_sz = mexpru.physical_sz(mexpru.u(container.root).sz)
    local delta = baseline_correction(fontset, outer_sz) - baseline_correction(fontset, node_sz)

    local wrap_width, skipy = wrap_edge and (wrap_edge - pos.x), nil
    if wrap_width then
        local raw_bb = vc.mexpr_get_bb(container.root)
        skipy = raw_bb.br.y - raw_bb.tl.y
    end
    -- Same t.x both times, so both land on the same row - one `row` describes this whole caret band.
    local wx, wtop, row = wrap_point(t.x, t.top, wrap_width, skipy)
    local _, wbottom = wrap_point(t.x, t.bottom, wrap_width, skipy)
    return {x = pos.x + wx, top = pos.y + wtop + delta, bottom = pos.y + wbottom + delta,
            row = row or 0}
end

--[[ Every stack in the formula as root-relative geometry ready to draw: {x0,y0,x1,y1, edges},
`edges` being the y of each internal cell boundary. Cached against the tree.

Exported for the same "testability only" reason make_supsub()/make_frac()/make_vert() are: a stale
cache draws contours in the wrong place, which is a test's job to catch rather than a screenshot's,
and draw() itself cannot run without a live ImGui context.

CACHED because finding the verts means recursing the whole tree - a mexpru.u() per node just to test
kind, plus anchor_len()/anchor_at() per child, each a Lua->C++->Lua crossing. Rediscovering that
every frame was the single largest item in draw(): 2.77ms of 4.46ms for two small formulas, against
0.43ms for the ENTIRE C++ layout and draw path. Nothing was being rebuilt - it was pure rediscovery,
and it grew with document size, which is the shape of the "starts to lag" report.

Only tree-derived geometry goes in. The wrap transform and draw_pos are applied fresh at draw time,
since they change with window width and scroll without the tree changing - caching them would mean
invalidating on things that are not edits.

THE KEY needs both halves. version alone misses rescale() (zoom), which replaces the whole tree
WITHOUT bumping version because it is not an edit. Root identity alone would mean trusting fifteen
separate `container.root = ...` sites to really produce a new node. It stores tostring() rather
than the node, so the cache pins no cut tree alive for a frame; the residual ABA gap - same
version, and a new root at the freed one's address, in one frame - costs one frame of stale
contours.
@date 2026-09-08 09:30 ]]
function mformula_new.vert_contours(container)
    mexpru.check_container(container)
    local key = tostring(container.version or 0) .. "/" .. tostring(container.root)
    local cache = container._contour_cache
    if cache and cache.key == key then
        return cache.items
    end

    prof.begin("lua.draw.contour_build")
    local items = {}

    --[[ Where cell i ends, in the vert's own frame. NOT re-derived from the min_cell floor
    (mexpru.vert()/mexpr_merge_v) - that would be a second copy of the layout rule, free to drift
    from the real one. Instead it falls out of the two facts the C++ guarantees: cells are contiguous
    starting at the stack's own top edge, and each row is CENTRED in its cell. So the padding above
    row i is whatever sits between the previous boundary and that row's top, and the same amount sits
    below it. Exact for uneven rows too (a cell holding a fraction is taller than its neighbours),
    where any "midpoint between the two rows" guess would not be. ]]
    local function cell_edges(node, u, origin_y)
        local edges = {}
        local edge = vc.mexpr_get_bb(node).tl.y -- the stack's own top, in its own frame
        for i = 1, #u.slots - 1 do              -- the last cell's bottom edge IS the contour
            local slot, off = table.unpack(node:anchor_at(i))
            local sbb = vc.mexpr_get_bb(slot)
            local pad = (off.y + sbb.tl.y) - edge
            edge = (off.y + sbb.br.y) + pad
            edges[i] = origin_y + edge -- stored root-relative, so drawing adds nothing but draw_pos
        end
        return edges
    end

    local function walk(node)
        local u = mexpru.u(node)
        if u and u.kind == "vert" and u.pos then
            local bb = vc.mexpr_get_bb(node)
            items[#items + 1] = {
                x0 = u.pos.x + bb.tl.x, y0 = u.pos.y + bb.tl.y,
                x1 = u.pos.x + bb.br.x, y1 = u.pos.y + bb.br.y,
                edges = cell_edges(node, u, u.pos.y),
            }
        end
        for i = 1, node:anchor_len() do
            walk(node:anchor_at(i)[1])
        end
    end
    walk(container.root)

    container._contour_cache = {key = key, items = items}
    prof.stop("lua.draw.contour_build")
    return items
end

--[[ One node's own box, in the frame draw() works in: relative to the `pos` draw() is given, with
the wrap transform and baseline_correction already applied, so a caller adds nothing but pos. nil
when the node has no position yet or no extent worth drawing (an inkless glyph).

Shared by the selection highlight and cursor_box() - the two things that need to know where a node
actually IS on screen, as opposed to where its caret goes. Keeping it in one place matters because
the wrap handling is the fiddly part: wrap_point() is applied to the TOP-LEFT only and the same
delta moved to both corners, so a node that wrapped moves as one rectangle rather than being turned
inside out by transforming each corner independently.
@date 2026-09-08 09:00 ]]
local function node_box(node, fontset, sz, wrap_width, root)
    local u = node and mexpru.u(node)
    if not u or not u.pos then
        return nil
    end
    local bb = vc.mexpr_get_bb(node)
    local x0, y0 = u.pos.x + bb.tl.x, u.pos.y + bb.tl.y
    local x1, y1 = u.pos.x + bb.br.x, u.pos.y + bb.br.y
    if x1 - x0 <= 0 or y1 - y0 <= 0 then
        return nil
    end
    local skipy
    if wrap_width then
        local rbb = vc.mexpr_get_bb(root)
        skipy = rbb.br.y - rbb.tl.y
    end
    local wx0, wy0 = wrap_point(x0, y0, wrap_width, skipy)
    local dx, dy = wx0 - x0, wy0 - y0
    return {x = x0 + dx, y = baseline_correction(fontset, sz) + y0 + dy,
            w = x1 - x0, h = y1 - y0}
end

--[[ Makes sure container.cursor_pos still names a live node, and puts it somewhere sane if it does
not. Returns the node.

cursor_pos is a WEAK ref (vc.wref_mexpr), so it CAN legitimately come back nil - that is what weak
means - and mexpru.cut() force-releases a superseded node even while shared_ptrs to it remain, so a
rebuild that forgets to move the cursor leaves it dangling rather than merely stale. Every per-frame
reader used to dereference it without checking, which turned a single missed reassignment into a
permanent, unrecoverable state: slot_markers() threw on `node.type`, main.lua's pcall caught it, and
the SAME throw repeated every frame forever. The app stayed alive and responsive but drew nothing
new - indistinguishable from a freeze - and filled the flight recorder with over a thousand identical
lines. Seen in a real session (Ctrl+Shift+Left x3, Ctrl+C, Right x6, Ctrl+V, then
"attempt to index a nil value (local 'node')" from frame 4420 to the end of the session).

Recovering to the root is a deliberately dull choice: the root always exists, cursor_pos on a horiz
is a position this file already handles everywhere ("before everything in it"), and the worst case
is a cursor that jumped somewhere unexpected - which is enormously better than an editor that has to
be killed. Logged ONCE per occurrence so the cause is visible without burying the log.
@date 2026-09-08 09:00 ]]
local function live_cursor(container)
    local node = container.cursor_pos and container.cursor_pos:get_obj()
    if node then
        return node
    end
    container.cursor_pos = vc.wref_mexpr(container.root)
    if input_recorder_warn then
        input_recorder_warn("cursor_pos was dangling - recovered to the formula root")
    end
    return container.root
end

--[[ THE `box` CONTAINER - what draw() hands back: where the formula ended up on screen.

Declared and sealed because it crosses four files and is the basis of every click: editor.lua turns
it into a click rect, and the three editors keep it from one frame to the next so the NEXT frame's
input has something to hit-test against. A typo reading it - `box.hight` - would come back nil and a
formula would simply stop being clickable, with nothing said.

Everything in it is RELATIVE TO THE DRAW ORIGIN, and `top` is negative: the origin is the BASELINE,
not the top of the ink.
@date 2026-09-12 15:50 ]]
local BOX_FIELDS = {
    width      = "how far right the ink reaches from the origin",
    top        = "the highest point, NEGATIVE - the origin is the baseline",
    bottom     = "the lowest point",
    cursor_top = "screen y of the caret's top this frame; UNSET when measuring, or when the "
                 .. "caret was not drawn",
    cursor_h   = "the caret's height, unset in the same cases - content.lua scrolls it into view",
}
local BOX_SHAPE = sealed.declare("mformula_new", "box", BOX_FIELDS)

--[[ Asserts that this is a draw box, for a function elsewhere that takes one. Returns it.
@date 2026-09-12 16:00 ]]
function mformula_new.check_box(box)
    return BOX_SHAPE.check(box, "box")
end


--[[ Draws the whole formula at `pos`, and returns the box it occupies.

`pos` is a BASELINE origin, the same convention plain text uses, not a top-left corner. The return
is {width, top, bottom, cursor_top, cursor_h} in the baseline frame measure() reports in, so a
caller can border the formula without measuring it a second time - and width/top/bottom are read
unconditionally, which is why measure() computes exactly those three. The two cursor fields are nil
while show_cursor is false, but the keys always exist.

show_cursor draws the caret (blinking off container.frame, which is persisted like root and
cursor_pos) and the selection; the caller decides which formula is the active one.

draw_wireframe is mexpr's own whole-tree bbox overlay, behind content.lua's wireframe button.

wrap_edge is an ABSOLUTE x in the same frame as `pos`, not a width; content past it wraps back
under itself. The returned width then never exceeds the usable column and bottom grows to fit the
rows, so the box around a wrapped formula grows DOWN. The caret follows: cursor_rect() is handed
the same wrap_edge and puts the blinker through wrap_point(), so a glyph that wrapped carries its
caret with it.

This also draws what ImGui knows nothing about - the vert contours and their cell dividers - before
the glyphs, so they sit under the text.
@date 2026-09-08 09:30 ]]
function mformula_new.draw(container, fontset, pos, sz, show_cursor, draw_wireframe, wrap_edge)
    mexpru.check_container(container)
    if show_cursor == nil then
        show_cursor = true
    end

    local draw_pos = {x = pos.x, y = pos.y + baseline_correction(fontset, sz)}
    local wrap_width = wrap_edge and (wrap_edge - draw_pos.x)
    --[[ drawn_h is a floor that can never actually raise anything, and is kept only because it
    costs nothing. mexpr_draw computes its returned height ANALYTICALLY - skipy * (wraps + 1), from
    the root's own bb against the usable column - which is the same formula content_extent() applies
    here in Lua, so the two agree by construction. It is not a measurement of what was drawn.

    A composite straddling the wrap edge CAN in principle fall below that uniform estimate, since
    each leaf wraps independently from its own unwrapped x. Measured rather than argued: sweeping
    fraction offsets against column widths puts the overshoot at exactly 0.0px for every wrap count
    a real box reaches (1-3 rows), and 43px only at a degenerate 22px column wrapped twelve times.
    Measuring it honestly would mean threading a max-bottom accumulator through mexpr_draw_rec -
    deliberately not done. ]]
    --[[ A contour around every stack, and a dash between each pair of its cells, drawn BEFORE the
    glyphs so both sit under the text. Requested ("draw under the vector a conour of it"): where a
    stack really sits is otherwise only inferrable from where its rows land, and the dividers make
    the cell boundaries visible rather than only the outer box.

    Positions come from the root-relative position cache plus each node's own tl/br, put through the
    SAME wrap transform mexpr_draw applies. The shift is taken from the top-left corner and applied
    to every point of that stack, so one that wrapped moves as a box rather than being turned
    inside out by transforming each corner on its own. ]]
    local contours = mformula_new.vert_contours(container)
    if #contours > 0 then
        local wrap_w = wrap_edge and (wrap_edge - draw_pos.x)
        local skipy
        if wrap_w then
            local rbb = vc.mexpr_get_bb(container.root)
            skipy = rbb.br.y - rbb.tl.y
        end
        for _, c in ipairs(contours) do
            local wx0, wy0 = wrap_point(c.x0, c.y0, wrap_w, skipy)
            local dx, dy = wx0 - c.x0, wy0 - c.y0
            vc.ImGui_AddRect({x = draw_pos.x + c.x0 + dx, y = draw_pos.y + c.y0 + dy},
                    {x = draw_pos.x + c.x1 + dx, y = draw_pos.y + c.y1 + dy},
                    VERT_CONTOUR_COLOR, 2, VERT_LINE_THICKNESS)
            local half = (c.x1 - c.x0) * VERT_DIVIDER_FRACTION / 2
            local mid = (c.x0 + c.x1) / 2
            for _, edge in ipairs(c.edges) do
                local ey = draw_pos.y + edge + dy
                vc.ImGui_AddLine({x = draw_pos.x + mid - half + dx, y = ey},
                        {x = draw_pos.x + mid + half + dx, y = ey}, VERT_CONTOUR_COLOR,
                        VERT_LINE_THICKNESS)
            end
        end
    end

    prof.begin("lua.draw.mexpr_draw")
    local drawn_h = vc.mexpr_draw(fontset, draw_pos, container.root, draw_wireframe or false,
            wrap_edge or math.huge)
    prof.stop("lua.draw.mexpr_draw")

    prof.begin("lua.draw.content_extent")
    local ext = content_extent(container, fontset, sz, wrap_width)
    prof.stop("lua.draw.content_extent")
    if wrap_width then
        local drawn_bottom = ext.top + drawn_h
        if drawn_bottom > ext.bottom then
            ext.bottom = drawn_bottom
        end
    end
    local cursor_top, cursor_h = nil, nil

    --[[ Restart the blink cycle whenever the caret lands somewhere new, or the tree changed under
    it - so it is ON the instant it moves and you can see where it went, instead of possibly landing
    mid-dark-phase and leaving you waiting up to half a second to find it. Requested:
    "when moved the cursor should reset to visible so that it is visible imediately where it was
    moved".

    Done here, in draw(), rather than at each of the many places that assign cursor_pos (every mover,
    every insert, try_close_bracket, the backspace branches...) - one comparison catches all of them,
    including any added later, and cannot fall out of sync the way a dozen scattered resets would.
    Keyed by node identity + version. tostring(), NOT the node itself and not `==` (which is a real
    identity comparison since, mexpru.same()'s own comment): a KEY has to be stable
    across handles, and every tree walk hands back a fresh ref to the same node - as a table key
    those would be distinct values, while tostring() is derived from the pointer and so is not.
    It also holds no reference that would keep a cut node alive. Same reasoning as
    reachable_graph()'s own keying below. ]]
    local blink_key = tostring(live_cursor(container)) .. "/" .. tostring(container.version or 0)
    if container._blink_key ~= blink_key then
        container._blink_key = blink_key
        container.frame = 0
    end

    --[[ Selection highlight: one rect per selected slot, spanning from the caret BEFORE it to the
    caret after - the same cell-by-cell shape editor_text.lua paints for plain text, and for the same
    reason. Going through cursor_rect() per slot rather than unioning raw bounding boxes means it
    inherits wrap-awareness and the nested-size baseline correction for free, so a selection on a
    row that wrapped highlights on the right rows.

    A slot whose two carets landed on different wrap rows is the one case a single rect can't
    describe; it gets a short stub, exactly as editor_text.lua does at a line break. Drawn before the
    glyphs below so the text stays legible on top. ]]
    do
        local sel_horiz, sel_lo, sel_hi = mformula_new.selection_range(container)
        if sel_horiz then
            local saved_cursor = container.cursor_pos
            local kids = mexpru.u(sel_horiz).children
            local function caret_at(idx)
                container.cursor_pos = vc.wref_mexpr(idx == 0 and sel_horiz or kids[idx])
                return mformula_new.cursor_rect(container, pos, fontset, wrap_edge)
            end
            for slot = sel_lo + 1, sel_hi do
                local a, b = caret_at(slot - 1), caret_at(slot)
                local right = (math.abs(a.top - b.top) < 0.5) and b.x or (a.x + 8)
                --[[ HEIGHT comes from the selected element's own box, not from the caret band.
                The two carets only know the cursor's line height (cursor_metrics()' G-to-g span),
                which is the same for every slot - so a selected fraction, stack or superscript got
                exactly the same short rectangle as a selected "x", and the highlight said nothing
                about what was actually selected ("for now it's heigh is irelevant of the selected
                items").

                WIDTH still comes from the carets: caret-to-caret spans the glyph's advance, where
                the ink box alone would leave unhighlighted gaps between letters and read as a row
                of separate blocks rather than one selection.

                Falls back to the caret band when the element has no box of its own - an empty
                placeholder, or a zero-ink glyph - since something has to be drawn there. ]]
                local nb = node_box(kids[slot], fontset, sz, wrap_width, container.root)
                local top = nb and (pos.y + nb.y) or math.min(a.top, b.top)
                local bottom = nb and (pos.y + nb.y + nb.h) or math.max(a.bottom, b.bottom)
                vc.ImGui_AddRectFilled({x = a.x, y = top}, {x = right, y = bottom},
                        SELECTION_COLOR, 0)
            end
            container.cursor_pos = saved_cursor
        end
    end

    container.frame = (container.frame or 0) + 1
    if show_cursor then
        local rect = mformula_new.cursor_rect(container, pos, fontset, wrap_edge)
        cursor_top, cursor_h = rect.top - pos.y, rect.bottom - rect.top
        -- Same ~30-frame half-period blink as the old editor's caret (roughly 0.5s at 60fps).
        if math.floor(container.frame / 30) % 2 == 0 then
            local color = innermost_unclosed_open(container) and PENDING_BRACKET_CURSOR_COLOR
                    or CURSOR_COLOR
            vc.ImGui_AddLine({x = rect.x, y = rect.top}, {x = rect.x, y = rect.bottom}, color, 2)
        end
    end

    return BOX_SHAPE.wrap{width = ext.width, top = ext.top, bottom = ext.bottom,
            cursor_top = cursor_top, cursor_h = cursor_h}
end

--[[ How big this formula is, WITHOUT drawing it: {width, top, bottom}, relative to the baseline a
draw() at the same pos would use.

The callers ask every frame, for every formula, in their own layout pass before anything is drawn -
that is how a line grows to fit what is in it. It answers out of content_extent(), the same reading
draw() returns, so a formula cannot measure one size and draw another. Wrapping is included, which
is what lets a wrapped formula claim its extra rows in pass 1 rather than one frame late.
@date 2026-09-08 09:30 ]]
function mformula_new.measure(container, fontset, sz, wrap_width)
    mexpru.check_container(container)
    local ext = content_extent(container, fontset, sz, wrap_width)
    --[[ THE SAME `box` DRAW RETURNS, with the two caret fields simply unset - measuring does not
    place a caret. It has to be the same type: editor.formula_click_rect is handed whichever of the
    two the caller has, and both answer the same question about where the ink is. They were two
    look-alike tables until 2026-09-12, which is why that function could not check what it got. ]]
    return BOX_SHAPE.wrap{width = ext.width, top = ext.top, bottom = ext.bottom}
end

--[[ How every tree edit announces itself: bump the version, and DROP any selection with it.

A selection is a pair of positions in a particular arrangement of the tree; the moment that
arrangement changes it no longer describes anything the user chose. Bumping the version is already
how each edit says "something changed", so the two belong together - stated once here rather than at
each of the eight edit sites, where the next one added would sooner or later forget.

Reported live: "sometimes space selects". An insert left the anchor untouched while the
caret moved on to the newly typed glyph, so a range appeared between the two - a keystroke that
should have cleared a selection conjured one instead.
@date 2026-09-08 09:00 ]]
local function mark_edited(container)
    container.sel_anchor = nil
    container.version = (container.version or 0) + 1
end

--[[ One fresh sup/sub SIDE: an empty atom wrapped in its own one-child horiz, so it can grow into
a real sequence like any other row. Returns both - the atom is what the cursor should name, the
horiz is what goes into the supsub's slot.

Shared by make_supsub() and by handle_input()'s "fill in the missing side" case, which have to build
exactly the same shape.
@date 2026-09-08 09:30 ]]
local function build_side(fontset, sz)
    local empty = build_empty_atom(fontset, sz)
    return empty, mexpru.horiz(fontset, {empty}, sz)
end

--[[ Puts a superscript or a subscript on the atom the cursor names - `slot` says which - by
wrapping it in a fresh supsub and leaving the cursor in the new empty slot. This is what
`math.sup` / `math.sub` do.

(A horiz has nothing specific to wrap, and an atom that is already a base is guarded at the call
site.)

ONLY the requested slot is built - the other stays genuinely nil, not an eager empty placeholder.
mexpr_supsub skips a nil slot's anchor entirely and reserves no space for it, which is what lets
navigation tell "doesn't exist yet" from "exists but empty" with a plain nil check.

base is target ITSELF, not wrapped in a horiz the way sup/sub are: a base is always exactly one
atom, never a sequence. Editing it further is its own case in handle_input().

target's parent MUST be captured before mexpru.supsub() runs: construction reparents target onto
the new supsub, so target:get_parent() afterwards answers the supsub, not the slot to splice into.
That is why the first splice is done by hand here instead of through propagate_rebuild(), whose
"ask old_node for its parent" would be asking the wrong node. The same trap caught the dress path
later - see swap_atom().

sup/sub render SUB_SIZE_DELTA smaller than the base, taken from target's own u(_).sz - the level it
was already rendering at, unchanged by becoming a base - not from any size passed in.

Exported rather than local so a test can call it without simulating key presses, which is this
codebase's own convention. It was exported alongside the get_parent_idx ordering fix below, so that
bug has a regression test against the real function rather than a hand-rolled mirror of it.
@date 2026-09-08 09:30 ]]
function mformula_new.make_supsub(container, fontset, slot, place)
    mexpru.check_container(container)
    --[[ THE WHOLE DECISION LIVES HERE, not half here and half in the key handler. Fill the supsub
    already standing over this base, build one around it, or refuse - plan_decoration answers all
    three, and this is the only entry, so a test calling it directly gets exactly what a keypress
    does. They had already drifted apart once: the handler learned to fill and this did not, so the
    same key did different things depending on which door it came through.

    `place` is where the side is DRAWN - beside the base, or centred over/under it. It is the only
    thing that used to require a second node kind. ]]
    place = place or mexpru.PLACE_BESIDE
    local plan, why = plan_decoration(container.cursor_pos:get_obj(), slot)
    if not plan then
        print("mformula_new: ignoring Ctrl+Shift+=/- - " .. why)
        return
    end

    -- Falls back to the base's own sz when the node is a bare wrapper itself (a resting spot, with
    -- no u(_).sz of its own). Covers a bigop too - it used to say `kind == "supsub"` here and so
    -- built a decoration on a bigop's base at the wrong scale.
    local base_sz = wrapper_base_sz(plan.action == "fill" and plan.base or plan.around)
    local sub_sz = math.min(base_sz + SUB_SIZE_DELTA, MAX_SIZE_INDEX)

    if plan.action == "fill" then
        local new_empty, new_horiz = build_side(fontset, sub_sz)
        fill_wrapper_slot(container, fontset, plan.wrapper, slot, new_horiz, place)
        container.cursor_pos = vc.wref_mexpr(new_empty)
        mark_edited(container)
        return
    end

    local target = plan.around
    local original_parent = target:get_parent()
    --[[ Captured HERE, before mexpru.supsub() runs, for the same reason original_parent is:
    supsub() reparents target onto the new node, and get_parent_idx() always scans whatever target's
    CURRENT parent is. Asked afterwards it answers 1 - target's index inside the new supsub, where
    it is the base - instead of its real index in the row.

    Invisible whenever target already sat at index 1 of its row, which is most sup/sub given to a
    formula's leading atom, and is why it went unnoticed until: "(a)", Left onto "a" at index 2,
    then the sup key overwrote children[1] - the OPEN bracket - leaving "a" untouched and the "("
    gone. ]]
    local target_idx = target:get_parent_idx()

    local new_empty, new_horiz = build_side(fontset, sub_sz)
    local supsub_node = mexpru.supsub(fontset, target,
            (slot == "sup") and new_horiz or nil,
            (slot == "sub") and new_horiz or nil,
            base_sz, place, place)

    --[[ original_parent MUST be a horiz, and until 2026-09-07 nobody checked.

    make_bigop() a few lines down has carried this exact guard from the start; this function never
    grew one, and the asymmetry was invisible for as long as every reachable target happened to sit
    in a horiz. A BIG OPERATOR'S BASE does not: its parent is the bigop itself, which has no
    children list at all, so this line threw
    "attempt to index a nil value (local 'children')" - and threw it AFTER mexpru.supsub() above
    had already reparented `target` into a new node. That is what made it so much worse than a
    no-op: the throw left the tree half-edited with the cursor naming something no longer in it, so
    every arrow key afterwards died in mexpru.u(nil) and the keyboard appeared to stop working.
    Reported 2026-09-07 ("the arrows got stuck"), one error per keypress in the recorder.

    Refusing here restores "the key does nothing" as the worst case. Filling a bigop's free side
    the way handle_input() already fills a supsub's is a real feature and a separate decision -
    this is only the guard. ]]
    local op_u = original_parent and mexpru.u(original_parent)
    if not op_u or op_u.kind ~= "horiz" then
        print("mformula_new: ignoring Ctrl+Shift+=/- here - this atom is not in a row "
                .. "(a big operator's base, for instance); nothing was changed")
        return
    end

    local children = op_u.children
    children[target_idx] = supsub_node
    local rebuilt = mexpru.horiz(fontset, children, mexpru.u(original_parent).sz)
    container.root = mexpru.propagate_rebuild(fontset, original_parent, rebuilt)

    container.cursor_pos = vc.wref_mexpr(new_empty)
    mark_edited(container)
end

--[[ A zero-width OVERPRINTING glyph - one the font declares no advance for, so the next atom
prints on top of it. char.adv_by_desc is the list; today that is \not and \mapstochar.

These are never symbols in their own right. A lone slash is not a thing anyone means to write - it
only exists to negate the atom after it, which is exactly how TeX builds \ne, \notin and \mapsto.
So everything that treats atoms one at a time has to treat an overprint glyph and its neighbour as
ONE, or the pair comes apart into a state the user cannot have asked for.
@date 2026-09-08 09:00 ]]
local function is_overprint(node)
    if not node or node.type ~= vc.MEXPR_TYPE_SYMBOL then
        return false
    end
    local entry = char.find_by_ncod(node.symb.code)
    return entry ~= nil and char.advance_of(entry.desc) == 0
end

--[[ Deletes an overprinted pair as one symbol. Returns whether it did.

Reported live 2026-09-06: "you can write != to get negation, but deleting it leaves the / behind."
Backspace removed only the "=", stranding a slash that renders as a bare mark and means nothing.
A test here even asserted the old behaviour as if it were a feature - it was not; a not-equal reads
as ONE symbol and has to delete like one.

Handled ahead of the ordinary delete path rather than inside it, because that path is built around
the bracket cascade - which this can never be part of. An overprint glyph is never a bracket, and if
either half of the pair somehow carries one, this bails and lets the real cascade logic run.
@date 2026-09-08 09:00 ]]
local function delete_overprint_unit(container, fontset, target, target_parent, backspace)
    mexpru.check_container(container)
    local horiz = target_parent
    if not horiz or mexpru.u(horiz).kind ~= "horiz" then
        return false
    end
    local children = mexpru.u(horiz).children
    local i = target:get_parent_idx()
    if not i then
        return false
    end

    --[[ Backspace deletes the atom the cursor names, so the slash to take with it is the one
    BEFORE. Forward delete removes the next atom, so it only matters when that next atom is itself
    a slash - then the thing it negates has to go too. ]]
    local lo, hi
    if backspace and is_overprint(children[i - 1]) then
        lo, hi = i - 1, i
    elseif (not backspace) and is_overprint(children[i + 1]) and children[i + 2] then
        lo, hi = i + 1, i + 2
    else
        return false
    end

    for k = lo, hi do
        if mexpru.u(children[k]).bracket then
            return false        -- leave anything carrying a bracket to the cascade path
        end
    end

    local cut = {}
    for _ = lo, hi do
        cut[#cut + 1] = table.remove(children, lo)
    end
    -- A row is never allowed to be empty (resolve_bracket_pairs errors on one, and there would be
    -- nowhere to put the cursor) - same fallback every other emptying path here uses.
    if #children == 0 then
        children[1] = build_empty_atom(fontset, mexpru.u(horiz).sz)
    end

    local rebuilt = mexpru.horiz(fontset, children, mexpru.u(horiz).sz)
    container.root = mexpru.propagate_rebuild(fontset, horiz, rebuilt)
    -- "Just before whatever you deleted", the convention the ordinary backspace follows.
    container.cursor_pos = vc.wref_mexpr(lo > 1 and children[lo - 1] or rebuilt)
    -- Cutting waits until propagate_rebuild has completed - see the ordinary path's own note.
    for _, n in ipairs(cut) do
        mexpru.cut(n)
    end
    mark_edited(container)
    return true
end

--[[ ASCII shorthands that become one glyph as you type the second character.

Asked for 2026-09-06: ">= should turn into greater than or equal ... and -> should turn into an
arrow, same with their reverses".

Keyed by what is ALREADY to the left, then by the character being typed. The left-hand key is the
glyph's ascii form where it has one, otherwise its char.lua desc - and that is what makes the
three-character sequences work with no lookahead and no timer: "<" then "=" has already become the
less-or-equal glyph by the time ">" arrives, so ">" extends THAT. Same for "<-" then ">". Every step
is a complete substitution on its own, so there is never a half-finished state to get stuck in.

SHORTHANDS FIRE ON TYPING ONLY. Nothing re-scans for them afterwards - not deletion, not loading a
file, not pasting - and that is what makes the escape work. To write the pair literally, type the
two characters with ANYTHING between them and then remove the separator: Left, Backspace, Right
leaves them adjacent and untouched. (Backspace, not Delete: backspace takes the atom the cursor
names - the separator - where forward delete would take the character after it.) The result
survives save and load, because from_latex does not run this table either. Reported as the trick
2026-09-06; it applies to every entry here.

Do not "fix" this by re-checking adjacency after an edit - that would take the escape away and
there would be no way left to write two dots.
@date 2026-09-08 09:00 ]]
local DIGRAPHS = {
    ["<"] = {["="] = {"\\le"},  ["-"] = {"\\leftarrow"}},
    [">"] = {["="] = {"\\ge"}},
    ["-"] = {[">"] = {"\\rightarrow"}},
    --[[ A single "." stays a period - decimal points and ordinary full stops have to keep
    working, so only the doubled form means the centred multiplication dot. Asked for
    2026-09-06: ".. gives cdot, keep the period as is". ]]
    ["."] = {["."] = {"\\cdot"}},
    --[[ Shapes drawn with the keys themselves: "_|" is a right angle standing on a line,
    "||" is two parallel strokes. Asked for 2026-09-06. A single "|" stays a plain bar (the
    tall bracket is Ctrl+Shift+\\, deliberately kept off this key), and a single "_" stays an
    underscore. ]]
    ["_"] = {["|"] = {"\\perp"}},

    --[[ The number sets: type the capital TWICE. "Double struck" is literally what blackboard
    bold means, so the gesture is the notation. Chosen 2026-09-06 over Alt+Shift+letter, which had
    room for only five of the eight - Q, L and H collide with the integral, Lambda and Theta - and
    splitting one family across two mechanisms is worse than either.

    The cost: "NN" can no longer be written as N times N. That is rare (one would write N^2), and
    the escape is the same as every other shorthand here - put anything between the two. ]]
    ["N"] = {["N"] = {"\\N"}},
    ["Z"] = {["Z"] = {"\\Z"}},
    ["Q"] = {["Q"] = {"\\Q"}},
    ["R"] = {["R"] = {"\\R"}},
    ["C"] = {["C"] = {"\\C"}},
    ["H"] = {["H"] = {"\\H"}},
    ["I"] = {["I"] = {"\\I"}},
    ["L"] = {["L"] = {"\\L"}},
    ["|"] = {["|"] = {"\\parallel"}},
    ["="] = {[">"] = {"\\Rightarrow"}, ["="] = {"\\equiv"}},

    --[[ Two atoms, not one: TeX has no single not-equal glyph, it overprints a zero-width
    \\not on the "=" that follows (char.lua adv_by_desc restores that zero width). So this
    shorthand inserts the pair, exactly what "\\ne" expands to on the LaTeX side. ]]
    ["!"] = {["="] = {"\\not", "="}},

    -- the extensions, applied to the glyph the first pair already produced
    ["\\le"]        = {[">"] = {"\\Leftrightarrow"}},
    ["\\leftarrow"] = {[">"] = {"\\leftrightarrow"}},

    --[[ "or equal" as a composite, the same idea one step further: the proper inclusion goes in
    from Alt+< / Alt+> (char.alt_symbols), and typing "=" after it upgrades the glyph in place.
    Nothing has to know how the inclusion got there - these are keyed on the GLYPH, so it works
    identically whether it came from the Alt key, from pasted LaTeX, or from a loaded file. ]]
    ["\\subset"] = {["="] = {"\\subseteq"}},
    ["\\supset"] = {["="] = {"\\supseteq"}},
    ["\\sim"]    = {["="] = {"\\approx"}},
}

--[[ Characters that stand for a SYMBOL rather than for themselves, substituted as they are typed.

Only "~" so far. In a formula a tilde is never wanted as a literal character - LaTeX uses it for a
non-breaking space, which has no meaning here - whereas "similar to" is an ordinary relation with the
same shape. Asked for 2026-09-06: "~ is similar".

Separate from DIGRAPHS because it replaces NOTHING: it is a one-character substitution at insertion
time, not a rewrite of the glyph to the left. It feeds DIGRAPHS all the same - once the tilde has
become \sim, typing "=" upgrades it to \approx by the ordinary extend rule.
@date 2026-09-08 09:00 ]]
local CHAR_REMAP = {
    ["~"] = "\\sim",
}

--[[ How a glyph is named in DIGRAPHS: its ascii character when it has one, else its desc. acod is
a single NUL for everything that cannot be typed, which is why that is the test.
@date 2026-09-08 09:00 ]]
local function glyph_token(node)
    if not node or node.type ~= vc.MEXPR_TYPE_SYMBOL then
        return nil
    end
    local entry = char.find_by_ncod(node.symb.code)
    if not entry then
        return nil
    end
    if entry.acod and entry.acod ~= string.char(0) then
        return entry.acod
    end
    return entry.desc
end

--[[ Replaces the atom left of the cursor when it and `ch` together form a shorthand. Returns
whether it did, in which case `ch` must NOT also be inserted.

Only fires on a plain glyph sitting directly in a row. A supsub BASE is excluded on purpose:
rewriting one means rebuilding the supsub around it, and "x^{<}" then "=" is not a shorthand anyone
is reaching for - the same reasoning that keeps bracket characters off a base.
@date 2026-09-08 09:00 ]]
local function try_digraph(container, fontset, target, target_is_supsub_base, ch)
    mexpru.check_container(container)
    if target_is_supsub_base then
        return false
    end
    local by_left = DIGRAPHS[glyph_token(target)]
    local descs = by_left and by_left[ch]
    if not descs then
        return false
    end
    --[[ Resolve EVERY piece before touching the row: a shorthand that can only half-build itself
    must not build anything, or "!=" would leave a bare slash behind on a catalog that lost "=". ]]
    local entries = {}
    for i, desc in ipairs(descs) do
        local e = char.find_by_desc(desc)
        if not e then
            return false    -- names a glyph the catalog lacks; fall through and type the character
        end
        entries[i] = e
    end
    local horiz = target:get_parent()
    if not horiz or mexpru.u(horiz).kind ~= "horiz" then
        return false
    end
    local children = mexpru.u(horiz).children
    local idx = mexpru.index_of(children, target)
    if not idx then
        return false
    end

    -- The replacement inherits the LOGICAL level of the glyph it replaces, not the cursor's.
    local sz = mexpru.u(target).sz
    local built = {}
    for i, e in ipairs(entries) do
        local g = mexpru.mexpr_symbol(fontset,
                {size = mexpru.physical_sz(sz), code = e.ncod}, true)
        mexpru.u(g).sz = sz
        built[i] = g
    end

    -- One atom out, however many in. The cursor lands on the LAST, which is where typing continues.
    table.remove(children, idx)
    for i = #built, 1, -1 do
        table.insert(children, idx, built[i])
    end
    local rebuilt = mexpru.horiz(fontset, children, mexpru.u(horiz).sz)
    container.root = mexpru.propagate_rebuild(fontset, horiz, rebuilt)
    container.cursor_pos = vc.wref_mexpr(built[#built])
    mark_edited(container)
    return true
end

-- Exported for tests (the make_supsub()/make_frac() convention): the branches that call these
-- need real keypresses.
mformula_new.try_digraph = try_digraph
mformula_new.delete_overprint_unit = delete_overprint_unit

--[[ Turns a just-typed "\name" into the glyph it names. Returns whether it did.

DELIBERATELY NOT A COMMAND MODE. The backslash and the letters go in as ordinary glyphs, so a
half-typed "\sum" is visible, editable and backspaceable like any other text; this then walks back
from the cursor over the letters to the backslash that opened them and swaps the whole run for one
glyph. There is nothing to display while it is being typed, no pending state to get stuck in, and
abandoning a command is just moving away from it.

It is also the only route to most of the catalog: Alt+letter covers Greek and ordinary keys cover
ASCII, which leaves every big operator, relation, arrow and set symbol with no way in at all.

The name is matched against char.lua's own `desc`, so it is exactly the LaTeX spelling the catalog
records and to_latex() writes back out. size_delta_by_desc is applied on the way in, which is why
"\sum" arrives at display size rather than as the tiny cmex10 glyph that would look wrong beside
its own limits.
@date 2026-09-08 09:30 ]]
function mformula_new.try_resolve_command(container, fontset)
    mexpru.check_container(container)
    local node = live_cursor(container)
    if not node or node.type ~= vc.MEXPR_TYPE_SYMBOL then
        return false
    end
    local horiz = node:get_parent()
    if not horiz or mexpru.u(horiz).kind ~= "horiz" then
        return false
    end
    local children = mexpru.u(horiz).children
    local last = mexpru.index_of(children, node)
    if not last then
        return false
    end

    -- Back over the letters to the backslash that opened the command.
    local letters, first = {}, nil
    for i = last, 1, -1 do
        local ch = children[i]
        if ch.type ~= vc.MEXPR_TYPE_SYMBOL then
            break
        end
        local e = char.find_by_ncod(ch.symb.code)
        if not e then
            break
        end
        if e.acod == "\\" then
            first = i
            break
        end
        if not (e.acod and e.acod:match("%a")) then
            break
        end
        table.insert(letters, 1, e.acod)
    end
    if not first or #letters == 0 then
        return false
    end

    local word = table.concat(letters)

    --[[ AN OPERATOR WORD BECOMES THE 1-TALL VERT IT IS WRITTEN AS - `\\lim` and Space gives `lim`,
    the same container a stack built by hand gives, which is what the parser reads as an operator
    name (mexpr_ast's operator_name).

    WITHOUT THIS THERE WAS NO SHORTCUT FOR THEM AT ALL: `\\lim` is not a catalogued GLYPH, so the
    lookup below found nothing and the command quietly did nothing, leaving the only route as
    "make a one-row stack, then type the letters into it". Asked 2026-09-11: "I think I can also
    spawn them by /command?".

    char.operator_words is the same list the LaTeX reader and writer use, so a word typed here, one
    pasted as `\\lim`, and one loaded from a save all arrive as the identical node. ]]
    if char.operator_word(word) then
        local sz = mexpru.u(children[first]).sz
        local glyphs = {}
        for k = 1, #word do
            local e = char.find_by_ascii(word:sub(k, k))
            if e then
                local g = mexpru.mexpr_symbol(fontset, {size = mexpru.physical_sz(sz),
                        code = e.ncod}, true)
                mexpru.u(g).sz = sz
                glyphs[#glyphs + 1] = g
            end
        end
        if #glyphs == #word then
            local vert = mexpru.vert(fontset, {mexpru.horiz(fontset, glyphs, sz)}, sz)
            mexpru.u(vert).sz = sz
            for _ = first, last do
                table.remove(children, first)
            end
            table.insert(children, first, vert)
            local rebuilt = mexpru.horiz(fontset, children, mexpru.u(horiz).sz)
            container.root = mexpru.propagate_rebuild(fontset, horiz, rebuilt)
            container.cursor_pos = vc.wref_mexpr(vert)
            mark_edited(container)
            return true
        end
    end

    local entry = char.find_by_desc("\\" .. word)
    if not entry then
        return false        -- not a name we know: leave the text alone, insert an ordinary space
    end

    --[[ The command's own size level comes from the backslash it started with, not from the cursor:
    every atom in the run carries the same one, and reading it from the first keeps the result at the
    level the user was typing at. size_delta_by_desc is then applied on top, exactly as the Alt-Greek
    path and the LaTeX parser both do - a LOGICAL level in u(_).sz, a boosted one in the glyph. ]]
    local sz = mexpru.u(children[first]).sz
    local delta = char.size_delta(entry.desc)
    local glyph_sz = delta and math.max(1, math.min(sz + delta, MAX_SIZE_INDEX)) or sz
    local glyph = mexpru.mexpr_symbol(fontset, {size = mexpru.physical_sz(glyph_sz),
            code = entry.ncod}, true)
    mexpru.u(glyph).sz = sz

    for _ = first, last do
        table.remove(children, first)
    end
    table.insert(children, first, glyph)
    local rebuilt = mexpru.horiz(fontset, children, mexpru.u(horiz).sz)
    container.root = mexpru.propagate_rebuild(fontset, horiz, rebuilt)
    container.cursor_pos = vc.wref_mexpr(glyph)
    mark_edited(container)
    return true
end

--[[ Operators that have a DISPLAY form, taken automatically when limits are attached.

"\cup" is the inline union - the one Alt+[ types, correctly small, the size you want in "A \cup B".
The moment it carries limits it is a different operator: "\bigcup", set at display size like a sum.
TeX makes the same distinction, and "\cup" with limits is not a thing anyone writes.

Reported 2026-09-06 as "the union is too small, intersection two" - the limits went on, the glyph
stayed inline-sized, and the result was a tiny union under a full-height "i=0". Promoting here means
Alt+[ needs no second key for the big form: the shape of what you are building decides it.

Only cup and cap for now; the other display forms (\bigvee, \bigwedge, \bigoplus) have no glyph
in these fonts yet.
@date 2026-09-08 09:00 ]]
local DISPLAY_OPERATOR = {
    ["\\cup"] = "\\bigcup",
    ["\\cap"] = "\\bigcap",
}

--[[ Swaps `atom` for its display-size counterpart when it has one, else returns it unchanged.
Rebuilt rather than retagged: the size boost lives in the glyph's own baked geometry (see
char.size_delta_by_desc), so it can only be applied by constructing it afresh.
@date 2026-09-08 09:00 ]]
local function to_display_operator(fontset, atom)
    if not atom or atom.type ~= vc.MEXPR_TYPE_SYMBOL then
        return atom
    end
    local entry = char.find_by_ncod(atom.symb.code)
    local want = entry and DISPLAY_OPERATOR[entry.desc]
    local target = want and char.find_by_desc(want)
    if not target then
        return atom
    end
    local sz = mexpru.u(atom).sz
    local delta = char.size_delta(target.desc)
    local glyph_sz = delta and math.max(1, math.min(sz + delta, MAX_SIZE_INDEX)) or sz
    local g = mexpru.mexpr_symbol(fontset, {size = mexpru.physical_sz(glyph_sz),
            code = target.ncod}, true)
    mexpru.u(g).sz = sz
    return g
end

--[[ Puts a limit ABOVE or BELOW what the cursor rests on - `slot` says which - turning it into a
BIG OPERATOR: a sum with bounds, an integral, a "lim" with what it tends to.

Its own shortcut rather than something inferred, because nothing about a glyph says whether its sup
belongs beside it or over it; the keystroke is what decides. Pressed on a bigop that already exists
it FILLS the empty side instead of nesting a second one, which is the only way to get both limits
without building a bigop inside a bigop.

Refuses on an empty slot: a limit sits on an operator, and there has to be one there to sit on.

The capture-before-you-wrap discipline is make_supsub()'s - mexpru.bigop() reparents target as it
builds, so the parent and the index have to be read first.
@date 2026-09-08 09:30 ]]
function mformula_new.make_bigop(container, fontset, slot)
    mexpru.check_container(container)
    --[[ The limit keys, which are the sup/sub keys with the other placement. This was a separate
    function over a separate node kind until 2026-09-10; what survives of it is the guard below and
    the operator's own display form, both of which are about big operators specifically rather than
    about how a side is drawn.

    A limit needs something to sit on. Without this guard an empty slot became the base of a second
    wrapper nested inside the first - reported 2026-09-07 as "inside a bigop-sup and empty I can't
    delete it", the two nested empties drawing identically to one, so the formula looked unchanged
    while Backspace had an invisible structure to collapse first and appeared to do nothing. ]]
    local target = container.cursor_pos:get_obj()
    if target.type == vc.MEXPR_TYPE_EMPTY_BOX then
        print("mformula_new: ignoring Ctrl+Shift+[/] in an empty slot - a limit needs an "
                .. "operator to sit on; type one first")
        return
    end

    --[[ An inline union/intersection becomes its display form the moment it takes limits. Done
    before the decoration, since it replaces the glyph the decoration will sit on. ]]
    if not is_supsub(target) and not is_wrapper_base(target, target:get_parent()) then
        local display = to_display_operator(fontset, target)
        if not mexpru.same(display, target) then
            container.root = mexpru.propagate_rebuild(fontset, target, display)
            container.cursor_pos = vc.wref_mexpr(display)
        end
    end

    mformula_new.make_supsub(container, fontset, slot, mexpru.PLACE_DISPLAY)
end

--[[ THE `base_glyph` CONTAINER - the glyph a formula can be started FROM, and the whole of what
this module needs to know about where that glyph came from.

IT EXISTS TO KEEP A TEXT ITEM OUT OF HERE. new_from_base took editor_text.lua's own `chars` entry
until 2026-09-12 and read `code` and `size_off` off it, which made this module - the one the text
editor is built ON - depend on the shape of a text item. It could not even be checked: editor_text
requires mformula_new, so reaching back for a checker would have been a require cycle, and the
layering was the reason rather than an obstacle to work around. Those two values were all that was
ever used, so they are their own type now, owned here, and the translation happens at the single
call site. Author, 2026-09-12: "mformula_new shouldn't know about text items".
@date 2026-09-12 23:55 ]]
local BASE_GLYPH_FIELDS = {
    code     = "the glyph's ncod - char.lua's catalogue code",
    size_off = "logical size steps for this glyph, negative = bigger; absent means none",
}
local BASE_GLYPH_SHAPE = sealed.declare("mformula_new", "base_glyph", BASE_GLYPH_FIELDS)

--[[ The one creator for a base_glyph.

Core: names the two values new_from_base takes, so a caller holding a glyph in a shape of its own
converts it HERE rather than trusting that its own table is close enough - which is exactly what the
old signature had no way to refuse.

Params: `code` the glyph's ncod, `size_off` its size boost or nil. Returns the sealed container.
@date 2026-09-12 23:55 ]]
function mformula_new.base_glyph(code, size_off)
    return BASE_GLYPH_SHAPE.wrap{code = code, size_off = size_off}
end

--[[ A brand-new formula that is one supsub, whose BASE is `base_glyph` (or nil), with the cursor
waiting in the requested `slot` ("sup"/"sub").

editor_text.lua's own plain-text Ctrl+Shift+=/- calls this: with the caret after an ordinary character it
lifts that character out of the text stream and hands it here, so "x" then Ctrl+Shift+= becomes an
"x" with the caret sitting in its exponent - the same gesture that, INSIDE a formula, make_supsub()
already provides. nil base_glyph (nothing typed before the caret) gets a fresh empty atom to hang the
slot off instead, matching editor_text.lua's own "no preceding character... base is just left empty".

Ported, the last of the old editor's exports with no counterpart here - until then
editor_text.lua:534 called straight through to a nil field and threw ("attempt to call a nil value (field
'new_from_base')") the moment Ctrl+Shift+=/- was pressed in plain text. Unlike the old row-based
version there is no need to eagerly build the OPPOSITE slot as well: sup/sub are lazy in this model
(build_side()'s own comment), and the Ctrl+Shift+=/- handler fills a missing side in place when it's
actually asked for.
@date 2026-09-08 09:00 ]]
function mformula_new.new_from_base(fontset, sz, base_glyph, slot)
    local base
    if base_glyph then
        BASE_GLYPH_SHAPE.check(base_glyph, "base_glyph")
        -- size_off is the same per-glyph visual boost editor_text.lua bakes in (currently only "\\int") -
        -- carried into the real construction call, while u(_).sz stays the nominal LOGICAL level,
        -- exactly as the Alt-Greek path and mformula_latex.lua's own parser both do.
        local glyph_sz = base_glyph.size_off
                and math.max(1, math.min(sz + base_glyph.size_off, MAX_SIZE_INDEX)) or sz
        base = mexpru.mexpr_symbol(fontset, {size = mexpru.physical_sz(glyph_sz),
                code = base_glyph.code}, true)
        mexpru.u(base).sz = sz
    else
        base = build_empty_atom(fontset, sz)
    end

    local slot_sz = math.min(sz + SUB_SIZE_DELTA, MAX_SIZE_INDEX)
    local slot_empty, slot_horiz = build_side(fontset, slot_sz)
    local supsub_node = mexpru.supsub(fontset, base,
            slot == "sup" and slot_horiz or nil,
            slot == "sub" and slot_horiz or nil)
    local root = mexpru.horiz(fontset, {supsub_node}, sz)
    mexpru.update_positions(root)
    return mexpru.new_container(root, slot_empty)
end

--[[ A fresh container that is already one empty fraction, with the cursor in the numerator - what
`formula.new_frac` inserts, so a fraction can be started from plain text without making an empty
formula first, and the next keystroke lands where it is wanted.

Built inline rather than through make_frac(), for the same reason new() calls no insert helper:
those splice into an EXISTING container at an existing cursor, and there is no container here yet
for one to read.
@date 2026-09-08 09:30 ]]
function mformula_new.new_with_frac(fontset, sz)
    local num_empty, num_horiz = build_side(fontset, sz)
    local _, den_horiz = build_side(fontset, sz)
    local frac_node = mexpru.frac(fontset, num_horiz, den_horiz, sz)
    local root = mexpru.horiz(fontset, {frac_node}, sz)
    mexpru.update_positions(root)
    return mexpru.new_container(root, num_empty)
end

--[[ `formula.new_stack` in plain text: a brand-new formula that is one single-slot stack, cursor
already inside that slot - the text-mode entry point, exactly parallel to new_with_frac() for
`formula.new_frac` and new() for `formula.new` ("make ctrl+ spawn the vector when in text mode same as the
other containers"). Starting at ONE slot matches what Ctrl+= does inside a formula: a
stack is born with a single row and grows by pressing it again (make_vert()/test_vert.lua's own
one-slot floor).

Built inline rather than by calling make_vert(), the same reason new_with_frac() doesn't call
make_frac(): both of those splice into an EXISTING container at an existing cursor_pos, and there is
no container yet here for them to read one from.
@date 2026-09-08 09:00 ]]
function mformula_new.new_with_vert(fontset, sz)
    local slot_empty, slot_horiz = build_side(fontset, sz)
    local root = mexpru.horiz(fontset, {mexpru.vert(fontset, {slot_horiz}, sz)}, sz)
    mexpru.update_positions(root)
    return mexpru.new_container(root, slot_empty)
end

--[[ Arrow-key navigation. None of it touches the tree - only container.cursor_pos - and cursor
movement deliberately never bumps container.version, so it does not become an undo step.

Four resting-position kinds matter, dispatched by is_horiz()/is_supsub()/whether target is a base:
  - a horiz at position 0, before its first child
  - a plain atom (empty or glyph) in some horiz
  - a supsub's own base atom
  - a supsub node itself, meaning "after the whole compound"

Left/Right walk reading order: between adjacent slots of a horiz, and at the edges of a sup/sub
horiz, into or out of that supsub - base on the left, the supsub itself on the right. That asymmetry
is deliberate; see move_right(). Up/Down move between a base and the END of whichever of sup/sub
exists, and from elsewhere inside sup/sub reach toward base directly (non-reciprocal). When that
fails locally, walk_up_vertical() climbs for a context where the motion does resolve.
@date 2026-09-08 09:00 ]]
local function is_horiz(node)
    return mexpru.u(node).kind == "horiz"
end

-- A fraction node: num and den, both horizes, both always present. @date 2026-09-08 09:30
local function is_frac(node)
    return mexpru.u(node).kind == "frac"
end

-- A decoration around a target - see unwrap(): a wrapper, never an atom in its own right. @date 2026-09-08 09:30
local function is_dress(node)
    return mexpru.u(node).kind == "dress"
end

--[[ What a descent into this slot actually enters: a dress is a WRAPPER, not an atom, so it hands
navigation on to whatever it holds.

The original design made a dress opaque - "a dressed element simply takes the place of the target
glyph and is else considered an atom itself". That is indistinguishable from wrapping while the
target is a GLYPH, since a glyph is a single position either way, which is why it held up until a
stack got dressed: "\hat{\stack{ABC}}" put a whole navigable structure behind an atom and made
every row inside it unreachable. Reported live: "a ^ can't be considered as a glyph,
that is the problem... a dress should act as a wrapper, it should forward most of the navigation to
the held value".

Only DESCENT unwraps. Upward the dress is still the atom occupying its slot - it is what the row
holds, what Left/Right step over as one unit, and what mexpru.slot_atom() reports a bracket or a
sprint landmark through. The decoration itself is never a destination in either direction; that part
of the original design is unchanged.

Recursive, since a dress can wrap a dress in principle (nothing builds that today - see
dressable_target() - but the walk should not depend on that staying true).
@date 2026-09-08 09:00 ]]
local function unwrap(node)
    while node and is_dress(node) and mexpru.u(node).target do
        node = mexpru.u(node).target
    end
    return node
end

--[[ A "vert" - N stacked slots, each a horiz (mexpru.vert()). Navigationally it behaves like a
frac with an arbitrary number of rows instead of exactly two: Left/Right treat the whole stack as
one atom, Up/Down step between its slots, and running off either end climbs out the same way a
frac's own num/den do.
@date 2026-09-08 09:00 ]]
local function is_vert(node)
    return mexpru.u(node).kind == "vert"
end

--[[ Is `node` (an atom) a supsub's own base? Returns that supsub too, or nil, nil if not - saves
every caller from re-deriving get_parent()/kind/same() by hand each time.
@date 2026-09-08 09:00 ]]
local function base_of(node)
    local parent = node:get_parent()
    if parent ~= nil and is_supsub(parent) and mexpru.same(mexpru.u(parent).base, node) then
        return parent
    end
    return nil
end

-- '(' / '[' / '{' -> bracket type, and back - entangled-bracket opening (open_bracket() below).
local OPEN_BRACKETS = {
    ["("] = vc.MEXPR_BRACKET_ROUND, ["["] = vc.MEXPR_BRACKET_SQUARE, ["{"] = vc.MEXPR_BRACKET_CURLY,
}
local OPEN_BRACKET_ASCII = {
    [vc.MEXPR_BRACKET_ROUND] = "(", [vc.MEXPR_BRACKET_SQUARE] = "[", [vc.MEXPR_BRACKET_CURLY] = "{",
}

--[[ The "|" delimiter, on `math.bar_bracket` - ONE shortcut that both opens and closes.

Deliberately a KEY and not the "|" character, asked for in exactly those terms: "that is
why I've said to put it on ctrl+shift+|, such that '|' is not affected". Binding the character
instead would have made a literal bar untypeable, the way "(" is not a literal today - which for a
bar is a real loss, since it is ordinary content in its own right.

The bar is NOT a third kind of bracket in the model: its atoms carry the ordinary
u(_).bracket = {is_open, type, peer}, so the counter rule, scan_bracket(), peer_slot() and the
cascade delete keep working untouched. All that differs is how the SHORTCUT is read - close if one
is pending and the cursor may legally close it, open otherwise (see the handler in handle_input()).

A consequence worth stating: bars cannot nest. With a single pending slot the second press always
closes the first, so "||a||" is unreachable - the same ambiguity that makes LaTeX demand
\left|...\right| for it, not a limitation introduced here.

OPEN/CLOSE_BRACKET_ASCII both map it to "|" because those drive GLYPH lookup (find_by_ascii) in
open_bracket()/try_close_bracket()/rescale_node() - both halves of a bar pair really are drawn with
the same character. Serialization does NOT use them for the bar: with "|" still a literal, "|" on
its own would be ambiguous on reload, so mformula_latex.lua writes \lvert/\rvert instead.

nil until C++ registers MEXPR_BRACKET_BAR (math_expr_composer.h); until then the handler below is
unreachable and nothing changes.
@date 2026-09-08 09:00 ]]
local BAR_BRACKET = vc.MEXPR_BRACKET_BAR
if BAR_BRACKET then
    OPEN_BRACKET_ASCII[BAR_BRACKET] = "|"
end

-- ')' / ']' / '}' -> bracket type, and back - entangled-bracket closing (try_close_bracket() below).
local CLOSE_BRACKETS = {
    [")"] = vc.MEXPR_BRACKET_ROUND, ["]"] = vc.MEXPR_BRACKET_SQUARE, ["}"] = vc.MEXPR_BRACKET_CURLY,
}
local CLOSE_BRACKET_ASCII = {
    [vc.MEXPR_BRACKET_ROUND] = ")", [vc.MEXPR_BRACKET_SQUARE] = "]", [vc.MEXPR_BRACKET_CURLY] = "}",
}
-- Same character on both sides - that IS the bar (BAR_BRACKET above).
if BAR_BRACKET then
    CLOSE_BRACKET_ASCII[BAR_BRACKET] = "|"
end

--[[ The catalog entry for one half of a bracket pair.

MOST PAIRS ARE ASCII and are found by character. The integral's are not: its halves are the operator
glyph and the letter `d`, so its open half is found by DESC. One function rather than three lookups,
because there are three places that need a half's glyph - opening, closing, and rescaling on zoom -
and a pair whose glyph one of them cannot find is a pair that half-survives a zoom.
@date 2026-09-10 23:40 ]]
local function bracket_entry(bracket_type, is_open)
    if bracket_type == char.BRACKET_INTEGRAL then
        if is_open then
            return char.find_by_desc("\\int")
        end
        return char.find_by_ascii("d")
    end
    local ascii
    if is_open then
        ascii = OPEN_BRACKET_ASCII[bracket_type]
    else
        ascii = CLOSE_BRACKET_ASCII[bracket_type]
    end
    return ascii and char.find_by_ascii(ascii)
end


--[[ Splices a freshly-built glyph atom (`new_glyph` - ALREADY tagged with whatever it needs, at
minimum u(_).sz, same as every atom this file builds carries) into the tree at cursor_pos, per this
file's own model comment's REPLACE/INSERT-AT-START/INSERT-AFTER/bump-old-base-out rules - shared by
the ordinary character-typing loop in handle_input() below and open_bracket()'s own placeholder
insertion (a bracket atom is typed exactly like any other character at this point - it's just an
ordinary ASCII glyph with extra bookkeeping tagged on), so both go through the identical splice
mechanics rather than duplicating them. Moves cursor_pos to `new_glyph` and bumps container.version,
same as every tree-editing operation in this file already does.
@date 2026-09-08 09:00 ]]
local function insert_glyph_at_cursor(container, fontset, target, target_parent, target_is_horiz,
        target_is_empty, target_is_supsub_base, target_sz, new_glyph)
    if target_is_empty then
        container.root = mexpru.propagate_rebuild(fontset, target, new_glyph)
    elseif target_is_horiz then
        local children = mexpru.u(target).children
        table.insert(children, 1, new_glyph)
        local rebuilt = mexpru.horiz(fontset, children, target_sz)
        container.root = mexpru.propagate_rebuild(fontset, target, rebuilt)
    elseif target_is_supsub_base then
        local supsub_node = target_parent
        local outer_horiz = supsub_node:get_parent()
        local outer_children = mexpru.u(outer_horiz).children
        local u = mexpru.u(supsub_node)
        local rebuilt_supsub = mexpru.supsub(fontset, new_glyph, u.sup, u.sub)

        local idx = supsub_node:get_parent_idx()
        outer_children[idx] = rebuilt_supsub
        table.insert(outer_children, idx, target)

        local rebuilt_outer = mexpru.horiz(fontset, outer_children, mexpru.u(outer_horiz).sz)
        container.root = mexpru.propagate_rebuild(fontset, outer_horiz, rebuilt_outer)
    else
        local horiz = target_parent
        local children = mexpru.u(horiz).children
        local idx = target:get_parent_idx()
        table.insert(children, idx + 1, new_glyph)
        local rebuilt = mexpru.horiz(fontset, children, mexpru.u(horiz).sz)
        container.root = mexpru.propagate_rebuild(fontset, horiz, rebuilt)
    end

    container.cursor_pos = vc.wref_mexpr(new_glyph)
    mark_edited(container)
end


--[[ Splices a freshly built COMPOUND (a fraction, a stack) in at the cursor, then parks the cursor
wherever the caller says - typically inside the compound's own first slot.

Goes through insert_glyph_at_cursor() above rather than splicing by hand, because that function
already knows all four things cursor_pos can be sitting on - and one of them was being missed: an
EMPTY placeholder atom. make_frac()/make_vert() used to insert AFTER the cursor's atom
unconditionally, so doing either on a brand-new formula - whose only content IS that placeholder -
left the placeholder sitting to the compound's left, rendering as a blank gap that nothing could
delete and nothing explained. Reported live: "see how for no reason the vecotr has an
empty space to it's left, why?". On an empty atom the right splice is to REPLACE it, which is
exactly the case insert_glyph_at_cursor() already handles.

Lives HERE, below insert_glyph_at_cursor(), not up beside make_supsub() where the other
compound-builders used to sit - same forward-reference constraint make_vert() records further down.
No mark_edited() of its own: insert_glyph_at_cursor() already did it.
@date 2026-09-08 09:00 ]]
local function insert_compound_at_cursor(container, fontset, node, target_sz, cursor_to)
    local target = container.cursor_pos:get_obj()
    local tp = target:get_parent()
    insert_glyph_at_cursor(container, fontset, target, tp,
            mexpru.u(target).kind == "horiz",
            target.type == vc.MEXPR_TYPE_EMPTY_BOX,
            is_wrapper_base(target, tp),
            target_sz, node)
    container.cursor_pos = vc.wref_mexpr(cursor_to)
end

--[[ `math.frac`: inserts a fresh, empty fraction AT the cursor position and moves the cursor into
its numerator. Unlike make_supsub(), never WRAPS whatever's already there - a
fraction has no single preceding glyph that obviously belongs in either half (num/den are each a
full horiz, built from nothing, not derived from an existing atom) - see this file's own top model
comment and the fraction design discussion. Built at cursor_pos's own current size level
(target_sz, matching make_supsub()'s own reasoning) - num/den render at that SAME size, not shrunk
(mexpru.frac()'s own doc comment). Caller is responsible for the "on a supsub's own base" no-op
check (see handle_input() below) - this function assumes it's always safe to insert, same division
of responsibility as make_supsub()'s own call site handling the "already has this side" no-op
instead of make_supsub() itself.

Exported alongside make_supsub(), same reasoning: directly testable without simulating key presses.
@date 2026-09-08 09:30 ]]
function mformula_new.make_frac(container, fontset, target_sz)
    mexpru.check_container(container)
    local num_empty, num_horiz = build_side(fontset, target_sz)
    local _, den_horiz = build_side(fontset, target_sz)
    insert_compound_at_cursor(container, fontset, mexpru.frac(fontset, num_horiz, den_horiz,
            target_sz), target_sz, num_empty)
end

--[[ '(' / '[' / '{' typed (bracket_type = OPEN_BRACKETS[ch]): builds the placeholder open-bracket
glyph - an ordinary ASCII glyph at this point, same as any other typed character - and splices it in
via insert_glyph_at_cursor(), the exact same 4-way splice an ordinary typed character goes through,
since at this point it genuinely IS just an ordinary character as far as the tree is concerned. Tags
it u(_).bracket = {is_open=true, type=bracket_type}. Nothing is recorded anywhere else - the row
IS the record, and innermost_unclosed_open() reads it back by the counter rule - a
single slot, not a stack (opening a SECOND bracket while one is already pending is a no-op/blocked -
see this function's own call site in handle_input()). While pending, mformula_new.draw() shows a
purple cursor (PENDING_BRACKET_CURSOR_COLOR) instead of the ordinary CURSOR_COLOR.
@date 2026-09-08 09:00 ]]
local function open_bracket(container, fontset, target, target_parent, target_is_horiz,
        target_is_empty, target_is_supsub_base, target_sz, bracket_type)
    mexpru.check_container(container)
    local entry = bracket_entry(bracket_type, true)
    --[[ target_sz is LOGICAL - mapped to PHYSICAL only for the real construction call below, same as
    every other glyph this file builds (mexpru.rescale()'s own comment). The desc's own size boost is
    applied on top, which matters for exactly one bracket half so far: `\int` is drawn a few levels
    up from the text around it (char.size_delta_by_desc), and an integral opened without it came out
    the height of a letter. u(_).sz stays the surrounding NOMINAL level either way. ]]
    local delta = char.size_delta(entry.desc)
    local glyph_sz = target_sz
    if delta then
        glyph_sz = math.max(1, math.min(target_sz + delta, MAX_SIZE_INDEX))
    end
    local new_glyph = mexpru.mexpr_symbol(fontset, {size = mexpru.physical_sz(glyph_sz), code = entry.ncod}, true)
    mexpru.u(new_glyph).sz = target_sz
    mexpru.u(new_glyph).bracket = {is_open = true, type = bracket_type}

    insert_glyph_at_cursor(container, fontset, target, target_parent, target_is_horiz,
            target_is_empty, target_is_supsub_base, target_sz, new_glyph)

end

--[[ The innermost still-unclosed open bracket to the LEFT of the cursor, or nil.

This REPLACED a stored container.pending_bracket slot on 2026-09-06. That slot could hold exactly
one bracket, so typing a second open while one was unclosed was a silent no-op - "{" could never be
closed over "(", and "{()}" was unreachable. Reported as "a wrong limitation", and it was: the row
already contains every bracket, so a parallel slot was never a model of the state, only a cache of
one fact about it.

The rule is the counter, stated by the user and already written as mexpru.bracket_count: walking
left, a close raises the depth, an open lowers it, and the first open met at depth zero is ours.
"{ ( a ) |" walks ")" to depth 1, "(" back to 0, and finds "{".

Read through slot_atom, because a ")" is frequently a supsub base ("(a)^2") and invisible to any
walk reading children directly - the blind spot that has produced six live bugs now.

A RESOLVED open at depth zero means the cursor is INSIDE a finished pair, so nothing at this level
is closable from here and the answer is nil - which is what keeps a close from crossing out of the
pair it sits in.

Forward-declared near PENDING_BRACKET_CURSOR_COLOR - see the note there for why.
@date 2026-09-08 09:30 ]]
function innermost_unclosed_open(container)
    mexpru.check_container(container)
    local node = container.cursor_pos and container.cursor_pos:get_obj()
    if not node then
        return nil
    end
    local horiz, idx
    if is_horiz(node) then
        horiz, idx = node, 0            -- resting on the row itself: slot 0, nothing to the left
    else
        -- A base occupies its supsub's own slot, the same convention every other walk here uses.
        local carrier = base_of(node) or node
        horiz = carrier:get_parent()
        idx = carrier:get_parent_idx()
    end
    if not horiz or mexpru.u(horiz).kind ~= "horiz" or not idx then
        return nil
    end

    local children = mexpru.u(horiz).children
    local depth = 0
    for i = idx, 1, -1 do
        local atom = children[i] and mexpru.slot_atom(children[i])
        local br = atom and mexpru.u(atom).bracket
        if br then
            if not br.is_open then
                depth = depth + 1
            elseif depth > 0 then
                depth = depth - 1
            elseif not br.peer then
                return atom
            else
                return nil              -- inside a resolved pair; closing here would cross
            end
        end
    end
    return nil
end

-- Exported for tests: this is the whole of the bracket-nesting rule, and worth pinning directly.
mformula_new.innermost_unclosed_open = innermost_unclosed_open
--[[ Exported for testability only, the same convention make_supsub()/try_digraph() already follow:
the integral's open and close cannot be reached from a test any other way, since both live behind
the character queue and one of them behind an Alt chord. ]]
mformula_new.pending_integral = pending_integral
mformula_new.open_bracket = open_bracket

--[[ THE definition of where a still-PENDING bracket may close - one source of truth, shared by
try_close_bracket() (which refuses anything outside it) and by the arrow-key cursor confinement
(which stops the cursor getting outside it at all). One definition, because those two answering
differently is exactly how the malformed states arose.

`node` is a candidate position; returns the resolved close target, or nil. Legal means all of:
  - it resolves to a direct sibling of the pending open atom (a base reads as occupying its
    supsub's slot, which is what lets a pair close onto a ")" that is itself a base - "(a+b)^{2}"),
  - at or after the open atom's index - never close to the left of your own open,
  - and NOT at or past the close of whatever pair ENCLOSES the pending open.

That last clause is the whole "(_1 (_2 a )_1 )_2" bug: with "(_2" pending inside a resolved pair,
nothing stopped the cursor walking onto ")_1" and closing there, interleaving instead of nesting.
It renders and even serializes as an innocent "((a))" - the damage is only in the peer links, which
is why every downstream walk quietly built on a structure that was never valid. The enclosing close
comes from mexpru.scan_bracket() rather than a hand-rolled depth walk; nil means nothing encloses
it, so there is no right-hand bound at this level.
@date 2026-09-08 09:30 ]]
local function close_position_ok(container, node, open_atom)
    open_atom = open_atom or innermost_unclosed_open(container)
    if not open_atom then
        return nil
    end
    local open_horiz = open_atom:get_parent()
    if not open_horiz then
        return nil
    end

    local target = node
    local base_owner = base_of(target)
    if base_owner then
        target = base_owner
    end
    if is_horiz(target) then
        return nil
    end
    local parent = target:get_parent()
    if not parent or not mexpru.same(parent, open_horiz) then
        return nil
    end

    local open_idx = open_atom:get_parent_idx()
    local idx = target:get_parent_idx()
    if open_idx == 0 or idx == 0 or idx < open_idx then
        return nil
    end

    --[[ THE counter rule (mexpru.bracket_count(), and its own comment): everything strictly between
    the pending open and the position we'd close at must be BALANCED - the running count of open
    brackets back to zero - and must never have gone negative on the way, since going negative means
    stepping over the close of the pair that encloses us.

    Both halves matter and each one is a real bug that happened here. Non-zero means inner brackets
    are still open, so closing would interleave them with ours ("(_1 (_2 a )_1 )_2"). Negative means
    we walked out of our own enclosing group entirely. And because the count comes from
    mexpru.bracket_delta(), it also sees a bracket that is a supsub's BASE rather than a sibling
    ("(a)^{N}") - invisible to the depth-tracked scan this replaces, which simply walked past such a
    bracket and reported an unrelated one as the boundary. ]]
    local count = mexpru.bracket_count(mexpru.u(open_horiz).children, open_idx + 1, idx)
    if count ~= 0 then
        return nil
    end
    return target
end

--[[ The movement half of close_position_ok() above: while a bracket is pending, the cursor is
confined to that bracket's own closable region for exactly as long as it stays open - no descending
into a sup/sub/frac slot, no climbing out of the horiz, no walking past an enclosing pair's close.
Requested directly: "the user should not be able to pass outside the acceptable place to
place a bracket area, so shouldn't be able to travel to sup or sub, or whatever else".

This is what turns the whole family of "stuck, un-closeable pending bracket" states from things to
be guarded one entry point at a time into things that simply cannot be reached: every one of them
began with the cursor wandering somewhere its pending bracket could never close from, which is no
longer a place it can go. The pending open atom's own slot is itself inside the region, so
backspacing the bracket away always stays possible - confined, never trapped.

With nesting it is the INNERMOST unclosed bracket that confines the cursor, so the region shrinks as
more are opened. Settled 2026-09-06, when the single pending slot became a counter over the row.
@date 2026-09-08 09:30 ]]
local function cursor_pos_forbidden(container, node)
    return innermost_unclosed_open(container) ~= nil
            and close_position_ok(container, node) == nil
end

--[[ A closing bracket was typed: matches it against the pending open one, or swallows it.
Returns whether it actually closed one.

It closes only when a bracket IS pending, its type matches, and the cursor is somewhere
close_position_ok() allows. Anything else is a pure no-op - and the character is not inserted as
content either, because closing brackets are reserved and never text.

A close landing exactly ON the open atom closes an EMPTY pair, and a fresh empty atom fills the gap,
because resolve_bracket_pairs() errors loudly on a pair with an empty span. Only in that case: real
content already there needs no filler and drives both brackets' size itself.

Once matched, BOTH atoms get .peer set to the other's u table, and the rebuild triggered right here
resolves the pair into properly sized glyphs - until this moment the open atom has been rendering as
an ordinary unsized character.

The RETURN VALUE replaced a trick: the bar shortcut used to detect success by watching a stored
pending slot go nil. Once the pending open is derived from the row instead of stored, there is no
slot to watch, so the honest signal is the one it should always have been.
@date 2026-09-08 09:30 ]]
local function try_close_bracket(container, fontset, bracket_type)
    mexpru.check_container(container)
    -- The innermost unclosed open, found by the counter rule - see innermost_unclosed_open().
    local open_atom = innermost_unclosed_open(container)
    if not open_atom then
        return false
    end
    local open_bracket_u = mexpru.u(open_atom).bracket
    --[[ A type mismatch here IS the no-crossing rule: the innermost unclosed open is the only one
    a close can pair with, so "{(a}" refuses rather than reaching past the "(". ]]
    if open_bracket_u.type ~= bracket_type then
        return false
    end
    local open_horiz = open_atom:get_parent()

    -- One shared legality check (close_position_ok() above) rather than this function's own
    -- open-ended "same parent, at or after open_idx" test - that one had no right-hand bound, so
    -- it happily interleaved pairs into "(_1 (_2 a )_1 )_2". See that function's own comment.
    local cursor_node = container.cursor_pos:get_obj()
    local close_target = close_position_ok(container, cursor_node, open_atom)
    if not close_target then
        return false
    end
    -- Non-nil exactly when the cursor is sitting ON a supsub's own base (rather than on the supsub
    -- itself, or on any ordinary sibling) - the one case that closes INTO the base below.
    local closing_onto_base = base_of(cursor_node)

    local open_idx = open_atom:get_parent_idx()
    local close_target_idx = close_target:get_parent_idx()

    local children = mexpru.u(open_horiz).children
    local close_sz = mexpru.u(open_atom).sz
    local close_entry = bracket_entry(bracket_type, false)
    -- close_sz is LOGICAL - mapped to PHYSICAL only for the real construction call (same reasoning
    -- as open_bracket()'s own new_glyph construction just above).
    local close_glyph = mexpru.mexpr_symbol(fontset, {size = mexpru.physical_sz(close_sz), code = close_entry.ncod}, true)
    mexpru.u(close_glyph).sz = close_sz

    local close_idx
    if closing_onto_base then
        --[[ Closing with the cursor ON a supsub's base puts the ")" in as that supsub's NEW base,
        bumping the old one out just before it: "(a^{N}" closed here becomes "(a)^{N}", not
        "(a^{N})".

        Deliberately only the CLOSING half - nothing here ever conjures an opening bracket ("I want
        only to be able to close after base, not to open there"). You open where you already could,
        walk to the base, and close there; the two brackets you get are the two you typed.

        Without it, the "a base reads as occupying its supsub's slot" convention - still exactly
        right for deciding LEGALITY just above - would also decide PLACEMENT, dropping the ")" after
        the whole compound and putting the exponent inside the parens. Legality and placement
        genuinely differ here, which is why only placement is special-cased.

        The pair is peer-linked but never tier-resolved, since its ")" is not in the flat children
        list resolve_bracket_pairs() walks - identical to the "(a)^{N}" you get by typing "(a)" and
        adding the exponent after, so this is a second route to an existing shape. ]]
        local supsub_node = close_target
        local u = mexpru.u(supsub_node)
        children[close_target_idx] = mexpru.supsub(fontset, close_glyph, u.sup, u.sub)
        table.insert(children, close_target_idx, cursor_node)
        -- The old base now occupies close_target_idx; the rebuilt supsub sits one along. Neither is
        -- where the ")" itself lives (it's the base INSIDE that supsub, not a slot of its own), so
        -- close_idx names the supsub and the cursor is set from close_glyph directly below.
        close_idx = nil
    elseif close_target_idx == open_idx then
        local filler = build_empty_atom(fontset, close_sz)
        table.insert(children, open_idx + 1, filler)
        table.insert(children, open_idx + 2, close_glyph)
        close_idx = open_idx + 2
    else
        table.insert(children, close_target_idx + 1, close_glyph)
        close_idx = close_target_idx + 1
    end

    --[[ peer is the other atom's own u TABLE, both ways round (mexpru.lua's own top comment on the
    convention, and what every peer lookup compares against). The close side used to be handed
    `open_bracket_u` - which despite the name is the open atom's BRACKET table, not its u table - so
    the close->open link pointed at an object no lookup would ever match.

    That stayed invisible for as long as every pair got resolved: resolve_bracket_pairs() rewrites
    BOTH links correctly the moment it resolves one, papering over the bad one immediately. A pair
    closed onto a supsub's base is the one kind it can never resolve (that ")" is a base, not a
    sibling in the flat list it walks), so there the wrong link simply survived - the pair read as
    linked from the open side and as orphaned from the close side. Cascade-delete then found nothing
    to take down with it and left a bracket behind: "((A)^{N})" backspaced down to the unbalanced
    "((A)" (reported live, "reached an invalid state"). ]]
    mexpru.u(close_glyph).bracket = {is_open = false, type = bracket_type, peer = mexpru.u(open_atom)}
    open_bracket_u.peer = mexpru.u(close_glyph)

    -- children[close_idx] is read AFTER the rebuild below, not a local variable holding close_glyph
    -- directly - resolve_bracket_pairs() (mexpru.lua), part of that same rebuild, immediately
    -- resolves this brand-new pair (its first ever resolve) and REPLACES both atoms in `children`
    -- with the real sized glyphs - close_glyph itself is the now-discarded placeholder by the time
    -- this returns.
    local rebuilt = mexpru.horiz(fontset, children, mexpru.u(open_horiz).sz)
    container.root = mexpru.propagate_rebuild(fontset, open_horiz, rebuilt)
    -- close_idx is nil for the closed-onto-a-base case: the ")" isn't a slot in `children` at all
    -- there, it's the base inside the rebuilt supsub, so it's named directly rather than read back
    -- out of the list.
    container.cursor_pos = vc.wref_mexpr(close_idx and children[close_idx] or close_glyph)
    mark_edited(container)
    --[[ TRUE, AND IT IS LOAD-BEARING. Every `return false` above means "I did not close"; this is
    the only path that did, and it said nothing - so the one caller that ASKS (the bar key, which
    is a single shortcut for both opening and closing) read a successful close as a refusal and went
    on to open a bracket instead.

    That was a hard crash, not a cosmetic wart. The open path is handed `target`/`target_parent`,
    captured before this function ran; propagate_rebuild has just replaced the whole tree, so those
    handles name freed nodes. Touching one faults - proved 2026-09-11 by tracing the live app:
    `tostring(target_parent)` was the last thing to run before an 0xC0000005. Reported as
    "ctrl+shift+\ and closing it with ctrl+shift+\ crashed the app".

    The doc comment on the bar handler already claimed this - "it now says so with a return value" -
    which is how the caller came to be written against a contract the function never kept. ]]
    return true
end

--[[ Rebuilds `node` and everything beneath it at the current global zoom. Every u(_).sz stays
exactly as it was - those are LOGICAL and never touched by zoom - and only the real glyph geometry
is built at physical_sz(that value).

A 1:1 structural mirror, built through this file's ordinary construction helpers, so every node kind
is handled the same way it was built the first time and there is nothing rescale-specific to keep in
sync as kinds get added.

Bracket atoms come back as small plain un-resolved glyphs (is_open/type kept, peer dropped - it
named a node of the old tree). The horiz branch hands the old pairing to transfer_bracket_peers()
and lets resolve_bracket_pairs() re-tier them, exactly as a live ")" keypress does. Skipping that
transfer is what collapsed every bracket to a plain paren on zoom.

Returns (new_node, mapped_cursor): the new node standing in for `cursor_target`, or nil if this
branch never met it. Deterministic rather than a nearest-fit guess - the walk mirrors the original,
so the node built at the step that replaced cursor_target IS its new home, however deep.
@date 2026-09-08 09:00 ]]
mformula_new.try_close_bracket = try_close_bracket
local function rescale_node(fontset, node, cursor_target)
    local u = mexpru.u(node)
    local logical = u.sz
    local new_node, mapped

    if u.kind == "horiz" then
        local new_children = {}
        for i, child in ipairs(u.children) do
            local nc, m = rescale_node(fontset, child, cursor_target)
            new_children[i] = nc
            mapped = mapped or m
        end
        -- Before horiz(), because its resolve_bracket_pairs() is what reads these peers. The atoms
        -- above were rebuilt peerless on purpose; this is what re-links them (mexpru.lua).
        mexpru.transfer_bracket_peers(u.children, new_children)
        new_node = mexpru.horiz(fontset, new_children, logical)
    elseif u.kind == "supsub" then
        local new_base, m1 = rescale_node(fontset, u.base, cursor_target)
        local new_sup, new_sub, m2, m3
        if u.sup then new_sup, m2 = rescale_node(fontset, u.sup, cursor_target) end
        if u.sub then new_sub, m3 = rescale_node(fontset, u.sub, cursor_target) end
        --[[ Rebuilt at the ZOOM's logical size, so `resupsub` cannot be used here - it keeps the
        node's own. The placements still have to travel, and forgetting them is what would move a
        limit out from under its operator on a zoom. ]]
        new_node = mexpru.supsub(fontset, new_base, new_sup, new_sub, logical, u.sup_place,
                u.sub_place)
        mapped = m1 or m2 or m3
    elseif u.kind == "frac" then
        local new_num, m1 = rescale_node(fontset, u.num, cursor_target)
        local new_den, m2 = rescale_node(fontset, u.den, cursor_target)
        new_node = mexpru.frac(fontset, new_num, new_den, logical)
        mapped = m1 or m2
    elseif u.kind == "vert" then
        local new_slots = {}
        for i, slot in ipairs(u.slots) do
            local ns, m = rescale_node(fontset, slot, cursor_target)
            new_slots[i] = ns
            mapped = mapped or m
        end
        new_node = mexpru.vert(fontset, new_slots, logical)
    elseif u.kind == "dress" then
        -- Rebuild the target at the new zoom, then re-derive the decoration against it - shared
        -- with propagate_rebuild()'s dress branch, which is what keeps the two from diverging.
        local new_target, m = rescale_node(fontset, u.target, cursor_target)
        new_node = mexpru.redress(fontset, new_target, u, logical)
        mapped = m
    elseif u.bracket then
        --[[ Through bracket_entry, not the ascii tables directly: the integral's halves have no
        ASCII spelling on the open side, so reading the table gave nil and rebuilding one on a zoom
        died on it. Every half is found the same way now, wherever it is found.

        The size boost rides along for the same reason it does when the half is first typed - `\int`
        is drawn several levels up from the text around it, and a zoom that re-derived it without
        the boost would shrink it to letter height. ]]
        local entry = bracket_entry(u.bracket.type, u.bracket.is_open)
        local delta = char.size_delta(entry.desc)
        local glyph_sz = logical
        if delta then
            glyph_sz = math.max(1, math.min(logical + delta, MAX_SIZE_INDEX))
        end
        new_node = mexpru.mexpr_symbol(fontset, {size = mexpru.physical_sz(glyph_sz), code = entry.ncod}, true)
        mexpru.u(new_node).bracket = {is_open = u.bracket.is_open, type = u.bracket.type}
        mexpru.u(new_node).sz = logical
    elseif node.type == vc.MEXPR_TYPE_EMPTY_BOX then
        new_node = build_empty_atom(fontset, logical)
    else
        -- A plain glyph's own baked geometry ISN'T always built at exactly `logical` - char.lua's
        -- size_delta_by_desc (currently just "\\int") boosts specific glyphs bigger than their
        -- surrounding nominal level at construction time (mformula_latex.lua's own from_latex()
        -- comment: "u(_).sz is a LOGICAL... reading, not a visual one" - the boost is real ink,
        -- deliberately NOT reflected in u(_).sz). That boost isn't recorded anywhere else on the
        -- node, so it has to be RE-DERIVED here the same way construction derives it the first
        -- time (from the glyph's own code -> desc -> size_delta_by_desc lookup) - found,
        -- reported live: without this, every rescale (any zoom change) silently rebuilt a boosted
        -- glyph like \\int as a perfectly ordinary-sized one, since this branch used to just take
        -- `logical` at face value.
        local entry = char.find_by_ncod(node.symb.code)
        local delta = entry and char.size_delta(entry.desc)
        local glyph_sz = delta and math.max(1, math.min(logical + delta, MAX_SIZE_INDEX)) or logical
        new_node = mexpru.mexpr_symbol(fontset, {size = mexpru.physical_sz(glyph_sz), code = node.symb.code}, true)
        mexpru.u(new_node).sz = logical
    end

    if cursor_target and mexpru.same(node, cursor_target) then
        mapped = new_node
    end
    return new_node, mapped
end

--[[ An INDEPENDENT structural copy of `container` - fresh nodes throughout, cursor mapped onto
the copy.

Exists for undo. editor_text.lua snapshots with deep_copy(), which copies Lua tables but passes userdata
straight through - and an mexpr_t IS userdata, so a snapshot's root was the SAME node as the live
one. propagate_rebuild() then cuts every superseded node, the old root included, leaving the
snapshot pointing at freed memory: Ctrl+Z after any formula-internal edit crashed with "Expected
userdata at index 1", every frame. undo_or_redo() had always assumed it was restoring "a fresh copy
with all-new tables", which was true of the old row-based model and silently stopped being true.

rescale_node() IS the copy: already a 1:1 mirror through the ordinary constructors, and unlike
rescale() it does not cut the original. Rebuilt at the current zoom from each node's LOGICAL sz, so
a snapshot restored at a different zoom comes back correctly sized rather than frozen.

sel_anchor is deliberately NOT carried across - it is a weak ref into the OLD
tree, which the copy has no matching nodes for. A half-typed bracket comes back un-closeable rather
than dangling; that is the honest degradation.
@date 2026-09-08 09:00 ]]
function mformula_new.clone(container, fontset)
    mexpru.check_container(container)
    local cursor_target = container.cursor_pos:get_obj()
    local new_root, mapped_cursor = rescale_node(fontset, container.root, cursor_target)
    mexpru.update_positions(new_root)
    return mexpru.new_container(new_root, mapped_cursor or new_root, container.version)
end

--[[ A deep copy of one node and everything under it - rescale_node with no cursor to map.

Exported rather than reimplemented because a 1:1 structural mirror is exactly what a copy is, and
this one already handles every node kind, keeps each logical size, and hands bracket pairs back to
resolve_bracket_pairs to be re-tiered. A second copier would be a second opinion about all three.
Its consumer is ast_mexpr, which copies the glyphs of a name rather than re-rendering it.
@date 2026-09-12 02:00 ]]
function mformula_new.clone_node(fontset, node)
    return (rescale_node(fontset, node, nil))
end

--[[ How many size steps SMALLER a sup or a sub is drawn than its base. Exported for the same reason
clone_node is: a writer building a power has to match what typing one produces, and the number is
the whole of that rule. @date 2026-09-12 02:00 ]]
mformula_new.SUB_SIZE_DELTA = SUB_SIZE_DELTA

--[[ Where the cursor is, as a PATH of anchor indices from the root, instead of a node reference.

A node reference only means anything inside its own tree. An undo baseline holds a CLONE - a 1:1
structural mirror built by the same constructors (clone() -> rescale_node()) - so the same path
names the same place in it, which is what lets a snapshot be given a cursor position captured after
the snapshot itself was taken.

Walks anchors rather than u(_).children/.base/.sup/.num/..., so it needs no per-kind knowledge and
keeps working for every node kind this file can build, present and future. Returns nil when the
cursor is not reachable from the root (a dangling ref, or a node already spliced out), which the
caller must treat as "no usable position" rather than as the root.
@date 2026-09-08 09:00 ]]
function mformula_new.cursor_path(container)
    mexpru.check_container(container)
    local node = container.cursor_pos and container.cursor_pos:get_obj()
    if not node then
        return nil
    end
    local path = {}
    while true do
        local parent = node:get_parent()
        if not parent then
            break
        end
        local idx
        for i = 1, parent:anchor_len() do
            if mexpru.same(parent:anchor_at(i)[1], node) then
                idx = i
                break
            end
        end
        if not idx then
            return nil          -- parent doesn't own it: the tree is mid-splice, no honest answer
        end
        table.insert(path, 1, idx)
        node = parent
    end
    -- The walk has to have arrived at THIS container's root; anything else is a foreign tree.
    if not mexpru.same(node, container.root) then
        return nil
    end
    return path
end

--[[ Puts the cursor at `path` (from cursor_path(), possibly taken against a DIFFERENT but
structurally identical tree). Returns false, leaving the cursor alone, if the path doesn't resolve -
so a caller can fall back rather than land the cursor somewhere arbitrary.
@date 2026-09-08 09:00 ]]
function mformula_new.cursor_from_path(container, path)
    mexpru.check_container(container)
    if not path then
        return false
    end
    local node = container.root
    for _, idx in ipairs(path) do
        if idx < 1 or idx > node:anchor_len() then
            return false
        end
        node = node:anchor_at(idx)[1]
    end
    container.cursor_pos = vc.wref_mexpr(node)
    return true
end

--[[ Rebuilds the whole tree at the CURRENT global zoom, so content typed before a zoom change
catches up with content typed after it. The public entry to rescale_node(); content.lua calls it per
box whenever the zoom actually moves. Newly typed content needs nothing - it already picks up the
current zoom as it is built.

EVERY CACHED NODE REFERENCE IS STALE AFTERWARDS: this builds new nodes rather than resizing the old
ones in place. A caller holding parse marks or hit boxes has to drop them - see
editor_definition.rescale(), which is where that bit once.

root and cursor_pos are reassigned in place, and the old root is cut loose exactly as
propagate_rebuild() cuts a superseded one, so the old tree lets go immediately instead of lingering
on the collector's schedule.
@date 2026-09-08 09:30 ]]
function mformula_new.rescale(container, fontset)
    mexpru.check_container(container)
    local cursor_target = container.cursor_pos:get_obj()
    local old_root = container.root
    local new_root, mapped_cursor = rescale_node(fontset, old_root, cursor_target)
    mexpru.update_positions(new_root)
    -- cursor_target (an OLD descendant, possibly deep inside old_root) is done being read after
    -- the walk above completes - nil it out before cut(), same "don't touch this local again"
    -- discipline as everywhere else in this file (handle_input()'s own cascade-delete comment):
    -- left live, it'd keep that ONE old node from cascading away with the rest of old_root.
    cursor_target = nil
    mexpru.cut(old_root)
    container.root = new_root
    container.cursor_pos = vc.wref_mexpr(mapped_cursor or new_root)
end

-- Forward-declared: mutually recursive (a frac's num/den, having no base to land on, exits by
-- treating the FRAC ITSELF as an atom in ITS OWN container - the same "whatever occupies this slot"
-- move move_left_within() already does for a plain atom or a supsub).
local exit_horiz_leftward, move_left_within

--[[ Leaves `horiz` to the LEFT - where that lands depends on what holds it. Root has nothing
further left and stays put; otherwise the parent is one of four kinds:

  - supsub or bigop: land on ITS BASE. A bigop carries the same base/sup/sub slots as a supsub and
    differs only in where the limits draw, so it leaves the same way. Its absence here was a hard
    lock rather than a wrong landing - a limit's horiz matched no branch, the function returned
    having done nothing, and the cursor stayed put forever (2026-09-07: losing "the ability to exit
    the integral area to the left", 31 consecutive Lefts in the recorder with no movement).

  - frac or vert: no base to reach toward, so leaving one leftward means leaving the WHOLE
    compound - it occupies a single slot in its own container either way, and Left/Right already
    read it as one opaque atom. Missing this case built a wref to a nonexistent .base: a
    permanently dangling cursor that only threw a frame later, somewhere else.

ONLY for a cursor already at horiz's own position 0, never for one on its first element. Those are
two different on-screen spots and each needs its own keypress - see move_left_within().
@date 2026-09-08 09:30 ]]
exit_horiz_leftward = function(container, horiz)
    local horiz_parent = horiz:get_parent()
    if not horiz_parent then
        return
    end
    local hp_u = mexpru.u(horiz_parent)
    -- A kind comparison rather than is_supsub(), only because is_supsub is declared further down
    -- this file - the two mean the same thing here.
    if hp_u.kind == "supsub" then
        container.cursor_pos = vc.wref_mexpr(hp_u.base)
    elseif hp_u.kind == "frac" or hp_u.kind == "vert" then
        -- Both have no base to reach toward, so leaving one leftward means leaving the WHOLE
        -- compound - it occupies a single slot in its own container either way.
        move_left_within(container, horiz_parent:get_parent(), horiz_parent)
    end
end

--[[ Moves left one slot within `horiz`, where `node` occupies some index. The preceding sibling
if there is one; otherwise node is the first element, and what happens depends on its kind:

  - a glyph or supsub: land on `horiz` ITSELF (position 0), not straight out via
    exit_horiz_leftward(). These are genuinely different on-screen spots - an element renders with
    the caret AFTER it, horiz's position 0 renders at the left edge BEFORE it - so each needs its
    own keypress. Collapsing them was tried and is wrong: in A^{B+C}, walking left from C through +
    to B, a further Left must land on the sup's horiz first, THEN base.

  - an EMPTY atom: the opposite. cursor_target() renders an EMPTY_BOX and a horiz's position 0
    identically, so here they ARE the same spot and landing on the horiz wastes a keypress - skip
    out via exit_horiz_leftward(). Not merely cosmetic: an empty atom is never anything but a
    horiz's only child, so resting on the horiz would apply its "write inserts at start" rule
    instead of the empty atom's "write REPLACES it", leaving a stray empty atom behind.
@date 2026-09-08 09:00 ]]
move_left_within = function(container, horiz, node)
    local children = mexpru.u(horiz).children
    -- node:get_parent_idx() - safe: every call site of this function passes horiz = node:get_parent()
    -- (see this function's own callers), and `children` here is a fresh, unmutated read of it.
    local idx = node:get_parent_idx()
    if idx > 1 then
        container.cursor_pos = vc.wref_mexpr(children[idx - 1])
    elseif node.type == vc.MEXPR_TYPE_EMPTY_BOX then
        exit_horiz_leftward(container, horiz)
    else
        container.cursor_pos = vc.wref_mexpr(horiz)
    end
end

--[[ One position left, through everything: into a supsub's base, out of a slot, past an atom.

The unit of movement is a POSITION in the reachable graph, not a character - which is why the caret
sometimes rests ON a compound (meaning "after the whole thing") rather than between two glyphs. The
graph is what show_graph draws, and these four functions are what walk it.
@date 2026-09-08 09:10 ]]
function mformula_new.move_left(container)
    mexpru.check_container(container)
    --[[ live_cursor(), not cursor_pos:get_obj() directly. A dangling cursor - a wref to a node
    some rebuild has since destroyed - makes get_obj() return nil, and every branch below then
    indexes it, so the FIRST thing an arrow key did was throw
    "mexpru.lua:42: attempt to index a nil value (local 'ref')". main.lua's pcall caught it, the
    frame was abandoned, and from the outside the arrow keys simply stopped working - reported
    2026-09-07 as "the arrows got stuck", with the recorder showing one error per keypress.

    live_cursor() is this file's own answer to that and already existed: it recovers to the
    formula root and reports it through the flight recorder, so a dangling cursor costs you your
    place rather than the use of the keyboard. Movement is exactly where that recovery has to
    happen, since it is the first thing anyone presses when something has gone wrong. ]]
    local target = live_cursor(container)

    if is_horiz(target) then
        exit_horiz_leftward(container, target)
        return
    end

    if is_supsub(target) then
        -- "after the whole compound" - left dives straight into its own base (the mirror of
        -- move_right()'s "entering from the left dives into base" - here we're LEAVING via the
        -- left side of this resting spot, into the thing this compound reads as first).
        container.cursor_pos = vc.wref_mexpr(mexpru.u(target).base)
        return
    end

    local base_owner = base_of(target)
    if base_owner then
        -- Exit the WHOLE supsub leftward, treating it as an ordinary slot in its own container
        -- horiz (same move_left_within() any plain atom uses) - NOT into sup/sub, Left/Right never
        -- reach those, only Up/Down do.
        local outer_horiz = base_owner:get_parent()
        move_left_within(container, outer_horiz, base_owner)
        return
    end

    -- A plain atom sitting in a horiz.
    move_left_within(container, target:get_parent(), target)
end

--[[ Lands rightward ON `node`: if node is a supsub, dive into its own base instead of resting on
node itself - otherwise a single Right keypress landing "on" a multi-glyph-wide compound would
visually jump past its entire width in one step, unlike every other keypress (see this file's own
top comment on why entering from the right, by contrast, needs no such adjustment - S's own
position already sits at its right edge, exactly where stepping right onto it from a full glyph's
width away should land).
@date 2026-09-08 09:00 ]]
local function land_rightward(node)
    if is_supsub(node) then
        return mexpru.u(node).base
    end
    return node
end

--[[ Exits `node` (an atom or a supsub - "whatever occupies this slot") RIGHTWARD out of `horiz`:
next sibling if there is one (diving into its base first, per land_rightward(), if that sibling is
itself a supsub), else exit horiz itself - if horiz has no parent (root), nothing further right;
otherwise land on horiz's own parent supsub ("after the whole compound"). A later, separate Right
keypress re-applies this SAME function to that supsub (is_supsub(target) branch in move_right()),
so a chain of "was also last in ITS OWN container" resolves one keypress at a time, not recursively
in one call - matches how every other keypress only ever takes one visual step.
@date 2026-09-08 09:00 ]]
local function move_right_within(container, horiz, node)
    local children = mexpru.u(horiz).children
    -- node:get_parent_idx() - safe, same reasoning as move_left_within()'s own use above (every
    -- call site here also passes horiz = node:get_parent()).
    local idx = node:get_parent_idx()
    if idx < #children then
        container.cursor_pos = vc.wref_mexpr(land_rightward(children[idx + 1]))
        return
    end
    local horiz_parent = horiz:get_parent()
    if horiz_parent then
        container.cursor_pos = vc.wref_mexpr(horiz_parent)
    end
end

--[[ One position right - the mirror of move_left(), entering a compound from its left rather than
its right. @date 2026-09-08 09:10 ]]
function mformula_new.move_right(container)
    mexpru.check_container(container)
    -- live_cursor(), not get_obj() - see move_left's own note on the dangling case.
    local target = live_cursor(container)

    if is_horiz(target) then
        local first = mexpru.u(target).children[1]
        container.cursor_pos = vc.wref_mexpr(land_rightward(first))
        return
    end

    if is_supsub(target) then
        -- "after the whole compound" - right exits to whatever's next in ITS OWN container horiz,
        -- exactly like any plain atom sitting in that same slot would.
        move_right_within(container, target:get_parent(), target)
        return
    end

    local base_owner = base_of(target)
    if base_owner then
        container.cursor_pos = vc.wref_mexpr(base_owner) -- "after the whole compound"
        return
    end

    -- A plain atom sitting in a horiz.
    move_right_within(container, target:get_parent(), target)
end

--[[ Enters `sup_or_sub_horiz` at its END (last element) - the entry point used when arriving from
S (cursor_pos = the supsub node itself, "after the whole compound", approaching from further
right) - reciprocal with the last-of-sup/sub "down/up -> S" boundary rule below.
@date 2026-09-08 09:00 ]]
local function enter_at_end(sup_or_sub_horiz)
    local children = mexpru.u(sup_or_sub_horiz).children
    return children[#children]
end

--[[ Enters `sup_or_sub_horiz` at its own START (position 0) - the entry point used when arriving
from base (approaching from the left/before side, so landing at the beginning reads naturally),
UNLESS its only child is a lone empty atom, in which case that's the exact same on-screen spot as
landing on the horiz itself (cursor_target() renders an EMPTY_BOX and a horiz's own position 0
identically) - land on that atom directly instead, so a real edit there triggers its own REPLACE
rule rather than the horiz's INSERT-AT-START rule (this file's own invariant: an empty atom is
never anything but a horiz's sole child).
@date 2026-09-08 09:00 ]]
local function enter_at_start(sup_or_sub_horiz)
    local children = mexpru.u(sup_or_sub_horiz).children
    if #children == 1 and children[1].type == vc.MEXPR_TYPE_EMPTY_BOX then
        return children[1]
    end
    return sup_or_sub_horiz
end

--[[ Is this slot horiz still UNTYPED - nothing in it but the empty atom it was created with?

The same question enter_at_start() asks, and the same invariant behind it: an empty atom is never
anything but a horiz's sole child. A slot that is nil counts as untyped too, which is what makes
this work for the LAZY sup/sub this file builds - "x^{}" has no sub node at all, and "the other
slot is also empty" has to be true of it.
@date 2026-09-08 09:00 ]]
local function slot_is_untyped(slot_horiz)
    if not slot_horiz then
        return true
    end
    local children = mexpru.u(slot_horiz).children
    return children ~= nil and #children == 1
            and children[1].type == vc.MEXPR_TYPE_EMPTY_BOX
end

--[[ The supsub whose sup/sub the cursor is sitting in, when BOTH its slots are still untyped -
i.e. the exact state make_supsub() leaves behind, with nothing typed since. Returns nil otherwise.

The cursor may be resting on the slot's horiz or on the empty atom inside it; cursor_target()
renders those identically (enter_at_start()'s own comment), so both have to be accepted here.
@date 2026-09-08 09:00 ]]
local function collapsible_supsub(container)
    local node = live_cursor(container)
    if not node then
        return nil
    end
    local slot_horiz = node
    if not is_horiz(slot_horiz) then
        slot_horiz = node:get_parent()
    end
    if not slot_horiz or not is_horiz(slot_horiz) then
        return nil
    end
    local supsub = slot_horiz:get_parent()
    if not supsub then
        return nil
    end
    --[[ is_supsub, not a bare kind check: a BIGOP carries the same base/sup/sub slots and collapses
    the same way - back to its bare operator. It was excluded by an explicit `kind ~= "supsub"`,
    so a freshly made big operator could not be undone from inside its own empty limit, and the only
    way out was deleting the operator underneath it. Reported 2026-09-06: "after creating a bigop
    marker I can't delete it from inside it". ]]
    local u = mexpru.u(supsub)
    if not is_supsub(supsub) then
        return nil
    end
    local in_sup = mexpru.same(u.sup, slot_horiz)
    local in_sub = mexpru.same(u.sub, slot_horiz)
    if not (in_sup or in_sub) then
        return nil
    end
    --[[ Two outcomes, and which one is decided by whether the OTHER side EXISTS - not by whether
    it happens to be empty.

    THIS SLOT MUST ALREADY BE UNTYPED, always. Backspacing the "B" out of "x^{B}" clears the B and
    leaves the superscript standing; a second press, on the now-empty slot, is what removes the
    structure. That has been the rule from the start and is unchanged.

    Given that, the side the cursor is in is removed ("drop") whenever the node has another side at
    all, and the whole node is undone ("collapse") only when it does not. Collapse is the
    single-sided case: undoing the spawn that made the node, which is what make_supsub leaves
    behind and what Backspace there should reverse.

    IT USED TO ASK WHETHER BOTH SIDES WERE UNTYPED, which took an EMPTY sibling along with the one
    being deleted. That was invisible while a node's two sides could only be spawned together, and
    became wrong once each side could be added by its own keypress: put a limit under an operator,
    add an empty power beside it, delete the power - and the limit went too. Reported live,
    2026-09-10: "deleting sup also deletes bsub, not ok".

    The case this rule was ALSO written for still works, and is the reason "drop" exists at all:
    add a limit above a sum that already has one below, change your mind, and the empty slot can be
    removed on its own. That used to return nil - Backspace did nothing - which reached the user as
    "I can't delete it". ]]
    --[[ Spelled out rather than with `in_sup and X or Y`: that idiom returns Y when X is nil, and
    a side being nil is exactly the case this has to distinguish. A one-sided node read as
    two-sided, and refused to collapse. ]]
    local this_slot, this_side, other_side
    if in_sup then
        this_slot, this_side, other_side = "sup", u.sup, u.sub
    else
        this_slot, this_side, other_side = "sub", u.sub, u.sup
    end

    if not slot_is_untyped(this_side) then
        return nil
    end
    if other_side == nil then
        return supsub, "collapse", this_slot
    end
    return supsub, "drop", this_slot
end

--[[ Backspace in a sup/sub that was never typed into: undo the whole spawn, leaving just the base.

Ported from the old collapse_if_both_empty(), which the new model lost - reported live
: "delete from an empty horiz no longer deletes sup when on empty horiz x^[empty]".

EITHER DELETE KEY reaches this, since 2026-09-07. It was Backspace only, because Delete elsewhere
in this file means "the thing after the cursor" and an empty slot has nothing after it - true, but
the consequence was that Delete did nothing at all in an empty slot, which reads as a broken key
rather than as a consistent model. Ruled: "if the horiz is empty it should delete, only when the
horiz has something else than an empty should it not" - which is exactly the condition below, so
the caller needs no extra test.

The other condition is unchanged and still matters: a slot must be untyped ALREADY, at the moment
the key is pressed - not merely become empty because of this press - or backspacing the "B" out of
"x^{B}" would take the whole superscript with it in one keystroke instead of just clearing what was
typed. A second press, on the now-empty slot, is what removes the structure.

The cursor lands on the base, which is where the compound used to sit.

Returns whether it did anything, and is public so a test can drive it - handle_input()'s Backspace
branch needs real keypresses, the same reason every other handle_input-adjacent test here works one
level down.
@date 2026-09-08 09:00 ]]
function mformula_new.collapse_empty_supsub(container, fontset)
    mexpru.check_container(container)
    local supsub, mode, side = collapsible_supsub(container)
    if not supsub then
        return false
    end
    local u = mexpru.u(supsub)
    local base = u.base
    if mode == "collapse" then
        container.root = mexpru.propagate_rebuild(fontset, supsub, base)
    else
        --[[ Remove only the side the cursor is in, keeping the other one and its content. Rebuilt
        through the same constructor that made it, so a bigop stays a bigop (limits above/below)
        and a supsub stays a supsub (beside) - passing one through the other's constructor would
        silently move the surviving limit to the wrong place. ]]
        --[[ Spelled out, because `(side == "sup") and nil or u.sup` does NOT clear the side: the
        `and` yields nil and the `or` then falls straight through to u.sup, putting it back. Written
        that way this branch rebuilt an identical node and reported success, so "remove just this
        side" has never actually removed one - and no test saw it, because they all asserted that
        the OTHER side survived and never that this one was gone. ]]
        local new_sup, new_sub = u.sup, u.sub
        if side == "sup" then
            new_sup = nil
        else
            new_sub = nil
        end
        local rebuilt = mexpru.resupsub(fontset, u, base, new_sup, new_sub)
        container.root = mexpru.propagate_rebuild(fontset, supsub, rebuilt)
        --[[ Take the base back OUT of the rebuilt node rather than reusing the handle captured
        before it. The constructor may or may not adopt the node it was handed, and the rebuild
        that follows tears down the old subtree - so the pre-rebuild handle can name something that
        no longer exists, and pointing the cursor at it produces a DANGLING cursor. That is not a
        theoretical hazard: it showed up in a live session's flight recorder as
        "WARN cursor_pos was dangling - recovered to the formula root", after which arrow keys had
        nothing sensible to move through and Left stopped leaving the operator at all.

        Reading it back from `rebuilt` is correct whichever way the constructor behaved. ]]
        base = mexpru.u(rebuilt).base or rebuilt
    end
    -- Either way the cursor lands on the base, which is where the removed part used to hang.
    container.cursor_pos = vc.wref_mexpr(base)
    mark_edited(container)
    return true
end

-- Which frac slot plays the same role as sup/sub does for a supsub, per direction - "num" is
-- frac's "upper" slot (sup's counterpart), "den" its "lower" one (sub's counterpart). Used by
-- walk_up_vertical() below to recognize a frac ancestor as a bifurcation point too, not just a
-- supsub one.
local FRAC_COUNTERPART = {sup = "num", sub = "den"}
local FRAC_SIBLING = {num = "den", den = "num"}

--[[ Only reached when a vertical motion has no local target. `node` is the supsub/frac we are
stuck at; `sup_or_sub` is which of ITS slots would answer this motion one level further out ("sup"
while searching for a Down target, "sub" for an Up one - the mirror of what we were just inside).

Climbs: if node's container horiz is its parent's `sup_or_sub` slot, land on that parent's base -
the bifurcation is found and the motion resolves. If it is instead the corresponding FRAC slot, the
bifurcation is a sibling jump into that frac's OTHER slot: a frac ancestor answers through its own
num/den semantics rather than being transparent, so a fraction nested in another fraction resolves
there instead of skipping past it hunting for a supsub. Otherwise keep climbing.

Returns nil when nothing above resolves it - either the climb reaches the root, or it bottoms out at
a node with no base of its own (a frac, which has no base to fall back to the way a supsub does).
Every caller must treat nil as a true no-op and leave cursor_pos exactly where it was.
@date 2026-09-08 09:00 ]]
local function walk_up_vertical(node, sup_or_sub)
    local frac_slot = FRAC_COUNTERPART[sup_or_sub]
    while true do
        local container_horiz = node:get_parent()
        local grandparent = container_horiz:get_parent()
        if not grandparent then
            return mexpru.u(node).base
        end
        local gp_u = mexpru.u(grandparent)
        if mexpru.same(gp_u[sup_or_sub], container_horiz) then
            return mexpru.u(grandparent).base
        end
        if mexpru.same(gp_u[frac_slot], container_horiz) then
            return enter_at_start(gp_u[FRAC_SIBLING[frac_slot]])
        end
        node = grandparent
    end
end

-- Applies walk_up_vertical()'s result, if any - a nil result is a true no-op, see its own comment.
local function apply_walk(container, node, sup_or_sub)
    local target = walk_up_vertical(node, sup_or_sub)
    if target then
        container.cursor_pos = vc.wref_mexpr(target)
    end
end

--[[ DOWN means "into the part below" here, not "next line": a subscript, a denominator, the next
cell of a stack. Where there is nothing below to enter, it climbs out to whatever contains this.
@date 2026-09-08 09:10 ]]
function mformula_new.move_down(container)
    mexpru.check_container(container)
    -- live_cursor(), not get_obj() - see move_left's own note on the dangling case.
    local target = live_cursor(container)

    if is_supsub(target) then
        local sub = mexpru.u(target).sub
        if sub then
            container.cursor_pos = vc.wref_mexpr(enter_at_end(sub))
        else
            apply_walk(container, target, "sup")
        end
        return
    end

    -- Resting ON a frac node itself ("after the whole compound", same resting spot Left/Right
    -- leave the cursor at, treating it as one opaque atom) - Down enters its denominator. Always
    -- possible (num/den are never absent, unlike supsub's lazily-built sup/sub - mexpr_frac itself
    -- requires both), so no walk_up_vertical fallback needed here. Enters at the END (not start) -
    -- same "arriving from further right" convention is_supsub(target)'s own sub-entry above uses,
    -- since resting on the frac itself is likewise a right-approach spot.
    --[[ Through a dress to what it holds (unwrap()) for the DESCENT branches only - resting on a
    dressed stack and pressing Down has to enter the stack. The climb-out logic below keeps using
    `target` itself, since up there the dress is the atom occupying the row's slot. ]]
    local inner = unwrap(target)

    if is_frac(inner) then
        container.cursor_pos = vc.wref_mexpr(enter_at_end(mexpru.u(inner).den))
        return
    end

    -- Mirror for a vert: Down enters the BOTTOMMOST slot, as it enters a frac's denominator.
    if is_vert(inner) then
        local slots = mexpru.u(inner).slots
        container.cursor_pos = vc.wref_mexpr(enter_at_end(slots[#slots]))
        return
    end

    local base_owner = base_of(target)
    if base_owner then
        local sub = mexpru.u(base_owner).sub
        if sub then
            container.cursor_pos = vc.wref_mexpr(enter_at_start(sub))
        else
            apply_walk(container, base_owner, "sup")
        end
        return
    end

    -- Inside (or at the start of) some horiz H - "element or at horiz cursor" both behave the
    -- same, per this file's own top comment, EXCEPT for the one boundary case right below: being
    -- ON THE LAST ELEMENT of sup specifically reciprocates S's own "up -> end of sup" entry point,
    -- same as being on S itself would - horiz's own position-0 state never counts as "the last
    -- element" (there's no element there to BE the boundary one), so that still falls through to
    -- the ordinary non-boundary rule.
    local horiz = is_horiz(target) and target or target:get_parent()
    local horiz_parent = horiz:get_parent()
    if not horiz_parent then
        return
    end
    local hp_u = mexpru.u(horiz_parent)
    local horiz_children = mexpru.u(horiz).children
    -- target:get_parent_idx() - safe: only evaluated (Lua's `and` short-circuit) when target is NOT
    -- a horiz, in which case `horiz` above was set to target:get_parent() directly - a fresh,
    -- unmutated read.
    local is_last_element = (not is_horiz(target)) and target:get_parent_idx() == #horiz_children

    if is_vert(horiz_parent) then
        -- In a vert slot: Down steps to the slot below, and running off the LAST one climbs out
        -- exactly as a denominator's own Down does. enter_at_start, matching the frac's own
        -- num->den convention (a pure vertical jump, not an approach from either side).
        local slots = hp_u.slots
        local idx = mexpru.index_of(slots, horiz)
        if idx and slots[idx + 1] then
            container.cursor_pos = vc.wref_mexpr(enter_at_start(slots[idx + 1]))
        else
            apply_walk(container, horiz_parent, "sup")
        end
        return
    end

    if mexpru.same(hp_u.sup, horiz) and is_last_element then
        container.cursor_pos = vc.wref_mexpr(horiz_parent)
    elseif mexpru.same(hp_u.sub, horiz) then
        -- Already in sub - down has no local meaning (sub is the "bottom") - walk up looking for
        -- an ancestor where down finally resolves.
        apply_walk(container, horiz_parent, "sup")
    elseif mexpru.same(hp_u.sup, horiz) then
        -- In sup, not the boundary element - down reaches toward base directly.
        container.cursor_pos = vc.wref_mexpr(hp_u.base)
    elseif mexpru.same(hp_u.num, horiz) then
        -- In numerator - down jumps DIRECTLY to denominator (no base to route through the way
        -- sup->base does - a frac has none, design discussion). Not conditioned on
        -- "last element" the way sup's boundary check is - there's no intermediate "reach toward
        -- base" case for a frac to fall into first, so any position within num jumps straight
        -- across. enter_at_start (not _end): this is a pure vertical jump, not an approach from
        -- either side, and matches the old row-editor's own num/den convention (always lands at
        -- the sibling slot's own start) plus reuses enter_at_start()'s "still-untyped -> land on
        -- the empty atom directly" collapse for a freshly Ctrl+/'d fraction's other side.
        container.cursor_pos = vc.wref_mexpr(enter_at_start(hp_u.den))
    elseif mexpru.same(hp_u.den, horiz) then
        -- Already in denominator - down has no LOCAL meaning, but still climbs (2026-09-04 design
        -- discussion, revised from an earlier no-climb draft): walk_up_vertical() now recognizes a
        -- frac ancestor's OWN "num" as a bifurcation point too, not just a supsub's "sup" - so
        -- (a/b)/c with the cursor in "b" going Down resolves to "c" (the OUTER frac's own other
        -- slot), and a frac nested inside a supsub's sup/sub still escapes toward that supsub's
        -- base the same way it always did. Degrades to apply_walk()'s true no-op only when NEITHER
        -- kind of ancestor is ever found (frac all the way to the root).
        apply_walk(container, horiz_parent, "sup")
    end
end

--[[ UP means "into the part above": a superscript, a numerator, the previous cell of a stack -
the mirror of move_down(). @date 2026-09-08 09:10 ]]
function mformula_new.move_up(container)
    mexpru.check_container(container)
    -- live_cursor(), not get_obj() - see move_left's own note on the dangling case.
    local target = live_cursor(container)

    -- Through a dress for the DESCENT branches only, exactly as move_down() does - see unwrap().
    local inner = unwrap(target)

    if is_supsub(inner) then
        local sup = mexpru.u(inner).sup
        if sup then
            container.cursor_pos = vc.wref_mexpr(enter_at_end(sup))
        else
            apply_walk(container, target, "sub")
        end
        return
    end

    -- Resting ON a frac node itself - mirror of move_down()'s own is_frac() branch: Up enters its
    -- numerator, always possible, entering at the END (arriving from further right).
    if is_frac(inner) then
        container.cursor_pos = vc.wref_mexpr(enter_at_end(mexpru.u(inner).num))
        return
    end

    -- A vert is the same idea with N rows instead of 2: Up enters the TOPMOST slot, exactly as it
    -- enters a frac's numerator ("up, down climb to the topmost or downard most element, in the
    -- same way as fractions").
    if is_vert(inner) then
        container.cursor_pos = vc.wref_mexpr(enter_at_end(mexpru.u(inner).slots[1]))
        return
    end

    local base_owner = base_of(target)
    if base_owner then
        local sup = mexpru.u(base_owner).sup
        if sup then
            container.cursor_pos = vc.wref_mexpr(enter_at_start(sup))
        else
            apply_walk(container, base_owner, "sub")
        end
        return
    end

    -- Mirror of move_down()'s own boundary comment: the LAST element of sub reciprocates S's own
    -- "down -> end of sub" entry point.
    local horiz = is_horiz(target) and target or target:get_parent()
    local horiz_parent = horiz:get_parent()
    if not horiz_parent then
        return
    end
    local hp_u = mexpru.u(horiz_parent)
    local horiz_children = mexpru.u(horiz).children
    -- target:get_parent_idx() - safe, same reasoning as move_down()'s own use above.
    local is_last_element = (not is_horiz(target)) and target:get_parent_idx() == #horiz_children

    if is_vert(horiz_parent) then
        -- Mirror of move_down()'s own vert branch: Up steps to the slot above, and running off the
        -- FIRST one climbs out the way a numerator's own Up does.
        local slots = hp_u.slots
        local idx = mexpru.index_of(slots, horiz)
        if idx and idx > 1 and slots[idx - 1] then
            container.cursor_pos = vc.wref_mexpr(enter_at_start(slots[idx - 1]))
        else
            apply_walk(container, horiz_parent, "sub")
        end
        return
    end

    if mexpru.same(hp_u.sub, horiz) and is_last_element then
        container.cursor_pos = vc.wref_mexpr(horiz_parent)
    elseif mexpru.same(hp_u.sup, horiz) then
        apply_walk(container, horiz_parent, "sub")
    elseif mexpru.same(hp_u.sub, horiz) then
        container.cursor_pos = vc.wref_mexpr(hp_u.base)
    elseif mexpru.same(hp_u.den, horiz) then
        -- In denominator - up jumps DIRECTLY to numerator (mirror of move_down()'s own num->den
        -- jump - unconditional, no boundary/base-routing step to fall into first).
        container.cursor_pos = vc.wref_mexpr(enter_at_start(hp_u.num))
    elseif mexpru.same(hp_u.num, horiz) then
        -- Already in numerator - up has no local meaning. Climbs the same way den's own Down-climb
        -- does (mirror, symmetric per this file's own fraction design discussion) -
        -- walk_up_vertical() recognizes a frac ancestor's "den" as the bifurcation slot for an Up
        -- search (FRAC_COUNTERPART["sub"] = "den"), so e.g. (a/b)/c with the cursor in "a" going Up
        -- resolves to "c" the same way going Down from "b" resolves to it.
        apply_walk(container, horiz_parent, "sub")
    end
end

--[[ Which slot of a vert this cursor position is in: the vert, and the 1-based slot index. nil
when the position isn't inside a vert at all. Same "immediate enclosing horiz only" reading the
frac branches use, so all the vertical rules agree about where the cursor IS.

Lives here, below the navigation helpers, rather than up beside make_frac(): it needs is_vert()
and enter_at_start(), and make_frac()'s own comment records what happens to anything declared above
those - a silent forward reference to a nil global.
@date 2026-09-08 09:00 ]]
local function vert_slot_of(target)
    local horiz = is_horiz(target) and target or target:get_parent()
    if not horiz then
        return nil
    end
    local vp = horiz:get_parent()
    if not vp or not is_vert(vp) then
        return nil
    end
    return vp, mexpru.index_of(mexpru.u(vp).slots, horiz)
end

-- #############################################################################################
-- Accents
-- #############################################################################################

--[[ ACCENTS ("dressing"). Each is a TOGGLE: the same one again takes it off and leaves the bare
atom, and removing the last dot does the same.

Two INDEPENDENT slots, above and below - an atom can wear a hat and a bar beneath at once. The
shortcut picks the slot: the plain action is ABOVE, its `_below` twin is BELOW (math.accent_hat and
math.accent_hat_below, and the same for tilde and bar). Dots are math.dot_add / math.dot_remove and
live in the above slot.

A dress is a WRAPPER, not an atom - see unwrap(). From outside it is the atom occupying its slot
(Left/Right step over the whole thing, slot_atom() reports a bracket or sprint landmark through it),
but a descent - a click, Up/Down - passes through to whatever it holds, so a dressed stack stays
navigable. The decoration itself is never a cursor destination either way.

Stored on the node: u.above_kind / u.bellow_kind name the accent in each slot for toggling,
u.above_recipe / u.bellow_recipe are the char.lua builders to re-derive the glyph from - an accent
is chosen by the TARGET's width, so it must be re-picked whenever the target changes (see
mexpru.redress()) - and u.dots counts dots. Dots share the above slot with a named accent, so they
replace each other; the below slot is untouched by that.
@date 2026-09-08 09:00 ]]
local ACCENT_RECIPES = {
    hat = char.hat_accent,
    tilde = char.tilde_accent,
    bar = char.bar_accent,
    vec = char.vec_accent,
    vecleft = char.vec_left_accent,
}

--[[ Replaces `old` with `new` in the tree and puts the cursor on `new`.

`old_parent` is captured by the CALLER, before it builds `new`, and passed through to
propagate_rebuild() - see its own comment. Dressing builds a node that ADOPTS `old` (mexpr_dress
reparents its target), so reading old:get_parent() here answers the new dress instead of the row,
and propagate_rebuild then rebuilds "the parent" by wrapping that dress in another dress, and
again, forever - a hang, which is what test_dress_editor.lua was timing out on. make_supsub() has
carried the same capture-before-you-wrap discipline, and the same comment, since.
@date 2026-09-08 09:00 ]]
local function swap_atom(container, fontset, old, old_parent, new)
    container.root = mexpru.propagate_rebuild(fontset, old, new, old_parent)
    container.cursor_pos = vc.wref_mexpr(new)
    mark_edited(container)
end

--[[ The atom under the cursor, or nil when there is nothing dressable there. A horiz is a position
rather than a thing, and an empty placeholder has no ink to sit an accent over.
@date 2026-09-08 09:00 ]]
local function dressable_target(container)
    local node = live_cursor(container)
    if not node or is_horiz(node) or node.type == vc.MEXPR_TYPE_EMPTY_BOX then
        return nil
    end
    --[[ Climb to the enclosing dress when the cursor is on the thing a dress already holds.

    Under the wrapper model (unwrap()) the cursor can rest INSIDE a dress - that is the whole point
    of forwarding navigation to the held value. Without this climb, an accent pressed there would
    wrap the target a SECOND time and build "\hat{\hat{x}}", where the intent is plainly to toggle
    the accent the atom already wears. One decoration per slot per atom stays the rule; this is what
    keeps it true now that the inside is reachable.

    Only one level, and only from the dress's own TARGET - a cursor deeper inside a dressed stack
    is on that stack's own content, and dressing THAT is a perfectly ordinary thing to want. ]]
    local parent = node:get_parent()
    if parent and is_dress(parent) and mexpru.same(mexpru.u(parent).target, node) then
        return parent
    end
    return node
end

--[[ A dress node's own bookkeeping, read back off it (or an empty table for an undressed atom) so
a toggle can change ONE slot and leave the rest exactly as it found it. Without this, dressing the
underside of a hatted atom quietly dropped the hat.
@date 2026-09-08 09:00 ]]
local function dress_spec(u)
    if u.kind ~= "dress" then
        return mexpru.dress_spec{}
    end
    return mexpru.dress_spec{
        above_kind = u.above_kind, above_recipe = u.above_recipe,
        bellow_kind = u.bellow_kind, bellow_recipe = u.bellow_recipe,
        dots = u.dots,
    }
end

--[[ Builds what `spec` describes around `target`, or hands back the bare target when it asks for
nothing at all - which is what makes taking the last decoration off leave a plain atom rather than
an empty dress.

`spec` is shaped exactly like a dress node's own u table, so it goes straight to mexpru.redress() -
THE single place a dress is constructed. Spelling the construction out a third time here is
precisely the drift that lost dots on an edit once already (see redress()'s own comment).
@date 2026-09-08 09:00 ]]
local function build_dress_spec(fontset, target, spec, sz)
    if not (spec.above_recipe or spec.bellow_recipe or (spec.dots and spec.dots > 0)) then
        return target
    end
    return mexpru.redress(fontset, target, spec, sz)
end

--[[ The three named accents - `math.accent_hat` / `_tilde` / `_bar`, and the `_below` half of each
for the underside. `where` is
"above" (the default) or "below". Same accent again on the SAME slot removes it; a different one
replaces it; the other slot is never touched.
@date 2026-09-08 09:00 ]]
function mformula_new.toggle_accent(container, fontset, kind, where)
    mexpru.check_container(container)
    local node = dressable_target(container)
    if not node then
        return
    end
    -- BEFORE build_dress_spec(): building the dress reparents `target`, so this is the last moment
    -- old's real position in the tree can still be read (swap_atom()'s own comment).
    local old_parent = node:get_parent()
    local u = mexpru.u(node)
    local target = (u.kind == "dress") and u.target or node
    local spec = dress_spec(u)

    --[[ Spelled out, NOT `(was == kind) and nil or kind`: that is the classic Lua a-and-b-or-c
    trap - `true and nil` is nil, which is falsy, so the `or` fires and the expression yields `kind`
    on BOTH branches. The accent could then never be taken off; pressing the same one again just
    re-applied it. ]]
    if where == "below" then
        local want = kind
        if spec.bellow_kind == kind then
            want = nil
        end
        spec.bellow_kind = want
        spec.bellow_recipe = nil
        if want then
            spec.bellow_recipe = ACCENT_RECIPES[want]
        end
    else
        local want = kind
        if spec.above_kind == kind then
            want = nil
        end
        spec.above_kind = want
        spec.above_recipe = nil
        if want then
            spec.above_recipe = ACCENT_RECIPES[want]
            spec.dots = nil     -- one slot above; a named accent and dots cannot share it
        end
    end

    swap_atom(container, fontset, node, old_parent, build_dress_spec(fontset, target, spec,
            mexpru.u(target).sz))
end

--[[ `math.dot_add` adds a dot, `math.dot_remove` takes one away. Removing the last undresses the
atom entirely,
which is what makes Ctrl+, a complete undo of Ctrl+. rather than leaving an empty dress behind.
@date 2026-09-08 09:00 ]]
function mformula_new.adjust_dots(container, fontset, delta)
    mexpru.check_container(container)
    local node = dressable_target(container)
    if not node then
        return
    end
    local old_parent = node:get_parent()   -- before the rebuild reparents - see swap_atom()
    local u = mexpru.u(node)
    local target = (u.kind == "dress") and u.target or node
    local spec = dress_spec(u)
    local have = spec.dots or 0
    local want = math.max(0, math.min(3, have + delta))
    if want == have then
        return   -- already at the floor or the ceiling; not an edit
    end
    spec.dots = nil
    if want > 0 then
        spec.dots = want
        -- Dots take the slot above, so they replace whatever named accent was up there. Anything
        -- BELOW is left exactly as it was.
        spec.above_kind, spec.above_recipe = nil, nil
    end
    swap_atom(container, fontset, node, old_parent, build_dress_spec(fontset, target, spec,
            mexpru.u(target).sz))
end

--[[ Turns what the cursor is on into a STACK, or gives the stack it is already in one more slot -
the growing half of `math.stack_grow`.

A stack starts as a SINGLE slot ("it starts with a single element"), which looks like nothing but
its own content; pressing again stacks another row under it. The new slot goes directly BELOW the
one the cursor is in rather than at the end, so building downward is just the same key repeatedly,
and the cursor follows into the new row, which is where you would type next.

The shrinking half refuses at one slot. A zero-slot stack cannot be drawn at all, and more to the
point "needs delete to disappear": shrinking resizes a stack, removing it is what Backspace and
Delete are for, and letting the two mean the same thing at n=1 would make a stack vanish under a
keystroke aimed at its contents.
@date 2026-09-08 09:30 ]]
function mformula_new.make_vert(container, fontset, target_sz)
    mexpru.check_container(container)
    local target = container.cursor_pos:get_obj()

    -- Already in a stack? Grow it instead of nesting another one inside it.
    local vert, idx = vert_slot_of(target)
    if vert and idx then
        local u = mexpru.u(vert)
        local slots = u.slots
        local new_empty, new_horiz = build_side(fontset, u.sz)
        table.insert(slots, idx + 1, new_horiz)
        local rebuilt = mexpru.vert(fontset, slots, u.sz)
        container.root = mexpru.propagate_rebuild(fontset, vert, rebuilt)
        container.cursor_pos = vc.wref_mexpr(new_empty)
        mark_edited(container)
        return
    end

    -- Otherwise a brand-new one-slot stack, spliced in through the exact same helper make_frac()
    -- uses - including its replace-an-empty-placeholder case, which is what stopped a fresh stack
    -- from being born with a blank gap to its left.
    local slot_empty, slot_horiz = build_side(fontset, target_sz)
    insert_compound_at_cursor(container, fontset, mexpru.vert(fontset, {slot_horiz}, target_sz),
            target_sz, slot_empty)
end

--[[ `math.stack_shrink`: drop the slot the cursor is in. Refuses at one slot (see make_vert()) and
does
nothing at all outside a vert. The cursor lands in the slot that took the removed one's place -
the one below, or the new last one if the bottom row was the one removed.
@date 2026-09-08 09:00 ]]
function mformula_new.shrink_vert(container, fontset)
    mexpru.check_container(container)
    local vert, idx = vert_slot_of(container.cursor_pos:get_obj())
    if not vert or not idx then
        return
    end
    local u = mexpru.u(vert)
    local slots = u.slots
    if #slots <= 1 then
        print("mformula_new: a vert always keeps at least one slot - use Delete to remove the stack")
        return
    end

    local removed = table.remove(slots, idx)
    local rebuilt = mexpru.vert(fontset, slots, u.sz)
    container.root = mexpru.propagate_rebuild(fontset, vert, rebuilt)
    container.cursor_pos = vc.wref_mexpr(enter_at_start(slots[math.min(idx, #slots)]))
    mexpru.cut(removed)     -- after propagate_rebuild, same ordering rule as every other removal
    mark_edited(container)
end

--[[ The frac whose own `slot` ("num"/"den") horiz directly holds `target` - nil if target isn't
sitting in that slot of a fraction. Same "immediate enclosing horiz only" reading move_up()/
move_down() themselves use, so these agree about where the cursor IS.
@date 2026-09-08 09:00 ]]
local function frac_slot_owner(target, slot)
    local horiz = is_horiz(target) and target or target:get_parent()
    if not horiz then
        return nil
    end
    local hp = horiz:get_parent()
    if not hp or not is_frac(hp) then
        return nil
    end
    return mexpru.same(mexpru.u(hp)[slot], horiz) and hp or nil
end

--[[ Alt+Up / Alt+Down: take the NON-RECIPROCAL vertical road backwards.

The fraction is the case that motivates it. From the frac NODE, Up enters the numerator and Down the
denominator - but from inside the numerator, plain Down jumps straight ACROSS to the denominator,
never back to the node it came from. So the two entry moves have no ordinary inverse and the frac
node itself becomes hard to return to. These supply exactly those: num --Alt+Down--> the frac node,
den --Alt+Up--> the frac node.

Only fractions need it. A supsub already reciprocates - the last element of a sup/sub lands back on
the supsub itself, and base <-> sup/sub round-trips. Where there is no non-reciprocal road to
reverse, these fall through to the plain move, so Alt+arrow is never a dead key.
@date 2026-09-08 09:00 ]]
function mformula_new.move_down_reverse(container)
    mexpru.check_container(container)
    -- live_cursor(), not get_obj() - see move_left's own note on the dangling case.
    local target = live_cursor(container)
    local owner = frac_slot_owner(target, "num") or (select(1, vert_slot_of(target)))
    if owner then
        container.cursor_pos = vc.wref_mexpr(owner)
        return
    end
    mformula_new.move_down(container)
end

--[[ Back up THE WAY YOU CAME IN: from inside a denominator or a stack cell, onto the compound
itself rather than further up into its numerator.

That is the difference from move_up(), which goes UP the picture. Leaving a slot by the door you
entered is a different intention from moving to whatever happens to sit above it.
@date 2026-09-08 09:10 ]]
function mformula_new.move_up_reverse(container)
    mexpru.check_container(container)
    -- live_cursor(), not get_obj() - see move_left's own note on the dangling case.
    local target = live_cursor(container)
    local owner = frac_slot_owner(target, "den") or (select(1, vert_slot_of(target)))
    if owner then
        container.cursor_pos = vc.wref_mexpr(owner)
        return
    end
    mformula_new.move_up(container)
end

--[[ The vertical half of the sprint, inside a stack: straight to the topmost
or bottommost slot rather than one row at a time ("shift sprints to upermost or botom most").
Returns false anywhere else, so Shift+Up/Down keeps its plain meaning outside a stack.
@date 2026-09-08 09:00 ]]
local function sprint_vertical(container, dir)
    local vert, idx = vert_slot_of(container.cursor_pos:get_obj())
    if not vert or not idx then
        return false
    end
    local slots = mexpru.u(vert).slots
    local goal = (dir > 0) and #slots or 1
    if goal == idx then
        return false            -- already there: let the plain move climb out of the stack
    end
    container.cursor_pos = vc.wref_mexpr(enter_at_start(slots[goal]))
    return true
end

-- #############################################################################################
-- The sprint
-- #############################################################################################

--[[ THE SPRINT (`math.sprint_left` / `math.sprint_right`): cross a long row by jumping between
LANDMARKS instead of one atom at a time. A landmark is a bracket atom, or the slot's own edge.

Brackets earn it because they are what the eye navigates a formula by - where sub-expressions start
and stop - so stopping on them lands the caret where you want to type far more often than a fixed
stride would. Open AND close both count: stopping only on opens would make the sprint asymmetric,
skipping a group's end when moving right. "=" and ";" join them at a coarser scale, being where one
statement ends and the next begins.

Scanning stays inside the cursor's IMMEDIATE horiz - a sprint runs along the row you are on, it does
not tunnel into a sup/sub or a fraction - and once nothing further remains in that row the last step
falls through to the plain move, which is what exits the slot. Repeated Shift+Right still gets you
out, in fewer presses. Vertical movement is deliberately unaffected. ]]
--[[ Landmark glyphs beyond the brackets, by their own ascii (resolved to ncod once, lazily - this
runs before any fontset exists at require time). Kept as ascii here so the list reads as what it
is; add to it and the sprint picks the new stop up with no other change.
@date 2026-09-08 09:00 ]]
local SPRINT_LANDMARK_ASCII = {"=", ";"}
local sprint_landmark_ncod = nil

-- #############################################################################################
-- Selection
-- #############################################################################################

--[[ SELECTION - deliberately confined to ONE horiz.

Ruled: "selecting in a formula can work in horiz limited zone, so you can select the
things in a row in a horiz, but going down with your selection or up a sup is not allowed". That
constraint is what makes this tractable at all: a horiz is already a flat list, so a selection is
just an index range in it and never has to reason about what a partial sup/sub or half a fraction
would even mean.

container.sel_anchor is a wref to the atom the selection was started from; the selection runs
between that atom's slot and the cursor's. Both ends are ROW SLOTS, in the same 0..#children
numbering the cursor already uses (0 = resting on the horiz itself, "before everything"), so the
selected children are exactly lo+1..hi. ]]

--[[ Which row slot a cursor position occupies: its horiz and its index there. A supsub's own BASE
reads as its supsub's slot (base_of()'s established convention, the same one try_close_bracket()
uses), so selecting across "(a)^{2}" treats that whole compound as the one slot it visually is.
nil when the position isn't in a horiz at all.
@date 2026-09-08 09:00 ]]
local function slot_of(node)
    local owner = base_of(node)
    if owner then
        node = owner
    end
    if is_horiz(node) then
        return node, 0
    end
    local h = node:get_parent()
    if not h or not is_horiz(h) then
        return nil, nil
    end
    return h, node:get_parent_idx()
end

--[[ The live selection as (horiz, lo, hi) - children lo+1..hi are selected - or nil when there
isn't one. Returns nil rather than an empty range when the two ends have collapsed onto the same
slot, so callers can treat "no selection" and "an empty one" identically. Also nil if the anchor has
been cut from the tree, or somehow ended up in a different horiz than the cursor - neither should
happen, but a selection spanning two rows is exactly the thing this feature is defined not to do.
@date 2026-09-08 09:00 ]]
function mformula_new.selection_range(container)
    mexpru.check_container(container)
    if not container.sel_anchor then
        return nil
    end
    local anchor = container.sel_anchor:get_obj()
    if not anchor then
        return nil
    end
    local a_horiz, a_idx = slot_of(anchor)
    local c_horiz, c_idx = slot_of(container.cursor_pos:get_obj())
    if not a_horiz or not c_horiz or not mexpru.same(a_horiz, c_horiz) or a_idx == c_idx then
        return nil
    end
    return a_horiz, math.min(a_idx, c_idx), math.max(a_idx, c_idx)
end

--[[ `math.select_left` / `math.select_right`. Moves the cursor one slot along WITHIN its own horiz -
never the
ordinary move_left()/move_right(), which would descend into a sup/sub or climb out of the row
entirely, both of which this feature exists to forbid. Clamped at both ends, so running into the
edge of the row simply stops rather than escaping it.
@date 2026-09-08 09:00 ]]
local function extend_selection(container, dir)
    local cursor = container.cursor_pos:get_obj()
    local horiz, idx = slot_of(cursor)
    if not horiz then
        return
    end
    if not container.sel_anchor then
        container.sel_anchor = vc.wref_mexpr(cursor)
    end
    local children = mexpru.u(horiz).children
    local next_idx = idx + dir
    if next_idx < 0 or next_idx > #children then
        return
    end
    container.cursor_pos = vc.wref_mexpr(next_idx == 0 and horiz or children[next_idx])
end

--[[ `edit.select_all` inside a formula: everything in the TOP-LEVEL row, selected.

THE ROOT ROW, not the row the caret happens to be in. A selection may never leave its horiz (see the
SELECTION comment above), so with the caret inside a sup there are two readings of "all" - that sup's
row, or the formula - and only one of them is what the words say. The caret moves out to the root
row, the same way select-all in any text editor leaves it at the end of what it selected.

Nothing happens when the row is empty (there is no slot to put the far end on) or when a pending
bracket confines the cursor, which is the one state cursor_pos_forbidden exists to protect: a
select-all that teleported out of an unclosed bracket would be a way around it.
@date 2026-09-12 00:40 ]]
local function select_all(container)
    mexpru.check_container(container)
    local root = container.root
    if not is_horiz(root) then
        return false
    end
    local children = mexpru.u(root).children
    local last = children[#children]
    if not last or cursor_pos_forbidden(container, last) then
        return false
    end
    --[[ Anchor ON the horiz itself: slot 0 is "before everything" in the same numbering the cursor
    uses, so anchor 0 with the cursor at #children makes the range 1..#children - the whole row. ]]
    container.sel_anchor = vc.wref_mexpr(root)
    container.cursor_pos = vc.wref_mexpr(last)
    return true
end

--[[ Removes the selected run, if there is one. Returns true when the keypress was CONSUMED - which
includes the refusal below, since silently falling through to an ordinary backspace after declining
to delete a selection would delete something the user never pointed at.

Refuses a run whose brackets don't balance on their own: taking "(a" out of "(a)" would leave a
close with no partner, which is precisely the state the counter rule exists to make unreachable.
Selecting a whole "(a)" and deleting it is fine, since that run balances.

The emptied-span check mirrors the ordinary backspace path's: removing everything between a pair
leaves resolve_bracket_pairs() with a span it errors loudly on, so a fresh empty atom fills the gap
the same way it does there.
@date 2026-09-08 09:00 ]]
--[[ Exported for tests, the convention make_supsub()/make_frac() already use: the real entry point
is the keypress above, which needs a live ImGui for keymap.pressed(). @date 2026-09-12 00:40 ]]
mformula_new.select_all = select_all

local function delete_selection(container, fontset)
    local horiz, lo, hi = mformula_new.selection_range(container)
    if not horiz then
        return false
    end
    local children = mexpru.u(horiz).children
    local horiz_sz = mexpru.u(horiz).sz

    local run = {}
    for i = lo + 1, hi do
        run[#run + 1] = children[i]
    end
    if not mexpru.brackets_balanced(run) then
        print("mformula_new: refusing to delete a selection that would split a bracket pair")
        return true
    end

    local cut = {}
    for i = hi, lo + 1, -1 do
        cut[#cut + 1] = table.remove(children, i)
    end

    -- Did that empty out an enclosing pair? (mexpru.peer_slot(), not a hand-rolled adjacency test.)
    local before = children[lo]
    local before_br = before and mexpru.u(before).bracket
    if before_br and before_br.is_open and before_br.peer
            and mexpru.peer_slot(children, before) == lo + 1 then
        table.insert(children, lo + 1, build_empty_atom(fontset, horiz_sz))
    end

    local cursor_node
    if #children == 0 then
        -- A horiz can never be left with nothing in it (mexpr_merge_h needs at least one child) -
        -- same single-empty-atom fallback the ordinary backspace uses.
        cursor_node = build_empty_atom(fontset, horiz_sz)
        children[1] = cursor_node
    end

    local rebuilt = mexpru.horiz(fontset, children, horiz_sz)
    container.root = mexpru.propagate_rebuild(fontset, horiz, rebuilt)
    -- Cursor lands where the run began - "before what was removed", the same convention every other
    -- deletion here follows. lo == 0 means the run started the row, so rest on the horiz itself.
    container.cursor_pos = vc.wref_mexpr(cursor_node or (lo > 0 and children[lo]) or rebuilt)

    -- Cutting waits until AFTER propagate_rebuild(), same ordering requirement as the ordinary
    -- cascade (the old ancestor chain still references these until then).
    for _, node in ipairs(cut) do
        mexpru.cut(node)
    end
    mark_edited(container)      -- drops the (now removed) selection along with the version bump
    return true
end

--[[ Typing over a selection replaces it, the way it does in any editor. Shared by the character
loop and by Space (which has its own branch and so never reaches that loop).

Returns the cursor's target and its four flags, re-derived AFTER the removal since that moves the
cursor - or nil when there is nothing to insert into, which happens when delete_selection() declined
the removal (an unbalanced run). Declining the delete has to decline the insert too: typing into the
middle of a run the editor just refused to remove would be a worse outcome than doing nothing.
@date 2026-09-08 09:00 ]]
local function replace_selection_before_insert(container, fontset, target, target_parent,
        target_is_horiz, target_is_empty, target_is_supsub_base)
    if not mformula_new.selection_range(container) then
        return target, target_parent, target_is_horiz, target_is_empty, target_is_supsub_base
    end
    if not delete_selection(container, fontset) or mformula_new.selection_range(container) then
        return nil
    end
    local t = container.cursor_pos:get_obj()
    local tp = t:get_parent()
    return t, tp,
            mexpru.u(t).kind == "horiz",
            t.type == vc.MEXPR_TYPE_EMPTY_BOX,
            is_wrapper_base(t, tp)
end

-- Exported for testability only (same reason make_supsub()/make_frac() are - handle_input() itself
-- is keypress-driven and can't be called headless).
--[[ Does a Ctrl+arrow sprint STOP at this node?

Core: the landmarks are brackets and operator symbols - the joints of an expression - so sprinting
moves between the meaningful parts rather than by a fixed number of glyphs.

Detail: reads THROUGH slot_atom, because `(a)^{2}` keeps its `)` as the supsub's BASE. Scanning
siblings alone sees no bracket there and sprints past the whole group - reported live, "shift
doesn't stop at )". The same blind spot surfaces in three other places; slot_atom carries the note.
@date 2026-09-12 04:15 ]]
function mformula_new.is_sprint_landmark(node)
    -- mexpru.slot_atom(): what this row slot actually carries, looking through a supsub to its own
    -- base. "(a)^{2}" keeps its ")" as the BASE, so a scan of siblings alone sees no bracket there
    -- and sprints past the whole group - reported live, "shift doesn't stop at)". See
    -- slot_atom()'s own comment for the other three places that same blind spot surfaced.
    local probe = mexpru.slot_atom(node)

    if mexpru.u(probe).bracket then
        return true
    end
    -- Only a real SYMBOL carries a meaningful symb.code - every other kind leaves that field at
    -- whatever it defaulted to, which could collide with a landmark's own code by accident.
    if probe.type ~= vc.MEXPR_TYPE_SYMBOL then
        return false
    end
    if not sprint_landmark_ncod then
        sprint_landmark_ncod = {}
        for _, ascii in ipairs(SPRINT_LANDMARK_ASCII) do
            local entry = char.find_by_ascii(ascii)
            if entry then
                sprint_landmark_ncod[entry.ncod] = true
            end
        end
    end
    return sprint_landmark_ncod[probe.symb.code] == true
end

--[[ One sprint step along the row, in the direction `dir`. Returns whether it moved.

Scans only the cursor's IMMEDIATE horiz - a sprint runs along the row you are on rather than
tunnelling into a sup or a fraction - and returns false once nothing further remains that way, which
is what lets the caller fall through to the plain move and leave the slot.
@date 2026-09-08 09:30 ]]
local function sprint_horizontal(container, dir)
    local target = container.cursor_pos:get_obj()
    local horiz = is_horiz(target) and target or target:get_parent()
    if not horiz or not is_horiz(horiz) then
        return false
    end
    local children = mexpru.u(horiz).children
    -- Resting ON the horiz is position 0 ("before everything" - this file's own model comment).
    local idx = is_horiz(target) and 0 or target:get_parent_idx()

    local first, last = (dir > 0) and idx + 1 or idx - 1, (dir > 0) and #children or 1
    for i = first, last, dir do
        if mformula_new.is_sprint_landmark(children[i]) then
            container.cursor_pos = vc.wref_mexpr(children[i])
            return true
        end
    end

    -- No bracket that way - run to the slot's own edge instead, if not already sitting on it.
    if dir > 0 and idx < #children then
        container.cursor_pos = vc.wref_mexpr(children[#children])
        return true
    elseif dir < 0 and idx > 0 then
        container.cursor_pos = vc.wref_mexpr(horiz)
        return true
    end
    return false        -- already at the edge: let the plain move carry us out of the slot
end

--[[ All four arrows - plain, Alt-reversed, selecting or sprinting - behind the pending-bracket
confinement every cursor move goes through (cursor_pos_forbidden()'s own comment). Returns true when
a key was actually consumed. Left/Right take no Alt variant (a plain reciprocal chain, nothing to
reverse); Up/Down take neither of the other two (see sprint_horizontal(), and the SELECTION note
below on why a selection cannot leave its row).

`sprint` and `selecting` say WHICH GESTURE this is, and the caller reads them off the keymap rather
than off the modifier keys - see the call site for what happened when it did otherwise.
@date 2026-09-11 07:40 ]]
local function handle_arrows(container, alt, sprint, selecting)
    local function go(move)
        local before = container.cursor_pos
        -- Any ordinary movement drops the selection - it only survives the gesture that builds it.
        if not selecting then
            container.sel_anchor = nil
        end
        move(container)
        if cursor_pos_forbidden(container, container.cursor_pos:get_obj()) then
            container.cursor_pos = before
        end
    end

    -- Shift+Left/Right EXTENDS instead of moving. Only horizontally: a selection may never leave
    -- its row (see the SELECTION comment above), so Up/Down keep their plain meaning and simply
    -- drop the selection like any other move.
    if selecting then
        if keymap.pressed("math.select_left") then
            go(function(c) extend_selection(c, -1) end)
            return true
        end
        if keymap.pressed("math.select_right") then
            go(function(c) extend_selection(c, 1) end)
            return true
        end
    end
    if keymap.pressed("nav.left") or keymap.pressed("math.sprint_left") then
        go(function(c)
            if not (sprint and sprint_horizontal(c, -1)) then
                mformula_new.move_left(c)
            end
        end)
        return true
    end
    if keymap.pressed("nav.right") or keymap.pressed("math.sprint_right") then
        go(function(c)
            if not (sprint and sprint_horizontal(c, 1)) then
                mformula_new.move_right(c)
            end
        end)
        return true
    end
    if keymap.pressed("nav.up") or keymap.pressed("math.back_up") then
        go(function(c)
            if alt then
                mformula_new.move_up_reverse(c)
            elseif not (sprint and sprint_vertical(c, -1)) then
                mformula_new.move_up(c)
            end
        end)
        return true
    end
    if keymap.pressed("nav.down") or keymap.pressed("math.back_down") then
        go(function(c)
            if alt then
                mformula_new.move_down_reverse(c)
            elseif not (sprint and sprint_vertical(c, 1)) then
                mformula_new.move_down(c)
            end
        end)
        return true
    end
    return false
end

--[[ Everything handle_input() needs to know about where the cursor currently IS, derived fresh from
container.cursor_pos. Factored out because the typing loop has to re-derive it after EVERY inserted
character: an insert rebuilds the spine and moves the cursor, so `target` and its four companions are
stale the moment one goes in.

Returns, in order: the node the cursor names, its parent, whether it is a horiz, whether it is the
empty placeholder, whether it is a supsub's own BASE, and the size level to build at.

  - supsub base: parent is a supsub AND that supsub's own .base IS target (not .sup/.sub - a base is
    a bare atom directly under the supsub, see make_supsub()), which is the only way to tell them
    apart.
  - size comes off cursor_pos's own node, never the outer `sz` (that is the whole formula's size and
    would be wrong for anything typed inside a smaller sup/sub). Falls back to the base's size when
    target is a bare supsub node - its own resting spot after move_left()/move_right(), and a supsub
    carries no u(_).sz of its own. Ctrl+/ pressed exactly there used to crash on a nil size
.
@date 2026-09-08 09:00 ]]
local function cursor_state(container)
    -- live_cursor(), not a raw get_obj(): a dangling weak ref recovers to the root instead of
    -- returning nil and dead-ending every branch below it (see live_cursor()'s own comment).
    local target = live_cursor(container)
    if not target then
        return nil
    end
    local target_parent = target:get_parent()
    return target,
           target_parent,
           (mexpru.u(target).kind == "horiz"),
           (target.type == vc.MEXPR_TYPE_EMPTY_BOX),
           is_wrapper_base(target, target_parent),
           wrapper_base_sz(target)
end

--[[ ONE FRAME of input for this formula, and the only entry point the editors use: every key, the
mouse having already been routed by the caller.

Called UNCONDITIONALLY every frame a formula owns input - not on a keypress edge - so it decides for
itself whether anything applies and no caller has to know which keys mean something inside a
formula. Whether the tree actually changed is not returned: the callers read container.version,
which every real edit bumps.

EVERY EDIT HAS THE SAME SHAPE, whatever the key. Find the cursor's immediate horiz (itself, if it is
one, otherwise its parent), splice that horiz's own remembered children list, rebuild it, and let
propagate_rebuild() ripple the new node up to the root and refresh the position cache. The model at
the top of this file says which splice each (node kind x key) pair does.

fontset and sz are needed because an edit builds real mexpr nodes as it goes rather than deferring
them to a later layout pass, and a node cannot be built without knowing what it is drawn with.
@date 2026-09-08 09:30 ]]
function mformula_new.handle_input(container, fontset, sz)
    mexpru.check_container(container)
    -- cursor_state() above derives all six; the typing loop below re-derives them per character.
    local target, target_parent, target_is_horiz, target_is_empty, target_is_supsub_base,
            target_sz = cursor_state(container)

    -- Checked ahead of plain typing, same as the old editor's own sup/sub handling - a no-op
    -- while cursor_pos is on a horiz (nothing specific to wrap yet - see this file's own model
    -- comment on the horiz-cursor case). On a supsub's own base, this is only a no-op if the
    -- REQUESTED side already exists (nesting a second supsub onto an already-occupied side isn't a
    -- real thing to want - logged, not silently ignored) - if that side is genuinely absent (sup/sub
    -- are lazy now, not eagerly both built - see make_supsub()'s own comment), this FILLS IT IN
    -- instead: a real structural change (the supsub's own bb changes - an empty side still reserves
    -- real layout space, per math_expr_composer.h), so it goes through the same
    -- rebuild-and-propagate-up path as every other edit, not treated as a lighter-weight operation.
    -- Raw modifier state is still needed: the Alt+letter / Alt+punctuation glyph families below
    -- are whole key families rather than single actions, and handle_arrows() takes the flags as
    -- parameters to choose plain vs sprint vs reverse movement.
    local ctrl_down, shift_down, alt_down = keymap.mods()
    --[[ NO BLOCK BELOW GATES ON A MODIFIER, and none may. Each block used to test ctrl/shift before
    looking at the key, which would quietly defeat the customiser: rebind one of these to
    Alt+something and the outer guard would swallow it before the binding was ever consulted. Every
    keymap.pressed() matches its own modifiers exactly, so a gate is redundant as well as harmful.
    The raw flags read above are for the two things that are NOT single actions: the Alt+letter and
    Alt+punctuation glyph families, and handle_arrows(), which needs them to choose between a plain
    move, a sprint and a reverse. ]]
    if not target_is_horiz then
        local sup_pressed = keymap.pressed("math.sup")
        local sub_pressed = keymap.pressed("math.sub")
        if sup_pressed or sub_pressed then
            if mexpru.u(target).bracket and mexpru.u(target).bracket.is_open
                    and mexpru.u(target).bracket.type ~= char.BRACKET_INTEGRAL then
                --[[ An OPEN bracket never becomes a supsub's base - a CLOSE one is a different
                matter entirely and is explicitly allowed (see below).

                Ruled, verbatim: "bracket as base is legitimate, this bracket ')', not
                this one '('" - and it isn't an arbitrary split. "(a+b)^{2}" is ordinary maths, and
                in this model the ONLY way to write it is the sup hanging off the ")" - the closing
                bracket is what the exponent visually and semantically attaches to, so that shape
                has to stay reachable (it's already in this repo's own saved demo content, and
                from_latex() reads it back that way too). An exponent on the OPEN bracket, by
                contrast, means nothing at all - and a still-PENDING open atom wrapped as a base
                additionally broke closing it outright, since try_close_bracket() resolves its own
                open_atom:get_parent() expecting a plain horiz, not a supsub (reported live:
                "a+a(^A", stuck, un-closeable, every later ")" a silent no-op).

                The guard is one-sided for that reason: blocking both made "(a+b)^2" impossible
                to type at all. ]]
                print("mformula_new: ignoring Ctrl+Shift+=/- on an OPEN bracket - an exponent "
                        .. "belongs on the closing bracket of a group, never the opening one")
            else
                --[[ One call for every case. Whether this base already carries a wrapper, and
                whether that wrapper's side is free, is make_supsub's own question now - the branch
                that used to answer it here is gone, along with the drift it caused. ]]
                mformula_new.make_supsub(container, fontset, sup_pressed and "sup" or "sub")
            end
            return
        end
    end

    --[[ `edit.select_all`. Ahead of copy/cut so the two compose the way they do in a text box:
    Ctrl+A then Ctrl+C is the whole formula on the clipboard. The binding is the text editor's own
    `edit.select_all` rather than a new one - it is the same idea, and a formula that answered a
    different key for it would be a second thing to learn. ]]
    if keymap.pressed("edit.select_all") then
        select_all(container)
        return
    end

    --[[ `edit.copy` / `edit.cut` on a selection, written out as "$$...$$" - the same wrapper a text
    box uses for a whole embed, so one fragment round-trips both ways: back into a formula, where
    the paste path unwraps it, and out into plain text, where "$$...$$" is already what becomes an
    embed. Cut refuses exactly where delete does, and for the same reason. ]]
    do
        local copy = keymap.pressed("edit.copy")
        local cut = keymap.pressed("edit.cut")
        if copy or cut then
            local horiz, lo, hi = mformula_new.selection_range(container)
            if horiz then
                local children = mexpru.u(horiz).children
                local run = {}
                for i = lo + 1, hi do
                    run[#run + 1] = children[i]
                end
                vc.ImGui_SetClipboardText("$$" .. mformula_new.nodes_to_latex(run) .. "$$")
                if cut then
                    delete_selection(container, fontset)
                end
            end
            return
        end
    end

    --[[ `edit.paste` INTO a formula: parse, then splice. The clipboard already speaks this editor's
    interchange format - a text box renders an embed as "$$<latex>$$" and from_latex() reads it back
    - and three checks sit between the two steps:
      - a "$$...$$" wrapper is unwrapped when present, anything else is read as LaTeX directly, so
        pasting plain "a+b" from elsewhere works rather than being rejected;
      - nothing is spliced while a bracket is PENDING - a half-typed pair plus arbitrary incoming
        brackets is what produced the crossed and orphaned pairs, and there is no sensible reading
        of which open the pasted closes belong to;
      - the parsed content must be bracket-BALANCED on its own, or a partnerless bracket lands in a
        formula that was fine a moment ago.
    Parsed at target_sz, so it is sized to where it lands rather than where it was copied from, and
    each node goes through insert_glyph_at_cursor() - the same splice typing uses - so all four
    cursor cases behave as they already do and the run chains left to right. ]]
    if keymap.pressed("edit.paste") then
        local text = vc.ImGui_GetClipboardText()
        local body = text and (text:match("^%s*%$%$(.*)%$%$%s*$") or text)
        if not body or body == "" then
            return
        end
        if innermost_unclosed_open(container) then
            print("mformula_new: ignoring paste while a bracket is still open - close it first")
            return
        end

        local parsed = mformula_new.from_latex(fontset, target_sz, body)
        local incoming = mexpru.u(parsed.root).children
        -- from_latex() always yields at least one child, an empty placeholder for empty input -
        -- pasting that would insert an invisible slot, so it counts as nothing to paste.
        if #incoming == 0 or (#incoming == 1 and incoming[1].type == vc.MEXPR_TYPE_EMPTY_BOX) then
            return
        end
        if not mexpru.brackets_balanced(incoming) then
            print("mformula_new: refusing to paste - its brackets don't balance on their own")
            return
        end

        for _, node in ipairs(incoming) do
            local t = container.cursor_pos:get_obj()
            local tp = t:get_parent()
            insert_glyph_at_cursor(container, fontset, t, tp,
                    mexpru.u(t).kind == "horiz",
                    t.type == vc.MEXPR_TYPE_EMPTY_BOX,
                    is_wrapper_base(t, tp),
                    target_sz, node)
        end
        return
    end

    --[[ `math.stack_grow` / `math.stack_shrink`: make a stack, grow it, shrink it (make_vert() and
    shrink_vert()). Their defaults are deliberately WITHOUT Shift - Ctrl+Shift+= and Ctrl+Shift+- are
    already superscript and subscript, and on a US layout "+" IS Shift+Equal, so the literal reading
    of "ctrl+'+'" collides with the sup binding outright. Ruled in favour of the plain Equal and
    Minus keys, which were free and read as the same family as the sup/sub pair. ]]
    do
        if keymap.pressed("math.stack_grow") then
            mformula_new.make_vert(container, fontset, target_sz)
            return
        end
        if keymap.pressed("math.stack_shrink") then
            mformula_new.shrink_vert(container, fontset)
            return
        end
        --[[ ACCENTS. The bar is Ctrl+G, and it took two moves to get there: the original sketch
        said Ctrl+-, which is already how a stack loses a cell three lines up, and Ctrl+B is spoken
        for by a bold that does not exist yet. G is free - the only ImGuiKey_G in this codebase is
        char.lua's greek_keys, which is ALT+G for gamma, a different modifier entirely.

        A context-dependent Ctrl+- (bar on a plain atom, shrink inside a stack) was considered and
        rejected: a key whose meaning depends on where the cursor is is the hardest kind to remap
        coherently, and these are due to become customisable. ]]
        if keymap.pressed("math.accent_bar") then
            mformula_new.toggle_accent(container, fontset, "bar")
            return
        end
        if keymap.pressed("math.dot_add") then
            mformula_new.adjust_dots(container, fontset, 1)
            return
        end
        if keymap.pressed("math.dot_remove") then
            mformula_new.adjust_dots(container, fontset, -1)
            return
        end
        --[[ The hat is Ctrl+6, WITHOUT Shift, even though the accent it writes is "^" and "^" is
        Shift+6 on a US layout. It was Ctrl+Shift+6 - the literal reading of the "ctrl+^" this was
        asked for - and moved on the report "ctrl+6, my bad, no ctrl+shift+6": every
        other accent here (Ctrl+G, Ctrl+. , Ctrl+,) is reachable without Shift, and reaching for it
        on just this one is the odd move out. Nothing else binds a bare Ctrl+digit. ]]
        if keymap.pressed("math.accent_hat") then
            mformula_new.toggle_accent(container, fontset, "hat")
            return
        end
        --[[ The tilde moved here from Ctrl+Shift+` on, when Shift became the "put it
        UNDERNEATH" modifier across the whole family - it could not go on keeping Shift just because
        "~" happens to be Shift+` on a US layout, or the one accent whose unshifted form was free
        would have been the odd one out in both directions at once. ]]
        if keymap.pressed("math.accent_tilde") then
            mformula_new.toggle_accent(container, fontset, "tilde")
            return
        end
    end

    --[[ Shift is "put it UNDERNEATH": the same three accent keys as the block above, dressing the
    other side of the atom. One rule for the whole family rather than three unrelated
    shortcuts, so there is nothing per-accent to remember.

    This block shares the Ctrl+Shift space with the superscript/subscript pair further up, but not
    the keys - those are Equal and Minus - so the order of the two does not matter. ]]
    do
        if keymap.pressed("math.accent_tilde_below") then
            mformula_new.toggle_accent(container, fontset, "tilde", "below")
            return
        end
        if keymap.pressed("math.accent_hat_below") then
            mformula_new.toggle_accent(container, fontset, "hat", "below")
            return
        end
        if keymap.pressed("math.accent_bar_below") then
            mformula_new.toggle_accent(container, fontset, "bar", "below")
            return
        end
        -- Ctrl+Shift+[ / Ctrl+Shift+] : a limit above / below - see make_bigop().
        if keymap.pressed("math.limit_above") then
            mformula_new.make_bigop(container, fontset, "sup")
            return
        end
        if keymap.pressed("math.limit_below") then
            mformula_new.make_bigop(container, fontset, "sub")
            return
        end
        --[[ Ctrl+Shift+. and Ctrl+Shift+, - vector arrows, right and left. The keys ARE the
        mnemonic: on a US layout Shift+. is ">" and Shift+, is "<", which is what they draw.

        These are the one place Shift does NOT mean "underneath". The dot pair (Ctrl+. / Ctrl+,) is
        add/remove rather than above/below and never had a shifted form, so the shifted pair was
        free - and a leftward arrow is a different accent, not the same one somewhere else. ]]
        if keymap.pressed("math.vec") then
            mformula_new.toggle_accent(container, fontset, "vec")
            return
        end
        if keymap.pressed("math.vec_left") then
            mformula_new.toggle_accent(container, fontset, "vecleft")
            return
        end
        --[[ Ctrl+Shift+\ - the "|" delimiter (BAR_BRACKET's own comment). Close-then-open, in
        that order: with a bar already open and the cursor somewhere it can legally close, this
        press is the closing one. try_close_bracket() is left to judge that, since it owns every
        rule about where a close is allowed (close_position_ok()), and it now says so with a return
        value - it used to be inferred from container.pending_bracket going nil, which stopped
        existing when that slot became a scan of the row.

        If it declines - the innermost unclosed bracket is a different type, or the cursor has
        wandered out of the closable region - the press opens a new bar instead, which is what this
        key has always meant when there was nothing to close. ]]
        if BAR_BRACKET and keymap.pressed("math.bar_bracket") then
            if try_close_bracket(container, fontset, BAR_BRACKET) then
                -- closed by the call above
            elseif target_is_supsub_base then
                print("mformula_new: ignoring Ctrl+Shift+\\ on a supsub's own base - a bracket "
                        .. "atom can never become one (it would be permanently unclosable) - "
                        .. "move off the base first")
            else
                open_bracket(container, fontset, target, target_parent, target_is_horiz,
                        target_is_empty, target_is_supsub_base, target_sz, BAR_BRACKET)
            end
            return
        end
    end

    -- `math.frac` (make_frac()): a fresh, empty fraction at the cursor. A no-op, logged, on a
    -- supsub's own base: unlike sup/sub, a fraction has no notion of a base to attach to, so there
    -- is no "fill in the missing side" alternative here - it simply does not apply there.
    if keymap.pressed("math.frac") then
        if target_is_supsub_base then
            print("mformula_new: ignoring Ctrl+/ on a supsub's own base - fractions have no base to attach to")
        else
            mformula_new.make_frac(container, fontset, target_sz)
        end
        return
    end

    -- Alt+letter / Alt+Shift+letter Greek shortcuts (char.greek_keys/greek_alt/greek_alt_shift) -
    -- ported from editor_text.lua's own plain-text handling (this file had NONE at all before
    -- - reported live: "alt+chars doesn't produce greek letters like outside of math box"). Same
    -- fallback convention as editor_text.lua's own version: no distinct Greek glyph for a given letter
    -- (or none mapped) falls back to the plain/uppercase Latin letter rather than inserting nothing.
    -- char.size_delta_by_desc's own boost (currently just "\\int") is applied at construction here
    -- too, same as mformula_latex.lua's own from_latex() and mexpru.rescale_node()'s own re-
    -- derivation - u(_).sz stays the surrounding NOMINAL level regardless (that field is LOGICAL
    -- "what level does this belong to", never a visual one - test_int_size.lua's own comment).
    -- Arrows, before the Alt branch below: that branch returns unconditionally (Alt is otherwise
    -- entirely about Greek letters), which used to make every Alt+arrow a dead key. Handled here in
    -- one place for both, so plain and Alt-reversed movement can't drift apart.
    --[[ THE TWO FLAGS ARE ASKED OF THE KEYMAP, NOT OF THE MODIFIER KEYS.

    They were computed here as `shift and not ctrl` and `ctrl and shift`, which was a second copy of
    what the bindings already say - and the two drifted the moment the bindings were swapped
    (2026-09-10, "holding shift selects, ctrl+shift jumps on left,right arrows"). keymap.lua took
    the new meaning, this line kept the old one, and the result was that inside a formula Shift+Left
    quietly moved instead of selecting and Ctrl+Shift+Left moved instead of sprinting: `selecting`
    was false for Shift, so the select branch was never reached, and `sprint` was false for
    Ctrl+Shift, so the sprint branch fell through to the plain move. Reported 2026-09-11: "the shift
    held does not select in the formula and ctrl+shift doesn't sprint +arrows left right".

    Reading the actions instead makes that impossible, and it is also what the keymap registry is
    FOR - these bindings are customisable, and a hardcoded chord here would ignore a rebinding while
    the action right below it honoured one. Both directions are asked because the flags are about
    the GESTURE, not about which arrow: handle_arrows uses `selecting` for Up/Down too, where it
    means "do not drop what is selected". ]]
    if handle_arrows(container, alt_down,
            keymap.pressed("math.sprint_left") or keymap.pressed("math.sprint_right"),
            keymap.pressed("math.select_left") or keymap.pressed("math.select_right")) then
        return
    end

    --[[ WHILE AN INTEGRAL IS PENDING, THE ONLY THING THAT TYPES IS `d`.

    Author, 2026-09-10: "dissallow writing anything while the integral is pending, only d, so you
    need to close it first, not direcly there, where you want, but nothing else in the meantime".
    Arrows are above this line, so you can still walk to wherever the differential belongs; nothing
    between here and the character queue can insert or restructure anything.

    DELETION IS THE ONE EXCEPTION, and it has to be: a pending pair with no way to type and no way
    to delete would be a trap with no exit. Backspace on the `\int` removes it and the formula is
    ordinary again.

    THIS IS ALSO WHAT MAKES SUP/SUB ON THE OPEN HALF SAFE. try_close_bracket resolves its open
    atom's parent expecting a plain horiz, and an open bracket wrapped in a supsub breaks that -
    the live "a+a(^A" report, stuck and un-closeable. A pending integral cannot acquire a supsub at
    all, because the key that would build one cannot be pressed while it is pending.
    @date 2026-09-10 23:40 ]]
    if pending_integral(container)
            and not (keymap.pressed("text.backspace") or keymap.pressed("text.delete")) then
        for _, cp in ipairs(vc.ImGui_input_queue_chars()) do
            if cp == 100 then       -- 'd'
                --[[ A refusal stays a refusal: if the cursor is somewhere the pair may not close
                from, the `d` is NOT typed instead. Nothing else is accepted here, so leaving a
                stray letter behind would be the one way to write while pending. ]]
                try_close_bracket(container, fontset, char.BRACKET_INTEGRAL)
                return
            end
        end
        return
    end

    --[[ Space, handled as a KEY rather than left to the character queue below - which filters
    `cp > 32` and so drops it (32 is space), exactly as the old version did, for the
    reason it gives: the queue doesn't always deliver one. Without this a space simply could not be
    typed inside a formula at all - "a", Space, "b" came out "ab" (measured, porting
    audit). Inserted as an ordinary glyph like any other character; slot_markers() is what keeps it
    visible despite having no ink of its own. ]]
    if keymap.pressed("text.space") then
        -- Space first completes a "\name" if one is being typed - see try_resolve_command().
        if mformula_new.try_resolve_command(container, fontset) then
            return
        end
        local entry = char.find_by_ascii(" ")
        if entry then
            -- A space is typing, so it REPLACES a selection like any other character does. Its own
            -- branch (see above) means it doesn't reach the char loop's replace, so it does it here.
            local t, tp, t_horiz, t_empty, t_base = replace_selection_before_insert(container, fontset,
                    target, target_parent, target_is_horiz, target_is_empty, target_is_supsub_base)
            if not t then
                return
            end
            local new_glyph = mexpru.mexpr_symbol(fontset, {size = mexpru.physical_sz(target_sz),
                    code = entry.ncod}, true)
            mexpru.u(new_glyph).sz = target_sz
            insert_glyph_at_cursor(container, fontset, t, tp, t_horiz, t_empty, t_base, target_sz,
                    new_glyph)
        end
        return
    end

    --[[ Alt+punctuation: the set-theory symbols, which Alt+letter cannot reach because every letter
    is spoken for by Greek. Paired by the key's own left/right position, and by Shift for the
    "bigger" relation of each pair:

        Alt+[  union        Alt+]  intersection
        Alt+,  in           Alt+.  contains          (membership)
        Alt+Shift+,  subset-or-equal   Alt+Shift+.  superset-or-equal

    Requested 2026-09-06. Each is an ordinary glyph, inserted exactly as a typed character is. ]]
    -- `not ctrl_down`, added 2026-09-07 - the same ruling editor_text.lua's Greek loop carries:
    -- Alt+letter is Greek, Ctrl+Alt+letter is not, and AltGr (which reports as Ctrl+Alt) therefore
    -- no longer produces one. Both glyph families stay raw ImGui polls because they are FAMILIES,
    -- destined for F2's glyph-binding section rather than the shortcut registry.
    if alt_down and not ctrl_down then
        -- char.alt_symbols, not a table of its own: F2's legend draws from the same one.
        for _, sym in ipairs(char.alt_symbols) do
            if vc.ImGui_IsKeyPressed(sym.key_id, true) then
                local entry = char.find_by_desc((shift_down and sym.shift) or sym.plain)
                if entry then
                    local new_glyph = mexpru.mexpr_symbol(fontset,
                            {size = mexpru.physical_sz(target_sz), code = entry.ncod}, true)
                    mexpru.u(new_glyph).sz = target_sz
                    insert_glyph_at_cursor(container, fontset, target, target_parent,
                            target_is_horiz, target_is_empty, target_is_supsub_base,
                            target_sz, new_glyph)
                    return
                end
            end
        end
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
                -- glyphmap, not char.lua's tables - see editor_text.lua's own note. Both paths
                -- must read the same live map, or Alt+letter would mean different things inside
                -- a formula and outside one.
                local entry = glyphmap.entry(key_name, true, shift_down)
                if not entry then
                    entry = char.find_by_ascii(shift_down and letter:upper() or letter)
                end
                if entry then
                    --[[ AN INTEGRAL IS OPENED, NOT INSERTED. `\int` is the open half of a pair whose
                    close is the `d` of its differential, so typing it starts a pending bracket
                    exactly as `(` does - and the `d` that eventually closes it is what tells the
                    parser where the body ends and which variable is being integrated over. Author,
                    2026-09-10: "( is /int and ) is d". ]]
                    if entry.desc == "\\int" and not target_is_supsub_base then
                        open_bracket(container, fontset, target, target_parent, target_is_horiz,
                                target_is_empty, target_is_supsub_base, target_sz,
                                char.BRACKET_INTEGRAL)
                        handled = true
                        return
                    end
                    local delta = char.size_delta(entry.desc)
                    local glyph_sz = delta and math.max(1, math.min(target_sz + delta, MAX_SIZE_INDEX)) or target_sz
                    local new_glyph = mexpru.mexpr_symbol(fontset,
                            {size = mexpru.physical_sz(glyph_sz), code = entry.ncod}, true)
                    mexpru.u(new_glyph).sz = target_sz
                    insert_glyph_at_cursor(container, fontset, target, target_parent, target_is_horiz,
                            target_is_empty, target_is_supsub_base, target_sz, new_glyph)
                    --[[ `handled`, not a bare return: this is inside the per-key callback now, so
                    returning only ends that one row's turn. Without the flag the walk continues
                    and a second row bound to the same key would insert a second glyph. ]]
                    handled = true
                    return
                end
            end
        end)
        return
    end

    --[[ EVERY character in the queue, not just the first.

    Each branch below used to `return`, so exactly one character per frame was inserted and the rest
    of that frame's queue was dropped on the floor - ImGui clears the queue each frame regardless of
    how much of it was read. Invisible at human typing speed on a frame that never drops, which is
    why it survived; it bites whenever characters arrive in a burst - an OS key-repeat burst, a
    frame that ran long, an IME committing several at once. Found by sending 13 characters
    in one frame over the debug pipe: the recorder logged all 13, the document got the first.

    The whole cursor state has to be re-derived per character (cursor_state()), because inserting
    one rebuilds the spine and moves the cursor - `target` and its companions are stale immediately
    after. That is the entire reason this could not just have its `return`s deleted. ]]
    --[[ KEYS WITH A `plain` OVERRIDE, before the character queue - the same gap editor_text.lua
    describes in its own copy of this, and it has to be closed in both or a remapped key would type
    one thing in prose and another inside a formula.

    Characters arrive from ImGui's queue carrying no idea which key produced them, so a remapped
    key is invisible there; it has to be polled. A key that fires here suppresses the queue for
    this frame, since the queue is about to deliver that same key's character too. ]]
    local overridden = false
    glyphmap.each(function(key_name, slots)
        if overridden or not slots.plain then
            return
        end
        if vc.ImGui_IsKeyPressed(keymap.key_of(key_name), true) then
            local entry = glyphmap.entry(key_name, false, false)
            if entry then
                local t, tp, t_horiz, t_empty, t_base, t_sz = cursor_state(container)
                if t then
                    local new_glyph = mexpru.mexpr_symbol(fontset,
                            {size = mexpru.physical_sz(t_sz), code = entry.ncod}, true)
                    mexpru.u(new_glyph).sz = t_sz
                    insert_glyph_at_cursor(container, fontset, t, tp, t_horiz, t_empty, t_base,
                            t_sz, new_glyph)
                    -- Counted, not frame-skipped - see editor_text.lua's note: the key event and
                    -- its character need not arrive in the same frame, and skipping one frame let
                    -- both through.
                    container.suppress_chars = (container.suppress_chars or 0) + 1
                    overridden = true
                end
            end
        end
    end)
    --[[ NOT returning here. The character this key produces may still be sitting in the queue, or
    may arrive next frame; either way the loop below is what swallows it, and returning early would
    leave the count owing and the next ordinary character eaten in its place. ]]

    for _, cp in ipairs(vc.ImGui_input_queue_chars()) do
        if cp > 32 and cp < 256 and (container.suppress_chars or 0) > 0 then
            -- Belongs to a key an override already handled; swallow exactly one per override.
            container.suppress_chars = container.suppress_chars - 1
        elseif cp > 32 and cp < 256 then
            local ch = string.char(cp)
            target, target_parent, target_is_horiz, target_is_empty, target_is_supsub_base,
                    target_sz = cursor_state(container)
            if not target then
                return
            end
            -- Typing over a selection replaces it (see replace_selection_before_insert()).
            target, target_parent, target_is_horiz, target_is_empty, target_is_supsub_base =
                    replace_selection_before_insert(container, fontset, target, target_parent,
                            target_is_horiz, target_is_empty, target_is_supsub_base)
            if not target then
                return
            end

            -- '(' / '[' / '{' and ')' / ']' / '}' are intercepted here, ahead of the ordinary
            -- char.find_by_ascii() path below - see open_bracket()'s/try_close_bracket()'s own
            -- comments (near base_of()). Opening a SECOND bracket while one is already pending is a
            -- no-op/blocked (single pending slot, not a stack); a CLOSE bracket always goes through
            -- try_close_bracket() (its own comment covers every way it can be a no-op).
            --
            -- target_is_supsub_base is ALSO blocked here - the mirror image of the bracket-as-
            -- supsub-base guard in the Ctrl+Shift+=/- dispatch below. insert_glyph_at_cursor()'s
            -- own target_is_supsub_base branch makes whatever glyph is being typed the supsub's
            -- NEW base and bumps the OLD one out as a plain sibling - exactly right for an
            -- ordinary letter, but if the glyph being typed is itself a bracket-open character,
            -- that makes IT the base instead: open_atom:get_parent() then returns the supsub node,
            -- not a horiz, which try_close_bracket() never expects - every later ')' silently
            -- no-ops (its own close_parent/open_horiz mismatch check), leaving this bracket
            -- permanently pending. Reported live, ("a(^n"): traced via a temporary DBG
            -- trace to cursor_pos resting on an EXISTING supsub's own base (reached by navigating
            -- out of its sup/sub and back onto the base - move_left()'s own "into base" landing,
            -- exactly like the plain-letter case above), then '(' typed there.
            if OPEN_BRACKETS[ch] then
                if target_is_supsub_base then
                    print("mformula_new: ignoring '(' typed onto a supsub's own base - a bracket "
                            .. "atom can never become one (it would be permanently unclosable) - "
                            .. "move off the base first")
                else
                    --[[ No "one at a time" guard any more. It used to refuse a second open while
                    one was unclosed, which made "{()}" unreachable - reported 2026-09-06 as "a
                    wrong limitation". Nesting is bounded by the counter rule instead: a close pairs
                    with the innermost unclosed open, and only if the types match. ]]
                    open_bracket(container, fontset, target, target_parent, target_is_horiz,
                            target_is_empty, target_is_supsub_base, target_sz, OPEN_BRACKETS[ch])
                end
            elseif CLOSE_BRACKETS[ch] then
                try_close_bracket(container, fontset, CLOSE_BRACKETS[ch])
            elseif try_digraph(container, fontset, target, target_is_supsub_base, ch) then
                -- ">=" and friends replaced the glyph to the left; `ch` is consumed by that.
            else
                -- CHAR_REMAP first: "~" stands for \sim, not for a literal tilde.
                local entry = (CHAR_REMAP[ch] and char.find_by_desc(CHAR_REMAP[ch]))
                        or char.find_by_ascii(ch)
                if entry then
                    -- target_sz is LOGICAL - mapped to PHYSICAL only for the real construction call.
                    local new_glyph = mexpru.mexpr_symbol(fontset, {size = mexpru.physical_sz(target_sz), code = entry.ncod}, true)
                    mexpru.u(new_glyph).sz = target_sz
                    insert_glyph_at_cursor(container, fontset, target, target_parent, target_is_horiz,
                            target_is_empty, target_is_supsub_base, target_sz, new_glyph)
                end
            end
        end
    end

    -- Backspace removes the atom cursor_pos itself names; Delete removes whichever atom comes
    -- right after it. Neither does anything while cursor_pos is on a horiz or an empty atom (see
    -- this file's own model comment) - there's no atom AT that position for either key to act on.
    local backspace = keymap.pressed("text.backspace")
    local fwd_delete = keymap.pressed("text.delete")
    -- A selection takes precedence over either key's ordinary meaning, and BEFORE the horiz/empty
    -- guard below: a selection can legitimately start at slot 0 (cursor resting on the horiz), which
    -- that guard would otherwise turn into a no-op.
    if (backspace or fwd_delete) and delete_selection(container, fontset) then
        return
    end
    --[[ Before the horiz/empty guard below, which would otherwise swallow it: in a still-untyped
    sup/sub the cursor IS on a horiz or an empty atom, and the whole point is that either delete
    key there undoes the spawn. See collapse_empty_supsub().

    DELETE AS WELL AS BACKSPACE since 2026-09-07. It was Backspace only, on the reasoning that
    Delete means "the thing after the cursor" and an empty slot has none - which is consistent, and
    still left Delete doing NOTHING WHATSOEVER in an empty slot, so the key simply appeared broken
    there. Ruled: "if the horiz is empty it should delete, only when the horiz has something else
    than an empty should it not".

    No guard is needed here for that second half: collapsible_supsub() only returns a target when
    the cursor's own slot is untyped, so a slot with content in it declines on its own and Delete
    falls through to its ordinary forward-delete meaning below. ]]
    if (backspace or fwd_delete)
            and mformula_new.collapse_empty_supsub(container, fontset) then
        return
    end
    if (not (backspace or fwd_delete)) or target_is_horiz or target_is_empty then
        return
    end

    -- An overprinted pair (\ne, \notin, \mapsto) deletes as the one symbol it reads as.
    if delete_overprint_unit(container, fontset, target, target_parent, backspace) then
        return
    end

    if target_is_supsub_base then
        -- Delete (forward) on a base has no defined meaning yet ("the next thing" isn't a plain
        -- horiz sibling here) - a no-op, not a guess, until this is actually designed.
        if not backspace then
            return
        end
        -- Backspace: the reverse of typing's "bump the old base out" above - removes base's own
        -- glyph and pulls in whatever sits immediately BEFORE the supsub's own slot in the outer
        -- horiz to become the new base, removing it from there. Falls back to a fresh empty atom
        -- (same size level) if the supsub was already first in that horiz - nothing to pull in.
        local supsub_node = target_parent
        local outer_horiz = supsub_node:get_parent()
        local outer_children = mexpru.u(outer_horiz).children
        -- supsub_node:get_parent_idx() - safe HERE (outer_children is a fresh, unmutated read), but
        -- NOT below anymore, once table.remove() has already mutated this same Lua list - see that
        -- one's own comment.
        local supsub_idx = supsub_node:get_parent_idx()

        -- Cascade (reported live: "(a)^b, remove) ... only the right bracket gets
        -- deleted, the other one stays"): target (the OLD base, about to be discarded below) might
        -- itself be a resolved bracket atom - its own peer has to go down with it too, same
        -- invariant the ORDINARY victim/cascade branch further down already has (this file's own
        -- model comment). Missed here specifically because wrapping a bracket atom as a supsub's
        -- own base moves it OUT of the flat children list resolve_bracket_pairs()/scan_bracket()
        -- ever look at - found via scan_bracket() starting from the SUPSUB's own position (the slot
        -- the bracket atom itself used to occupy), not target:get_parent_idx() (which would answer
        -- target's index WITHIN the supsub - always 1 - not its peer's real position out here).
        -- mexpru.peer_slot() - a direct .peer identity read, for the same reason the ordinary
        -- cascade below uses it: `target` here is a BASE, so it isn't in outer_children at all and
        -- a depth walk from the supsub's slot has no way to tell its real partner from the next
        -- unmatched bracket it happens to meet. Its peer, though, IS an ordinary sibling out here,
        -- so looking it up by identity is both exact and simpler.
        local target_br = mexpru.u(target).bracket
        local peer_idx = mexpru.peer_slot(outer_children, target)

        --[[ ...and the sibling about to be pulled IN can be a bracket atom too. An OPEN one must
        never become a base (same rule as the Ctrl+Shift+=/- guard above, and for the same reasons);
        a CLOSE one is fine and in fact wanted - pulling a ")" in is exactly how "(a)b^{2}" becomes
        "(a)^{2}" when the "b" is backspaced away, which is a perfectly ordinary edit.

        Reported live ("again malformed"), from "(a^{A})" with the cursor back on the
        base "a", Backspace: the preceding sibling there is the pair's own OPEN bracket, and it got
        pulled in as the new base - the formula serialized as "(^{A})", a superscript with no base,
        and the bracket left where scan_bracket()/try_close_bracket() no longer see it as the flat
        sibling they both need. Falls back to the SAME fresh empty atom the "supsub was already
        first in the horiz" case below uses: backspace still does what was asked (the old base is
        gone) while the open bracket stays the ordinary flat sibling it has to be, pair intact. ]]
        local prev = supsub_idx > 1 and outer_children[supsub_idx - 1]
        local prev_br = prev and mexpru.u(prev).bracket
        local prev_is_open_bracket = prev_br ~= nil and prev_br.is_open

        local new_base
        if supsub_idx > 1 and not prev_is_open_bracket then
            new_base = outer_children[supsub_idx - 1]
            table.remove(outer_children, supsub_idx - 1)
            -- The pull-in above may have shifted the peer's own index (if the peer sits AFTER the
            -- pulled-in sibling, e.g. target itself was the OPEN bracket and peer is the close,
            -- further right).
            if peer_idx and peer_idx > supsub_idx - 1 then
                peer_idx = peer_idx - 1
            end
        else
            new_base = build_empty_atom(fontset, target_sz)
        end

        local cut_peer
        if peer_idx then
            cut_peer = table.remove(outer_children, peer_idx)
        end

        local u = mexpru.u(supsub_node)
        local rebuilt_supsub = mexpru.supsub(fontset, new_base, u.sup, u.sub)
        -- Deliberately NOT supsub_node:get_parent_idx() here - the table.remove() calls above
        -- already mutated outer_children (Lua), but outer_horiz's own C++ subobjs hasn't been
        -- rebuilt yet (still reflects the PRE-removal order) - get_parent_idx() would silently
        -- return the stale index. mexpru.index_of() re-scans the LIVE, already-mutated Lua list
        -- instead, which is what's actually needed once the two have diverged like this.
        outer_children[mexpru.index_of(outer_children, supsub_node)] = rebuilt_supsub

        local rebuilt_outer = mexpru.horiz(fontset, outer_children, mexpru.u(outer_horiz).sz)
        container.root = mexpru.propagate_rebuild(fontset, outer_horiz, rebuilt_outer)
        container.cursor_pos = vc.wref_mexpr(new_base)
        -- Only cut_peer here, same ordering reason as the ordinary victim/cascade branch below
        -- (cutting has to wait until AFTER propagate_rebuild() actually completes) - target itself
        -- (the old base) is never explicitly cut anywhere in this branch, a pre-existing gap from
        -- before this fix (not introduced by it): propagate_rebuild() doesn't cut superseded
        -- ancestors it splices OUT of (only the final root, and whatever a caller explicitly cuts
        -- itself - see propagate_rebuild()'s own comment), and this branch never did either.
        if cut_peer then mexpru.cut(cut_peer) end
        mark_edited(container)
        return
    end

    --[[ target_parent is not always a row, and everything below assumes it is.

    A cursor resting on a BIG OPERATOR'S BASE has the bigop itself as its parent, which carries
    base/sup/sub and no children list at all - so the read below produced nil and the first
    indexing of it threw "attempt to index a nil value (local 'children')". Reported 2026-09-07 as
    "still can't delete the sup": the Delete handler died before it could do anything, so the key
    looked inert while actually taking the whole frame down with it.

    This is the third place the same assumption has bitten (make_supsub() above, and
    exit_horiz_leftward()'s missing bigop branch): a bigop is structurally a supsub, and code that
    only pattern-matches "atom inside a horiz" keeps meeting one and falling over. Refusing here
    restores a plain no-op, which is the correct answer anyway - there is no "next atom" to forward
    delete when the cursor is on a slot of a compound rather than in a row. ]]
    local horiz = target_parent
    local horiz_u = horiz and mexpru.u(horiz)
    if not horiz_u or horiz_u.kind ~= "horiz" then
        return
    end
    local horiz_sz = horiz_u.sz
    local children = horiz_u.children
    -- target:get_parent_idx() - safe, `children` is a fresh, unmutated read of target's own parent.
    local i = target:get_parent_idx()

    -- Which atom this keypress actually removes, and where. fwd_delete with nothing after target
    -- is the existing no-op (children[i+1] absent) - unchanged.
    local victim, victim_idx
    if backspace then
        victim, victim_idx = target, i
    elseif fwd_delete and children[i + 1] then
        victim, victim_idx = children[i + 1], i + 1
    else
        return
    end

    -- Bracket cascade (2026-09-04 design discussion): a RESOLVED bracket atom (has a peer) takes
    -- that peer down with it - the pair disappears together, the CONTENT between them survives,
    -- unwrapped, as ordinary siblings (mformula_new.lua's own model: a bracket pair is never a
    -- separate composite node the way a supsub/frac is, its content already lives directly in
    -- `children` alongside everything else - there is nothing else TO unwrap). A still-PENDING
    -- open bracket (typed, never closed - no peer yet) has no cascade target; mexpru.cut() below,
    -- once it runs on it, is what makes container.pending_bracket (a weak ref) correctly read back
    -- nil from then on - no separate bookkeeping needed for that specific field, or for any other
    -- weak ref anywhere that might also point at this same node.
    --[[ mexpru.peer_slot() - a direct .peer identity read, NOT mexpru.scan_bracket(). This used to
    walk by depth, which is what scan_bracket() is for (finding the pair enclosing an ORDINARY
    position, per its own doc comment) and expressly not how a bracket's own partner is meant to be
    found. The difference only shows once a peer can sit somewhere the walk cannot see: a resolved
    ")" that is a supsub's own BASE ("(a)^{N}") is not in `children` at all, so the walk sailed past
    the supsub, met the next unmatched bracket along and cascaded THAT one - two atoms that were
    never partners - leaving the real peer orphaned. Reported live ("reached an invalid
    state"): backspacing in "((A)^{N})" deleted the outer ")" together with the INNER "(", leaving
    the unbalanced "((A)".

    mexpru.slot_atom() on the victim covers the mirror case in the same breath: the victim may not BE
    a bracket and still carry one off with it, since deleting a whole supsub takes its base along and
    that base can be half of a real pair. "Removing anything that CONTAINS half a pair takes the
    other half with it" - not merely "removing a bracket takes its peer". Both readings are now the
    one lookup rather than three chained attempts. ]]
    local victim_br = mexpru.u(victim).bracket
    local peer_idx, peer_is_base = mexpru.peer_slot(children, mexpru.slot_atom(victim))
    -- A peer sitting in somebody's BASE can't be spliced out of the row - that slot needs a new
    -- base instead, which is the branch below.
    local peer_base_owner_idx = peer_is_base and peer_idx or nil
    if peer_base_owner_idx then
        peer_idx = nil
    end

    -- Only table.remove() here - NOT mexpru.cut() yet. Cutting has to wait until AFTER
    -- propagate_rebuild() below actually completes: until then, the OLD (pre-edit) ancestor chain
    -- - not yet superseded - still references these nodes via its OWN C++-side subobjs
    -- (math_expr_composer.h), same as `children` itself did before this table.remove(). Cutting
    -- early releases Lua's claim while that OLD chain still holds its own, so nothing actually
    -- dies - found by this file's own test (test_bracket_cascade.lua) catching exactly that
    -- ordering mistake in an earlier draft of this function.
    local cut_lo, cut_hi, cut_mid, cascade_span_empty
    if peer_base_owner_idx then
        --[[ The peer is a supsub's own BASE ("(a)^{N}" - victim is the "(", its ")" is the base of
        the supsub at peer_base_owner_idx). Removing the pair therefore means giving that supsub a
        NEW base rather than splicing its old one out of `children`, since the old one was never in
        `children` to begin with.

        What it gets is the sibling immediately before it - which, for the shape this arises from,
        is precisely the content that was sitting between the two brackets. That makes this the
        exact inverse of the close-onto-a-base splice in try_close_bracket(): that one bumps the old
        base OUT to make room for the ")", this one pulls it back IN as the ")" goes away, so
        "(a)^{N}" cascades cleanly back to "a^{N}". Falls back to a fresh empty atom when the supsub
        has nothing before it to reclaim, same as the ordinary backspace-a-base path does. ]]
        local supsub_node = children[peer_base_owner_idx]
        local su = mexpru.u(supsub_node)
        local reclaim_idx = peer_base_owner_idx - 1
        local new_base
        if reclaim_idx >= 1 and reclaim_idx ~= victim_idx then
            new_base = children[reclaim_idx]
            table.remove(children, reclaim_idx)
        else
            new_base = build_empty_atom(fontset, horiz_sz)
            reclaim_idx = nil
        end
        -- Re-find the supsub after that removal may have shifted it, then swap its base.
        local owner_now = mexpru.index_of(children, supsub_node)
        children[owner_now] = mexpru.supsub(fontset, new_base, su.sup, su.sub)

        -- Now drop the victim itself, whose index may also have shifted left by the reclaim above.
        local v = mexpru.index_of(children, victim)
        cut_lo = table.remove(children, v)
        i = v
    elseif peer_idx then
        -- Remove the LARGER index first so the smaller one's own index doesn't shift out from
        -- under it. `i` (the empty-span check below) becomes the lower of the two - that check
        -- reasons about the hole the removal left, which for a cascade is where the pair used to
        -- begin.
        local lo, hi = math.min(victim_idx, peer_idx), math.max(victim_idx, peer_idx)
        --[[ An EMPTY pair takes its placeholder with it. "The content survives, unwrapped" is the
        cascade's rule and it is right for `(a)` -> `a`, but the thing inside `()` is not content -
        it is the placeholder the pair needed in order to exist at all, and leaving it behind drops
        a stray empty box into the row (span_is_lone_placeholder's own comment). ]]
        cascade_span_empty = mformula_new.span_is_lone_placeholder(children, lo, hi)
        cut_hi = table.remove(children, hi)
        if cascade_span_empty then
            cut_mid = table.remove(children, lo + 1)
        end
        cut_lo = table.remove(children, lo)
        i = lo
    else
        cut_lo = table.remove(children, victim_idx)
        i = victim_idx
    end

    --[[ Where the CURSOR lands, tracked separately from `i` above: "just before whatever you
    actually deleted", the same convention a plain single-atom backspace already follows - which for
    a cascade means before the atom you deleted, NOT before its peer.

    Reported live: "after the cursor deletes a bracket it shouldn't jump to the other one
    if I do ((a)) and delete, it wil jump me to the left of <a>". Backspacing a pair's CLOSE bracket
    used to land on `i` (= lo, the peer's own slot), teleporting the cursor across the entire group
    to its far left edge - you delete at the right end of "((a))" and end up sitting left of the
    "a". Deleting the OPEN bracket was always right and still is (victim IS lo there, so the old and
    new readings agree exactly) - only the close-bracket direction moves.

    When the peer sat to our LEFT it has been removed too, so everything from victim rightward
    shifted down one - hence victim_idx - 1. ]]
    local cursor_i = victim_idx
    if peer_base_owner_idx then
        -- That branch already re-derived the victim's real, post-reclaim index into `i` - the same
        -- "where the deleted thing was" this wants, so there's nothing to adjust by hand here.
        cursor_i = i
    elseif peer_idx and peer_idx < victim_idx then
        cursor_i = victim_idx - 1
        -- The placeholder between them went too, so one MORE slot before the victim is gone.
        if cascade_span_empty then
            cursor_i = cursor_i - 1
        end
    end
    -- `target`/`victim` are never read again below - only `cut_lo`/`cut_hi`, and only to pass to
    -- mexpru.cut() once it's actually safe to.

    -- Whatever this removal left immediately adjacent at i-1/i might now be a resolved bracket
    -- pair with an EMPTY span between them - either this removal was the ONLY thing between an
    -- open/close pair (the ordinary, non-cascade branch above), or cascading out a NESTED pair
    -- emptied its own OUTER one. resolve_bracket_pairs() (mexpru.lua) errors loudly on an empty
    -- span rather than misbehaving silently - crashed live: "(,a,),left,backspace".
    -- mexpru.scan_bracket() (not a hand-rolled peer check - this file's own established rule)
    -- confirms real adjacency structurally; a fresh empty atom fills the gap, same convention
    -- try_close_bracket()'s own "closed immediately, nothing typed yet" case already uses.
    local before = children[i - 1]
    local before_br = before and mexpru.u(before).bracket
    if before_br and before_br.is_open and before_br.peer
            and mexpru.scan_bracket(children, i - 1, 1) == i then
        table.insert(children, i, build_empty_atom(fontset, horiz_sz))
        -- That filler occupies index i, pushing everything from i rightward along - including the
        -- cursor's own landing slot, if it sat at or after it.
        if cursor_i >= i then
            cursor_i = cursor_i + 1
        end
    end

    if backspace then
        if #children == 0 then
            -- The horiz can't be left with zero children (mexpr_merge_h needs at least one) -
            -- falls back to a single fresh empty atom, same shape as a brand new formula (new()) -
            -- cursor_pos follows it there, ready to type again. Same size level the horiz already
            -- had - a subscript emptied out this way stays subscript-sized, not back to the base.
            local empty_atom = build_empty_atom(fontset, horiz_sz)
            children = {empty_atom}
            local rebuilt = mexpru.horiz(fontset, children, horiz_sz)
            container.root = mexpru.propagate_rebuild(fontset, horiz, rebuilt)
            container.cursor_pos = vc.wref_mexpr(empty_atom)
        else
            local rebuilt = mexpru.horiz(fontset, children, horiz_sz)
            container.root = mexpru.propagate_rebuild(fontset, horiz, rebuilt)
            -- Preceding sibling if there was one, else the horiz itself (what was deleted was
            -- first) - matches where backspacing through plain text would leave you. cursor_i, not
            -- `i`: see its own comment above on why a cascade's two indices differ.
            if cursor_i > 1 and children[cursor_i - 1] then
                container.cursor_pos = vc.wref_mexpr(children[cursor_i - 1])
            else
                container.cursor_pos = vc.wref_mexpr(rebuilt)
            end
        end
        if cut_hi then mexpru.cut(cut_hi) end
        if cut_mid then mexpru.cut(cut_mid) end
        mexpru.cut(cut_lo)
    else
        local rebuilt = mexpru.horiz(fontset, children, horiz_sz)
        container.root = mexpru.propagate_rebuild(fontset, horiz, rebuilt)
        -- cursor_pos still names `target` itself, untouched by this edit (fwd_delete never cuts
        -- target - see this function's own comment on why victim/peer can't land on it) - still
        -- valid without reassignment: mexpru.horiz()/mexpr_merge_h re-parents its EXISTING
        -- children rather than recreating them, so target's own identity survives the rebuild.
        if cut_hi then mexpru.cut(cut_hi) end
        if cut_mid then mexpru.cut(cut_mid) end
        mexpru.cut(cut_lo)
    end
    mark_edited(container)
end

--[[ Root-relative bounding box for any mexpr_t node (horiz, supsub, or atom), for hit_test()'s own
descent below - the mexpr_t tree is itself a natural space-partitioning structure (a parent's own
bb always contains every child's), which is exactly what that descent walks.

Deliberately RAW (vc.mexpr_get_bb(node) as-is, no to_baseline_frame()) - unlike cursor_target()
above, this never gets re-anchored into an outer screen pos anywhere. A real click arrives in a
DIFFERENT frame (relative to draw()'s own `pos`, before its +baseline_correction(sz) shift) -
mformula_new.hit_test() converts into this raw frame once, at the entry point, before any descent
starts (see its own comment), so everything below that point - this function included - can stay
in the plain "a's own middle at each node's own size" frame mexpru.u(_).pos itself is. Applying
to_baseline_frame()'s +baseline_correction(node's own sz) HERE (per-node, during descent) would be
wrong regardless - mexpr_draw_rec never reconciles per-node size differences, it just accumulates
raw anchor offsets self-consistently regardless of size, so that correction only ever belongs once,
at the outermost root, not per node.
@date 2026-09-08 09:00 ]]
local function node_bbox(fontset, node)
    local pos = mexpru.u(node).pos
    local bb = vc.mexpr_get_bb(node)
    return {left = pos.x + bb.tl.x, right = pos.x + bb.br.x, top = pos.y + bb.tl.y, bottom = pos.y + bb.br.y}
end

--[[ Exported for tests, which have to probe points in the SAME frame this measures in - a node's
own `pos` plus its local box. Re-deriving that in a test would be a second opinion about the frame,
and a wrong one is invisible: every probe simply misses. @date 2026-09-12 01:30 ]]
mformula_new.node_bbox = node_bbox

-- Plain containment test, in whatever frame both were measured in. @date 2026-09-08 09:30
local function point_in_bbox(pt, box)
    return pt.x >= box.left and pt.x <= box.right and pt.y >= box.top and pt.y <= box.bottom
end

--[[ The cursor position immediately BEFORE `node`, within its own parent - the previous sibling
(landing on ITS own "after itself" position), or the parent horiz itself (position 0) if `node` is
already first there. If `node`'s parent is a supsub, `node` IS that supsub's own base (the one atom
that isn't a horiz child - this file's own model comment) - "before" then means before the WHOLE
COMPOUND, same as move_left()'s own base_of() handling (exits the supsub entirely rather than
treating a bare base as if it had ordinary horiz siblings of its own), so this recurses using the
supsub itself in that case rather than reading mexpru.u(parent).children off a node that doesn't
have one.
@date 2026-09-08 09:00 ]]
local function target_before(node)
    local parent = node:get_parent()
    if is_supsub(parent) then
        return target_before(parent)
    end
    local children = mexpru.u(parent).children
    -- node:get_parent_idx() - safe, `children` is a fresh, unmutated read of node's own parent.
    local idx = node:get_parent_idx()
    if idx > 1 then
        return children[idx - 1]
    end
    return parent
end

--[[ Resolves `click` to a cursor position among `horiz`'s own children, for when none of their
individual bboxes contain it (a gap between them, or before-the-first/after-the-last) - the LAST
child whose own right edge is <= click.x becomes the target (its own natural "after itself" cursor
position), or `horiz` itself (position 0) if click is left of even the first child's own edge.
@date 2026-09-08 09:00 ]]
local function horiz_margin_target(fontset, horiz, click)
    local target = horiz
    for _, child in ipairs(mexpru.u(horiz).children) do
        if click.x >= node_bbox(fontset, child).right then
            target = child
        else
            break
        end
    end
    return target
end

--[[ hit_test()'s own tree descent - bbox containment at each level, deepest wins, viewing the
mexpr_t tree as a simple space-partitioning structure rather than walking move_left/move_right/
move_up/move_down to enumerate every reachable position. Terminal cases:
  - an EMPTY_BOX hit is immediate - it IS its own cursor position already.
  - a horiz with no child bbox containing the click resolves via horiz_margin_target() above.
  - a SYMBOL glyph hit splits by its own horizontal midpoint: left half -> target_before() (the
    blinker sits AFTER the cursor position, so the left half of a glyph's own ink means "before
    it"), right half -> the glyph itself.
  - a supsub with the click inside its own combined extent but outside base/sup/sub individually
    (real empty space - e.g. above/below base where sup/sub don't reach, or the vertical gap
    between sup and sub) splits by x against base's own right edge: left (over base's column) ->
    target_before() (before the WHOLE supsub, same as landing left of a base glyph would), right
    (over the sup/sub column) -> the supsub itself ("after the whole compound").
@date 2026-09-08 09:00 ]]
local function hit_test_node(fontset, node, click)
    if node.type == vc.MEXPR_TYPE_EMPTY_BOX then
        return node
    end

    if is_horiz(node) then
        for _, child in ipairs(mexpru.u(node).children) do
            if point_in_bbox(click, node_bbox(fontset, child)) then
                return hit_test_node(fontset, child, click)
            end
        end
        return horiz_margin_target(fontset, node, click)
    end

    if is_supsub(node) then
        local u = mexpru.u(node)
        local base_box = node_bbox(fontset, u.base)
        if point_in_bbox(click, base_box) then
            return hit_test_node(fontset, u.base, click)
        end
        if u.sup and point_in_bbox(click, node_bbox(fontset, u.sup)) then
            return hit_test_node(fontset, u.sup, click)
        end
        if u.sub and point_in_bbox(click, node_bbox(fontset, u.sub)) then
            return hit_test_node(fontset, u.sub, click)
        end
        -- Real empty space (inside the supsub's own combined extent, but outside base/sup/sub
        -- individually - e.g. above/below base where sup/sub don't reach, or the vertical gap
        -- between sup and sub) - a 3-way split by x, not just base's own right edge: left of
        -- base's own MIDPOINT means "before the whole supsub" (target_before()); from there up to
        -- the WHOLE COMPOUND's own midpoint - which reaches into the sup/sub column too, not just
        -- base's - reads as "closer to base" and lands there directly; past the compound's own
        -- midpoint is "after the whole compound" (the supsub itself).
        local base_mid = (base_box.left + base_box.right) / 2
        if click.x < base_mid then
            return target_before(node)
        end
        local combined_box = node_bbox(fontset, node)
        local combined_mid = (combined_box.left + combined_box.right) / 2
        if click.x < combined_mid then
            return u.base
        end
        return node
    end

    if is_vert(node) then
        -- Same descent a frac gets, over N slots instead of two: into whichever row was clicked,
        -- and otherwise onto the nearest one by vertical distance so a click in the gap between
        -- rows still lands somewhere sensible rather than on the stack itself.
        local slots = mexpru.u(node).slots
        local best, best_dist
        for _, slot in ipairs(slots) do
            local bb = node_bbox(fontset, slot)
            if point_in_bbox(click, bb) then
                return hit_test_node(fontset, slot, click)
            end
            local mid = (bb.top + bb.bottom) / 2
            local dist = math.abs(click.y - mid)
            if not best_dist or dist < best_dist then
                best, best_dist = slot, dist
            end
        end
        return best and hit_test_node(fontset, best, click) or node
    end

    --[[ A dress hands the click straight to what it holds - the wrapper rule (see unwrap()).
    Without this a dressed compound was a dead region: the click stopped at the dress, which is
    fine for a dressed glyph and useless for a dressed stack, whose rows could not be clicked into
    at all. The decoration's own ink is not a target and is simply fallen through. ]]
    if is_dress(node) then
        return hit_test_node(fontset, mexpru.u(node).target, click)
    end

    if is_frac(node) then
        local u = mexpru.u(node)
        if point_in_bbox(click, node_bbox(fontset, u.num)) then
            return hit_test_node(fontset, u.num, click)
        end
        if point_in_bbox(click, node_bbox(fontset, u.den)) then
            return hit_test_node(fontset, u.den, click)
        end
        -- Real empty space, inside the frac's own combined extent but outside num/den individually
        -- (near the divider line, or the small margin either side of it) - unlike a supsub, a frac
        -- has no base to give this a 3-way split: "num/den nearly fill the whole thing, basically no
        -- dead space of its own" (2026-09-04 design discussion) - so this splits exactly like an
        -- ordinary SYMBOL glyph does below, by the frac's OWN horizontal midpoint alone.
        local box = node_bbox(fontset, node)
        if click.x < (box.left + box.right) / 2 then
            return target_before(node)
        end
        return node
    end

    -- MEXPR_TYPE_SYMBOL.
    local box = node_bbox(fontset, node)
    if click.x < (box.left + box.right) / 2 then
        return target_before(node)
    end
    return node
end

--[[ Mutates container.cursor_pos directly to hit_test_node()'s descent from root - the same
convention every move_* uses, so editor.lua just calls it with no assignment.

`click` is {x,y} relative to the SAME `pos` draw() takes, NOT yet in node_bbox()'s raw root-relative
frame: draw() shifts pos by +baseline_correction() before handing it to mexpr_draw, and this undoes
that shift on the way in so the descent can compare against node_bbox() directly. Without it every
click's y landed outside the whole tree's bbox, so the x-only margin fallback fired regardless of
where you clicked vertically - the symptom was every click resolving to the same place.

wrap_width is RELATIVE, and is unwrap_point()'s reverse of vc.mexpr_draw's wrap: a click that
visually landed on a wrapped row has to be mapped back into formula space before the descent, which
only knows unwrapped positions. nil means "never wraps".
@date 2026-09-08 09:00 ]]
--[[ A click in the formula's own drawn frame, moved into the raw tree's frame.

The only thing the caret's hit test and a gesture's glyph test share: draw() shifts pos by
+baseline_correction() before handing it to mexpr_draw, so that shift is undone here, and a click
that landed on a WRAPPED row is mapped back into unwrapped formula space, which is the only space
node_bbox() knows. nil wrap_width means "never wraps".

What they do NOT share is what happens next - see glyph_at() versus hit_test_node().
@date 2026-09-12 01:10 ]]
local function raw_point(container, fontset, sz, click, wrap_width)
    local raw_click = {x = click.x, y = click.y - baseline_correction(fontset, sz)}
    if wrap_width then
        local raw_bb = vc.mexpr_get_bb(container.root)
        local skipy = raw_bb.br.y - raw_bb.tl.y
        raw_click.x, raw_click.y = unwrap_point(raw_click.x, raw_click.y, wrap_width, skipy, raw_bb.tl.y)
    end
    return raw_click
end

--[[ The LEAF GLYPH whose own box contains this point, or nil. Nothing is snapped to.

NOT hit_test_node's question, and that is the whole point of it existing. A caret click must always
land somewhere, so that descent falls back at every level - a gap between glyphs resolves to the
nearest edge, a point past the last glyph resolves to "after it", a click in the empty space beside
a fraction bar resolves to the fraction. Every one of those fallbacks is right for a caret and wrong
for a gesture: a right-click three lines above the formula would answer for a glyph the user cannot
see themselves pointing at. Author, 2026-09-11: "we want the exact matching glyph's box and check it
against the mouse and if no box intersects (none of the leaf ones), then simply ignore it: right
click only works on things that you can roughly see".

So: containment only, all the way down, and nil the moment nothing contains the point. Compound
nodes are pure structure here - a horiz, a supsub, a stack and a fraction are asked about their
children and never answer for themselves, which is what makes the fraction bar, the gap between a
sup and a sub, and the space between two glyphs all read as "nothing there".

A DRESS IS THE EXCEPTION, and only for its own ink: the arrow of a `\vec{F}` is drawn by the dress
but belongs to the F under it, so a point on the decoration answers with the dress itself. The tag
lookup already unwraps that (ast_gestures.node_at goes through slot_atom), and the alternative -
nil - would make the visible half of an accented glyph dead.
@date 2026-09-12 01:10 ]]
local function glyph_at(fontset, node, click)
    if not point_in_bbox(click, node_bbox(fontset, node)) then
        return nil
    end

    if is_horiz(node) then
        for _, child in ipairs(mexpru.u(node).children) do
            local hit = glyph_at(fontset, child, click)
            if hit then
                return hit
            end
        end
        return nil
    end

    if is_supsub(node) then
        local u = mexpru.u(node)
        return glyph_at(fontset, u.base, click)
                or (u.sup and glyph_at(fontset, u.sup, click))
                or (u.sub and glyph_at(fontset, u.sub, click))
                or nil
    end

    if is_vert(node) then
        for _, slot in ipairs(mexpru.u(node).slots) do
            local hit = glyph_at(fontset, slot, click)
            if hit then
                return hit
            end
        end
        return nil
    end

    if is_dress(node) then
        return glyph_at(fontset, mexpru.u(node).target, click) or node
    end

    if is_frac(node) then
        local u = mexpru.u(node)
        return glyph_at(fontset, u.num, click) or glyph_at(fontset, u.den, click) or nil
    end

    -- SYMBOL or EMPTY_BOX, and its own box holds the point - tested at the top.
    return node
end

--[[ Exported for tests, in the RAW frame: the conversion above needs a drawn container, and what is
worth asserting is the descent - that it finds the glyph it is over, and nothing when it is over
none. @date 2026-09-12 01:10 ]]
mformula_new.glyph_at = glyph_at

--[[ WHICH GLYPH IS UNDER THIS POINT, or nil. Reads; changes nothing.

The gesture's question. Never moves the caret, and never answers for a glyph the point is not
actually on - see glyph_at above for why that differs from where a click would put the cursor.
@date 2026-09-12 01:10 ]]
function mformula_new.node_at(container, fontset, sz, click, wrap_width)
    mexpru.check_container(container)
    return glyph_at(fontset, container.root,
            raw_point(container, fontset, sz, click, wrap_width))
end

--[[ Places the caret from a click, or extends a selection from a drag.

Core: SNAPS TO THE NEAREST POSITION and therefore always lands - a click in the margin still puts
the caret somewhere sensible. That is the opposite of node_at below, which answers only for a glyph
the point is really on, and the reason both exist.

Core: `extend` is a drag in progress. The anchor is kept and only the far end moves, CLAMPED TO THE
ANCHOR'S OWN HORIZ - dragging up into a superscript would leave the row the selection started in,
which selection is defined not to allow, so such a hit is ignored and the selection stays put rather
than jumping slots. Without `extend`, any existing selection is dropped, which is what a fresh click
should do.

Params: `click` is already RELATIVE to the formula's own origin and `wrap_width` is a width, not an
edge; editor.lua does that conversion. Mutates the container's cursor and returns nothing.
@date 2026-09-12 04:15 ]]
function mformula_new.hit_test(container, fontset, sz, click, wrap_width, extend)
    mexpru.check_container(container)
    local hit = hit_test_node(fontset, container.root, raw_point(container, fontset, sz, click,
            wrap_width))

    --[[ `extend` is a drag in progress (editor.lua holds the button state): keep the anchor and move
    only the far end, so sweeping the mouse grows a selection. Clamped to the anchor's OWN horiz -
    dragging up into a superscript or down into a denominator lands outside the row the selection
    started in, which this feature is defined not to allow, so such a hit is simply ignored and the
    selection stays where it was rather than silently jumping slots.
    Without `extend` (a fresh click) any selection is dropped, which is what clicking should do. ]]
    if extend then
        local anchor = container.sel_anchor and container.sel_anchor:get_obj()
        if not anchor then
            container.sel_anchor = vc.wref_mexpr(container.cursor_pos:get_obj())
            anchor = container.sel_anchor:get_obj()
        end
        local a_horiz = select(1, slot_of(anchor))
        local h_horiz = select(1, slot_of(hit))
        if not a_horiz or not h_horiz or not mexpru.same(a_horiz, h_horiz) then
            return
        end
    else
        container.sel_anchor = nil
    end
    container.cursor_pos = vc.wref_mexpr(hit)
end

--[[ The debug overlay's {nodes, edges}: every position the four movers can actually reach.

BFS from the CURRENT cursor_pos, trying all four movers at each position found. Nodes are keyed by
tostring() identity rather than by the node, because a table key has to be stable across the fresh
handles every walk produces - a keying question, not the comparison question mexpr_t's __eq
settled. Positions come from cursor_rect() (called with pos={0,0}, so everything stays
root-relative), which already knows how to place a node's cursor band including nested sup/sub.

Edges only for RECIPROCAL moves - a->b one way AND b->a the exact opposite. A few one-directional
jumps exist by design, and drawing them as bidirectional lines would misdescribe the model.

Destructively drives container.cursor_pos through the traversal, saving and restoring it, and
caches on container._graph_cache keyed by version/sz/wrap_width: a full BFS is up to four real
cursor moves per reachable position, too much to redo every frame the overlay is up.

`wrap_width` is RELATIVE - the usable column width, not the absolute screen edge draw() takes -
because this works in the root-relative frame, where the wrap edge sits at x = wrap_width. Passing
the absolute edge made cursor_rect() see a column as wide as the whole screen, so graph nodes never
wrapped while the glyphs they describe did. nil means "never wraps", as everywhere else.
@date 2026-09-08 09:00 ]]
function mformula_new.reachable_graph(container, fontset, sz, wrap_width)
    mexpru.check_container(container)
    local cache = container._graph_cache
    if cache and cache.version == (container.version or 0) and cache.sz == sz
            and cache.wrap_width == wrap_width then
        return cache.graph
    end

    local saved_cursor = container.cursor_pos

    local nodes, index_of = {}, {}
    local function get_or_add(node)
        local key = tostring(node)
        local idx = index_of[key]
        if idx then
            return idx, false
        end
        container.cursor_pos = vc.wref_mexpr(node)
        -- pos={0,0}, so the edge cursor_rect() wants (absolute, in the same frame as pos) IS
        -- wrap_width here - see this function's own comment on the two frames.
        local rect = mformula_new.cursor_rect(container, {x = 0, y = 0}, fontset, wrap_width)
        -- `row` travels with the node so a caller can tell a real wrap crossing from an ordinary
        -- sup/sub height difference - see cursor_rect()/wrap_point() on why y can't say.
        nodes[#nodes + 1] = {x = rect.x, y = (rect.top + rect.bottom) / 2, row = rect.row or 0}
        idx = #nodes
        index_of[key] = idx
        return idx, true
    end

    local movers = {
        {name = "left", fn = mformula_new.move_left},
        {name = "right", fn = mformula_new.move_right},
        {name = "up", fn = mformula_new.move_up},
        {name = "down", fn = mformula_new.move_down},
    }
    local opposite_name = {left = "right", right = "left", up = "down", down = "up"}

    -- trans[idx][name] = the node index that mover reaches from idx - filled in as the BFS visits
    -- every reachable node exactly once (trying all 4 movers each time), then used afterward to
    -- test reciprocity without a second traversal.
    local trans = {}
    local start_node = saved_cursor:get_obj()
    local start_idx = get_or_add(start_node)
    local queue, qi = {{node = start_node, idx = start_idx}}, 1
    while qi <= #queue do
        local cur = queue[qi]
        qi = qi + 1
        trans[cur.idx] = trans[cur.idx] or {}
        for _, m in ipairs(movers) do
            container.cursor_pos = vc.wref_mexpr(cur.node)
            m.fn(container)
            local new_node = container.cursor_pos:get_obj()
            if not mexpru.same(new_node, cur.node) then
                local idx, is_new = get_or_add(new_node)
                trans[cur.idx][m.name] = idx
                if is_new then
                    queue[#queue + 1] = {node = new_node, idx = idx}
                end
            end
        end
    end

    local edges, seen = {}, {}
    for a, by_name in pairs(trans) do
        for name, b in pairs(by_name) do
            if trans[b] and trans[b][opposite_name[name]] == a then
                local lo, hi = math.min(a, b), math.max(a, b)
                local key = lo .. ">" .. hi
                if not seen[key] then
                    seen[key] = true
                    edges[#edges + 1] = {a = lo, b = hi}
                end
            end
        end
    end

    container.cursor_pos = saved_cursor
    local graph = {nodes = nodes, edges = edges}
    container._graph_cache = {version = container.version or 0, sz = sz, wrap_width = wrap_width, graph = graph}
    return graph
end

--[[ The box of whatever sits under the cursor, for editor.lua to paint a soft highlight behind.

Returns {x, y, w, h, color} relative to the same `pos` draw() is given, or nil when there is nothing
to highlight. Geometry only - the caller draws it, and the caller alone decides WHEN, because
"underneath everything" is a draw-ORDER property this function cannot enforce. editor.lua issues it
before the reachable graph, giving highlight -> graph -> contours -> glyphs -> blinker.

Skips a horiz: resting on one means "before everything in it", a position rather than a thing, and
painting the whole row would not read as highlighting a character. Everything else cursor_pos can
name gets a box - a glyph, the empty placeholder, or a whole supsub when the cursor rests after it.

The y already has baseline_correction() folded in, since draw() applies it internally and a caller
working from the raw `pos` would be off by it. Wrapping uses the same transform the vert contour
does - wrap_point() on the top-left, then that delta applied to the whole box, so a highlighted
glyph that wrapped moves as one rectangle rather than being torn across two rows. ]]
local CURSOR_HL_R, CURSOR_HL_G, CURSOR_HL_B = 0x66, 0xFF, 0xFF -- #66ffff, a cyan
--[[ STATIC, at what the pulse used to rest on. It breathed on a sine when first built; asked to
stop, "stop at the idle of the animation", so this is the MIDPOINT of that old
oscillation (0x16..0x4E) - the value it spent most of its time near and the one the eye had already
settled on, rather than either extreme.

Spread across CURSOR_HL_FEATHER + 1 nested rectangles instead of painted as one, which is what makes
the edge soft: ImGui has no blur, but N translucent rounded rects, each a pixel wider and fainter than
the one inside it, composite into a gradient falloff. The per-layer alpha is chosen so the layers
build back up to the same centre opacity a single 0x32 rectangle would have had:
1 - (1 - a)^N = 0x32/255, which for N = 4 (feather 3) gives a = 0x0E. So the middle looks exactly as
it did and only the boundary changes - re-derive this alpha if the feather ever changes.
@date 2026-09-08 09:00 ]]
local CURSOR_HL_LAYER_ALPHA = 0x0E
local CURSOR_HL_FEATHER = 3   -- px the outermost layer extends past the glyph box

--[[ Returns a LIST of rectangles, outermost/faintest first, all sharing the geometry below - the
caller draws them in order and the overlap does the feathering. Empty list when there is nothing to
highlight.
@date 2026-09-08 09:00 ]]
function mformula_new.cursor_box(container, fontset, sz, wrap_width)
    mexpru.check_container(container)
    local node = container.cursor_pos and container.cursor_pos:get_obj()
    if not node or is_horiz(node) then
        return {}
    end
    -- Same geometry the selection highlight uses - node_box() owns the wrap/baseline handling.
    local box = node_box(node, fontset, sz, wrap_width, container.root)
    if not box then
        return {} -- no position yet, or a zero-extent node (an inkless glyph)
    end

    -- ImGui packs ABGR (0xAABBGGRR) - blue is the HIGH byte pair. Written the RGBA way round this
    -- comes out orange, which is exactly what happened to SELECTION_COLOR once already.
    local color = (CURSOR_HL_LAYER_ALPHA << 24) | (CURSOR_HL_B << 16)
            | (CURSOR_HL_G << 8) | CURSOR_HL_R

    local bx, by, bw, bh = box.x, box.y, box.w, box.h

    local layers = {}
    for i = CURSOR_HL_FEATHER, 0, -1 do -- outermost (widest, drawn first) to innermost
        layers[#layers + 1] = {
            x = bx - i, y = by - i, w = bw + 2 * i, h = bh + 2 * i,
            color = color,
            -- Rounding grows with the inset so the outer layers are rounder than the inner ones,
            -- which softens the corners as well as the sides - a stack of equally-square rects
            -- feathers the edges but leaves four hard corners.
            rounding = i + 1,
        }
    end
    return layers
end

--[[ Every place a click can put the caret that has no ink of its own: {x, y, w, h} rects in the
same root-relative frame cursor_target() answers in, for the caller to outline and hit-test after
adding its own draw origin.

Without them those positions are reachable by arrow key and unreachable by mouse, which reads as the
formula refusing the click.

ONLY the "start" cases get one - a horiz, or an EMPTY atom - because neither paints anything of its
own. A SYMBOL atom already has ink to see and click, and a marker there would draw an empty-slot
outline beside real content, reading as "there is still an empty box here" when the tree has moved
on.

`sz` is no longer used: a marker takes its size from the NAMED node's own level, for the reason
cursor_target() gives. It is kept for parity with the other per-frame signatures.
@date 2026-09-08 09:30 ]]
function mformula_new.slot_markers(container, fontset, sz)
    mexpru.check_container(container)
    local node = live_cursor(container)
    if node.type ~= vc.MEXPR_TYPE_EMPTY_BOX and mexpru.u(node).kind ~= "horiz" then
        return {}
    end
    local t = cursor_target(fontset, node)
    -- LOGICAL -> PHYSICAL before touching real font metrics (mexpru.rescale()'s own comment).
    local min = min_extent(fontset, mexpru.physical_sz(mexpru.u(node).sz))
    return {{x = t.x, y = t.top, w = min.width, h = t.bottom - t.top}}
end

--[[ Is everything between `lo` and `hi` in `children` exactly ONE empty placeholder?

Asked when a bracket pair is cascaded away. The rule the cascade otherwise follows is that the
CONTENT between a pair survives, unwrapped - which is right for `(a)` becoming `a`, and wrong for
`()`, because the placeholder inside an empty pair only ever existed to give the pair something to
hold. Removing the brackets and keeping it leaves a stray empty box sitting in the row.

Reported live 2026-09-07: "I do (,),delete results in an additional empty left around". Typing `a`,
then `(`, then `)`, then Backspace left `a` followed by an empty atom instead of just `a` - visible
as a gap, and enough to make a definition's name stop parsing.

Exported so the rule itself can be tested: the branch that uses it lives inside handle_input(),
which needs a live ImGui frame and so cannot be driven headlessly.
@date 2026-09-08 09:00 ]]
function mformula_new.span_is_lone_placeholder(children, lo, hi)
    if hi - lo ~= 2 then
        return false
    end
    local mid = children[lo + 1]
    return mid ~= nil and mid.type == vc.MEXPR_TYPE_EMPTY_BOX
end

--[[ Where each of `nodes` sits, as {x, y, w, h} in the SAME frame draw() is handed as its origin -
so a caller adds its own draw x/baseline and has a screen rect. Nodes not in this container (or not
positioned yet) are skipped rather than returned as garbage.

Added for the definition box's per-character parse feedback: it needs to paint behind individual
atoms it did or did not manage to read, which nothing else here had a reason to ask for. Deliberately
takes a LIST rather than one node - a Lua table cannot be keyed by an mexpr_p (identity has to go
through mexpru.same()), so callers carry lists of nodes, not sets.
@date 2026-09-08 09:00 ]]
function mformula_new.node_rects(fontset, nodes)
    local out = {}
    for _, node in ipairs(nodes or {}) do
        local u = node and mexpru.u(node)
        if u and u.pos then
            --[[ Mirrors cursor_target() rather than node_bbox(), and the difference matters:
            node_bbox() works in the RAW tree frame, but mexpr_symbol re-centres every glyph on the
            middle of 'a', so a raw bb's y is not baseline-relative and a highlight built from it
            floats above the text. to_baseline_frame() is the correction, and it has to be applied
            at the NODE'S OWN size - an atom inside a subscript is smaller than the row around it.

            Horizontally the ink box; vertically the LINE box (baseline_shift .. line_height), the
            same band the caret occupies - so a run of marked characters paints as one continuous
            strip instead of a ragged outline tracking each glyph's ascenders. ]]
            local sz = mexpru.physical_sz(u.sz or (u.base and mexpru.u(u.base).sz))
            local pos = u.pos
            local bb = to_baseline_frame(fontset, sz, vc.mexpr_get_bb(node))
            local cm = cursor_metrics(fontset, sz)
            out[#out + 1] = {
                x = pos.x + bb.tl.x,
                y = pos.y + cm.baseline_shift,
                w = bb.br.x - bb.tl.x,
                h = cm.line_height,
            }
        else
            out[#out + 1] = false
        end
    end
    return out
end

-- LaTeX serialization lives in its own file (mformula_latex.lua) - re-exported here so the editors
-- (which only ever know this module as `mformula`) need not require anything extra. All three use
-- it: the text editor for its $$...$$ embeds, the formula and definition boxes for their whole
-- content.
local mformula_latex = require("mformula_latex")
mformula_new.to_latex = mformula_latex.to_latex
mformula_new.from_latex = mformula_latex.from_latex
mformula_new.nodes_to_latex = mformula_latex.nodes_to_latex

--[[ Profiler instrumentation (prof.lua / perf_composer.h) - same bottom-of-file placement and same
reasoning as mexpru.lua's own block: one place to lift out, no call site needs to know.

These are the per-frame phases. The editors call draw()/measure()/cursor_rect() once per
formula per frame and reachable_graph()/slot_markers() when their overlays are on, so this is where
"cost per frame scales with how much is on screen" would show up. handle_input()/rescale()/clone()
are per-EVENT rather than per-frame, and separating those two groups in the report is most of the
diagnosis: a spike that lands in the first group is a drawing cost, one that lands in the second is
an edit doing too much work.
@date 2026-09-08 09:00 ]]
mformula_new.draw            = prof.wrap("lua.mformula.draw", mformula_new.draw)
mformula_new.measure         = prof.wrap("lua.mformula.measure", mformula_new.measure)
mformula_new.cursor_rect     = prof.wrap("lua.mformula.cursor_rect", mformula_new.cursor_rect)
mformula_new.hit_test        = prof.wrap("lua.mformula.hit_test", mformula_new.hit_test)
mformula_new.reachable_graph = prof.wrap("lua.mformula.reachable_graph", mformula_new.reachable_graph)
mformula_new.slot_markers    = prof.wrap("lua.mformula.slot_markers", mformula_new.slot_markers)
mformula_new.handle_input    = prof.wrap("lua.mformula.handle_input", mformula_new.handle_input)
mformula_new.rescale         = prof.wrap("lua.mformula.rescale", mformula_new.rescale)
mformula_new.clone           = prof.wrap("lua.mformula.clone", mformula_new.clone)
mformula_new.to_latex        = prof.wrap("lua.mformula.to_latex", mformula_new.to_latex)
mformula_new.from_latex      = prof.wrap("lua.mformula.from_latex", mformula_new.from_latex)

return mformula_new

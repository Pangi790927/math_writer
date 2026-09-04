--[[
mformula_new.lua - rebuild of mformula.lua's structured expression editor, this time holding
mexpr_t itself (via mexpru.lua) as the live edited tree instead of a separate row/item Lua model
that build_row() re-derives into mexpr on every change. Built up incrementally, function by
function - not yet wired into editor.lua in place of mformula.lua.

Model: a container = {root=<mexpr_p>, cursor_pos=<wref_t<mexpr_t>>}.

root: the mexpr_t currently held - always a "horiz" (mexpru.horiz() - a plain left-to-right
mexpr_merge_h sequence), never a bare atom. EMPTY_BOX and SYMBOL ("atoms") are the only leaf kinds
this file builds, and an atom is never root directly - it's always sitting inside some horiz's own
children list, at least one horiz always exists at root even when there's exactly one atom in it
(see new()). A horiz can't be mutated in place (mexpr_merge_h recomputes every child's x-offset
from scratch, so changing one child potentially reflows everyone after it) - an edit rebuilds the
affected horiz via mexpru.horiz(), then mexpru.propagate_rebuild() splices that new horiz into ITS
OWN parent's children list and rebuilds that too, all the way up to the root - see handle_input().

A supsub node (mexpru.supsub() - make_supsub()) is the other composite kind: mexpr_supsub's own
base/sup/sub, each EITHER a single atom (base - see make_supsub()'s own comment for why it's never
horiz-wrapped, only ever exactly one atom) OR a horiz (sup/sub - can hold a real sequence, same as
any other horiz). A supsub node itself always sits as one element of SOME horiz's children list
(never bare, same rule as an atom) - from that horiz's own perspective a supsub is just another
slot, indistinguishable from an atom for cursor/rebuild purposes except by u(_).kind.

cursor_pos: a WEAK reference (wref_t, math_expr_composer.h) to whichever mexpr_t node the cursor is
anchored to. Weak specifically so the cursor can never be the thing keeping a node alive - it only
ever rides along with whatever the tree itself already holds via parent/anchor_*/u(horiz).children.
What "anchored to node X" MEANS, and what each key does, depends on which kind of node X is - see
cursor_target() and handle_input():
  - X is a horiz (anchor's own subobjs holding a sequence of atom/supsub siblings): cursor sits at
    X's own position 0, before its first child. Delete does nothing (no atom to remove AT this
    position - it names a gap, not a slot). Writing a glyph inserts it at the START of X's own
    children list.
  - X is an EMPTY atom: cursor sits AT this atom (it renders as the cursor itself - see
    cursor_target()). Delete does nothing (nothing typed here yet to remove). Writing a glyph
    REPLACES X, in place, within its parent horiz's children list (or, if X is a supsub's own base,
    within that supsub - propagate_rebuild()'s kind dispatch handles both the same way).
  - X is a SYMBOL atom sitting in a horiz (a glyph already typed, NOT a supsub's base - that's its
    own case below): cursor sits immediately after it. Backspace removes X itself from its parent
    horiz's children list. Delete removes whichever atom comes right AFTER X in that same list (a
    no-op if X is last). Writing a glyph inserts a new one immediately after X in that list.
  - X is a supsub's own NON-empty base: writing a glyph REPLACES base with it, bumping the glyph
    that used to be there out into the horiz holding the whole supsub (right before the supsub's
    own slot). Backspace is the reverse: removes base's own glyph and pulls whatever sits right
    BEFORE the supsub back in to become the new base (or falls back to a fresh empty atom if there
    was nothing there). Delete (forward) has no defined behavior yet - a no-op. Ctrl+Shift+-/+ on
    a base is also a no-op (logged) - nesting a supsub directly onto a base isn't a real thing to
    want. See handle_input()'s own comment for the exact mechanics of each.
Whichever of these ends up changing the tree moves cursor_pos to name the newly-relevant atom.
]]

local vc = require("virt_composer")
local char = require("char")
local mexpru = require("mexpru")

local mformula_new = {}

local CURSOR_COLOR = 0xff00ffff
-- Cursor color while container.pending_bracket is set - "you're in bracket-closing mode, waiting
-- for the matching )/]/}". A visibly different hue (purple, vs. CURSOR_COLOR's yellow) rather than
-- a blink-rate/shape change, so it reads at a glance without having to watch it blink first.
local PENDING_BRACKET_CURSOR_COLOR = 0xffff00cc

-- How much smaller (in font-size-table steps) a sup/sub's own content renders, relative to its
-- base - same trick, same constants as mformula.lua's own SUB_SIZE_DELTA/MAX_SIZE_INDEX: char.lua's
-- size table is sorted BIGGEST to smallest, so this must ADD to sz, not scale it (sz is a discrete
-- 1..18 index, not a pixel size) - +1 is the next size down (e.g. 36pt -> 24pt, a ~67% ratio).
-- MAX_SIZE_INDEX defers to mexpru's own canonical copy (2026-09-04's Ctrl+MouseWheel zoom levels -
-- see mexpru.lua's own comment) instead of keeping a separate duplicate that char.lua's own table
-- edits would need to track by hand.
local SUB_SIZE_DELTA = 1
local MAX_SIZE_INDEX = mexpru.MAX_SIZE_INDEX

--[[ mexpr_symbol(is_char=true)/mexpr_draw (math_expr_composer.h) re-center every glyph on the
vertical middle of 'a' at its own size - a convention mexpr's own composition relies on - but NOT
the same baseline plain text (and this file's own cursor_target(), which reads node bb) sits on.
This is the one-time-per-size correction added to a true baseline y before handing it to
mexpr_draw, so mexpr-drawn content lands exactly where plain text/the cursor at the same pos would
- same trick, same reasoning as mformula.lua's own baseline_correction(). ]]
local baseline_correction_cache = {}
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
cursor is sized/positioned from (mformula.lua's own get_metrics() used this exact trick). An empty
atom's own tl.y..br.y is built to match this exactly (see build_empty_atom() below) - not 'a's own
ink extent - so it IS a real text cursor's size/position, not just something proportional to it. ]]
local function cursor_metrics(fs, sz)
    local G, g = char.find_by_ascii("G"), char.find_by_ascii("g")
    local G_sz = fs:char_get_sz({size = sz, code = G.ncod})
    local g_sz = fs:char_get_sz({size = sz, code = g.ncod})
    return {line_height = g_sz.bl.y - G_sz.tr.y, baseline_shift = G_sz.tr.y}
end

--[[ mexpr_symbol (math_expr_composer.h) builds every SYMBOL's own tl/br shifted (symb_off) to land
centered on 'a's own middle once actually DRAWN (mexpr_draw_rec's pos+m->tl math) - not directly
comparable to cursor_metrics()' true-baseline-relative numbers without first undoing that shift,
same as baseline_correction() above already does for mexpr_draw itself (draw_pos = pos+correction).
content_extent()/cursor_target() below do their OWN bb math instead of going through mexpr_draw, so
they have to apply the same correction themselves - this converts a raw vc.mexpr_get_bb() reading
into the SAME frame cursor_metrics() already is (true-baseline, relative to whatever `pos`
draw()/cursor_rect() were given). Only y shifts - symb_off's x component is always 0. ]]
local function to_baseline_frame(fontset, sz, bb)
    local bc = baseline_correction(fontset, sz)
    return {tl = {x = bb.tl.x, y = bb.tl.y + bc}, br = {x = bb.br.x, y = bb.br.y + bc}}
end

--[[ The extent a freshly-created, still-empty atom has at font size sz: H-wide (a real typing
slot, not a cursor-thin sliver), real-cursor-height (cursor_metrics() above - the same
[baseline_shift, baseline_shift+line_height] band a plain-text caret spans). This is both what
build_empty_atom() below builds an atom FROM, and the floor content_extent() clamps against - per
the rule that a formula's rendered size never shrinks below "empty atom" size, however small what's
actually typed turns out to be (e.g. a lone "."). ]]
local function min_extent(fs, sz)
    local cm = cursor_metrics(fs, sz)
    local H = char.find_by_ascii("H")
    local width = fs:char_get_sz({size = sz, code = H.ncod}).adv
    return {width = width, top = cm.baseline_shift, bottom = cm.baseline_shift + cm.line_height}
end

--[[ Builds one fresh empty atom (mexpr_empty) at font size sz, sized from min_extent() above.
mexpr_empty(fs, x, y, above_bl) puts tl at (0, -above_bl) and br at (x, y-above_bl);
content_extent()/cursor_target() read EVERY node's bb through to_baseline_frame() (+bc), so the raw
tl/br built here have bc baked OUT in advance (above_bl = bc-ext.top, not just -ext.top) - once
read back through that same +bc conversion, this atom's own top/bottom come out to EXACTLY
ext.top/ext.bottom, canceling out - see to_baseline_frame()'s own comment for why that conversion
exists at all (mexpr_symbol needs it for real; an empty atom doesn't, this just keeps both node
kinds flowing through the same one code path rather than special-casing which one needs it). Used
both by new() (the very first atom) and handle_input() (an emptied-out horiz falls back to one -
see its own comment). Tags u(ret).sz = sz - every atom remembers its own size level the same way
every horiz does (mexpru.horiz()'s own u(ret).sz), since cursor_pos frequently ends up naming an
atom directly and cursor_target() needs to know what level to render the caret at. ]]
local function build_empty_atom(fontset, sz)
    -- sz is LOGICAL (u(_).sz's own meaning, untouched by zoom - mexpru.rescale()'s own comment);
    -- the actual geometry below has to be built at the CURRENT PHYSICAL size (mexpru.physical_sz()
    -- - content.lua's Ctrl+MouseWheel zoom, 2026-09-04), while u(ret).sz keeps recording sz itself
    -- (logical), same as every other atom this file builds.
    local phys = mexpru.physical_sz(sz)
    local ext = min_extent(fontset, phys)
    local bc = baseline_correction(fontset, phys)
    local ret = mexpru.mexpr_empty(fontset, ext.width, ext.bottom - ext.top, bc - ext.top)
    mexpru.u(ret).sz = sz
    return ret
end

--[[ A brand new, empty container. root is a horiz (mexpru.horiz() - see this file's own model
comment for why root is NEVER a bare atom) wrapping a single fresh empty atom - cursor_pos points
at that atom ITSELF, not at the horiz: the horiz-cursor case inserts a NEW glyph alongside whatever
is already there, while the atom-cursor case replaces that one atom in place - only the second
gives the right result (one glyph, not the empty atom plus a stray glyph next to it) the first time
something is typed into a fresh formula. update_positions() seeds the position cache (mexpru.lua)
for this brand new tree - every later edit refreshes it again itself (propagate_rebuild()), so this
is the only place it has to be primed from nothing. ]]
function mformula_new.new(fontset, sz)
    local empty_atom = build_empty_atom(fontset, sz)
    local root = mexpru.horiz(fontset, {empty_atom}, sz)
    mexpru.update_positions(root)
    return {
        root = root,
        cursor_pos = vc.wref_mexpr(empty_atom),
        version = 0,
    }
end

--[[ Parks cursor_pos at container's own START/END - editor.lua's entry point for Ctrl+Right/
Ctrl+Left landing on an ADJACENT formula from outside it (arriving from its left/right side
respectively), mirroring move_right()/move_left()'s own "position 0 of root" and "resting on root's
own last child" resting spots (this file's own model comment) - NOT wrapped/entered any further,
same as those functions never dive into a compound uninvited either. `_start` is simply root itself
(root's own position 0, always a valid resting spot). `_end` mirrors mformula_latex.from_latex()'s
own default cursor placement: root's own last child directly, whatever kind it is - a supsub or frac
there already reads as "after the whole compound" on its own, no further dive needed. ]]
function mformula_new.cursor_to_start(container)
    container.cursor_pos = vc.wref_mexpr(container.root)
end

function mformula_new.cursor_to_end(container)
    local children = mexpru.u(container.root).children
    container.cursor_pos = vc.wref_mexpr(children[#children])
end

--[[ container.root's own bounding box (through to_baseline_frame() - see its own comment), clamped
to never read smaller than min_extent() - shared by measure() and draw() so the two can't disagree
about how big the formula actually is (draw()'s return value is what editor.lua actually draws the
box border from - see its own comment - so this clamp has to reach both, not just measure()'s
line-growing pass). root is a horiz, so its own bb is already relative to root's own origin
directly - no position-cache lookup needed here the way cursor_target() below needs one (root has
no parent to be offset from). ]]
--[[ wrap_width (2026-09-05, vc.mexpr_draw's own edge_x - see this file's own draw() comment) is
how much horizontal room this formula actually has before it wraps, relative to wherever IT
starts (NOT an absolute x - a formula sitting partway through a line, after other content, gets
LESS than the box's own full width, same as plain glyphs' own width_limit check already gives it).
nil means "never wraps" (vc.mexpr_draw's own math.huge convention upstream).

When content actually needs more than that, width is capped at wrap_width (it can't actually be
any wider on screen - it wraps back instead) and bottom grows by exactly one more RAW root height
(skipy - vc.mexpr_draw's own field) per extra row - computed the SAME analytical way vc.mexpr_draw
itself does (see its own comment: root's total width vs. the usable column, not a counter threaded
through the recursion), so measure() (called every frame, pass 1, before any real draw) and draw()
(pass 2) always agree on the box's own required height - no frame lag needed for THIS, unlike
draw()'s own returned total height (used instead for cursor_rect()/hit_test()'s wrap transforms,
which need to know exactly which row real content landed on, not just how many rows exist). ]]
local function content_extent(container, fontset, sz, wrap_width)
    local raw_bb = vc.mexpr_get_bb(container.root)
    local bb = to_baseline_frame(fontset, sz, raw_bb)
    local min = min_extent(fontset, sz)
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

    return {width = width, top = top, bottom = bottom}
end

--[[ Where the cursor sits, in ROOT-relative terms (this file's own model comment explains WHICH
spot, per node kind) - unlike content_extent() above, `node` here can be any descendant of root (an
atom or horiz nested arbitrarily deep, e.g. inside a supsub's sup/sub), so its own local bb alone
isn't enough: mexpru.u(node).pos (mexpru.lua's position cache, refreshed by every edit - see
propagate_rebuild()) gives its position relative to root, added on top of its own (baseline-frame-
converted) local bb to get a true root-relative rect.

sz comes from the NODE itself (mexpru.u(node).sz - every horiz/atom remembers its own size level,
see mexpru.horiz()/build_empty_atom()), NOT a size passed in from outside - a cursor sitting inside
a smaller-rendered sup/sub has to render at THAT size, not the outer formula's own.

x is the one thing that actually differs by node kind - a horiz or an EMPTY atom (nothing to place
the cursor after) uses its own left edge; a SYMBOL atom (real content) uses its own right edge, the
same "where does the next thing go" convention mformula.lua's build_row() used. top/bottom are
ALWAYS real cursor metrics (cursor_metrics(), not the node's own ink extent) regardless of which -
a horiz containing a much taller glyph, or a "." with almost no ink of its own, would otherwise
give a cursor that's the wrong height for either reason. ]]
--[[ KNOWN GAP (2026-09-04, not fixed here - see cursor_rect() below for why): top/bottom are
cm.baseline_shift/line_height, TRUE-baseline-relative numbers read straight off G/g's own
char_get_sz() - NOT converted into the "a's own middle at node's own size" frame every OTHER
root-relative reading in this file (mexpru.u(_).pos, and any raw vc.mexpr_get_bb()) is already in.
That conversion is exactly baseline_correction(fontset, sz) (see its own comment) - omitting it
here happens to be invisible whenever the cursor's own node sz equals whatever size the caller
will eventually re-anchor these numbers at (every plain in-line atom, which is why this was never
visible before), but is a real, uncorrected error for a nested (sup/sub, different-sz) node -
cursor_rect() below is the one caller that needs the numbers actually right (the live blinker), so
it applies the missing correction itself rather than changing what this function returns - the
OTHER caller, slot_markers() (via editor.lua's own content_x/y-based marker drawing), has this
exact same gap for a marker on nested content and does NOT get it fixed here - flagged, not
addressed, since fixing it means also touching editor.lua's own marker draw call. ]]
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

--[[ Forward wrap transform (vc.mexpr_draw's own wrap loop, math_expr_composer.h's draw_info_t) -
maps a point in the tree's own UNWRAPPED "formula space" (the same raw, root-relative frame
node_bbox()/cursor_target() already work in) to where it actually lands on screen once wrapping
drops it onto whichever row it really falls on. Mirrors the C++ `while` loop exactly (not a
closed-form division) so it can never disagree with what actually got drawn, even in the
composite-splitting edge case (2026-09-05, left as a known rough edge for now) where different
leaves can end up wrapping different numbers of times - this only ever needs to be right for ONE
specific x (whatever's actually being placed - a cursor, here), never the whole tree's worst case at
once, so per-call iteration costs nothing. unwrap_point() below is the inverse, for a click going
the other way. wrap_width nil/non-positive means "never wraps" (x,y returned unchanged) - same
convention as everywhere else in this file. ]]
local function wrap_point(x, y, wrap_width, skipy)
    if not wrap_width or wrap_width <= 0 then
        return x, y
    end
    while x > wrap_width do
        x = x - wrap_width
        y = y + skipy
    end
    return x, y
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
own top edge, before any wrap shift. ]]
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

--[[ The cursor's on-screen rect: cursor_target() above (already root-relative, at whatever size
level the named node itself is - see its own comment), shifted by `pos` - the screen origin root
is/will be drawn at (mexpr_draw's own `pos` argument, the SAME uncorrected frame cursor_target()'s
own numbers are already in - see baseline_correction()'s own comment for why draw() applies that
correction only to the actual mexpr_draw call, not here).

Also applies the correction cursor_target() itself doesn't (see its own comment): baseline_shift/
line_height come from G/g's TRUE-baseline metrics, but mexpru.u(_).pos (root-relative) is in the
"a's own middle at the NODE's OWN size" frame - the same frame draw()'s own draw_pos converts INTO
via +baseline_correction(fontset, OUTER sz) before ever calling mexpr_draw. Bridging both: add
baseline_correction(outer sz) - baseline_correction(node's own sz) - zero whenever they're the same
size (every plain in-line cursor, unaffected), a real correction for a nested (sup/sub) one. ]]
--[[ wrap_edge (2026-09-05, vc.mexpr_draw's own edge_x - see draw()'s own comment) is an ABSOLUTE x
(same frame as `pos`, NOT a width) - the blinker's own x/top/bottom (below) are run through
wrap_point() so it actually renders on whichever row the named node really landed on, instead of its
old unwrapped spot. nil means "never wraps", same convention as everywhere else here. ]]
function mformula_new.cursor_rect(container, pos, fontset, wrap_edge)
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
    local wx, wtop = wrap_point(t.x, t.top, wrap_width, skipy)
    local _, wbottom = wrap_point(t.x, t.bottom, wrap_width, skipy)
    return {x = pos.x + wx, top = pos.y + wtop + delta, bottom = pos.y + wbottom + delta}
end

--[[ Draws container.root at `pos` (baseline origin - same convention plain text/mformula.lua's
own draw() use), at font size sz, with a blinking caret when show_cursor. container.frame (mirrors
mformula.lua's state.frame) drives the blink - persisted on container across calls the same way
root/cursor_pos already are.

@return {width=, top=, bottom=, cursor_top=, cursor_h=} - SAME contract mformula.lua's draw() had
(editor.lua reads width/top/bottom off this UNCONDITIONALLY, not just when show_cursor - measure()
above computes the first three the same way for exactly that reason). cursor_top/cursor_h (relative
to pos.y, like top/bottom) are nil/nil when show_cursor is false - editor.lua only reads them
itself when its own is_active_formula is true, but the keys always exist either way.

draw_wireframe (default false) is vc.mexpr_draw's own draw_bb - a whole-tree debug bounding-box
overlay, off by default so it doesn't clutter ordinary editing; content.lua's own wireframe-toggle
button (2026-09-04) is what flips it on. Used to be hardcoded true here (a leftover from this
editor's own early development, when seeing every node's bbox by default was the point), which is
what content.lua's toggle button exists to fix.

wrap_edge (default nil - never wraps, vc.mexpr_draw's own math.huge convention) is an ABSOLUTE x
(same frame as `pos`, NOT a width) - content past it wraps back under itself instead of running off
past whatever column/box editor.lua actually has available (vc.mexpr_draw's own long-hidden wrap
feature, 2026-09-05: it always exists in math_expr_composer.h, just used to hardcode the whole OS
window's own edge instead of taking one from the caller). @return's own width/bottom already account
for it below - width never exceeds the usable column (wrap_edge - pos.x), and bottom grows to fit
however many rows wrapping actually produced (vc.mexpr_draw's own returned total height), so
content.lua's box grows DOWN to fit a wrapped formula instead of (or now: as well as) growing right.

KNOWN GAP (2026-09-05, not fixed here): cursor_rect()/cursor_target() still compute the caret's
position from the tree's own UNWRAPPED coordinates - a cursor resting on a glyph that visually
wrapped to a lower row will render at its old, unwrapped spot instead of following it down. Same
category of unfinished-ness the C++ wrap loop's own TODO already flags for selection. ]]
function mformula_new.draw(container, fontset, pos, sz, show_cursor, draw_wireframe, wrap_edge)
    if show_cursor == nil then
        show_cursor = true
    end

    local draw_pos = {x = pos.x, y = pos.y + baseline_correction(fontset, sz)}
    local wrap_width = wrap_edge and (wrap_edge - draw_pos.x)
    -- drawn_h is vc.mexpr_draw's own ACTUAL total height (real recursive walk, not the analytical
    -- estimate content_extent()/measure() use) - kept as a floor below, not the primary source: the
    -- two USUALLY agree exactly (same formula), but a composite that straddles the wrap boundary
    -- (a fraction split mid-row - the wrap loop's own known per-leaf-independent limitation, flagged
    -- live 2026-09-05, left as-is for now) can make the real drawn height come out taller than the
    -- analytical guess. Only draw() ever sees this (measure() still can't, one frame ahead of any
    -- actual draw - accepted tradeoff, "it would skip a frame, but that doesn't really matter").
    local drawn_h = vc.mexpr_draw(fontset, draw_pos, container.root, draw_wireframe or false,
            wrap_edge or math.huge)

    local ext = content_extent(container, fontset, sz, wrap_width)
    if wrap_width then
        local drawn_bottom = ext.top + drawn_h
        if drawn_bottom > ext.bottom then
            ext.bottom = drawn_bottom
        end
    end
    local cursor_top, cursor_h = nil, nil

    container.frame = (container.frame or 0) + 1
    if show_cursor then
        local rect = mformula_new.cursor_rect(container, pos, fontset, wrap_edge)
        cursor_top, cursor_h = rect.top - pos.y, rect.bottom - rect.top
        -- Same ~30-frame half-period blink as mformula.lua's own caret (roughly 0.5s at 60fps).
        if math.floor(container.frame / 30) % 2 == 0 then
            local color = container.pending_bracket and PENDING_BRACKET_CURSOR_COLOR or CURSOR_COLOR
            vc.ImGui_AddLine({x = rect.x, y = rect.top}, {x = rect.x, y = rect.bottom}, color, 2)
        end
    end

    return {width = ext.width, top = ext.top, bottom = ext.bottom,
            cursor_top = cursor_top, cursor_h = cursor_h}
end

--[[ mformula.lua's measure() contract: {width, top, bottom}, relative to whatever baseline y a
draw() call at the same pos would use - editor.lua calls this UNCONDITIONALLY for every formula
item on every frame (its own layout pass, before anything is actually drawn) to grow the line to
fit. content_extent() (above) is the same clamped-to-never-shrink-below-empty-atom reading draw()'s
own return value uses, so the two agree on how big the formula is - wrap_width (content_extent()'s
own comment) included, so a wrapped formula grows editor.lua's own line-height reservation in pass 1
already, not just draw()'s own return value one frame late. ]]
function mformula_new.measure(container, fontset, sz, wrap_width)
    local ext = content_extent(container, fontset, sz, wrap_width)
    return {width = ext.width, top = ext.top, bottom = ext.bottom}
end

--[[ Builds one fresh sup/sub SIDE at font size sz: an empty atom, wrapped in its own one-child
horiz (so it can later grow into a real sequence, same as any other horiz). Returns both the atom
(what cursor_pos should end up naming) and the horiz (what actually goes into a supsub's own
sup/sub slot) - shared by make_supsub() and the "fill in the missing side" case in handle_input()
below, since both need to build exactly this same shape. ]]
local function build_side(fontset, sz)
    local empty = build_empty_atom(fontset, sz)
    return empty, mexpru.horiz(fontset, {empty}, sz)
end

--[[ Ctrl+Shift+'='/'-' (make_supsub("sup")/("sub")): wraps whatever atom cursor_pos currently
names (empty or glyph - anything EXCEPT a horiz, nothing specific to wrap in that case, AND except
an atom that's already a supsub's own base, see the no-op/fill-in guards at the call site) into a
fresh supsub node, and moves cursor_pos into the requested slot's own fresh empty atom, ready to
type. ONLY the requested slot is built - the other stays genuinely absent (nil), not an eager empty
placeholder - mexpr_supsub (math_expr_composer.h) already treats a nil sup/sub as "not there at
all" (skips its own anchor entirely, doesn't reserve layout space for it), which is exactly what
lets navigation later tell "doesn't exist yet" apart from "exists but empty" with a plain nil check.

base is target ITSELF - NOT wrapped in a horiz the way sup/sub are. A supsub's base is always
exactly one atom (empty or glyph), never a sequence - editing it further (typing a second
character, backspacing it) is handled as its own case in handle_input() below, not by growing a
list the way a horiz would.

target's OWN parent has to be captured BEFORE the supsub is built: mexpru.supsub(fs, target, ...)
(like any construction using target as an argument) reparents target onto the new supsub node as a
side effect (math_expr_composer.h sets each child's ->parent while building), so
target:get_parent() would answer "the new supsub" if read AFTER that point - too late to find
target's ORIGINAL slot to splice the supsub into. This is why the first splice is done by hand here
rather than via mexpru.propagate_rebuild(fs, target, ...) directly - target's parent identity
changes mid-construction, propagate_rebuild's own "ask old_node for its current parent" wouldn't be
asking the right node anymore.

sup/sub render SMALLER than the base (SUB_SIZE_DELTA, capped at MAX_SIZE_INDEX) - base_sz comes
from target's own u(target).sz (the level it was ALREADY rendering at, unchanged by becoming a
base), not any size passed in from outside - matches cursor_target()'s own per-node sz reasoning. ]]
local function make_supsub(container, fontset, slot)
    local target = container.cursor_pos:get_obj()
    -- Falls back to base's own sz when target is a bare supsub node itself (resting spot, no u(_).sz
    -- of its own) - same fallback, same reason, as handle_input()'s own target_sz computation (see
    -- its comment) - NOT is_supsub() itself (declared further down this file, after this function,
    -- same forward-reference reason make_frac() uses a raw kind check instead too).
    local base_sz = mexpru.u(target).sz
            or (mexpru.u(target).kind == "supsub" and mexpru.u(mexpru.u(target).base).sz)
    local sub_sz = math.min(base_sz + SUB_SIZE_DELTA, MAX_SIZE_INDEX)
    local original_parent = target:get_parent()

    local new_empty, new_horiz = build_side(fontset, sub_sz)
    local supsub_node
    if slot == "sup" then
        supsub_node = mexpru.supsub(fontset, target, new_horiz, nil)
    else
        supsub_node = mexpru.supsub(fontset, target, nil, new_horiz)
    end

    local children = mexpru.u(original_parent).children
    -- target:get_parent_idx() (math_expr_composer.h) - safe here since `children` was just read
    -- fresh above, nothing's mutated it since, so target's own parent (not yet rebuilt) and this
    -- Lua list are still in exact sync.
    children[target:get_parent_idx()] = supsub_node
    local rebuilt = mexpru.horiz(fontset, children, mexpru.u(original_parent).sz)
    container.root = mexpru.propagate_rebuild(fontset, original_parent, rebuilt)

    container.cursor_pos = vc.wref_mexpr(new_empty)
    container.version = (container.version or 0) + 1
end

--[[ Ctrl+/ (mid-formula): inserts a fresh, empty fraction AT the cursor position and moves
cursor_pos into its numerator. Unlike make_supsub(), never WRAPS whatever's already there - a
fraction has no single preceding glyph that obviously belongs in either half (num/den are each a
full horiz, built from nothing, not derived from an existing atom) - see this file's own top model
comment and the 2026-09-04 fraction design discussion. Splices in exactly like a typed glyph does in
handle_input() below: at the very start if cursor_pos is a horiz, otherwise right after whatever
atom/compound cursor_pos currently names within its own container horiz (a frac or supsub node
resting there is just another element of that list for this purpose, no different from an atom).
Built at cursor_pos's own current size level (target_sz, matching make_supsub()'s own reasoning) -
num/den render at that SAME size, not shrunk (mexpru.frac()'s own doc comment). Caller is
responsible for the "on a supsub's own base" no-op check (see handle_input() below) - this function
assumes it's always safe to insert, same division of responsibility as make_supsub()'s own call
site handling the "already has this side" no-op instead of make_supsub() itself. ]]
local function make_frac(container, fontset, target_sz)
    local target = container.cursor_pos:get_obj()

    local num_empty, num_horiz = build_side(fontset, target_sz)
    local _, den_horiz = build_side(fontset, target_sz)
    local frac_node = mexpru.frac(fontset, num_horiz, den_horiz, target_sz)

    -- NOT is_horiz() - that helper (and is_supsub()/is_frac()) is declared further down this file,
    -- after this function; a plain kind check does the same thing without a forward reference.
    if mexpru.u(target).kind == "horiz" then
        local children = mexpru.u(target).children
        table.insert(children, 1, frac_node)
        local rebuilt = mexpru.horiz(fontset, children, target_sz)
        container.root = mexpru.propagate_rebuild(fontset, target, rebuilt)
    else
        local horiz = target:get_parent()
        local children = mexpru.u(horiz).children
        -- target:get_parent_idx() - safe here, same reasoning as make_supsub()'s own use above.
        table.insert(children, target:get_parent_idx() + 1, frac_node)
        local rebuilt = mexpru.horiz(fontset, children, mexpru.u(horiz).sz)
        container.root = mexpru.propagate_rebuild(fontset, horiz, rebuilt)
    end

    container.cursor_pos = vc.wref_mexpr(num_empty)
    container.version = (container.version or 0) + 1
end

--[[ Like mformula_new.new(), but root starts with a single, empty fraction node, cursor already in
its numerator - editor.lua's entry point for Ctrl+/ pressed in plain text (mirrors Ctrl+M's plain
mformula_new.new()), so a fraction can be started without Ctrl+M first. Builds the node inline
rather than calling make_frac() - same reason make_frac() itself doesn't get reused here as
mformula_new.new() doesn't call any "insert into an existing tree" helper either: there's no
container/cursor_pos yet for make_frac() to read from. ]]
function mformula_new.new_with_frac(fontset, sz)
    local num_empty, num_horiz = build_side(fontset, sz)
    local _, den_horiz = build_side(fontset, sz)
    local frac_node = mexpru.frac(fontset, num_horiz, den_horiz, sz)
    local root = mexpru.horiz(fontset, {frac_node}, sz)
    mexpru.update_positions(root)
    return {
        root = root,
        cursor_pos = vc.wref_mexpr(num_empty),
        version = 0,
    }
end

--[[ Arrow-key navigation. Cursor movement never bumps container.version (see editor.lua's own
undo-coalescing comment: only real tree edits should count as an undo step, not pure cursor
movement) - none of the functions below touch the tree at all, only container.cursor_pos.

Four resting-position KINDS matter here, dispatched throughout by is_horiz()/is_supsub()/whether
target is a supsub's own base:
  - a horiz H, at position 0 (before its first child)
  - a plain atom (empty or glyph) sitting in some horiz
  - a supsub's own base atom
  - a supsub node S itself ("after the whole compound" - same on-screen spot as "before whatever
    comes next" in S's own container horiz)

Left/Right walk the reading-order chain: within a horiz, between adjacent slots; at either edge of
a horiz that's a supsub's sup/sub, into/out of that supsub (base on the left, S itself on the
right - deliberately asymmetric, see move_right()'s own comment on why entering a supsub from the
left dives straight into its base instead of resting on S). Up/Down move between a supsub's own
base and the END of whichever of sup/sub exists; from anywhere else inside sup/sub, they reach
toward base directly (non-reciprocal - see move_up()/move_down()'s own comments) UNLESS that fails
locally, in which case walk_up_vertical() climbs the tree looking for a context where the motion
DOES resolve, landing on whichever ancestor's base finally answers it (or where it started, if
none ever does - see walk_up_vertical()'s own comment). ]]
local function is_horiz(node)
    return mexpru.u(node).kind == "horiz"
end

local function is_supsub(node)
    return mexpru.u(node).kind == "supsub"
end

local function is_frac(node)
    return mexpru.u(node).kind == "frac"
end

--[[ Is `node` (an atom) a supsub's own base? Returns that supsub too, or nil, nil if not - saves
every caller from re-deriving get_parent()/kind/same() by hand each time. ]]
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

--[[ Splices a freshly-built glyph atom (`new_glyph` - ALREADY tagged with whatever it needs, at
minimum u(_).sz, same as every atom this file builds carries) into the tree at cursor_pos, per this
file's own model comment's REPLACE/INSERT-AT-START/INSERT-AFTER/bump-old-base-out rules - shared by
the ordinary character-typing loop in handle_input() below and open_bracket()'s own placeholder
insertion (a bracket atom is typed exactly like any other character at this point - it's just an
ordinary ASCII glyph with extra bookkeeping tagged on), so both go through the identical splice
mechanics rather than duplicating them. Moves cursor_pos to `new_glyph` and bumps container.version,
same as every tree-editing operation in this file already does. ]]
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
        table.insert(children, target:get_parent_idx() + 1, new_glyph)
        local rebuilt = mexpru.horiz(fontset, children, mexpru.u(horiz).sz)
        container.root = mexpru.propagate_rebuild(fontset, horiz, rebuilt)
    end

    container.cursor_pos = vc.wref_mexpr(new_glyph)
    container.version = (container.version or 0) + 1
end

--[[ '(' / '[' / '{' typed (bracket_type = OPEN_BRACKETS[ch]): builds the placeholder open-bracket
glyph - an ordinary ASCII glyph at this point, same as any other typed character - and splices it in
via insert_glyph_at_cursor(), the exact same 4-way splice an ordinary typed character goes through,
since at this point it genuinely IS just an ordinary character as far as the tree is concerned. Tags
it u(_).bracket = {is_open=true, type=bracket_type} and parks container.pending_bracket on it - a
single slot, not a stack (opening a SECOND bracket while one is already pending is a no-op/blocked -
see this function's own call site in handle_input()). While pending, mformula_new.draw() shows a
purple cursor (PENDING_BRACKET_CURSOR_COLOR) instead of the ordinary CURSOR_COLOR. ]]
local function open_bracket(container, fontset, target, target_parent, target_is_horiz,
        target_is_empty, target_is_supsub_base, target_sz, bracket_type)
    local entry = char.find_by_ascii(OPEN_BRACKET_ASCII[bracket_type])
    -- target_sz is LOGICAL - mapped to PHYSICAL only for the real construction call below, same as
    -- every other glyph this file builds (mexpru.rescale()'s own comment).
    local new_glyph = mexpru.mexpr_symbol(fontset, {size = mexpru.physical_sz(target_sz), code = entry.ncod}, true)
    mexpru.u(new_glyph).sz = target_sz
    mexpru.u(new_glyph).bracket = {is_open = true, type = bracket_type}

    insert_glyph_at_cursor(container, fontset, target, target_parent, target_is_horiz,
            target_is_empty, target_is_supsub_base, target_sz, new_glyph)

    container.pending_bracket = vc.wref_mexpr(new_glyph)
end

-- ')' / ']' / '}' -> bracket type, and back - entangled-bracket closing (try_close_bracket() below).
local CLOSE_BRACKETS = {
    [")"] = vc.MEXPR_BRACKET_ROUND, ["]"] = vc.MEXPR_BRACKET_SQUARE, ["}"] = vc.MEXPR_BRACKET_CURLY,
}
local CLOSE_BRACKET_ASCII = {
    [vc.MEXPR_BRACKET_ROUND] = ")", [vc.MEXPR_BRACKET_SQUARE] = "]", [vc.MEXPR_BRACKET_CURLY] = "}",
}

--[[ ')' / ']' / '}' typed (bracket_type = CLOSE_BRACKETS[ch]) - only actually closes when: a
bracket IS pending, its own type matches the key pressed, and cursor_pos currently rests at a
position belonging to the SAME horiz the open atom itself lives in (its own get_parent()) - either
an ordinary sibling slot there, or (base_of()'s own "a base reads as occupying its supsub's slot"
convention, reused here) a supsub's base whose supsub sits in that horiz. Any other cursor position,
or no pending bracket at all, or a type mismatch: swallowed - a pure no-op, nothing inserted as a
stray character either (closing brackets are reserved, never ordinary content).
A closing bracket landing exactly ON the open atom itself closes an EMPTY pair ("imagine an I
[cursor] at the current font level" - a fresh empty atom fills the gap, since mexpru.lua's
resolve_bracket_pairs() relies on a pair's span never actually being empty and errors loudly
otherwise) - only in that exact case; any real content already there gets no filler, its own extent
alone drives both brackets' eventual size.
Once matched, BOTH atoms get u(_).bracket.peer set on each other - a reference to the OTHER's own
u() table, not the raw node (mexpru.lua's own top comment on why that distinction matters - real Lua
`==`, no C++ identity workaround needed) - which is what lets mexpru.horiz()'s very next rebuild
(triggered right here) immediately resolve the pair into its real, properly-sized glyphs via
resolve_bracket_pairs() - the open atom rendered as a perfectly ordinary, unsized glyph up until
this exact point (open_bracket()'s own comment), both sides replaced together the instant it closes. ]]
local function try_close_bracket(container, fontset, bracket_type)
    local pending = container.pending_bracket
    if not pending then
        return
    end
    local open_atom = pending:get_obj()
    local open_bracket_u = mexpru.u(open_atom).bracket
    if open_bracket_u.type ~= bracket_type then
        return
    end
    local open_horiz = open_atom:get_parent()

    local close_target = container.cursor_pos:get_obj()
    local base_owner = base_of(close_target)
    if base_owner then
        close_target = base_owner
    end
    if is_horiz(close_target) then
        return
    end
    local close_parent = close_target:get_parent()
    if not close_parent or not mexpru.same(close_parent, open_horiz) then
        return
    end

    local open_idx = open_atom:get_parent_idx()
    local close_target_idx = close_target:get_parent_idx()
    if open_idx == 0 or close_target_idx == 0 or close_target_idx < open_idx then
        return
    end

    local children = mexpru.u(open_horiz).children
    local close_sz = mexpru.u(open_atom).sz
    local close_entry = char.find_by_ascii(CLOSE_BRACKET_ASCII[bracket_type])
    -- close_sz is LOGICAL - mapped to PHYSICAL only for the real construction call (same reasoning
    -- as open_bracket()'s own new_glyph construction just above).
    local close_glyph = mexpru.mexpr_symbol(fontset, {size = mexpru.physical_sz(close_sz), code = close_entry.ncod}, true)
    mexpru.u(close_glyph).sz = close_sz

    local close_idx
    if close_target_idx == open_idx then
        local filler = build_empty_atom(fontset, close_sz)
        table.insert(children, open_idx + 1, filler)
        table.insert(children, open_idx + 2, close_glyph)
        close_idx = open_idx + 2
    else
        table.insert(children, close_target_idx + 1, close_glyph)
        close_idx = close_target_idx + 1
    end

    mexpru.u(close_glyph).bracket = {is_open = false, type = bracket_type, peer = open_bracket_u}
    open_bracket_u.peer = mexpru.u(close_glyph)
    container.pending_bracket = nil

    -- children[close_idx] is read AFTER the rebuild below, not a local variable holding close_glyph
    -- directly - resolve_bracket_pairs() (mexpru.lua), part of that same rebuild, immediately
    -- resolves this brand-new pair (its first ever resolve) and REPLACES both atoms in `children`
    -- with the real sized glyphs - close_glyph itself is the now-discarded placeholder by the time
    -- this returns.
    local rebuilt = mexpru.horiz(fontset, children, mexpru.u(open_horiz).sz)
    container.root = mexpru.propagate_rebuild(fontset, open_horiz, rebuilt)
    container.cursor_pos = vc.wref_mexpr(children[close_idx])
    container.version = (container.version or 0) + 1
end

--[[ Rebuilds `node` (and everything beneath it) at the CURRENT global zoom (mexpru.get_zoom()/
mexpru.physical_sz()) - every node's own u(_).sz stays exactly what it already was (LOGICAL, never
touched by zoom - mexpru.physical_sz()'s own comment); only the REAL glyph geometry actually
constructed for each leaf uses physical_sz(that logical value) instead. A 1:1 structural mirror of
the original tree - same kind, same children/base-sup-sub/num-den shape - built bottom-up via this
file's OWN normal construction helpers (mexpru.horiz()/supsub()/frac(), build_empty_atom(),
mexpru.mexpr_symbol()), so every kind of node this file can ever build is handled the exact same way
it was built the first time, nothing rescale-specific to keep in sync as new node kinds get added.

Bracket atoms (u(_).bracket) are rebuilt back to their PENDING/un-resolved shape - a small plain
glyph at the new physical size, is_open/type preserved, peer dropped - rather than reconstructing
the resolved mexpr_bracket_left/right composite by hand: the enclosing mexpru.horiz() call a few
lines below re-runs resolve_bracket_pairs() (mexpru.lua) on the way back up regardless, which
rebuilds the REAL sized bracket glyphs and re-links peers itself, exactly mirroring how a live
close-bracket keypress (try_close_bracket() above) produces them the first time. Cheaper to let that
existing machinery redo its own job than to duplicate bracket-height math here.

Returns (new_node, mapped_cursor) - mapped_cursor is the NEW node standing in for `cursor_target`
(compared by mexpru.same, i.e. identity) once the walk passes through it, or nil if this branch
never encountered it. Deterministic, not a nearest-fit guess: since the walk is a structural mirror
of the original tree, "the node built at the exact step that replaced cursor_target" IS cursor_pos's
new home, however deeply nested. mformula_new.rescale() (the public entry point, below) does the
top-level container.cursor_pos reassignment once the whole walk completes. ]]
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
        new_node = mexpru.horiz(fontset, new_children, logical)
    elseif u.kind == "supsub" then
        local new_base, m1 = rescale_node(fontset, u.base, cursor_target)
        local new_sup, new_sub, m2, m3
        if u.sup then new_sup, m2 = rescale_node(fontset, u.sup, cursor_target) end
        if u.sub then new_sub, m3 = rescale_node(fontset, u.sub, cursor_target) end
        new_node = mexpru.supsub(fontset, new_base, new_sup, new_sub)
        mapped = m1 or m2 or m3
    elseif u.kind == "frac" then
        local new_num, m1 = rescale_node(fontset, u.num, cursor_target)
        local new_den, m2 = rescale_node(fontset, u.den, cursor_target)
        new_node = mexpru.frac(fontset, new_num, new_den, logical)
        mapped = m1 or m2
    elseif u.bracket then
        local ascii = u.bracket.is_open and OPEN_BRACKET_ASCII[u.bracket.type]
                or CLOSE_BRACKET_ASCII[u.bracket.type]
        local entry = char.find_by_ascii(ascii)
        new_node = mexpru.mexpr_symbol(fontset, {size = mexpru.physical_sz(logical), code = entry.ncod}, true)
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
        -- time (from the glyph's own code -> desc -> size_delta_by_desc lookup) - found 2026-09-05,
        -- reported live: without this, every rescale (any zoom change) silently rebuilt a boosted
        -- glyph like \\int as a perfectly ordinary-sized one, since this branch used to just take
        -- `logical` at face value.
        local entry = char.find_by_ncod(node.symb.code)
        local delta = entry and char.size_delta_by_desc[entry.desc]
        local glyph_sz = delta and math.max(1, math.min(logical + delta, MAX_SIZE_INDEX)) or logical
        new_node = mexpru.mexpr_symbol(fontset, {size = mexpru.physical_sz(glyph_sz), code = node.symb.code}, true)
        mexpru.u(new_node).sz = logical
    end

    if cursor_target and mexpru.same(node, cursor_target) then
        mapped = new_node
    end
    return new_node, mapped
end

--[[ Public entry point for rescale_node() above - content.lua's own Ctrl+MouseWheel zoom handler
calls this (via editor.rescale(), per box) on every embedded formula any time the global zoom
actually changes, so already-typed content visually catches up (newly-typed content already picks
up the current zoom on its own - target_sz's own construction call, unchanged by any of this).
Reassigns container.root/cursor_pos in place; the OLD root is mexpru.cut() loose the same way
propagate_rebuild() already does for a superseded root (mexpru.cut()'s own comment - without this
the whole OLD tree lingers on Lua's own collector schedule instead of letting go immediately). ]]
function mformula_new.rescale(container, fontset)
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

--[[ Exits `horiz` to the LEFT: if horiz has no parent (it's root), nothing further left. Otherwise
horiz's parent is EITHER a supsub or a frac (the only two things a horiz can ever sit inside, besides
being root itself):
  - supsub: land on ITS base (unique to supsub - a frac has no equivalent, see below).
  - frac (horiz is num or den - reached only after Up/Down entered it, Left/Right never dive into
    num/den directly): no base to land on - the whole frac reads as ONE opaque atom for Left/Right
    (this file's own model/2026-09-04 fraction design discussion), so exiting leftward from INSIDE
    it is the same move as exiting leftward from RESTING ON it - move_left_within() on the frac
    node's own container, treating the frac itself as "whatever occupies this slot".
    (Found live 2026-09-04: this case was missing entirely - reading a nonexistent .base off a frac
    silently built a wref to nil, a permanently dangling cursor_pos with no further error until the
    NEXT frame's cursor_target()/slot_markers() call indexed it.)
Used ONLY when cursor_pos is ALREADY horiz's own position 0 - NOT when cursor_pos is on horiz's
first element (see move_left_within()'s own comment for why those are two DIFFERENT on-screen spots,
not one - a real point this file got wrong once already: landing "on horiz" and landing "on its
base" each need their own separate Left keypress, not one keypress skipping straight past the
first). ]]
exit_horiz_leftward = function(container, horiz)
    local horiz_parent = horiz:get_parent()
    if not horiz_parent then
        return
    end
    local hp_u = mexpru.u(horiz_parent)
    if hp_u.kind == "supsub" then
        container.cursor_pos = vc.wref_mexpr(hp_u.base)
    elseif hp_u.kind == "frac" then
        move_left_within(container, horiz_parent:get_parent(), horiz_parent)
    end
end

--[[ Moves left by one slot within `horiz`, where `node` (an atom OR a supsub - both are just
"whatever occupies this slot" for this purpose) currently sits at some index. Preceding sibling if
there is one. Otherwise `node` is horiz's own FIRST element, and what happens depends on what kind
it is:
  - node is a glyph or supsub: land on `horiz` ITSELF (position 0) - NOT exit_horiz_leftward()
    straight to base/wherever's further out. These are genuinely different on-screen spots: a
    glyph/supsub element renders with the caret AFTER it, while horiz's own position 0 renders at
    horiz's own left edge, BEFORE its first element - two distinct positions, each needing its own
    Left keypress. (A prior version of this collapsed them into one keypress - wrong, confirmed by
    testing: A^{B+C}, walking left from C through + to B, a further Left has to land on sup's own
    horiz first, THEN base - not skip straight to base in one step.)
  - node is an EMPTY atom: the OPPOSITE correction - landing on `horiz` here WOULD be the
    redundant, wasted-keypress case cursor_target() already treats an EMPTY_BOX and a horiz's own
    position 0 identically (same is_start branch, same left-edge x) - genuinely the same on-screen
    spot, unlike the glyph case above. Skip straight past via exit_horiz_leftward() instead. This
    isn't just cosmetic: per this file's own invariant, an empty atom is NEVER anything but a
    horiz's ONLY child (new()/handle_input()'s empty-fallback both only ever produce a lone empty
    atom, never one alongside real content) - so resting cursor_pos on that horiz would hit its
    "write inserts at start of list" rule instead of the empty atom's own "write REPLACES it" rule,
    producing a stray leftover empty atom next to whatever got typed. ]]
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

function mformula_new.move_left(container)
    local target = container.cursor_pos:get_obj()

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
width away should land). ]]
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
in one call - matches how every other keypress only ever takes one visual step. ]]
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

function mformula_new.move_right(container)
    local target = container.cursor_pos:get_obj()

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
right) - reciprocal with the last-of-sup/sub "down/up -> S" boundary rule below. ]]
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
never anything but a horiz's sole child). ]]
local function enter_at_start(sup_or_sub_horiz)
    local children = mexpru.u(sup_or_sub_horiz).children
    if #children == 1 and children[1].type == vc.MEXPR_TYPE_EMPTY_BOX then
        return children[1]
    end
    return sup_or_sub_horiz
end

-- Which frac slot plays the same role as sup/sub does for a supsub, per direction - "num" is
-- frac's "upper" slot (sup's counterpart), "den" its "lower" one (sub's counterpart). Used by
-- walk_up_vertical() below to recognize a frac ancestor as a bifurcation point too, not just a
-- supsub one.
local FRAC_COUNTERPART = {sup = "num", sub = "den"}
local FRAC_SIBLING = {num = "den", den = "num"}

--[[ Only reached when a vertical motion has NO local target (see move_up()/move_down()'s own
"non-reciprocal" cases) - `node` is the supsub/frac we're stuck at, `sup_or_sub` is which of ITS OWN
slots would answer this same motion if found one level further out ("sup" while searching for a
Down target, "sub" while searching for an Up target - the mirror of what we were just inside).
Climbs: does node's own container horiz belong to node's parent's `sup_or_sub` slot (a supsub
ancestor)? If so, land on THAT parent's base - "bifurcation" found, the motion finally resolves.
Does it instead belong to the CORRESPONDING frac slot (FRAC_COUNTERPART[sup_or_sub] - "num" for a
Down search, "den" for an Up one - a frac ancestor)? Then the bifurcation is a direct sibling jump
into that frac's OTHER slot instead - "propagate via the rules of whatever was having the frac"
(2026-09-04 design discussion): a frac ancestor answers through its OWN num/den semantics rather
than being transparent to the climb, so a fraction nested inside ANOTHER fraction's own num/den
resolves there, not by skipping past it hunting only for a supsub further out. If NEITHER matches
(still the same side we started on, one level further out - a supsub's other sup/sub slot, or a
frac's own OTHER num/den... which can't happen, since a frac's horiz IS always either its num or its
den, never anything else - so in practice this case is purely "another supsub's matching-direction
slot"), keep climbing from that parent.

Returns nil when nothing above ever resolves it - EITHER the climb reaches the root with no match
ever found, OR it bottoms out at a node with no .base of its own (a frac, when node ITSELF is where
we started and there's no further ancestor - a frac has no base to fall back to the way a supsub
does). Every caller must treat nil as a true no-op (leave cursor_pos exactly where it was), NOT
reassign it. ]]
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

function mformula_new.move_down(container)
    local target = container.cursor_pos:get_obj()

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
    if is_frac(target) then
        container.cursor_pos = vc.wref_mexpr(enter_at_end(mexpru.u(target).den))
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
        -- sup->base does - a frac has none, 2026-09-04 design discussion). Not conditioned on
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

function mformula_new.move_up(container)
    local target = container.cursor_pos:get_obj()

    if is_supsub(target) then
        local sup = mexpru.u(target).sup
        if sup then
            container.cursor_pos = vc.wref_mexpr(enter_at_end(sup))
        else
            apply_walk(container, target, "sub")
        end
        return
    end

    -- Resting ON a frac node itself - mirror of move_down()'s own is_frac(target) branch: Up
    -- enters its numerator, always possible, entering at the END (arriving from further right).
    if is_frac(target) then
        container.cursor_pos = vc.wref_mexpr(enter_at_end(mexpru.u(target).num))
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
        -- does (mirror, symmetric per this file's own 2026-09-04 fraction design discussion) -
        -- walk_up_vertical() recognizes a frac ancestor's "den" as the bifurcation slot for an Up
        -- search (FRAC_COUNTERPART["sub"] = "den"), so e.g. (a/b)/c with the cursor in "a" going Up
        -- resolves to "c" the same way going Down from "b" resolves to it.
        apply_walk(container, horiz_parent, "sub")
    end
end

--[[ mformula.lua's handle_input() contract - editor.lua calls this UNCONDITIONALLY every frame a
formula is active (not just on a keypress edge - see its own call site's comment on why: this is
the "forward keys to the active formula" branch, reached whenever nothing else claimed the input
first). fontset/sz (new here - mformula.lua's own handle_input() never needed them, since it only
ever pushed plain {code=} data, deferring any real mexpr_* call to build_row() - this architecture
builds the real mexpr node AT edit time instead, so it needs them right away; editor.lua's call
site was updated to pass these through).

Every case follows the same shape: figure out cursor_pos's IMMEDIATE horiz (either cursor_pos
itself, if it's already a horiz, or cursor_pos:get_parent() if it's an atom), splice that horiz's
OWN remembered children list (mexpru.u(horiz).children), rebuild via mexpru.horiz(), then
mexpru.propagate_rebuild() to ripple that change up to the root and refresh the position cache -
see this file's own model comment for exactly which splice each (node kind x key) combination does,
and mexpru.propagate_rebuild()'s own comment for how the upward ripple works. ]]
function mformula_new.handle_input(container, fontset, sz)
    local target = container.cursor_pos:get_obj()
    local target_parent = target:get_parent()
    local target_is_horiz = (mexpru.u(target).kind == "horiz")
    local target_is_empty = (target.type == vc.MEXPR_TYPE_EMPTY_BOX)
    -- target is a supsub's own base atom when its parent is a supsub AND that supsub's own .base
    -- IS target (not its .sup or .sub - a base is a bare atom directly under the supsub, see
    -- make_supsub()'s own comment, so this is the only way to tell base apart from anything else).
    local target_is_supsub_base = target_parent ~= nil and mexpru.u(target_parent).kind == "supsub"
            and mexpru.same(mexpru.u(target_parent).base, target)
    -- The size level to build/rebuild AT is always read off cursor_pos's own node (mexpru.horiz()/
    -- build_empty_atom() tag every node with its own u(_).sz) - NOT the outer `sz` parameter, which
    -- is only ever the top-level formula's own size (editor.lua's constant FONT_SZ) and would be
    -- wrong for anything typed inside a smaller-rendered sup/sub. `sz` itself only still matters
    -- here as the fallback for the Ctrl+Shift+-/+ check below (make_supsub() reads its own base
    -- size off cursor_pos the same way, so it doesn't need `sz` passed in either).
    --
    -- Falls back to base's own sz (same trick cursor_target() already uses) when target is a bare
    -- supsub node itself ("after the whole compound" - move_left()/move_right()'s own resting spot,
    -- e.g. cursor_pos landing there by default at the end of freshly-loaded content that ends in a
    -- sup/sub - mformula_latex.from_latex()'s own comment) - a supsub never carries its own u(_).sz
    -- (mexpru.supsub()'s own comment: it spans several sizes at once, none uniquely "its own").
    -- Found 2026-09-04 (fraction design/build): Ctrl+/ pressed in exactly that resting spot crashed
    -- (mexpru.frac() -> char.hline_basic(nil) -> invalid char size) before this fallback existed -
    -- same latent gap already existed for Ctrl+Shift+=/- there too (make_supsub()'s OWN internal
    -- base_sz read, fixed the same way, below).
    local target_sz = mexpru.u(target).sz or (is_supsub(target) and mexpru.u(mexpru.u(target).base).sz)

    -- Checked ahead of plain typing, same as mformula.lua's own Ctrl+Shift+-/+ handling - a no-op
    -- while cursor_pos is on a horiz (nothing specific to wrap yet - see this file's own model
    -- comment on the horiz-cursor case). On a supsub's own base, this is only a no-op if the
    -- REQUESTED side already exists (nesting a second supsub onto an already-occupied side isn't a
    -- real thing to want - logged, not silently ignored) - if that side is genuinely absent (sup/sub
    -- are lazy now, not eagerly both built - see make_supsub()'s own comment), this FILLS IT IN
    -- instead: a real structural change (the supsub's own bb changes - an empty side still reserves
    -- real layout space, per math_expr_composer.h), so it goes through the same
    -- rebuild-and-propagate-up path as every other edit, not treated as a lighter-weight operation.
    local ctrl_down = vc.ImGui_IsKeyDown("ImGuiKey_LeftCtrl") or vc.ImGui_IsKeyDown("ImGuiKey_RightCtrl")
    local shift_down = vc.ImGui_IsKeyDown("ImGuiKey_LeftShift") or vc.ImGui_IsKeyDown("ImGuiKey_RightShift")
    if ctrl_down and shift_down and not target_is_horiz then
        local sup_pressed = vc.ImGui_IsKeyPressed("ImGuiKey_Equal", false)
        local sub_pressed = vc.ImGui_IsKeyPressed("ImGuiKey_Minus", false)
        if sup_pressed or sub_pressed then
            if target_is_supsub_base then
                local supsub_node = target_parent
                local u = mexpru.u(supsub_node)
                if (sup_pressed and u.sup) or (sub_pressed and u.sub) then
                    print("mformula_new: ignoring Ctrl+Shift+=/- on a supsub's own base - that side already exists")
                else
                    local sub_sz = math.min(target_sz + SUB_SIZE_DELTA, MAX_SIZE_INDEX)
                    local new_empty, new_horiz = build_side(fontset, sub_sz)
                    local rebuilt_supsub
                    if sup_pressed then
                        rebuilt_supsub = mexpru.supsub(fontset, u.base, new_horiz, u.sub)
                    else
                        rebuilt_supsub = mexpru.supsub(fontset, u.base, u.sup, new_horiz)
                    end
                    container.root = mexpru.propagate_rebuild(fontset, supsub_node, rebuilt_supsub)
                    container.cursor_pos = vc.wref_mexpr(new_empty)
                    container.version = (container.version or 0) + 1
                end
            else
                make_supsub(container, fontset, sup_pressed and "sup" or "sub")
            end
            return
        end
    end

    -- Ctrl+/ (make_frac()): inserts a fresh, empty fraction at the cursor - see make_frac()'s own
    -- comment. A no-op (logged) on a supsub's own base specifically - unlike sup/sub, a fraction has
    -- no notion of a base to attach to at all (this file's own top model comment / 2026-09-04
    -- fraction design discussion), so there's no "fill in" alternative the way Ctrl+Shift+=/- has;
    -- it just doesn't apply there.
    if ctrl_down and not shift_down and vc.ImGui_IsKeyPressed("ImGuiKey_Slash", false) then
        if target_is_supsub_base then
            print("mformula_new: ignoring Ctrl+/ on a supsub's own base - fractions have no base to attach to")
        else
            make_frac(container, fontset, target_sz)
        end
        return
    end

    for _, cp in ipairs(vc.ImGui_input_queue_chars()) do
        if cp > 32 and cp < 256 then
            local ch = string.char(cp)

            -- '(' / '[' / '{' and ')' / ']' / '}' are intercepted here, ahead of the ordinary
            -- char.find_by_ascii() path below - see open_bracket()'s/try_close_bracket()'s own
            -- comments (near base_of()). Opening a SECOND bracket while one is already pending is a
            -- no-op/blocked (single pending slot, not a stack); a CLOSE bracket always goes through
            -- try_close_bracket() (its own comment covers every way it can be a no-op).
            if OPEN_BRACKETS[ch] then
                if not container.pending_bracket then
                    open_bracket(container, fontset, target, target_parent, target_is_horiz,
                            target_is_empty, target_is_supsub_base, target_sz, OPEN_BRACKETS[ch])
                end
                return
            elseif CLOSE_BRACKETS[ch] then
                try_close_bracket(container, fontset, CLOSE_BRACKETS[ch])
                return
            end

            local entry = char.find_by_ascii(ch)
            if entry then
                -- target_sz is LOGICAL - mapped to PHYSICAL only for the real construction call.
                local new_glyph = mexpru.mexpr_symbol(fontset, {size = mexpru.physical_sz(target_sz), code = entry.ncod}, true)
                mexpru.u(new_glyph).sz = target_sz
                insert_glyph_at_cursor(container, fontset, target, target_parent, target_is_horiz,
                        target_is_empty, target_is_supsub_base, target_sz, new_glyph)
                return
            end
        end
    end

    -- Arrow keys: pure cursor movement, no tree edit - see move_left()/move_right()/move_up()/
    -- move_down()'s own comments for the full mechanics. Checked ahead of backspace/delete (which
    -- both need target_is_empty/target_is_horiz gating that doesn't apply to movement at all).
    if vc.ImGui_IsKeyPressed("ImGuiKey_LeftArrow", true) then
        mformula_new.move_left(container)
        return
    end
    if vc.ImGui_IsKeyPressed("ImGuiKey_RightArrow", true) then
        mformula_new.move_right(container)
        return
    end
    if vc.ImGui_IsKeyPressed("ImGuiKey_UpArrow", true) then
        mformula_new.move_up(container)
        return
    end
    if vc.ImGui_IsKeyPressed("ImGuiKey_DownArrow", true) then
        mformula_new.move_down(container)
        return
    end

    -- Backspace removes the atom cursor_pos itself names; Delete removes whichever atom comes
    -- right after it. Neither does anything while cursor_pos is on a horiz or an empty atom (see
    -- this file's own model comment) - there's no atom AT that position for either key to act on.
    local backspace = vc.ImGui_IsKeyPressed("ImGuiKey_Backspace", true)
    local fwd_delete = vc.ImGui_IsKeyPressed("ImGuiKey_Delete", true)
    if (not (backspace or fwd_delete)) or target_is_horiz or target_is_empty then
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

        local new_base
        if supsub_idx > 1 then
            new_base = outer_children[supsub_idx - 1]
            table.remove(outer_children, supsub_idx - 1)
        else
            new_base = build_empty_atom(fontset, target_sz)
        end

        local u = mexpru.u(supsub_node)
        local rebuilt_supsub = mexpru.supsub(fontset, new_base, u.sup, u.sub)
        -- Deliberately NOT supsub_node:get_parent_idx() here - the table.remove() above already
        -- mutated outer_children (Lua), but outer_horiz's own C++ subobjs hasn't been rebuilt yet
        -- (still reflects the PRE-removal order) - get_parent_idx() would silently return the stale
        -- index. mexpru.index_of() re-scans the LIVE, already-mutated Lua list instead, which is
        -- what's actually needed once the two have diverged like this.
        outer_children[mexpru.index_of(outer_children, supsub_node)] = rebuilt_supsub

        local rebuilt_outer = mexpru.horiz(fontset, outer_children, mexpru.u(outer_horiz).sz)
        container.root = mexpru.propagate_rebuild(fontset, outer_horiz, rebuilt_outer)
        container.cursor_pos = vc.wref_mexpr(new_base)
        container.version = (container.version or 0) + 1
        return
    end

    local horiz = target_parent
    local horiz_sz = mexpru.u(horiz).sz
    local children = mexpru.u(horiz).children
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
    -- mexpru.scan_bracket(), not a hand-rolled search: victim's own peer, found by depth-tracked
    -- walk in the direction its OWN kind implies (open -> rightward, close -> leftward) - it can
    -- never resolve to `i` itself (an already-resolved pair always has at least one real element
    -- between its two atoms - resolve_bracket_pairs()'s own invariant, mexpru.lua - so victim and
    -- ITS OWN peer are never adjacent), so target survives intact whenever victim isn't target.
    local victim_br = mexpru.u(victim).bracket
    local peer_idx = victim_br and victim_br.peer
            and mexpru.scan_bracket(children, victim_idx, victim_br.is_open and 1 or -1)

    -- Only table.remove() here - NOT mexpru.cut() yet. Cutting has to wait until AFTER
    -- propagate_rebuild() below actually completes: until then, the OLD (pre-edit) ancestor chain
    -- - not yet superseded - still references these nodes via its OWN C++-side subobjs
    -- (math_expr_composer.h), same as `children` itself did before this table.remove(). Cutting
    -- early releases Lua's claim while that OLD chain still holds its own, so nothing actually
    -- dies - found by this file's own test (test_bracket_cascade.lua) catching exactly that
    -- ordering mistake in an earlier draft of this function.
    local cut_lo, cut_hi
    if peer_idx then
        -- Remove the LARGER index first so the smaller one's own index doesn't shift out from
        -- under it. `i` (the landing-spot reference for backspace below) becomes the lower of the
        -- two - "before the whole cut pair", the same convention a single-atom removal already
        -- uses for "before the removed atom".
        local lo, hi = math.min(victim_idx, peer_idx), math.max(victim_idx, peer_idx)
        cut_hi = table.remove(children, hi)
        cut_lo = table.remove(children, lo)
        i = lo
    else
        cut_lo = table.remove(children, victim_idx)
        i = victim_idx
    end
    -- `target`/`victim` are never read again below - only `cut_lo`/`cut_hi`, and only to pass to
    -- mexpru.cut() once it's actually safe to.

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
            -- Preceding sibling if there was one, else the horiz itself (the removed atom, or the
            -- cut pair's own lower index, was first) - matches where backspacing forward through
            -- plain text would leave you.
            if i > 1 then
                container.cursor_pos = vc.wref_mexpr(children[i - 1])
            else
                container.cursor_pos = vc.wref_mexpr(rebuilt)
            end
        end
        if cut_hi then mexpru.cut(cut_hi) end
        mexpru.cut(cut_lo)
    else
        local rebuilt = mexpru.horiz(fontset, children, horiz_sz)
        container.root = mexpru.propagate_rebuild(fontset, horiz, rebuilt)
        -- cursor_pos still names `target` itself, untouched by this edit (fwd_delete never cuts
        -- target - see this function's own comment on why victim/peer can't land on it) - still
        -- valid without reassignment: mexpru.horiz()/mexpr_merge_h re-parents its EXISTING
        -- children rather than recreating them, so target's own identity survives the rebuild.
        if cut_hi then mexpru.cut(cut_hi) end
        mexpru.cut(cut_lo)
    end
    container.version = (container.version or 0) + 1
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
at the outermost root, not per node. ]]
local function node_bbox(fontset, node)
    local pos = mexpru.u(node).pos
    local bb = vc.mexpr_get_bb(node)
    return {left = pos.x + bb.tl.x, right = pos.x + bb.br.x, top = pos.y + bb.tl.y, bottom = pos.y + bb.br.y}
end

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
have one. ]]
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
position), or `horiz` itself (position 0) if click is left of even the first child's own edge. ]]
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
    (over the sup/sub column) -> the supsub itself ("after the whole compound"). ]]
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

--[[ mformula.lua's hit_test() contract, adapted: mutates container.cursor_pos directly to the
result of hit_test_node()'s descent from root (same convention every move_* function already uses -
editor.lua just calls this now, no assignment, see its own call site's comment). `click` is {x,y},
relative to the SAME `pos` draw() takes (editor.lua's local_click = mpos - draw_x/draw_y, where
draw_x/draw_y IS that pos) - NOT yet in node_bbox()'s raw root-relative frame, since draw() shifts
`pos` by +baseline_correction(fontset, sz) before handing it to mexpr_draw. This function undoes
that shift on the way in, so hit_test_node()'s descent can compare against node_bbox() directly.
(Found live 2026-09-04: without this, every click's y landed outside the whole tree's own bounding
box, so hit_test_node()'s x-only margin fallback fired regardless of where vertically you clicked -
symptom was every click resolving to "right before \\int", no matter where on/under it you clicked.)
See this file's own hit_test_node()/target_before()/horiz_margin_target() comments for the full
algorithm.

wrap_width (2026-09-05, RELATIVE - editor.lua's own cached wrap_edge minus its own draw_x, since
`click` itself already arrives draw_x-relative - see this comment's own click paragraph) is
unwrap_point()'s own reverse of vc.mexpr_draw's wrap: a click that visually landed on some wrapped
row needs mapping back to "formula space" BEFORE hit_test_node()'s descent, which only ever knows
about unwrapped positions. nil means "never wraps", same convention as everywhere else here. ]]
function mformula_new.hit_test(container, fontset, sz, click, wrap_width)
    local raw_click = {x = click.x, y = click.y - baseline_correction(fontset, sz)}
    if wrap_width then
        local raw_bb = vc.mexpr_get_bb(container.root)
        local skipy = raw_bb.br.y - raw_bb.tl.y
        raw_click.x, raw_click.y = unwrap_point(raw_click.x, raw_click.y, wrap_width, skipy, raw_bb.tl.y)
    end
    container.cursor_pos = vc.wref_mexpr(hit_test_node(fontset, container.root, raw_click))
end

--[[ mformula.lua's reachable_graph() debug-overlay contract: {nodes, edges}. Honestly empty for
now - there's no move_left/move_right/move_vertical here yet for a BFS to drive, not a stand-in
pretending there's more to show. ]]
function mformula_new.reachable_graph(container, fontset, sz)
    return {nodes = {}, edges = {}}
end

--[[ mformula.lua's slot_markers() contract: a list of {x, y, w, h} rects, in the SAME root-relative
frame cursor_target()'s x/top/bottom already are - editor.lua adds its own content_x/y draw origin
on top. Only the "start" cases (cursor_pos on a horiz or an EMPTY atom - see cursor_target()'s own
comment) get a marker: neither paints anything of its own, so without one there'd be nothing to
click on at all. Once cursor_pos is on a SYMBOL atom, there's real ink to see and click already - a
marker there would draw an empty-atom-shaped outline right next to it, reading as "there's still an
empty box here" even though the tree itself has already moved on. `sz` (the outer/base level) isn't
actually used here anymore - the marker's own size comes from the NAMED node's own u(node).sz (see
cursor_target()'s comment on why), kept only for parity with the rest of this contract's signatures. ]]
function mformula_new.slot_markers(container, fontset, sz)
    local node = container.cursor_pos:get_obj()
    if node.type ~= vc.MEXPR_TYPE_EMPTY_BOX and mexpru.u(node).kind ~= "horiz" then
        return {}
    end
    local t = cursor_target(fontset, node)
    -- LOGICAL -> PHYSICAL before touching real font metrics (mexpru.rescale()'s own comment).
    local min = min_extent(fontset, mexpru.physical_sz(mexpru.u(node).sz))
    return {{x = t.x, y = t.top, w = min.width, h = t.bottom - t.top}}
end

-- LaTeX serialization lives in its own file (mformula_latex.lua) - re-exported here so editor.lua
-- (which only ever knows this module as `mformula`) doesn't need to require anything extra.
local mformula_latex = require("mformula_latex")
mformula_new.to_latex = mformula_latex.to_latex
mformula_new.from_latex = mformula_latex.from_latex

return mformula_new

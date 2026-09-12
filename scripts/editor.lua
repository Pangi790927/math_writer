--[[ ==================================== WHAT THIS FILE OFFERS ====================================

draw_formula(container: mformula.container, fontset: fontset, sz: size, origin: {x,y}, opts: table)
             -> {box, markers}
    Puts one formula on screen with everything around it - highlight,
    position graph, slot markers - in the one order they may be drawn in.
    `origin.y` is the BASELINE. See `opts` at the function itself.

formula_click_rect(box: mformula_new.box, markers: {marker}) -> l, r, t, b
    The rect a click must land in to count as inside this formula, as
    offsets from the draw origin. Covers the markers, not just the glyphs.

point_in_box(pos: {x,y}, hb: hitbox)    -> boolean
    A screen point against a drawn box. Inclusive on both edges, and
    false rather than an error when the box was never drawn.

formula_hit_test(container: mformula.container, fontset: fontset, sz: size, click: {x,y},
                 draw_x: number, draw_y: number, wrap_edge: number, extend: boolean) -> nothing
    Places the caret from a click, or extends a selection from a drag.
    Moves the container's cursor itself.

formula_node_at(container: mformula.container, fontset: fontset, sz: size, click: {x,y},
                draw_x: number, draw_y: number, wrap_edge: number) -> mexpr node | nil
    WHICH GLYPH the point is over. Touches neither cursor nor selection,
    and nil is a real answer.

edit_bracket(container: mformula.container, fontset: fontset, sz: size) -> changed
    One frame of input. True when the TREE changed, not when the cursor
    merely moved - the seam an owner's undo hangs off.

--- internal, not on the module table --------------------------------------------------------------
    DRAW_OPTS      every option draw_formula understands; a caller's key is checked
                   against it, since opts arrives already built
    in_formula_frame
@date 2026-09-12 01:25
================================================================================================= ]]

--[[
editor.lua - THE SHARED HALF of the editors: everything needed to render and drive ONE formula
sitting inside a box.

Four things live here - the selection highlight, the reachable-position graph, the wireframe view
and click-to-place-cursor - because they are what it takes to put an `mformula` container on screen
and let somebody work in it, and not one of them has anything to do with a character stream. All
three editors need exactly those four. That is the lesson the split was made of (2026-09-06, out of
the old editor.lua, the flat glyph-stream half going to editor_text.lua): editor_definition.lua was
written first without this file, on the reasoning that a definition box and a text box "share the
shape of their interface and none of their implementation", and shipped missing all four.

WHAT IS **NOT** HERE, deliberately:

  - **Undo/redo.** What a step even IS differs per owner: editor_text.lua snapshots its whole char
    stream alongside the formula, and a definition box has no stream to snapshot. `edit_bracket()`
    below is the seam - it reports whether a keystroke changed the tree, and each owner decides
    what to do about it.
  - **Layout.** Where a formula sits - inline in a text flow, or stacked as one of a definition's
    slots - is the owner's business entirely.

CONVENTIONS worth stating once, because both callers get them wrong otherwise:

  - `origin` is where mformula.draw() is told to draw: x is the left edge, **y is the BASELINE**.
    Not the top. A caller that has a top edge converts with mformula.measure()'s own `top`, which
    is negative (see editor_definition.lua's draw).
  - `wrap_edge` is an ABSOLUTE screen x - the right edge content may reach. mformula.hit_test()
    and cursor_box() want a RELATIVE width instead, and converting is this file's job, not the
    caller's. Getting that conversion wrong is a real past bug, recorded in editor_text.lua.

@date 2026-09-08 08:01
]]


local vc = require("virt_composer")
local mformula = require("mformula_new")
local mexpru = require("mexpru")
local sealed = require("sealed")

local editor = {}

--[[ The soft track under the reachable-position graph, and the outline on a slot marker. Both were
tuned against the text editor's background; they live here now so all three editors share one look
rather than drifting apart. @date 2026-09-08 08:01 ]]
local CURSOR_TRACK_COLOR = 0x8055cc55
local EMPTY_SLOT_COLOR   = 0xff888844

--[[ THE `opts` A DRAW TAKES - every option draw_formula understands, and nothing else.

Declared through sealed.lua and checked with `check_keys` rather than `wrap`: `opts` arrives already
built, as a table literal at each of the four call sites, so every key - misspelt ones included - is
present before a seal could fire on it. See sealed.check_keys for why that is a property of Lua
rather than a choice.

A misspelt option is not a harmless no-op: `active` misspelt makes a formula silently uneditable,
`wrap_edge` misspelt silently stops it wrapping.
@date 2026-09-12 15:30 ]]
local DRAW_OPTS = sealed.declare("editor", "draw opts", {
    active         = "this is the formula being edited - gates the caret, highlight, graph, markers",
    show_wireframe = "forwarded to mformula.draw: mexpr's own debug bounding boxes",
    show_graph     = "the reachable-position graph; ignored unless `active`",
    wrap_edge      = "ABSOLUTE right edge for wrapping, or nil for no wrap",
})

--[[ Draws one formula, with everything that goes around it, and returns what the caller needs to
route clicks into it:

    { box = <mformula.draw's return>, markers = <slot markers, or nil> }

`opts`:
    active          this is the formula being edited - gates the caret, the highlight, the graph
                    and the markers. Only one formula on screen should ever be active.
    show_wireframe  forwarded to mformula.draw (mexpr's own debug bounding boxes)
    show_graph      the reachable-position graph (below); ignored unless `active`
    wrap_edge       ABSOLUTE right edge for wrapping, or nil for no wrap

DRAW ORDER IS LOAD-BEARING and is the whole reason this is one function rather than three the
caller sequences itself. The highlight goes down first, then the graph, then the formula - so the
highlight ends up beneath the graph, the glyphs, the vert contours and the blinker, which is what
"under walk graph and under the mexpr drawing and under the blinker and anything else" asks for.
None of it can move inside mformula.draw(), because anything drawn in there is already on top of
the graph.
@date 2026-09-08 08:01 ]]
function editor.draw_formula(container, fontset, sz, origin, opts)
    --[[ Checked here because nothing below does: mformula's cursor_box, reachable_graph,
    slot_markers and draw all take the container and none of them checks it. ]]
    mexpru.check_container(container)
    assert(type(origin) == "table" and type(origin.x) == "number" and type(origin.y) == "number",
            "draw_formula needs an origin {x, y} - and y is the BASELINE, not the top")

    DRAW_OPTS.check_keys(opts, "opts")
    opts = opts or {}

    local x, y = origin.x, origin.y
    -- ABSOLUTE -> RELATIVE, once, here. See this file's header.
    local wrap_width = opts.wrap_edge and (opts.wrap_edge - x)
    local markers = nil

    if opts.active then
        --[[ The caret highlight. A LIST, outermost/faintest first - drawn in order, and the
        overlap is what feathers the edge, because ImGui has no blur (cursor_box()'s own comment).
        Active formula only: a soft pulse under every box's caret at once reads as clutter, and
        only one of them is where you are actually typing. ]]
        for _, hl in ipairs(mformula.cursor_box(container, fontset, sz, wrap_width)) do
            vc.ImGui_AddRectFilled({x = x + hl.x, y = y + hl.y}, {x = x + hl.x + hl.w,
                    y = y + hl.y + hl.h}, hl.color, hl.rounding)
        end

        if opts.show_graph then
            --[[ Every position any navigation key can reach - Left/Right within a row, Up/Down
            into a node's sup/sub - so navigation fixes can be checked by eye rather than only
            through the left-right chain. Drawn THROUGH the glyphs (each node sits exactly where
            that position's own blinker would), not as a strip underneath, so it reads as "these
            are the gaps between them".

            An edge is split only when its two ends really wrapped onto DIFFERENT ROWS, and the
            test is the nodes' own wrap `row`, NOT their y. Keying off y was flatly wrong: a
            superscript sits at a different y from its base on the SAME row, so every base<->sup
            edge got treated as a row crossing and shot a stub to the column edge. Reported live:
            "lines that wouldn't normaly intersect the edge now pass through to the edge". ]]
            local graph = mformula.reachable_graph(container, fontset, sz, wrap_width)
            --[[ The column the stubs are clamped to. col_r is only ever read on the
            row-crossing branch below, which cannot run without wrapping (with no wrap_edge every
            node is row 0), so the fallback is never actually used - it is here so the local is
            always a number rather than nil. ]]
            local col_l = x
            local col_r = opts.wrap_edge or x
            for _, e in ipairs(graph.edges) do
                local a, b = graph.nodes[e.a], graph.nodes[e.b]
                -- Earlier ROW first, so the stubs read in reading order.
                if (b.row or 0) < (a.row or 0) then
                    a, b = b, a
                end
                if (a.row or 0) == (b.row or 0) then
                    vc.ImGui_AddLine({x = x + a.x, y = y + a.y}, {x = x + b.x, y = y + b.y},
                            CURSOR_TRACK_COLOR, 2)
                else
                    -- Two ends of one connection, each clamped to its own row. Intermediate rows
                    -- are deliberately not filled: these edges only ever join positions adjacent
                    -- in reading order, at most one row apart.
                    vc.ImGui_AddLine({x = x + a.x, y = y + a.y}, {x = col_r, y = y + a.y},
                            CURSOR_TRACK_COLOR, 2)
                    vc.ImGui_AddLine({x = col_l, y = y + b.y}, {x = x + b.x, y = y + b.y},
                            CURSOR_TRACK_COLOR, 2)
                end
            end
            for _, n in ipairs(graph.nodes) do
                vc.ImGui_AddCircleFilled({x = x + n.x, y = y + n.y}, 4, CURSOR_TRACK_COLOR)
            end
        end

        --[[ Slot markers. Every row - the root included, since "past the whole formula" needs a
        marker too or that position is reachable by arrow keys but never by clicking - gets one
        right after its own content. Real and clickable either way, but otherwise invisible, so
        outlining them makes an empty slot ("click here to start") and a filled one ("room to keep
        typing") read the same way instead of only the empty one showing anything. ]]
        markers = mformula.slot_markers(container, fontset, sz)
        for _, mk in ipairs(markers) do
            vc.ImGui_AddRect({x = x + mk.x, y = y + mk.y}, {x = x + mk.x + mk.w,
                    y = y + mk.y + mk.h}, EMPTY_SLOT_COLOR, 2, 1)
        end
    end

    local box = mformula.draw(container, fontset, {x = x, y = y}, sz, opts.active,
            opts.show_wireframe, opts.wrap_edge)

    return {box = box, markers = markers}
end

--[[ The rect a click must land in to count as "inside this formula", in the formula's own
draw-origin frame: returns l, r, t, b as offsets from `origin`.

It has to cover every MARKER too, not just the content bbox - the root's trailing marker in
particular sticks out past `box.width` on purpose (see draw_formula above). Without that, clicking
a marker poking past the border reads as "outside" and deactivates the formula instead of
hit-testing into it.
@date 2026-09-08 08:01 ]]
function editor.formula_click_rect(box, markers)
    --[[ `markers` stays nil-tolerant: a formula that is not the active one is drawn without them,
    and every caller would otherwise guard for that itself. `box` is required - it is what the rect
    is derived from. ]]
    mformula.check_box(box)
    local l, r, t, b = 0, box.width, box.top, box.bottom
    if markers then
        for _, mk in ipairs(markers) do
            l = math.min(l, mk.x)
            r = math.max(r, mk.x + mk.w)
            t = math.min(t, mk.y)
            b = math.max(b, mk.y + mk.h)
        end
    end
    return l, r, t, b
end

--[[ Is a screen point inside a formula's click box?

THE SAME FOUR COMPARISONS were written out in every editor that hosts a formula - the text box, the
formula box, the definition's slots - and each of them keeps its boxes in the same shape already
(`{x, y, w, h, draw_x, draw_y, wrap_edge}`, built from editor.formula_click_rect above). So the shape
was shared and only the test was copied. Author, 2026-09-11: "more small functions not repeated the
better".

INCLUSIVE ON BOTH EDGES, which is what those copies did: a click exactly on the right edge of a
formula belongs to it. Nil-tolerant because a box that has not been drawn yet has no rectangle, and
every caller would otherwise guard for that itself.
@date 2026-09-11 21:40 ]]
function editor.point_in_box(pos, hb)
    --[[ NO TYPE CHECK HERE, deliberately, and it is the one function in this file with none. Both
    arguments are plain rectangles - `{x, y}` and `{x, y, w, h}` - assembled at half a dozen call
    sites and never a declared container, so there is nothing to check against that would not be
    invented on the spot. Nil is a real argument for either: a box that has not been drawn yet has
    no rectangle, and answering false is the whole reason this is nil-tolerant.

    Written out rather than as `(hb and pos) ~= nil`, which said the same thing and read as a
    mistake. ]]
    if not hb or not pos then
        return false
    end
    return pos.x >= hb.x and pos.x <= hb.x + hb.w
            and pos.y >= hb.y and pos.y <= hb.y + hb.h
end

--[[ A screen point in the formula's OWN frame, plus the wrap width in that frame.

ABSOLUTE -> RELATIVE, the same conversion draw_formula does: mformula never receives draw_x, because
the point is already relative to it by the time it gets there. Written once because both things a
pointer can do to a formula - place the caret, ask what is there - need exactly this and nothing
else. @date 2026-09-11 21:20 ]]
local function in_formula_frame(click, draw_x, draw_y, wrap_edge)
    return {x = click.x - draw_x, y = click.y - draw_y}, wrap_edge and (wrap_edge - draw_x)
end

--[[ Places the formula's cursor from a click (or extends a selection from a drag), given the
click in SCREEN coordinates and the origin the formula was drawn at.

`extend` true continues a drag rather than starting a fresh cursor. Mutates the container's
cursor directly - the same convention mformula's own move_*() uses - rather than returning a
position for the caller to assign.
@date 2026-09-08 08:01 ]]
function editor.formula_hit_test(container, fontset, sz, click, draw_x, draw_y, wrap_edge, extend)
    local local_click, wrap_width = in_formula_frame(click, draw_x, draw_y, wrap_edge)
    mformula.hit_test(container, fontset, sz, local_click, wrap_width, extend)
end

--[[ WHICH GLYPH a screen point is over, or nil. Touches neither the cursor nor the selection.

What a right-click asks, and a DIFFERENT question from the one above rather than half of it: a caret
click snaps to the nearest position and always lands, while this answers only for a glyph the point
is really on. Same frame conversion, different finder - mformula's glyph_at() carries the reasoning.
@date 2026-09-12 01:10 ]]
function editor.formula_node_at(container, fontset, sz, click, draw_x, draw_y, wrap_edge)
    local local_click, wrap_width = in_formula_frame(click, draw_x, draw_y, wrap_edge)
    return mformula.node_at(container, fontset, sz, local_click, wrap_width)
end

--[[ Runs one frame of input against a formula and reports whether the tree actually CHANGED, as
opposed to the cursor merely moving (arrows, a click). `container.version` is bumped by every real
tree edit, which is exactly that signal, so no caller has to re-derive "was this an edit".

The seam for undo: each owner decides what a step means for it. editor_text.lua snapshots its
whole char stream; a definition box has no equivalent yet, and what one should be is still open.
@date 2026-09-08 08:01 ]]
function editor.edit_bracket(container, fontset, sz)
    local pre_version = container.version
    mformula.handle_input(container, fontset, sz)
    return container.version ~= pre_version
end

return editor

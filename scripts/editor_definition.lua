--[[
editor_definition.lua - the editor inside a DEFINITION box (the green one).

A definition declares a name and its type: `f : R -> N`. The design (docs/phase2_design.md
sections 6 and 10, and the 2026-09-06 conversation that followed) settles its shape as **n+2
formula slots**:

    1  name pattern    the applied form, `f(x)` / `a_n` / `v_{max}` - which is what carries BOTH
                       the name and the notation it is written with
    n  parameter sets  one per parameter, each an expression denoting a set (`R`, `{g,e}`, ...)
    1  result type     the set an application lands in

and `n` is **derived, not entered**: mexpr_ast.parse_name() reads the name slot, counts its free
variables, and that count is the arity. The user never types a number, and the row reshapes itself
as the name changes.

A name is invalid for most of the time it is being typed, so the row **holds the last valid arity**
and marks the trouble instead of rearranging itself under the cursor: a red rule under the name
slot, plus per-character marks behind it (green read, blue unfinished, red the character that
breaks the rule).

After the whole signature comes a ";" and a generated SHORTHAND - `F : N^2 \times R^3 -> R^3` -
with runs of the same domain collapsed into powers. It is a real formula, focusable and copyable
(it yields "$$...$$" like any other), but not editable: it restates the cells, so anything typed
into it is discarded and it snaps back.

WHY THIS IS ITS OWN FILE: a definition box is not a text box. It has no character stream, no
lines, no wrapping between glyphs - it is a small fixed set of formula slots stacked down a box.
That part is genuinely its own.

WHAT IT SHARES, through `editor.lua`: everything involved in putting ONE formula on screen and
letting someone work in it - the caret/selection highlight, the reachable-position graph, the slot
markers, click-to-place-cursor. The first version of this file did NOT use any of that and simply
called mformula.draw() itself, which is why the definition box arrived with no selection, no graph
view, no boxes view and no clicking into it. If something here starts looking like it belongs to
"a formula in a box" rather than "a definition", it belongs in editor.lua.

@date 2026-09-08 08:12
]]

local vc = require("virt_composer")
local char = require("char")
local mformula = require("mformula_new")
local mexpru = require("mexpru")
local editor = require("editor")  -- the shared formula host; see its header
local mexpr_ast = require("mexpr_ast")
local keymap = require("keymap")

local editor_definition = {}

--[[ The signature is laid out on ONE line, reading the way it will be written:

        NAME  :  PARAM  ->  RETURNSET          with parameters
        NAME  \in  RETURNSET                   with none

so that what is on screen already looks like the thing being declared, rather than a stack of
anonymous boxes. The separators are DRAWN GLYPHS, not slots - they are punctuation, not something
to edit - and they come from the same Computer Modern catalog as everything else, so they sit on
the same baseline as the formulas beside them.

SLOTS ARE POSITIONAL: slots[1] is the name, slots[#slots] is the result, and everything between is
a parameter. So `#slots == n + 2`, which is the shape the design calls for, and the slot COUNT is
where the arity lives - there is no separate number to serialise and no way for the two to
disagree.

A parameter cell is a DOMAIN RESTRICTION written the way it is read - `n \in \N`, naming the
variable and the set it comes from - while the result cell holds the set alone. Cells are separated
by commas; the cartesian product appears only in the shorthand.

The `\in` form is the arity-0 case: `x \in R`, a plain named variable, with no parameters and no
shorthand (there is nothing to shorten).
@date 2026-09-08 08:12 ]]
local SLOT_GAP = 8      -- horizontal gap between a slot and the separator next to it
local LINE_GAP = 6      -- vertical gap between the signature row and the shorthand under it
--[[ How far a slot's field is drawn OUTSIDE the formula it holds, on every side. It is part of the
box's real ink, so the height reported back to content.lua has to include it on BOTH lines - it did
not, which is what made the content sit flush against the box border and read as overlapping the
next box. ]]
local FIELD_PAD = 3
--[[ DERIVED ROWS: the lines under the signature that are computed from it rather than typed.

    1  the shorthand      F : N^2 \times R^3 -> R^3
    2  the computed name  the pattern the parser read out of the name slot

`state.current` names whichever box has the caret. A real slot is a positive index into
`state.slots`; a derived row is the NEGATIVE of its index in `state.derived`, so -1 is the
shorthand and -2 the computed name. One number covers both, and every place that only cares about
slots can keep testing `> 0`.
@date 2026-09-08 08:12 ]]
local DERIVED_SHORTHAND = 1
local DERIVED_PATTERN   = 2
--[[ The arity a definition starts at, before anything has been typed. An empty name slot does not
parse, so there is nothing to derive from yet, and the box has to show SOMETHING: one parameter is
the shape a definition usually has, and the first valid name replaces it. ]]
local INITIAL_ARITY = 1

local SEP_COLON = ":"
local SEP_ARROW = "\\rightarrow"
local SEP_TIMES = "\\times"
local SEP_IN    = "\\in"
--[[ Parameter cells are DOMAIN RESTRICTIONS - one set per parameter - so they read as a list
and are separated by commas. The cartesian product appears only in the shorthand, where the
domains really are being multiplied together. ]]
local SEP_COMMA = ","

local SEP_COLOR       = 0xffdddddd
--[[ Drawn under the name slot while what is in it does not parse. ImGui packs 0xAABBGGRR, so this
is red (255,60,60). ]]
local INVALID_COLOR   = 0xff3c3cff
local INVALID_THICK   = 2

--[[ Per-character parse feedback, painted BEHIND the glyphs of the name slot. Requested
2026-09-07: "all the characters that where parsed in green, all in work in blue, the conflicting one
in red and the rest left alone".

  green  the parser read this and accepted it
  blue   this is inside something unfinished - an open bracket, an unterminated quote. Most of
         typing looks like this, so it must not read as an error.
  red    this is the character that breaks the rule
  (none) the parser never got here; deliberately unpainted, so "how far did it get" is visible

Low alpha: this sits under real glyphs and has to stay legible through them. Packing is 0xAABBGGRR
- get it backwards and green becomes a muddy blue.
@date 2026-09-08 08:12 ]]
local MARK_COLORS = {
    ok   = 0x5544cc44,   -- green (68,204,68)
    work = 0x66ff8844,   -- blue  (68,136,255)
    --[[ Noticeably more opaque than the other two. At the same alpha, red over the definition
    box's own green ground mixes to a muddy brown and stops reading as an error at all - and this
    is the one mark that has to be unmistakable. ]]
    bad  = 0xaa3c3cff,   -- red   (255,60,60)
}
--[[ Every slot gets a faint field behind it, whether or not it is the one being edited. Without it
an empty slot is literally invisible (slot markers only draw on the ACTIVE formula), and the box
reads as punctuation floating in space rather than as three things you can click. ]]
local SLOT_BG_COLOR   = 0x22ffffff
local SLOT_EDGE_COLOR = 0x66ffffff

--[[ A fresh, empty definition. The slots are NOT built here: constructing a formula needs a
fontset, and content.lua's insert_box() has never taken one (content.new(), deserialize() and every
test call it without). ensure() below fills them in on the first draw or keystroke, both of which
have a fontset to hand.
@date 2026-09-08 08:12 ]]
function editor_definition.new()
    return {
        undo = {},        -- stack of snapshots, newest last
        redo = {},        -- what undo popped, so it can be put back
        baseline = nil,   -- the pre-edit snapshot, CACHED - see begin_edit()
        slots = nil,
        current = 1,      -- which box has the caret: a POSITIVE index into slots, or the negative
                          -- of an index into `derived` (-1 the shorthand, -2 the computed name),
                          -- so one number covers both and everything that only cares about slots
                          -- tests `> 0`.
        hitboxes = nil,   -- per-slot click geometry, rebuilt by draw() and read by handle_input()
                          -- on the NEXT frame. Same one-frame-behind arrangement content.lua uses
                          -- for its own box layout; imperceptible, and it avoids measuring twice.
        dragging = nil,   -- the slot a drag-select started in, so the drag keeps extending in it
                          -- even once the pointer leaves.
    }
end

--[[ Builds the slots if they are missing, and returns them. Idempotent, and safe to call every
frame. Built at mexpru.DEFAULT_SIZE - the fixed LOGICAL size every new formula is created at, with
zoom applied globally on top of it (see mexpru.DEFAULT_SIZE's own comment); NOT the caller's live
font size, which already has zoom folded in and would double-count it.
@date 2026-09-08 08:12 ]]
local function ensure(state, fontset)
    state.slots = state.slots or {}
    --[[ 1 name + n parameters + 1 result. Grows the list rather than replacing it, so a document
    saved when a definition had a different arity keeps whatever it had - the SLOT COUNT is where
    arity is stored, so there is no separate number to serialise and no way for the two to
    disagree. ]]
    --[[ ONLY fills in what is missing to make a usable row; it must NOT enforce a minimum arity,
    because the slot count IS the arity and sync_arity() below is what sets it. An earlier version
    padded up to INITIAL_ARITY + 2 on every frame, which silently undid every shrink: typing a
    name of arity 0 trimmed the row to two slots and the next frame put the third back.

    A brand-new definition starts at INITIAL_ARITY; anything that already has a name and a result
    keeps exactly the slots it has. ]]
    local want = (#state.slots == 0) and (INITIAL_ARITY + 2) or 2
    while #state.slots < want do
        table.insert(state.slots, mformula.new(fontset, mexpru.DEFAULT_SIZE))
    end
    return state.slots
end

-- ################################################################################################
-- The shorthand
-- ################################################################################################

--[[ The SET a domain cell restricts to.

A parameter cell is a domain restriction written the way it is read - `n \in \N`, naming the
variable and the set it comes from - so the shorthand, which is about the domain alone, has to take
what follows the membership sign. A cell with no `\in` is read as a bare set, which is what the
RESULT cell contains (`\R ^{2}`, not `y \in \R ^{2}`).

Textual, on the LaTeX, and it will not survive contact with anything clever: it takes what follows
the LAST `\in`, so a set that itself mentions membership would confuse it. That is the same
provisional footing the run-grouping below is on, and it goes away together with it once
docs/phase2_design.md section 9's structural equality exists. ]]
local function domain_set(tex)
    local after = tex:match("^.*" .. "\\in%s*(.*)$")
    -- Parenthesised on purpose: gsub returns the string AND a replacement count, and letting both
    -- escape would spread into whatever the caller does with the result.
    return ((after or tex):gsub("%s+$", ""))
end

--[[ The compact restatement of the signature as LaTeX, or nil when there is no honest one to
show - arity 0, an unparsed name, a domain still empty:

    NAME : R , R , N -> R        becomes        NAME : R^{2} \times N -> R

Runs of the SAME domain collapse into a power, which is the whole point of it: a function of four
reals reads as `R^4` rather than as four cells you have to count. Requested 2026-09-07, with the
example `F : N^2 x R^2 -> R^3`.

Built as a STRING and handed to from_latex() rather than laid out by hand, and that is what keeps
it a real formula: it goes through the same layout as everything else - a real superscript, real
spacing, the same fonts - so the only new code here is the string.

Domains are compared BY THEIR LaTeX, textually, rather than by the structural equality of
docs/phase2_design.md section 9, which does not exist yet. Until it does, two spellings of one set
do not collapse together.
@date 2026-09-08 08:12 ]]
local function shorthand_latex(state)
    local slots = state.slots
    local nparams = #slots - 2
    if nparams < 1 or not state.pattern then
        -- Arity 0 already renders as `NAME \in RET`, which is as short as it gets.
        return nil
    end

    local parts = {}
    local run_tex, run_len = nil, 0
    local function flush()
        if run_tex then
            parts[#parts + 1] = (run_len > 1) and (run_tex .. "^{" .. run_len .. "}") or run_tex
            run_tex, run_len = nil, 0
        end
    end

    for i = 2, #slots - 1 do
        local tex = domain_set(mformula.to_latex(slots[i]))
        if tex == "" then
            -- A domain not filled in yet: there is no honest shorthand to show.
            return nil
        end
        if tex == run_tex then
            run_len = run_len + 1
        else
            flush()
            run_tex, run_len = tex, 1
        end
    end
    flush()

    local ret = domain_set(mformula.to_latex(slots[#slots]))
    if ret == "" then
        return nil
    end

    --[[ The NAME alone, never the applied pattern: a signature is `F : ...`, not `F(x,y) : ...`.
    state.pattern.name is what mexpr_ast.parse_name() read. ]]
    --[[ DOUBLE backslashes. These are LaTeX macros being built as Lua string literals, and Lua
    reads `\t` as a tab and `\r` as a carriage return - written singly, the shorthand rendered as
    "N^2 imes R" and "N ightarrow R", the macro names with their first letter eaten. ]]
    return state.pattern.name .. ":" .. table.concat(parts, "\\times ")
            .. "\\rightarrow " .. ret
end

--[[ The COMPUTED NAME: what the parser actually made of the name slot, as its pattern string -
`a,sub,(1),sub,(2)` for `a_{n_{m}}`, `f(),(1),(2),(3)` for `f(x,y,z)`. The name with its argument
positions numbered, which is what a definition IS (2026-09-07: "this is the name with the two
arguments possible, this is what a definition is, a pattern").

Held from the last VALID parse, like the arity: while a name is being typed it does not parse, and
blanking the row on every keystroke would make it useless exactly when you are watching it.
@date 2026-09-08 08:12 ]]
local function pattern_latex(state)
    return state.pattern and state.pattern.text or nil
end

--[[ Rebuilds each derived row, and only when the string it would draw actually changes - otherwise
this is a from_latex() per row per frame, and each is a full tree build.

Every row is built the same way, from a LaTeX string, which is what keeps them real formulas: they
render through the same layout as everything else and can be selected and copied like any other.
They are not editable - see handle_input.
@date 2026-09-08 08:12 ]]
local function sync_derived(state, fontset)
    state.derived = state.derived or {}
    local want = {
        [DERIVED_SHORTHAND] = shorthand_latex(state),
        [DERIVED_PATTERN]   = pattern_latex(state),
    }
    for i = 1, 2 do
        local row = state.derived[i]
        if not row then
            row = {}
            state.derived[i] = row
        end
        if row.tex ~= want[i] then
            row.tex = want[i]
            row.c = want[i] and mformula.from_latex(fontset, mexpru.DEFAULT_SIZE, want[i]) or nil
            row.hit = nil
        end
    end
end

--[[ The container a `current` value names, or nil. Positive is a slot, negative a derived row. ]]
local function current_container(state)
    if state.current > 0 then
        return state.slots and state.slots[state.current]
    end
    local row = state.derived and state.derived[-state.current]
    return row and row.c
end

-- ################################################################################################
-- Undo
-- ################################################################################################

--[[ A definition box had NO undo at all until 2026-09-07, which is what "ctrl+z doesn't work on
hats" turned out to be: hats were simply what got tried first. Nothing in here is specific to
accents.

A snapshot is a clone of every slot plus which one had the caret. mformula.clone() is a real
structural copy (rescale_node()), so a restored slot is independent of the one it replaced -
including its dresses, which clone rebuilds through mexpru.redress() rather than losing.

Kept SEPARATE from editor_text.lua's undo rather than shared, because the two are snapshots of
different things: that one captures a character stream with formulas embedded in it, this one
captures a fixed set of formula slots. What they share - "did this keystroke change the tree" - is
already in editor.lua as edit_bracket().
@date 2026-09-08 08:12 ]]
local MAX_UNDO = 200

local function snapshot(state, fontset)
    local slots = {}
    for i, slot in ipairs(state.slots or {}) do
        slots[i] = mformula.clone(slot, fontset)
    end
    return {slots = slots, current = state.current}
end

local function restore(state, snap)
    state.slots = snap.slots
    state.current = math.min(snap.current or 1, #snap.slots)
    --[[ The name may have changed back to something with a different arity, so the row has to be
    re-derived. The version of a RESTORED clone is not comparable with what was parsed before it,
    so the cached parse is dropped outright rather than compared. ]]
    state.parsed_version = nil
    state.hitboxes = nil
end

--[[ Makes sure a pre-edit baseline exists, and caches it.

Cached rather than rebuilt per frame for the same reason editor_text.lua caches its own: this runs
on every frame a definition box is active, and taking a snapshot unconditionally means cloning
every slot ~60 times a second to throw all but one away. editor_text.lua's own comment records that
that made the editor visibly lag once ("it lags a lot"). ]]
local function begin_edit(state, fontset)
    if not state.baseline then
        state.baseline = snapshot(state, fontset)
    end
end

--[[ Files the cached baseline as one undo step. Called only where a keystroke really changed the
tree, so moving the caret never costs a step. @date 2026-09-08 08:12 ]]
local function commit_edit(state)
    if not state.baseline then
        return
    end
    state.undo[#state.undo + 1] = state.baseline
    if #state.undo > MAX_UNDO then
        table.remove(state.undo, 1)
    end
    state.baseline = nil        -- the tree just changed; any cached one is stale
    state.redo = {}             -- a fresh edit forks history, the same as everywhere else
end

--[[ Moves one step between the two stacks, pushing the CURRENT state onto the other one first so
the move is itself reversible. Returns whether there was anything to move. @date 2026-09-08 08:12 ]]
local function undo_or_redo(state, fontset, want_redo)
    local from = want_redo and state.redo or state.undo
    local to = want_redo and state.undo or state.redo
    local snap = table.remove(from)
    if not snap then
        return false
    end
    to[#to + 1] = snapshot(state, fontset)
    restore(state, snap)
    state.baseline = nil
    return true
end

--[[ Re-checks every PARAMETER cell. Each must be a membership and nothing else -
`<name> \in <set>` - because a parameter cell is a domain restriction: it names the variable and
the set it is drawn from. Requested 2026-09-07: "the param boxes should reject anything else than
apartenance of named to set".

Same shape as the name check: cached against each cell's own `version`, so a cell is only re-parsed
when it actually changes, and the outcome is per-cell rather than one flag for the box - the whole
point is to point at WHICH cell is wrong.

Unlike the name, an invalid parameter changes nothing structural. Arity comes from the name alone,
so a half-typed domain never reshapes the row; it only marks itself.
@date 2026-09-08 08:12 ]]
local function sync_domains(state, fontset)
    state.slot_invalid = state.slot_invalid or {}
    state.slot_marks = state.slot_marks or {}
    state.slot_parsed = state.slot_parsed or {}
    for i = 2, #state.slots - 1 do
        local cell = state.slots[i]
        local ver = cell.version or 0
        if state.slot_parsed[i] ~= ver then
            state.slot_parsed[i] = ver
            local ok, err, _, marks = mexpr_ast.parse_domain(fontset, cell)
            state.slot_invalid[i] = (not ok) and (err or "not a membership") or nil
            --[[ On SUCCESS the marks ride on the result table; only a FAILURE returns them as the
            fourth value. Reading just the fourth meant a cell that parsed cleanly showed no green
            at all - the marks were being produced and thrown away. ]]
            state.slot_marks[i] = ok and ok.marks or marks
        end
    end
    -- Slots that no longer exist must not keep stale verdicts: an arity change reuses indices.
    for i = #state.slots, #state.slot_parsed do
        state.slot_invalid[i] = nil
        state.slot_marks[i] = nil
        state.slot_parsed[i] = nil
    end
end

--[[ Re-derives the arity from the NAME slot, and reshapes the row to match.

The rule, stated 2026-09-07: **hold the last valid arity until the name parses again.** A name is
invalid for most of the time it is being typed (`f(` on the way to `f(x)`), and slots appearing and
vanishing under the cursor on the way there would be unusable. So nothing about the row changes
until the name is a name again; while it is not, the only feedback is a red line under it.

Cheap enough to call every frame: it re-parses only when the name slot's own `version` has moved,
which is bumped by every real tree edit and by nothing else.
@date 2026-09-08 08:12 ]]
local function sync_arity(state, fontset)
    local name = state.slots[1]
    local ver = name.version or 0
    if state.parsed_version == ver then
        return
    end
    state.parsed_version = ver

    --[[ Marks ride on the result table when the parse SUCCEEDS and come back as the fourth value
    when it fails - see sync_domains(). Taking both is what makes a valid name paint green rather
    than paint nothing. ]]
    local pat, err, _, marks = mexpr_ast.parse_name(fontset, name)
    marks = (pat and pat.marks) or marks
    --[[ Marks come back on BOTH paths and are always taken: they describe how far this parse got,
    which is the thing worth seeing precisely when it did not finish. Unlike the arity, they are
    NOT held from the last valid parse - they describe what is on screen right now. ]]
    state.marks = marks
    if not pat then
        --[[ Invalid: the row keeps the shape it had. `pattern` is deliberately NOT cleared - it is
        the last thing that DID parse, and holding it is what "hold the last valid arity" means. ]]
        state.invalid = err or "not a name"
        return
    end
    state.invalid = nil
    state.pattern = pat

    local want = pat.arity + 2
    if #state.slots == want then
        return
    end

    --[[ Reshape around the ends: the name and the result type are what the user typed and must
    survive an arity change untouched. Only the middle is added to or trimmed, and trimming takes
    from the END so the parameters that stay keep their own slots (and whatever is in them). ]]
    local first, last = state.slots[1], state.slots[#state.slots]
    local params = {}
    for i = 2, #state.slots - 1 do
        params[#params + 1] = state.slots[i]
    end
    while #params > pat.arity do
        table.remove(params)
    end
    while #params < pat.arity do
        params[#params + 1] = mformula.new(fontset, mexpru.DEFAULT_SIZE)
    end

    local rebuilt = {first}
    for _, sl in ipairs(params) do
        rebuilt[#rebuilt + 1] = sl
    end
    rebuilt[#rebuilt + 1] = last
    state.slots = rebuilt

    -- The caret may have been in a slot that no longer exists. A derived row is a NEGATIVE index
    -- and must survive this untouched.
    if state.current > 0 and state.current > #state.slots then
        state.current = #state.slots
    end
    state.hitboxes = nil
end

--[[ The row to draw: slot, separator, slot, ... - derived from how many slots there are, never
stored. `n == 0` is the plain-variable form (`x \in R`); otherwise the parameters are joined with
`\times` and the result is introduced by `->`.
@date 2026-09-08 08:12 ]]
local function signature_row(nslots)
    local nparams = nslots - 2
    local row = {{slot = 1}}
    if nparams <= 0 then
        row[#row + 1] = {glyph = SEP_IN}
    else
        row[#row + 1] = {glyph = SEP_COLON}
        for i = 1, nparams do
            if i > 1 then
                row[#row + 1] = {glyph = SEP_COMMA}
            end
            row[#row + 1] = {slot = 1 + i}
        end
        row[#row + 1] = {glyph = SEP_ARROW}
    end
    row[#row + 1] = {slot = nslots}
    return row
end

--[[ Draws every slot down the box from `pos`, and returns the total content height so the caller
can size the box around it.

mformula's measure()/draw() work in a BASELINE frame: `top` is NEGATIVE (how far the content
reaches above the baseline) and `bottom` positive. So a slot whose top edge should land at `y` is
drawn with its baseline at `y - m.top`, and occupies `m.bottom - m.top`. Getting that backwards
puts the formula above its own box, which is exactly what it looks like.

It also records the click geometry every frame - `state.hitboxes` per slot, `row.hit` per derived
row - because handle_input() runs in a separate call and cannot re-derive where anything landed.

  pos             top-left of the content; each line's baseline comes from its own measure
  sz              the logical size to draw at
  width_limit     how far right a DERIVED row may reach; the signature line is never wrapped
  show_cursor     this box is the active one: outlines the current slot and draws its caret
  show_wireframe  passed through to editor.draw_formula (mexpr's debug boxes)
  show_graph      passed through: the reachable-position graph
@date 2026-09-08 08:12 ]]
function editor_definition.draw(state, fontset, pos, sz, width_limit, show_cursor,
        show_wireframe, show_graph)
    local slots = ensure(state, fontset)
    sync_arity(state, fontset)
    slots = state.slots
    sync_domains(state, fontset)
    sync_derived(state, fontset)
    local row = signature_row(#slots)

    --[[ Pass 1: measure every piece and find the line's common extent. The whole signature shares
    ONE baseline - a `:` sitting at a different height from the name beside it is exactly what this
    avoids - so the tallest piece decides where that baseline falls.

    Formulas are measured with NO wrap width: a signature is one line by construction. If a long
    one ever needs to fold, that is a layout decision to take deliberately, not something to
    inherit by accident from passing width_limit through here. ]]
    local top, bottom = 0, 0
    for _, piece in ipairs(row) do
        if piece.slot then
            local m = mformula.measure(slots[piece.slot], fontset, sz, nil)
            piece.w, piece.top, piece.bottom = m.width, m.top, m.bottom
        else
            local g = char.find_by_desc(piece.glyph)
            local gs = fontset:char_get_sz({size = sz, code = g.ncod})
            -- tr is the TOP corner and bl the BOTTOM one (screen y grows down), the same way
            -- mformula's own line metrics read them.
            piece.ncod = g.ncod
            piece.w, piece.top, piece.bottom = gs.adv, gs.tr.y, gs.bl.y
        end
        top = math.min(top, piece.top)
        bottom = math.max(bottom, piece.bottom)
    end

    -- Pass 2: place everything left to right on that baseline.
    --[[ + FIELD_PAD: the fields are drawn from `top - pad`, so without this the first line's field
    would start ABOVE pos.y and eat into the box's own padding. ]]
    local baseline = pos.y + FIELD_PAD - top
    local x = pos.x
    local hitboxes = {}
    for _, piece in ipairs(row) do
        if piece.slot then
            local active = show_cursor and piece.slot == state.current
            --[[ Which cell, if any, failed to parse. Computed before the marks below because it
            GATES them. ]]
            local slot_bad = (piece.slot == 1) and state.invalid
                    or (state.slot_invalid and state.slot_invalid[piece.slot])

            --[[ Parse feedback goes down BEFORE the formula, so the glyphs sit on top of it rather
            than under it. The name slot gets it from the name parse; every PARAMETER cell gets it
            from its own domain parse. The result cell is not parsed - it is a bare set, and there
            is no expression parser yet to judge one.

            ONLY ON A CELL THAT IS WRONG. These marks answer "how far did it get and where does it
            break", which is a question worth answering while something needs fixing and noise the
            rest of the time - a cell that parses cleanly is left alone. Verbatim, 2026-09-07: "I
            only wanted to know what was good in a formula and what was bad when I had to fix it".
            So the green is not a badge for a correct cell; it is context around a red one. ]]
            local marks = slot_bad and ((piece.slot == 1) and state.marks
                    or (state.slot_marks and state.slot_marks[piece.slot]))
            if marks then
                local nodes = {}
                for _, m in ipairs(marks) do
                    nodes[#nodes + 1] = m.node
                end
                local rects = mformula.node_rects(fontset, nodes)
                for i, rc in ipairs(rects) do
                    local color = rc and MARK_COLORS[marks[i].status]
                    if color then
                        vc.ImGui_AddRectFilled({x = x + rc.x, y = baseline + rc.y},
                                {x = x + rc.x + rc.w, y = baseline + rc.y + rc.h}, color, 2)
                    end
                end
            end
            --[[ The field behind the slot, drawn BEFORE the formula so the glyphs land on top of
            it. Outlined only for the slot being edited, so which one has the caret reads even
            when it is empty and there is no caret to see. ]]
            local pad = FIELD_PAD
            vc.ImGui_AddRectFilled({x = x - pad, y = baseline + top - pad},
                    {x = x + math.max(piece.w, 6) + pad, y = baseline + bottom + pad},
                    SLOT_BG_COLOR, 3)
            if active then
                vc.ImGui_AddRect({x = x - pad, y = baseline + top - pad},
                        {x = x + math.max(piece.w, 6) + pad, y = baseline + bottom + pad},
                        SLOT_EDGE_COLOR, 3, 1)
            end
            local r = editor.draw_formula(slots[piece.slot], fontset, sz, {x = x, y = baseline}, {
                active = active,
                show_wireframe = show_wireframe,
                show_graph = show_graph,
            })
            --[[ The click target, in screen coordinates, including any markers poking past the
            content (editor.formula_click_rect's own comment). Recorded for EVERY slot, not just
            the active one - clicking an inactive slot is how the caret gets into it, which is the
            whole point of "all clickable". ]]
            local l, rr, t, b = editor.formula_click_rect(r.box, r.markers)
            hitboxes[piece.slot] = {
                x = x + l - pad, y = baseline + t - pad,
                w = (rr - l) + 2 * pad, h = (b - t) + 2 * pad,
                draw_x = x, draw_y = baseline,
            }
            --[[ The name slot, while what is in it does not parse: a red rule under it. The only
            feedback there is, deliberately - the row itself does not move while a name is being
            typed (sync_arity's own comment), so this is what says "the shape you can see is the
            last one that made sense, not this one". ]]
            if slot_bad then
                local uy = baseline + bottom + pad + 1
                vc.ImGui_AddLine({x = x - pad, y = uy},
                        {x = x + math.max(piece.w, 6) + pad, y = uy},
                        INVALID_COLOR, INVALID_THICK)
            end
        else
            fontset:char_draw({size = sz, code = piece.ncod}, {x = x, y = baseline},
                    SEP_COLOR, false, 0)
        end
        x = x + math.max(piece.w, 6) + SLOT_GAP
    end

    state.hitboxes = hitboxes

    --[[ THE DERIVED ROWS, each on its own line under the signature: the shorthand, then the
    computed name. Each is an ordinary box like the slots - same field behind it, same
    click-to-place-caret, same drag-to-select-part-of-it - and the ONLY difference is that edits are
    discarded (handle_input), because they are computed from the cells above rather than typed.

    Requested 2026-09-07: "I want it bellow, on the next line ... in a normal math box ... just do
    one of those boxes without allowing the modification of the mexpr", then "I want a third row
    with the computed name". The first version put the shorthand inline after a ";" and made a click
    select the whole thing, which meant parts of it could not be selected at all. ]]
    local total_h = (bottom - top) + 2 * FIELD_PAD
    local pad = FIELD_PAD
    for i, row in ipairs(state.derived or {}) do
        if row.c then
            local row_y = pos.y + total_h + LINE_GAP
            local m = mformula.measure(row.c, fontset, sz, width_limit)
            local row_baseline = row_y + pad - m.top
            local active = show_cursor and state.current == -i
            vc.ImGui_AddRectFilled({x = pos.x - pad, y = row_baseline + m.top - pad},
                    {x = pos.x + math.max(m.width, 6) + pad, y = row_baseline + m.bottom + pad},
                    SLOT_BG_COLOR, 3)
            if active then
                vc.ImGui_AddRect({x = pos.x - pad, y = row_baseline + m.top - pad},
                        {x = pos.x + math.max(m.width, 6) + pad, y = row_baseline + m.bottom + pad},
                        SLOT_EDGE_COLOR, 3, 1)
            end
            local r = editor.draw_formula(row.c, fontset, sz, {x = pos.x, y = row_baseline}, {
                active = active,
                show_wireframe = show_wireframe,
                show_graph = show_graph,
                wrap_edge = pos.x + width_limit,
            })
            local l, rr, t, b = editor.formula_click_rect(r.box, r.markers)
            row.hit = {
                x = pos.x + l - pad, y = row_baseline + t - pad,
                w = (rr - l) + 2 * pad, h = (b - t) + 2 * pad,
                draw_x = pos.x, draw_y = row_baseline, wrap_edge = pos.x + width_limit,
            }
            total_h = total_h + LINE_GAP + (m.bottom - m.top) + 2 * pad
        else
            row.hit = nil
        end
    end

    return total_h
end

--[[ One frame of input for the definition: route a click or drag to whichever slot it landed in,
then hand the frame to the slot that has the caret.

Returns true if the keystroke actually CHANGED a slot's tree, as opposed to only moving the
cursor. That is the signal undo is built on - here through begin_edit/commit_edit below, in
editor_text.lua through its own snapshots - and it is handed back to the caller as well, so
content.lua can tell an edit from a click without re-deriving it.
@date 2026-09-08 08:12 ]]
function editor_definition.handle_input(state, fontset, sz)
    local slots = ensure(state, fontset)

    --[[ Undo and redo, checked before anything else so they work wherever the caret is, and redo
    first - the same placement, the same bindings and the same order editor_text.lua uses, so the
    two boxes cannot disagree about what undo means. ]]
    if keymap.pressed("edit.redo") then
        undo_or_redo(state, fontset, true)
        return false
    end
    if keymap.pressed("edit.undo") then
        undo_or_redo(state, fontset, false)
        return false
    end

    local down = vc.ImGui_IsMouseDown("ImGuiMouseButton_Left")
    if not down then
        state.dragging = nil
    end
    -- NOTE: `dragging` holds a box index, which for a derived row is NEGATIVE - truthy in Lua, so
    -- the `state.dragging ~= nil` tests below stay correct. Do not "simplify" them to `if
    -- state.dragging then`; it happens to work and stops working the moment 0 becomes a valid
    -- index again.

    --[[ CLICK ROUTING FIRST, for every target, THEN dispatch to whatever ended up current.

    The order matters and getting it wrong is what "I can't deselect it" was: the shorthand's own
    input handling used to run before the slot hit-testing and return immediately, so once the caret
    was in the shorthand every later click was swallowed before the slots were ever considered -
    nothing could take focus back off it. Routing decides WHERE input goes; dispatch then sends it
    there. Nothing between the two may return. ]]
    local function inside(mp, hb)
        return hb and mp.x >= hb.x and mp.x <= hb.x + hb.w
                and mp.y >= hb.y and mp.y <= hb.y + hb.h
    end

    --[[ Every clickable box, in one list, so the shorthand is routed exactly like a slot: click to
    place the caret, drag to select PART of it. It is only special at dispatch, where an edit to it
    is discarded. A derived row's index is NEGATIVE, which is why the container comes from the entry
    rather than from slots[idx]. ]]
    local function click_targets()
        local t = {}
        for i, hb in ipairs(state.hitboxes or {}) do
            t[#t + 1] = {idx = i, hb = hb, container = slots[i]}
        end
        for i, row in ipairs(state.derived or {}) do
            if row.c and row.hit then
                t[#t + 1] = {idx = -i, hb = row.hit, container = row.c}
            end
        end
        return t
    end

    local clicked = vc.ImGui_IsMouseClicked("ImGuiMouseButton_Left", false)
    if clicked or (down and state.dragging) then
        local mp = vc.ImGui_GetMousePos()
        local targets = click_targets()
        local hit
        if clicked then
            for _, t in ipairs(targets) do
                if inside(mp, t.hb) then
                    hit = t
                    break
                end
            end
        else
            for _, t in ipairs(targets) do
                if t.idx == state.dragging then
                    hit = t
                    break
                end
            end
        end
        if hit then
            --[[ A fresh click places the caret; continuing a drag EXTENDS the selection from where
            it started, which is why `dragging` remembers WHICH box rather than re-hit-testing every
            frame - a drag that wanders out of the box must keep extending inside it, not jump to
            whatever is under the pointer. ]]
            state.current = hit.idx
            editor.formula_hit_test(hit.container, fontset, sz, mp, hit.hb.draw_x, hit.hb.draw_y,
                    hit.hb.wrap_edge, state.dragging ~= nil and not clicked)
            state.dragging = hit.idx
        end
    end

    --[[ Leaving the shorthand DESELECTS it. Its selection lives in the container itself, so
    without this the highlight stays painted after focus has moved on and the shorthand goes on
    looking selected when it is not - which is half of what "I can not deselect it" was. Done here,
    unconditionally, so the highlight can never outlive the focus regardless of how focus moved. ]]
    for i, row in ipairs(state.derived or {}) do
        if row.c and state.current ~= -i then
            row.c.sel_anchor = nil
        end
    end

    --[[ The shorthand can also be left by keyboard: Escape puts the caret back in the name slot.
    Without it, a definition reached entirely by keyboard could be entered and not left. ]]
    if state.current < 0 and keymap.pressed("definition.exit_slot") then
        state.current = 1
        return false
    end

    if state.current < 0 then
        local row_c = current_container(state)
        if not row_c then
            -- It went away (a cell was emptied); the caret cannot stay in something not drawn.
            state.current = 1
        else
            --[[ Selection, navigation and Ctrl+C all work because mformula handles them. An EDIT
            is discarded instead of kept: the shorthand is derived from the cells, so the only
            honest response to typing into it is to put back what the cells say. Clearing the cached
            string is what makes sync_shorthand() rebuild it on the next frame. ]]
            if editor.edit_bracket(row_c, fontset, sz) then
                state.derived[-state.current].tex = nil
            end
            return false
        end
    end

    --[[ One undo step per keystroke that actually CHANGED the tree - cursor movement and clicks
    do not make steps. edit_bracket() (editor.lua) is what draws that line, by reporting whether the
    container's own version moved. ]]
    begin_edit(state, fontset)
    local cur = slots[state.current] or slots[1]
    local changed = editor.edit_bracket(cur, fontset, sz)
    if changed then
        commit_edit(state)
    end
    return changed
end

--[[ After a zoom change, so already-built content catches up with the new size rather than only
newly-typed content being affected (mformula.rescale()'s own comment). ]]
function editor_definition.rescale(state, fontset)
    if not state.slots then
        return
    end
    for _, slot in ipairs(state.slots) do
        mformula.rescale(slot, fontset)
    end

    --[[ EVERY CACHED NODE REFERENCE IS NOW STALE. mformula.rescale() rebuilds a container's tree
    out of NEW nodes (rescale_node()); it does not resize the old ones in place. So anything holding
    on to nodes from before the zoom is pointing at a discarded tree, and those nodes keep their old
    positions - which is exactly what the parse marks did: after a zoom the green/red rectangles
    stayed at the pre-zoom size and offset while the glyphs moved, so they no longer covered the
    characters they described.

    Dropping the cached parse (rather than trying to remap the nodes) is the honest fix: re-parsing
    is cheap, happens once per zoom, and cannot go subtly wrong the way a remap could. Clearing the
    version stamps is what makes sync_arity()/sync_domains() actually redo the work - they skip when
    the stamp matches, and a rescale does not bump a container's `version`. ]]
    state.marks = nil
    state.parsed_version = nil
    state.slot_marks = {}
    state.slot_parsed = {}
    state.hitboxes = nil

    --[[ The derived rows are NOT among the slots, so the loop above never reached them - after a
    zoom they were left drawn at the old size next to text that had moved. Rebuilt rather than
    rescaled, since they are generated from strings anyway: dropping them is what makes
    sync_derived() build fresh ones at the new size on the next frame. ]]
    state.derived = nil
    if state.current < 0 then
        -- The caret cannot stay in a container that is about to be replaced.
        state.current = 1
    end
end

--[[ The whole definition as text, for saving: a length-prefixed LIST of slot LaTeX, counted up
front.

    <count>\n  then count times  <len>\n<latex>

Length-prefixed rather than delimited for the same reason content.lua's own box list is: a LaTeX
string can contain any character, so no separator is guaranteed not to collide with real content.
The COUNT is also where the arity lives - there is no separate number written down, so a saved
definition cannot disagree with itself about how many parameters it has.
@date 2026-09-08 08:12 ]]
function editor_definition.to_text(state)
    local slots = state.slots or {}
    local parts = {tostring(#slots), "\n"}
    for _, slot in ipairs(slots) do
        local latex = mformula.to_latex(slot)
        parts[#parts + 1] = tostring(#latex) .. "\n" .. latex
    end
    return table.concat(parts)
end

--[[ Inverse of to_text(). Lenient in the same way every other loader here is: a body that does not
parse leaves the state with no slots at all, and ensure() then hands it a fresh empty one on the
next frame - a corrupt or foreign definition costs you that definition, never the whole document.
@date 2026-09-08 08:12 ]]
function editor_definition.from_text(state, text, fontset)
    local slots = {}
    local nl = text:find("\n", 1, true)
    local count = nl and tonumber(text:sub(1, nl - 1))
    if count then
        local at = nl + 1
        for _ = 1, count do
            local nl2 = text:find("\n", at, true)
            local len = nl2 and tonumber(text:sub(at, nl2 - 1))
            if not len then
                break
            end
            local latex = text:sub(nl2 + 1, nl2 + len)
            slots[#slots + 1] = mformula.from_latex(fontset, mexpru.DEFAULT_SIZE, latex)
            at = nl2 + 1 + len
        end
    end
    if #slots > 0 then
        state.slots = slots
    end
end

return editor_definition

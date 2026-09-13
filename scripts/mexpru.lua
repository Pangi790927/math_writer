--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | THE FORMULA CONTAINER
-- | dress_spec(fields: table)               -> mexpru.u
-- |     A dress DESCRIPTION, sealed as a `u` because it carries the same
-- |     five fields a dress node's own `u` does. What redress takes when
-- |     there is no dress node yet.
-- |
-- | new_container(root: node, cursor_node: node | nil, version: number | nil) -> mexpru.container
-- | check_container(container: mexpru.container)            -> container
-- |     A formula: a root row, a cursor, a version. THE ONE CREATOR, and
-- |     the container is SEALED - `version` is bumped by every real tree
-- |     edit and by nothing else, which is what every cache here keys on.
-- |
-- | THE PER-NODE TABLE
-- | u(ref: node)                            -> mexpru.u | nil
-- | last_slot(node: node)                   -> node
-- |     The end of a row - where a caret lands after everything in it. An
-- |     empty row answers with itself, so a cursor is never set to nil.
-- | child_links(node: node)                 -> {node}
-- |     Every child hanging off a node, in drawing order - the ONE
-- |     definition of "what is below this", so a walk cannot fall behind
-- |     the `u` declaration.
-- | is_node(ref: any)                       -> boolean
-- | check_node(ref: node, what: string)     -> node
-- | check_u(u: mexpru.u)                    -> mexpru.u
-- |     An mexpr node is a C++ object - userdata - so this is STRUCTURAL,
-- |     not a metatable identity the way a sealed container's check is.
-- |     A node's own bookkeeping - kind, children, sz, bracket, the ast
-- |     tags. mexpr_t has a fixed C++ shape, so everything this layer
-- |     needs to remember lives here. A NEW FIELD GOES IN `u`.
-- |
-- | SIZE AND ZOOM
-- | MAX_SIZE_INDEX / DEFAULT_SIZE           constants
-- | set_zoom(z: number) / get_zoom()        -> nothing / z
-- | physical_sz(logical: size)              -> index
-- |     LOGICAL sizes are relative and zoom never touches them; zoom
-- |     applies only where a logical level becomes a real char.lua index.
-- |     A fresh formula passes DEFAULT_SIZE, never a live font size.
-- |
-- | READING A NODE
-- | slot_atom(node: node) / undressed(node: node) -> node
-- |     Through a dress or a supsub to the thing itself - what almost
-- |     every question about a node has to go through first.
-- | bracket_delta(node: node)               -> -1 | 0 | 1
-- | bracket_count(children: {node}, from: integer, to: integer) -> count | nil
-- | brackets_balanced(children: {node})     -> ok, count
-- | peer_slot(children: {node}, node: node) -> index, is_base | nil
-- | scan_bracket(children: {node}, idx: integer, direction: integer) -> index | nil
-- | transfer_bracket_peers(old_children: {node}, new_children: {node}) -> nothing
-- | same(a: node, b: node) / index_of(children: {node}, child: node)
-- |
-- | THE RAW C++ CREATORS, WRAPPED
-- | mexpr_empty / mexpr_symbol / mexpr_frac / mexpr_supsub
-- | mexpr_bracket_left / mexpr_bracket_right / mexpr_unarexpr
-- | mexpr_binexpr / mexpr_merge_h / mexpr_merge_v / mexpr_accent
-- | mexpr_dress                             -> node
-- |     GENERATED, one per entry of WRAPPED, so there is no
-- |     `function mexpru.mexpr_empty(...)` line anywhere. Each takes the
-- |     same arguments as the `vc.mexpr_*` it wraps and adds one thing: a
-- |     fresh sealed `u` captured onto the node. Prefer the shaped
-- |     constructors below - horiz, supsub, frac and the rest - which set
-- |     `kind` and the rest of `u` as well; these are the floor they are
-- |     built on, and mformula_new reaches past them for empty, symbol and
-- |     frac only.
-- |
-- | BUILDING
-- | horiz(fs: fontset, children: {node}, sz: size) -> node
-- | supsub(fs: fontset, base: node, sup: node, sub: node, sz: size, sup_place: place,
-- |        sub_place: place) -> node
-- | resupsub(fs: fontset, u: mexpru.u, base: node, sup: node, sub: node) -> node
-- | bigop(fs: fontset, base: node, sup: node, sub: node, sz: size) -> node
-- | vert(fs: fontset, slots: {node}, sz: size) -> node
-- | dress(fs: fontset, target: node, above: node, bellow: node, sz: size) -> node
-- | redress(fs: fontset, target: node, u: mexpru.u, sz: size) -> node
-- | accent(fs: fontset, recipe_fn: function, target: node, sz: size) -> node
-- | dots(fs: fontset, n: number, sz: size)  -> node
-- | frac(fs: fontset, num: node, den: node, sz: size) -> node
-- | PLACE_BESIDE / PLACE_DISPLAY            constants
-- | cut(node: node)                         -> nothing
-- | update_positions(node: node, pos: {x,y}) -> nothing
-- | propagate_rebuild(fs: fontset, old_node: node, new_node: node, known_parent: node | nil)
-- |       -> root
-- |     Every constructor wraps the raw vc.mexpr_* creator identically:
-- |     call through, attach a fresh `u`, return it.
-- |
-- | --- internal, not on the module table ---------------------------------------------------------
-- |     new_u()        the ONE creator for a node's `u` table, and where the seal is
-- |                    attached - every constructor goes through it
-- |     U_FIELDS, U_SHAPE, the creator wrappers, the size table and the bracket scanner
-- |
-- | @date 2026-09-13 21:15
-- | ===============================================================================================
--]]

--[[
mexpru.lua - the Lua side of an mexpr node: the wrappers that give every node a table to hang
things on, and the two numbers that decide how big anything is drawn.

WRAPPING. Each vc.mexpr_* creator (math_expr_composer.h) has a wrapper here whose only behavioural
difference is that the node comes back with a Lua table captured into its `u` field - the per-node
bookkeeping the editors need and C++ knows nothing about. Calling vc.mexpr_* directly still works;
the node simply has no table yet, which is a bug waiting to happen rather than a shortcut.

SIZES. A size in this codebase is an INDEX into char.lua's size table, biggest first, so a larger
index is a smaller glyph. Two constants live here because everything else has to agree on them:
MAX_SIZE_INDEX (that table's length) and DEFAULT_SIZE (the logical level a brand-new formula is
built at, whatever the current zoom). Zoom itself is one global offset set by content.lua rather
than a parameter threaded through draw, measure, input and hit-test - see set_zoom() below.

@date 2026-09-08 08:55
]]

local vc = require("virt_composer")
local sealed = require("sealed")
local char = require("char")

local mexpru = {}

-- #char.lua's m_font_sizes. The canonical copy - four other files used to keep their own.
mexpru.MAX_SIZE_INDEX = 18
-- The LOGICAL level a brand-new formula is built at, whatever the current zoom. Callers building a
-- fresh formula must pass this, never content.lua's live state.font_size - that double-counts zoom.
mexpru.DEFAULT_SIZE = 12

local current_zoom = 0

--[[ @brief Sets the zoom every PHYSICAL size is offset by - Ctrl+MouseWheel, for the whole app.
-- |
-- | ZOOM IS NOT A LOGICAL SIZE. A node's `u(_).sz` is relative and zoom never touches it: a
-- | superscript is its base plus SUB_SIZE_DELTA whatever the zoom. Zoom applies only where a
-- | logical level becomes a real char.lua index, which is why it is one module-wide value rather
-- | than a parameter threaded through draw, measure, input and hit-test. content.lua sets it before
-- | any of those run.
-- |
-- | @param z  number - an index offset; positive draws smaller, since the size table runs biggest
-- |           first
-- |
-- | @note A fresh formula passes mexpru.DEFAULT_SIZE, never content.lua's live font_size: the live
-- |       size already includes the zoom, and passing it counts the zoom twice.
-- |
-- | @date 2026-09-13 21:15
--]]
function mexpru.set_zoom(z)
    current_zoom = z
end

--[[ @brief The zoom currently in force - see set_zoom for why it lives here and not on a node.
-- |
-- | @return number - the index offset last set; 0 at start
-- |
-- | @date 2026-09-13 21:15
--]]
function mexpru.get_zoom()
    return current_zoom
end

--[[ @brief A LOGICAL size level -> the PHYSICAL char.lua index that builds or measures real glyphs.
-- |
-- | A MAPPING, NOT A MUTATION of u(_).sz: applying a delta to an already-physical value drifts once
-- | any step clamps, so zooming out and back in would stop being reversible. Re-deriving from the
-- | untouched logical value keeps it exact.
-- |
-- | @param logical  size - u(_).sz, relative and never touched by zoom
-- | @return integer - logical plus the zoom, clamped to 1 .. MAX_SIZE_INDEX
-- |
-- | @date 2026-09-13 21:15
--]]
function mexpru.physical_sz(logical)
    return math.max(1, math.min(mexpru.MAX_SIZE_INDEX, logical + current_zoom))
end

--[[ THE `u` TABLE'S DECLARED FIELDS - the single source for what a node may carry.

WHY A DECLARATION AT ALL. `u` is written by five files (mexpru, mformula_new, mformula_latex,
mexpr_ast, ast_mexpr) and read by more, so until now a typo made a NEW field instead of an error:
`u.bracjet = x` stored happily, `u.bracjet` read back nil, and nothing anywhere said the field did
not exist. There was also no one place that listed what a node carries.

WHAT THE SEAL DOES, and what it deliberately does not. The table looks exactly as it always did to
every caller:

  - a DECLARED field that was never set still reads as nil. `u.bracket` on a plain letter is nil,
    as it has always been, and that is a normal answer rather than an error.
  - an UNDECLARED name is refused, on read AND on write, with the name in the message. That is the
    signal to come back here and add it - a failure means the registration is out of date, not that
    the caller should route around it.

COST. Both metamethods fire ONLY while a key is absent: once a field has been written, reads and
writes of it go straight to the table. So the check is paid on a field's first write and on reads of
fields a node does not have, and never on the fields it does.

Each entry says what the field is and which kind of node carries it. Keep them one line; the
mechanism each belongs to is documented at the constructor that sets it.
@date 2026-09-12 04:40 ]]
local U_FIELDS = {
    -- every node
    kind          = "what this node IS: horiz, symbol, supsub, frac, vert, bracket, dress, accent",
    sz            = "LOGICAL size level - relative, never scaled by zoom. See set_zoom().",
    pos           = "{x, y} of the node's own origin, filled in by update_positions()",
    children      = "a horiz's slot list, in row order",

    -- supsub
    base          = "the thing a superscript or subscript rides on",
    sup           = "the superscript row, or nil",
    sub           = "the subscript row, or nil",
    sup_place     = "PLACE_BESIDE or PLACE_DISPLAY - beside the base, or above it",
    sub_place     = "the same, for the subscript",

    -- big operators
    above_kind    = "what the limit above a bigop is, when it has one",
    bellow_kind   = "the same, below",
    above_recipe  = "char.lua recipe the above-limit is drawn from",
    bellow_recipe = "the same, below",
    wants_limits  = "this operator takes limits rather than an ordinary sup/sub",

    -- fractions
    num           = "numerator row",
    den           = "denominator row",

    -- brackets
    bracket       = "{is_open, type, peer} on a bracket atom; nil on everything else",
    peer          = "the matching bracket's u TABLE, not its node - identity compares directly",

    -- verts, slots, targets
    slots         = "a vert's rows",
    target        = "what a dress or an accent is attached to",

    -- decoration
    dots          = "how many dots an accent carries",

    -- the ast correspondence, written by the parse
    ast_id        = "which ast node this glyph NAMES, for resolving a gesture",
    ast_draws     = "which ast node this glyph IS THE INK OF, for the writer",

    -- latex
    group_closed  = "a group that has already been closed, while rendering",
}

--[[ The shape, declared once through sealed.lua rather than with a metatable written out here.
Six containers in this project need the same seventeen lines; see that file for the rule and for why
the read and the write halves behave differently. @date 2026-09-12 05:45 ]]
local U_SHAPE = sealed.declare("mexpru", "u", U_FIELDS)

--[[ @brief A node's OWN table - the per-node bookkeeping this layer hangs on an mexpr_t.
-- |
-- | `mexpr_t` IS A C++ OBJECT WITH A FIXED SHAPE, so everything Lua needs to remember about a node
-- | lives in here instead: `kind`, `children`, `sz`, `bracket`, and the ast tags the parse writes.
-- | A NEW FIELD GOES HERE - adding one to C++ would change the core for a script-layer concern.
-- |
-- | THE SAME TABLE COMES BACK FOR THE SAME NODE every time (lua_object_t::push), so a `u` is a real
-- | identity key where a raw mexpr handle is not.
-- |
-- | @param ref  node - any live mexpr_t
-- | @return mexpru.u | nil - nil for a node that never captured one (built by calling vc.mexpr_*
-- |         directly, or a C++-built leaf); nothing is created here
-- | @throws when the node carries a table that is not a sealed `u`: something bypassed new_u, and
-- |         every field guarantee this file makes is void for it
-- |
-- | @date 2026-09-13 21:15
--]]
function mexpru.u(ref)
    local u = ref.u:push()
    --[[ NIL IS AN ANSWER, not a fault: a lua_object_t that never captured anything pushes nil, and
    that is what a node built by calling `vc.mexpr_*` directly rather than through the wrappers
    below looks like. Handing that back lets the caller say what an un-adopted node means to it.

    ANYTHING ELSE MUST BE A `u`. The seal only reaches tables new_u made; a plain table in there
    means something captured its own, bypassing the one creator, and every field guarantee this
    file makes is void for it. That is worth an error rather than a nil - author, 2026-09-12: "if
    it's not the u's type error out, if nil return nil, else return it". ]]
    if u == nil then
        return nil
    end
    return U_SHAPE.check(u, "u")
end

--[[ THE `container` CONTAINER - a formula: a root row, a cursor into it, and a version.

DECLARED HERE, in mexpru, and not in mformula_new where it is mostly used. Two layers build one:
mformula_new has five constructors and mformula_latex.from_latex a sixth, and mformula_new requires
mformula_latex rather than the other way round - so mformula_new cannot own the creator without a
cycle. mexpru is what both share, and a container is mexpr vocabulary anyway: a root node plus a
cursor into it.

`version` IS THE CONTRACT. It is bumped by every real TREE edit and by nothing else - not by a
cursor move, not by a click - which is how every caller tells "the formula changed" from "the caret
moved", and what the ast and transform caches are keyed on.

The underscore fields are per-container CACHES, each keyed on `version` by whoever owns it. They are
declared because they are written from other files - ast_gestures keeps the parse here, so it dies
with the formula rather than outliving it.
@date 2026-09-12 11:20 ]]
local CONTAINER_FIELDS = {
    root             = "the top-level horiz; the formula itself",
    cursor_pos       = "a weak ref to the node the caret sits after",
    version          = "bumped by every real TREE edit, and by nothing else",
    sel_anchor       = "the far end of a selection, or nil",
    pending_bracket  = "an opened bracket still waiting for its match, or nil",
    frame            = "this container's own frame counter",
    suppress_chars   = "while set, typed characters are swallowed",
    _blink_key       = "what the caret's blink phase is keyed on, so it restarts on a move",
    _ast_cache       = "ast_gestures' parse of this row, keyed on `version`",
    _transform_cache = "ast_gestures' preview of one option, keyed on version and option",
    _contour_cache   = "the vert contours last computed for this tree",
    _graph_cache     = "the reachable-position graph last computed for this tree",
}
local CONTAINER_SHAPE = sealed.declare("mexpru", "container", CONTAINER_FIELDS)

--[[ @brief Is this an mexpr node?
-- |
-- | STRUCTURAL, NOT IDENTITY, and that is forced: an mexpr_t is `userdata`, with no metatable of
-- | ours to compare against. What can be said is that it is userdata carrying the `u` field every
-- | node has - which separates a node from a wref, a fontset or a number.
-- |
-- | @param ref  any - nil is fine, and answers false
-- | @return boolean
-- |
-- | @date 2026-09-13 21:15
--]]
function mexpru.is_node(ref)
    return type(ref) == "userdata" and ref.u ~= nil
end

--[[ @brief Asserts that `ref` is an mexpr node, for a function that requires one.
-- |
-- | @param ref   any
-- | @param what  string | nil - the parameter's name, added to the message
-- | @return node - `ref`
-- | @throws naming the Lua type that arrived; level 3, so the position is the caller's
-- |
-- | @date 2026-09-13 21:15
--]]
function mexpru.check_node(ref, what)
    if not mexpru.is_node(ref) then
        error(string.format("mexpru: expected an mexpr node%s, got %s",
                what and (" for `" .. what .. "`") or "", type(ref)), 3)
    end
    return ref
end

--[[ @brief Asserts that `u` is a node's sealed `u` table, for a function elsewhere that takes one.
-- |
-- | @param u  any
-- | @return mexpru.u - `u`
-- | @throws naming the type that arrived
-- |
-- | @date 2026-09-13 21:15
--]]
function mexpru.check_u(u)
    return U_SHAPE.check(u, "u")
end

--[[ @brief Asserts that this is a formula container, for the top of a function that takes one.
-- |
-- | PUBLISHED because the container is declared HERE while almost every function taking one lives
-- | elsewhere - mformula_new, the editors, ast_gestures - and CONTAINER_SHAPE is local to this
-- | file.
-- |
-- | @param container  any
-- | @return mexpru.container - `container`, so the call can stand as a function's first line
-- | @throws naming the type that arrived
-- |
-- | @date 2026-09-13 21:15
--]]
function mexpru.check_container(container)
    return CONTAINER_SHAPE.check(container, "container")
end

--[[ @brief A formula container. THE ONE CREATOR - six places used to build this table by hand.
-- |
-- | @param root         node - the top-level horiz; not checked
-- | @param cursor_node  node | nil - the node the caret sits after, wrapped here as a WEAK ref so
-- |        no
-- |                     caller has to remember to
-- | @param version      integer | nil - 0 for a fresh formula; carried over by clone
-- | @return mexpru.container - sealed; no selection, nothing pending, empty caches
-- |
-- | @date 2026-09-13 21:15
--]]
function mexpru.new_container(root, cursor_node, version)
    return CONTAINER_SHAPE.wrap{
        root = root,
        cursor_pos = cursor_node and vc.wref_mexpr(cursor_node) or nil,
        version = version or 0,
    }
end

--[[ WHICH `u` FIELDS HOLD CHILD NODES - the tree's edges, named once.

WHY THIS IS NOT LEFT TO EACH WALKER. ast_mexpr.origins walked a tree by listing these eight fields
by hand, and that list is a SECOND declaration of the node shape, free to fall behind U_FIELDS above.
A node-valued field added there and forgotten here would not break anything loudly: origins would
simply return an incomplete map, ast_mexpr would re-render the glyphs it failed to find instead of
copying them, and the only symptom would be a decoration or a spacing quietly lost on a rebuild.

Split in two because they are reached differently - a list is iterated, a single link is followed -
and the load-time assertion below is what keeps both honest against U_FIELDS.
@date 2026-09-12 13:30 ]]
local U_CHILD_LISTS = {"children", "slots"}
local U_CHILD_NODES = {"base", "sup", "sub", "target", "num", "den"}

for _, group in ipairs({U_CHILD_LISTS, U_CHILD_NODES}) do
    for _, field in ipairs(group) do
        U_SHAPE.check_name(field, "child link")
    end
end

--[[ @brief The LAST slot of a row - where a caret lands after everything in it.
-- |
-- | THE ONE DEFINITION of "the end of this formula", which was written out three times - and only
-- | one of the three had the empty-row fallback.
-- |
-- | AN EMPTY ROW ANSWERS WITH ITSELF, so a cursor is never set to nil: the caret lands "before
-- | everything", a real position in the same numbering. A horiz always carries at least one empty
-- | atom in practice, so this is a fallback rather than a case.
-- |
-- | @param node  node - any node; one that is not a row has no children and answers with itself
-- | @return node
-- |
-- | @date 2026-09-13 21:15
--]]
function mexpru.last_slot(node)
    local children = mexpru.u(node).children
    return (children and children[#children]) or node
end

--[[ @brief Every child node hanging off `node`.
-- |
-- | THE ONE DEFINITION OF "what is below this node". A caller walking a whole tree asks here rather
-- | than listing the fields itself, so the walk cannot fall behind the `u` declaration - a
-- | load-time assertion ties the link lists to U_FIELDS.
-- |
-- | @param node  node - must carry a `u`
-- | @return {node} - a fresh flat list: `children` and `slots` first, then base, sup, sub, target,
-- |         num, den. Empty for a leaf; unset links are skipped
-- |
-- | @date 2026-09-13 21:15
--]]
function mexpru.child_links(node)
    local out = {}
    local u = mexpru.u(node)
    for _, field in ipairs(U_CHILD_LISTS) do
        for _, child in ipairs(u[field] or {}) do
            out[#out + 1] = child
        end
    end
    for _, field in ipairs(U_CHILD_NODES) do
        if u[field] then
            out[#out + 1] = u[field]
        end
    end
    return out
end

--[[ @brief A DRESS DESCRIPTION, as a `u`. What redress is handed when there is no dress node yet.
-- |
-- | A `u` AND NOT A TYPE OF ITS OWN: it carries exactly the five fields a dress node's own `u` does
-- | - above_kind, above_recipe, bellow_kind, bellow_recipe, dots - because it describes the same
-- | thing before there is a node to hang it on. That is what lets redress check its argument.
-- |
-- | @param fields  table | nil - sealed in place, not copied; nil is an empty description, which
-- |                means "no decoration"
-- | @return mexpru.u
-- |
-- | @note The seal does NOT check the literal's keys, since they are all present when `wrap` runs:
-- |       a misspelt `dot = 2` passes silently. `check_keys` would catch it.
-- |
-- | @date 2026-09-13 21:15
--]]
function mexpru.dress_spec(fields)
    return U_SHAPE.wrap(fields or {})
end

--[[ A fresh, sealed `u`. The ONE place a node's table is made, which is what lets the seal be
attached in one line rather than at every constructor. @date 2026-09-12 05:45 ]]
local function new_u()
    return U_SHAPE.wrap({})
end

-- Every raw vc.mexpr_* creator that returns a fresh mexpr_p, wrapped identically: call through,
-- capture a new {} into its u, return it. (mexpr_draw/mexpr_get_bb aren't creators, not wrapped;
-- wref_mexpr/rref_mexpr wrap an EXISTING mexpr_t rather than making a new one and aren't mexpr_t
-- themselves - no u field on those at all.)
local WRAPPED = {
    "mexpr_empty", "mexpr_symbol", "mexpr_frac", "mexpr_supsub",
    "mexpr_bracket_left", "mexpr_bracket_right",
    "mexpr_unarexpr", "mexpr_binexpr", "mexpr_merge_h", "mexpr_merge_v",
    "mexpr_accent", "mexpr_dress",
}

for _, name in ipairs(WRAPPED) do
    local raw = vc[name]
    mexpru[name] = function(...)
        local ret = raw(...)
        ret.u:capture(new_u())
        return ret
    end
end

--[[ THE bracket model. A bracket atom carries u(_).bracket = {is_open, type, peer}; `peer` is the
OTHER atom's u TABLE, not its mexpr_p. lua_object_t::push() always hands back the same table for the
same node, so `==` between two u tables is a real identity check - resolve_bracket_pairs() below
finds a pair's match with it directly, no depth walk.

Nothing but a bracket atom carries .bracket; bracket_kind() returns nil for ordinary content. `peer`
is nil while PENDING (typed, not yet closed - mformula_new.lua's container.pending_bracket) and is
always set on BOTH atoms at once, by whoever sets either.
@date 2026-09-08 08:55 ]]
local function bracket_kind(node)
    local u = mexpru.u(node)
    return u and u.bracket
end

--[[ @brief THE atom carrying a row slot's meaning: the node, or what a supsub or dress wraps.
-- |
-- | "(a)^{2}" IS [ "(", a, supsub(base=")") ] - the closing half is a BASE, invisible to any walk
-- | that reads children directly. That blind spot produced four separate live bugs (cascade delete
-- | taking the wrong partner, scan_bracket reporting an unrelated boundary, the wrap counter
-- | mis-balancing, the sprint skipping a bracket), so every walk over a row goes through here.
-- |
-- | RECURSIVE, through supsubs and dresses alike - a hatted, squared ")" still resolves - and a big
-- | operator is a supsub here, so a bracket in its base is found too. The integral depends on that.
-- |
-- | A BRACKET IS NEVER LOOKED THROUGH: a node that is itself a bracket answers as itself.
-- |
-- | @param node  node - must carry a `u`
-- | @return node - the atom, possibly `node` itself
-- |
-- | @note NOT the same question as mformula_new's is_wrapper_base, which asks about the cursor's
-- |       own node rather than what a slot carries. They look alike; don't merge them.
-- |
-- | @date 2026-09-13 21:15
--]]
function mexpru.slot_atom(node)
    local u = mexpru.u(node)
    if not u.bracket and u.kind == "supsub" and u.base then
        return mexpru.slot_atom(u.base)
    end
    if not u.bracket and u.kind == "dress" and u.target then
        return mexpru.slot_atom(u.target)
    end
    return node
end

--[[ @brief The node a dress is wrapping - "make the dress transparent".
-- |
-- | A DECORATION IS DONE TO A THING, and anything asking what is really here should see through it.
-- | `\\vec{F_{n}}` is a dress around a supsub, and a reader stopping at the dress sees a letter
-- | with no subscript - how that subscript went missing (mexpr_ast's `unit`).
-- |
-- | STOPS AT WHATEVER THE DRESSES WRAP, unlike slot_atom, which keeps going through supsubs to the
-- | bare atom. slot_atom asks "which glyph is this, ultimately"; this asks "what is this decoration
-- | applied to" - and for a supsub the answer must still BE the supsub, or its limits are lost.
-- |
-- | @details Loops, since nothing forbids a rebuild nesting two dresses. A bracket is never looked
-- |          through, the same carve-out slot_atom makes.
-- |
-- | @param node  node | nil
-- | @return node | nil - `node` itself when it is not a dress; nil for nil
-- |
-- | @date 2026-09-13 21:15
--]]
function mexpru.undressed(node)
    local u = node and mexpru.u(node)
    while u and not u.bracket and u.kind == "dress" and u.target do
        node = u.target
        u = mexpru.u(node)
    end
    return node
end

--[[ @brief What one row slot does to bracket depth: +1 for an open, -1 for a close, 0 otherwise.
-- |
-- | THE ONE DEFINITION OF THAT QUESTION, so every scan counting brackets - the pairing, the
-- | cursor's forbidden positions, the parser's term splitting - agrees about what counts. Reads
-- | THROUGH slot_atom, so a bracket carrying an exponent still answers as a bracket.
-- |
-- | @param node  node - a row slot
-- | @return integer - -1, 0 or 1. A pending bracket counts like a closed one
-- |
-- | @date 2026-09-13 21:15
--]]
function mexpru.bracket_delta(node)
    local br = mexpru.u(mexpru.slot_atom(node)).bracket
    if not br then
        return 0
    end
    return br.is_open and 1 or -1
end

--[[ @brief THE counter rule over children[from..to]: the open count, or nil if it goes negative.
-- |
-- | A BRACKET MAY CLOSE ONLY WHERE THE COUNT IS BACK TO ZERO, and the count may never go below
-- | zero. A step that would take it negative IS the close of the ENCLOSING pair, so it and
-- | everything beyond are out of bounds for anything opened inside.
-- |
-- | @details A count rather than a walk looking for a specific atom, because a count is checkable
-- |          over any range without knowing which atom is whose partner. Stops early at a missing
-- |          child.
-- |
-- | @param children  {node} - a row's children
-- | @param from      integer - first index
-- | @param to        integer - last index, inclusive
-- | @return integer | nil - the count at `to`; nil the moment it would go negative
-- |
-- | @date 2026-09-13 21:15
--]]
function mexpru.bracket_count(children, from, to)
    local count = 0
    for i = from, to do
        local child = children[i]
        if not child then
            break
        end
        local delta = mexpru.bracket_delta(child)
        if delta < 0 and count == 0 then
            return nil          -- this is the ENCLOSING close - never step over it
        end
        count = count + delta
    end
    return count
end

--[[ @brief The counter rule over a whole row.
-- |
-- | ONLY ok == false IS CORRUPTION: a close with nothing open, which no edit may ever produce. A
-- | positive count is an ordinary mid-edit state - a pending bracket.
-- |
-- | @param children  {node} - a row's children
-- | @return boolean, integer - ok, and the count: when ok, 0 is balanced and more is pending; when
-- |         not ok, the count where it would have gone negative
-- |
-- | @date 2026-09-13 21:15
--]]
function mexpru.brackets_balanced(children)
    local count = 0
    for i = 1, #children do
        local delta = mexpru.bracket_delta(children[i])
        if delta < 0 and count == 0 then
            return false, count
        end
        count = count + delta
    end
    return true, count
end

--[[ @brief Where a bracket's OWN peer sits in `children`: an identity read, NOT a depth walk.
-- |
-- | USE THIS FOR A BRACKET'S PARTNER, and scan_bracket only for what encloses an ORDINARY position.
-- | A depth walk cannot see a peer parked in a supsub base and returns the next unmatched bracket
-- | instead, silently pairing two atoms that were never partners - "((A)^{N})" lost a bracket on
-- | backspace exactly this way.
-- |
-- | @param children  {node} - the row to look in
-- | @param node      node - the bracket atom
-- | @return integer, boolean | nil - the slot's index, and whether the peer is that slot's BASE
-- |         (removal then means rebuilding a supsub, not splicing the row); nil when `node` is not
-- |         a bracket, is still pending, or its peer is not in this row
-- |
-- | @date 2026-09-13 21:15
--]]
function mexpru.peer_slot(children, node)
    local br = mexpru.u(node).bracket
    if not br or not br.peer then
        return nil
    end
    for i, child in ipairs(children) do
        local carrier = mexpru.slot_atom(child)
        if mexpru.u(carrier) == br.peer then
            return i, mexpru.u(carrier) ~= mexpru.u(child)
        end
    end
    return nil
end

--[[ @brief The first bracket from idx+direction not claimed by a nested pair passed on the way.
-- |
-- | FOR AN ORDINARY POSITION: with direction -1 it finds the pair ENCLOSING `idx`. A bracket atom's
-- | own match is never found this way - see peer_slot.
-- |
-- | @details Checks only is_open, never the type: every closed pair is type-matched already, since
-- |          a close pairs with the innermost unclosed open and refuses a mismatch. Reads each slot
-- |          through slot_atom, so a ")" carrying an exponent is counted.
-- |
-- | @param children   {node} - the row
-- | @param idx        integer - the position to start beside; not itself examined
-- | @param direction  integer - -1 walks left, 1 walks right
-- | @return integer | nil - the bracket's index; nil when none is unclaimed
-- |
-- | @date 2026-09-13 21:15
--]]
function mexpru.scan_bracket(children, idx, direction)
    local depth = 0
    local i = idx + direction
    while children[i] do
        local br = bracket_kind(mexpru.slot_atom(children[i]))
        if br then
            -- An open met while walking right, or a close met while walking left, starts (or
            -- continues) a nested/earlier-unrelated pair that has to be skipped past whole before
            -- our own search can resolve.
            local starts_nested = (direction == 1 and br.is_open) or (direction == -1 and not br.is_open)
            if starts_nested then
                depth = depth + 1
            elseif depth > 0 then
                depth = depth - 1
            else
                return i
            end
        end
        i = i + direction
    end
    return nil
end

--[[ @brief Copies the open/close pairing of `old_children` onto `new_children`, slot by slot.
-- |
-- | FOR A REBUILD THAT MAKES NEW BRACKET ATOMS - rescale_node on a zoom - whose peers cannot be
-- | carried across, since they name `u` tables of the tree being discarded. Without this every pair
-- | reads as pending and stays at the small plain glyph: the "brackets go small when I zoom" bug.
-- |
-- | TRANSFERS RATHER THAN RE-DERIVES, and that is the whole design: pairing is NOT a function of
-- | position. "(_1 (_2 a )_1" with the inner one pending is an ordinary state, and any depth scan
-- | would invent a pair nobody closed. A rescale is a 1:1 mirror, so old slot i IS new slot i.
-- |
-- | @param old_children  {node} - the row before the rebuild, peers intact
-- | @param new_children  {node} - the same shape, rebuilt; its bracket atoms get their peers set
-- |
-- | @note A pair whose new atoms carry no `bracket` is skipped. Slots are read through slot_atom.
-- |
-- | @date 2026-09-13 21:15
--]]
function mexpru.transfer_bracket_peers(old_children, new_children)
    for i = 1, #old_children do
        local old_atom = mexpru.slot_atom(old_children[i])
        local ob = old_atom and mexpru.u(old_atom).bracket
        if ob and ob.is_open and ob.peer then
            local j = mexpru.peer_slot(old_children, old_atom)
            local new_open = j and mexpru.slot_atom(new_children[i])
            local new_close = j and mexpru.slot_atom(new_children[j])
            if new_open and new_close and mexpru.u(new_open).bracket and mexpru.u(new_close).bracket then
                mexpru.u(new_open).bracket.peer = mexpru.u(new_close)
                mexpru.u(new_close).bracket.peer = mexpru.u(new_open)
            end
        end
    end
end

--[[ slot_atom()'s inverse: puts `new_atom` back where slot_atom() found the old one, rebuilding
whatever wrapped it so the wrapper survives the swap.

"(a)^{2}" is [ "(", a, supsub(base=")") ]. Growing that pair means replacing the ")" INSIDE the
supsub - assigning over children[close_idx] wholesale would throw the exponent away with it.

Mirrors slot_atom() case for case, and must keep doing so: any node shape that can hide a bracket
has to be un-hideable again, or a pair that can be found is one that cannot be resized.
@date 2026-09-08 08:55 ]]
local function replace_slot_atom(fs, node, new_atom)
    local u = mexpru.u(node)
    if not u.bracket and u.kind == "supsub" and u.base then
        return mexpru.resupsub(fs, u, replace_slot_atom(fs, u.base, new_atom), u.sup, u.sub)
    end
    if not u.bracket and u.kind == "dress" and u.target then
        return mexpru.redress(fs, replace_slot_atom(fs, u.target, new_atom), u, u.sz)
    end
    return new_atom
end

--[[ Resolves every entangled bracket pair currently found in children[lo..hi] (the WHOLE list by
default - lo/hi are only ever passed explicitly by this function's OWN recursion below), innermost
first, before `children` is handed to mexpr_merge_h - see mformula_new.lua's own PENDING_BRACKET
comment for why a horiz's rebuild can't just be "merge whatever's here" anymore once brackets are
involved: each pair's own glyphs depend on everything CURRENTLY between them.

For an open bracket at `i`, finding where its own close currently sits is a plain forward walk
comparing each element's own u table against `br.peer` (this file's own top comment on why that's a
real, reliable check) - not wasted work: this function's actual job per pair is gathering everything
strictly BETWEEN the two into `inner` for sizing, which requires visiting every element in the span
regardless of how the boundary gets found, so the search costs nothing beyond what the job already
needs. It does NOT need depth-tracking (a stack, or scan_bracket()'s own counter) to stay correct
despite however many OTHER open/close brackets (nested pairs) sit in between - unlike interpreting
brackets generically, checking against one SPECIFIC known target (`br.peer`) doesn't care what it
passes over on the way to it.
Innermost-first: on finding an open bracket's own close this way, it first recurses into the range
strictly BETWEEN them (whatever nests inside gets fully resolved first, its own atoms' identities
possibly replaced) before gathering `inner` and rebuilding this pair's own two glyphs against that
now-settled content.
@date 2026-09-08 08:55 ]]
local function resolve_bracket_pairs(fs, children, lo, hi)
    lo = lo or 1
    hi = hi or #children
    local i = lo
    while i <= hi do
        --[[ Through slot_atom, not children[i] directly. A bracket carrying an exponent is a supsub
        BASE ("(a)^{2}", which is also every \sqrt now that from_latex rewrites roots into powers),
        and reading the slot directly finds the supsub, whose u never equals br.peer - so the close
        was never located, the pair never grew, and "(a/b)^{2}" drew letter-height parentheses
        around a two-line fraction. Reported live 2026-09-06; the same blind spot slot_atom() was
        written for, at the one call site that still read around it. ]]
        local open_atom = mexpru.slot_atom(children[i])
        local br = bracket_kind(open_atom)
        if br and br.is_open and br.peer then
            local close_idx = i + 1
            while close_idx <= hi
                    and mexpru.u(mexpru.slot_atom(children[close_idx])) ~= br.peer do
                close_idx = close_idx + 1
            end

            if close_idx <= hi then
                local close_atom = mexpru.slot_atom(children[close_idx])
                resolve_bracket_pairs(fs, children, i + 1, close_idx - 1)

                local inner = {}
                for k = i + 1, close_idx - 1 do
                    table.insert(inner, children[k])
                end
                if #inner == 0 then
                    error("resolve_bracket_pairs: bracket pair's own span is empty - " ..
                            "mformula_new.lua is supposed to keep a bracket pair's span non-empty " ..
                            "(a fresh empty atom, same as an emptied-out horiz falls back to) " ..
                            "whenever backspace/delete would otherwise remove its last remaining child")
                end

                -- sz is LOGICAL (u(_).sz's own meaning, untouched by zoom - mexpru.physical_sz()'s
                -- own comment) - mapped to PHYSICAL below for the real bracket construction/height
                -- check, same as every other leaf this file's own callers build. Missing this
                -- mapping here specifically (found live, alongside the sizing issue
                -- below: "behaves quite differently with different zoom levels") meant a resolved
                -- bracket pair kept rendering at whatever size it was AT WHEN LAST RESOLVED,
                -- ignoring the current zoom entirely, while everything around it correctly rescaled.
                local sz = mexpru.u(open_atom).sz
                local phys_sz = mexpru.physical_sz(sz)
                --[[ A pair with no tiered family is left exactly as typed: the integral's, whose
                halves are an operator glyph and a `d` and grow with nothing. The recursion above has
                already resolved whatever nests INSIDE it, which is the part that does still matter.
                @date 2026-09-10 23:40 ]]
                local opts = char.bracket_opts(br.type, phys_sz)
                if opts then
                    local assembled = (#inner == 1) and inner[1] or mexpru.mexpr_merge_h(fs, inner)

                    -- Short content keeps the PLAIN typed glyphs, untouched. Do not "fix" this by
                    -- forcing a minimum height into the tiered system instead (tried twice): its
                    -- smallest tier ("\\bigl(", FONT_MATH_EX) is not a same-size stand-in for a typed
                    -- "(" (FONT_NORMAL) but a deliberately larger glyph, so any threshold still lands
                    -- on it. "(a" -> "(a)" has to change nothing but the ")" appearing.
                    local plain_paren = char.find_by_ascii("(")
                    local paren_sz = fs:char_get_sz({size = phys_sz, code = plain_paren.ncod})
                    local plain_h = math.abs(paren_sz.tr.y - paren_sz.bl.y)
                    local content_bb = vc.mexpr_get_bb(assembled)
                    local content_h = content_bb.br.y - content_bb.tl.y

                    --[[ `inner` is what sits strictly BETWEEN the brackets, so an exponent riding on
                    the closing one is correctly NOT counted - "(a/b)^{2}" sizes its parentheses to the
                    fraction, not to the fraction plus the 2, which is what TeX does too. ]]
                    local grew = content_h > plain_h
                    local new_left, new_right
                    if not grew then
                        new_left = open_atom
                        new_right = close_atom
                    else
                        new_left = mexpru.mexpr_bracket_left(fs, assembled, opts)
                        new_right = mexpru.mexpr_bracket_right(fs, assembled, opts)
                        mexpru.u(new_left).sz = sz
                        mexpru.u(new_right).sz = mexpru.u(close_atom).sz
                    end
                    mexpru.u(new_left).bracket = {is_open = true, type = br.type, peer = mexpru.u(new_right)}
                    mexpru.u(new_right).bracket = {is_open = false, type = br.type, peer = mexpru.u(new_left)}

                    --[[ Only when the glyphs actually CHANGED. Short content keeps the atoms it already
                    had, and rebuilding a wrapper around an identical base would hand back a new node for
                    no reason - a fresh identity that peer transfer and any live cursor ref would then
                    have to chase. The untouched case stays exactly the no-op it always was. ]]
                    if grew then
                        children[i] = replace_slot_atom(fs, children[i], new_left)
                        children[close_idx] = replace_slot_atom(fs, children[close_idx], new_right)
                    end
                end

                i = close_idx + 1
            else
                -- Still pending (no peer, or peer not found within this range) - an ordinary glyph
                -- as far as this pass is concerned, nothing to resolve.
                i = i + 1
            end
        else
            i = i + 1
        end
    end
end

--[[ @brief Caches every node's position into its `u.pos`, walking the tree the way mexpr_draw does.
-- |
-- | mexpr_t STORES tl/br RELATIVE TO ITS OWN ORIGIN only, so this is where anything wanting a
-- | position reads it. RELATIVE to the root, not screen space: the cache survives the box being
-- | drawn anywhere else. Only a TREE EDIT invalidates it; recompute by calling again.
-- |
-- | @details Raw C++-built subobjs (a fraction's divider, a big operator's symbol) have no `u` and
-- |          are skipped; they are always leaves.
-- |
-- | @param node  node - the root of the walk
-- | @param pos   {x, y} | nil - `node`'s own position; nil means the origin
-- |
-- | @date 2026-09-13 21:15
--]]
function mexpru.update_positions(node, pos)
    pos = pos or {x = 0, y = 0}
    local u = mexpru.u(node)
    if u then
        u.pos = pos
    end

    for i = 1, node:anchor_len() do
        local a = node:anchor_at(i)
        local child, child_pos = a[1], a[2]
        mexpru.update_positions(child, {x = pos.x + child_pos.x, y = pos.y + child_pos.y})
    end
end

--[[ @brief A row: a left-to-right sequence of nodes, with its bracket pairs sized to their content.
-- |
-- | IT REMEMBERS kind, children and sz, so propagate_rebuild can redo this exact construction from
-- | a changed children list. `children` is kept BY REFERENCE - propagate_rebuild splices it in
-- | place.
-- |
-- | EVERY ENTANGLED BRACKET PAIR IS RESOLVED FIRST, innermost out: a pair's glyphs depend on what
-- | is currently between them, and a grown pair's atoms are REPLACED in `children`.
-- |
-- | @param fs        fontset
-- | @param children  {node} - modified in place when a pair grows
-- | @param sz        size - logical
-- | @return node - kind "horiz"
-- | @throws when a closed pair's span is empty; mformula_new keeps it non-empty
-- |
-- | @date 2026-09-13 21:15
--]]
function mexpru.horiz(fs, children, sz)
    resolve_bracket_pairs(fs, children)
    local ret = mexpru.mexpr_merge_h(fs, children)
    mexpru.u(ret).kind = "horiz"
    mexpru.u(ret).children = children
    mexpru.u(ret).sz = sz
    return ret
end

--[[ WHERE ONE SIDE IS DRAWN. Named here rather than registered as a C++ enum because the binding
takes plain ints - the enum machinery in math_expr_composer.h feeds the YAML config, not Lua.
@date 2026-09-10 16:20 ]]
mexpru.PLACE_BESIDE = 0
mexpru.PLACE_DISPLAY = 1

--[[ @brief A base with a superscript and/or subscript, each beside it or centred over/under it.
-- |
-- | THREE NAMED SLOTS rather than horiz's ordered list, so propagate_rebuild finds which one
-- | changed by name.
-- |
-- | PLACEMENT IS PER SIDE, and both are remembered in `u` so a rebuild puts them back. There used
-- | to be two node kinds, supsub and bigop, and every walk that forgot the second lost a bracket or
-- | rebuilt an operator as the wrong thing; a big operator is now a supsub with DISPLAY sides.
-- |
-- | @param fs         fontset
-- | @param base       node - required
-- | @param sup        node | nil
-- | @param sub        node | nil
-- | @param sz         size | nil - logical; also scales the gap to the sides. Not stored when nil
-- | @param sup_place  place | nil - PLACE_BESIDE (the default) or PLACE_DISPLAY
-- | @param sub_place  place | nil - likewise
-- | @return node - kind "supsub"
-- |
-- | @date 2026-09-13 21:15
--]]
function mexpru.supsub(fs, base, sup, sub, sz, sup_place, sub_place)
    sup_place = sup_place or mexpru.PLACE_BESIDE
    sub_place = sub_place or mexpru.PLACE_BESIDE
    local ret = mexpru.mexpr_supsub(fs, base, sup, sub,
            char.hline_basic(mexpru.physical_sz(sz or mexpru.DEFAULT_SIZE)),
            sup_place, sub_place)
    mexpru.u(ret).kind = "supsub"
    mexpru.u(ret).base = base
    mexpru.u(ret).sup = sup
    mexpru.u(ret).sub = sub
    mexpru.u(ret).sup_place = sup_place
    mexpru.u(ret).sub_place = sub_place
    if sz then
        mexpru.u(ret).sz = sz
    end
    return ret
end

--[[ @brief Rebuilds a supsub with new slots, keeping the placement and size its `u` records.
-- |
-- | THE SINGLE PLACE A SUPSUB IS RECONSTRUCTED, for the reason redress is for a dress: placement
-- | lives only in `u`, and a rebuild that forgot it would silently move a limit from under its
-- | operator to beside it. Five rebuilds used to choose a constructor by kind instead.
-- |
-- | @param fs    fontset
-- | @param u     mexpru.u - the old node's; its sz, sup_place and sub_place are reused. Not checked
-- | @param base  node
-- | @param sup   node | nil
-- | @param sub   node | nil
-- | @return node - a new supsub
-- |
-- | @date 2026-09-13 21:15
--]]
function mexpru.resupsub(fs, u, base, sup, sub)
    return mexpru.supsub(fs, base, sup, sub, u.sz, u.sup_place, u.sub_place)
end

--[[ @brief A big operator with limits - a sum, an integral, "lim": a supsub, both sides DISPLAY.
-- |
-- | IT IS A SUPSUB for everything but drawing: base the operator, sup above, sub below. The same
-- | field names are what let every walk need no bigop case; only a rebuild reads the placement.
-- |
-- | @param fs    fontset
-- | @param base  node - the operator
-- | @param sup   node | nil - the upper limit
-- | @param sub   node | nil - the lower limit
-- | @param sz    size - required in spirit, where supsub's is optional: a display side scales its
-- |        gap
-- |              from it
-- | @return node - kind "supsub"
-- |
-- | @date 2026-09-13 21:15
--]]
function mexpru.bigop(fs, base, sup, sub, sz)
    return mexpru.supsub(fs, base, sup, sub, sz,
            mexpru.PLACE_DISPLAY, mexpru.PLACE_DISPLAY)
end

--[[ The floor a vert cell never shrinks below - "the size the cell started with". H's advance wide,
G's top to g's baseline tall, i.e. exactly the box an EMPTY slot has (mformula_new.lua's
min_extent()/cursor_metrics() compute the same pair; mexpru is the lower layer, so it recomputes
rather than imports). Derived here from sz rather than passed in by vert()'s four callers, one of
which would eventually forget it. PHYSICAL size - these are real font metrics.
@date 2026-09-08 08:55 ]]
local function empty_cell_extent(fs, sz)
    local physical = mexpru.physical_sz(sz)
    local G, g, H = char.find_by_ascii("G"), char.find_by_ascii("g"), char.find_by_ascii("H")
    local G_sz = fs:char_get_sz({size = physical, code = G.ncod})
    local g_sz = fs:char_get_sz({size = physical, code = g.ncod})
    local H_sz = fs:char_get_sz({size = physical, code = H.ncod})
    return {x = H_sz.adv, y = g_sz.bl.y - G_sz.tr.y}
end

--[[ @brief N rows stacked vertically with no divider - a matrix, or a named operator's word.
-- |
-- | THE SAME PRIMITIVE A FRACTION STACKS WITH, minus the line. Every row is one uniform size: a
-- | stack does not shrink its rows the way an exponent does. A cell never shrinks below an empty
-- | slot's box, derived here from `sz`.
-- |
-- | @param fs     fontset
-- | @param slots  {node} - each a horiz; kept BY REFERENCE, as horiz's children are
-- | @param sz     size - logical
-- | @return node - kind "vert"
-- |
-- | @date 2026-09-13 21:15
--]]
function mexpru.vert(fs, slots, sz)
    local ret = mexpru.mexpr_merge_v(fs, slots, empty_cell_extent(fs, sz))
    mexpru.u(ret).kind = "vert"
    mexpru.u(ret).slots = slots
    mexpru.u(ret).sz = sz
    return ret
end

--[[ @brief Dresses `target` with a decoration above and/or below - a hat, a bar, dots.
-- |
-- | A DRESSED NODE IS AN ATOM: it takes the target's place in its row, is never entered, and the
-- | decoration cannot be selected. That is the shape of a supsub's base, which this codebase has
-- | repeatedly got wrong - so slot_atom and peer_slot look THROUGH a dress to its target.
-- |
-- | @details mexpr_dress only PLACES the decorations (TEXbook Appendix G Rule 12). The clearance
-- |          between target and decoration is the height of hline_basic, the pen width; it used to
-- |          be a letter-tall glyph, which floated every accent a letter and a half up.
-- |
-- | @param fs      fontset
-- | @param target  node
-- | @param above   node | nil - built by accent() or dots()
-- | @param bellow  node | nil - built by accent()
-- | @param sz      size - logical
-- | @return node - kind "dress"; the caller records above_kind and friends, as redress does
-- |
-- | @date 2026-09-13 21:15
--]]
function mexpru.dress(fs, target, above, bellow, sz)
    --[[ mexpr_dress measures this char's HEIGHT and uses it as the clearance between the target's
    ink and the decoration - its own comment calls for "the pen width, which is font-derived and
    already the thickness a drawn accent is stroked at". hline_basic is that: the rule glyph a
    fraction's divider is drawn from, 1 unit tall here.

    It used to pass code = 0, which is not a pen width but char.lua's first table entry, 26 units
    tall at size 12 - so every accent floated a letter and a half above its own letter and a dressed
    "a" measured 48 units against the bare glyph's 17. ]]
    local ret = mexpru.mexpr_dress(fs, target, above, bellow,
            char.hline_basic(mexpru.physical_sz(sz)))
    mexpru.u(ret).kind = "dress"
    mexpru.u(ret).target = target
    mexpru.u(ret).sz = sz
    return ret
end

--[[ @brief The accent glyph, or drawn shape, that fits `target`'s width.
-- |
-- | @param fs         fontset
-- | @param recipe_fn  function(fontsz) - a char.lua accent, e.g. char.hat_accent
-- | @param target     node - its box width picks the tier (Rule 12's successor search)
-- | @param sz         size - logical
-- | @return node - to pass to dress()
-- |
-- | @date 2026-09-13 21:15
--]]
function mexpru.accent(fs, recipe_fn, target, sz)
    local bb = vc.mexpr_get_bb(target)
    return mexpru.mexpr_accent(fs, recipe_fn(mexpru.physical_sz(sz)), bb.br.x - bb.tl.x)
end

--[[ @brief n dots side by side, for the one-, two- and three-dot accents.
-- |
-- | Built by merging, since there is no ddot in these fonts.
-- |
-- | @param fs  fontset
-- | @param n   integer - how many
-- | @param sz  size - logical
-- | @return node - a single dot glyph for n <= 1, else a merged row of n
-- |
-- | @note n = 0 still gives one dot; redress only calls this for n > 0.
-- |
-- | @date 2026-09-13 21:15
--]]
function mexpru.dots(fs, n, sz)
    local one = char.dot_accent_char(mexpru.physical_sz(sz))
    if n <= 1 then
        return mexpru.mexpr_symbol(fs, one, false)
    end
    local parts = {}
    for _ = 1, n do
        parts[#parts + 1] = mexpru.mexpr_symbol(fs, one, false)
    end
    return mexpru.mexpr_merge_h(fs, parts)
end

--[[ @brief A fraction: numerator over denominator, with a rule between.
-- |
-- | BOTH ROWS RENDER AT THE FRACTION'S OWN SIZE - typesetting does not shrink them the way an
-- | exponent shrinks - so a frac carries its own sz directly, and nothing reading it needs a
-- | base-fallback.
-- |
-- | @param fs   fontset
-- | @param num  node - REQUIRED, always a horiz; mexpr_frac raises without it
-- | @param den  node - REQUIRED, always a horiz
-- | @param sz   size - logical; the rule is built at its physical size
-- | @return node - kind "frac"
-- |
-- | @date 2026-09-13 21:15
--]]
function mexpru.frac(fs, num, den, sz)
    -- sz is LOGICAL (u(ret).sz below) - the divider LINE's own real geometry (char.hline_basic)
    -- needs the current PHYSICAL size instead (mexpru.physical_sz()'s own comment).
    local ret = mexpru.mexpr_frac(fs, num, den, char.hline_basic(mexpru.physical_sz(sz)))
    mexpru.u(ret).kind = "frac"
    mexpru.u(ret).num = num
    mexpru.u(ret).den = den
    mexpru.u(ret).sz = sz
    return ret
end

--[[ @brief Rebuilds a dress with `u`'s decoration around a possibly new, possibly resized target.
-- |
-- | THE SINGLE PLACE A DRESS IS RECONSTRUCTED. Its callers - propagate_rebuild when the target is
-- | edited, rescale_node on a zoom - had drifted: only one checked `dots`, so editing the letter
-- | under a dot accent silently dropped the dots.
-- |
-- | THE DECORATION IS REBUILT, never carried across, because an accent is chosen by the target's
-- | WIDTH - a letter edited into a wider one needs a wider hat.
-- |
-- | @details Dots are tested before above_recipe: a dotted dress has no recipe. The new node's `u`
-- |          gets the same five decoration fields.
-- |
-- | @param fs      fontset
-- | @param target  node - not checked; the C++ side raises its own
-- | @param u       mexpru.u - checked; a dress node's own, or a dress_spec
-- | @param sz      size - logical
-- | @return node - kind "dress"
-- |
-- | @date 2026-09-13 21:15
--]]
function mexpru.redress(fs, target, u, sz)
    --[[ `u` is READ HERE - dots, above_recipe, bellow_recipe - so it is checked here. `target` is
    only forwarded into accent/dress and on into the C++ side, which raises its own when handed the
    wrong thing. ]]
    U_SHAPE.check(u, "u")
    local above
    if u.dots and u.dots > 0 then
        above = mexpru.dots(fs, u.dots, sz)
    elseif u.above_recipe then
        above = mexpru.accent(fs, u.above_recipe, target, sz)
    end
    local bellow = u.bellow_recipe and mexpru.accent(fs, u.bellow_recipe, target, sz) or nil

    local ret = mexpru.dress(fs, target, above, bellow, sz)
    local ru = mexpru.u(ret)
    ru.above_kind = u.above_kind
    ru.above_recipe = u.above_recipe
    ru.bellow_kind = u.bellow_kind
    ru.bellow_recipe = u.bellow_recipe
    ru.dots = u.dots
    return ret
end

--[[ @brief Do these two handles name the same node? One pointer comparison.
-- |
-- | THROUGH THE __eq HANDLER mexpr_t registers (math_expr_composer.h's mexpr_lua_eq). Two handles
-- | onto one node are different Lua values, so `==` only works through it.
-- |
-- | @param a  node | nil
-- | @param b  node | nil
-- | @return boolean - true for two nils: an absent sup and an absent sup are the same absence
-- |
-- | @note This used to compare tostring() output, because no handler was registered; peer-linking
-- |       got built on that workaround, which is the case CLAUDE.md's Law 1 is written from.
-- |
-- | @date 2026-09-13 21:15
--]]
local function same(a, b)
    if a == nil or b == nil then
        return a == nil and b == nil
    end
    return a == b
end
mexpru.same = same

--[[ @brief `child`'s index within `children`, by identity.
-- |
-- | @param children  {node}
-- | @param child     node
-- | @return integer | nil - the first match through same(); nil when not there
-- |
-- | @date 2026-09-13 21:15
--]]
local function index_of(children, child)
    for i, c in ipairs(children) do
        if same(c, child) then
            return i
        end
    end
    return nil
end
mexpru.index_of = index_of

--[[ @brief Puts a rebuilt node where the old one was, rebuilding every ancestor up to the root.
-- |
-- | A COMPOSITE IS NEVER MUTATED IN PLACE, only rebuilt from its remembered construction arguments.
-- | So new_node is spliced into whichever slot of the parent old_node held, that parent is rebuilt,
-- | and so on upward: "the node and all its parents redo the operation they did at creation".
-- |
-- | OLD NODES ARE CUT LOOSE AT EVERY LEVEL, not only at the root. That was reverted once as a
-- | crash; the real cause was a bug in vc.force_release(), since fixed.
-- |
-- | @details The parent's kind picks the rebuild: horiz, supsub, frac, vert or dress.
-- |
-- | @param fs            fontset
-- | @param old_node      node - checked; the node being replaced
-- | @param new_node      node - its replacement
-- | @param known_parent  node | nil - for a WRAP, where new_node was built AROUND old_node: the
-- |                      constructor already reparented old_node, so get_parent() would answer
-- |                      new_node and the wrapper would be wrapped forever. Capture the parent
-- |                      BEFORE building new_node. Given, the slot is found by identity, and
-- |                      old_node is not cut, since new_node owns it
-- | @return node - the new root; the caller reassigns container.root to it. Positions are updated
-- | @throws when old_node is not in its parent's slots, or the parent's kind has no rebuild
-- |
-- | @date 2026-09-13 21:15
--]]
function mexpru.propagate_rebuild(fs, old_node, new_node, known_parent)
    --[[ AN INTEGRITY CHECK ON `old_node`, which is the one argument nothing downstream would catch:
    it is walked upward here - `get_parent()`, then cut() - rather than handed to anything that
    validates it, so a wrong one would fail as a method call on a nil field several lines in.

    `new_node` needs none: it reaches update_positions immediately, which passes it to u(), and that
    says what it found. `known_parent` is optional and, when given, reaches u() the same way. ]]
    mexpru.check_node(old_node, "old_node")
    local parent = known_parent or old_node:get_parent()
    if not parent then
        mexpru.update_positions(new_node)
        mexpru.cut(old_node)
        return new_node
    end

    local kind = mexpru.u(parent).kind
    local rebuilt
    if kind == "horiz" then
        local children = mexpru.u(parent).children
        -- get_parent_idx() (a C++ scan of parent's subobjs) rather than index_of(): valid only
        -- because `children` was just read fresh and nothing has spliced it since. After any
        -- table.insert/remove the two lists are out of step - see the vert branch below.
        children[known_parent and mexpru.index_of(children, old_node)
                or old_node:get_parent_idx()] = new_node
        rebuilt = mexpru.horiz(fs, children, mexpru.u(parent).sz)
    elseif kind == "supsub" then
        local u = mexpru.u(parent)
        local base, sup, sub = u.base, u.sup, u.sub
        if same(base, old_node) then
            base = new_node
        elseif same(sup, old_node) then
            sup = new_node
        elseif same(sub, old_node) then
            sub = new_node
        else
            error("propagate_rebuild: old_node not found among parent " .. kind ..
                    "'s base/sup/sub")
        end
        --[[ A bigop rebuilds through its own constructor but finds its changed slot exactly as a
        supsub does - they carry the same base/sup/sub fields, which is the whole point. ]]
        rebuilt = mexpru.resupsub(fs, u, base, sup, sub)
    elseif kind == "frac" then
        local u = mexpru.u(parent)
        local num, den = u.num, u.den
        if same(num, old_node) then
            num = new_node
        elseif same(den, old_node) then
            den = new_node
        else
            error("propagate_rebuild: old_node not found among parent frac's num/den")
        end
        rebuilt = mexpru.frac(fs, num, den, u.sz)
    elseif kind == "vert" then
        local u = mexpru.u(parent)
        local slots = u.slots
        -- index_of(), not get_parent_idx(): a vert's own slot list is the same Lua table the
        -- caller may have just spliced (grow/shrink), so the C++ subobjs and this list can be out
        -- of step - the same reason handle_input()'s cascade stopped trusting get_parent_idx()
        -- after a table.remove().
        local idx = mexpru.index_of(slots, old_node)
        if not idx then
            error("propagate_rebuild: old_node not found among parent vert's own slots")
        end
        slots[idx] = new_node
        rebuilt = mexpru.vert(fs, slots, u.sz)
    elseif kind == "dress" then
        -- Only the target is ever replaced - the decoration is not content and takes no cursor.
        local u = mexpru.u(parent)
        rebuilt = mexpru.redress(fs, new_node, u, u.sz)
    else
        error("propagate_rebuild: don't know how to rebuild a '" .. tostring(kind) .. "' node")
    end

    if not known_parent then
        mexpru.cut(old_node)   -- a wrap's old node is a live child of new_node; never cut that
    end
    return mexpru.propagate_rebuild(fs, parent, rebuilt)
end

--[[ @brief Releases a node the caller has ALREADY detached - now, rather than at the next trace.
-- |
-- | LUA'S COLLECTOR IS TRACING, NOT REFCOUNTED: an unreferenced node stays alive-but-orphaned until
-- | a trace reaches it (one survived two forced collections). Any WEAK ref still pointing at it -
-- | container.pending_bracket, say - reads back as alive that whole time. That bit the
-- | bracket-pending path.
-- |
-- | ONE NODE IS ENOUGH: mexpr_t owns its children by shared_ptr, so everything beneath goes with it
-- | - provided the caller kept no stray local.
-- |
-- | @param node  node - checked; already spliced out of its parent, with propagate_rebuild done and
-- |              container.root reassigned
-- |
-- | @note Do not touch the node, or anything reached through it, afterwards.
-- |
-- | @date 2026-09-13 21:15
--]]
function mexpru.cut(node)
    --[[ An integrity check, for the same reason propagate_rebuild checks `old_node`:
    what is handed here is DETACHED, not read, so nothing downstream would notice it
    was never a node. ]]
    mexpru.check_node(node, "node")
    vc.force_release(node)
end

--[[ Profiler instrumentation (prof.lua), applied at the bottom so it lifts out in one go and no
call site knows about it. All no-ops while the profiler is off.

u() is deliberately NOT wrapped despite being the most-called function here: it is a single registry
push, so the wrapper costs several times the callee and the figure describes the profiler rather
than the code (it read 27us per call when tried). Count the cpp.* boundary crossings instead.

same()/index_of() are also held as file-locals, and every caller inside this file uses those - so
rebinding the table field instruments EXTERNAL callers only. Deliberate, to keep the pcall out of
this file's tight loops, but it means the counts are "calls from outside mexpru", not "calls".
@date 2026-09-08 08:55 ]]
local prof = require("prof")
mexpru.same              = prof.wrap("lua.same", mexpru.same)
mexpru.index_of          = prof.wrap("lua.index_of", mexpru.index_of)
mexpru.propagate_rebuild = prof.wrap("lua.propagate_rebuild", mexpru.propagate_rebuild)
mexpru.update_positions  = prof.wrap("lua.update_positions", mexpru.update_positions)

return mexpru

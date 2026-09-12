--[[ ==================================== WHAT THIS FILE OFFERS ====================================

ast_for(fontset: fontset, container: mexpru.container, decls: {decl}) -> node, ns, err
    The container's parse, rebuilt only when the container changed.
    nil plus a reason is an ordinary answer: a row being typed is
    invalid most of the time.

node_at(ns: ast.ns, mexpr_node)         -> ast node | nil
    The ast node a clicked glyph names. Nil is a real answer - some
    glyphs belong to no node, and an implicit MUL has no glyph at all.

options(fontset: fontset, container: mformula.container, decls: {decl}, mexpr_node) -> {option, ...}
    Every transformation that applies at that glyph, as
    {id, label, params}. Empty is the common answer.

run(ns: ast.ns, root: node, option: transforms.option) -> new_root | nil, reason
    Runs one option. A thin pass to transforms.apply, kept so callers
    say what they mean rather than unpacking an option themselves.

preview(fontset: fontset, container: mformula.container, decls: {decl}, option: option)
        -> new_root, ns, err
    What that option WOULD produce for this container, cached. Safe to
    call every frame; see the note there on why that is not merely an
    optimisation.

--- internal, not on the module table --------------------------------------------------------------
    option_key
@date 2026-09-12 01:25
================================================================================================= ]]

--[[
ast_gestures.lua - what can be done HERE? Turns a click on a glyph into a list of transformations
with their parameters already worked out.

THE ONE QUESTION THIS FILE ANSWERS. A gesture happens on an mexpr - a right-click on a `+` - and a
transformation happens on the AST. Something has to get from one to the other. That is this file,
and nothing else.

IT NAMES NO TRANSFORMATION. Which ones exist, which apply where, and how each is run are all
transforms.lua's, and this file reaches them only through transforms.offers and transforms.apply.
Before that split it carried a resolver and a dispatch table of its own, so adding a transformation
meant editing this file too and the two copies of "where does distribute apply" drifted apart.

WHAT IT DELIBERATELY DOES NOT DO:

  - it does not transform anything, and it does not catch anything. A refusal comes back from
    transforms.apply as a reason; a crash inside a plugin is not this file's to hide.
  - it knows nothing about menus, drawing, or where the click came from. It takes an mexpr node.
  - it does not walk the row. The correspondence was recorded during the parse (mexpr_ast's
    `tag_ast`), and re-deriving it here would be a second opinion about it.

THE AST IS SCRATCH, AND CACHED. Author, 2026-09-11: "ast is scratch until the new operation comes,
so it persists for a time and at a request it reparses to update". So it is rebuilt whenever the
container's own `version` has moved and kept otherwise - the same arrangement editor_definition's
sync_arity already uses for a definition's name, and for the same reason: the cache cannot go stale
without the version moving, so nothing has to remember to invalidate it.

A CLICK PERSISTS UNTIL A CHOICE IS MADE, and the choice ends the interaction: the transform makes a
new cell and focus moves there, so the options list never has to survive an edit to the cell it came
from. That is what lets an option carry AST IDS rather than a closure over the tree.
@date 2026-09-12 01:25
]]


local mexpru = require("mexpru")
local mexpr_ast = require("mexpr_ast")
local ast = require("ast")
local transforms = require("transforms")

local ast_gestures = {}

--[[ The container's parse, rebuilt only when the container has actually changed.

THE ENTRY EVERY OTHER FUNCTION HERE GOES THROUGH. A gesture needs a tree to resolve against, and
re-parsing a row on every frame of a held right-click would be both wasteful and wrong - the ids a
menu is holding would be replaced underneath it between frames.

Core - THE CACHE CANNOT GO STALE. It is keyed on `container.version`, which mformula bumps on every
real tree edit and on nothing else, so a hit means the row is textually the same row. Nothing has to
remember to invalidate it; the same arrangement editor_definition's sync_arity uses. A cursor move
or a click does not bump the version, which is exactly right: neither changes what the row says.

Detail: the cache lives on the container as `_ast_cache`, so it travels with the row and dies with
it. A failed parse is cached too - a row that does not parse is not worth re-attempting sixty times
a second, and it will not start parsing until something changes it, which bumps the version anyway.

Params:
    fontset    passed through to mexpr_ast.build, which needs it to read glyphs
    container  the mformula container to parse; also where the cache is kept
    decls      content.declarations_before(...).order, same as every other caller of build

Returns node, ns, err. nil plus a reason is an ORDINARY state, not a failure worth reporting: a row
being typed is invalid most of the time, and a gesture on an unparseable row simply has no options.
@date 2026-09-12 02:05 ]]
function ast_gestures.ast_for(fontset, container, decls)
    mexpru.check_container(container)
    --[[ `decls` is the ORDER LIST from content.declarations_before, not the container it came in:
    a list has no shape to seal, so what can be said is that it is one. nil is not allowed - a
    caller with nothing to declare passes {}, and nil here would silently parse every name as free.
    ]]
    assert(type(decls) == "table", "ast_for needs a declaration list")
    local cache = container._ast_cache
    local version = container.version or 0
    if cache and cache.version == version then
        return cache.node, cache.ns, cache.err
    end
    local node, err, ns = mexpr_ast.build(fontset, container, decls)
    container._ast_cache = {version = version, node = node, ns = ns, err = err}
    return node, ns, err
end

--[[ The ast node a click on `mexpr_node` names, or nil.

Reads the tag the parse left on the mexpr (`u(_).ast_id`) and looks it up in the namespace that
parse produced. Nil is a real answer: a glyph may belong to no node at all - an implicit MUL is
written with nothing, and a bracket that precedence made unnecessary carries no CELL.

THROUGH slot_atom, because a clicked glyph may be wrapped: a bracket carrying an exponent is a
supsub base, and reading the outer node would find the supsub rather than the thing clicked. This
is the same blind spot section 8 of the design doc warns about.
@date 2026-09-11 19:00 ]]
function ast_gestures.node_at(ns, mexpr_node)
    ast.check_ns(ns)
    --[[ NIL IS A REAL ARGUMENT, not a mistake: a right-click on empty space resolves to no glyph
    at all, and every caller here would otherwise guard for it itself. Anything that is NOT nil has
    to be a real mexpr node, though - mexpru.u() on something else fails deep inside the binding
    layer with a message about the C++ type. ]]
    if mexpr_node == nil then
        return nil
    end
    mexpru.check_node(mexpr_node, "mexpr_node")

    -- `u()` always returns a table, so the old `u and` could not fire.
    local id = mexpru.u(mexpr_node).ast_id
    if not id then
        local atom = mexpru.slot_atom(mexpr_node)
        id = atom and mexpru.u(atom).ast_id
    end
    if not id then
        return nil
    end

    --[[ THROUGH ast.node_of, which is the only way to read a namespace: it checks what it found,
    so this file does not have to remember that the result becomes a transformation's parameter and
    would be RUN against rather than merely printed. A MISS is ordinary - an id from a previous
    parse answers to nothing in this namespace - and comes back nil. ]]
    return ast.node_of(ns, id)
end

--[[ Every transformation that applies at `mexpr_node`, as

    {id = "distribute", label = "Distribute", params = {add = <ast id>}}

IDS, NOT A CLOSURE, and not the nodes themselves. An option is a description of a transformation
that COULD be run: it survives being shown in a menu, it can be logged, and it cannot accidentally
keep a whole tree alive.

AIM MATTERS: the options are the ones for the GLYPH under the pointer, not for the expression around
it. Which glyphs name what is each transformation's own rule and lives with it; this file only
resolves the click to a node and asks.

AN EMPTY LIST IS THE COMMON ANSWER, and that is not a failure - it is what a right-click on a plain
`a+b` should give. What the caller does with an empty list is the caller's business, and content.lua
draws it as an empty menu rather than as nothing: see its own note for why. This file only reports.
@date 2026-09-12 01:25 ]]
function ast_gestures.options(fontset, container, decls, mexpr_node)
    local root, ns = ast_gestures.ast_for(fontset, container, decls)
    if not root then
        return {}
    end
    return transforms.offers(ns, root, ast_gestures.node_at(ns, mexpr_node))
end

--[[ Runs one option against a tree.

WHERE A GESTURE BECOMES A TRANSFORMATION. Everything up to here describes what could be done; this
is the call that does it, and it is the only one in this file that changes anything.

Core - IT DECIDES NOTHING. The option already names the transformation and carries its parameters,
and transforms.lua alone knows how to reach a plugin. So this unpacks and forwards, and that is the
whole of it. It stays a named function rather than being inlined at each call site because "run this
option" is what every one of them means, and because spreading an option's shape into three
arguments is how that shape ends up known in places that should not know it.

Detail: no catching. A refusal arrives as nil plus a reason because transforms.apply converted it at
the boundary; a crash inside a plugin is raised through here untouched, deliberately, so a broken
transformation cannot masquerade as an inapplicable one.

Params:
    ns, root   the namespace and tree the option's ids refer to - from ast_for above, and they must
               be from the SAME version the option was built against
    option     {id, label, params}, as options() produced it

Returns the new root, or nil plus the reason. The source tree is untouched either way.
@date 2026-09-12 02:05 ]]
function ast_gestures.run(ns, root, option)
    --[[ Checked HERE, unlike options() above: that one forwards every argument untouched into a
    function that checks it, while this one reads `option.id` and `option.params` itself. A function
    that USES a value owes the check; one that only passes it on does not. ]]
    transforms.check_option(option)
    return transforms.apply(option.id, ns, root, option.params)
end

--[[ A stable string for one option, for use as a cache key.

EVERY PARAMETER, SORTED. It used to read `option.params.add` - distribute's parameter name, written
into a file that is not supposed to know any transformation's parameters. The second transformation
to take something other than `add` would have keyed as "...:nil" and been served the first one's
cached tree, on an expression that had not changed. Sorting is what makes the key independent of the
order pairs() happens to walk in.
@date 2026-09-12 01:25 ]]
local function option_key(option)
    local names = {}
    for name in pairs(option.params or {}) do
        names[#names + 1] = name
    end
    table.sort(names)
    local parts = {tostring(option.id)}
    for _, name in ipairs(names) do
        parts[#parts + 1] = name .. "=" .. tostring(option.params[name])
    end
    return table.concat(parts, ":")
end

--[[ What `option` would produce for this container: the new root, the namespace it lives in, or nil
plus a reason. CACHED, exactly like the parse above and keyed on the same version.

WHY IT MUST BE CACHED and is not merely faster for being so: a transformation MINTS NODES, and the
namespace they are minted into is the container's own cached one. Run every frame - which is what a
panel that previews it does - the ids climb by a handful per frame forever, and the namespace grows
without bound while nothing on screen changes. Seen live, 2026-09-11: an untouched preview walked its
ids from 368 to 5513 in the time it took to take two screenshots.

KEYED ON THE OPTION TOO, not just the version, because two options on one unchanged expression are
two different answers - and the ids in an option's params already name nodes in this version's tree,
so the pair is exactly what the answer depends on.
@date 2026-09-12 01:25 ]]
function ast_gestures.preview(fontset, container, decls, option)
    --[[ Only `option` is checked here. `fontset`, `container` and `decls` go straight into ast_for,
    which checks them - re-checking would put the same guard twice on one path. This one is read by
    option_key below before anything else happens to it. ]]
    transforms.check_option(option)
    local root, ns, err = ast_gestures.ast_for(fontset, container, decls)
    if not root then
        return nil, nil, err
    end
    local version = container.version or 0
    local key = option_key(option)
    local cache = container._transform_cache
    if cache and cache.version == version and cache.key == key then
        return cache.root, ns, cache.err
    end
    local new_root, terr = ast_gestures.run(ns, root, option)
    container._transform_cache = {version = version, key = key, root = new_root, err = terr}
    return new_root, ns, terr
end

return ast_gestures

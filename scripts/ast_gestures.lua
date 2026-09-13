--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- |
-- | ast_for(fontset: fontset, container: mexpru.container, decls: {decl}) -> node, ns, err
-- |     The container's parse, rebuilt only when the container changed.
-- |     nil plus a reason is an ordinary answer: a row being typed is
-- |     invalid most of the time.
-- |
-- | node_at(ns: ast.ns, mexpr_node: mexpr node | nil) -> ast node | nil
-- |     The ast node a clicked glyph names. Nil is a real answer - some
-- |     glyphs belong to no node, and an implicit MUL has no glyph at all.
-- |
-- | options(fontset: fontset, container: mexpru.container, decls: {decl},
-- |         mexpr_node: mexpr node | nil) -> {option, ...}
-- |     Every transformation that applies at that glyph, as
-- |     {id, label, params}. Empty is the common answer.
-- |
-- | run(ns: ast.ns, root: node, option: transforms.option) -> new_root | nil, reason
-- |     Runs one option. A thin pass to transforms.apply, kept so callers
-- |     say what they mean rather than unpacking an option themselves.
-- |
-- | preview(fontset: fontset, container: mexpru.container, decls: {decl},
-- |         option: transforms.option) -> new_root, ns, err
-- |     What that option WOULD produce for this container, cached. Safe to
-- |     call every frame; see the note there on why that is not merely an
-- |     optimisation.
-- |
-- | --- internal, not on the module table ---------------------------------------------------------
-- |     option_key
-- |
-- | @date 2026-09-13 19:30
-- | ===============================================================================================
--]]

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

--[[ @brief The container's parse, rebuilt only when the container has actually changed.
-- |
-- | THE ENTRY EVERY OTHER FUNCTION HERE GOES THROUGH. A gesture needs a tree to resolve against,
-- | and re-parsing a row on every frame of a held right-click would be both wasteful and wrong -
-- | the ids a menu is holding would be replaced underneath it between frames.
-- |
-- | KEYED ON `container.version`, which mformula bumps on every real tree edit and on nothing else,
-- | so nothing has to remember to invalidate it - the same arrangement editor_definition's
-- | sync_arity uses. A cursor move or a click does not bump it: neither changes what the row says.
-- |
-- | @details The cache lives on the container as `_ast_cache`, so it travels with the row and dies
-- |          with it. A failed parse is cached too; it cannot start parsing until an edit bumps the
-- |          version anyway.
-- |
-- | @param fontset    fontset - passed through to mexpr_ast.build
-- | @param container  mexpru.container - checked; also where the cache is kept
-- | @param decls      {mexpr_ast.decl} - content.declarations_before(...).order. Required: a caller
-- |                   with nothing to declare passes {}
-- | @return node | nil, ast.ns, string | nil - nil plus a reason is an ORDINARY state: a row being
-- |         typed is invalid most of the time, and a gesture on it simply has no options
-- |
-- | @note `decls` IS NOT PART OF THE KEY. Editing a definition above this row changes what its
-- |       names resolve to without bumping this container's version, and the old parse is served
-- |       until the row itself is edited.
-- |
-- | @date 2026-09-13 19:30
--]]
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

--[[ @brief The ast node a click on `mexpr_node` names, or nil.
-- |
-- | READS THE TAG THE PARSE LEFT on the mexpr (`u(_).ast_id`) and looks it up in the namespace that
-- | parse produced, through ast.node_of - which checks what it found, since the result becomes a
-- | transformation's parameter and is run against.
-- |
-- | THROUGH slot_atom when the node itself carries no tag, because a clicked glyph may be wrapped:
-- | a bracket carrying an exponent is a supsub base, and reading the outer node would find the
-- | supsub rather than the thing clicked - the blind spot section 8 of the design doc warns about.
-- |
-- | @param ns          ast.ns - checked; the namespace of the parse that tagged the row
-- | @param mexpr_node  mexpr node | nil - nil (empty space) answers nil; anything else is checked
-- | @return ast node | nil - nil is a real answer: an implicit MUL is written with nothing, a
-- |         bracket that precedence made unnecessary carries no CELL, and an id from a previous
-- |         parse answers to nothing in this namespace
-- |
-- | @date 2026-09-13 19:30
--]]
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

--[[ @brief Every transformation that applies at the glyph `mexpr_node`.
-- |
-- |     {id = "distribute", label = "Distribute", params = {add = <ast id>}}
-- |
-- | IDS, NOT A CLOSURE, and not the nodes themselves: an option survives being shown in a menu, can
-- | be logged, and cannot accidentally keep a whole tree alive.
-- |
-- | AIM MATTERS: the options are the ones for the GLYPH under the pointer, not for the expression
-- | around it. Which glyphs name what is each transformation's own rule; this file only resolves
-- | the click to a node and asks transforms.offers.
-- |
-- | @param fontset     fontset - forwarded to ast_for
-- | @param container   mexpru.container - forwarded to ast_for, which checks it
-- | @param decls       {mexpr_ast.decl} - forwarded to ast_for
-- | @param mexpr_node  mexpr node | nil - forwarded to node_at, which checks it
-- | @return {transforms.option, ...} - EMPTY IS THE COMMON ANSWER, and also what an unparseable row
-- |         gives. content.lua draws an empty list as an empty menu rather than as nothing
-- |
-- | @date 2026-09-13 19:30
--]]
function ast_gestures.options(fontset, container, decls, mexpr_node)
    local root, ns = ast_gestures.ast_for(fontset, container, decls)
    if not root then
        return {}
    end
    return transforms.offers(ns, root, ast_gestures.node_at(ns, mexpr_node))
end

--[[ @brief Runs one option against a tree. WHERE A GESTURE BECOMES A TRANSFORMATION.
-- |
-- | IT DECIDES NOTHING. The option already names the transformation and carries its parameters,
-- | and transforms.lua alone knows how to reach a plugin, so this unpacks and forwards. It stays a
-- | named function because "run this option" is what every call site means, and spreading an
-- | option's shape into three arguments is how that shape ends up known where it should not be.
-- |
-- | NO CATCHING. A refusal arrives as nil plus a reason because transforms.apply converted it; a
-- | crash inside a plugin is raised through here untouched, so a broken transformation cannot
-- | masquerade as an inapplicable one.
-- |
-- | @param ns      ast.ns - checked by transforms.apply
-- | @param root    node - checked by transforms.apply. Both must be from the SAME version the
-- |                option was built against, since its ids refer to them
-- | @param option  transforms.option - checked; as options() produced it
-- | @return node | nil, string - the new root, or nil and the reason. The source tree is untouched
-- |         either way
-- |
-- | @date 2026-09-13 19:30
--]]
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

--[[ @brief What `option` would produce for this container, CACHED like the parse.
-- |
-- | IT MUST BE CACHED, not merely faster for it: a transformation MINTS NODES into the container's
-- | own cached namespace. Run every frame - what a panel that previews it does - the ids climb by a
-- | handful per frame and the namespace grows without bound while nothing on screen changes. Seen
-- | live, 2026-09-11: an untouched preview walked its ids from 368 to 5513 in two screenshots.
-- |
-- | KEYED ON VERSION AND OPTION, because two options on one unchanged expression are two different
-- | answers, and the ids in an option's params already name nodes in this version's tree.
-- |
-- | @details One entry is kept, `_transform_cache` on the container: previewing two options in
-- |          alternation re-runs each on every switch. A refusal is cached like a result.
-- |
-- | @param fontset    fontset - forwarded to ast_for
-- | @param container  mexpru.container - forwarded to ast_for, which checks it
-- | @param decls      {mexpr_ast.decl} - forwarded to ast_for
-- | @param option     transforms.option - checked
-- | @return node | nil, ast.ns | nil, string | nil - the new root, the namespace it lives in, and
-- |         the reason when there is no root: the row did not parse, or the plugin refused
-- |
-- | @date 2026-09-13 19:30
--]]
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

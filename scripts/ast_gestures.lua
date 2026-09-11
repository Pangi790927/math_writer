--[[
ast_gestures.lua - what can be done HERE? Turns a click on a glyph into a list of transformations
with their parameters already worked out.

THE ONE QUESTION THIS FILE ANSWERS. A gesture happens on an mexpr - a right-click on a `+` - and a
transformation happens on the AST. Something has to get from one to the other, decide which
transformations apply, and bind their parameters. That is this file, and nothing else.

WHAT IT DELIBERATELY DOES NOT DO:

  - it does not transform anything. An option names a transform and its parameters; running it is
    transforms.lua's job. Keeping "what applies" apart from "how it is done" is what stops every
    new transform needing a second home in the menu code.
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
@date 2026-09-11 19:00
]]

local mexpru = require("mexpru")
local mexpr_ast = require("mexpr_ast")
local ast = require("ast")
local transforms = require("transforms")

local ast_gestures = {}

--[[ The AST for this container, rebuilt only when the container has changed since last time.

`decls` is content.declarations_before(...).order, same as every other caller of build. Returns
node, ns - or nil plus the parse error, which is an ordinary state: a row being typed is invalid
most of the time, and a gesture on an unparseable row simply has no options.
@date 2026-09-11 19:00 ]]
function ast_gestures.ast_for(fontset, container, decls)
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
    if not ns or not mexpr_node then
        return nil
    end
    local u = mexpru.u(mexpr_node)
    local id = u and u.ast_id
    if not id then
        local atom = mexpru.slot_atom(mexpr_node)
        id = atom and mexpru.u(atom).ast_id
    end
    return id and ns.by_id[id] or nil
end

--[[ The sum a SIGN belongs to, or nil. `num` is the NUM a minus glyph named.

A sign is not a node of its own: `a-b` is ADD(a, MUL(NUM(-1), b)) and `a-3` is ADD(a, NUM(-3)), so
the minus is tagged one or two levels under the sum depending on whether the term has other factors.
Both shapes are the same glyph doing the same job, which is why this exists rather than a plain
parent test.
@date 2026-09-12 00:10 ]]
local function sum_of_sign(num, parents)
    local up = parents[num.id]
    if up and up.type == ast.MUL and up[1] == num then
        up = parents[up.id]
    end
    if up and up.type == ast.ADD then
        return up
    end
    return nil
end

--[[ The ADD a click NAMES, and that ADD's parent. nil when the click did not land on a sum's own
operator.

THE GLYPH MUST BE THE OPERATOR - a `+`, or the `-` that carries a term's sign. It used to climb from
wherever it landed to the nearest sum above, so clicking a TERM offered the transformation too. That
was mine to invent and it was wrong: reported 2026-09-11, "Something is wrong I can wright click the
d in a(b+d) and apply distribute". A letter is one operand of one term; reading it as "the sum around
it" makes the gesture ambiguous exactly where sums nest, and there is no way to say which sum was
meant once aim stops mattering.

So the answer is now the node the parse TAGGED to the glyph under the pointer, and nothing above it.
@date 2026-09-12 00:10 ]]
local function add_at(node, parents)
    local add
    if node.type == ast.ADD then
        add = node
    elseif node.type == ast.NUM then
        add = sum_of_sign(node, parents)
    end
    if not add then
        return nil
    end
    return add, parents[add.id]
end

--[[ Every transformation that applies at `mexpr_node`, as

    {id = "distribute", label = "Distribute", params = {add = <ast id>}}

IDS, NOT A CLOSURE, and not the nodes themselves. An option is a description of a transformation
that COULD be run: it survives being shown in a menu, it can be logged, and it cannot accidentally
keep a whole tree alive. The caller runs it by handing the id and params to transforms.lua.

AIM MATTERS: the options are the ones for the GLYPH under the pointer, not for the expression around
it. A `+` names its sum; the letter beside it names itself and offers nothing.

AN EMPTY LIST IS THE COMMON ANSWER for now, and that is not a failure - it is what a right-click on
a plain `a+b` should give, because there is nothing there to distribute into. What the caller does
with an empty list is the caller's business, and content.lua draws it as an empty menu rather than as
nothing: see its own note for why. This file only reports.
@date 2026-09-11 19:00 ]]
function ast_gestures.options(fontset, container, decls, mexpr_node)
    local out = {}
    local root, ns = ast_gestures.ast_for(fontset, container, decls)
    if not root then
        return out
    end
    local node = ast_gestures.node_at(ns, mexpr_node)
    if not node then
        return out
    end

    local parents = ast.parent_map(root)
    local add, add_parent = add_at(node, parents)

    --[[ DISTRIBUTE needs a product to distribute INTO - the sum's own parent must be a MUL. `a+b`
    on its own offers nothing; `a(b+c)` offers it on the `+`, on `b`, and on `c`. ]]
    if add and add_parent and add_parent.type == ast.MUL then
        out[#out + 1] = {id = "distribute", label = "Distribute", params = {add = add.id}}
    end

    return out
end

--[[ How each transformation is CALLED from an option - the one place that knows a transform's
parameter names.

An option carries `params` because the parameters differ per transform: distribute takes the sum to
distribute, and the next one will take something else. Keeping the mapping here rather than at every
call site means running an option is `ast_gestures.run(ns, root, option)` wherever it happens -
today the F6 preview, tomorrow the menu's own commit.
@date 2026-09-11 22:10 ]]
local APPLY = {
    distribute = function(ns, root, params) return transforms.distribute(ns, root, params.add) end,
}

--[[ Runs one option against a tree. Returns the new root, or nil plus the transform's own reason.
@date 2026-09-11 22:10 ]]
function ast_gestures.run(ns, root, option)
    local apply = APPLY[option.id]
    if not apply then
        return nil, "no such transformation: " .. tostring(option.id)
    end
    return apply(ns, root, option.params)
end

--[[ What `option` would produce for this container: the new root, the namespace it lives in, or nil
plus a reason. CACHED, exactly like the parse above and keyed on the same version.

WHY IT MUST BE CACHED and is not merely faster for being so: a transformation MINTS NODES, and the
namespace they are minted into is the container's own cached one. Run every frame - which is what a
panel that previews it does - the ids climb by a handful per frame forever, and the namespace grows
without bound while nothing on screen changes. Seen live, 2026-09-11: an untouched preview walked its
ids from 368 to 5513 in the time it took to take two screenshots.

KEYED ON THE OPTION TOO, not just the version, because two options on one unchanged expression are
two different answers - and the id in an option's params already names a node in this version's
tree, so the pair is exactly what the answer depends on.
@date 2026-09-11 22:10 ]]
function ast_gestures.preview(fontset, container, decls, option)
    local root, ns, err = ast_gestures.ast_for(fontset, container, decls)
    if not root then
        return nil, nil, err
    end
    local version = container.version or 0
    local key = tostring(option.id) .. ":" .. tostring(option.params and option.params.add)
    local cache = container._transform_cache
    if cache and cache.version == version and cache.key == key then
        return cache.root, ns, cache.err
    end
    local new_root, terr = ast_gestures.run(ns, root, option)
    container._transform_cache = {version = version, key = key, root = new_root, err = terr}
    return new_root, ns, terr
end

return ast_gestures

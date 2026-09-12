--[[ ==================================== WHAT THIS FILE OFFERS ====================================

PUBLISHED THROUGH THE REGISTRY, not through a module table. `transforms.register` at the bottom of
this file hands the two functions below to transforms.lua, which is the only caller either of them
ever has - so they are external in every sense that matters, and being `local` is an artefact of how
a plugin is delivered rather than a statement about who may call them. The file's `return` is a
marker; the spec table is the interface.

offer(ctx: transforms.ctx)              -> option | nil
    Whether this transformation applies where the user pointed, and with
    which parameters. nil - it does not apply here - is the common
    answer. Called on every right-click, so it stays cheap.

apply(ctx: transforms.ctx)              -> node
    Multiplies the sum out. Refuses through ctx.check when the gesture
    did not land on a sum inside a product. Leaves the source tree
    untouched and shares every subtree it did not have to rebuild.

Both take the ctx transforms.lua builds - {ns, root, node, params, check, parents()} - and neither
is reached by name from anywhere. From outside, this whole file is:

    local option = transforms.offers(ns, root, node)[1]   -- offer() built its params
    transforms.apply(option.id, ns, root, option.params)

THE PARAMS COME FROM THE OFFER. They are a sealed `distribute.params`, built only by offer() and
checked by apply() on the way back in, so a hand-written `{add = <id>}` is refused however right the
key looks. Anything that wants to run this asks what is offered first, which is what the right-click
menu and the F6 preview already do.

--- internal ---------------------------------------------------------------------------------------
    is_one, product_of, replace_in, sum_of_sign, add_at, PARAMS_FIELDS, PARAMS_SHAPE
@date 2026-09-12 22:15
================================================================================================= ]]

--[[
transform_distribute.lua - multiplying a sum out: x(b + c)y becomes xby + xcy.

A PLUGIN, and the first one, so it is also the worked example of what a transformation file is: it
registers itself into transforms.lua at the bottom and is reached only through transforms.apply.
Delete its require line there and the transformation is gone from the application - no menu code,
no dispatch table and no gesture resolver mentions it by name.

BOTH HALVES OF ONE TRANSFORMATION LIVE TOGETHER. `offer` decides where the gesture applies and
`apply` performs it, and they are the same knowledge read in two directions - "the click must be on
an ADD whose parent is a MUL" is exactly the condition apply refuses on. Splitting them across two
files is how they drift, which is what happened while the resolver lived in ast_gestures.lua and
distribute lived here.

@date 2026-09-12 01:25
]]


local ast = require("ast")
local sealed = require("sealed")
local transforms = require("transforms")

local check = transforms.check
local check_ctx = transforms.check_ctx

--[[ THE `params` CONTAINER - what this transformation needs in order to run, and the only thing it
receives beyond the tree itself.

ITS CREATOR IS `offer` BELOW, which is the only place one is ever built: the whole point of the
option an offer returns is that apply can be handed it back later, unchanged, so there is exactly
one producer and one consumer and they are both in this file. `apply` checks what arrived rather
than trusting it, because between the two lies a menu that can sit open across frames, a cache, a
savefile of activation state and content.lua - none of which this file can see.

The names here are this plugin's own; transforms.lua declares `params` as a field of an option and
does not know what is in it, which is why the seal belongs here rather than there. It is also the
one shape whose field list is repeated: `params = {"add"}` in the register call at the bottom is
what the dispatcher checks arrived, and this is what says what it MEANS.
@date 2026-09-12 22:15 ]]
local PARAMS_FIELDS = {
    add = "ast id of the ADD to multiply out; its parent must be the MUL",
}
local PARAMS_SHAPE = sealed.declare("distribute", "params", PARAMS_FIELDS)

--[[ Is this the number 1 - the factor a product may drop without changing?
@date 2026-09-11 20:00 ]]
local function is_one(node)
    return type(node) == "table" and node.type == ast.NUM
            and node[1] == 1 and node[2] == 1 and node[3] == 1
end

--[[ A product of `factors`, tidied.

THE CLEAN-UP HAPPENS IN THE SAME STEP, on request - author, 2026-09-11: "and yes, we clean back
up". Distribution routinely leaves a product of one thing, or a stray 1 where a term was just the
unit, and carrying those forward would make every later step read around debris the transform itself
created.

ORDER IS PRESERVED, and that is not incidental: multiplication here is not assumed commutative -
vectors have products, and a cross product does not commute. Distribution is valid without
commutativity; REORDERING is a different transformation and has to be asked for separately.

Returns a MUL of what survived, or the single survivor unwrapped, or the number 1 when everything
was dropped - so the caller never has to special-case a one-factor product.
@date 2026-09-11 20:00 ]]
local function product_of(ns, factors)
    local kept = {}
    for _, f in ipairs(factors) do
        if not is_one(f) then
            kept[#kept + 1] = f
        end
    end
    if #kept == 0 then
        return ast.new_num(ns, 1, 1, 1)
    end
    if #kept == 1 then
        return kept[1]
    end
    return ast.new_mul(ns, table.unpack(kept))
end

--[[ Rebuilds the path from `root` down to `old`, with `new` in its place.

SHARES EVERY UNTOUCHED SUBTREE - the same node objects, with their own ids - and makes a new node
only for the ancestors on the path. Author, 2026-09-11: "we want the transformation to reuse parts
of the graph in the mexpr, changing litle let's us cut the graph in just the right parts to repair
it with minimal stitches". Identity is then what says which regions of the old mexpr can be reused
verbatim, which is how the user's own spacing survives a step.

Nothing is mutated: the source tree is left exactly as it was, so the cell it belongs to stays
valid - section 1's immutable cells.

Refuses when `old` is not reachable from `root`, which can only mean the caller mixed two trees.
@date 2026-09-11 20:00 ]]
local function replace_in(ns, root, parents, old, new)
    while old ~= root do
        local parent = parents[old.id]
        check(parent, "the node is not in this tree")
        local rebuilt = ast.new(ns, parent.type)
        for i = 1, #parent do
            rebuilt[i] = (parent[i] == old) and new or parent[i]
        end
        old, new = parent, rebuilt
    end
    return new
end

--[[ The ADD a negative term's NUM belongs to, or nil.

`a-b` is ADD(a, MUL(NUM(1,1,-1), b)), so the minus glyph's node sits one or two levels under the
sum it is a term of - one when the term was a bare number, two when the sign became a factor. This
climbs exactly that far and no further.
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
was invented rather than asked for, and it was wrong: reported 2026-09-11, "Something is wrong I can
wright click the d in a(b+d) and apply distribute". A letter is one operand of one term; reading it
as "the sum around it" makes the gesture ambiguous exactly where sums nest, and there is no way to
say which sum was meant once aim stops mattering.

So the answer is the node the parse TAGGED to the glyph under the pointer, and nothing above it.
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

--[[ Whether distribution applies at the glyph the user pointed at, and with what parameters.

HALF THE CONTRACT with transforms.lua - the half that is asked, unprompted, on every right-click
anywhere in a formula. `apply` below is the other half, and the two must agree: every condition this
one checks before offering is a condition apply refuses on, so an option that appears can always be
run and one that never appears can never be reached by accident.

Core - WHICH GLYPH COUNTS. The pointer must be on the sum's own OPERATOR: a `+`, or the `-` that
carries a term's sign. Those are the glyphs the parse tagged to the ADD (mexpr_ast's `tag_ast`), and
`add_at` above resolves exactly them and nothing above them. Aim is the whole gesture - a letter is
one operand of one term, and reading it as "the sum around it" makes the offer ambiguous wherever
sums nest.

Core - AND A PRODUCT TO DISTRIBUTE INTO. The sum's own parent must be a MUL, because distribution
needs something to multiply through. `a+b` standing alone offers nothing however precisely it is
clicked; `a(b+c)` offers it on the `+`, and `a(b-c)` on the `-`.

Detail: it reads the tree and nothing else - no cursor is moved, no node is created, nothing is
cached. Asking costs a parent_map walk that transforms.lua has usually already paid for, which is
what makes it safe to call on every click.

Params: `ctx`, built by transforms.lua. Three of its fields are read -
    ctx.node       the ast node the click resolved to. NOT the root; this is the aim.
    ctx.parents()  the memoized child-id -> parent map for ctx.root.
    ctx.ns         unused here, present for transformations that mint or look up nodes.
`ctx.params` is absent for an offer - parameters are what an offer PRODUCES, not what it receives.

Returns one option - `{id, label, params = {add = <ast id>}}` - or nil when it does not apply. The
option carries an ID rather than the node, so it can sit in a menu across frames without keeping a
tree alive.

Note: nil is the ordinary answer, not a failure. Most glyphs in most formulas are not a sum's
operator, and content.lua draws the resulting empty list as an EMPTY MENU rather than as nothing, so
that "understood, and there is nothing here" cannot be mistaken for a dead binding.
@date 2026-09-12 02:05 ]]
local function offer(ctx)
    check_ctx(ctx)
    local add, parent = add_at(ctx.node, ctx.parents())
    if not (add and parent and parent.type == ast.MUL) then
        return nil
    end
    return transforms.option("distribute", "Distribute", PARAMS_SHAPE.wrap{add = add.id})
end

--[[ Multiplies the sum out.

    x(b + c)y   ->   xby + xcy

`params.add` names the ADD; its parent must be the MUL. That is the whole input - the gesture worked
it out already, and this needs to know nothing about how the click arrived.

WHAT IS SHARED AND WHAT IS COPIED, decided by one question only: does this subtree end up in the
output MORE THAN ONCE? Only the factors surrounding the sum do - `a` in `a(b+c)` becomes the `a` of
two terms - so those are copied from the second term on, because one node cannot sit in two places
under one id.

THE SUM'S OWN TERMS ARE NEVER COPIED. Each appears exactly once in the result: `b` lands in the
first term and `c` in the second, and nothing needs a second `c`. Copying them anyway was the
original shape here and it was wrong twice over - author, 2026-09-12: "there is no point in creating
a new reference". It minted nodes nothing was ever drawn for, so the writer that rebuilds the mexpr
had to re-render glyphs it could have carried across verbatim, losing whatever decoration and
spacing they had. Cheap for a bare letter; a whole subtree for `2x` or a fraction.

What is left is the smallest diff the algebra allows, which is the point: the untouched parts of the
old drawing stay usable.

REFUSES rather than widening, the way selection does everywhere: not an ADD, no parent, parent not a
MUL. A transformation offered where it does not apply is how one ends up running on the wrong nodes.

Returns the new root. Untouched nodes keep their ids and the result lives in the same namespace.
@date 2026-09-12 01:25 ]]
local function apply(ctx)
    check_ctx(ctx)
    local ns, root = ctx.ns, ctx.root
    --[[ ON RETRIEVAL, not on trust: the table being read here is the one `offer` built, but it has
    travelled through a menu and a cache to get back, and the metatable is what says it is still
    that table rather than one somebody assembled with the right-looking key. ]]
    PARAMS_SHAPE.check(ctx.params, "params")
    local add = ast.node_of(ns, ctx.params.add)
    check(add and add.type == ast.ADD, "distribute needs a sum")

    local parents = ctx.parents()
    local mul = parents[add.id]
    check(mul and mul.type == ast.MUL, "distribute needs a product around the sum")

    -- Where the sum sits among the product's factors: everything before it stays before, and
    -- everything after stays after, in every term.
    local at
    for i = 1, #mul do
        if mul[i] == add then
            at = i
            break
        end
    end
    check(at, "the sum is not a factor of that product")

    local terms = {}
    for t = 1, #add do
        local factors = {}
        for i = 1, #mul do
            if i == at then
                -- Used once, so it travels as itself - see the header.
                factors[#factors + 1] = add[t]
            else
                --[[ The first term keeps the original factor nodes; the rest take copies. See the
                header on why the asymmetry is the point rather than an oversight. ]]
                factors[#factors + 1] = (t == 1) and mul[i] or ast.copy_fresh(ns, mul[i])
            end
        end
        terms[#terms + 1] = product_of(ns, factors)
    end

    local expanded = ast.new_add(ns, table.unpack(terms))
    return replace_in(ns, root, parents, mul, expanded)
end

--[[ DEFAULT ACTIVE, unlike a plugin dropped in from outside. This one ships with the project and
the author asked for it on: "distribute will be default actuvated". An unticked `transforms.save`
entry is what turns it off again, and the absence of any entry leaves it on.
@date 2026-09-12 02:30 ]]
transforms.register{
    id = "distribute",
    label = "Distribute",
    params = {"add"},
    default_active = true,
    offer = offer,
    apply = apply,
}

return true

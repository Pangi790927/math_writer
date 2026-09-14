--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- |
-- | PUBLISHED THROUGH THE REGISTRY, not through a module table. `transforms.register` at the bottom
-- | of this file hands the two functions below to transforms.lua, which is the only caller either
-- | of them ever has - so they are external in every sense that matters, and being `local` is an
-- | artefact of how a plugin is delivered rather than a statement about who may call them. The
-- | file's `return` is a marker; the spec table is the interface.
-- |
-- | offer(ctx: transforms.ctx)              -> option | nil
-- |     Whether this transformation applies where the user pointed, and with
-- |     which parameters. nil - it does not apply here - is the common
-- |     answer. Called on every right-click, so it stays cheap.
-- |
-- | apply(ctx: transforms.ctx)              -> node
-- |     Multiplies the sum out. Refuses through ctx.check when the gesture
-- |     did not land on a sum inside a product. Leaves the source tree
-- |     untouched and shares every subtree it did not have to rebuild.
-- |
-- | Both take the ctx transforms.lua builds - {ns, root, node, params, check, parents()} - and
-- | neither is reached by name from anywhere. From outside, this whole file is:
-- |
-- |     local option = transforms.offers(ns, root, node)[1]   -- offer() built its params
-- |     transforms.apply(option.id, ns, root, option.params)
-- |
-- | THE PARAMS COME FROM THE OFFER. They are a sealed `distribute.params`, built only by offer()
-- | and checked by apply() on the way back in, so a hand-written `{add = <id>}` is refused however
-- | right the key looks. Anything that wants to run this asks what is offered first, which is what
-- | the right-click menu and the F6 preview already do.
-- |
-- | --- internal, not on the module table ---------------------------------------------------------
-- |     is_one, product_of, replace_in, sum_of_sign, add_at, PARAMS_FIELDS, PARAMS_SHAPE
-- |
-- | @date 2026-09-13 16:00
-- | ===============================================================================================
--]]

--[[ @file transforms/distribute.lua
-- | @brief Multiplying a sum out: x(b + c)y becomes xby + xcy.
-- |
-- | A PLUGIN, and the first one, so it is also the worked example of what a transformation file
-- | is: it registers itself into transforms.lua at the bottom and is reached only through
-- | transforms.apply. Delete its require line there and the transformation is gone from the
-- | application - no menu code, no dispatch table and no gesture resolver mentions it by name.
-- |
-- | BOTH HALVES OF ONE TRANSFORMATION LIVE TOGETHER. `offer` decides where the gesture applies and
-- | `apply` performs it, and they are the same knowledge read in two directions - "the click must
-- | be on an ADD whose parent is a MUL" is exactly the condition apply refuses on.
-- |
-- | @note Splitting the two across files is how they drift, which is what happened while the
-- |       resolver lived in ast_gestures.lua and distribute lived here.
-- |
-- | @date 2026-09-13 16:00
--]]


local ast = require("ast")
local sealed = require("sealed")
local transforms = require("transforms")

local check = transforms.check
local check_ctx = transforms.check_ctx

--[[ @brief The `params` container: what this transformation needs in order to run, and the only
-- |        thing it receives beyond the tree itself.
-- |
-- | ITS CREATOR IS `offer` BELOW, the only place one is ever built. The whole point of the option
-- | an offer returns is that apply can be handed it back later, unchanged, so there is exactly one
-- | producer and one consumer and both are in this file.
-- |
-- | `apply` CHECKS WHAT ARRIVED rather than trusting it, because between the two lies a menu that
-- | can sit open across frames, a cache, a savefile of activation state and content.lua - none of
-- | which this file can see.
-- |
-- | THE SEAL BELONGS HERE, not in transforms.lua: the names are this plugin's own, and
-- | transforms.lua declares `params` as a field of an option without knowing what is in it.
-- |
-- | @note This is the one shape whose field list is repeated: `params = {"add"}` in the register
-- |       call at the bottom is what the dispatcher checks ARRIVED, and this is what says what it
-- |       MEANS.
-- |
-- | @date 2026-09-13 16:00
--]]
local PARAMS_FIELDS = {
    add = "ast id of the ADD to multiply out; its parent must be the MUL",
}
local PARAMS_SHAPE = sealed.declare("distribute", "params", PARAMS_FIELDS)

--[[ @brief Is this the number 1 - the factor a product may drop without changing?
-- | @date 2026-09-13 16:00
--]]
local function is_one(node)
    return type(node) == "table" and node.type == ast.NUM
            and node[1] == 1 and node[2] == 1 and node[3] == 1
end

--[[ @brief A product of `factors`, tidied: 1s dropped, a one-factor product unwrapped.
-- |
-- | THE CLEAN-UP HAPPENS IN THE SAME STEP, on request - author, 2026-09-11: "and yes, we clean back
-- | up". Distribution routinely leaves a product of one thing, or a stray 1 where a term was just
-- | the unit, and carrying those forward would make every later step read around debris the
-- | transform itself created.
-- |
-- | ORDER IS PRESERVED, and that is not incidental: multiplication here is not assumed commutative
-- | - vectors have products, and a cross product does not commute. Distribution is valid without
-- | commutativity; REORDERING is a different transformation and has to be asked for separately.
-- |
-- | @param ns       ast.ns - where a replacement 1 is minted, when everything was dropped
-- | @param factors  node[] - in order; not modified
-- | @return node - a MUL of what survived, or the single survivor unwrapped, or the number 1 when
-- |         everything was dropped, so the caller never special-cases a one-factor product
-- |
-- | @date 2026-09-13 16:00
--]]
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

--[[ @brief A distributed term: `coeff` spliced onto the front of `term`, in the shape the parse
-- |        would have produced.
-- |
-- | The coefficient folds into a leading numeral (`2(a-b)` gives `-2c`, never a product of two
-- | numbers) and otherwise becomes the term's first factor - never a nested MUL, which the writer
-- | cannot express: signs are written as operators, so a coefficient nested one level down would
-- | read back as a term of its own.
-- |
-- | @param ns     ast.ns - where replacement numbers are minted
-- | @param coeff  node | nil - the sum-term's leading NUM, or nil when it had none
-- | @param term   node - the distributed term before its coefficient is attached
-- | @param first  boolean - this is the sum's first term
-- | @return node - a positive unit coefficient on the FIRST term is dropped: a plain term is what
-- |         an unsigned term of a sum is, and it round-trips as one
-- |
-- | @date 2026-09-15
--]]
local function term_with_coeff(ns, coeff, term, first)
    if not coeff then
        return term
    end
    if first and coeff[1] == 1 and coeff[3] == 1 then
        return term
    end
    if term.type == ast.NUM then
        return ast.new_num(ns, coeff[1] * term[1], coeff[2] * term[2], coeff[3] * term[3])
    end
    local args
    if term.type == ast.MUL and term[1].type == ast.NUM then
        local folded = ast.new_num(ns, coeff[1] * term[1][1], coeff[2] * term[1][2],
                coeff[3] * term[1][3])
        args = {folded}
        for k = 2, #term do
            args[#args + 1] = term[k]
        end
    else
        args = {coeff}
        for k = 1, #term do
            args[#args + 1] = term[k]
        end
    end
    return ast.new_mul(ns, table.unpack(args))
end

--[[ @brief Rebuilds the path from `root` down to `old`, with `new` in its place.
-- |
-- | SHARES EVERY UNTOUCHED SUBTREE - the same node objects, with their own ids - and makes a new
-- | node only for the ancestors on the path. Author, 2026-09-11: "we want the transformation to
-- | reuse parts of the graph in the mexpr, changing litle let's us cut the graph in just the right
-- | parts to repair it with minimal stitches". Identity is then what says which regions of the old
-- | mexpr can be reused verbatim, which is how the user's own spacing survives a step.
-- |
-- | NOTHING IS MUTATED: the source tree is left exactly as it was, so the cell it belongs to stays
-- | valid - docs/phase2_design.md section 1's immutable cells.
-- |
-- | @param ns       ast.ns - where the rebuilt ancestors are minted
-- | @param root     node - the tree's root; the walk stops here
-- | @param parents  table - child id -> parent node, for `root` (ctx.parents())
-- | @param old      node - the subtree being replaced; must be reachable from `root`
-- | @param new      node - what takes its place
-- | @return node - the new root, or `new` itself when `old` was the root
-- | @throws refusal (transforms.check) when `old` is not reachable from `root`, which can only
-- |         mean the caller mixed two trees
-- |
-- | @date 2026-09-13 16:00
--]]
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

--[[ @brief The ADD the click landed inside, and that ADD's parent.
-- |
-- | A click resolves to a node - a number, a reference, a term's coefficient - and this walks the
-- | ast from there: up through the product that node's term lives in, however deeply it nests, to
-- | the sum directly above. The mexpr never carries structure (DESIGN.md, "Glyphs draw,
-- | transforms walk"); which sum a click belongs to is this layer's walk, not a tag's job.
-- |
-- | @param node     node - what the click resolved to
-- | @param parents  table - child id -> parent node
-- | @return node, node | nil - the ADD and its parent (nil parent when the ADD is the root);
-- |         nil when no sum is directly above the click
-- |
-- | @note Clicking any term of the sum reaches it - `d` in `a(b+d)` and `b` alike. What does not
-- |       is anything outside the sum: `a` itself climbs to the MUL above, not the ADD inside it,
-- |       and a sum inside a term of another sum is found only from inside that term.
-- |
-- | @note The restriction to operator glyphs here - climbing forbidden, offers only from a `+` or
-- |       a sign - was the 2026-09-11 fix for a right-click that broke, and it cut this walk out
-- |       of the design instead of finding the fault. Reversed 2026-09-15; see DESIGN.md.
-- |
-- | @date 2026-09-15
--]]
local function add_at(node, parents)
    local add
    if node.type == ast.ADD then
        add = node
    else
        local up = parents[node.id]
        while up and up.type == ast.MUL do
            up = parents[up.id]
        end
        add = (up and up.type == ast.ADD) and up or nil
    end
    if not add then
        return nil
    end
    return add, parents[add.id]
end

--[[ @brief Whether distribution applies at the glyph the user pointed at, and with what parameters.
-- |
-- | HALF THE CONTRACT with transforms.lua - the half that is asked, unprompted, on every
-- | right-click anywhere in a formula. `apply` below is the other half, and the two must agree:
-- | every condition this one checks before offering is a condition apply refuses on, so an option
-- | that appears can always be run and one that never appears can never be reached by accident.
-- |
-- | WHERE THE CLICK LANDS. Anywhere inside a term of the sum: `add_at` above walks the ast from
-- | the node the click resolved to, over the product that term lives in, to the sum directly
-- | above - the mexpr carries no structure, so the walk is this layer's (DESIGN.md, "Glyphs draw,
-- | transforms walk"). A click outside the sum, on `a` in `a(b+c)`, climbs past it and offers
-- | nothing.
-- |
-- | AND A PRODUCT TO DISTRIBUTE INTO. The sum's own parent must be a MUL, because distribution
-- | needs something to multiply through. `a+b` standing alone offers nothing however precisely it
-- | is clicked; `a(b+c)` offers it from any term of the sum.
-- |
-- | @details Reads the tree and nothing else - no cursor is moved, no node is created, nothing is
-- |          cached. Asking costs a parent_map walk that transforms.lua has usually already paid
-- |          for, which is what makes it safe to call on every click.
-- |
-- | @param ctx  transforms.ctx - built by transforms.lua. Two of its fields are read:
-- |               ctx.node       the ast node the click resolved to. NOT the root; this is the aim.
-- |               ctx.parents()  the memoized child-id -> parent map for ctx.root.
-- |             `ctx.ns` is unused here, present for transformations that mint or look up nodes.
-- |             `ctx.params` is absent for an offer - parameters are what an offer PRODUCES.
-- | @return option | nil - one option, `{id, label, params = {add = <ast id>}}`, or nil when it
-- |         does not apply. The option carries an ID rather than the node, so it can sit in a
-- |         menu across frames without keeping a tree alive.
-- |
-- | @note nil is the ordinary answer, not a failure. Most glyphs in most formulas are not a sum's
-- |       operator, and content.lua draws the resulting empty list as an EMPTY MENU rather than as
-- |       nothing, so that "understood, and there is nothing here" cannot be mistaken for a dead
-- |       binding.
-- |
-- | @date 2026-09-13 16:00
--]]
local function offer(ctx)
    check_ctx(ctx)
    local add, parent = add_at(ctx.node, ctx.parents())
    if not (add and parent and parent.type == ast.MUL) then
        return nil
    end
    return transforms.option("distribute", "Distribute", PARAMS_SHAPE.wrap{add = add.id})
end

--[[ @brief Multiplies the sum out.
-- |
-- |     x(b + c)y   ->   xby + xcy
-- |
-- | `params.add` names the ADD; its parent must be the MUL. That is the whole input - the gesture
-- | worked it out already, and this needs to know nothing about how the click arrived.
-- |
-- | WHAT IS SHARED AND WHAT IS COPIED, decided by one question only: does this subtree end up in
-- | the output MORE THAN ONCE? Only the factors surrounding the sum do - `a` in `a(b+c)` becomes
-- | the `a` of two terms - so those are copied from the second term on, because one node cannot
-- | sit in two places under one id.
-- |
-- | THE SUM'S OWN TERMS ARE NEVER COPIED. Each appears exactly once in the result: `b` lands in the
-- | first term and `c` in the second, and nothing needs a second `c`. What is left is the smallest
-- | diff the algebra allows, which is the point: the untouched parts of the old drawing stay
-- | usable.
-- |
-- | REFUSES rather than widening, the way selection does everywhere. A transformation offered where
-- | it does not apply is how one ends up running on the wrong nodes.
-- |
-- | @param ctx  transforms.ctx - built by transforms.lua. Reads ctx.ns, ctx.root, ctx.params (a
-- |             `distribute.params` that offer() built) and ctx.parents().
-- | @return node - the new root. Untouched nodes keep their ids, and the result lives in the same
-- |         namespace.
-- | @throws refusal (ctx.check) when the node is not an ADD, its parent is not a MUL, or the sum
-- |         is not among that MUL's factors. RAISES instead when ctx.params is not a sealed
-- |         `distribute.params`, or when its id names nothing in this namespace - a caller error,
-- |         not a gesture that does not apply.
-- |
-- | @note Copying the sum's own terms was the original shape here, and it was wrong twice over -
-- |       author, 2026-09-12: "there is no point in creating a new reference". It minted nodes
-- |       nothing was ever drawn for, so the writer that rebuilds the mexpr had to re-render glyphs
-- |       it could have carried across verbatim, losing whatever decoration and spacing they had.
-- |       Cheap for a bare letter; a whole subtree for `2x` or a fraction.
-- |
-- | @date 2026-09-13 16:00
--]]
local function apply(ctx)
    check_ctx(ctx)
    local ns, root = ctx.ns, ctx.root
    --[[ ON RETRIEVAL, not on trust: the table being read here is the one `offer` built, but it
    -- | has travelled through a menu and a cache to get back, and the metatable is what says it is
    -- | still that table rather than one somebody assembled with the right-looking key.
    --]]
    PARAMS_SHAPE.check(ctx.params, "params")
    local add = ast.node_of(ns, ctx.params.add)
    --[[ TWO FAILURES, TWO MECHANISMS, which the one line here used to answer with one sentence.
    -- |
    -- | node_of gives nil when the id names nothing in THIS namespace - an option run against a
    -- | tree it was not built against. That is a caller that paired them wrong, not a gesture that
    -- | does not apply, so it goes through the SEAL and raises, naming the type it wanted; `add and
    -- | ...` was a hand-rolled nil guard standing in for exactly that. A node that IS here and
    -- | simply is not a sum is the ordinary refusal, and keeps the sentence a user reads in the
    -- | menu.
    -- |
    -- | "distribute needs a sum" was the answer to both, so a stale option reported itself as a
    -- | gesture landing in the wrong place - true of the second case and a lie about the first.
    -- |
    -- | @date 2026-09-13 01:20
    --]]
    ast.check_node(add, "params.add")
    check(add.type == ast.ADD, "distribute needs a sum")

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
        --[[ The sum's term split into its coefficient and the rest: the term carries its sign as
        -- | a leading NUM (the parse's shape), and the coefficient must reach the FRONT of the
        -- | distributed term, which is what term_with_coeff is for. A bare number term is its own
        -- | coefficient. ]]
        local t_node = add[t]
        local coeff, rest = nil, {}
        if t_node.type == ast.NUM then
            coeff = t_node
        elseif t_node.type == ast.MUL and t_node[1].type == ast.NUM then
            coeff = t_node[1]
            for k = 2, #t_node do
                rest[#rest + 1] = t_node[k]
            end
        else
            rest[1] = t_node
        end

        local factors = {}
        for i = 1, #mul do
            if i == at then
                -- Used once, so it travels as itself - see the header.
                for _, f in ipairs(rest) do
                    factors[#factors + 1] = f
                end
            else
                --[[ The first term keeps the original factor nodes; the rest take copies. See
                -- | the header on why the asymmetry is the point rather than an oversight.
                --]]
                factors[#factors + 1] = (t == 1) and mul[i] or ast.copy_fresh(ns, mul[i])
            end
        end
        terms[#terms + 1] = term_with_coeff(ns, coeff, product_of(ns, factors), t == 1)
    end

    local expanded = ast.new_add(ns, table.unpack(terms))
    return replace_in(ns, root, parents, mul, expanded)
end

--[[ @brief Registers distribute with transforms.lua, DEFAULT ACTIVE.
-- |
-- | Unlike a plugin dropped in from outside, this one ships with the project and the author asked
-- | for it on: "distribute will be default actuvated". An unticked `transforms.save` entry is what
-- | turns it off again, and the absence of any entry leaves it on.
-- |
-- | @date 2026-09-13 16:00
--]]
transforms.register{
    id = "distribute",
    label = "Distribute",
    params = {"add"},
    default_active = true,
    offer = offer,
    apply = apply,
}

return true

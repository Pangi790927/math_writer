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

--[[ @brief A distributed term: `coeff` attached to the front of `term`, in the shape the parse
-- |        would have produced.
-- |
-- | A coefficient never merges into another numeral - magnitudes never multiply (the author,
-- | 2026-09-15: "-2x3 ... shouldn't be automatically reduced"). What folds is SIGNS: a
-- | coefficient meeting a term that already leads with a sign coefficient folds the two signs
-- | into one, auto-reduced for now (the author may one day let a double negative stand). A unit
-- | `+1` on a FIRST term is dropped: a plain term is what an unsigned term of a sum is.
-- |
-- | @param ns     ast.ns - where replacement numbers are minted
-- | @param coeff  node | nil - the sum-term's leading NUM, or nil when it had none
-- | @param term   node - the distributed term before its coefficient is attached
-- | @param first  boolean - this term lands first in its sum
-- | @return node
-- |
-- | @date 2026-09-15
--]]
local function term_with_coeff(ns, coeff, term, first)
    if not coeff then
        return term
    end
    local is_unit = function(n)
        return n.type == ast.NUM and n[1] == 1 and n[2] == 1
    end
    --[[ A SIGN-NUMBER: magnitude exactly 1 - the unit, or infinity, +1 or -1 over 0 - carrying
    nothing but a sign. A unit sign meeting one folds their signs, infinity included, so that
    `-(-inf)` becomes `+inf` and never a product of two minus-ones. ]]
    local is_sign_number = function(n)
        return n.type == ast.NUM and n[1] == 1 and (n[2] == 1 or n[2] == 0)
    end
    if is_unit(coeff) and term.type == ast.MUL and is_sign_number(term[1]) then
        -- Sign folding, auto-reduced for now - the author may one day let a double negative
        -- stand. The folded number keeps its own denominator: infinity stays over 0.
        local signs = (coeff[3] or 1) * (term[1][3] or 1)
        if first and signs == 1 and term[1][2] == 1 then
            local bare = {}
            for k = 2, #term do
                bare[#bare + 1] = term[k]
            end
            return product_of(ns, bare)
        end
        local args = {ast.new_num(ns, 1, term[1][2], signs)}
        for k = 2, #term do
            args[#args + 1] = term[k]
        end
        return ast.new_mul(ns, table.unpack(args))
    end
    if first and is_unit(coeff) and coeff[3] == 1 then
        return term
    end
    if term.type == ast.MUL then
        local args = {coeff}
        for k = 1, #term do
            args[#args + 1] = term[k]
        end
        return ast.new_mul(ns, table.unpack(args))
    end
    return ast.new_mul(ns, coeff, term)
end

--[[ The parent of `node`, looking through any chain of CELLs - the user's own brackets around a
thing do not hide it from whatever is above it.
@date 2026-09-15 ]]
local function through_cells(parents, node)
    local up = parents[node.id]
    while up and up.type == ast.CELL do
        up = parents[up.id]
    end
    return up
end

--[[ Does `factor` hold `node` - as itself, or inside a chain of CELLs? `a((b+c))` nests one
redundant bracket inside another, and both are the user's.
@date 2026-09-15 ]]
local function holds_through_cells(factor, node)
    while factor ~= nil and factor.type == ast.CELL do
        factor = factor[1]
    end
    return factor == node
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

--[[ The expanded sum placed where its product sat - the grammar of the two endings:

    in a product or at the root:  a(b+c)                   ->  ab + ac     (plain replacement)
    a whole term of a sum:        x + a(b+c) at the inner  ->  x + ab + ac (the terms join that sum)
                                 a(b-(c+d)) at the inner  ->  a(b-c-d)

The join is the SPLICE: an ADD cannot be a term of an ADD - bracketing it would build a CELL the
tree does not have, and the write would refuse its own result - so the expanded terms take their
product's place among the enclosing sum's terms, each carrying the sign of the position it lands
in. Nothing new is distributed; the one distribution done is only expressed where its result
lives.
@date 2026-09-15 ]]
local function splice_up(ns, root, parents, mul, expanded)
    local outer = through_cells(parents, mul)
    if not (outer and outer.type == ast.ADD) then
        return replace_in(ns, root, parents, mul, expanded)
    end
    local pos
    for i = 1, #outer do
        local f = outer[i]
        if f == mul or holds_through_cells(f, mul) then
            pos = i
            break
        end
    end
    local unit = ast.new_num(ns, 1, 1, 1)
    local kids = {}
    for i = 1, pos - 1 do
        kids[#kids + 1] = outer[i]
    end
    for i = 1, #expanded do
        kids[#kids + 1] = term_with_coeff(ns, unit, expanded[i], pos + i == 2)
    end
    for i = pos + 1, #outer do
        kids[#kids + 1] = outer[i]
    end
    return replace_in(ns, root, parents, outer, ast.new_add(ns, table.unpack(kids)))
end

--[[ A sum's term split into its sign and its factors - the grammar of every term distribute
multiplies through:

    b             ->  no sign, factors {b}
    MUL(1, c)     ->  sign +1, factors {c}
    MUL(-1, 2, x) ->  sign -1, factors {2, x}   (a sign is its own factor, never folded)
    3             ->  the number is the whole term and its own coefficient

@date 2026-09-15 ]]
local function split_term(t_node)
    if t_node.type == ast.NUM then
        return t_node, {}
    end
    if t_node.type == ast.MUL then
        --[[ A MUL WITH A LEADING NUM splits sign-from-factors; a MUL WITHOUT one has all of its
        children as plain factors, and they are SPLICES into the surrounding factor list, not a
        nested product riding through. The distinction matters to the round trip: juxtaposition
        reparses FLAT (found 2026-09-15 on `\sum e^{-jk(\delta t+\beta)w}` - distributing the
        inner sum left `MUL(\delta, t)` nested inside the term, the written form was the same ink,
        and verify failed on flat-vs-nested). A first term of an inner bracketed sum is the case
        that arrives here bare - every term after the first carries its sign coefficient and takes
        the branch above. ]]
        local rest = {}
        if t_node[1].type == ast.NUM then
            for k = 2, #t_node do
                rest[#rest + 1] = t_node[k]
            end
            return t_node[1], rest
        end
        for k = 1, #t_node do
            rest[#rest + 1] = t_node[k]
        end
        return nil, rest
    end
    return nil, {t_node}
end

--[[ @brief The ADD a sign belongs to, and the MUL above it.
-- |
-- | A SIGN IS THE BUTTON - the author, 2026-09-15 - so this is where the click must have landed:
-- | the resolved node is the sign's coefficient, the unit NUM(1) or NUM(-1) leading its term's
-- | product, which is what the parse stamps on a sign glyph. From there the walk is the author's
-- | own shape for the whole question: "take the ADD this '+' or '-' is under and walk to the mul
-- | above ... if not a (ADD, (MUL)), then refuse it" - over the term's product, through any
-- | CELLs, to the ADD; then up through CELLs again to the MUL the distribution needs.
-- |
-- | The mexpr never carries structure (DESIGN.md, "Glyphs draw, transforms walk"), and the shape
-- | alone tells a sign from everything else: a value numeral sits one factor in, a digit names a
-- | value, a letter names a reference - none of them lead a product as a unit sign.
-- |
-- | @param node     node - what the click resolved to
-- | @param parents  table - child id -> parent node
-- | @return node, node | nil - the ADD and the MUL above it; nil when the click was not on a
-- |         term's sign, or the sum has no product around it
-- |
-- | @date 2026-09-15
--]]
local function add_at(node, parents)
    local mul = parents[node.id]
    if not (node.type == ast.NUM and node[1] == 1 and node[2] == 1
            and mul and mul.type == ast.MUL and mul[1] == node) then
        return nil
    end
    local add = through_cells(parents, mul)
    if not (add and add.type == ast.ADD) then
        return nil
    end
    local above = through_cells(parents, add)
    if not (above and above.type == ast.MUL) then
        return nil
    end
    return add, above
end

--[[ @brief Whether distribution applies at the glyph the user pointed at, and with what parameters.
-- |
-- | HALF THE CONTRACT with transforms.lua - the half that is asked, unprompted, on every
-- | right-click anywhere in a formula. `apply` below is the other half, and the two must agree:
-- | every condition this one checks before offering is a condition apply refuses on, so an option
-- | that appears can always be run and one that never appears can never be reached by accident.
-- |
-- | THE SIGN IS THE BUTTON. The pointer must be on a `+` or a `-`: the click resolves to the
-- | sign's coefficient, and `add_at` above walks from there - the ADD the sign separates terms
-- | of, the MUL above it through any CELLs - or the option never appears. A letter, a digit,
-- | even the value numeral of a signed term offers nothing (the author, 2026-09-15: "I want only
-- | plus to offer the distribute operation ... a + is visualy the button, the same is -").
-- |
-- | AND A PRODUCT TO DISTRIBUTE INTO. The sum's own parent must be a MUL (through CELLs),
-- | because distribution needs something to multiply through. `a+b` standing alone offers
-- | nothing however precisely it is clicked.
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
    local add = add_at(ctx.node, ctx.parents())
    if not add then
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
    --[[ Through any CELLs: the user's own brackets around the sum do not hide it from the
    distribution - they are brackets the distribution is about to make implied. ]]
    local mul = through_cells(parents, add)
    check(mul and mul.type == ast.MUL, "distribute needs a product around the sum")

    -- Where the sum sits among the product's factors - as itself, or inside the CELLs carrying
    -- it: everything before it stays before, and everything after stays after, in every term.
    local at
    for i = 1, #mul do
        local f = mul[i]
        if f == add or holds_through_cells(f, add) then
            at = i
            break
        end
    end
    check(at, "the sum is not a factor of that product")

    local terms = {}
    for t = 1, #add do
        -- The term's own sign and factors; the factors take the sum's place among the product's.
        local coeff, rest = split_term(add[t])
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

    return splice_up(ns, root, parents, mul, ast.new_add(ns, table.unpack(terms)))
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

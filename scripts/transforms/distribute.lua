--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- |
-- | offer(ctx: transforms.ctx)              -> option | nil
-- |     Answers whether distribution applies at ctx.node: the node must be
-- |     a term's sign coefficient, of a sum that a product holds. nil, the
-- |     common answer, when not. Reads the tree only; creates nothing.
-- |
-- | apply(ctx: transforms.ctx)              -> node
-- |     Multiplies the sum out. Refuses through ctx.check when the tree is
-- |     not a sum inside a product. Leaves the source tree untouched and
-- |     shares every subtree it did not have to rebuild. Its params are the
-- |     sealed {add = <ast id of the sum>} that offer built.
-- |
-- | --- internal, not on the module table ---------------------------------------------------------
-- |     is_one, is_unit_magnitude, is_sign_carrier    what a number must look like to be
-- |         dropped, folded, or read as a sign
-- |     through_cells, sum_at_sign                    from a term's sign coefficient to the sum,
-- |         and the product around it
-- |     split_term, product_of, term_with_coeff       the algebra of one distributed term
-- |     replace_in, splice_up                         placing the expanded sum back into the tree
-- |     PARAMS_FIELDS, PARAMS_SHAPE
-- |
-- | @date 2026-09-19 13:05
-- | ===============================================================================================
--]]

--[[ @file transforms/distribute.lua
-- | @brief Multiplying a sum out: x(b + c)y becomes xby + xcy.
-- |
-- | Distribution is local: one application opens one sum, and a bracketed sum inside a term
-- | stays for the next one. It passes through the bracket CELLs around the sum, which the
-- | distribution is about to make implied, and when the distributed product was itself a whole
-- | term of a sum, the expanded terms join that sum where the product sat - a sum cannot be a
-- | term of a sum.
-- |
-- | `offer` and `apply` are one contract in two directions: every condition offer requires
-- | before offering is a condition apply refuses on, so an option that appears can always run
-- | and one that never appears can never be reached by accident. The transformation hands
-- | itself to transforms.lua at the bottom of the file.
-- |
-- | @date 2026-09-19 12:40
--]]


local ast = require("ast")
local sealed = require("sealed")
local transforms = require("transforms")

local check = transforms.check
local check_ctx = transforms.check_ctx

--[[ @brief Holds what apply receives beyond the tree: the sum's ast id.
-- |
-- | Built only by `offer` below, and checked by apply rather than trusted: the metatable is
-- | what says a table is the one offer built, and not one assembled with right-looking keys.
-- |
-- | @date 2026-09-19 13:05
--]]
local PARAMS_FIELDS = {
    add = "ast id of the ADD to multiply out; its parent must be the MUL",
}
local PARAMS_SHAPE = sealed.declare("distribute", "params", PARAMS_FIELDS)

--[[ @brief Is this exactly the number 1 - the factor a product may drop without changing?
-- |
-- | Only +1 over 1 is it. A -1 carries a sign, and an infinity shares the magnitude while
-- | changing everything it multiplies, so both survive the cleanup that drops this one.
-- |
-- | @param node  node - any factor of a product
-- | @return boolean
-- |
-- | @date 2026-09-19 11:20
--]]
local function is_one(node)
    return node.type == ast.NUM and node[1] == 1 and node[2] == 1 and node[3] == 1
end

--[[ @brief Is this a number of magnitude 1 and finite - +1 or -1 - able to stand as a coefficient?
-- |
-- | The sign is left open, which is what separates this from is_one above: a coefficient's whole
-- | job is to carry one. The parse stamps a term's sign as exactly this number - the unit leading
-- | the term's product - so a term's sign coefficient answers yes here.
-- |
-- | @param node  node
-- | @return boolean
-- |
-- | @date 2026-09-19 12:10
--]]
local function is_unit_magnitude(node)
    return node.type == ast.NUM and node[1] == 1 and node[2] == 1
end

--[[ @brief Is this a number carrying nothing but a sign - magnitude 1, finite or infinite?
-- |
-- | +1, -1, and the two infinities, which are +1 and -1 over 0. A sign meeting one of these as a
-- | coefficient folds with it, infinity included, so `-(-inf)` becomes `+inf` and never a product
-- | of two minus-ones. Wider than is_unit_magnitude by exactly the infinities.
-- |
-- | @param node  node
-- | @return boolean
-- |
-- | @date 2026-09-19 11:20
--]]
local function is_sign_carrier(node)
    return node.type == ast.NUM and node[1] == 1 and (node[2] == 1 or node[2] == 0)
end

--[[ @brief Finds the first non-CELL ancestor above `node`, and its child on the way down.
-- |
-- | The user's own brackets around a thing do not hide it from whatever is above it: a CELL is
-- | redundant by construction, so a walk that wants the expression's place in the tree looks
-- | through the whole run of them. The SLOT is that place - the outermost CELL, or `node` itself
-- | when nothing brackets it - and it is always a DIRECT child of the holder, which is what lets
-- | a caller find where a bracketed thing sits by comparing children for identity rather than
-- | searching them with a predicate.
-- |
-- | @param parents  table - child id -> parent node, for the tree `node` is in
-- | @param node     node - the walk starts above it
-- | @return node | nil, node - the holder, nil when only CELLs (or nothing) sit above `node`; and
-- |         the holder's child on the path down to `node`
-- |
-- | @date 2026-09-19 13:05
--]]
local function through_cells(parents, node)
    local slot = node
    local up = parents[node.id]
    while up and up.type == ast.CELL do
        slot = up
        up = parents[up.id]
    end
    return up, slot
end

--[[ @brief Finds the sum a term's sign coefficient leads into, when a product holds that sum.
-- |
-- | Every term of a sum but the first carries its sign as a leading unit number, so `node` is
-- | such a coefficient exactly when it is a number of unit magnitude, its parent is the term's
-- | product, and it is that product's first factor. From there the sum is the first non-CELL
-- | ancestor of the term's product, and the product distribution needs is the first non-CELL
-- | ancestor of the sum: both must exist, for distribution needs a term of a sum and that sum
-- | held by a product - `a+b` standing alone has neither.
-- |
-- | @param node     node - any node of the tree
-- | @param parents  table - child id -> parent node
-- | @return node | nil - the ADD, or nil when `node` is not a term's sign coefficient, or no MUL
-- |         holds its sum
-- |
-- | @note The first term of a sum carries no sign, so a sum is reached through the signs of its
-- |       later terms only.
-- |
-- | @date 2026-09-19 13:05
--]]
local function sum_at_sign(node, parents)
    local mul = parents[node.id]
    if not (is_unit_magnitude(node) and mul and mul.type == ast.MUL and mul[1] == node) then
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
    return add
end

--[[ Splits a sum's term into its sign and its factors - the grammar of every term distribute
multiplies through:

    b             ->  no sign, factors {b}
    MUL(1, c)     ->  sign +1, factors {c}
    MUL(-1, 2, x) ->  sign -1, factors {2, x}   (a sign is its own factor, never folded)
    3             ->  the number is the whole term and its own coefficient

@date 2026-09-19 13:05 ]]
local function split_term(t_node)
    if t_node.type == ast.NUM then
        return t_node, {}
    end
    if t_node.type == ast.MUL then
        --[[ A MUL with a leading NUM splits sign-from-factors; a MUL without one splices its
        -- | children flat into the surrounding factor list. The parse builds products flat - a
        -- | MUL inside a MUL is not a shape the tree keeps, and a result carrying one writes the
        -- | same ink but fails the reparse verify on flat-vs-nested. The bare case arrives here
        -- | as the first term of a bracketed sum; every term after the first carries its sign
        -- | coefficient and takes the branch above. ]]
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

--[[ @brief Builds a product of `factors`, tidied: 1s dropped, a one-factor product unwrapped.
-- |
-- | Distribution routinely leaves a product of one factor, or a stray 1 where a term was the
-- | unit; carrying those forward would make every later step read around debris this
-- | transformation created, so the cleanup happens in the same step that builds the product.
-- |
-- | The order of factors is preserved: multiplication is not assumed commutative - a vector
-- | product does not commute - and distribution is valid without commutativity while reordering
-- | is a different transformation altogether.
-- |
-- | @param ns       ast.ns - mints the replacement 1, when every factor was dropped
-- | @param factors  node[] - in order; not modified
-- | @return node - a MUL of what survived, the single survivor unwrapped, or the number 1, so a
-- |         caller never special-cases a one-factor product
-- |
-- | @date 2026-09-19 13:05
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

--[[ @brief Builds a distributed term: `coeff` attached to the front of `term`, in the shape the
-- |        parse would have produced.
-- |
-- | A coefficient never merges into another numeral - magnitudes never multiply, and `-2` times
-- | `x` stays a product rather than becoming a numeral of magnitude 2. What folds is signs only:
-- | a unit coefficient meeting a term that already leads with a sign carrier folds the two into
-- | one (auto-reduced, for now), and the folded number keeps its own denominator, so infinity
-- | stays over 0. A unit +1 arriving on a first term is dropped outright: a plain term is what an
-- | unsigned term of a sum is.
-- |
-- | @param ns     ast.ns - where replacement numbers are minted
-- | @param coeff  node | nil - the term's leading NUM, or nil when it had none
-- | @param term   node - the distributed term before its coefficient is attached
-- | @param first  boolean - this term lands first in its sum
-- | @return node
-- |
-- | @note `coeff` may be placed into the result as it stands, so a caller handing the same node
-- |       to two calls can put one id in two places - splice_up mints a fresh unit per term for
-- |       exactly that reason.
-- |
-- | @date 2026-09-19 13:05
--]]
local function term_with_coeff(ns, coeff, term, first)
    if not coeff then
        return term
    end
    if is_unit_magnitude(coeff) and term.type == ast.MUL and is_sign_carrier(term[1]) then
        --[[ Fold: the two signs become one, on a fresh number, so the term keeps a single
        -- | leading sign. A first term folding to a plain +1 over 1 needs no sign at all, and
        -- | comes back tidied through product_of. ]]
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
    --[[ Drop: a first term is what an unsigned term of a sum is, so a unit +1 arriving on one
    -- | is noise rather than a factor. ]]
    if first and is_unit_magnitude(coeff) and coeff[3] == 1 then
        return term
    end
    --[[ Attach: every other coefficient leads the term as a factor in its own right, prepended
    -- | to the term's own factors when there is a product to lead. ]]
    if term.type == ast.MUL then
        local args = {coeff}
        for k = 1, #term do
            args[#args + 1] = term[k]
        end
        return ast.new_mul(ns, table.unpack(args))
    end
    return ast.new_mul(ns, coeff, term)
end

--[[ @brief Rebuilds the path from `root` down to `old`, with `new` in its place.
-- |
-- | Every untouched subtree is shared - the same node objects, with their own ids - and a new
-- | node is made only for the ancestors on the path. Identity is then what says which regions of
-- | the old mexpr can be reused verbatim, which is how the user's own spacing survives a step.
-- | Nothing is mutated: the source tree is left as it was, so the cell it belongs to stays valid
-- | (docs/phase2_design.md section 1's immutable cells).
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
-- | @date 2026-09-19 12:10
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

--[[ @brief Places the expanded sum where its product sat - the grammar of the two endings:
-- |
-- |     in a product or at the root:  a(b+c)                   ->  ab + ac
-- |     a whole term of a sum:        x + a(b+c) at the inner  ->  x + ab + ac
-- |                                  a(b-(c+d)) at the inner   ->  a(b-c-d)
-- |
-- | The first ending is a plain replacement; the second is the splice. An ADD cannot be a term of
-- | an ADD - bracketing it would build a CELL the tree does not have, and the write would refuse
-- | its own result - so the expanded terms take their product's place among the enclosing sum's
-- | terms, each carrying the sign of the position it lands in. Nothing new is distributed; the one
-- | distribution done is only expressed where its result lives.
-- |
-- | The position's sign is a unit handed to term_with_coeff, which folds it with whatever sign
-- | the term already leads with. A FRESH unit per term, because that coefficient may be placed
-- | into the tree as it stands, and one node cannot sit in two places under one id.
-- |
-- | @param ns        ast.ns - where the splice's numbers are minted
-- | @param root      node - the tree's root; handed to replace_in
-- | @param parents   table - child id -> parent node, for `root` (ctx.parents())
-- | @param mul       node - the product that was distributed
-- | @param expanded  node - the ADD the distribution produced, taking the product's place
-- | @return node - the new root
-- |
-- | @date 2026-09-19 13:05
--]]
local function splice_up(ns, root, parents, mul, expanded)
    local outer, slot = through_cells(parents, mul)
    if not (outer and outer.type == ast.ADD) then
        return replace_in(ns, root, parents, mul, expanded)
    end
    -- The product's place in the sum is its slot's index - always found, because the slot is a
    -- direct child of the holder through_cells just returned.
    local pos
    for i = 1, #outer do
        if outer[i] == slot then
            pos = i
            break
        end
    end
    local kids = {}
    for i = 1, pos - 1 do
        kids[#kids + 1] = outer[i]
    end
    for i = 1, #expanded do
        kids[#kids + 1] = term_with_coeff(ns, ast.new_num(ns, 1, 1, 1), expanded[i], pos + i == 2)
    end
    for i = pos + 1, #outer do
        kids[#kids + 1] = outer[i]
    end
    return replace_in(ns, root, parents, outer, ast.new_add(ns, table.unpack(kids)))
end

--[[ @brief Answers whether distribution applies at `ctx.node`, and with what parameters.
-- |
-- | The condition is `sum_at_sign` above: `ctx.node` must be a term's sign coefficient, of a sum
-- | that a product holds - the two relations distribution needs, a term of a sum and that sum
-- | held by a product. A letter, a digit, the value numeral of a signed term, or the sign of a
-- | sum no product holds all answer nil, and `a+b` standing alone answers nil however it is
-- | reached.
-- |
-- | The other half of the contract is `apply` below, and the two are the same condition read in
-- | two directions: everything this requires before offering is something apply refuses on, so
-- | an option that appears can always run.
-- |
-- | @details Reads the tree and nothing else: no node is created, nothing cached.
-- |
-- | @param ctx  transforms.ctx - reads ctx.node and ctx.parents(); ctx.ns is unused here, and
-- |             ctx.params is absent, because parameters are what an offer produces
-- | @return option | nil - {id, label, params = {add = <ast id>}}
-- |
-- | @date 2026-09-19 13:05
--]]
local function offer(ctx)
    check_ctx(ctx)
    local add = sum_at_sign(ctx.node, ctx.parents())
    if not add then
        return nil
    end
    return transforms.option("distribute", "Distribute", PARAMS_SHAPE.wrap{add = add.id})
end

--[[ @brief Multiplies the sum out.
-- |
-- |     x(b + c)y   ->   xby + xcy
-- |
-- | `params.add` names the ADD; its parent must be the MUL. That is the whole input: the tree,
-- | and one id.
-- |
-- | What is shared and what is copied is decided by one question only: does this subtree end up
-- | in the output more than once? Only the factors surrounding the sum do - `a` in `a(b+c)`
-- | becomes the `a` of two terms - so they are shared in the first term and copied after,
-- | because one node cannot sit in two places under one id. The sum's own terms are never
-- | copied: each lands in exactly one term of the result, which keeps the diff to the old tree -
-- | and so the repair of the drawing - as small as the algebra allows.
-- |
-- | Refuses rather than widening, the way selection does everywhere: a transformation run where
-- | it does not apply is how one ends up running on the wrong nodes.
-- |
-- | @param ctx  transforms.ctx - reads ctx.ns, ctx.root, ctx.params (a `distribute.params` that
-- |             offer() built) and ctx.parents()
-- | @return node - the new root. Untouched nodes keep their ids, and the result lives in the same
-- |         namespace.
-- | @throws refusal (ctx.check) when the node is not an ADD, its parent is not a MUL, or the sum
-- |         is not among that MUL's factors. Raises instead when ctx.params is not a sealed
-- |         `distribute.params`, or when its id names nothing in this namespace - a caller error,
-- |         not a tree the transformation refuses.
-- |
-- | @date 2026-09-19 12:10
--]]
local function apply(ctx)
    check_ctx(ctx)
    local ns, root = ctx.ns, ctx.root
    --[[ The params table reaches apply from outside this file; the seal is what proves it is the
    -- | one `offer` built, rather than one assembled with right-looking keys. ]]
    PARAMS_SHAPE.check(ctx.params, "params")
    local add = ast.node_of(ns, ctx.params.add)
    --[[ Two failures, two mechanisms. node_of gives nil when the id names nothing in this
    -- | namespace - an option run against a tree it was not built against - which is a caller
    -- | error and raises through the seal, naming the type it wanted. A node that is here and
    -- | simply is not a sum is the ordinary refusal, and keeps the sentence a reader sees. ]]
    ast.check_node(add, "params.add")
    check(add.type == ast.ADD, "distribute needs a sum")

    local parents = ctx.parents()
    --[[ Through any CELLs: the brackets around the sum do not hide it from the distribution -
    -- | they are brackets the distribution is about to make implied. The slot is the outermost
    -- | of them, or the sum itself, and always a direct factor of the product. ]]
    local mul, slot = through_cells(parents, add)
    check(mul and mul.type == ast.MUL, "distribute needs a product around the sum")

    -- Where the sum sits among the product's factors: everything before it stays before, and
    -- everything after stays after, in every term.
    local at
    for i = 1, #mul do
        if mul[i] == slot then
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

--[[ Registers the transformation, on by default. @date 2026-09-19 12:40 ]]
transforms.register{
    id = "distribute",
    label = "Distribute",
    params = {"add"},
    default_active = true,
    offer = offer,
    apply = apply,
}

return true

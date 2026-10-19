--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | peel_cells(node: node)                  -> node
-- |     What a run of CELLs wraps: the first node below them that is not a
-- |     CELL, or `node` itself.
-- | through_cells(parents: {id -> node}, node: node) -> holder, slot
-- |     The first ancestor above `node` that is not a CELL, and the child of
-- |     that ancestor on the way down - the outermost CELL, or `node`.
-- |
-- | product(ns: ast.ns, factors: {node})    -> node
-- |     A FLAT product in the shape the parser builds: unit factors dropped,
-- |     every sign gathered onto one leading number, a one-factor product
-- |     unwrapped. The factors are placed as given, never copied.
-- |
-- | swap_in_parent(ns: ast.ns, root: node, parents: {id -> node}, old: node, new: node)
-- |       -> root | nil, reason
-- |     The tree with `new` where `old` was: every ancestor on the path is
-- |     rebuilt, everything else shared. A SUM landing in a sum is spliced
-- |     into it, so the result stays as flat as a parse of it would be.
-- |
-- | is_unit_magnitude(node: node)           -> boolean
-- |     Answers whether `node` is +1 or -1 over 1, which is what a term's
-- |     sign coefficient is.
-- |
-- | split_term(t_node: node)                -> node | nil, {node}
-- |     Splits a sum's term into its leading number and its factors. A term
-- |     with no leading number comes back with no coefficient.
-- |
-- | product_of(ns: ast.ns, factors: {node}) -> node
-- |     Builds a product with every exact 1 dropped and a lone survivor
-- |     unwrapped. Unlike `product`, it leaves every sign where it is.
-- |
-- | term_with_coeff(ns: ast.ns, coeff: node | nil, term: node, first: boolean) -> node
-- |     Attaches `coeff` to the front of `term` in the shape the parse
-- |     builds: signs fold with signs, magnitudes never merge, and a +1 on a
-- |     sum's first term is dropped.
-- |
-- | --- internal, not on the module table ---------------------------------------------------------
-- |     is_unit, signed_num, check_parents, is_sign_carrier, as_factor
-- |
-- | @date 19-10-2026-20:35
-- | ===============================================================================================
--]]

--[[ @file transform_utils.lua
-- | @brief The helpers a transformation plugin builds its result with, so a plugin holds only its
-- |        own algebra.
-- |
-- | PLAIN FUNCTIONS, CALLED BY CHOICE. Nothing here runs by itself: a normalization is a decision
-- | of the transformation that uses it, never a global rule. Author, 2026-09-13: "to use a
-- | normalization is a choice of the transformation, not a global rule".
-- |
-- | AST -> AST ONLY. The parser's own normalizations (mexpr_ast: `-1a` becoming `-a`) work on the
-- | drawing, and the writer (ast_mexpr) draws whatever tree it is given. This file is the middle
-- | stage and knows nothing of either.
-- |
-- | WHY "THE SHAPE THE PARSER BUILDS" MATTERS HERE ANYWAY: a result is written back to glyphs and
-- | parsed again by ast_mexpr.verify. A tree the parser would never produce - a product inside a
-- | product, a sum inside a sum - draws correctly and still fails that check, so the builders here
-- | produce the flat shapes.
-- |
-- | @note NOT IN scripts/transforms/, deliberately: every file in that folder is registered as a
-- |       plugin by the folder scan. Nor does it require transforms: that file requires every
-- |       plugin as it loads and a plugin requires this one, so loading this file first would
-- |       loop. A helper here refuses by returning nil and a reason, never by transforms.check;
-- |       the plugin turns the reason into its own refusal.
-- |
-- | @date 19-10-2026-20:35
--]]

local ast = require("ast")

local transform_utils = {}

--[[ @brief Answers whether `node` is exactly the number 1, the factor a product may drop without
-- |        changing.
-- |
-- | Only +1 over 1 is it. A -1 carries a sign, and an infinity shares the magnitude while changing
-- | everything it multiplies, so both survive the cleanup that drops this one - in `product` and
-- | in product_of alike.
-- |
-- | @param node  node - any factor of a product
-- | @return boolean
-- |
-- | @date 19-10-2026-20:35
--]]
local function is_unit(node)
    return node.type == ast.NUM and node[1] == 1 and node[2] == 1 and node[3] == 1
end

--[[ `num` with its sign replaced by `sign`, as a new node - or `num` itself when it already has it.
@date 2026-09-13 19:45 ]]
local function signed_num(ns, num, sign)
    if num[3] == sign then
        return num
    end
    return ast.new_num(ns, num[1], num[2], sign)
end

--[[ Asserts a child-id -> parent map, as ast.parent_map builds. It is a plain table with no shape
of its own to check, so what can be said is that it is one. @date 2026-09-13 19:45 ]]
local function check_parents(parents)
    assert(type(parents) == "table", "transform_utils: `parents` must be a map from ast.parent_map")
end

--[[ @brief What a run of CELLs wraps: the first node below them that is not a CELL.
-- |
-- | A CELL IS THE USER'S OWN BRACKETS, redundant by construction (mexpr_ast's maybe_cell), so a
-- | transformation that wants to see the expression rather than its grouping looks through them.
-- |
-- | @param node  node - checked
-- | @return node - `node` itself when it is not a CELL
-- |
-- | @date 2026-09-13 19:45
--]]
function transform_utils.peel_cells(node)
    ast.check_node(node, "node")
    while node.type == ast.CELL do
        node = node[1]
    end
    return node
end

--[[ @brief The first ancestor above `node` that is not a CELL, and its child on the way down.
-- |
-- | HOW AN OFFER LOOKS THROUGH BRACKETS: `a((b+c))` holds the sum two CELLs deep, and the product
-- | it belongs to is the first non-CELL ancestor.
-- |
-- | @param parents  {id -> node} - ast.parent_map of the tree `node` is in
-- | @param node     node - checked
-- | @return node | nil, node - the holder, nil when only CELLs (or nothing) sit above `node`; and
-- |         the holder's child on the path: the outermost CELL, or `node` when there is none
-- |
-- | @date 2026-09-13 19:45
--]]
function transform_utils.through_cells(parents, node)
    check_parents(parents)
    ast.check_node(node, "node")
    local slot = node
    local holder = parents[node.id]
    while holder and holder.type == ast.CELL do
        slot = holder
        holder = parents[holder.id]
    end
    return holder, slot
end

--[[ @brief A FLAT product of `factors`, in the shape the parser builds for the same text.
-- |
-- | FLAT: a factor that is itself a product is spliced in, in place, so `a(cd)` is MUL(a, c, d).
-- |
-- | ONE SIGN, IN FRONT: every number's sign is gathered, and the product's sign goes on its first
-- | factor when that is a number, otherwise on a -1 put in front - what the parser does with `-ac`
-- | and `-2a`. A factor of exactly 1 is dropped.
-- |
-- | ORDER IS OTHERWISE PRESERVED: multiplication is not assumed commutative - vectors have
-- | products. Only the sign moves, and a sign is a scalar.
-- |
-- | @details Returns the single survivor unwrapped, or a number when nothing survives, so a caller
-- |          never special-cases a one-factor product. The factors are placed as they are; a caller
-- |          that uses one node in two products copies it first.
-- |
-- | @param ns       ast.ns - checked; new numbers and the product are minted here
-- | @param factors  {node} - each checked; in order; not modified
-- | @return node - a MUL, a single factor, or a NUM
-- |
-- | @date 2026-09-13 19:45
--]]
function transform_utils.product(ns, factors)
    ast.check_ns(ns)
    assert(type(factors) == "table", "transform_utils.product needs a list of factors")
    local flat = {}
    for i, f in ipairs(factors) do
        ast.check_node(f, "factor " .. i)
        if f.type == ast.MUL then
            for _, inner in ipairs(f) do
                flat[#flat + 1] = inner
            end
        else
            flat[#flat + 1] = f
        end
    end

    local negative, kept = false, {}
    for _, f in ipairs(flat) do
        if f.type == ast.NUM and (f[3] or 1) < 0 then
            negative = not negative
            f = signed_num(ns, f, 1)
        end
        if not is_unit(f) then
            kept[#kept + 1] = f
        end
    end

    if negative then
        if kept[1] and kept[1].type == ast.NUM then
            kept[1] = signed_num(ns, kept[1], -1)
        else
            table.insert(kept, 1, ast.new_num(ns, 1, 1, -1))
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

--[[ @brief The tree with `new` where `old` was: the path to the root rebuilt, the rest shared.
-- |
-- | SHARES EVERY UNTOUCHED SUBTREE - the same node objects, with their own ids - and makes a new
-- | node only for the ancestors on the path. Author, 2026-09-11: "we want the transformation to
-- | reuse parts of the graph in the mexpr, changing litle let's us cut the graph in just the right
-- | parts to repair it with minimal stitches". Nothing is mutated, so the source tree stays valid.
-- |
-- | A SUM LANDING IN A SUM IS SPLICED: when `new` is an ADD and `old`'s parent is an ADD, `new`'s
-- | terms take `old`'s place among the parent's terms, rather than nesting a sum the parser would
-- | never build.
-- |
-- | @param ns       ast.ns - checked; the rebuilt ancestors are minted here
-- | @param root     node - checked; the walk stops here
-- | @param parents  {id -> node} - ast.parent_map(root)
-- | @param old      node - checked; must be reachable from `root`
-- | @param new      node - checked; what takes its place
-- | @return node | nil, string - the new root (`new` itself when `old` was the root); or nil and a
-- |         reason when `old` is not in this tree, which can only mean the caller mixed two trees
-- |
-- | @date 2026-09-13 19:45
--]]
function transform_utils.swap_in_parent(ns, root, parents, old, new)
    ast.check_ns(ns)
    ast.check_node(root, "root")
    check_parents(parents)
    ast.check_node(old, "old")
    ast.check_node(new, "new")

    local first = true
    while old ~= root do
        local parent = parents[old.id]
        if not parent then
            return nil, "the node is not in this tree"
        end
        local rebuilt = ast.new(ns, parent.type)
        local splice = first and new.type == ast.ADD and parent.type == ast.ADD
        for i = 1, #parent do
            if parent[i] == old then
                if splice then
                    for _, term in ipairs(new) do
                        rebuilt[#rebuilt + 1] = term
                    end
                else
                    rebuilt[#rebuilt + 1] = new
                end
            else
                rebuilt[#rebuilt + 1] = parent[i]
            end
        end
        old, new, first = parent, rebuilt, false
    end
    return new
end

--[[ @brief Answers whether `node` is a finite number of magnitude 1, +1 or -1, able to stand as a
-- |        term's sign coefficient.
-- |
-- | The sign is left open, unlike a test for exactly +1: a coefficient's whole job is to carry
-- | one. The parse stamps a term's sign as exactly this number - the unit leading the term's
-- | product - so a term's sign coefficient answers yes here.
-- |
-- | @param node  node - not checked
-- | @return boolean
-- |
-- | @date 19-10-2026-22:22
--]]
local function is_unit_magnitude(node)
    return node.type == ast.NUM and node[1] == 1 and node[2] == 1
end
transform_utils.is_unit_magnitude = is_unit_magnitude

--[[ @brief Answers whether `node` is a number carrying nothing but a sign - magnitude 1, finite or
-- |        infinite.
-- |
-- | +1, -1, and the two infinities, which are +1 and -1 over 0. A sign meeting one of these as a
-- | coefficient folds with it, infinity included, so `-(-inf)` becomes `+inf` and never a product
-- | of two minus-ones. Wider than is_unit_magnitude by exactly the infinities.
-- |
-- | @param node  node
-- | @return boolean
-- |
-- | @date 19-10-2026-20:35
--]]
local function is_sign_carrier(node)
    return node.type == ast.NUM and node[1] == 1 and (node[2] == 1 or node[2] == 0)
end

--[[ @brief Splits a sum's term into its leading number and its factors - the grammar of every term
-- |        distribute multiplies through:
-- |
-- |     b             ->  no sign, factors {b}
-- |     MUL(a, b)     ->  no sign, factors {a, b}   (spliced flat into the factors around it)
-- |     MUL(1, c)     ->  sign +1, factors {c}
-- |     MUL(-1, 2, x) ->  sign -1, factors {2, x}   (a sign is its own factor, never folded)
-- |     3             ->  the number is the whole term and its own coefficient
-- |
-- | Every term after a sum's first leads with the sign coefficient the parse stamped. The first
-- | term leads with one only when its sign was typed, so it usually comes back with none.
-- |
-- | @details Any leading number is taken as the coefficient, whatever its magnitude: the first
-- |          term `2x` gives 2, a value rather than a sign.
-- |
-- | @param t_node  node - a term of a sum; not checked
-- | @return node | nil, {node} - the leading NUM, the term itself when it is a NUM, or nil; and the
-- |         factors after it, in a fresh list holding the term's own nodes
-- |
-- | @date 19-10-2026-20:35
--]]
function transform_utils.split_term(t_node)
    if t_node.type == ast.NUM then
        return t_node, {}
    end
    if t_node.type == ast.MUL then
        --[[ A MUL with a leading NUM splits sign-from-factors; a MUL without one splices its
        -- | children flat into the surrounding factor list. The parse builds products flat - a
        -- | MUL inside a MUL is not a shape the tree keeps, and a result carrying one writes the
        -- | same ink but fails the reparse verify on flat-vs-nested. The bare case arrives here
        -- | as the first term of a bracketed sum; every term after the first carries its sign
        -- | coefficient and takes the leading-NUM branch. @date 19-10-2026-20:56 ]]
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

--[[ @brief Gives what `node` becomes as one of a product's factors: a single bracket pair around a
-- |        sum gives way to the sum.
-- |
-- | Among factors a sum needs exactly one pair of brackets, and the parse builds no CELL for that
-- | pair: `(a+b)c` reads as MUL(ADD, c). A CELL holding a sum directly, placed among factors, is
-- | a tree the parse never makes - its write draws the same ink and fails the reparse. Only the
-- | innermost pair is the sum's own, so `((a+b))` keeps its CELLs, as it reads back.
-- |
-- | @param node  node - about to be placed among a product's factors
-- | @return node - the ADD inside, when `node` is a CELL holding one directly; otherwise `node`
-- |
-- | @date 19-10-2026-20:35
--]]
local function as_factor(node)
    if node.type == ast.CELL and node[1].type == ast.ADD then
        return node[1]
    end
    return node
end

--[[ @brief Builds a product of `factors`, tidied: exact 1s dropped, a one-factor product
-- |        unwrapped.
-- |
-- | Distribution routinely leaves a product of one factor, or a stray 1 where a term was the
-- | unit; carrying those forward would make every later step read around debris the distribution
-- | created, so the cleanup happens in the same step that builds the product. When two or more
-- | factors survive, a CELL holding a sum directly gives way to the sum, since among factors the
-- | parse builds no CELL for a sum's one bracket pair. A bracketed first term moved among factors
-- | needs exactly that: `c((a+d)+b)` gives `c(a+d)`, the sum bare.
-- |
-- | The order of factors is preserved: multiplication is not assumed commutative - a vector
-- | product does not commute - and distribution is valid without commutativity while reordering
-- | factors is a different transformation altogether.
-- |
-- | @param ns       ast.ns - mints the replacement 1, when every factor was dropped
-- | @param factors  node[] - in order; not modified
-- | @return node - a MUL of what survived, the single survivor as it is, or the number 1, so a
-- |         caller never special-cases a one-factor product
-- |
-- | @note Signs stay where they are: a -1 is a factor like any other. `product`, in this file,
-- |       gathers them onto a leading number instead - the shape the parse built until a sign
-- |       became its own coefficient (DESIGN.md, 2026-09-15).
-- |
-- | @date 19-10-2026-22:22
--]]
local function product_of(ns, factors)
    local kept = {}
    for _, f in ipairs(factors) do
        if not is_unit(f) then
            kept[#kept + 1] = f
        end
    end
    if #kept == 0 then
        return ast.new_num(ns, 1, 1, 1)
    end
    if #kept == 1 then
        return kept[1]
    end
    for i, f in ipairs(kept) do
        kept[i] = as_factor(f)
    end
    return ast.new_mul(ns, table.unpack(kept))
end
transform_utils.product_of = product_of

--[[ @brief Builds a term of a sum: `coeff` attached to the front of `term`, in the shape the parse
-- |        would have produced.
-- |
-- | A coefficient never merges into another numeral - magnitudes never multiply, and `-2` times
-- | `x` stays a product rather than becoming a numeral of magnitude 2. What folds is signs only:
-- | a unit coefficient meeting a term that is, or already leads with, a number carrying nothing
-- | but a sign - +1, -1, or an infinity, which is 1 over 0 - folds the two into one (auto-reduced,
-- | for now), and the folded number keeps its own denominator, so infinity stays over 0. A unit
-- | +1 arriving on a first term is dropped outright: a plain term is what an unsigned term of a
-- | sum is. A numeral meeting a term that leads with a finite sign goes behind that sign, where
-- | the parse puts it: `-2y` is MUL(-1, 2, y).
-- |
-- | @param ns     ast.ns - where replacement numbers are minted
-- | @param coeff  node | nil - the term's leading NUM, or nil when it had none; nil hands `term`
-- |               back as it is
-- | @param term   node - the term before its coefficient is attached
-- | @param first  boolean - this term lands first in its sum
-- | @return node
-- |
-- | @note `coeff` may be placed into the result as it stands, so a caller handing the same node
-- |       to two calls can put one id in two places - the distribute transformation mints a fresh
-- |       unit per term for exactly that reason.
-- | @note A first term whose signs fold to +1 over 1 comes back as product_of builds its remaining
-- |       factors, so an exact 1 among them goes with the sign: `+x \cdot 1` landing first comes
-- |       back as `x`.
-- |
-- | @date 19-10-2026-22:22
--]]
function transform_utils.term_with_coeff(ns, coeff, term, first)
    if not coeff then
        return term
    end
    if is_unit_magnitude(coeff) and term.type == ast.MUL and is_sign_carrier(term[1]) then
        --[[ Fold: the two signs become one, on a fresh number, so the term keeps a single
        -- | leading sign. A first term folding to a plain +1 over 1 needs no sign at all, and
        -- | comes back tidied through product_of. @date 19-10-2026-20:56 ]]
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
    --[[ Fold, on a term that IS a sign carrier - the folded `+1` of a sum, or the lone sign a
    -- | product of nothing else left: one number with both signs. Attached instead, it drew
    -- | `x+-1` (found 18-10-2026). @date 18-10-2026-22:15 ]]
    if is_unit_magnitude(coeff) and is_sign_carrier(term) then
        return ast.new_num(ns, 1, term[2], (coeff[3] or 1) * (term[3] or 1))
    end
    --[[ Drop: a first term is what an unsigned term of a sum is, so a unit +1 arriving on one
    -- | is noise rather than a factor. @date 19-10-2026-20:56 ]]
    if first and is_unit_magnitude(coeff) and coeff[3] == 1 then
        return term
    end
    --[[ Behind a sign: in front of one, a numeral drew `2-1y`, which reads back as 2 - y, or
    -- | `2\cdot -1y`, which does not parse at all (found 18-10-2026). @date 18-10-2026-21:30 ]]
    if not is_unit_magnitude(coeff) then
        if is_unit_magnitude(term) then
            return ast.new_mul(ns, term, coeff)
        end
        if term.type == ast.MUL and is_unit_magnitude(term[1]) then
            local args = {term[1], coeff}
            for k = 2, #term do
                args[#args + 1] = term[k]
            end
            return ast.new_mul(ns, table.unpack(args))
        end
    end
    --[[ Attach: every other coefficient leads the term as a factor in its own right, prepended
    -- | to the term's own factors when there is a product to lead - and a term that is not one
    -- | becomes a factor itself, through as_factor. @date 18-10-2026-21:10 ]]
    if term.type == ast.MUL then
        local args = {coeff}
        for k = 1, #term do
            args[#args + 1] = term[k]
        end
        return ast.new_mul(ns, table.unpack(args))
    end
    return ast.new_mul(ns, coeff, as_factor(term))
end

return transform_utils

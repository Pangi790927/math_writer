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
-- | --- internal, not on the module table ---------------------------------------------------------
-- |     is_unit, signed_num, check_parents
-- |
-- | @date 2026-09-13 19:45
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
-- |       plugin by the folder scan.
-- |
-- | @date 2026-09-13 19:45
--]]

local ast = require("ast")

local transform_utils = {}

--[[ Is this the number 1, the factor a product may drop without changing? @date 2026-09-13 19:45 ]]
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

return transform_utils

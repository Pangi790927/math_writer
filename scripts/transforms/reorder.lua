--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- |
-- | apply(ctx: transforms.ctx)              -> node
-- |     Moves one term of a sum in front of another of its terms, or to the
-- |     end, and each term takes the sign of the place it lands in. Refuses
-- |     through ctx.check when the ids name no term and no place among that
-- |     term's own sum, or when the order would not change. Its params are
-- |     {term = <ast id>, before = <ast id>}, a plain table the caller builds.
-- |
-- | --- internal, not on the module table ---------------------------------------------------------
-- |     as_first, without_plus_one, placed, moved_order
-- |
-- | @date 19-10-2026-22:19
-- | ===============================================================================================
--]]

--[[ @file transforms/reorder.lua
-- | @brief Moving a term of a sum to another place among its terms: a + b + 2c with 2c dragged to
-- |        the front becomes 2c + a + b.
-- |
-- | THE DRAG IS THE ONLY WAY IN. A term selector names the term, the drop names its new place,
-- | and the UI builds the option itself - transforms.option("reorder", label, {term, before}) -
-- | and commits it like a menu pick. So this plugin has no offer: the right-click menu and F6 ask
-- | transforms.offers, which skips a plugin without one, and they stay as they were. With no
-- | offer to seal the params, they arrive as a plain table, and an id that names nothing is
-- | refused like any other drop that does not fit, rather than raised.
-- |
-- | Only a sum's terms move, and only among themselves: the step takes addition to commute, and
-- | nothing here touches the order of a product's factors. A drop into or out of a bracket, or
-- | across a relation, is a different transformation and is refused here.
-- |
-- | The result is what the parse of its own writing gives. Every term keeps its sign (DESIGN.md,
-- | "A sign is always its own coefficient"): the term that lands first loses a +1 and keeps a -1,
-- | and the term that leaves first gains a +1. Terms that stay first, or stay later, are the
-- | same nodes, shared; the sum and the path above it are rebuilt.
-- |
-- | @date 19-10-2026-20:39
--]]


local ast = require("ast")
local mexpr_ast = require("mexpr_ast")
local transforms = require("transforms")
local transform_utils = require("transform_utils")

local check = transforms.check
local check_ctx = transforms.check_ctx
local LEAF = mexpr_ast.CELL_LEAF

--[[ @brief Gives what `term` becomes as the first term of its sum, in the shape the parse gives the
-- |        same writing - the grammar of the term that lands first, once its sign is placed:
-- |
-- |     ADD(a, b)          ->  CELL(ADD(a, b))    x+(a+b)  ->  (a+b)+x
-- |     CELL(a)            ->  a                  x+(a)    ->  a+x
-- |     MUL(CELL(a), b)    ->  MUL(a, b)          x+(a)b   ->  ab+x
-- |     anything else      ->  itself
-- |
-- | With its +1 gone nothing stands in front of the term, and that is what the parse decides
-- | brackets by (mexpr_ast's maybe_cell). A sum that sat among the sign's factors stands alone
-- | now, so its pair is redundant and kept as a CELL. A leaf the pair held now leads the term, so
-- | the pair is dropped - and it does not come back when the term leaves first place again. A
-- | term that keeps a -1 keeps it in front, and its brackets do not change.
-- |
-- | @param ns    ast.ns - the CELL and the rebuilt product are minted here
-- | @param term  node - the term as without_plus_one leaves it: no +1 in front, a -1 kept
-- | @return node - `term` itself when nothing changes
-- |
-- | @date 19-10-2026-22:19
--]]
local function as_first(ns, term)
    if term.type == ast.ADD then
        return ast.new_cell(ns, term)
    end
    if term.type == ast.CELL and LEAF[term[1].type] then
        return term[1]
    end
    if term.type == ast.MUL and term[1].type == ast.CELL and LEAF[term[1][1].type] then
        local args = {term[1][1]}
        for k = 2, #term do
            args[#args + 1] = term[k]
        end
        return ast.new_mul(ns, table.unpack(args))
    end
    return term
end

--[[ @brief Gives `term` without the +1 that leads it, every factor behind that sign kept as it
-- |        stands:
-- |
-- |     MUL(+1, x, 1)    ->  MUL(x, 1)    a+x\cdot 1  ->  x\cdot 1+a
-- |     MUL(+1, x)       ->  x            a+x         ->  x+a
-- |     MUL(-1, x)       ->  itself       a-x         ->  -x+a
-- |     NUM(+1)          ->  itself       a+1         ->  1+a
-- |
-- | Only the sign goes. A typed 1 behind it stays, so the term dragged back out of first place
-- | regains its +1 and reads as it did. term_with_coeff is not used here for that reason: on a
-- | first term it drops every exact 1 along with the sign.
-- |
-- | A -1 is the term's own sign and stays in front. A +1 that is the whole term, the sign the parse
-- | folds onto a typed 1, is the term's value and stays too. A lone remaining factor stands alone,
-- | the shape the parse gives a term of one factor.
-- |
-- | @param ns    ast.ns - the product of the remaining factors is minted here, when two or more
-- |              remain
-- | @param term  node - a term of the sum, as the source tree has it
-- | @return node - the lone remaining factor, a new product of them, or `term` itself when no +1
-- |         leads it or nothing would remain
-- |
-- | @note A typed 1 that the parse folded the sign onto is that +1, and goes with it:
-- |       `a + 1 \cdot 1` with its second term moved first is `1 + a`.
-- |
-- | @date 19-10-2026-22:26
--]]
local function without_plus_one(ns, term)
    local coeff, rest = transform_utils.split_term(term)
    local plus_one = coeff and transform_utils.is_unit_magnitude(coeff) and coeff[3] == 1
    if not plus_one or #rest == 0 then
        return term
    end
    if #rest == 1 then
        return rest[1]
    end
    return ast.new_mul(ns, table.unpack(rest))
end

--[[ @brief Gives `term` as it stands in its new place: itself when it stays first or stays later,
-- |        and otherwise rebuilt with the sign of the place it lands in.
-- |
-- | A term landing first loses its +1 through without_plus_one, then takes the first place's
-- | brackets through as_first. The term leaving first gains a +1: a fresh unit handed to
-- | term_with_coeff, which folds it with a sign the term already leads with - the call distribute
-- | makes when its expanded terms join a sum. The unit is fresh per call because term_with_coeff
-- | may place it as it stands.
-- |
-- | @param ns         ast.ns - the unit and every rebuilt node are minted here
-- | @param term       node - one term of the sum, as the source tree has it
-- | @param first      boolean - it lands first
-- | @param was_first  boolean - it was first
-- | @return node
-- |
-- | @note A typed exact 1 stays with its term into first place and out of it, so the step undoes:
-- |       `a + x \cdot 1` with its second term moved first is `x \cdot 1 + a`, and `a` moved back
-- |       in front gives `a + x \cdot 1` again.
-- |
-- | @date 19-10-2026-22:26
--]]
local function placed(ns, term, first, was_first)
    if first == was_first then
        return term
    end
    if first then
        return as_first(ns, without_plus_one(ns, term))
    end
    return transform_utils.term_with_coeff(ns, ast.new_num(ns, 1, 1, 1), term, false)
end

--[[ @brief Lists `add`'s terms with `term` moved in front of `before`, or to the end when `before`
-- |        is `add` itself, and answers nil when that is the order they already have.
-- |
-- | @param add     node - the sum
-- | @param term    node - one of its terms
-- | @param before  node - one of its terms, `term` included, or `add`
-- | @return {node} | nil - the sum's own term nodes, reordered
-- |
-- | @date 19-10-2026-20:39
--]]
local function moved_order(add, term, before)
    local order = {}
    for i = 1, #add do
        if add[i] == before then
            order[#order + 1] = term
        end
        if add[i] ~= term then
            order[#order + 1] = add[i]
        end
    end
    if before == add then
        order[#order + 1] = term
    end
    for i = 1, #add do
        if order[i] ~= add[i] then
            return order
        end
    end
    return nil
end

--[[ @brief Moves one term of a sum to another place among its terms.
-- |
-- |     (abc+ab^2)d + ac + 2\pi,  2\pi in front of (abc+ab^2)d  ->  2\pi + (abc+ab^2)d + ac
-- |
-- | `params.term` names the term: a direct child of an ADD, so a bracketed term is its CELL.
-- | `params.before` names the term it lands in front of, or the ADD itself to land last. That is
-- | the whole input: the tree, and two ids.
-- |
-- | Refuses rather than widening. A drop anywhere but among the term's own siblings is refused,
-- | and so is a drop that leaves the order as it was, which would make a step that changes
-- | nothing.
-- |
-- | @param ctx  transforms.ctx - reads ctx.ns, ctx.root, ctx.params and ctx.parents()
-- | @return node - the new root. Untouched nodes keep their ids, and the result lives in the same
-- |         namespace.
-- | @throws refusal (ctx.check) when `params.term` names no term of a sum in this tree, when
-- |         `params.before` names neither a term of that same sum nor the sum itself, or when the
-- |         order would not change
-- |
-- | @date 19-10-2026-20:39
--]]
local function apply(ctx)
    check_ctx(ctx)
    local ns, root, params = ctx.ns, ctx.root, ctx.params
    local parents = ctx.parents()
    local term = ast.node_of(ns, params.term)
    local add = term and parents[term.id]
    check(add and add.type == ast.ADD, "only a term of a sum can be moved")
    local before = ast.node_of(ns, params.before)
    check(before and (before == add or parents[before.id] == add),
            "a term can only move among the terms of its own sum")
    local order = moved_order(add, term, before)
    check(order, "the term is already in that place")
    local kids = {}
    for p, t in ipairs(order) do
        kids[p] = placed(ns, t, p == 1, t == add[1])
    end
    return check(transform_utils.swap_in_parent(ns, root, parents, add,
            ast.new_add(ns, table.unpack(kids))))
end

--[[ @brief Registers the transformation, on by default and with no offer, since a drag is its only
-- |        way in. @date 19-10-2026-20:39
--]]
transforms.register{
    id = "reorder",
    label = "Reorder terms",
    params = {"term", "before"},
    default_active = true,
    apply = apply,
}

return true

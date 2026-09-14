--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- |
-- | NAMESPACES AND NODES
-- | new_ns()                                -> ns
-- | node_of(ns: ast.ns, id: id)             -> node | nil
-- |     THE ONLY WAY TO READ A NAMESPACE - `by_id` is the storage, this is
-- |     the lookup, and it CHECKS what it found. A miss is nil; an entry
-- |     that is not a node raises.
-- | check_ns(ns: ast.ns)                    -> ns
-- | check_node(node: node, what: string | nil) -> node
-- |     Assert a namespace or a node, for a function in another file that
-- |     takes one - the shapes are declared here and are local to here.
-- | is_node(x: any)                         -> boolean
-- |     The dispatch half of "value or node": a table carrying a `type`.
-- |     check_node is the guarantee; this is only the question.
-- | ns_insert_object(ns: ast.ns, id: id, obj: node) -> nothing
-- | new(ns: ast.ns, type: ast type, id: id | nil)   -> node
-- |     A namespace owns ids; every node is minted into one and answers to
-- |     `ns.by_id[id]`. The id IS the name (phase2 section 10), so two
-- |     nodes may never share one.
-- |
-- | copy(ns: ast.ns, node: node, new_ns: ast.ns, keep_vars: boolean) -> node
-- | copy_fresh(ns: ast.ns, node: node | value) -> node | value
-- |     The same tree somewhere else, versus a second tree that looks the
-- |     same. copy_fresh mints new ids in the SAME namespace - what a
-- |     transformation needs when a subtree lands in two places.
-- | ns_import_ast(dst_ns: ast.ns, src_ns: ast.ns, node: node) -> NOT IMPLEMENTED
-- |     A stub with an empty body since it was written. It RAISES; it does
-- |     not return a node. See the TODO on it for what is undecided.
-- |
-- | parent_map(root: node)                  -> {child id -> parent node}
-- |     Computed per call and thrown away; never stored on a node, because
-- |     a tree is shared and two trees would disagree about the parent.
-- |
-- | RELATIONS
-- | new_eq(ns: ast.ns, expr1: node, expr2: node) -> node
-- | new_ineq_less(ns: ast.ns, expr1: node, expr2: node) -> node
-- | new_ineq_leq(ns: ast.ns, expr1: node, expr2: node) -> node
-- | new_ineq_neq(ns: ast.ns, expr1: node, expr2: node) -> node
-- | new_ineq_greater(ns: ast.ns, expr1: node, expr2: node) -> node
-- | new_ineq_geq(ns: ast.ns, expr1: node, expr2: node) -> node
-- | new_tends(ns: ast.ns, expr1: node, expr2: node) -> node
-- | new_implies(ns: ast.ns, expr1: node, expr2: node) -> node
-- | new_iff(ns: ast.ns, expr1: node, expr2: node) -> node
-- |     Each is two operands and nothing else. Both are CHECKED to be nodes.
-- |     GENERATED, one per row of BINARY_TYPES in a loop - no definition line,
-- |     no per-function header; the loop's one comment carries the family.
-- |
-- | SET RELATIONS
-- | new_in(ns: ast.ns, expr1: node, expr2: node) -> node
-- | new_ni(ns: ast.ns, expr1: node, expr2: node) -> node
-- | new_subset(ns: ast.ns, expr1: node, expr2: node) -> node
-- | new_subseteq(ns: ast.ns, expr1: node, expr2: node) -> node
-- | new_supset(ns: ast.ns, expr1: node, expr2: node) -> node
-- | new_supseteq(ns: ast.ns, expr1: node, expr2: node) -> node
-- |     The same shape; membership and containment, both directions.
-- |     GENERATED with the relations above, from the same BINARY_TYPES loop.
-- |
-- | ARITHMETIC
-- | new_add(ns: ast.ns, ...: node)          -> node
-- | new_mul(ns: ast.ns, ...: node)          -> node
-- |     N-ary and order-preserving: `a+b+c` is ONE node with three
-- |     children, and multiplication is not assumed commutative. EVERY
-- |     operand is checked, which is where a stray nil would otherwise go
-- |     unnoticed - nothing downstream reads the arity back.
-- |     GENERATED, one per row of a small loop (ADD/MUL/VEC).
-- | new_div(ns: ast.ns, expr1: node, expr2: node)   -> node
-- |     Binary; generated with the relations, from BINARY_TYPES.
-- | new_exp(ns: ast.ns, base: node, exponent: node) -> node
-- | new_int(ns: ast.ns, name: string, sup: node, sub: node, body: node) -> node
-- | new_group_bigop(ns: ast.ns, node_type: ast type, vars: {name}, sups: {node}, subs: {node},
-- |                 body: node)             -> node
-- |     The explicit form. `vars` is a list of NAMES, not nodes.
-- |
-- | new_sum / new_prod / new_union / new_intersect / new_lim / new_limsup / new_liminf / new_min /
-- | new_max / new_sup / new_inf / new_argmin / new_argmax
-- |     (ns: ast.ns, vars: {name}, sups: {node}, subs: {node}, body: node) -> node
-- |     GENERATED, one per row of GROUP_BIGOP_SYMBOL, in a loop rather than
-- |     typed out - so there is no `function ast.new_sum(...)` line
-- |     anywhere. They are otherwise identical to new_group_bigop with the
-- |     type already chosen, and each carries the same argument checks.
-- |
-- | LEAVES AND STRUCTURE
-- | new_num(ns: ast.ns, m: number, n: number, sign: number) -> node
-- |     A RATIONAL, not a float: numerator, denominator and sign kept
-- |     apart, so a third stays a third. The sign lives on the number.
-- | num_text(node: node)                    -> text
-- | new_var(ns: ast.ns, name: string)       -> node   the declaration
-- | new_vref(ns: ast.ns, ref: node | id)    -> node   a USE of one
-- | new_call(ns: ast.ns, fn: node | string, ...: node) -> node
-- |     `fn` may be a STRING - a declaration's key, when it lives in
-- |     another box's namespace. The arguments must be nodes.
-- | new_vec(ns: ast.ns, ...: node)                  -> node
-- |     Generated with new_add/new_mul.
-- | new_cell(ns: ast.ns, expr: node)                -> node
-- | new_mat(ns: ast.ns, rows: number, cols: number, ...: node) -> node
-- | new_null(ns: ast.ns)                            -> node
-- |
-- | TEXT
-- | to_string(ns: ast.ns, node: node)       -> text
-- | to_string_lines(ns: ast.ns, node: node, depth: number, out: {line}) -> {line, ...}
-- | from_string(ns: ast.ns, s: string)      -> node | value | nil
-- |     A pair: what to_string writes, from_string reads back - and RAISES
-- |     on text it cannot read. Ids are in it, so it cannot compare two
-- |     trees across namespaces.
-- | shape(ns: ast.ns, node: node)           -> text
-- |     THE COMPARISON KEY, id-free, for asking whether two trees in
-- |     different namespaces are the same expression.
-- | type_name(node_type: ast type)          -> text | nil
-- |
-- | --- internal, not on the module table ---------------------------------------------------------
-- |     new_ns()       THE ONE creator for a namespace - see it for the `ns` shape
-- |     new()          THE ONE creator for a node - see it for the `node` shape
-- |     new_bigop, and the type/symbol tables
-- |
-- | @date 2026-09-14 11:00
-- | ===============================================================================================
--]]

--[[
ast.lua - THE MEANING TREE: what a formula IS, as opposed to how it is drawn or typed.

Every mathematical element has a node shape here; serialization, deserialization and the transforms
are all written against this base. The editors do not build these yet - phase 1 keeps a formula as
mexpr plus LaTeX - so this is the model phase 2 grows into (docs/phase2_design.md), and
transforms.lua is the first thing written against it.

A node is a TUPLE: an operator, then its operands, each node carrying its own id so anything else
can refer to it. The catalogue of tuple shapes is written out below.

NOT HERE: an ast -> LaTeX writer sat at the bottom of this file until 2026-09-09, when it and
mexpr.lua (its only consumer) were deleted as unreachable. The LaTeX the app really reads and
writes is mformula_latex.lua's, and it works on the mexpr tree, not on these nodes.

@date 2026-09-14
]]

-- tuples:
-- _ID:(...)                    -- tuple with it's id, each tupple will have such an ID 
-- (=, a1, a2)                  -- equality
-- (<, a1, a2)                  -- inequality (and all others <, <=. >=, >, !=)
-- (+, a1, a2, a3, ...)         -- sum of elements
-- (*, a1, a2, a3, ...)         -- product of elements
-- (/, a1, a2)                  -- division
-- (^, a1, a2)                  -- exponentiation
-- (N, m, n, sign)              -- rational/natural number m/n
-- (@, f, a1, a2, a3, ...)      -- function call
-- (#, name)                    -- named variable
-- (&, id)                      -- variable reference
-- (V, a1, a2, a3, ...)         -- vector
-- (M, m, n, a1, ... a[m+n])    -- matrix
-- (_, a1)                      -- paranthesis
-- (~, )                        -- see ast.NULL: an operand that is deliberately absent
-- (I, var, sup, sub, body)     -- integral  \int_{sub}^{sup} body d(var). \int keeps this fixed
--                                 four-slot shape rather than the constraint lists below - its
--                                 variable comes from the trailing differential, not from a
--                                 relation (docs/phase2_design.md "Bigop scoping"). SUP FIRST
--                                 since 2026-09-11, like the groups - see new_bigop. An absent
--                                 bound is a NULL node, never a nil
-- (in, a1, a2)                 -- membership: a1 \in a2
-- (ni, a1, a2)                  -- backward membership: a1 \ni a2  (== a2 \in a1)
-- (subset, a1, a2)              -- proper subset: a1 \subset a2
-- (subeq, a1, a2)               -- subset-or-equal: a1 \subseteq a2
-- (supset, a1, a2)              -- proper superset: a1 \supset a2
-- (supeq, a1, a2)               -- superset-or-equal: a1 \supseteq a2
--
-- BIGOP GROUPS - added 2026-09-10, "Bigop scoping" (docs/phase2_design.md): SUM/PROD/UNION/
-- INTERSECT share one shape, N variables and a constraint list per side rather than one var and a
-- bare from/to - see new_bigop_group. Three plain counts up front (same idiom MAT's own m/n
-- already use for metadata that isn't itself a node), then that many children in order:
-- (S,    n_vars, n_sup, n_sub, var1..varN, sup1..supM, sub1..subK, body)   -- \sum
-- (P,    n_vars, n_sup, n_sub, var1..varN, sup1..supM, sub1..subK, body)   -- \prod
-- (U,    n_vars, n_sup, n_sub, var1..varN, sup1..supM, sub1..subK, body)   -- \bigcup
-- (X,    n_vars, n_sup, n_sub, var1..varN, sup1..supM, sub1..subK, body)   -- \bigcap
-- each sup/sub constraint is itself a real relation node (=, <, in, subeq, ...) built the same way
-- any other relation is - a bigop remembers them rather than discarding them once the variables it
-- spawns are known.
-- SUP BEFORE SUB in all five operators since 2026-09-11 (new_bigop's own note for why). The side
-- that SPAWNS is still the sub - that is a different question and it did not move.
-- ...                          -- other custom ones to be thought about later?

--[[ reminder: name option: mathew - math expression writter @date 2026-09-08 08:55 ]]

local sealed = require("sealed")

local ast = {
    INVALID = 1,
    EQ = 2,
    INEQ_LESS = 3,
    INEQ_LEQ = 4,
    INEQ_NEQ = 5,
    INEQ_GREATER = 6,
    INEQ_GEQ = 7,
    ADD = 8,
    MUL = 9,
    DIV = 10,
    EXP = 11,
    NUM = 12,
    CALL = 13,
    VAR = 14,
    VEC = 15,   --[[VEC and MAT are here for later, so I don't forget about them]]
    MAT = 16,
    CELL = 17,  --[[ paranthesis - not sure why I would care about this? ]]
    VREF = 18,
    --[[ The BIG OPERATORS, added 2026-09-10. One shape, three operators - see new_bigop below for
    what makes them different in kind from everything above: they DECLARE a variable. ]]
    SUM = 19,
    PROD = 20,
    INT = 21,
    --[[ Relations, added 2026-09-10 alongside "Bigop scoping" (docs/phase2_design.md) - general
    purpose, not bigop-only, same shape as EQ. IN/NI and SUBSET*/SUPSET* are mirror pairs of each
    other (`a \ni b` means exactly `b \in a`) but get their OWN types regardless, same precedent
    INEQ_LESS/INEQ_GREATER already set for `<`/`>` - a mirrored glyph is still a distinct glyph, not
    an excuse to reuse a node with swapped operands. ]]
    IN = 22,
    NI = 23,
    SUBSET = 24,
    SUBSETEQ = 25,
    SUPSET = 26,
    SUPSETEQ = 27,
    --[[ UNION/INTERSECT, added the same day as IN/SUBSETEQ - share SUM/PROD's constraint-list
    shape (new_bigop_group below), not the single-var shape INT still uses. ]]
    UNION = 28,
    INTERSECT = 29,
    --[[ NOTHING IN THIS SLOT, on purpose: an indefinite integral has no bound, and a nil there
    would stop Lua's `#` at the hole - every generic walk over a node's children silently skipped
    the body. A leaf with no operands, serializing as `(null:id)` and reading back like any node.
    @date 2026-09-11 07:00 ]]
    NULL = 30,
    --[[ `x \\to 0`, the relation a limit's subscript is written with. A RELATION rather than
    anything limit-specific: `\to` is ordinary notation that happens to be where limits use it, and
    a bigop's constraints are built through the same door as any other relation (RELATIONS in
    mexpr_ast). Asymmetric like membership - only the left side varies, so only it may be spawned.
    @date 2026-09-11 10:20 ]]
    TENDS = 31,
    --[[ THE NAMED BIG OPERATORS - written as words rather than as a glyph, and otherwise identical
    to SUM/PROD: same group shape, same constraint lists, same spawning. Added 2026-09-11 on request
    ("now do the limit too, it should look like sum and also add min, max argmin argmax").

    They differ from `sin`/`log`/`det`, which are also words: those are NAMES applied to an
    argument (`sin(),(1)` in the trie), while these DECLARE a variable in their subscript and bind
    it in their body. Which is exactly the sum/integral distinction, so they take that machinery
    whole - see GROUP_BIGOP_SYMBOL below for how little is per-operator. ]]
    LIM = 32,
    MIN = 33,
    MAX = 34,
    ARGMIN = 35,
    ARGMAX = 36,
    --[[ `limsup`/`liminf` are ONE word here, not two. They are written `lim sup` and this app
    drops spaces before reading an operator's letters, so the vert spells `limsup` however it was
    typed - which is also the macro LaTeX names it by. ]]
    LIMSUP = 37,
    LIMINF = 38,
    SUP = 39,
    INF = 40,
    --[[ LOGICAL IMPLICATION AND EQUIVALENCE - binary relations, but binding LOOSER than every one
    of them, which is why mexpr_ast keeps them out of its RELATIONS table. Not TENDS: a different
    glyph ("tends to" vs "implies"), a different node. @date 2026-09-11 16:00 ]]
    IMPLIES = 41,
    IFF = 42,
}

--[[ THE `ns` CONTAINER's declared fields - the id -> node storage plus the next id to hand out.
Sealed like every other container; ids are what a reference names, so a node only means anything
inside the namespace it was made in. The field strings below are the one list.
@date 2026-09-12 08:00 ]]
local NS_FIELDS = {
    by_id   = "{id -> node}: the STORAGE. Written by ns_insert_object; read through "
              .. "ast.node_of, which checks what it found. Reaching in directly is what let a "
              .. "non-node sit in it unnoticed.",
    last_id = "the next id to hand out, kept PAST anything inserted - including ids read back "
              .. "from a file - so a loaded document can never be handed one it already uses.",
}
local NS_SHAPE = sealed.declare("ast", "ns", NS_FIELDS)

--[[ THE `node` CONTAINER's declared fields, in ARRAY MODE: children are positional and unbounded
(and a leaf's array part holds its value), so integer keys pass untouched and only the two string
keys are policed. Catches `node.typ`/`node.parent`/`node.value`; does not check child count or
type - `type` decides what the array part means, and only the constructors set both together.
@date 2026-09-12 08:30 ]]
local NODE_FIELDS = {
    type = "one of the ast.* constants; ast.type_name() reads it back",
    id   = "its name in the namespace, unique and never reused",
}
local NODE_SHAPE = sealed.declare("ast", "node", NODE_FIELDS, {array = true})

--[[ @brief A fresh, empty namespace. THE ONE CREATOR of the `ns` container.
-- |
-- | IDS ARE THE REAL NAMES in this model (docs/phase2_design.md section 10), and a namespace is
-- | what hands them out and resolves them. Every node belongs to exactly one.
-- |
-- | @details Sealed, with two fields: `by_id` {id -> node}, read only through node_of; and
-- |          `last_id`, the next id to hand out, kept PAST anything inserted - ids read back from a
-- |          file included - so a loaded document is never given an id it already uses. What is
-- |          inside `by_id` is an ordinary table.
-- |
-- | @return ast.ns - empty, handing out 1 first
-- |
-- | @date 2026-09-13 21:30
--]]
function ast.new_ns()
    return NS_SHAPE.wrap{ by_id = {}, last_id = 1 }
end

--[[ @brief Registers a node under `id`, keeping the namespace's next id past it.
-- |
-- | SO AN ID READ BACK FROM A FILE cannot later be handed out a second time.
-- |
-- | @param ns   ast.ns - checked
-- | @param id   id - the integer to register under
-- | @param obj  node - checked
-- |
-- | @note Overwrites whatever `id` held; ast.new checks for a collision before calling this, and
-- |       ast.copy does not.
-- |
-- | @date 2026-09-13 21:30
--]]
function ast.ns_insert_object(ns, id, obj)
    NS_SHAPE.check(ns)
    NODE_SHAPE.check(obj, "obj")
    ns.by_id[id] = obj
    if ns.last_id <= id then
        ns.last_id = id + 1
    end
end


--[[ @brief The node an id names in `ns`, or nil.
-- |
-- | THE ONLY WAY TO READ A NAMESPACE. `by_id` is the storage; this is the lookup, and it CHECKS
-- | what it found. Before it existed every caller wrote `ns.by_id[id]` and had to remember the
-- | result is indexed as a node - which is how ast.shape came to read `var[1]` off whatever was
-- | there. Author, 2026-09-12: "instead of a public array... this way we are sure of what it is".
-- |
-- | @param ns  ast.ns - checked
-- | @param id  id
-- | @return node | nil - nil for a MISS, which is ordinary: an id from another namespace, or from a
-- |         parse since thrown away
-- | @throws when the entry is not a node - something wrote past ns_insert_object
-- |
-- | @date 2026-09-13 21:30
--]]
function ast.node_of(ns, id)
    NS_SHAPE.check(ns)
    local node = ns.by_id[id]
    if node == nil then
        return nil
    end
    return NODE_SHAPE.check(node, "the node id " .. tostring(id) .. " names")
end

--[[ @brief Asserts that `ns` is a namespace, for a function elsewhere that takes one.
-- |
-- | PUBLISHED because the shapes are declared HERE while plenty of callers live in other files, and
-- | NS_SHAPE / NODE_SHAPE are local to this one.
-- |
-- | @param ns  any
-- | @return ast.ns - `ns`, so the call can stand as a function's first line
-- | @throws naming the type that arrived
-- |
-- | @date 2026-09-13 21:30
--]]
function ast.check_ns(ns)
    return NS_SHAPE.check(ns, "ns")
end

--[[ @brief Asserts that `node` is an ast node, for a function elsewhere that takes one.
-- |
-- | @param node  any
-- | @param what  string | nil - the parameter's name in the message; "node" when nil
-- | @return node - `node`
-- | @throws naming the type that arrived, and the parameter
-- |
-- | @date 2026-09-13 21:30
--]]
function ast.check_node(node, what)
    return NODE_SHAPE.check(node, what or "node")
end

--[[ @brief Is this an ast node - a table carrying a `type`?
-- |
-- | THE DISPATCH HALF of "value or node", the question every recursive walk over a node's array
-- | part asks. ast.check_node is the guarantee; this is only the test.
-- |
-- | @param x  any
-- | @return boolean
-- |
-- | @date 2026-09-14
--]]
function ast.is_node(x)
    return type(x) == "table" and x.type ~= nil
end

--[[ @brief A node of `type`, registered in `ns`. THE ONE CREATOR of the `node` container.
-- |
-- | EVERY CONSTRUCTOR GOES THROUGH HERE, which is what makes "has an id" true of every node rather
-- | than of most. A node has two named fields - `type`, `id` - and an ARRAY PART: the children in
-- | meaning order, or a leaf's VALUE (NUM {m, n, sign}, VAR {name}, VREF {referenced id}).
-- |
-- | SEALED IN ARRAY MODE: integer keys pass untouched, and any string key but `type` and `id` is
-- | refused. `type` decides what the array part means; only the constructors set both together.
-- |
-- | `id` IS THE DESERIALIZER'S DOOR. Without it the namespace hands out the next free id; with it
-- | the node takes the id it is given, because the ids in a saved tree are what its references
-- | point at. The id is decided before anything is registered.
-- |
-- | @param ns    ast.ns - checked
-- | @param type  ast type - one of the ast.* constants; not checked
-- | @param id    id | nil - a specific id to take
-- | @return node - sealed, registered, with an empty array part for the caller to fill
-- | @throws when `id` is given and already taken in `ns`
-- |
-- | @note Correcting the id afterwards, as from_string once did, registered each node twice and
-- |       made every tree of more than one node unreadable.
-- |
-- | @date 2026-09-13 21:30
--]]
function ast.new(ns, type, id)
    NS_SHAPE.check(ns)
    --[[ SEALED BEFORE IT IS REGISTERED, not after: ns_insert_object checks that what it is handed
    is a node, and a node that has not been wrapped yet is not one. Wrapping here also means the two
    assignments below go through the seal, which is the cheapest possible proof that `type` and `id`
    really are declared. ]]
    local ret = NODE_SHAPE.wrap({ type = type })
    if id then
        if ast.node_of(ns, id) then
            error("ID " .. tostring(id) .. " is already taken in namespace")
        end
        ret.id = id
    else
        ret.id = ns.last_id
    end
    ast.ns_insert_object(ns, ret.id, ret)
    return ret
end

--[[ @brief The same tree in another namespace, under the SAME ids.
-- |
-- | THE SAME TREE SOMEWHERE ELSE - copy_fresh is the other half, a second tree that looks the same.
-- | Ids are kept, so `new_ns` is presumed empty of them at the root of the call.
-- |
-- | @param ns         ast.ns - checked; where `node` lives
-- | @param node       node - checked; the tree to copy
-- | @param new_ns     ast.ns - checked here rather than inside ast.new, so the error names this
-- |                   argument
-- | @param keep_vars  boolean - true registers each referenced VAR in `new_ns` under its own id, so
-- |                   the copy's references still resolve
-- | @return node - the copy's root, sealed
-- | @throws for a reference when `keep_vars` is false: creating new variables in the new namespace
-- |         is not written yet
-- |
-- | @note Nothing calls this today. Existing entries in `new_ns` are overwritten without a check.
-- |
-- | @date 2026-09-13 21:30
--]]
function ast.copy(ns, node, new_ns, keep_vars)
    NS_SHAPE.check(ns)
    --[[ The DESTINATION is checked here too, not left to the inner ast.new: caught there, the
    error names a call inside this function instead of the argument the caller got wrong. ]]
    NS_SHAPE.check(new_ns, "new_ns")
    NODE_SHAPE.check(node, "node")
    --[[ SEALED, like anything ast.new makes. This is the one constructor that does NOT go through
    ast.new - it has to keep the source's id rather than take a fresh one - so the wrap has to be
    written here, and it was missed when nodes were first sealed: `ns_insert_object` refused the
    plain table and every call to this raised. Nothing calls ast.copy today, which is exactly why
    no test noticed. ]]
    local ret = NODE_SHAPE.wrap{ type = node.type }
    ast.ns_insert_object(new_ns, node.id, ret)
    for i = 1, #node do
        if type(node[i]) == "table" and node[i].id then
            if node[i].type == ast.VREF then
                if keep_vars then
                    ast.ns_insert_object(new_ns, node[i][1], ast.node_of(ns, node[i][1]))
                else
                    error("TODO: I didn't need it until now, but I must find a way to " ..
                            "create the new vars inside the new namespace, or figure out a " ..
                            "different solution like to specify what are the new vars " ..
                            "in the new namespace")
                end
            end
            ret[i] = ast.copy(ns, node[i], new_ns, keep_vars)
        else
            ret[i] = node[i]
        end
    end
    return ret
end

--[[ @brief A deep copy of `node` with FRESH ids, in the SAME namespace.
-- |
-- | FOR A SUBTREE THAT LANDS IN TWO PLACES. `a(b+c)` distributed leaves `a` twice, and two nodes
-- | cannot answer to one id - the id is the real name (phase2 section 10). ast.copy keeps ids, so
-- | it would produce exactly that collision.
-- |
-- | VREFs ARE COPIED AS REFERENCES, never followed: a second reference to one variable is a new
-- | node pointing at the same VAR, not a second variable.
-- |
-- | @param ns    ast.ns - checked; the copy is minted here
-- | @param node  node | value - a node is checked; a scalar comes back as itself, which is how the
-- |              recursion reaches a leaf's value
-- | @return node | value
-- |
-- | @date 2026-09-13 21:30
--]]
function ast.copy_fresh(ns, node)
    NS_SHAPE.check(ns)
    -- A value or a node; see ast.to_string for why a scalar here is the base case, not an error.
    if type(node) == "table" then
        NODE_SHAPE.check(node, "node")
    end
    if type(node) ~= "table" or not node.type then
        return node
    end
    local ret = ast.new(ns, node.type)
    for i = 1, #node do
        ret[i] = ast.copy_fresh(ns, node[i])
    end
    return ret
end

--[[ @brief child id -> parent node, for one tree.
-- |
-- | COMPUTED PER CALL AND THROWN AWAY, never stored on the nodes. A tree is shared - a
-- | transformation's result keeps most of its source's nodes - so a `.parent` on a node would write
-- | into something somebody else holds, and the two trees would disagree about the parent.
-- |
-- | @param root  node - checked; the root has no entry
-- | @return {[id] = node} - a fresh plain table
-- |
-- | @note A node reachable twice under one root would be mapped to whichever parent was walked
-- |       last. Trees here never share a node within one root, which copy_fresh exists to
-- |       guarantee.
-- |
-- | @date 2026-09-13 21:30
--]]
function ast.parent_map(root)
    NODE_SHAPE.check(root, "root")
    local parents = {}
    local function walk(node)
        for i = 1, #node do
            local child = node[i]
            if ast.is_node(child) then
                parents[child.id] = node
                walk(child)
            end
        end
    end
    walk(root)
    return parents
end

--[[ @brief NOT IMPLEMENTED: importing a tree from one namespace into another. It raises.
-- |
-- | @param dst_ns  ast.ns - checked
-- | @param src_ns  ast.ns - checked
-- | @param node    node - not reached
-- | @throws always, "not implemented"
-- |
-- | @note TODO: figure out if this makes sens, if this is not copy with extra rules, etc.
-- |
-- | @date 2026-09-13 21:30
--]]
function ast.ns_import_ast(dst_ns, src_ns, node)
    NS_SHAPE.check(dst_ns)
    NS_SHAPE.check(src_ns, "src_ns")
    --[[ RAISES RATHER THAN RETURNING NIL, which is what it did before 2026-09-12. An unimplemented
    function that quietly answers nil is the same silence the sealed containers exist to remove: the
    caller carries on with a nil it never meant to have, and the manifest above said `-> node`, so
    nothing anywhere suggested it was a stub. Nothing calls this today, so raising changes no
    behaviour - it only makes the first caller find out immediately. ]]
    error("ast.ns_import_ast is not implemented - see its comment", 2)
end

--[[ Every BINARY constructor in one loop - two checked operands in the written order, and nothing
differs between them but the type. Generated the same way the group bigop family further down is:
no `function ast.new_eq(...)` line exists, so there is no per-function header; each is still an
entry in the manifest above. `pairs` order is irrelevant here - no two rows touch the same key.

The value beside each name is what the node reads as; documentation only.
@date 2026-09-14 ]]
local BINARY_TYPES = {
    EQ           = "a = b",
    INEQ_LESS    = "a < b",
    INEQ_LEQ     = "a <= b",
    INEQ_NEQ     = "a != b",
    INEQ_GREATER = "a > b",
    INEQ_GEQ     = "a >= b",
    TENDS        = "a \\to b",
    IMPLIES      = "a \\Rightarrow b",
    IFF          = "a \\Leftrightarrow b",
    IN           = "a \\in b",
    NI           = "a \\ni b",
    SUBSET       = "a \\subset b",
    SUBSETEQ     = "a \\subseteq b",
    SUPSET       = "a \\supset b",
    SUPSETEQ     = "a \\supseteq b",
    DIV          = "a / b",
}
for name in pairs(BINARY_TYPES) do
    local node_type = ast[name]
    ast["new_" .. name:lower()] = function(ns, expr1, expr2)
        NS_SHAPE.check(ns)
        NODE_SHAPE.check(expr1, "expr1")
        NODE_SHAPE.check(expr2, "expr2")
        local ret = ast.new(ns, node_type)
        ret[1] = expr1
        ret[2] = expr2
        return ret
    end
end

-- Arithmetic operators
--[[ The N-ARY constructors of one shape - every operand checked, order kept - generated like the
binary family above. `a+b+c` is ONE node with three children (a gesture on any `+` names the whole
sum), and multiplication is not assumed commutative, so order is kept there too. `new_call` and
`new_mat` stay hand-written: each takes leading non-node arguments of its own.
@date 2026-09-14 ]]
for _, name in ipairs{"ADD", "MUL", "VEC"} do
    local node_type = ast[name]
    ast["new_" .. name:lower()] = function(ns, ...)
        NS_SHAPE.check(ns)
        --[[ EVERY operand, not just the first: a variadic constructor is where a stray nil or a raw
        number slips in unnoticed, because nothing downstream reads the arity back. ]]
        for i = 1, select("#", ...) do
            NODE_SHAPE.check((select(i, ...)), "operand " .. i)
        end
        local ret = ast.new(ns, node_type)
        for i, expr in ipairs({...}) do
            ret[i] = expr
        end
        return ret
    end
end

--[[ Only the integral still has the OLD bigop shape, (var, sup, sub, body); the rest moved to the
GROUP shape (new_bigop_group) - N variables and a constraint list per side, because a single `var`
was not general enough for `i<n`, `i \in S`, or more than one variable. INT keeps this shape: its
variable comes from the trailing `dx`, so its limits were never constraints to generalize.

BIG OPERATORS ARE THE FIRST NODES THAT DECLARE A NAME: `var` is an ast.new_var owned by this node,
and the body refers to it through an ordinary new_vref - so scope needs no second mechanism. A name
resolves to the innermost binder that declares it; a name no binder claims travels outward past the
root as a free variable.
@date 2026-09-10 07:05 ]]
local OLD_SHAPE_BIGOPS = {[ast.INT] = true}

--[[ EVERY GROUP-SHAPED BIG OPERATOR, and the only place one is named: type name -> the symbol it
serializes as. One row here generates the operator's membership in GROUP_BIGOPS (so catch_free
scopes it), its type_to_symbol entry and hence its round-trip, and its `ast.new_<name>`
constructor - nothing else is per-operator, because nothing else about them differs. Word symbols
for the named ones; the tuple reader takes any symbol with no comma in it, so length costs nothing.
@date 2026-09-11 10:20 ]]
local GROUP_BIGOP_SYMBOL = {
    SUM = "S", PROD = "P", UNION = "U", INTERSECT = "X",
    LIM = "lim", LIMSUP = "limsup", LIMINF = "liminf",
    MIN = "min", MAX = "max", SUP = "sup", INF = "inf",
    ARGMIN = "argmin", ARGMAX = "argmax",
}

local GROUP_BIGOPS = {}
for name in pairs(GROUP_BIGOP_SYMBOL) do
    GROUP_BIGOPS[ast[name]] = true
end

--[[ Rebinds every FREE reference to `name` inside `sub` so it points at `var` - the whole of the
binding. Free means not already claimed by a nearer binder: a nested operator declaring the same
name shadows this one, so its body is skipped while its bounds (written outside its own scope) are
still ours. Only VREFs move; the VAR they pointed at stays, since something outside the body may
still be referring to it.
@date 2026-09-10 07:40 ]]
local function catch_free(ns, sub, name, var)
    if not ast.is_node(sub) then
        return
    end
    if sub.type == ast.VREF then
        local target = ast.node_of(ns, sub[1])
        if target and target.type == ast.VAR and target[1] == name then
            sub[1] = var.id
        end
        return
    end
    if OLD_SHAPE_BIGOPS[sub.type] and sub[1] and sub[1][1] == name then
        -- Shadowed: its body is that operator's, but its bounds are still ours.
        catch_free(ns, sub[2], name, var)
        catch_free(ns, sub[3], name, var)
        return
    end
    if GROUP_BIGOPS[sub.type] then
        local n_vars, n_sup, n_sub = sub[1], sub[2], sub[3]
        for k = 1, n_vars do
            if sub[3 + k][1] == name then
                -- Shadowed: this group rebinds `name` itself - its subs, sups and body are its
                -- own scope for this name, none of them ours to descend into.
                return
            end
        end
        local idx = 3 + n_vars
        for _ = 1, n_sup do
            idx = idx + 1
            catch_free(ns, sub[idx], name, var)
        end
        for _ = 1, n_sub do
            idx = idx + 1
            catch_free(ns, sub[idx], name, var)
        end
        catch_free(ns, sub[idx + 1], name, var) -- body
        return
    end
    for i = 1, #sub do
        catch_free(ns, sub[i], name, var)
    end
end

--[[ A big operator over `name` in INT's own shape, (var, sup, sub, body) - SUP FIRST, in every big
operator, because it is drawn above and a listing that puts the sub first inverts what is on
screen. Absent bounds are filled with a NULL here rather than left to the caller, so no INT can
exist with a hole in it. No checks: ast.new_int is the only route in, and it checks.
@date 2026-09-10 07:40 ]]
local function new_bigop(ns, node_type, name, sup, sub, body)
    local ret = ast.new(ns, node_type)
    ret[1] = ast.new_var(ns, name)
    --[[ FILLED HERE rather than by the caller, so no INT can exist with a hole in it whoever built
    it - see ast.NULL for what a hole did. An indefinite integral is an ordinary integral with
    nothing where its bounds go, not a different node. ]]
    ret[2] = sup or ast.new_null(ns)
    ret[3] = sub or ast.new_null(ns)
    ret[4] = body
    catch_free(ns, body, name, ret[1])
    return ret
end

--[[ @brief An integral over `name`: it DECLARES that variable and binds the body's free uses of it.
-- |
-- |     ast.new_int(ns, "x", one, zero, body)      -- body's free `x` now means this integral's `x`
-- |
-- | THE NAME COMES IN, NOT THE VARIABLE: the operator makes its own VAR, so no integral's slot 1
-- | can belong to somebody else. Author, 2026-09-10: "bigop ops need to create a var, probably
-- | reuse new_var, the idea is that in this way we will achieve our binding".
-- |
-- | THE BODY IS BUILT FIRST, which the integral requires: `\int_0^1 x dx` declares `x` AFTER the
-- | body. Build the body with `x` free, then say who binds it - the catch repoints those
-- | references.
-- |
-- | @details The only big operator still in the old shape, (var, sup, sub, body): its variable is
-- |          written after the body, so its limits were never constraints to generalise. Sup comes
-- |          before sub, as in every big operator.
-- |
-- | @param ns    ast.ns - checked
-- | @param name  string - the variable's name, e.g. "x"
-- | @param sup   node | nil - checked when given; the upper limit, NULL when absent
-- | @param sub   node | nil - checked when given; the lower limit, NULL when absent
-- | @param body  node - checked; the integrand
-- | @return node - an INT node
-- |
-- | @date 2026-09-13 21:30
--]]
function ast.new_int(ns, name, sup, sub, body)
    NS_SHAPE.check(ns)
    assert(type(name) == "string", "a big operator's variable must be a name")
    --[[ `sup` and `sub` are OPTIONAL - an indefinite integral has nothing where its bounds go, and
    new_bigop fills the hole with a NULL rather than demanding one. `body` is not optional. ]]
    if sup ~= nil then NODE_SHAPE.check(sup, "sup") end
    if sub ~= nil then NODE_SHAPE.check(sub, "sub") end
    NODE_SHAPE.check(body, "body")
    return new_bigop(ns, ast.INT, name, sup, sub, body)
end

--[[ The GROUP shape: binds N names at once - `vars` is a list of NAME strings (the operator makes
its own VAR for each), `sups`/`subs` are already-built constraint nodes, and catching runs over
every tree for every name, since a later constraint may use an earlier one's variable
(`\sum_{i=0,j=i+1}`). No checks here: both routes in (ast.new_group_bigop, the generated family
below) check first.
@date 2026-09-10 ]]
local function new_bigop_group(ns, node_type, vars, sups, subs, body)
    local ret = ast.new(ns, node_type)
    ret[1] = #vars
    ret[2] = #sups
    ret[3] = #subs

    local var_nodes = {}
    for k, name in ipairs(vars) do
        var_nodes[k] = ast.new_var(ns, name)
        ret[3 + k] = var_nodes[k]
    end

    local idx = 3 + #vars
    for _, s in ipairs(sups) do
        idx = idx + 1
        ret[idx] = s
    end
    for _, s in ipairs(subs) do
        idx = idx + 1
        ret[idx] = s
    end
    ret[idx + 1] = body

    for k, name in ipairs(vars) do
        for _, s in ipairs(sups) do
            catch_free(ns, s, name, var_nodes[k])
        end
        for _, s in ipairs(subs) do
            catch_free(ns, s, name, var_nodes[k])
        end
        catch_free(ns, body, name, var_nodes[k])
    end

    return ret
end

--[[ @brief Any GROUP big operator - sum, product, lim and the rest - chosen by TYPE.
-- |
-- |     (op, n_vars, n_sup, n_sub, var1..varN, sup1..supM, sub1..subK, body)
-- |
-- | BY TYPE, because that is what a reader of a row has in hand; the generated new_sum, new_lim and
-- | the rest are for callers that know which operator they mean.
-- |
-- | N NAMES BOUND AT ONCE, and every one is caught across each sup, each sub and the body - a later
-- | constraint may use an earlier one's variable, as in `\sum_{i=0,j=i+1}`.
-- |
-- | @param ns         ast.ns - checked
-- | @param node_type  ast type - must be a group operator
-- | @param vars       {string} - NAMES, each checked; the operator makes its own VAR for each
-- | @param sups       {node} - each checked; already-built constraints, e.g. `n` or `i < n`
-- | @param subs       {node} - each checked; the side that spawns the variables, `i = 1`
-- | @param body       node - checked
-- | @return node
-- |
-- | @date 2026-09-13 21:30
--]]
function ast.new_group_bigop(ns, node_type, vars, sups, subs, body)
    NS_SHAPE.check(ns)
    assert(GROUP_BIGOPS[node_type], "not a group big operator")
    --[[ `vars` is a list of NAMES, not nodes - new_bigop_group calls new_var on each. The two
    limit lists and the body are nodes. ]]
    assert(type(vars) == "table" and type(sups) == "table" and type(subs) == "table",
            "a group big operator needs its three lists")
    for k, name in ipairs(vars) do
        assert(type(name) == "string", "variable " .. k .. " of a big operator must be a name")
    end
    for k, node in ipairs(sups) do
        NODE_SHAPE.check(node, "sup " .. k)
    end
    for k, node in ipairs(subs) do
        NODE_SHAPE.check(node, "sub " .. k)
    end
    NODE_SHAPE.check(body, "body")
    return new_bigop_group(ns, node_type, vars, sups, subs, body)
end

--[[ ast.new_sum, ast.new_prod, ast.new_lim, ast.new_argmax ... - one per row of
GROUP_BIGOP_SYMBOL, all identical but for the type they pass. `pairs` order is irrelevant here,
unlike the read_constraints walk that was bitten by it: no two rows touch the same key. ]]
for name in pairs(GROUP_BIGOP_SYMBOL) do
    local node_type = ast[name]
    ast["new_" .. name:lower()] = function(ns, vars, sups, subs, body)
        --[[ THE SAME PREAMBLE new_group_bigop above carries, and written out again rather than
        factored into a local: the check belongs to the API function, and this loop body IS the API
        function - it is one text that becomes ast.new_sum, ast.new_prod, ast.new_lim and the rest.
        There is no `function ast.new_sum(...)` line anywhere to put it on instead, which is why
        the family had no checks at all until 2026-09-12. ]]
        NS_SHAPE.check(ns)
        --[[ `vars` is a list of NAMES, not nodes - new_bigop_group calls new_var on each. The two
        limit lists and the body are nodes. ]]
        assert(type(vars) == "table" and type(sups) == "table" and type(subs) == "table",
                "a group big operator needs its three lists")
        for k, name in ipairs(vars) do
            assert(type(name) == "string", "variable " .. k .. " of a big operator must be a name")
        end
        for k, node in ipairs(sups) do
            NODE_SHAPE.check(node, "sup " .. k)
        end
        for k, node in ipairs(subs) do
            NODE_SHAPE.check(node, "sub " .. k)
        end
        NODE_SHAPE.check(body, "body")
        return new_bigop_group(ns, node_type, vars, sups, subs, body)
    end
end

--[[ @brief `base^exponent`.
-- |
-- | @param ns        ast.ns - checked
-- | @param base      node - checked
-- | @param exponent  node - checked; a root arrives here as a power of 1/n
-- | @return node - an EXP node
-- |
-- | @date 2026-09-13 21:30
--]]
function ast.new_exp(ns, base, exponent)
    NS_SHAPE.check(ns)
    NODE_SHAPE.check(base, "base")
    NODE_SHAPE.check(exponent, "exponent")
    local ret = ast.new(ns, ast.EXP)
    ret[1] = base
    ret[2] = exponent
    return ret
end

--[[ @brief What a NUM node IS, as text - the reading its three slots stand for.
-- |
-- |     (N, 3, 4, -1)   ->  -3/4
-- |     (N, 7, 1, 1)    ->  7
-- |     (N, 1, 0, 1)    ->  inf
-- |
-- | INFINITY IS A DENOMINATOR OF ZERO. Author, 2026-09-11: "infty should also parse, it's a number
-- | like any other, give it a specific value in over 0 in denominator". It needs no node type of
-- | its own, and the SIGN gives it a direction for free.
-- |
-- | ONE READING FOR BOTH DEBUG VIEWS, which is why it lives here: F4 and F5 cannot disagree about
-- | what a number says.
-- |
-- | @param node  node - checked; a NUM
-- | @return string
-- |
-- | @note `m/0` for any other m is NOT glossed as infinity: nothing builds one, and reading `0/0`
-- |       as "inf" would invent an answer. It prints the raw pair.
-- |
-- | @date 2026-09-13 21:30
--]]
function ast.num_text(node)
    NODE_SHAPE.check(node, "node")
    local m, n, sign = node[1], node[2], node[3]
    local s = ((sign or 1) < 0) and "-" or ""
    if n == 0 then
        return (m == 1) and (s .. "inf") or (s .. tostring(m) .. "/0")
    end
    if n == 1 then
        return s .. tostring(m)
    end
    return s .. tostring(m) .. "/" .. tostring(n)
end

--[[ @brief A RATIONAL number, (N, m, n, sign): numerator, denominator and sign kept apart.
-- |
-- | NOT A FLOAT: a third is a third rather than 0.333..., and two expressions that should be equal
-- | still are after arithmetic. The sign lives on the number rather than in a wrapper, which is why
-- | a `-` glyph in a row names the NUM it belongs to.
-- |
-- | @details Not reduced. Negative m or n are normalised into `sign`, so m and n come out
-- |          non-negative. n = 0 is infinity (see num_text).
-- |
-- | @param ns    ast.ns - checked
-- | @param m     integer - asserted, not coerced: a float here is a bug upstream
-- | @param n     integer | nil - asserted; defaults to 1
-- | @param sign  1 | -1 | nil - defaults to 1
-- | @return node - a NUM node
-- |
-- | @date 2026-09-13 21:30
--]]
function ast.new_num(ns, m, n, sign)
    NS_SHAPE.check(ns)
    n = n or 1
    sign = sign or 1
    assert(type(m) == "number" and m == math.floor(m), "m must be an integer")
    assert(type(n) == "number" and n == math.floor(n), "n must be an integer")
    assert(sign == 1 or sign == -1, "sign must be 1 or -1")
    
    -- Two independent flips: a negative m or n is moved into `sign`, so m and n come out
    -- non-negative - and both negative flips the sign twice, i.e. not at all.
    if m < 0 then
        m, sign = -m, -sign
    end
    if n < 0 then
        n, sign = -n, -sign
    end

    local ret = ast.new(ns, ast.NUM)
    ret[1] = m
    ret[2] = n
    ret[3] = sign
    return ret
end

--[[ @brief Applying `fn` to arguments, (@, fn, a1, a2, ...).
-- |
-- | THE FUNCTION IS CHILD 1, not a name held beside the node, so what is applied can itself be an
-- | expression.
-- |
-- | @param ns   ast.ns - checked
-- | @param fn   node | string - NOT checked: a call to a name declared in another box carries that
-- |             declaration's KEY, since the declaration lives in a different namespace
-- | @param ...  node - every argument checked
-- | @return node - a CALL node
-- |
-- | @date 2026-09-13 21:30
--]]
function ast.new_call(ns, fn, ...)
    NS_SHAPE.check(ns)
    --[[ `fn` IS NOT CHECKED, and that is not an omission: it may be a node OR a STRING. A call to a
    name declared in another box carries the declaration's KEY, because the declaration lives in a
    different namespace and the key is what identifies it across the two (mexpr_ast's read_pattern
    says the same at its call site). Checking it for a node broke three tests the moment it was
    added. The arguments below have no such exemption. ]]
    for i = 1, select("#", ...) do
        NODE_SHAPE.check((select(i, ...)), "argument " .. i)
    end
    local ret = ast.new(ns, ast.CALL)
    ret[1] = fn
    for i, arg in ipairs({...}) do
        ret[i+1] = arg
    end
    return ret
end

--[[ @brief The absent operand - an indefinite integral's missing limit. See ast.NULL.
-- |
-- | @param ns  ast.ns - checked
-- | @return node - a NULL node, carrying nothing but its own id
-- |
-- | @date 2026-09-13 21:30
--]]
function ast.new_null(ns)
    NS_SHAPE.check(ns)
    return ast.new(ns, ast.NULL)
end

--[[ @brief A VARIABLE, (#, name) - the declaration itself. A USE of it is a VREF; see new_vref.
-- |
-- | @param ns    ast.ns - checked
-- | @param name  string - asserted; the node's entire content. Anything else makes a variable no
-- |              reference can resolve against, failing much later at the use site
-- | @return node - a VAR node
-- |
-- | @date 2026-09-13 21:30
--]]
function ast.new_var(ns, name)
    NS_SHAPE.check(ns)
    --[[ A STRING, and the node's entire content - a VAR is its name. Anything else here makes a
    variable nothing can resolve a reference against, and the failure surfaces much later, at the
    use site, as a name that matches nothing. ]]
    assert(type(name) == "string", "a variable's name must be a string")
    local ret = ast.new(ns, ast.VAR)
    ret[1] = name
    return ret
end

--[[ @brief A matrix of `rows` by `cols`, (M, rows, cols, a1, ...), filled in row-major order.
-- |
-- | FEWER ELEMENTS THAN rows*cols IS ALLOWED - a matrix being typed is a real state - but MORE is
-- | refused, since that can only mean the caller and the shape disagree.
-- |
-- | @param ns    ast.ns - checked
-- | @param rows  integer - asserted positive
-- | @param cols  integer - asserted positive
-- | @param ...   node - every element checked
-- | @return node - a MAT node
-- | @throws for more than rows*cols elements
-- |
-- | @date 2026-09-13 21:30
--]]
function ast.new_mat(ns, rows, cols, ...)
    NS_SHAPE.check(ns)
    --[[ THE SHAPE FIRST, because everything below is derived from it: a non-integer `rows` makes
    `expected_max` a float and the element bound meaningless, and a zero or negative one makes a
    matrix with no positions to put an element in. ]]
    assert(type(rows) == "number" and rows == math.floor(rows) and rows > 0,
            "a matrix needs a positive whole number of rows")
    assert(type(cols) == "number" and cols == math.floor(cols) and cols > 0,
            "a matrix needs a positive whole number of columns")
    for i = 1, select("#", ...) do
        NODE_SHAPE.check((select(i, ...)), "element " .. i)
    end

    local elements = {...}
    local expected_max = rows * cols
    --[[ FEWER than rows*cols is allowed - a matrix being typed is a real state - but more can only
    mean the caller and the shape disagree.

    The message used to pass four arguments for three placeholders, so it read "rows*cols=<rows>
    allows max <cols>": both numbers wrong, and the one that mattered never shown. Fixed
    2026-09-12. ]]
    assert(#elements <= expected_max,
            string.format("matrix has %d elements but %dx%d allows at most %d",
                    #elements, rows, cols, expected_max))
    local ret = ast.new(ns, ast.MAT)
    ret[1] = rows
    ret[2] = cols
    for i, expr in ipairs(elements) do
        ret[i+2] = expr
    end
    return ret
end

--[[ @brief Brackets the user wrote where precedence did not need them, (_, expr).
-- |
-- | KEPT BECAUSE THEY CARRY THE USER'S OWN GROUPING. Brackets precedence requires are absorbed into
-- | the tree's shape instead - `a(b+c)` is MUL(a, ADD) with no CELL - so a CELL is always redundant
-- | brackets, and transformations can arrange by them. mexpr_ast's maybe_cell decides which.
-- |
-- | @param ns    ast.ns - checked
-- | @param expr  node - checked; what the brackets hold
-- | @return node - a CELL node
-- |
-- | @date 2026-09-13 21:30
--]]
function ast.new_cell(ns, expr)
    NS_SHAPE.check(ns)
    NODE_SHAPE.check(expr, "expr")
    local ret = ast.new(ns, ast.CELL)
    ret[1] = expr
    return ret
end

--[[ @brief A USE of a variable, (&, var id).
-- |
-- | THE REFERENCE IS THE WHOLE NODE: it names a VAR and carries nothing else, so two uses of one
-- | variable are two nodes pointing at one declaration, not two variables that share a name. That
-- | is what makes duplicating a factor cheap - see copy_fresh.
-- |
-- | @param ns   ast.ns - checked
-- | @param ref  id | node - the id itself, or a node to take `id` from. A node is NOT checked to be
-- |             a VAR
-- | @return node - a VREF node
-- | @throws when `ref` is neither a number nor a table with an id
-- |
-- | @date 2026-09-13 21:30
--]]
function ast.new_vref(ns, ref)
    NS_SHAPE.check(ns)
    local ref_id
    if type(ref) == "number" then
        ref_id = ref
    elseif type(ref) == "table" and ref.id then
        ref_id = ref.id
    else
        error("ref must be a number (id) or an AST node with an id")
    end
    local ret = ast.new(ns, ast.VREF)
    ret[1] = ref_id
    return ret
end

-- #################################################################################################
-- Serialization/Deserialization
-- #################################################################################################

-- Serialization: AST node -> string
local type_to_symbol = {
    [ast.EQ] = "=",
    [ast.INEQ_LESS] = "<",
    [ast.INEQ_LEQ] = "<=",
    [ast.INEQ_NEQ] = "!=",
    [ast.INEQ_GREATER] = ">",
    [ast.INEQ_GEQ] = ">=",
    [ast.ADD] = "+",
    [ast.MUL] = "*",
    [ast.DIV] = "/",
    [ast.EXP] = "^",
    [ast.NUM] = "N",
    [ast.CALL] = "@",
    [ast.VAR] = "#",
    [ast.VEC] = "V",
    [ast.MAT] = "M",
    [ast.CELL] = "_",
    [ast.VREF] = "&",
    [ast.INT] = "I",
    [ast.IN] = "in",
    [ast.NI] = "ni",
    [ast.SUBSET] = "subset",
    [ast.SUBSETEQ] = "subeq",
    [ast.SUPSET] = "supset",
    [ast.SUPSETEQ] = "supeq",
    [ast.NULL] = "null",
    [ast.TENDS] = "to",
    [ast.IMPLIES] = "=>",
    [ast.IFF] = "<=>",
}

--[[ The group operators' symbols come from the one table that defines them - see
GROUP_BIGOP_SYMBOL. Written in here rather than listed twice. ]]
for name, symbol in pairs(GROUP_BIGOP_SYMBOL) do
    type_to_symbol[ast[name]] = symbol
end

--[[ @brief A node as one line of text, ids included: `(+, (&, 2:3), (N, 1, 1, 1:4):5)`.
-- |
-- | FOR READING, AND FOR from_string: the two are a pair, so what this writes must parse back. Ids
-- | are part of it, which is exactly why it cannot answer "are these the same expression" across
-- | namespaces - ast.shape is that question.
-- |
-- | @param ns    ast.ns - checked
-- | @param node  node | number | string - a node is checked; a scalar is written as itself, which
-- |        is
-- |              how the recursion reaches a leaf's value
-- | @return string
-- | @throws for anything else, e.g. a boolean
-- |
-- | @date 2026-09-13 21:30
--]]
function ast.to_string(ns, node)
    NS_SHAPE.check(ns)
    --[[ A VALUE **OR** A NODE. Numbers and strings are not errors here: they are the base case, and
    they arrive through the recursion below, because a leaf's array part holds its value rather than
    child nodes. What a TABLE may be is exactly one thing, and saying so here is what stops some
    other sealed container - a container, a state - being walked as if it were a tree. ]]
    if type(node) == "table" then
        NODE_SHAPE.check(node, "node")
    end
    if type(node) == "number" then
        return tostring(node)
    elseif type(node) == "string" then
        return node
    elseif type(node) == "table" then
        local symbol = type_to_symbol[node.type] or "?"
        local parts = {"(" .. symbol}
        for i = 1, #node do
            table.insert(parts, ", " .. ast.to_string(ns, node[i]))
        end
        return table.concat(parts) .. ":" .. tostring(node.id) .. ")"
    else
        error("Cannot serialize: " .. type(node))
    end
end


--[[ @brief The same serialization as to_string, one NODE per line with its depth - the F5 view.
-- |
-- |     (=:9)
-- |       (@, F(),(1):5)
-- |         (N, 0, 1, 1:4)  1
-- |       (&, 2:7)  x
-- |
-- | EACH LINE IS WHAT to_string WOULD WRITE for that node with its child NODES lifted out: head,
-- | scalar operands, id. It lives here, beside to_string, because the two must agree - a change to
-- | the tuple shape is made in both or in neither.
-- |
-- | EVERY LINE COMES BACK AS PIECES WITH ROLES, which the F5 overlay paints: "op_sym" an operator's
-- | symbol, "bind_sym" the # of a declaration and the & of a reference, "var_name" a declared name,
-- | "ref_name" the name a reference resolves to, "num_value" what a number cell reads as. Blue and
-- | green name VARIABLES, red is an OPERATION on them - naming told from arithmetic at a glance.
-- |
-- | @details A reference's name and a number's reading are appended after the tuple as a gloss; the
-- |          tuple stays authoritative.
-- |
-- | @param ns     ast.ns - checked
-- | @param node   node | value - a node is checked; a scalar is its own one-line leaf
-- | @param depth  integer | nil - this node's depth; 0 when nil
-- | @param out    {line} | nil - appended to; a fresh list when nil
-- | @return {{depth, text, parts}, ...} - `out`, in pre-order; `parts` are {text, role} pieces that
-- |         concatenate to `text`
-- |
-- | @note Colours asked for 2026-09-11: "var creations are going to have the # blue and the k
-- |       inside also colored in green", "I want ^, +, *, those things in red", "and & should also
-- |       be blue", "also in yellow write the number next to the number cell".
-- |
-- | @date 2026-09-13 21:30
--]]
function ast.to_string_lines(ns, node, depth, out)
    NS_SHAPE.check(ns)
    -- A value or a node; see ast.to_string for why a scalar here is the base case, not an error.
    if type(node) == "table" then
        NODE_SHAPE.check(node, "node")
    end
    out = out or {}
    depth = depth or 0

    if not ast.is_node(node) then
        local text = tostring(node)
        out[#out + 1] = {depth = depth, text = text, parts = {{text = text}}}
        return out
    end

    local is_var, is_ref = node.type == ast.VAR, node.type == ast.VREF
    local parts, kids = {}, {}
    local function put(text, role)
        parts[#parts + 1] = {text = text, role = role}
    end

    put("(")
    --[[ The two BINDING nodes share a colour because they are two halves of one thing: `#` makes a
    variable and `&` names one. Every other symbol is an operation and takes the operator colour. ]]
    put(type_to_symbol[node.type] or "?", (is_var or is_ref) and "bind_sym" or "op_sym")
    for i = 1, #node do
        local v = node[i]
        if type(v) == "table" and v.type then
            kids[#kids + 1] = v
        else
            put(", ")
            --[[ A VAR's single operand IS the name it declares - see ast.new_var. Nothing else
            here carries a name, so the role is decided by the node, not by the slot. ]]
            put(tostring(v), is_var and "var_name" or nil)
        end
    end
    -- Left unpainted, but still written on every node: the line has to stay byte-identical to
    -- what to_string produces.
    put(":" .. tostring(node.id))
    put(")")

    if is_ref then
        local target = ast.node_of(ns, node[1])
        if target and target[1] then
            put("  " .. tostring(target[1]), "ref_name")
        end
    elseif node.type == ast.NUM then
        -- (N, numerator, denominator, sign) read back as the number it is - see ast.num_text,
        -- which F4 uses too so the two views cannot gloss one tuple two ways.
        put("  " .. ast.num_text(node), "num_value")
    end

    local text = {}
    for _, piece in ipairs(parts) do
        text[#text + 1] = piece.text
    end
    out[#out + 1] = {depth = depth, text = table.concat(text), parts = parts}
    for _, kid in ipairs(kids) do
        ast.to_string_lines(ns, kid, depth + 1, out)
    end
    return out
end

-- Deserialization: string -> AST node
--[[ A node type's own NAME, for anything that shows a type to a person - F4's labels are exactly
this. Built by reversing the constants out of `ast` itself, so there is no second vocabulary that
could disagree with the one every branch tests against.
@date 2026-09-11 10:20 ]]
local type_name = {}
for key, value in pairs(ast) do
    if type(value) == "number" then
        type_name[value] = key
    end
end

--[[ @brief The readable name of a node type - "ADD" - or nil for an unknown one.
-- |
-- | @details Built by reversing the constants out of `ast` itself, so there is no second
-- |          vocabulary.
-- |
-- | @param node_type  ast type - a number
-- | @return string | nil
-- |
-- | @date 2026-09-13 21:30
--]]
function ast.type_name(node_type)
    return type_name[node_type]
end

--[[ @brief A canonical, ID-FREE rendering of a tree, for comparing one tree against another.
-- |
-- | IDS CANNOT BE IN IT. The comparison wanted is between a tree and a tree BUILT FROM IT - a
-- | transformation's output against what its rebuilt mexpr parses back to - which live in different
-- | namespaces, where ids cannot match by construction.
-- |
-- | A VREF RENDERS AS ITS VARIABLE'S NAME, which is why `ns` is a parameter: two namespaces agree
-- | about names exactly where they cannot agree about ids (docs/phase2_design.md section 9).
-- |
-- | @param ns    ast.ns - checked; the namespace `node`'s references resolve in
-- | @param node  node | value - a node is checked
-- | @return string - a comparison key, never read back. A reference nothing in `ns` answers to
-- |         falls back to its raw id
-- |
-- | @date 2026-09-13 21:30
--]]
function ast.shape(ns, node)
    NS_SHAPE.check(ns)
    -- A value or a node; see ast.to_string for why a scalar here is the base case, not an error.
    if type(node) == "table" then
        NODE_SHAPE.check(node, "node")
    end
    if not ast.is_node(node) then
        return tostring(node)
    end
    if node.type == ast.VREF then
        --[[ `ns and ns.by_id and` is gone: the preamble already guarantees both, and a guard that
        can no longer fire only hides the day one of them really is missing.

        WHAT COMES BACK IS INDEXED AS A NODE, so it is checked as one. A by_id entry that was not a
        node would read as a name here and quietly produce a wrong shape - and shape's entire job
        is to answer "are these two the same expression", so a wrong answer is the worst kind. ]]
        local var = ast.node_of(ns, node[1])
        if var then
            return "ref:" .. tostring(var[1])
        end
        --[[ An UNRESOLVED reference falls back to the raw id, which is a real state: a tree built
        against one namespace and shaped against another has references nothing here answers to. ]]
        return "ref:" .. tostring(node[1])
    end
    if node.type == ast.VAR then
        return "var:" .. tostring(node[1])
    end
    if node.type == ast.NUM then
        return "num:" .. ast.num_text(node)
    end
    local parts = {}
    for i = 1, #node do
        parts[i] = ast.shape(ns, node[i])
    end
    return (ast.type_name(node.type) or ("type" .. tostring(node.type)))
            .. "(" .. table.concat(parts, ",") .. ")"
end

--[[ The exact inverse of type_to_symbol, DERIVED rather than written.

It was a second literal listing all 29 pairs by hand, which is a serialization that can silently
stop round-tripping: a type whose two entries disagree writes one symbol and reads back as another,
or as nothing. They happened to agree; nothing made them.
@date 2026-09-11 10:20 ]]
local symbol_to_type = {}
for node_type, symbol in pairs(type_to_symbol) do
    assert(symbol_to_type[symbol] == nil, "two node types share the symbol " .. tostring(symbol))
    symbol_to_type[symbol] = node_type
end

-- Helper: split tuple arguments respecting nested parentheses
local function split_args(s)
    local args = {}
    local depth = 0
    local start = 1
    for i = 1, #s do
        local c = s:sub(i, i)
        if c == "(" then
            depth = depth + 1
        elseif c == ")" then
            depth = depth - 1
        elseif c == "," and depth == 0 then
            table.insert(args, s:sub(start, i - 1))
            start = i + 1
        end
    end
    -- Add last argument
    if start <= #s then
        table.insert(args, s:sub(start))
    end
    return args
end

--[[ @brief The inverse of to_string: text back into a tree in `ns`, under the ids it names.
-- |
-- | THE IDS IN THE TEXT ARE KEPT, because they are what its references point at. A tuple without an
-- | id takes a fresh one.
-- |
-- | @details Whitespace is stripped first, so the format is positional, not layout-sensitive. A
-- |          node with no operands, `(null:5)`, reads back.
-- |
-- | @param ns  ast.ns - checked; must not already hold the ids the text names
-- | @param s   string
-- | @return node | number | string | nil - a tree for a tuple; a bare number or word as itself; nil
-- |         only for empty text
-- | @throws for text it cannot read - an unknown symbol, unbalanced brackets - and for an id
-- |         already taken in `ns`
-- |
-- | @date 2026-09-13 21:30
--]]
function ast.from_string(ns, s)
    NS_SHAPE.check(ns)
    -- Remove all whitespace for simpler parsing
    s = s:gsub("%s+", "")
    
    -- Empty string
    if s == "" then
        return nil
    end
    
    -- Bare number
    local num = tonumber(s)
    if num then
        return num
    end
    
    -- Bare string/identifier (not a tuple)
    if s:sub(1, 1) ~= "(" then
        return s
    end
    
    -- Parse tuple: (type, arg1, arg2, ...:id). The leading "(" is guaranteed by the bare-string
    -- return above; only the trailing ")" still needs asserting.
    assert(s:sub(-1) == ")", "Expected ')' at end of tuple: " .. s)
    
    -- Extract content between parentheses
    local inner = s:sub(2, -2)
    
    -- Check for id suffix: ...:id
    local node_id = nil
    local colon_pos = inner:find(":%d+$")
    if colon_pos then
        -- Extract the id part
        local id_str = inner:sub(colon_pos + 1)
        node_id = tonumber(id_str)
        inner = inner:sub(1, colon_pos - 1)
    end
    
    -- Find the type symbol (everything before first comma)
    --[[ Or the WHOLE of what is left, when a node has no operands at all. `(null:5)` is the case
    that made this legal: ast.NULL is a leaf, so there is nothing after its symbol and nothing to
    separate with a comma. Before this, reading one back raised "Missing comma in tuple", which
    meant an indefinite integral could be written and never read - and to_string/from_string are
    meant to be inverses. @date 2026-09-11 06:30 ]]
    local first_comma = inner:find(",")
    
    local type_str = first_comma and inner:sub(1, first_comma - 1) or inner
    local args_str = first_comma and inner:sub(first_comma + 1) or ""
    
    -- Look up the type
    local node_type = symbol_to_type[type_str]
    if not node_type then
        error("Unknown type symbol: '" .. type_str .. "' in: " .. s)
    end
    
    -- Split arguments
    local arg_strs = split_args(args_str)
    local args = {}
    for _, arg_str in ipairs(arg_strs) do
        if arg_str ~= "" then  -- Skip empty
            table.insert(args, ast.from_string(ns, arg_str))
        end
    end
    
    --[[ The serialized id goes IN, rather than being corrected on afterwards - see ast.new.
    The old shape registered the node under a freshly allocated id first, which made every tree
    of more than one node unreadable and left a phantom entry behind when it did not. ]]
    local ret = ast.new(ns, node_type, node_id)
    for i, arg in ipairs(args) do
        ret[i] = arg
    end

    return ret
end

return ast

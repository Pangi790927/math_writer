--[[ ==================================== WHAT THIS FILE OFFERS ====================================

NAMESPACES AND NODES
new_ns()                                -> ns
node_of(ns: ast.ns, id: id)             -> node | nil
    THE ONLY WAY TO READ A NAMESPACE - `by_id` is the storage, this is
    the lookup, and it CHECKS what it found. A miss is nil; an entry
    that is not a node raises.
check_ns(ns: ast.ns)                    -> ns
check_node(node: node, what: string)    -> node
    Assert a namespace or a node, for a function in another file that
    takes one - the shapes are declared here and are local to here.
ns_insert_object(ns: ast.ns, id: id, obj: node) -> id
new(ns: ast.ns, type: ast type, id: id)           -> node
    A namespace owns ids; every node is minted into one and answers to
    `ns.by_id[id]`. The id IS the name (phase2 section 10), so two
    nodes may never share one.

copy(ns: ast.ns, node: node, new_ns: ast.ns, keep_vars: boolean) -> node
copy_fresh(ns: ast.ns, node: node)      -> node
    The same tree somewhere else, versus a second tree that looks the
    same. copy_fresh mints new ids in the SAME namespace - what a
    transformation needs when a subtree lands in two places.
ns_import_ast(dst_ns: ast.ns, src_ns: ast.ns, node: node) -> NOT IMPLEMENTED
    A stub with an empty body since it was written. It RAISES; it does
    not return a node. See the TODO on it for what is undecided.

parent_map(root: node)                  -> {child id -> parent node}
    Computed per call and thrown away; never stored on a node, because
    a tree is shared and two trees would disagree about the parent.

RELATIONS
new_eq(ns: ast.ns, expr1: node, expr2: node) -> node
new_ineq_less(ns: ast.ns, expr1: node, expr2: node) -> node
new_ineq_leq(ns: ast.ns, expr1: node, expr2: node) -> node
new_ineq_neq(ns: ast.ns, expr1: node, expr2: node) -> node
new_ineq_greater(ns: ast.ns, expr1: node, expr2: node) -> node
new_ineq_geq(ns: ast.ns, expr1: node, expr2: node) -> node
new_tends(ns: ast.ns, expr1: node, expr2: node) -> node
new_implies(ns: ast.ns, expr1: node, expr2: node) -> node
new_iff(ns: ast.ns, expr1: node, expr2: node) -> node
    Each is two operands and nothing else. Both are CHECKED to be nodes.

SET RELATIONS
new_in(ns: ast.ns, expr1: node, expr2: node) -> node
new_ni(ns: ast.ns, expr1: node, expr2: node) -> node
new_subset(ns: ast.ns, expr1: node, expr2: node) -> node
new_subseteq(ns: ast.ns, expr1: node, expr2: node) -> node
new_supset(ns: ast.ns, expr1: node, expr2: node) -> node
new_supseteq(ns: ast.ns, expr1: node, expr2: node) -> node
    The same shape; membership and containment, both directions.

ARITHMETIC
new_add(ns: ast.ns, ...: node)          -> node
new_mul(ns: ast.ns, ...: node)          -> node
    N-ary and order-preserving: `a+b+c` is ONE node with three
    children, and multiplication is not assumed commutative. EVERY
    operand is checked, which is where a stray nil would otherwise go
    unnoticed - nothing downstream reads the arity back.
new_div(ns: ast.ns, expr1: node, expr2: node)   -> node
new_exp(ns: ast.ns, base: node, exponent: node) -> node
new_int(ns: ast.ns, name: string, sup: node, sub: node, body: node) -> node
new_group_bigop(ns: ast.ns, node_type: ast type, vars: {name}, sups: {node}, subs: {node},
                body: node)             -> node
    The explicit form. `vars` is a list of NAMES, not nodes.

new_sum / new_prod / new_union / new_intersect / new_lim / new_limsup / new_liminf / new_min /
new_max / new_sup / new_inf / new_argmin / new_argmax
    (ns: ast.ns, vars: {name}, sups: {node}, subs: {node}, body: node) -> node
    GENERATED, one per row of GROUP_BIGOP_SYMBOL, in a loop rather than
    typed out - so there is no `function ast.new_sum(...)` line
    anywhere. They are otherwise identical to new_group_bigop with the
    type already chosen, and each carries the same argument checks.

LEAVES AND STRUCTURE
new_num(ns: ast.ns, m: number, n: number, sign: number) -> node
    A RATIONAL, not a float: numerator, denominator and sign kept
    apart, so a third stays a third. The sign lives on the number.
num_text(node: node)                    -> text
new_var(ns: ast.ns, name: string)       -> node   the declaration
new_vref(ns: ast.ns, ref: node)         -> node   a USE of one
new_call(ns: ast.ns, fn: node | key, ...: node)  -> node
    `fn` may be a STRING - a declaration's key, when it lives in
    another box's namespace. The arguments must be nodes.
new_vec(ns: ast.ns, ...: node)                  -> node
new_cell(ns: ast.ns, expr: node)                -> node
new_mat(ns: ast.ns, rows: number, cols: number, ...: node) -> node
new_null(ns: ast.ns)                            -> node

TEXT
to_string(ns: ast.ns, node: node)       -> text
to_string_lines(ns: ast.ns, node: node, depth: number, out: {string}) -> {text, ...}
from_string(ns: ast.ns, s: string)      -> node | nil
    A pair: what to_string writes, from_string reads back. Ids are in
    it, so it cannot compare two trees across namespaces.
shape(ns: ast.ns, node: node)           -> text
    THE COMPARISON KEY, id-free, for asking whether two trees in
    different namespaces are the same expression.
type_name(node_type: ast type)          -> text | nil

--- internal ---------------------------------------------------------------------------------------
    new_ns()       THE ONE creator for a namespace - see it for the `ns` shape
    new()          THE ONE creator for a node - see it for the `node` shape
    new_bigop, and the type/symbol tables
@date 2026-09-12 03:05
================================================================================================= ]]

--[[
ast.lua - THE MEANING TREE: what a formula IS, as opposed to how it is drawn or typed.

Every mathematical element in the program has a node shape here, and this is the base that
serialization, deserialization and the transforms are all written against. The editors do not build
these yet - phase 1 keeps a formula as mexpr plus LaTeX - so this is the model phase 2 grows into
(docs/phase2_design.md), and transforms.lua is the first thing written against it.

A node is a TUPLE: an operator, then its operands, each node carrying an id of its own so anything
else can refer to it. The catalogue of tuple shapes is written out below.

WHAT IS NOT HERE, since docs/phase2_design.md still describes it: an ast -> LaTeX writer sat at the
bottom of this file until 2026-09-09. Nothing outside its own recursion had ever called it, and
mexpr.lua - the only consumer of anything in this file besides main.lua's dead demo - was deleted
the same day. The LaTeX the app really reads and writes is mformula_latex.lua's, and it works on
the mexpr tree, not on these nodes.

@date 2026-09-09 21:20
]]
--[[ OBS: function names can't have spaces ]]

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
    --[[ NOTHING IN THIS SLOT, on purpose. An indefinite integral has no bounds, and `INT` keeps its
    fixed four-slot shape (var, from, to, body) rather than growing a count the way the group
    operators did - so "no bound" needs a node to BE.

    Leaving the slot nil instead is what this replaced, and it was silently wrong: Lua's `#` stops
    at the first hole, so `#node` answered 1 for `\int x dx` and every generic walk over a node's
    children - the namespace copy, to_string, to_string_lines - skipped the body entirely. Binding
    still worked, because catch_free reaches slot 4 by index rather than by walking, which is
    exactly why it went unnoticed. Found 2026-09-11 by the check that pairs two integrals crossways.

    A LEAF WITH NO OPERANDS, so it serializes as `(null:id)` and reads back like any other node.
    Spelled out rather than given a punctuation symbol like the rest: it appeared as `(~:5)` for one
    reading and drew "what is a tilda?" immediately, which is a fair question about a mark nothing
    else in the format uses. Named by the author, 2026-09-11: "plz name them (NULL), like this",
    then "null in paranthesis, like printf on a null string" - which is where the lower case comes
    from, and the tuple's own brackets supply the parentheses.
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
    --[[ LOGICAL IMPLICATION AND EQUIVALENCE - `a \\Rightarrow b`, `a \\Leftrightarrow b`. Binary and
    plain, the same shape as IN and the inequalities, which is all they need to be: nothing here
    evaluates them, and a connective that joins two statements is structurally a relation.

    NOT the same thing as TENDS, which shares an arrow-ish glyph family: `\\rightarrow` is a limit's
    "tends to" and `\\Rightarrow` is "implies". Different glyphs (the catalog has both, ncod 138 and
    146), different nodes, and the digraphs that produce them differ too - `-` then `>` gives the
    first, `=` then `>` the second. @date 2026-09-11 16:00 ]]
    IMPLIES = 41,
    IFF = 42,
}

--[[ A fresh NAMESPACE: the id -> node table every ast node in one tree is registered in, plus the
next id to hand out. Ids are what a reference names, so a node only means anything inside the
namespace it was made in. @date 2026-09-08 09:10 ]]
--[[ THE `ns` CONTAINER's declared fields. Sealed through sealed.lua like every other container
here, on the author's instruction 2026-09-12 - the earlier reasoning for leaving it open ("only
ast.new and ns_insert_object touch it") was the same argument that would have left every one of the
others open, and it is not the rule. Two fields, and nothing may add a third.
@date 2026-09-12 08:00 ]]
local NS_FIELDS = {
    by_id   = "{id -> node}: the STORAGE. Written by ns_insert_object; read through "
              .. "ast.node_of, which checks what it found. Reaching in directly is what let a "
              .. "non-node sit in it unnoticed.",
    last_id = "the next id to hand out, kept PAST anything inserted - including ids read back "
              .. "from a file - so a loaded document can never be handed one it already uses.",
}
local NS_SHAPE = sealed.declare("ast", "ns", NS_FIELDS)

--[[ THE `node` CONTAINER's declared fields - an ast node's whole NAMED surface, which is two
entries.

ARRAY MODE, and that is the shape of the thing: a node's children are POSITIONAL and unbounded -
the operands of an ADD, the base and exponent of an EXP - and a leaf's array part holds its value
instead (NUM is {m, n, sign}, VAR is {name}, VREF is {referenced id}). There is nothing there to
declare, so integer keys pass untouched and only the string ones are policed.

WHAT THIS CATCHES: `node.typ`, `node.parent`, `node.value` - names that read as if a node had them.
It does NOT catch a wrong child count or a child of the wrong type; `type` decides what the array
part means, and only the constructors below set both together.

`parent` and `loc` are NOT declared, deliberately: transforms_old.lua hangs them on nodes, and that
file is frozen and required by nothing. If it is ever revived they belong here, with the rest of
that design.
@date 2026-09-12 08:30 ]]
local NODE_FIELDS = {
    type = "one of the ast.* constants; ast.type_name() reads it back",
    id   = "its name in the namespace, unique and never reused",
}
local NODE_SHAPE = sealed.declare("ast", "node", NODE_FIELDS, {array = true})

--[[ THE `ns` CONTAINER - a namespace, and THE ONE CREATOR for it.

Core: ids are the real names in this model (docs/phase2_design.md section 10), and a namespace is
what hands them out and what resolves them. Every node belongs to exactly one.

Its fields:
    by_id    {id -> node}, the resolution table. `ns.by_id[some_id]` is how a gesture's stored id
             becomes a node again, which is why an option may carry ids instead of a tree.
    last_id  the next id to hand out. Kept PAST anything inserted, including ids read back from a
             file, so a loaded document can never be given an id it is already using.

SEALED, like every other container here. What is INSIDE `by_id` is an ordinary table - the seal
names the namespace's own two fields and says nothing about the ids it holds, which are unbounded by
definition.
@date 2026-09-12 05:10 ]]
function ast.new_ns()
    return NS_SHAPE.wrap{ by_id = {}, last_id = 1 }
end

--[[ Registers `obj` under `id`, keeping the namespace's next id past it - so an id read back from
a file cannot later be handed out a second time. @date 2026-09-08 09:10 ]]
function ast.ns_insert_object(ns, id, obj)
    NS_SHAPE.check(ns)
    NODE_SHAPE.check(obj, "obj")
    ns.by_id[id] = obj
    if ns.last_id <= id then
        ns.last_id = id + 1
    end
end


--[[ The node an id names in `ns`, or nil.

THE ONLY WAY TO READ A NAMESPACE. `by_id` is the storage; this is the lookup, and the difference is
that the lookup CHECKS what it found. Before this existed every caller wrote `ns.by_id[id]` and was
individually responsible for remembering that the result is indexed as a node - and most of them did
not remember, which is how ast.shape came to read `var[1]` off whatever happened to be in the table.
Author, 2026-09-12: "instead of a public array... this way we are sure of what it is".

A MISS IS ORDINARY and comes back nil: an id from another namespace, or from a parse that has since
been thrown away, answers to nothing here. What is NOT ordinary is an entry that is not a node, and
that raises - the table is only ever written by ns_insert_object, so anything else in it means
something wrote past the front door.
@date 2026-09-12 12:15 ]]
function ast.node_of(ns, id)
    NS_SHAPE.check(ns)
    local node = ns.by_id[id]
    if node == nil then
        return nil
    end
    return NODE_SHAPE.check(node, "the node id " .. tostring(id) .. " names")
end

--[[ Asserts that this is a namespace / an ast node, for a function elsewhere that takes one.

Published because both shapes are declared HERE while plenty of callers live in other files, and
NS_SHAPE / NODE_SHAPE are local to this one. Each returns its argument, so it can stand as the first
line of a function. @date 2026-09-12 11:55 ]]
function ast.check_ns(ns)
    return NS_SHAPE.check(ns, "ns")
end

--[[ Asserts an ast node. `what` names the argument in the message, so the error points at the
caller's parameter rather than at this line. @date 2026-09-12 11:55 ]]
function ast.check_node(node, what)
    return NODE_SHAPE.check(node, what or "node")
end

--[[ THE `node` CONTAINER - one ast node, and THE ONE CREATOR for it. Every constructor below goes
through here, which is what makes "has an id" true of every node rather than of most of them.

A node is a table with two named fields and an ARRAY PART:
    type     one of the ast.* constants; ast.type_name() reads it back
    id       its name in `ns`, unique and never reused
    [1..n]   the children, in meaning order - the operands of an ADD, the base and exponent of an
             EXP, the numerator and denominator of a DIV. A leaf's array part holds its VALUE
             instead: NUM is {m, n, sign}, VAR is {name}, VREF is {referenced id}.

THE ARRAY PART IS WHY THIS IS NOT SEALED. A seal names its fields; children are positional and
unbounded, so there is nothing to enumerate. What protects a node instead is that `type` decides
what its array part means, and only the constructors below set both together.

`id` IS OPTIONAL AND IS THE DESERIALIZER'S DOOR. Without it the namespace hands out the next free
id. With it the node takes the id it is given - which a reader needs, because the ids in a saved
tree are what its references point at, and a node that gets a fresh one has lost every reference to
it.

WHY IT IS A PARAMETER RATHER THAN A CORRECTION AFTERWARDS, which is what from_string used to do:
allocating an id, registering it, then overwriting it left the node in `by_id` TWICE, under a
phantom id nobody would ever look up - and made the collision check fire on the node's own
registration. That broke every tree of more than one node, since reading id `n` pushed `last_id` to
`n+1`, the next node allocated `n+1`, and applying ITS id found `n+1` taken. Nothing can go wrong
here that did not go wrong there, because the id is decided before anything is registered.
@date 2026-09-10 07:40 ]]
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

--[[ Create a copy of an ast, populating a namespace with the right references
(namespace presumed empty at the root of the copy call)

* ns - the old namespace
* node - the node to duplicate
* new_ns - the new namespace in which to create the new tree
* keep_vars - this dictates if the vars inside the expression reference the
             same vars as before
@date 2026-09-08 08:55 ]]
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

--[[ A deep copy of `node` with FRESH ids, in the SAME namespace.

THE OTHER HALF OF ast.copy ABOVE, and here rather than in whichever file happened to need it first:
one is "the same tree somewhere else", the other is "a second tree that looks the same". Keeping
them apart is what stops a caller reaching for the wrong one, and keeping them adjacent is what
makes the difference visible.

WHEN YOU NEED THIS ONE: whenever a transformation puts a subtree in two places. `a(b+c)` distributed
leaves `a` twice, and two nodes cannot answer to one id - the id is the real name (phase2 section
10). ast.copy preserves ids, so using it here would produce exactly that collision.

VREFs ARE COPIED AS REFERENCES, never followed: a reference names a variable by id, and a second
reference to the same variable is a new node pointing at the same VAR - not a second variable. Which
is why duplicating a factor costs nothing to reason about.
@date 2026-09-11 21:00 ]]
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

--[[ child id -> parent node, for one tree.

COMPUTED PER CALL AND THROWN AWAY, never stored on the nodes. A tree is shared - a transformation's
result keeps most of its source's nodes, which is what makes the mexpr repair small - so hanging a
`.parent` on a node would write into something somebody else is holding, and the two trees would
disagree about who the parent is.

Here rather than in either caller because both the gesture resolver (climbing to the enclosing sum)
and the transformations (rebuilding the path to the root) need exactly this, and had written it
twice.
@date 2026-09-11 21:00 ]]
function ast.parent_map(root)
    NODE_SHAPE.check(root, "root")
    local parents = {}
    local function walk(node)
        for i = 1, #node do
            local child = node[i]
            if type(child) == "table" and child.type then
                parents[child.id] = node
                walk(child)
            end
        end
    end
    walk(root)
    return parents
end

--[[ TODO: figure out if this makes sens, if this is not copy with extra rules, etc. @date 2026-09-08 08:55 ]]
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

--[[ The RELATION constructors - equality, then the five inequalities. Each takes two expressions
already in `ns` and returns the node joining them; they differ only in the type tag, which is what
tells them apart downstream. @date 2026-09-08 09:10 ]]
function ast.new_eq(ns, expr1, expr2)
    NS_SHAPE.check(ns)
    NODE_SHAPE.check(expr1, "expr1")
    NODE_SHAPE.check(expr2, "expr2")
    local ret = ast.new(ns, ast.EQ)
    ret[1] = expr1
    ret[2] = expr2
    return ret
end

-- Inequality operators
--[[ `a < b`. @date 2026-09-12 03:05 ]]
function ast.new_ineq_less(ns, expr1, expr2)
    NS_SHAPE.check(ns)
    NODE_SHAPE.check(expr1, "expr1")
    NODE_SHAPE.check(expr2, "expr2")
    local ret = ast.new(ns, ast.INEQ_LESS)
    ret[1] = expr1
    ret[2] = expr2
    return ret
end

--[[ `a <= b`. @date 2026-09-12 03:05 ]]
function ast.new_ineq_leq(ns, expr1, expr2)
    NS_SHAPE.check(ns)
    NODE_SHAPE.check(expr1, "expr1")
    NODE_SHAPE.check(expr2, "expr2")
    local ret = ast.new(ns, ast.INEQ_LEQ)
    ret[1] = expr1
    ret[2] = expr2
    return ret
end

--[[ `a != b`. @date 2026-09-12 03:05 ]]
function ast.new_ineq_neq(ns, expr1, expr2)
    NS_SHAPE.check(ns)
    NODE_SHAPE.check(expr1, "expr1")
    NODE_SHAPE.check(expr2, "expr2")
    local ret = ast.new(ns, ast.INEQ_NEQ)
    ret[1] = expr1
    ret[2] = expr2
    return ret
end

--[[ `a > b`. @date 2026-09-12 03:05 ]]
function ast.new_ineq_greater(ns, expr1, expr2)
    NS_SHAPE.check(ns)
    NODE_SHAPE.check(expr1, "expr1")
    NODE_SHAPE.check(expr2, "expr2")
    local ret = ast.new(ns, ast.INEQ_GREATER)
    ret[1] = expr1
    ret[2] = expr2
    return ret
end

--[[ `a >= b`. @date 2026-09-12 03:05 ]]
function ast.new_ineq_geq(ns, expr1, expr2)
    NS_SHAPE.check(ns)
    NODE_SHAPE.check(expr1, "expr1")
    NODE_SHAPE.check(expr2, "expr2")
    local ret = ast.new(ns, ast.INEQ_GEQ)
    ret[1] = expr1
    ret[2] = expr2
    return ret
end

--[[ Membership and inclusion - general purpose relations, same shape as EQ, not carved out as
bigop-only. Added 2026-09-10 alongside "Bigop scoping" (docs/phase2_design.md), where a bigop's
sub/sup constraints are built as ordinary relation nodes through this same door.

THE FULL FAMILY, six glyphs, six node types: `\in`/`\ni` (membership, forward and backward),
`\subset`/`\subseteq` (proper and non-strict subset), `\supset`/`\supseteq` (proper and non-strict
superset). `\ni` and the `\sup*` pair are each the exact mirror of an existing one - `a \ni b` means
precisely `b \in a` - but get their own constructors regardless: operands stay in the WRITTEN order,
never silently swapped, matching how `<`/`>` are already two types rather than one reused with
operands flipped. Whether `\subseteq` reaches the row as a single keystroke or as a digraph
(`\subset` then `=`) is an input-method fact this layer never sees either way - by the time a row
holds it, it is one real glyph like any other. ]]
--[[ `expr1 \to expr2` - "expr1 tends to expr2". @date 2026-09-11 10:20 ]]
function ast.new_tends(ns, expr1, expr2)
    NS_SHAPE.check(ns)
    NODE_SHAPE.check(expr1, "expr1")
    NODE_SHAPE.check(expr2, "expr2")
    local ret = ast.new(ns, ast.TENDS)
    ret[1] = expr1
    ret[2] = expr2
    return ret
end

--[[ `expr1 \\Rightarrow expr2` - expr1 implies expr2. @date 2026-09-11 16:00 ]]
function ast.new_implies(ns, expr1, expr2)
    NS_SHAPE.check(ns)
    NODE_SHAPE.check(expr1, "expr1")
    NODE_SHAPE.check(expr2, "expr2")
    local ret = ast.new(ns, ast.IMPLIES)
    ret[1] = expr1
    ret[2] = expr2
    return ret
end

--[[ `expr1 \\Leftrightarrow expr2` - expr1 holds exactly when expr2 does. @date 2026-09-11 16:00 ]]
function ast.new_iff(ns, expr1, expr2)
    NS_SHAPE.check(ns)
    NODE_SHAPE.check(expr1, "expr1")
    NODE_SHAPE.check(expr2, "expr2")
    local ret = ast.new(ns, ast.IFF)
    ret[1] = expr1
    ret[2] = expr2
    return ret
end

--[[ `a \in b` - a is a member of b. @date 2026-09-12 03:05 ]]
function ast.new_in(ns, expr1, expr2)
    NS_SHAPE.check(ns)
    NODE_SHAPE.check(expr1, "expr1")
    NODE_SHAPE.check(expr2, "expr2")
    local ret = ast.new(ns, ast.IN)
    ret[1] = expr1
    ret[2] = expr2
    return ret
end

--[[ `a \ni b` - a contains b as a member, the mirror of new_in. @date 2026-09-12 03:05 ]]
function ast.new_ni(ns, expr1, expr2)
    NS_SHAPE.check(ns)
    NODE_SHAPE.check(expr1, "expr1")
    NODE_SHAPE.check(expr2, "expr2")
    local ret = ast.new(ns, ast.NI)
    ret[1] = expr1
    ret[2] = expr2
    return ret
end

--[[ `a \subset b`, strict. @date 2026-09-12 03:05 ]]
function ast.new_subset(ns, expr1, expr2)
    NS_SHAPE.check(ns)
    NODE_SHAPE.check(expr1, "expr1")
    NODE_SHAPE.check(expr2, "expr2")
    local ret = ast.new(ns, ast.SUBSET)
    ret[1] = expr1
    ret[2] = expr2
    return ret
end

--[[ `a \subseteq b`. @date 2026-09-12 03:05 ]]
function ast.new_subseteq(ns, expr1, expr2)
    NS_SHAPE.check(ns)
    NODE_SHAPE.check(expr1, "expr1")
    NODE_SHAPE.check(expr2, "expr2")
    local ret = ast.new(ns, ast.SUBSETEQ)
    ret[1] = expr1
    ret[2] = expr2
    return ret
end

--[[ `a \supset b`, strict. @date 2026-09-12 03:05 ]]
function ast.new_supset(ns, expr1, expr2)
    NS_SHAPE.check(ns)
    NODE_SHAPE.check(expr1, "expr1")
    NODE_SHAPE.check(expr2, "expr2")
    local ret = ast.new(ns, ast.SUPSET)
    ret[1] = expr1
    ret[2] = expr2
    return ret
end

--[[ `a \supseteq b`. @date 2026-09-12 03:05 ]]
function ast.new_supseteq(ns, expr1, expr2)
    NS_SHAPE.check(ns)
    NODE_SHAPE.check(expr1, "expr1")
    NODE_SHAPE.check(expr2, "expr2")
    local ret = ast.new(ns, ast.SUPSETEQ)
    ret[1] = expr1
    ret[2] = expr2
    return ret
end

-- Arithmetic operators
--[[ A sum of any number of terms, in the order given.

VARIADIC because a sum is n-ary here rather than a tree of binary adds: `a+b+c` is ONE node with
three children, which is what lets a gesture on any `+` name the whole sum.
@date 2026-09-12 03:05 ]]
function ast.new_add(ns, ...)
    NS_SHAPE.check(ns)
    --[[ EVERY operand, not just the first: a variadic constructor is where a stray nil or a raw
    number slips in unnoticed, because nothing downstream reads the arity back. ]]
    for i = 1, select("#", ...) do
        NODE_SHAPE.check((select(i, ...)), "operand " .. i)
    end
    local ret = ast.new(ns, ast.ADD)
    for i, expr in ipairs({...}) do
        ret[i] = expr
    end
    return ret
end

--[[ A product of any number of factors, in the order given.

VARIADIC for the same reason new_add is, and ORDER IS KEPT: multiplication is not assumed
commutative here - vectors have products, and a cross product does not commute.
@date 2026-09-12 03:05 ]]
function ast.new_mul(ns, ...)
    NS_SHAPE.check(ns)
    --[[ EVERY operand, not just the first: a variadic constructor is where a stray nil or a raw
    number slips in unnoticed, because nothing downstream reads the arity back. ]]
    for i = 1, select("#", ...) do
        NODE_SHAPE.check((select(i, ...)), "operand " .. i)
    end
    local ret = ast.new(ns, ast.MUL)
    for i, expr in ipairs({...}) do
        ret[i] = expr
    end
    return ret
end

--[[ `a / b`, as a node - the fraction bar, not a computed value. @date 2026-09-12 03:05 ]]
function ast.new_div(ns, expr1, expr2)
    NS_SHAPE.check(ns)
    NODE_SHAPE.check(expr1, "expr1")
    NODE_SHAPE.check(expr2, "expr2")
    local ret = ast.new(ns, ast.DIV)
    ret[1] = expr1
    ret[2] = expr2
    return ret
end

--[[ A BIG OPERATOR - a sum, a product, a union, an intersection, or an integral. All five declare a
name; only the integral still does it as (op, var, from, to, body) - the other four moved to the
GROUP shape below (new_bigop_group), N variables and a constraint list per side.

THESE ARE THE FIRST NODES THAT DECLARE A NAME. Every other node in this file consumes references;
a big operator makes one. `var` is an ast.new_var that belongs to this node, and the body refers to
it through an ordinary ast.new_vref, exactly as it would to any other variable - so nothing walking
the body needs to know it is inside a binder to read it correctly.

WHAT THAT BUYS is scope without a second mechanism. Author, 2026-09-10: "int declares a variable
name, it offers the insides a new reference, itself, the idea is that we will have our free
variables that buble up outside of the root, while some vars get catched by bigops". So a name in
the body resolves to the innermost binder that declares it, and a name no binder claims keeps
travelling outward past the root, where it is a free variable of the whole formula. Collecting the
free variables of an expression is then one walk that subtracts each binder's `var` from what its
body returned.

ONLY THE INTEGRAL STILL HAS THIS SHAPE. Author, 2026-09-10, originally on all three: "int declares a
variable name, it offers the insides a new reference, itself, the idea is that we will have our free
variables that buble up outside of the root, while some vars get catched by bigops". SUM/PROD moved
to `new_bigop_group` below the same day ("Bigop scoping", docs/phase2_design.md) - a single `var`
turned out to be one relation (`=`) on one side and a bare bound on the other, not general enough for
`i<n`, `i \in S`, or more than one variable. INT keeps this shape: its variable is written as `dx`
after the body rather than under the sign, so nothing about its sub/sup was ever a constraint to
generalize in the first place.
@date 2026-09-10 07:05 ]]
local OLD_SHAPE_BIGOPS = {[ast.INT] = true}

--[[ The GROUP shape's own types - SUM/PROD/UNION/INTERSECT, added alongside "Bigop scoping". Kept
separate from OLD_SHAPE_BIGOPS because the slot layout differs: slot 1 there is THE var; here it is
a COUNT, and the vars are a run of slots starting at 4. ]]
--[[ EVERY GROUP-SHAPED BIG OPERATOR, and the only place one is named.

Type name -> the symbol it serializes as. Adding an operator is one row here: this table generates
its membership in GROUP_BIGOPS (so catch_free scopes it), its entry in type_to_symbol and hence in
symbol_to_type (so it round-trips), and its `ast.new_<name>` constructor. Nothing else is
per-operator, because nothing else about them differs - they share the shape, the counts, the
constraint lists and the spawning.

Author, 2026-09-11: "also there is a lot of code in common in between those, make sure to keep it in
common". Before this the four originals each had a hand-written constructor, a hand-written entry in
each of the two symbol tables and a hand-written entry here - four places to keep in step per
operator, and nine operators would have been thirty-six chances to miss one.

WORD SYMBOLS for the named ones (`lim`, `argmax`) rather than single letters. The single letters are
nearly used up, and a serialization is read by people; `(argmax, 1, 0, 1, ...)` needs no key. The
tuple reader takes any symbol with no comma in it, so length costs nothing.
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

--[[ Rebinds every free reference to `name` inside `sub` so it points at `var` instead.

THIS IS THE CATCH, and it is the whole of the binding. A body is built with no knowledge of what
encloses it, so a mention of `x` in it is an ordinary reference to whatever `x` the builder had.
Wrapping that body in an operator that declares `x` is what makes those mentions MEAN the operator's
variable - so the constructor walks the body once and repoints them.

FREE means not already claimed by a nearer binder. A nested operator declaring the same name
shadows this one, so its body is skipped - but not its BOUNDS, which are written outside its own
scope: in `\sum_{i=1}^{n}` the `1` and the `n` are not in `i`'s scope, and a `\sum_{x=1}^{x}`
inside an integral over `x` binds its body and nothing else. A GROUP bigop shadowing on one of
several variables still shadows the whole group for that name - its subs, sups AND body are all one
scope with each other, unlike the old shape's bounds-outside-body split.

Only VREFs move. The VAR they used to point at is left alone in the namespace, because something
outside the body may still be referring to it - `x + \int_0^1 x dx` has two mentions of `x` that
mean different things, and only the inner one is caught.
@date 2026-09-10 07:40 ]]
local function catch_free(ns, sub, name, var)
    if type(sub) ~= "table" or not sub.type then
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

--[[ WHY SUP COMES BEFORE SUB, in every big operator.

It reads UPSIDE DOWN otherwise. The sup is drawn ABOVE the operator and the sub BELOW it, so a
listing that puts the sub first inverts what is on screen - and the two debug views print the tuple
in order, so both were inverted. Reported 2026-09-11: "put sub under sup in f5, that is really
strange, the same in f4", then "like, flip the serialization maybe?".

FLIPPED IN THE NODE, not in the viewers. F5 prints exactly what ast.to_string writes and is
documented as the ground truth F4 is read FROM, so reordering only the display would have made it
disagree with the serialization it exists to show. This supersedes the original wording for INT -
"(var declaration, start_value, end_value, bound-expression)", 2026-09-10 - which fixed the four
slots and their meanings, not their order; the meanings are unchanged.

WHAT THIS BREAKS: an AST written as text before 2026-09-11 reads back with its two bounds swapped.
There is no version marker in the format to detect that, and nothing in the app stores AST text
today - the document is saved as LaTeX and the tree is rebuilt on load - so the exposure is limited
to a tree somebody serialized by hand.
@date 2026-09-11 09:40 ]]

--[[ A big operator over `name`, whose variable it DECLARES and whose body it then binds. INT's own
shape, (var, sup, sub, body) - the upper bound first, for the reason just above.

    ast.new_int(ns, "x", one, zero, body)      -- body's free `x` now means this integral's `x`

THE NAME COMES IN, NOT THE VARIABLE. Author, 2026-09-10: "bigop ops need to create a var, probably
reuse new_var, the idea is that in this way we will achieve our binding". So the operator owns the
variable it binds, and there is no way to build one whose slot 1 belongs to somebody else.

THE BODY IS BUILT FIRST, WHICH THE INTEGRAL REQUIRES. `\int_0^1 x dx` names its variable AFTER the
body - the `dx` at the end is where `x` is declared - so anything that needed the variable before
the body could not read an integral at all. Catching afterwards asks the caller for nothing: build
the body with `x` free, then say who binds it.
@date 2026-09-10 07:40 ]]
--[[ No checks here either - see new_bigop_group below. ast.new_int is the only route in, and it
checks. ]]
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

--[[ An integral, as a big operator: `name` is the glyph, `sup`/`sub` the limits, `body` the
integrand. Shares new_bigop with the sum and product forms,
        so all of them carry limits the same way.
@date 2026-09-12 03:05 ]]
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

--[[ SUM/PROD/UNION/INTERSECT - the GROUP shape, "Bigop scoping" (docs/phase2_design.md).

    (op, n_vars, n_sup, n_sub, var1..varN, sup1..supM, sub1..subK, body)

Unlike `new_bigop` above, this one binds N names at once. `vars` is a list of NAME STRINGS (the
operator makes its own `ast.new_var` for each, same "the name comes in, not the variable" rule);
`sups`/`subs` are lists of ALREADY-BUILT constraint nodes - ordinary relation trees (`=`, `<`, `in`,
`subeq`, or anything a general expression parser produced), built and handed in by the caller the
same way `body` already is, because building them means parsing row units and this file does not
parse rows.

SUP BEFORE SUB here too, counts included - see new_bigop above for why. Note that the SUB is still
the side that spawns the variables (`\sum_{i=1}^{n}`): which side declares has nothing to do with
which side is written first, and moving the order did not move that.

CATCHING RUNS OVER EVERY TREE, FOR EVERY NAME - each sub constraint, each sup constraint, and the
body - because a sup or a later sub may reference an earlier sub's own variable
(`\sum_{i=0,j=i+1}`) exactly as the body may. Order between different names does not matter; each
name's catch is an independent walk of the same fixed set of trees.
@date 2026-09-10 ]]
--[[ NO CHECKS HERE. Argument checking belongs to the API functions that reach this, not to the
local they funnel through - author, 2026-09-12: "do preamble checks, but only in the api calls, not
in locals". Both routes in check first: ast.new_group_bigop, and the generated ast.new_sum /
new_prod / new_lim family below. ]]
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

--[[ Builds any group operator by TYPE - what a caller that read the operator out of a row has in
hand, rather than one it picked at write time. mexpr_ast's reader uses this; the named constructors
below are for callers that know which operator they mean.
@date 2026-09-11 10:20 ]]
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
GROUP_BIGOP_SYMBOL, all identical but for the type they pass. Generated rather than typed out
because "identical but for one constant" is what a loop is for, and because a hand-written set is
where the tenth operator gets forgotten.

`pairs` ORDER IS IRRELEVANT HERE, unlike the read_constraints walk that was bitten by it: this only
populates a table, and no two rows touch the same key. Said explicitly because a `pairs` over
string keys in this project has meant a real bug before. ]]
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

--[[ `base^exponent`. @date 2026-09-12 03:05 ]]
function ast.new_exp(ns, base, exponent)
    NS_SHAPE.check(ns)
    NODE_SHAPE.check(base, "base")
    NODE_SHAPE.check(exponent, "exponent")
    local ret = ast.new(ns, ast.EXP)
    ret[1] = base
    ret[2] = exponent
    return ret
end

--[[ What a NUM node IS, as text - the reading its three slots stand for.

    (N, 3, 4, -1)   ->  -3/4
    (N, 7, 1, 1)    ->  7
    (N, 1, 0, 1)    ->  inf

INFINITY IS A DENOMINATOR OF ZERO, which is why this has to exist rather than every viewer doing its
own division. Author, 2026-09-11: "infty should also parse, it's a number like any other, give it a
specific value in over 0 in denominator". So it needs no node type of its own, no special case in
arithmetic that does not want one, and the SIGN gives it a direction for free - `-\infty` goes
through build_product's ordinary negation and comes out (N, 1, 0, -1).

`m/0` FOR ANY OTHER m IS NOT GLOSSED AS INFINITY. Nothing builds one today, and reading `0/0` back as
"inf" would be this function inventing an answer to a question the AST has not been asked. It prints
the raw pair instead, which is a thing a reader can go and look at.

Used by both debug views, which is the whole point of it living here: F4 and F5 cannot disagree
about what a number says.
@date 2026-09-11 09:00 ]]
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

-- Number: (N, m, n, sign) - rational/natural number m/n
--[[ A RATIONAL, as numerator, denominator and sign kept apart.

NOT A FLOAT. `m`/`n` are integers and `sign` is 1 or -1, so a third is a third rather than
0.333..., and two expressions that should be equal still are after arithmetic. The sign lives on the
number rather than in a wrapper, which is why a `-` glyph in a row names the NUM it belongs to.

Params: `n` defaults to 1 and `sign` to 1, so new_num(ns, 3) is the integer three. Both integers are
asserted rather than coerced - a float here is a bug upstream, not something to round.
@date 2026-09-12 03:05 ]]
function ast.new_num(ns, m, n, sign)
    NS_SHAPE.check(ns)
    n = n or 1
    sign = sign or 1
    assert(type(m) == "number" and m == math.floor(m), "m must be an integer")
    assert(type(n) == "number" and n == math.floor(n), "n must be an integer")
    assert(sign == 1 or sign == -1, "sign must be 1 or -1")
    
    -- Ensure m and n are positive, with sign capturing the overall sign
    if m < 0 and n < 0 then
        -- Both negative: flip both to positive (signs cancel out)
        m = -m
        n = -n
    elseif m < 0 then
        -- Only m is negative: flip m to positive and flip sign
        m = -m
        sign = -sign
    elseif n < 0 then
        -- Only n is negative: flip n to positive and flip sign
        n = -n
        sign = -sign
    end
    
    local ret = ast.new(ns, ast.NUM)
    ret[1] = m
    ret[2] = n
    ret[3] = sign
    return ret
end

-- Function call: (@, f, a1, a2, a3, ...)
--[[ Applying `fn` to arguments: `fn` is child 1 and the arguments follow it.

THE FUNCTION IS A CHILD, not a name held beside the node, so what is being applied can itself be an
expression and resolves through the same VREF machinery as any other use.
@date 2026-09-12 03:05 ]]
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

-- Named variable: (#, name)
--[[ The absent operand - see ast.NULL. Carries nothing but its own id. @date 2026-09-11 06:30 ]]
function ast.new_null(ns)
    NS_SHAPE.check(ns)
    return ast.new(ns, ast.NULL)
end

--[[ A VARIABLE, the declaration itself. A USE of it is a VREF - see new_vref. @date 2026-09-12 03:05 ]]
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

-- Vector: (V, a1, a2, ...)
--[[ A vector of the given components, in order. @date 2026-09-12 03:05 ]]
function ast.new_vec(ns, ...)
    NS_SHAPE.check(ns)
    --[[ EVERY operand, not just the first: a variadic constructor is where a stray nil or a raw
    number slips in unnoticed, because nothing downstream reads the arity back. ]]
    for i = 1, select("#", ...) do
        NODE_SHAPE.check((select(i, ...)), "operand " .. i)
    end
    local ret = ast.new(ns, ast.VEC)
    for i, expr in ipairs({...}) do
        ret[i] = expr
    end
    return ret
end

-- Matrix: (M, m, n, a1, ... a[m+n])
--[[ A matrix of `rows` by `cols`, filled from the elements given in row-major order.

Fewer elements than rows*cols is allowed - a partly built matrix is a real state while one is being
typed - but MORE is refused, since that can only mean the caller and the shape disagree.
@date 2026-09-12 03:05 ]]
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

-- Parentheses: (_, a1)
--[[ One cell of the proof DAG, wrapping the expression it states. @date 2026-09-12 03:05 ]]
function ast.new_cell(ns, expr)
    NS_SHAPE.check(ns)
    NODE_SHAPE.check(expr, "expr")
    local ret = ast.new(ns, ast.CELL)
    ret[1] = expr
    return ret
end

-- Variable reference: (&, ref_id)
-- ref can be either a number (id) or an AST node (whose id will be extracted)
--[[ A USE of a variable, by id.

THE REFERENCE IS THE WHOLE NODE: it names a VAR and carries nothing else, so two uses of one
variable are two nodes pointing at one declaration rather than two variables that happen to share a
name. That is what makes duplicating a factor cheap - see ast.copy_fresh.

Params: `ref` may be the id itself or the VAR node to take it from, because both are natural at a
call site and neither is more correct.
@date 2026-09-12 03:05 ]]
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

--[[ A node as a single line of text, ids included.

FOR READING, AND FOR from_string: the two are a pair, so what this writes must parse back. Ids are
part of it, which is exactly why it cannot answer "are these two trees the same expression" across
namespaces - ast.shape is that question.
@date 2026-09-12 03:05 ]]
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


--[[ The same serialization as to_string, split one NODE per line, with its depth.

    (=:9)
      (@, F(),(1):5)
        (N, 0, 1, 1:4)
      (&, 2:7)          ref: x

Each line is exactly what to_string would have written for that node with its child NODES lifted
out - so a leaf's line is byte-identical to its to_string text, and a compound's line is its head,
its scalar operands and its id. Reading them back in order and re-nesting by depth reconstructs the
string to_string produces.

WHY IT LIVES HERE rather than in the overlay that draws it: it has to agree with to_string, and two
functions that must agree are kept next to each other so a change to the tuple shape is made in both
or in neither. The F5 view is a debug instrument, but the format it shows is this file's.

EVERY LINE COMES BACK AS COLOURED PIECES, `parts`, alongside the plain `text` they concatenate to.
A reader that only wants the text ignores them; the F5 overlay paints them. The ROLES:

    "op_sym"    an operator's symbol - the ^, +, *, =, I, S   - RED
    "bind_sym"  the # of a declaration, the & of a reference  - BLUE
    "var_name"  the name a declaration declares               - GREEN
    "ref_name"  the name a reference resolves to              - GREEN
    "num_value" what a number cell actually is                - YELLOW

Asked for 2026-09-11: "var creations are going to have the # blue and the k inside also colored in
green", then "I want ^, +, *, those things in red", then "and & should also be blue", then "also in
yellow write the number next to the number cell".

THE YELLOW IS A READING, NOT A FIELD. A number is stored as three slots - `(N, 3, 4, -1)` is
numerator, denominator and sign - which is the right shape to compute with and an awful one to read.
The value beside it says what those three mean, exactly as a reference's green name says what its id
points at: the tuple stays authoritative and the gloss sits alongside.

WHAT THE SPLIT IS ACTUALLY FOR - the two blues against the reds. Everything painted blue or green
names a VARIABLE: `#` makes one, `&` points at one, and the greens say which. Everything red is an
OPERATION on whatever those produce. So the colour separates a tree's naming from its arithmetic at
a glance, which is the question F5 is opened to answer. The identificators are left alone: they are
on every line and colouring them would drown the two nodes that matter.

WHY THE SPLIT LIVES HERE and not in the overlay: the pieces have to agree with to_string, and two
functions that must agree are kept next to each other so a change to the tuple shape is made in both
or in neither. The colours are the F5 view's business; knowing which SPAN is a symbol is this
file's.
@date 2026-09-11 05:30 ]]
function ast.to_string_lines(ns, node, depth, out)
    NS_SHAPE.check(ns)
    -- A value or a node; see ast.to_string for why a scalar here is the base case, not an error.
    if type(node) == "table" then
        NODE_SHAPE.check(node, "node")
    end
    out = out or {}
    depth = depth or 0

    if type(node) ~= "table" or not node.type then
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

--[[ The readable name of a node type, or nil for an unknown one. @date 2026-09-12 03:05 ]]
function ast.type_name(node_type)
    return type_name[node_type]
end

--[[ A canonical, ID-FREE rendering of a tree, for comparing one against another.

WHY IDS CANNOT BE IN IT. The comparison anybody actually wants is between a tree and a tree BUILT
FROM IT - a transformation's output against what its rebuilt mexpr parses back to. Those live in
different namespaces and their ids cannot match by construction, so ast.to_string, which carries
them, answers "different" for two trees that are the same expression. This answers the question that
was meant.

A VREF RENDERS AS ITS VARIABLE'S NAME, which is the whole reason `ns` is a parameter. A name is the
identity of a variable (docs/phase2_design.md section 9); two namespaces agree about names exactly
where they cannot agree about ids.

NOT A SERIALIZATION: nothing reads this back. It is a comparison key, so it may be as verbose as it
likes and must only be INJECTIVE enough that two different expressions never collide.
@date 2026-09-12 02:00 ]]
function ast.shape(ns, node)
    NS_SHAPE.check(ns)
    -- A value or a node; see ast.to_string for why a scalar here is the base case, not an error.
    if type(node) == "table" then
        NODE_SHAPE.check(node, "node")
    end
    if type(node) ~= "table" or not node.type then
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

-- Helper: parse a token that's either a number or a string
local function parse_atom(s)
    local num = tonumber(s)
    if num then
        return num
    end
    return s
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

--[[ The inverse of to_string: text back into a tree in `ns`.

Whitespace is stripped first, so the format is positional rather than layout-sensitive. Returns nil
when the text is not a tree this can read, which a caller must check - a malformed line is ordinary
input here, not an exception.
@date 2026-09-12 03:05 ]]
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
    
    -- Parse tuple: (type, arg1, arg2, ...:id)
    assert(s:sub(1, 1) == "(", "Expected '(' at start of tuple: " .. s)
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

local ast = require("ast")

local transforms = {
    MODE_ADD,
    MODE_MUL,
}

--[[
transforms.lua - TERM DRAGGING: moving a term from where it sits to where you want it, with the
algebra that keeps the expression equal done as part of the move.

DELIBERATELY UNFINISHED, and not a bug to fix. This is exploratory design work still being thought
through - the notes below are that thinking, kept in the order it happened, and they disagree with
each other in places on purpose. Do not fill in the remaining cases without asking first.

Read everything under here as a record of intent rather than as a description of what the code
does.
@date 2026-09-08 08:55 ]]

--[[ TODO: because this was work in progress, it ended up changing while I was writing it, so
the description contains a lot of inacuracies ]]

--[[ MAYBE I must rethink the whole idea: instead of a source and a destination, it may be better
to think of it as move incremental movements of terms around, so instead of making the whole path of
transformations, simply do one transformation at a time, so given a subobject, take it out of the
expression for example, with some caveats of what means to 'take it out' ]]

--[[
This file should contain transforms of ast nodes in such a way that their mathematic rigor is
preserved, but aids comprehension. Those transforms will be triggered manually.

The first thing I want implemented is addition dragging and multiplication dragging. Addition
dragging will substract the element the place it is taken from and move it as an addition term where
the user finally wants it. Multiplication dragging will factor the term.

An example:
a(ab + ac + bc)
Encoded as:
(#, a, :1)
(#, b, :7)
(#, c, :8)
(*, (&, 1 :9), (+, (*, (&, 1 :10), (&, 7 :11) :12), (*, (&, 1 :13), (&, 8 :14) :15), (*, (&, 7 :16), (&, 8 :17) :18) :19) :20)
or in it's simplified form:
(*, a, (+, (*, a, b), (*, a, c), (*, b, c)))
Can add-move the term 'bc' outside the expression to obtain the following:
a(ab + ac) + abc
Or it can mul-move to get:
abc(ab/bc + 1 + ac/bc)

The idea is to have different operation options to be made in different contexts. Another context
that must be programmed is ab/ac, you could create a dragging of a from bellow the fraction to above
the fraction to obtain: (ab*(1/a))/c, or more precisely from something like (/, (*, a, b). (*, a, c))
to obtain something of the form (/, (*, a, b, (/, 1, a)), c). Of course in the case of '/' a more
usefull operation would be that of cancelation, or more preciselly in the case
(/, (*, a, b:1). (*, a, c:2):3)
selecting the a from 1, a from 2 and 3 to perform the cancelation resulting in
(/, b, c)
Some operations should auto resolve, for example multiplication by 1

]]

--[[
Let's make add-move:

* root is the root of the ast we are transforming
* src_id is the id of the object that we want to addmove
* dst is the id of the object in which we want to place the new term (-1 in case we want to change
the root into (+, root, src))
* dstloc in case the destination is an addition the location that the new term will be placed in

* returns the new root: this makes the change on a copy of the expression

By traveling the tree, the src node will invariably change, for example, in the above example, the
term 'a' was added to the 'bc' term because the 'moving' traveled a multiplication node. As such a
generic idea comes to mind: the nearest common ancestor is found for both dst and src and src will
traver to the comm_anc first and after that to dst, taking it's final place
]]
--[[ A generic observation is that diverse transformations will leave trees that have strange
artefacts, like the (*, a, 1), those should be cleaned up in a second pass and only some of such
transformations should be auto-called (because the user may like the verbosity for some reason) ]]

--[[ At this point we have our destination, we have our source and our ancestor and
for each node we know the parent that it has ]]

--[[ Now let's talk cases:
EQ = 2,
INEQ_LESS = 3,
INEQ_LEQ = 4,
INEQ_NEQ = 5,
INEQ_GREATER = 6,
INEQ_GEQ = 7,
-- later those need to trigger some special case, but for the specific operation of moving
the term, this is invalid, you can't have something like a+(b=c) in mathematics

ADD = 8,
-- quite simple, the term is simply removed from it

MUL = 9,
-- the term gets multiplied, it gets transformed into (*, the_value_of_mul, the_curr_src)

DIV = 10,
-- depends on the location of the drag, if draged from numerator it will inherit a division
else an error will be called, because you can't drag terms from denominator by default

EXP = 11,
-- results in a multiplication term e^(a+b) -- drag a --> e^a * e^b 
-- this is also a strange one because it can't continue after this one, because it no longer
is an addition after this step. how should I treat it, keep the term as e^a or move the whole
multiplication around. Probably best is to stop, and let the user have the partial result,
letting him move from there

NUM = 12,
-- can't happen

CALL = 13,
-- can't happen --> error, later when I will add sumation, limits, etc, it will be posible,
but not from now

VAR = 14,
-- can't happen

VEC = 15,
-- can't happen as an addmove, so other moves may need to be tried here, I guess each move
operation leads to a transformation of the term, here the user may need to have a way to move
it out: in a add move a new vector may appear, in a mulmove a factoring through the vector may
be done, either way, the final operation, the result of the move will be a sequence of
operations of moving a term outside of an operator, with different ways of taking it out

MAT = 16,
-- same as vec

CELL = 17,
-- depends on the whatever the relation was with the previous node

VREF = 18,
-- can't happen
]]

--[[ So after the deliberation above, it is more clear that it depends on the transitions,
it depends on the mode of movement, etc.

That said, a solution is to take all the cases:

### additon pathing:

## ADD -> ADD (self to self because we should never see (+, ..., (+, ...), ...), at most we could
see an ADD in a CELL in an ADD, this happen)
Either way, the solution to this is obvious, it simply moves around terms

## ADD -> MUL
This is transformed in an addition and here we enter the definition of a 'moving term' - this is
required not to do useless transforms when not needed, practically the move from ADD -> MUL will
end us in a state where we would consider us still in an add. Another way to see it is that if
the moving ended at that MUL, the result wuld've been the creation of a new add-node that would
contain the mul and the new other term

## ADD -> DIV
This is most similar to the mul above, we would still land in a ADD state

## ADD -> EXP
This must force us in a new MUL state, the new term remembered is still an exponentiation, but
a multipolication term novertheless, so the free moving term would be a multiplication term

## example MUL -> LOG
Would happen in reverse of the above
OBS: there is no mulmove and addmove, they are both moving terms around, the mulmove is obtained
by created a (*, 1, term) from the term, wherever it is, and starting a move from there because
a MUL -> ADD will result in a forced factorization, else it doesn't make sense to move terms
of multiplications around
]]

--[[ So what I want to do now:

OBS: I need a way to store the different operations that are done. 
I need to figure out the step that needs to be taken at each moment in the operation
I need to figure out what exactly to do on that step, so, figure out what node I am in, what
node I want to pass, what to remember the remembered auxiliary as, etc.
I need to do this step and advance
I also need to figure out what happens in reverse, so far I've only spoken what happens from src
to ancestor, but not what happens from ancestor to dst

]]

--[[
node - the node to traverse
parent - the parent of the node that will be set in node.p
ploc - the location of the node inside the parent node.p[node.ploc] == node
@date 2026-09-08 08:55 ]]
function transforms.initial_traverse(node, parent, ploc)
    parent = parent or nil
    ploc = ploc or 1

    node.parent = parent
    node.loc = ploc
    for i = 1, #node do
        if type(node[i]) == "table" then
            local fs, fd, fa = initial_traverse(node[i], node, i)
            found_src = fs or found_src
        end
    end         
end

function transforms.find(node, id)
    if node.id == id then
        return node
    end
    for i = 1, #node do
        local res = transforms.find(node[i], id)
        if res then
            return res
        end
    end
    return nil
end

--[[ assumes intial_traverse was called on root @date 2026-09-08 08:55 ]]
function transforms.extract_term(ns, node, mode)
    if (not node.parent) then
        --[[ there is nowhere to extract the term to, it doesn't even have a parent  ]]
        return node, false
    end
    local p = node.parent
    local pp = node.parent.parent
    if (not pp) then
        if p.type == ast.VEC then
            --[[ TODO: this should split the vector into two, the other one having only the
            extracted item and the caried result would be the second vector ]]
            return 
        end
        if p.type == ast.MAT then
            --[[ TODO: same as above, in fact both of them should also lead to something interesting,
            where you could select multiple elements from mat/vecs and have them merged in a new
            mat/vec ]]
            return 
        end
        --[[ The rest don't make sense, so ADD, MUL would not change at all, DIV, EXP, what would
        extracting a part of them achieve, etc. ]]
        return node, false
    end
    if p.type == ast.ADD then
        if pp.type == ast.EQ then
            --[[ a+b = b+c -> a = c or more precisely a+b = c -> a = c-b ]]
        end
        --[[ TODO: all eq ]]
        if pp.type == ast.MUL then
            --[[ (a+b+c)*d -> (b+c)*d + ad ]]
        end
        if pp.type == ast.DIV then
            --[[ (a+b)/c -> a/c + b/c returned term is a -> a/c ]]
            --[[ doesn't make sense for add+denominator ]]
        end
        if pp.type == ast.EXP then
            --[[ e^(a+b) -> e^a * e^b, the returned term is a -> e^a ]]
            --[[ no rule for base ]]
        end
        if pp.type == ast.MAT then
            --[[ as above ]]
        end
        if pp.type == ast.VEC then
            --[[ as above ]]
        end
    end
    if p.type == ast.MUL then
        if pp.type == ast.EQ then
            --[[ ab = ac -> b = c returned term is a -> nil ]]
        end
        --[[ TODO: all eq ]]
        if pp.type == ast.ADD then
            --[[ ab + c -> b + c/a (forced factorization) returned a -> b ]]
        end
        if pp.type == ast.DIV then
            --[[ (ab)/c -> a(b/c)  ]]
            --[[ a/bc -> a/b * 1/c ]]
        end
        --[[ log will be here sometime ]]
        if pp.type == ast.EXP then
            --[[ (ab)^c -> a^c * b^c ]]
        end
    end
    if p.type == ast.DIV then
        if pp.type == ast.EQ then
            --[[ not sure about those two: ]]
            --[[ I also need to figure out a way not to cancel zero or do something about it ]]
            --[[ a/b = c -> 1/b = c/a ]]
            --[[ b/a = c -> b = ca ]]
        end
        --[[ TODO: all eq ]]
        if pp.type == ast.MUL then
            --[[ a/b * c -> a/1 * c * 1/b (both numerator and denominator can be moved) ]]
        end
        if pp.type == ast.ADD then
            --[[ a/b + c -> a (1/b + c/a) ]]
            --[[ b/a + c -> 1/a (b + ca) ]]
        end
        if pp.type == ast.EXP then
            --[[ similar to mul in base ]]
        end
        -- if pp.type == (TODO: continue with the cases)
    end
    if p.type == ast.EXP then
        --[[ not sure what would extracting do here if anything ]]
    end
    if p.type == ast.VEC then
        --[[ TODO ]]
    end
    if p.type == ast.MAT then
        --[[ TODO ]]
    end
end


-- #################################################################################################
-- THE FIRST REAL TRANSFORMATION
-- #################################################################################################

--[[ Is this the number 1 - the factor a product may drop without changing? ]]
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
@date 2026-09-11 20:00 ]]
local function replace_in(ns, root, parents, old, new)
    while old ~= root do
        local parent = parents[old.id]
        if not parent then
            return nil, "the node is not in this tree"
        end
        local rebuilt = ast.new(ns, parent.type)
        for i = 1, #parent do
            rebuilt[i] = (parent[i] == old) and new or parent[i]
        end
        old, new = parent, rebuilt
    end
    return new
end

--[[ DISTRIBUTE a product over the sum inside it.

    x(b + c)y   ->   xby + xcy

`add_id` names the ADD; its parent must be the MUL. That is the whole parameter - the gesture
resolves it (ast_gestures) and this needs to know nothing about how the click arrived.

WHAT IS SHARED AND WHAT IS COPIED, which is decided by one question only: does this subtree end up
in the output MORE THAN ONCE? Only the factors surrounding the sum do - `a` in `a(b+c)` becomes the
`a` of two terms - so those are copied from the second term on, because one node cannot sit in two
places under one id.

THE SUM'S OWN TERMS ARE NEVER COPIED. Each of them appears exactly once in the result: `b` lands in
the first term and `c` in the second, and nothing needs a second `c`. Copying them anyway was the
original shape here and it was wrong twice over - author, 2026-09-12: "there is no point in creating
a new reference". It minted nodes nothing was ever drawn for, so the writer that rebuilds the mexpr
had to re-render glyphs it could have carried across verbatim, losing whatever decoration and spacing
they had. Cheap for a bare letter; a whole subtree for `2x` or a fraction.

What is left is the smallest diff the algebra allows, which is the point: the untouched parts of the
old drawing stay usable.

REFUSES rather than widening, the way selection does everywhere: not an ADD, no parent, parent not
a MUL. A transformation offered where it does not apply is how one ends up running on the wrong
nodes.

Returns the new root, or nil plus a reason. The source tree is untouched, and the result lives in
the SAME namespace - untouched nodes keep their ids, which is what lets "has this subtree changed?"
be answered by identity rather than by comparing shapes.
@date 2026-09-11 20:00 ]]
function transforms.distribute(ns, root, add_id)
    local add = ns.by_id[add_id]
    if not add or add.type ~= ast.ADD then
        return nil, "distribute needs a sum"
    end

    local parents = ast.parent_map(root)
    local mul = parents[add.id]
    if not mul or mul.type ~= ast.MUL then
        return nil, "distribute needs a product around the sum"
    end

    -- Where the sum sits among the product's factors: everything before it stays before, and
    -- everything after stays after, in every term.
    local at
    for i = 1, #mul do
        if mul[i] == add then
            at = i
            break
        end
    end
    if not at then
        return nil, "the sum is not a factor of that product"
    end

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

return transforms

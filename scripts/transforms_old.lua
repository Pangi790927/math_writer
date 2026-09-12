--[[ ==================================== WHAT THIS FILE OFFERS ====================================

NOTHING that runs. The three functions below are kept for their design, not for use, and the file
is not required from anywhere. Read the notes, not the code.

    initial_traverse(node, parent, ploc)   hangs .parent/.loc on a tree    (faulted, see above)
    find(node, id)                         the node with that id           (faulted, see above)
    extract_term(ns, node, mode)           lifts a term out of its parent  (needs the first)

@date 2026-09-12 01:25
================================================================================================= ]]

--[[
transforms_old.lua - THE FROZEN HALF of the original transforms.lua: term dragging, and the design
notes it was being thought through in.

MOVED HERE 2026-09-12, unchanged, when transforms.lua became the plugin registry. Nothing requires
this file and nothing calls into it. It is kept because it is exploratory design work the author is
still thinking through - CLAUDE.md's own "don't fill in the remaining cases without asking first" -
and deleting it would throw the thinking away along with the code.

NOT REPAIRED, DELIBERATELY. Three faults were found while moving it, and are recorded here rather
than fixed, because fixing frozen WIP unasked is the thing that rule forbids:

  - `initial_traverse` (below) recurses through the BARE name `initial_traverse`, which is a global
    and is nil - so it nil-calls on the first table child. It also unpacks three return values from
    a function that returns none, and writes to an undeclared global `found_src`.
  - `find` recurses into `node[i]` without checking it is a table, so any NUM - whose children are
    plain numbers - makes it index a number.
  - The module table used to be `{MODE_ADD, MODE_MUL}`, two undeclared globals, so it constructed
    `{nil, nil}`: an empty table that read as if it declared two constants. Dropped in the move,
    since nothing anywhere referenced either name.

`extract_term` assumes `initial_traverse` has run, which given the first fault means the pair has
never actually executed together.
@date 2026-09-12 01:25
]]


local ast = require("ast")

local transforms_old = {}

--[[
transforms_old.lua - TERM DRAGGING: moving a term from where it sits to where you want it, with the
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
function transforms_old.initial_traverse(node, parent, ploc)
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

function transforms_old.find(node, id)
    if node.id == id then
        return node
    end
    for i = 1, #node do
        local res = transforms_old.find(node[i], id)
        if res then
            return res
        end
    end
    return nil
end

--[[ assumes intial_traverse was called on root @date 2026-09-08 08:55 ]]
function transforms_old.extract_term(ns, node, mode)
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

return transforms_old

--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- | origins(root: mexpr node)               -> {ast id -> mexpr node}
-- | var_origins(ns: ast.ns, origins: {ast id -> mexpr node}) -> {VAR id -> mexpr node}
-- |     origins answers, for the nodes the parse stamped, where their ink is;
-- |     var_origins answers the looser question - any drawing of a use of
-- |     this variable - which is what lets a duplicated factor be copied
-- |     from a reference the source only wrote once.
-- |
-- | build(fontset: fontset, source_root: mexpr node | nil, ns: ast.ns, node: node, sz: size)
-- |       -> mexpr node | nil, reason
-- | container(fontset: fontset, source_root: mexpr node | nil, ns: ast.ns, node: node, sz: size)
-- |       -> mexpru.container | nil, reason
-- |     An ast tree written back out as glyphs, copying what was drawn for
-- |     anything with an IDENTITY and building the rest. `container` wraps
-- |     the row with a cursor and a version so an editor can hold it.
-- |     REFUSES BY NAME what it cannot write - divisions, the overprinted
-- |     \ne - because a refusal is a correct answer and a wrong drawing is
-- |     not. A DERIVATIVE it does write, as the fraction it is in notation,
-- |     bar green through mexpru.mark_diff; so are the GROUP BIG OPERATORS,
-- |     limits over and under, the plain relations a bigop's limit rows are
-- |     built from, and the INTEGRAL - its \int and closing d built as a
-- |     real bracket pair, bounds beside the sign.
-- |
-- | verify(fontset: fontset, container: mexpru.container, decls: {decl}, ns: ast.ns, node: node)
-- |       -> ok, want, got
-- |     Reparses what was built and compares shapes with what it was asked
-- |     to build. One parse, and it catches the whole class of bug that
-- |     matters here - a missing bracket, a dropped sign.
-- |
-- | --- internal, not on the module table ---------------------------------------------------------
-- |     new_write_ctx() THE ONE creator for the `ctx_write` every emit_* is handed
-- |     PREC/ATOM_PREC, glyph, glyph_desc, glyph_op, append, bracketed,
-- |     emit_ref, emit_digits, emit_num, emit_factors, emit_sum, emit_power,
-- |     emit_diff, emit_relation, emit_bigop, emit_int
-- |
-- | @date 2026-09-15 15:00
-- | ===============================================================================================
--]]

--[[
ast_mexpr.lua - the way BACK: an ast tree, written out as the mexpr tree that draws it.

THE DIRECTION mexpr_ast.lua does not go: that one reads glyphs and produces meaning, this one takes
meaning and produces glyphs - what a transformation needs the moment it has a result to show. The
mexpr is the artifact and the ast is scratch (docs/phase2_design.md), so nothing is finished until
it comes back through here.

TWO MECHANISMS, and which one applies is the whole design:

  - COPY, for anything with an IDENTITY. A variable's name is an assembled string (base text,
    dress suffix, primes, subscript) - an identity key, not a drawing - and re-rendering glyphs
    from it is a mistake this project already made once. A reference is written by copying the
    glyphs it was read from, which carries the accent, the size and the spacing for free;
    mexpr_ast records where they are (`u.ast_draws`).
  - BUILD, for STRUCTURE. Operators, brackets and digits have no identity to preserve - one `+` is
    every `+` - so they come from mexpru's plain constructors, the same ones typing uses.

NOT HERE YET, deliberately: divisions, the CELL, and the overprinted `\ne` - refused by name, like
anything else this file cannot draw. What it covers is what `distribute` can produce - sums,
products, whole numbers, references and powers - plus the DERIVATIVE (a fraction carrying `u.diff`,
through emit_diff), the GROUP BIG OPERATORS (\sum, \lim and the rest, limits over and under through
emit_bigop), the plain RELATIONS a bigop's limits are written with (k = 0, x \to 0, through
emit_relation), the CALL (callee letters and a cell-shaped bracket pair, emit_call) and the
INTEGRAL (its `\int` and closing `d` built as a real bracket pair, the bounds beside the sign,
through emit_int - found live 2026-09-16 as the reason a distribute inside an integral refused:
"cannot write a INT back yet"). A refusal is a correct answer; a wrong drawing is not.

THE SELF-CHECK IS PART OF THE CONTRACT: verify() reparses what was built and compares shapes with
what it was asked to build. It costs one parse and catches the class of bug that matters here - a
missing bracket, a dropped sign - as a mismatch rather than a formula that says something else
while looking reasonable. Every test in this area hangs off it.
@date 2026-09-14
]]

local vc = require("virt_composer")
local char = require("char")
local mexpru = require("mexpru")
local mformula_new = require("mformula_new")
local ast = require("ast")

local ast_mexpr = {}

--[[ Binding strength, and the only thing that decides where a bracket goes: THE INVERSE OF THE
PARSER'S CASCADE, so a child that binds LOOSER than the place it is written into must be bracketed
(`a*(b+c)` needs them, `a+(b*c)` does not) or reading it back finds a different tree. ATOM is what
a power's base must be - a run of several slots becomes one by being bracketed, and the exponent
rides on the closing bracket, which is how this editor has always drawn it.
@date 2026-09-12 02:00 ]]
local PREC = {
    [ast.ADD] = 1,
    [ast.MUL] = 2,
    [ast.DIFF] = 2,
    [ast.EXP] = 3,
}
--[[ A GROUP BIG OPERATOR binds at product strength for DRAWING purposes only: `d/dx \sum_i i^2`
writes the derivative's body against the sum unbracketed, and `(\sum_i i)^2` brackets it. In the
AST a bigop is NOT a term - it is an operator that declares variables; "sits like a factor" is a
fact about the mexpr row it draws into, and precedence is only ever the bracketing question
(the author, 2026-09-15). ]]
for node_type in pairs(ast.GROUP_BIGOP_DRAW) do
    PREC[node_type] = 2
end
PREC[ast.INT] = 2   -- the pair delimits its own body; to everything else it draws like a term
PREC[ast.CALL] = 2
PREC[ast.CELL] = 4   -- its brackets are always written, so it is an atom to everyone else

--[[ A relation's glyph, keyed by node type. Mirrors mexpr_ast's RELATIONS (desc -> constructor)
from the far side of the pair because the two face opposite directions and a constructor cannot
be inverted without calling it; they live in different files, so keep them in step by hand. NEQ
is absent ON PURPOSE: it draws as an overprinted pair (a zero-advance `\not` under the `=`), which
this writer does not build - it refuses, by name, as ever. ]]
local RELATION_DESC = {
    [ast.EQ] = "=", [ast.INEQ_LESS] = "<", [ast.INEQ_GREATER] = ">",
    [ast.INEQ_LEQ] = "\\le", [ast.INEQ_GEQ] = "\\ge", [ast.TENDS] = "\\rightarrow",
    [ast.IN] = "\\in", [ast.NI] = "\\ni", [ast.SUBSET] = "\\subset",
    [ast.SUBSETEQ] = "\\subseteq", [ast.SUPSET] = "\\supset",
    [ast.SUPSETEQ] = "\\supseteq",
}
local ATOM_PREC = 4

local function prec_of(node)
    return PREC[node.type] or ATOM_PREC
end

--[[ THE `ctx_write` CONTAINER - what every emit_* below is handed, and THE ONE CREATOR for it.
Named `ctx_write`, not `ctx`, because three containers in this project were called `ctx` and
`ctx.ns` meant a different thing in each. NOT SEALED: built here, read only by the emit_* locals,
dropped when the write finishes - if it ever leaves this file it should be sealed.
@date 2026-09-12 14:30 ]]
local function new_write_ctx(fontset, sz, origins, var_origins)
    return {fs = fontset, sz = sz, origins = origins, var_origins = var_origins}
end

--[[ One glyph, built the way every other glyph in this editor is: logical size on `u`, physical
size in the geometry (mexpru.rescale's own rule). Takes the catalog ENTRY, so the two lookups below
are one line each. @date 2026-09-14 ]]
local function glyph_of(ctx_write, entry)
    if not entry then
        return nil
    end
    local g = mexpru.mexpr_symbol(ctx_write.fs,
            {size = mexpru.physical_sz(ctx_write.sz), code = entry.ncod}, true)
    mexpru.u(g).sz = ctx_write.sz
    return g
end

local function glyph(ctx_write, ascii)
    return glyph_of(ctx_write, char.find_by_ascii(ascii))
end

--[[ The same, for a glyph that has no ascii key of its own - the centred dot. @date 2026-09-12 ]]
local function glyph_desc(ctx_write, desc)
    return glyph_of(ctx_write, char.find_by_desc(desc))
end

local function append(run, more)
    for _, n in ipairs(more) do
        run[#run + 1] = n
    end
    return run
end

--[[ `run`, wrapped in a round bracket pair that knows it is a pair. PLAIN GLYPHS PLUS A PEER LINK,
and nothing else - the SIZE of a bracket is not decided here: mexpru.horiz runs
resolve_bracket_pairs, which re-tiers a pair to fit what ended up between them, and building tall
glyphs here would be a second implementation of a rule that could not see its content. The peer is
a `u` TABLE, never a node - the established identity key, and it survives the rebuild.
@date 2026-09-12 02:00 ]]
local function bracketed(ctx_write, run)
    local open, close = glyph(ctx_write, "("), glyph(ctx_write, ")")
    if not open or not close then
        return nil, "no bracket glyphs in the font"
    end
    mexpru.u(open).bracket = {is_open = true, type = vc.MEXPR_BRACKET_ROUND,
            peer = mexpru.u(close)}
    mexpru.u(close).bracket = {is_open = false, type = vc.MEXPR_BRACKET_ROUND,
            peer = mexpru.u(open)}
    return append(append({open}, run), {close})
end

--[[ @brief ast id -> the mexpr node that DRAWS it, for one source tree.
-- |
-- | READ OFF THE TAGS mexpr_ast left (`u.ast_draws`), by walking the mexpr fresh each time, so
-- | nothing is stored between edits and nothing has to be invalidated.
-- |
-- | THE EDGES ARE mexpru.child_links, the one definition of "what is below this node" - an
-- | incomplete map would not be loud, only a decoration or a spacing quietly lost on a rebuild.
-- |
-- | @param root  mexpr node - checked; the tree the ast was parsed from
-- | @return {[ast id] = mexpr node} - only the nodes a tag names; an untagged node contributes
-- |         nothing, which the writer reads as "no copy available here"
-- |
-- | @date 2026-09-13 19:40
--]]
function ast_mexpr.origins(root)
    mexpru.check_node(root, "root")
    local out = {}
    -- THE EDGES COME FROM mexpru.child_links, never from a list written out here: a hand list is a
    -- second declaration of the node shape, free to fall behind, and an incomplete map is not loud.
    -- A nil CHILD is still guarded - most nodes have most links unset.
    local function walk(node)
        if not node then
            return
        end
        local u = mexpru.u(node)
        if u.ast_draws then
            out[u.ast_draws] = node
        end
        for _, child in ipairs(mexpru.child_links(node)) do
            walk(child)
        end
    end
    walk(root)
    return out
end

--[[ @brief VAR id -> a node drawing SOME reference to that variable.
-- |
-- | THE REASON A DUPLICATED FACTOR COSTS NOTHING. `a(b+c)` distributed writes `a` twice, and the
-- | second `a` is a fresh node with an id nothing was ever drawn for. But it references the SAME
-- | variable, and identity is what a name is - so any other reference to that variable is a
-- | correct drawing of it. Author, 2026-09-11: "all inside formulas are references or bounded
-- | variables".
-- |
-- | FROM THE NAMESPACE, NOT FROM THE TREE BEING WRITTEN. A transformation's result need not contain
-- | the original of every name it uses - distribute turns `a(b+c)` into `ab + a'c`, where `a'` is
-- | fresh - so walking the result would find no drawing for it. The namespace still holds every
-- | node the parse made.
-- |
-- | @details FIRST ONE WINS, arbitrarily and safely: every reference to one variable draws the same
-- |          name, or they would not be the same variable.
-- |
-- | @param ns       ast.ns - checked; required, since a missing namespace would read as "no
-- |                 references" and every name would be re-rendered instead of copied
-- | @param origins  {[ast id] = mexpr node} - as origins() built it; must be a table
-- | @return {[VAR id] = mexpr node}
-- |
-- | @date 2026-09-13 19:40
--]]
function ast_mexpr.var_origins(ns, origins)
    --[[ `if not ns or not ns.by_id then return out end` is gone. It turned a missing namespace into
    an EMPTY MAP, which is not a refusal - it is the same answer as "this tree has no references",
    so the writer would have gone on to re-render every name instead of copying it, and the only
    symptom would be decorations lost. A namespace is required here; say so. ]]
    ast.check_ns(ns)
    assert(type(origins) == "table",
            "var_origins needs an origins map, as ast_mexpr.origins builds")

    local out = {}
    for id, mexpr_node in pairs(origins) do
        --[[ `type(node) == "table"` used to guard this. ast.node_of answers a node or nil and
        nothing else, so the test is now just "did anything answer to that id". ]]
        local node = ast.node_of(ns, id)
        if node and node.type == ast.VREF and not out[node[1]] then
            out[node[1]] = mexpr_node
        end
    end
    return out
end

--[[ The glyphs for a reference: a copy of what it was written as. Refusing is the point - there is
no way to draw a name from its string, and a name this parse never saw drawn gets nil plus why.
@date 2026-09-12 02:00 ]]
local function emit_ref(ctx_write, node)
    local src = ctx_write.origins[node.id] or ctx_write.var_origins[node[1]]
    if not src then
        return nil, "nothing to copy for this name - it was never drawn in the source"
    end
    return {mformula_new.clone_node(ctx_write.fs, src)}
end

--[[ A whole number, as its digits - the one leaf with no identity to preserve: a `3` is every `3`,
so it is built rather than copied and nothing is lost. `sign` is handled by emit_num for a number
standing alone; inside a sum the sign IS the operator and emit_sum strips it first.
@date 2026-09-12 02:00 ]]
local function emit_digits(ctx_write, m)
    local run = {}
    for d in tostring(math.abs(m)):gmatch("%d") do
        run[#run + 1] = glyph(ctx_write, d)
    end
    return run
end

local function emit_num(ctx_write, node)
    local m, n, sign = node[1], node[2], node[3]
    if n ~= 1 then
        return nil, "only whole numbers can be written back so far (got "
                .. ast.num_text(node) .. ")"
    end
    local run = {}
    if (sign or 1) < 0 then
        run[#run + 1] = glyph(ctx_write, "-")
    end
    return append(run, emit_digits(ctx_write, m))
end

local emit    -- forward: the four below are mutually recursive with it

--[[ The factors of a product from index `from`, juxtaposed. WHEN A DOT IS NEEDED: `ab` needs
nothing between it, but `2 3` written as `23` is the number twenty-three - so a dot goes before any
numeric factor that is not the first. It never changes the meaning, and verify() proves it.
@date 2026-09-12 02:00 ]]
local function emit_factors(ctx_write, node, from)
    local run = {}
    for i = from, #node do
        local child = node[i]
        local sub, err = emit(ctx_write, child, PREC[ast.MUL])
        if not sub then
            return nil, err
        end
        if #run > 0 and child.type == ast.NUM then
            -- The centred dot the parser reads as multiplication (MUL_OPS), not an asterisk, which
            -- it reads as nothing at all.
            run[#run + 1] = glyph_desc(ctx_write, "\\cdot")
        end
        append(run, sub)
    end
    return run
end

--[[ A sum, with its terms' coefficients written as the operators they are.

Each term after the first carries its leading coefficient - the NUM a sign glyph tagged at the
parse; the first carries one only when it was itself signed. A UNIT coefficient is the sign and
contributes no digits (`-1 \cdot b` is spelled `-b`); any other keeps them (`-2b` needs its 2); a
bare number is its own coefficient and always writes its digits (`a + 1` is not `a +`). Writing
signs as operators rather than factors is the parse's own rule, so a writer that got it wrong
reads back as the SAME tree - verify() cannot catch this class, only this rule can.

REFUSES a fractional or infinite coefficient: only whole numbers can be written back so far.
@date 2026-09-15 ]]
local function emit_sum(ctx_write, node)
    local run = {}
    for i = 1, #node do
        local child = node[i]
        --[[ The term's leading coefficient, if it has one. `from` says where the remaining
        factors start: 2 inside a product, 0 when the bare number is the whole term, nil when
        the term carries no coefficient at all. ]]
        local coeff, from = nil, nil
        if child.type == ast.NUM then
            coeff, from = child, 0
        elseif child.type == ast.MUL and #child > 1 and child[1].type == ast.NUM then
            coeff, from = child[1], 2
        end
        if coeff and coeff[2] ~= 1 then
            return nil, "only whole numbers can be written back so far"
        end

        local negative = coeff and ((coeff[3] or 1) < 0)
        --[[ The operator glyph: every term after the first gets one. The first gets one only
        when its coefficient is negative, or a unit `+1` it cannot be written without - a plain
        `x` there would read back unsigned. ]]
        if i > 1 or negative or (coeff and from == 2 and coeff[1] == 1) then
            run[#run + 1] = glyph(ctx_write, negative and "-" or "+")
        end

        local part = {}
        if coeff and (from == 0 or coeff[1] ~= 1) then
            part = emit_digits(ctx_write, coeff[1])
        end
        local err
        if from == 2 then
            local tail
            tail, err = emit_factors(ctx_write, child, 2)
            if not tail then
                return nil, err
            end
            append(part, tail)
        elseif not coeff then
            part, err = emit(ctx_write, child, PREC[ast.ADD])
            if not part then
                return nil, err
            end
        end
        append(run, part)
    end
    return run
end

--[[ A power: the exponent rides on the base's LAST slot - which is the CLOSING BRACKET when the
base needed one, exactly how this editor draws and parses `(a+b)^{2}`. The exponent is a row of its
own, one size step smaller (SUB_SIZE_DELTA), so a built power and a typed one are the same tree.
@date 2026-09-12 02:00 ]]
local function emit_power(ctx_write, node)
    local base, err = emit(ctx_write, node[1], ATOM_PREC)
    if not base then
        return nil, err
    end
    local sup_sz = math.min(ctx_write.sz + mformula_new.SUB_SIZE_DELTA, mexpru.MAX_SIZE_INDEX)
    local inner
    inner, err = emit(new_write_ctx(ctx_write.fs, sup_sz, ctx_write.origins,
            ctx_write.var_origins), node[2], 1)
    if not inner then
        return nil, err
    end
    local carrier = base[#base]
    base[#base] = mexpru.supsub(ctx_write.fs, carrier,
            mexpru.horiz(ctx_write.fs, inner, sup_sz), nil,
            mexpru.u(carrier).sz or ctx_write.sz, mexpru.PLACE_BESIDE, mexpru.PLACE_BESIDE)
    return base
end

--[[ A catalog glyph WITH ITS SIZE BOOST, if it has one - the exact rule from_latex applies to
every macro it reads (its own push_char): `char.size_delta` says how many steps bigger the glyph
draws (`\int` is the one today), the glyph is built at that physical size, and `u.sz` keeps the
surrounding LOGICAL level so nothing downstream compounds on the boost. For a glyph with no boost
this is exactly `glyph_desc`. ]]
local function glyph_op(ctx_write, desc)
    local entry = char.find_by_desc(desc)
    if not entry then
        return nil
    end
    local delta = char.size_delta(entry.desc)
    local glyph_sz = delta and math.max(1, math.min(ctx_write.sz + delta,
            mexpru.MAX_SIZE_INDEX)) or ctx_write.sz
    local g = mexpru.mexpr_symbol(ctx_write.fs,
            {size = mexpru.physical_sz(glyph_sz), code = entry.ncod}, true)
    mexpru.u(g).sz = ctx_write.sz
    return g
end

--[[ A relation, flat: left, the relation's own glyph, right.

    k = 0        EQ(VREF k, NUM 0)          writes  k = 0
    x \to 0      TENDS(VREF x, NUM 0)       writes  x \to 0

NO BRACKETS ANYWHERE, because a relation never contains a relation (build_relation refuses the
second one) and its operands are whole expressions that reparse as whole expressions - the sum in
`a+b = c` writes with its plain `+` and reads back split on the `=`. A relation has exactly one
job in this writer today: a bigop's limit rows, where the reparse expects `i=0`, `i<n`,
`x \to 0` verbatim. NEQ is not here - it draws as an overprinted pair this writer does not build,
and refuses, by name, as ever. ]]
local function emit_relation(ctx_write, node)
    local desc = RELATION_DESC[node.type]
    if not desc then
        return nil, "cannot write a " .. (ast.type_name(node.type) or "?") .. " back yet"
    end
    local lhs, err = emit(ctx_write, node[1], 1)
    if not lhs then
        return nil, err
    end
    local rhs
    rhs, err = emit(ctx_write, node[2], 1)
    if not rhs then
        return nil, err
    end
    local g = glyph_desc(ctx_write, desc)
    if not g then
        return nil, "no glyph for " .. desc .. " in the font"
    end
    return append(append(lhs, {g}), rhs)
end

--[[ A group big operator, drawn the way typing draws it: the operator carrying its limits over
and under, the body as the rest of the term's factors.

    \sum_{i=0}^{n} i          SUM(n_vars=1, ..., sub EQ(i,0), sup VREF n, body i)
         ->  the \sum glyph, "i = 0" under it, "n" over it, then the body's glyphs
    \lim_{x \to 0} x          LIM(sub TENDS(x,0), body x)
         ->  a 1-tall vert spelling "lim", "x \to 0" under it, then the body

THE OPERATOR: a word ("lim", "argmax") builds the same 1-tall vert typing builds - loose letters
would reparse as a product; a glyph operator ("\\sum") builds its glyph WITH any size boost, the
from_latex rule. THE LIMITS are emitted by the ordinary emitters, so a name inside them copies
its ink through `origins` exactly as it does everywhere else - a copied `n` stays the drawn `n`,
not a rebuilt one; more than one constraint on a side becomes a VERT of rows, the one shape
constraint_rows reads back as several. THE BODY emits at product order, the settled bigop rule:
`\sum_i i^2` swallows its whole term, and an add-like body brackets itself through emit's own
precedence path. THE TUPLE'S VAR SLOTS ARE NOT EMITTED - a declaration has no ink; its ink is the
references (the `i` in `i=0`, the `i` in the body), which copy through the parse's tags.

No SOURCE node is taken beyond the standard maps: the operator, the vert and the limit rows are
built (one `\sum` is every `\sum`); the constraints and the body recurse through `emit`, and the
names inside them resolve through `origins`/`var_origins` - the reason a copied factor of a
distributed body still draws the user's own glyphs.
@date 2026-09-15 17:00 ]]
local function emit_bigop(ctx_write, node)
    local n_vars, n_sup, n_sub = node[1], node[2], node[3]
    local spelling = ast.GROUP_BIGOP_DRAW[node.type]

    local op
    if spelling:match("^%a+$") then
        -- A word operator: one row of letter glyphs in a 1-tall vert - what typing makes and
        -- operator_name validates on the way back in.
        local letters = {}
        for k = 1, #spelling do
            letters[#letters + 1] = glyph(ctx_write, spelling:sub(k, k))
        end
        op = mexpru.vert(ctx_write.fs,
                {mexpru.horiz(ctx_write.fs, letters, ctx_write.sz)}, ctx_write.sz)
    else
        op = glyph_op(ctx_write, spelling)
        if not op then
            return nil, "no glyph for " .. spelling .. " in the font"
        end
    end

    --[[ Each side's constraint rows: node[base+1] .. node[base+count]. One constraint is one row;
    several become a vert of rows, because constraint_rows reads exactly that back. An absent side
    (n == 0) answers nil and the supsub simply has no anchor there. ]]
    local function side(base, count)
        local rows = {}
        for k = 1, count do
            local run, err = emit(ctx_write, node[base + k], 1)
            if not run then
                return nil, err
            end
            rows[#rows + 1] = mexpru.horiz(ctx_write.fs, run, ctx_write.sz)
        end
        if count > 1 then
            return mexpru.vert(ctx_write.fs, rows, ctx_write.sz)
        end
        return rows[1]
    end
    local sup, err = side(3 + n_vars, n_sup)
    if not sup and err then
        return nil, err
    end
    local sub
    sub, err = side(3 + n_vars + n_sup, n_sub)
    if not sub and err then
        return nil, err
    end

    local head = mexpru.supsub(ctx_write.fs, op, sup, sub, ctx_write.sz,
            mexpru.PLACE_DISPLAY, mexpru.PLACE_DISPLAY)

    local body
    body, err = emit(ctx_write, node[#node], PREC[ast.MUL])
    if not body then
        return nil, err
    end
    return append({head}, body)
end

--[[ An integral, written as the pair it is read from: the `\int` glyph with its size boost and
its bounds beside it, the integrand between the halves, and the closing `d` - a real bracket half
carrying the peer link, because the reparse refuses an unpaired integral - with the variable
after it.

    \int_0^1 x dx      INT(var x, NUM 1, NUM 0, VREF x)   writes  the glyph, 1 over 0 beside it,
                                                                x, the d, x

THE VARIABLE IS CLONED, not built: the parse tags the `dx`'s own glyph with the var (read_integral),
so origins answers for it exactly as it does for a reference - and the clone carries the bound
blue the parse painted, the d is painted the differential green at the build, and the integrand's
caught mentions clone their own blue. A variable with no drawing anywhere is refused by name, as
every other uncopyable name is. NULL bounds (an indefinite integral) simply draw no sides.
@date 2026-09-16 16:00 ]]
local function emit_int(ctx_write, node)
    local open = glyph_op(ctx_write, "\\int")
    if not open then
        return nil, "no glyph for \\int in the font"
    end
    local close = glyph(ctx_write, "d")
    if not close then
        return nil, "no glyph for d in the font"
    end
    -- THE PAIR, the same peer links `bracketed` builds: the reparse finds the close BY PEER.
    mexpru.u(open).bracket = {is_open = true, type = char.BRACKET_INTEGRAL,
            peer = mexpru.u(close)}
    mexpru.u(close).bracket = {is_open = false, type = char.BRACKET_INTEGRAL,
            peer = mexpru.u(open)}
    close.color = mexpru.DIFF_COLOR

    --[[ The bounds ride the halves at the size a typed supsub uses, rebound the way emit_power
    rebinds its exponent - the glyph's own size is what draws, not the row's. A NULL bound is no
    side at all. ]]
    local sup_sz = math.min(ctx_write.sz + mformula_new.SUB_SIZE_DELTA, mexpru.MAX_SIZE_INDEX)
    local bound_ctx = new_write_ctx(ctx_write.fs, sup_sz, ctx_write.origins,
            ctx_write.var_origins)
    local function side(bound)
        if bound.type == ast.NULL then
            return nil
        end
        local run, err = emit(bound_ctx, bound, 1)
        if not run then
            return nil, err
        end
        return mexpru.horiz(ctx_write.fs, run, sup_sz)
    end
    local sup, err = side(node[2])
    if not sup and err then
        return nil, err
    end
    local sub
    sub, err = side(node[3])
    if not sub and err then
        return nil, err
    end

    local var = ctx_write.origins[node[1].id] or ctx_write.var_origins[node[1].id]
    if not var then
        return nil, "nothing to copy for the differential's variable - it was never drawn in "
                .. "the source"
    end
    local var_run = {mformula_new.clone_node(ctx_write.fs, var)}

    local body, berr = emit(ctx_write, node[4], 1)
    if not body then
        return nil, berr
    end

    local head = mexpru.supsub(ctx_write.fs, open, sup, sub, ctx_write.sz,
            mexpru.PLACE_BESIDE, mexpru.PLACE_BESIDE)
    local run = {head}
    append(run, body)
    run[#run + 1] = close
    append(run, var_run)
    return run
end

--[[ A CELL, written as exactly what it is: its brackets, around its content's glyphs.

    af(x)   MUL(a, f, CELL(x))   writes  a f ( x )   - the user's own parens, kept and given back

THE BRACKETS ARE ALWAYS WRITTEN, never absorbed by precedence, because a CELL exists precisely
because the parens were NOT implied - the parse kept them as the user's grouping (maybe_cell's own
note), and writing them back is the whole point: `af(x)` stays `af(x)` through a transform
instead of collapsing to `afx` (found live 2026-09-16 on exactly that distribute). The reparse
agrees from the other side: a juxtaposed group re-reads as a CELL, so the round trip holds.
@date 2026-09-16 10:30 ]]
local function emit_cell(ctx_write, node)
    local inner, err = emit(ctx_write, node[1], 1)
    if not inner then
        return nil, err
    end
    return bracketed(ctx_write, inner)
end

--[[ A call: the callee's name, then the arguments inside ONE bracket pair that is a CELL's ink.

    f(x)        CALL("f(),(1)", VREF x)     writes  f ( x )   - name glyphs, then a cell-shaped
                                                                     bracket pair around the args
    f(x,y)      CALL(key, x, y)             writes  f ( x , y ) - a comma between the args

THE EXTRA PARENTHESIS IS A CELL, by the author's ruling (2026-09-16): a call's brackets are the
user's own grouping - ordinary glyph pairs with peer links, what `bracketed` builds - not some
call-specific notation. The reparse agrees: with `f` declared above, the name extent swallows the
bracket group and resolve_use rebuilds the CALL, so the round trip holds; without the declaration
the brackets promote away exactly as a cell's would, and the formula reads as juxtaposition - the
reading it always had.

THE NAME IS EMITTED, NOT COPIED: the CALL node carries only the declaration's key (a string), not
the glyphs it was read from, and the parse's `ast_draws` tags were never written for a resolved
name. That is a loss for a DRESSED callee (`F\vec(x)` would re-render without its accent, which
is the mistake the whole copy-don't-render rule exists to prevent), so anything but plain letters,
digits and underscores is REFUSED by name until the parse tags the base glyphs and this can clone
them - a refusal today, not a quietly wrong drawing.
@date 2026-09-16 10:00 ]]
local function emit_call(ctx_write, node)
    local name = tostring(node[1]):match("^([^%(]*)%(")
    if name then
        name = name:gsub("^'", ""):gsub("'$", "")
    end
    if not name or name == "" or name:find("[^%w_]") then
        return nil, "cannot write the callee `" .. tostring(node[1]) .. "` back yet"
    end

    local run = {}
    for k = 1, #name do
        local g = glyph(ctx_write, name:sub(k, k))
        --[[ THE CALLEE LETTERS WEAR THE DECLARED-NAME ORANGE (mexpru's constant), the colour the
        parse puts on a name that resolves: a written call is a use of a declaration by
        construction - the key came from one - and a child box showing it plain would say
        undeclared. The argument glyphs below keep the default; the root alone is the name. ]]
        if g then
            g.color = mexpru.DECL_NAME_COLOR
        end
        run[#run + 1] = g
    end

    local inner = {}
    for k = 2, #node do
        if k > 2 then
            local comma = glyph(ctx_write, ",")
            if not comma then
                return nil, "no comma glyph in the font"
            end
            inner[#inner + 1] = comma
        end
        local part, err = emit(ctx_write, node[k], 1)
        if not part then
            return nil, err
        end
        append(inner, part)
    end
    return append(run, bracketed(ctx_write, inner))
end

--[[ A derivative, drawn as the fraction it is in notation: the sign over the sign and the
variables, the body following as the rest of the term's factors.

THE FRACTION CARRIES THE ONE BIT (mexpru.mark_diff), which tints the bar green - the only visual
difference from a division - and the signs are PLAIN letter-d glyphs (or ∂), exactly the glyphs
the parse re-reads. A variable whose name is longer than one letter - a dress is part of a name -
is refused rather than drawn without it: dropping a dress would write a different variable than
the node binds. The order rides the numerator's sign as a superscript, the slot typing puts one in.
@date 2026-09-15 15:00 ]]
local function emit_diff(ctx_write, node)
    local partial, order = node[1] == 1, node[2]
    local n_vars = node[3]
    local sign = partial and glyph_desc(ctx_write, "\\partial") or glyph(ctx_write, "d")

    local num
    if order > 1 then
        --[[ THE ORDER'S DIGITS ARE BUILT AT THE SMALL SIZE, by rebinding the ctx the way
        emit_power does - not by wrapping full-size glyphs in a small horiz, which was this
        function's own bug: emit_digits builds at ctx_write.sz, so a horiz at sup_sz around them
        changed nothing and the 2 of d^2 drew full-size (found 2026-09-15, reported as "the 2 is
        not drawn in a smaller font"). The glyph's own size is what draws, not the row's. ]]
        local sup_sz = math.min(ctx_write.sz + mformula_new.SUB_SIZE_DELTA,
                mexpru.MAX_SIZE_INDEX)
        num = {mexpru.supsub(ctx_write.fs, sign,
                mexpru.horiz(ctx_write.fs,
                        emit_digits(new_write_ctx(ctx_write.fs, sup_sz, ctx_write.origins,
                                ctx_write.var_origins), order), sup_sz), nil,
                mexpru.u(sign).sz or ctx_write.sz, mexpru.PLACE_BESIDE, mexpru.PLACE_BESIDE)}
    else
        num = {sign}
    end

    local den = {partial and glyph_desc(ctx_write, "\\partial") or glyph(ctx_write, "d")}
    for k = 1, n_vars do
        local name = node[3 + k]
        if #name ~= 1 then
            return nil, "cannot write the variable `" .. name .. "` in a differential yet"
        end
        den[#den + 1] = glyph(ctx_write, name)
    end

    local frac = mexpru.frac(ctx_write.fs, mexpru.horiz(ctx_write.fs, num, ctx_write.sz),
            mexpru.horiz(ctx_write.fs, den, ctx_write.sz), ctx_write.sz)
    mexpru.mark_diff(frac, true)

    local run = {frac}
    local body, err = emit(ctx_write, node[4 + n_vars], PREC[ast.MUL])
    if not body then
        return nil, err
    end
    append(run, body)
    return run
end

--[[ One ast node as a RUN of row slots - a list, not a node, because that is what a sum or a
product is in this model. `min_prec` is what the surrounding context requires; a node binding
looser than that is bracketed here, in ONE place, rather than at each site that could need it.
@date 2026-09-12 02:00 ]]
emit = function(ctx_write, node, min_prec)
    if type(node) ~= "table" or not node.type then
        return nil, "not an ast node: " .. tostring(node)
    end

    local run, err
    if node.type == ast.VREF then
        run, err = emit_ref(ctx_write, node)
    elseif node.type == ast.NUM then
        run, err = emit_num(ctx_write, node)
    elseif node.type == ast.MUL then
        local c = node[1]
        if #node > 1 and c.type == ast.NUM and c[2] == 1 and c[1] == 1 then
            -- A lone unit coefficient is written as the sign it is: `-x`, not `-1 \cdot x`. The
            -- sign must be written at all - a plain `x` would read back without the coefficient.
            local signed = {glyph(ctx_write, ((c[3] or 1) < 0) and "-" or "+")}
            local tail
            tail, err = emit_factors(ctx_write, node, 2)
            if not tail then
                return nil, err
            end
            run = append(signed, tail)
        else
            run, err = emit_factors(ctx_write, node, 1)
        end
    elseif node.type == ast.DIFF then
        run, err = emit_diff(ctx_write, node)
    elseif node.type == ast.INT then
        run, err = emit_int(ctx_write, node)
    elseif ast.GROUP_BIGOP_DRAW[node.type] then
        run, err = emit_bigop(ctx_write, node)
    elseif RELATION_DESC[node.type] then
        run, err = emit_relation(ctx_write, node)
    elseif node.type == ast.CALL then
        run, err = emit_call(ctx_write, node)
    elseif node.type == ast.CELL then
        run, err = emit_cell(ctx_write, node)
    elseif node.type == ast.ADD then
        run, err = emit_sum(ctx_write, node)
    elseif node.type == ast.EXP then
        run, err = emit_power(ctx_write, node)
    else
        return nil, "cannot write a " .. (ast.type_name(node.type) or "?") .. " back yet"
    end
    if not run then
        return nil, err
    end
    if prec_of(node) < (min_prec or 1) then
        return bracketed(ctx_write, run)
    end
    return run
end

--[[ @brief An ast tree as a formula's root row, drawn the way its source was.
-- |
-- | THE NAMES' GLYPHS ARE COPIED, never drawn from a string: `source_root` is the mexpr the tree
-- | was PARSED from and `ns` that parse's namespace, and together they are the only place a name's
-- | glyphs can come from. What has no identity - digits, operators, brackets - is built fresh.
-- |
-- | REFUSES rather than drawing wrong: a node type it cannot write, or a name with nothing to copy.
-- | Brackets go in exactly where precedence needs them.
-- |
-- | @param fontset      fontset
-- | @param source_root  mexpr node | nil - checked when given. nil means no source drawing, and
-- |                     anything with a name in it is refused - correct rather than convenient
-- | @param ns           ast.ns - checked; required
-- | @param node         node - checked; the tree to write
-- | @param sz           size | nil - defaults to mexpru.DEFAULT_SIZE
-- | @return mexpr node | nil, string - the root row, positions already updated since nothing
-- |         downstream can measure an unlaid tree; or nil and the reason
-- |
-- | @date 2026-09-13 19:40
--]]
function ast_mexpr.build(fontset, source_root, ns, node, sz)
    ast.check_ns(ns)
    ast.check_node(node, "node")
    --[[ `source_root` is OPTIONAL - nil means there is no source drawing to copy from, which is a
    real case: a tree built from scratch has nothing to inherit. Checked only when given. ]]
    if source_root ~= nil then
        mexpru.check_node(source_root, "source_root")
    end
    sz = sz or mexpru.DEFAULT_SIZE
    local origins = source_root and ast_mexpr.origins(source_root) or {}
    local ctx_write = new_write_ctx(fontset, sz, origins, ast_mexpr.var_origins(ns, origins))
    local run, err = emit(ctx_write, node, 1)
    if not run then
        return nil, err
    end
    local root = mexpru.horiz(fontset, run, sz)
    mexpru.update_positions(root)
    return root
end

--[[ @brief build(), as a container the editors can hold.
-- |
-- | THE CURSOR STARTS AT THE END of the row: the transformed cell has to open with the caret
-- | somewhere real, and "after everything" is the one position that exists for every tree.
-- |
-- | @param fontset      fontset
-- | @param source_root  mexpr node | nil - as for build
-- | @param ns           ast.ns - as for build
-- | @param node         node - as for build
-- | @param sz           size | nil - as for build
-- | @return mexpru.container | nil, string - a fresh one at version 0; or build's refusal
-- |
-- | @date 2026-09-13 19:40
--]]
function ast_mexpr.container(fontset, source_root, ns, node, sz)
    local root, err = ast_mexpr.build(fontset, source_root, ns, node, sz)
    if not root then
        return nil, err
    end
    return mexpru.new_container(root, mexpru.last_slot(root))
end

--[[ @brief Does the built mexpr parse back to the tree it was built from?
-- |
-- | THE CHECK THAT MAKES THE WRITER TRUSTWORTHY: "did I draw what I meant" is one parse and one
-- | string compare. It catches precisely what a writer gets wrong - a bracket that was needed and
-- | not written, a sign that became a factor - which produce a formula that says something else
-- | while looking entirely reasonable.
-- |
-- | SHAPES, NOT IDS (ast.shape): the rebuilt tree is parsed into a NEW namespace, so no id can
-- | match. Names can and do, which is what identity means here.
-- |
-- | @param fontset    fontset
-- | @param container  mexpru.container - checked; what build/container produced
-- | @param decls      {mexpr_ast.decl} | nil - to parse it back with; nil is none
-- | @param ns         ast.ns - checked; the namespace `node` lives in
-- | @param node       node - checked; the tree it was built from
-- | @return boolean, string, string - whether the shapes match, then both shapes - the caller
-- |         prints them, since a diff of two shapes is the only useful thing to say on failure. A
-- |         container that does not parse gives false and "did not parse: <reason>" as `got`
-- |
-- | @date 2026-09-13 19:40
--]]
function ast_mexpr.verify(fontset, container, decls, ns, node)
    mexpru.check_container(container)
    ast.check_ns(ns)
    ast.check_node(node, "node")
    local mexpr_ast = require("mexpr_ast")
    local want = ast.shape(ns, node)
    local reparsed, err, new_ns = mexpr_ast.build(fontset, container, decls or {})
    if not reparsed then
        return false, want, "did not parse: " .. tostring(err)
    end
    local got = ast.shape(new_ns, reparsed)
    return want == got, want, got
end

return ast_mexpr

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
-- |     REFUSES BY NAME what it cannot write - fractions, calls, big
-- |     operators, relations - because a refusal is a correct answer and a
-- |     wrong drawing is not.
-- |
-- | verify(fontset: fontset, container: mexpru.container, decls: {decl}, ns: ast.ns, node: node)
-- |       -> ok, want, got
-- |     Reparses what was built and compares shapes with what it was asked
-- |     to build. One parse, and it catches the whole class of bug that
-- |     matters here - a missing bracket, a dropped sign.
-- |
-- | --- internal, not on the module table ---------------------------------------------------------
-- |     new_write_ctx() THE ONE creator for the `ctx_write` every emit_* is handed
-- |     PREC/ATOM_PREC, glyph, glyph_desc, append, bracketed, emit_ref,
-- |     emit_digits, emit_num, emit_factors, emit_sum, emit_power
-- |
-- | @date 2026-09-14 11:00
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

NOT HERE YET, deliberately: fractions, calls, big operators, integrals, relations, and the CELL -
refused by name, like anything else this file cannot draw. What it covers is what `distribute` can
produce: sums, products, whole numbers, references and powers. A refusal is a correct answer; a
wrong drawing is not.

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
    [ast.EXP] = 3,
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

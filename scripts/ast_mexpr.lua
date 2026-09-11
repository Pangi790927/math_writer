--[[
ast_mexpr.lua - the way BACK: an ast tree, written out as the mexpr tree that draws it.

THE DIRECTION mexpr_ast.lua does not go. That one reads glyphs and produces meaning; this one takes
meaning and produces glyphs, which is what a transformation needs the moment it has a result to show.
The mexpr is the artifact and the ast is scratch (docs/phase2_design.md), so nothing is finished
until it comes back through here.

TWO MECHANISMS, AND WHICH ONE APPLIES IS THE WHOLE DESIGN:

  - COPY, for anything with an IDENTITY. A variable's name is an assembled string - base text, dress
    suffix, primes, subscript - which is an identity key and not a drawing. Re-rendering glyphs from
    it is the mistake the definition row already made once, drawing the arrow beside the `F` instead
    of over it. So a reference is written by copying the glyphs it was read from, which also carries
    the accent, the size and the spacing for free. mexpr_ast records where that is (`u.ast_draws`).
  - BUILD, for STRUCTURE. Operators, brackets and digits have no identity to preserve - one `+` is
    every `+` - so they are constructed from mexpru's plain constructors, the same ones typing uses.

WHAT IS NOT HERE YET, deliberately: fractions, calls, big operators, integrals, relations. This file
covers what `distribute` can produce - sums, products, whole numbers, references and powers - and
refuses, by name, anything else. A refusal is a correct answer; a wrong drawing is not.

THE SELF-CHECK IS PART OF THE CONTRACT. verify() reparses what was built and compares shapes with
what it was asked to build. We own both directions, it costs one parse, and it catches the one class
of bug that matters here - a missing bracket, a dropped sign - as a mismatch rather than as a formula
that says something else. Every test in this area hangs off it.
@date 2026-09-12 02:00
]]

local vc = require("virt_composer")
local char = require("char")
local mexpru = require("mexpru")
local mformula_new = require("mformula_new")
local ast = require("ast")

local ast_mexpr = {}

--[[ Binding strength, and the only thing that decides where a bracket goes.

THE INVERSE OF THE PARSER'S CASCADE (build_sum -> build_product -> read_factor), which is why the
numbers are in that order and not in some table of their own invention: a child that binds LOOSER
than the place it is being written into must be bracketed, or reading it back finds a different
tree. `a*(b+c)` needs them; `a+(b*c)` does not.

ATOM is what a power's base must be: `a^{2}` puts the exponent on ONE slot, so a base that is a run
of several has to become one by being bracketed - and then the exponent rides on the closing
bracket, which is how this editor has always drawn it.
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

--[[ One glyph, built the way every other glyph in this editor is: logical size on `u`, physical size
in the geometry (mexpru.rescale's own rule). @date 2026-09-12 02:00 ]]
local function glyph(ctx, ascii)
    local entry = char.find_by_ascii(ascii)
    if not entry then
        return nil
    end
    local g = mexpru.mexpr_symbol(ctx.fs,
            {size = mexpru.physical_sz(ctx.sz), code = entry.ncod}, true)
    mexpru.u(g).sz = ctx.sz
    return g
end

--[[ The same, for a glyph that has no ascii key of its own - the centred dot. @date 2026-09-12 ]]
local function glyph_desc(ctx, desc)
    local entry = char.find_by_desc(desc)
    if not entry then
        return nil
    end
    local g = mexpru.mexpr_symbol(ctx.fs,
            {size = mexpru.physical_sz(ctx.sz), code = entry.ncod}, true)
    mexpru.u(g).sz = ctx.sz
    return g
end

local function append(run, more)
    for _, n in ipairs(more) do
        run[#run + 1] = n
    end
    return run
end

--[[ `run`, wrapped in a round bracket pair that knows it is a pair.

PLAIN GLYPHS PLUS A PEER LINK, and nothing else: the SIZE of a bracket is not decided here. Both
halves go in as ordinary "(" and ")" with `u.bracket` set, and mexpru.horiz - which every run passes
through - runs resolve_bracket_pairs, which is what re-tiers a pair to fit what ended up between
them. Building tall glyphs here would be a second implementation of that rule, and one that could
not see the content it had to fit.

THE PEER IS A `u` TABLE, never a node: that is the established identity key, it survives the rebuild
that resolve_bracket_pairs performs, and it holds nothing weakly-referenced.
@date 2026-09-12 02:00 ]]
local function bracketed(ctx, run)
    local open, close = glyph(ctx, "("), glyph(ctx, ")")
    if not open or not close then
        return nil, "no bracket glyphs in the font"
    end
    mexpru.u(open).bracket = {is_open = true, type = vc.MEXPR_BRACKET_ROUND,
            peer = mexpru.u(close)}
    mexpru.u(close).bracket = {is_open = false, type = vc.MEXPR_BRACKET_ROUND,
            peer = mexpru.u(open)}
    return append(append({open}, run), {close})
end

--[[ id -> the mexpr node that DRAWS it, for one source tree.

Built by walking the mexpr and reading the tags mexpr_ast left (`u.ast_draws`), fresh each time, so
nothing is stored between edits and nothing has to be invalidated. The walk is per-kind because a
mexpr's children live under different names per kind; an unknown kind simply contributes nothing,
which is the right failure - it means "no copy available here", and the caller then refuses.
@date 2026-09-12 02:00 ]]
function ast_mexpr.origins(root)
    local out = {}
    local function walk(node)
        if not node then
            return
        end
        local u = mexpru.u(node)
        if not u then
            return
        end
        if u.ast_draws then
            out[u.ast_draws] = node
        end
        for _, child in ipairs(u.children or {}) do
            walk(child)
        end
        for _, slot in ipairs(u.slots or {}) do
            walk(slot)
        end
        walk(u.base)
        walk(u.sup)
        walk(u.sub)
        walk(u.target)
        walk(u.num)
        walk(u.den)
    end
    walk(root)
    return out
end

--[[ VAR id -> a node drawing SOME reference to that variable.

THE REASON A DUPLICATED FACTOR COSTS NOTHING. `a(b+c)` distributed writes `a` twice, and the second
`a` is a fresh node with an id nothing was ever drawn for. But it references the SAME variable, and
identity is what a name is - so any other reference to that variable is a correct drawing of it.
Author, 2026-09-11, on why duplication is not a problem here: "all inside formulas are references or
bounded variables".

FROM THE NAMESPACE, NOT FROM THE TREE BEING WRITTEN, and that is the whole correctness of it. A
transformation's result need not contain the original of every name it uses: distribute reuses the
first term's nodes and COPIES the rest, so `a(b+c)` becomes `ab + a'c'` where both primed nodes are
fresh. Walking the result would find no drawing for `c` and refuse a name that is written right
there in the source. The namespace still holds every node the parse made, so every name that was
ever drawn is reachable through it.

FIRST ONE WINS, arbitrarily and safely: every reference to one variable draws the same name, or they
would not be the same variable.
@date 2026-09-12 02:30 ]]
function ast_mexpr.var_origins(ns, origins)
    local out = {}
    if not ns or not ns.by_id then
        return out
    end
    for id, mexpr_node in pairs(origins) do
        local node = ns.by_id[id]
        if type(node) == "table" and node.type == ast.VREF and not out[node[1]] then
            out[node[1]] = mexpr_node
        end
    end
    return out
end

--[[ The glyphs for a reference: a copy of what it was written as. nil plus a reason when there is
nothing to copy - a name this parse never saw drawn, which today means a declared name (whose spans
are not recorded yet). Refusing is the point: there is no way to draw a name from its string.
@date 2026-09-12 02:00 ]]
local function emit_ref(ctx, node)
    local src = ctx.origins[node.id] or ctx.var_origins[node[1]]
    if not src then
        return nil, "nothing to copy for this name - it was never drawn in the source"
    end
    return {mformula_new.clone_node(ctx.fs, src)}
end

--[[ A whole number, as its digits. Numbers are the one leaf with no identity to preserve: a `3` is
every `3`, so it is built rather than copied and nothing is lost.

REFUSES A FRACTION (n ~= 1) and INFINITY (n == 0), which are real numbers this file cannot draw yet -
a fraction needs mexpru.mexpr_frac and a stage this is not at. `sign` is handled here only for a
number standing alone; inside a sum the sign IS the operator and emit_sum strips it first.
@date 2026-09-12 02:00 ]]
local function emit_digits(ctx, m)
    local run = {}
    for d in tostring(math.abs(m)):gmatch("%d") do
        run[#run + 1] = glyph(ctx, d)
    end
    return run
end

local function emit_num(ctx, node)
    local m, n, sign = node[1], node[2], node[3]
    if n ~= 1 then
        return nil, "only whole numbers can be written back so far (got "
                .. ast.num_text(node) .. ")"
    end
    local run = {}
    if (sign or 1) < 0 then
        run[#run + 1] = glyph(ctx, "-")
    end
    return append(run, emit_digits(ctx, m))
end

local emit    -- forward: the four below are mutually recursive with it

--[[ The factors of a product from index `from`, juxtaposed.

WHEN A DOT IS NEEDED. Juxtaposition is multiplication here, so `ab` needs nothing between it - but
`2 3` written as `23` is the number twenty-three, and `a 2` risks reading as one name once names may
be several glyphs long. The rule is therefore CONSERVATIVE: a dot before any numeric factor that is
not the first. It never changes the meaning, and re-parsing proves it - which is what verify() is
for.
@date 2026-09-12 02:00 ]]
local function emit_factors(ctx, node, from)
    local run = {}
    for i = from, #node do
        local child = node[i]
        local sub, err = emit(ctx, child, PREC[ast.MUL])
        if not sub then
            return nil, err
        end
        if #run > 0 and child.type == ast.NUM then
            -- The centred dot the parser reads as multiplication (MUL_OPS), not an asterisk, which
            -- it reads as nothing at all.
            run[#run + 1] = glyph_desc(ctx, "\\cdot")
        end
        append(run, sub)
    end
    return run
end

--[[ Is this term of a sum a NEGATIVE one, and what are its factors without the sign?

WHY IT HAS TO BE ASKED. The parser puts a term's sign on its leading NUM - `a-b` is
ADD(a, MUL(NUM(-1), b)) - so a writer that simply put `+` between the terms would produce
`a + -1 \cdot b`. It reads back as the same tree, which is exactly why only a rule, not the
self-check, can catch it.

Returns (negative, node, from): `from` is where emit_factors should start, which skips a bare -1
because `-1 \cdot b` is spelled `-b`, and keeps the digits of anything else because `-2b` needs its
2. A negative NUM standing alone as a term is the third case and needs no product at all.
@date 2026-09-12 02:00 ]]
local function negative_term(child)
    if child.type == ast.NUM then
        return (child[3] or 1) < 0
    end
    if child.type == ast.MUL and child[1] and child[1].type == ast.NUM then
        return (child[1][3] or 1) < 0
    end
    return false
end

--[[ A sum, with its signs written as the operators they are. @date 2026-09-12 02:00 ]]
local function emit_sum(ctx, node)
    local run, err = emit(ctx, node[1], PREC[ast.ADD])
    if not run then
        return nil, err
    end
    for i = 2, #node do
        local child = node[i]
        local negative = negative_term(child)
        run[#run + 1] = glyph(ctx, negative and "-" or "+")

        local part
        if not negative then
            part, err = emit(ctx, child, PREC[ast.ADD])
        elseif child.type == ast.NUM then
            -- The sign became the operator, so the number itself is written unsigned.
            if child[2] ~= 1 then
                return nil, "only whole numbers can be written back so far"
            end
            part = emit_digits(ctx, child[1])
        else
            local coefficient = child[1]
            if coefficient[2] ~= 1 then
                return nil, "only whole numbers can be written back so far"
            end
            --[[ `-1 \cdot b` is spelled `-b`: a unit coefficient is the sign and nothing else, so
            it contributes no digits. Any other coefficient keeps its own. ]]
            part = (coefficient[1] == 1) and {} or emit_digits(ctx, coefficient[1])
            local tail
            tail, err = emit_factors(ctx, child, 2)
            part = tail and append(part, tail) or nil
        end
        if not part then
            return nil, err
        end
        append(run, part)
    end
    return run
end

--[[ A power: the exponent rides on the base's LAST slot.

THAT LAST SLOT IS THE CLOSING BRACKET when the base needed one, and that is not a trick - it is how
this editor draws and parses `(a+b)^{2}`, established long before there was an ast to write back.
So bracketing happens first, through the ordinary precedence path, and whatever the base run ends
with becomes the supsub's base.

THE EXPONENT IS A ROW OF ITS OWN, one size step smaller - the same step typing produces
(mformula_new.SUB_SIZE_DELTA), so a built power and a typed one are the same tree.
@date 2026-09-12 02:00 ]]
local function emit_power(ctx, node)
    local base, err = emit(ctx, node[1], ATOM_PREC)
    if not base then
        return nil, err
    end
    local sup_sz = math.min(ctx.sz + mformula_new.SUB_SIZE_DELTA, mexpru.MAX_SIZE_INDEX)
    local inner
    inner, err = emit({fs = ctx.fs, sz = sup_sz, origins = ctx.origins,
            var_origins = ctx.var_origins}, node[2], 1)
    if not inner then
        return nil, err
    end
    local carrier = base[#base]
    base[#base] = mexpru.supsub(ctx.fs, carrier, mexpru.horiz(ctx.fs, inner, sup_sz), nil,
            mexpru.u(carrier).sz or ctx.sz, mexpru.PLACE_BESIDE, mexpru.PLACE_BESIDE)
    return base
end

--[[ One ast node as a RUN of row slots - a list, not a node, because that is what a sum or a product
is in this model: several slots of one row, with no node of their own.

`min_prec` is what the surrounding context requires; a node binding looser than that is bracketed
here, in one place, rather than at each site that could need it.
@date 2026-09-12 02:00 ]]
emit = function(ctx, node, min_prec)
    if type(node) ~= "table" or not node.type then
        return nil, "not an ast node: " .. tostring(node)
    end

    local run, err
    if node.type == ast.VREF then
        run, err = emit_ref(ctx, node)
    elseif node.type == ast.NUM then
        run, err = emit_num(ctx, node)
    elseif node.type == ast.MUL then
        run, err = emit_factors(ctx, node, 1)
    elseif node.type == ast.ADD then
        run, err = emit_sum(ctx, node)
    elseif node.type == ast.EXP then
        run, err = emit_power(ctx, node)
    else
        return nil, "cannot write a " .. (ast.type_name(node.type) or "?") .. " back yet"
    end
    if not run then
        return nil, err
    end
    if prec_of(node) < (min_prec or 1) then
        return bracketed(ctx, run)
    end
    return run
end

--[[ An ast tree as a formula's root row, drawn the way its source was.

`source_root` is the mexpr the tree was PARSED from and `ns` that parse's namespace - together they
are the only place the names' glyphs can come from. Pass nil for either and anything with a name in
it is refused, which is correct rather than convenient.

Returns the root node, or nil plus a reason. Positions are updated here, since nothing downstream
can measure a tree that has never been laid out.
@date 2026-09-12 02:00 ]]
function ast_mexpr.build(fontset, source_root, ns, node, sz)
    sz = sz or mexpru.DEFAULT_SIZE
    local origins = source_root and ast_mexpr.origins(source_root) or {}
    local ctx = {
        fs = fontset,
        sz = sz,
        origins = origins,
        var_origins = ast_mexpr.var_origins(ns, origins),
    }
    local run, err = emit(ctx, node, 1)
    if not run then
        return nil, err
    end
    local root = mexpru.horiz(fontset, run, sz)
    mexpru.update_positions(root)
    return root
end

--[[ Same thing, as a container the editors can hold: root, a cursor, and a version.

The cursor starts at the END of the row, where a caret lands after anything is inserted - the
transformed cell has to open with the caret somewhere real, and "after everything" is the one
position that exists for every tree.
@date 2026-09-12 02:00 ]]
function ast_mexpr.container(fontset, source_root, ns, node, sz)
    local root, err = ast_mexpr.build(fontset, source_root, ns, node, sz)
    if not root then
        return nil, err
    end
    local children = mexpru.u(root).children
    return {
        root = root,
        cursor_pos = vc.wref_mexpr(children[#children] or root),
        version = 0,
    }
end

--[[ Does the built mexpr parse back to the tree it was built from?

THE CHECK THAT MAKES THE WRITER TRUSTWORTHY, and the reason it can be this cheap: both directions
live here, so the question "did I draw what I meant" is one parse and one string compare. What it
catches is precisely what a writer gets wrong - a bracket that was needed and not written, a sign
that became a factor - and those produce a formula that says something else while looking entirely
reasonable.

SHAPES, NOT IDS (ast.shape): the rebuilt tree is parsed into a NEW namespace, so no id can match.
Names can and do, which is what identity means here.

Returns true, or false plus both shapes - the caller prints them, because a diff of two shapes is the
only useful thing to say when this fails.
@date 2026-09-12 02:00 ]]
function ast_mexpr.verify(fontset, container, decls, ns, node)
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

--[[ ==================================== WHAT THIS FILE OFFERS ====================================
-- |
-- | The parse
-- | build(fontset: fontset, container: mexpru.container, decls: {decl}, ns: ast.ns)
-- |       -> node | nil, reason, ns
-- |     Parses the formula a container holds into an ast tree - the parser's
-- |     actual output. The parse also stamps `u.ast_id` on glyphs as nodes are
-- |     built from them - every digit of a numeral, a sign its coefficient -
-- |     which is how a click later resolves to a node.
-- | describe(fontset: fontset, container: mexpru.container, decls: {decl}) -> {line, ...}
-- |     Shows the tree build produced, one node per indented line - what the
-- |     F4 viewer draws. A failed parse shows a single line with the reason.
-- |
-- | Names
-- | parse_name(fontset: fontset, container: mexpru.container) -> pattern | nil, reason, node, marks
-- | parse_use(fontset: fontset, container: mexpru.container, decls: {decl}) -> use | nil, reason
-- | parse_use_units(units: {unit}, decls: {decl}, opts: table) -> use | nil, reason, node, marks
-- |     parse_name reads a declaration of a name; parse_use and parse_use_units
-- |     read a use of one. Superscripts are refused in a declaration and
-- |     allowed at a use: `f^2` is not a name, but `f^2(x)` is a use of one.
-- | match_use(use: mexpr_ast.use, decl_tokens: {string}) -> args, nil, spec | nil, reason
-- | resolve_use(use: mexpr_ast.use, decls: {decl}) -> hit | nil, reason, count
-- |     The most specific matching declaration wins; a genuine tie is an
-- |     error, and the losers ride along on the hit as `shadowed`.
-- | check_declarations(decls: {decl})       -> {root, accepted, refused}
-- |     Checks the set rather than each declaration alone: the question is
-- |     whether two collide, so a name that is fine alone can still be
-- |     refused beside another.
-- |
-- | Built-ins
-- | builtin_functions()                     -> {{name, arity}, ...} sorted
-- |     Lists the built-in function names with how many arguments each takes.
-- | named_operators()                       -> {name, ...} sorted
-- |     Lists the big operators written as words - the binders, `lim` to `argmax`.
-- | new_decl(fields: table)                 -> decl
-- | DECL_SHAPE                              the declaration's shape
-- |     A decl is one declaration as the document hands it over. It is declared
-- |     here rather than in editor_definition, which builds it: this is the
-- |     layer that decides what a declaration is, and the dependency runs this way.
-- |
-- | builtin_declarations(fontset: fontset)  -> {decl, ...}
-- | is_builtin_name(fontset: fontset, text: string) -> boolean
-- | is_builtin_word(name: string)           -> boolean
-- |     The consecrated names enter resolution as real declarations, in the
-- |     same shape a definition box hands out, so there is one path and not two.
-- |
-- | Pieces
-- | MARK_STATUSES                           {status -> meaning}
-- |     MARK_STATUSES carries the three statuses a parse mark may take: ok,
-- |     work, bad. It is declared here and checked by the drawing side at load,
-- |     so the two cannot drift.
-- |
-- | parse_number(text: string)              -> {m, n, sign} | nil
-- |     Reads a written decimal as an exact rational, or nil if it is not one.
-- | parse_domain(fontset: fontset, container: mexpru.container)
-- |       -> {var, set, marks} | nil, reason, node, marks
-- |     Parses a parameter cell, which must be a membership and nothing else.
-- |
-- | --- internal, not on the module table ---------------------------------------------------------
-- |     new_parse_ctx()  the one creator for the `ctx_parse` the cascade carries down
-- |     unit()          the one creator for the parser's per-slot container - a different
-- |                     table from mexpru's `u`, despite both being called `u` in use
-- |     the unit list, the parser cascade (build_sum -> build_product ->
-- |     read_factor), the pattern trie, the ast tagging and the declared-name paint
-- |
-- | @date 2026-09-14
-- | ===============================================================================================
--]]

--[[
mexpr_ast.lua - the bridge from the edited tree (mexpr) to meaning: the parse.

The first piece is the name pattern, which is what a definition box's first slot holds. A name
pattern is not an expression - it declares one name, written in the notation it will be applied
with, and the parameters are read off from it: `f(x)`, `a_n`, `F_{m,n}`, `v_'max'`. Everything in
it that is not the name itself or a literal is a free variable, and the count of those is the
arity the definition needs (docs/phase2_design.md section 10).

The rules come from the author's spec of 2026-09-07; each example fixes one of them:

  accepted                          rejected
  a_b        letter, subscript      2(whatever)   must not start with a number applied to anything
  a_'maxlim' quoted literal index   ab            two atoms at the same level is multiplication,
  'abc'      quoted name                          not a name
  a(x)       call notation          F_{mn}        same, one level down: juxtaposition inside an
  1_u        decorated number                     argument is multiplication
  F_{m,n}    two arguments          a^{'abcd'}x   nothing may follow the base
  a^'abcd'   quoted literal power   (a)           must not start with a bracket

Reading the rules:

  - A bare `1` or `a` with nothing else is a name, the simplest one. What `2(whatever)` breaks is
    not "starts with a digit" - `1_u` is fine - but that a number cannot be applied.
  - Quotes separate a multi-letter name from a product: `'abc'` is one name, `abc` is three
    variables multiplied. Likewise `v_'max'` is a literal while `v_{max}` is v applied to m*a*x.
  - Literals are not parameters: a quoted string and a number are constants, so `a_'maxlim'` has
    arity zero and `a_n` has arity one.
  - A name has no superscript. A power is an operation performed on a name, so it belongs to the
    expression around it: in `a^2` the name is `a`.

The output is a flattened pattern - the base name, then each notation step and the arguments it
takes, with the free variables numbered in traversal order:

    a_{n_{m}}   ->  a,sub,(1),sub,(2)
    f(x,y,z)    ->  f(),(1),(2),(3)

Traversal order is same-line, then sub: `f(x)_q` reads the call arguments first, then its index.
Whatever compares two patterns later must use this same order, or two spellings of one declaration
will not match.
@date 2026-09-14
]]

local vc = require("virt_composer")
local char = require("char")
local mexpru = require("mexpru")
local sealed = require("sealed")
local ast = require("ast")
--[[ For building the built-in declarations by PARSING them - see builtin_declarations. No cycle:
mformula_latex knows about vc/char/mexpru and nothing about this file. ]]
local mformula_latex = require("mformula_latex")

local mexpr_ast = {}

local QUOTE = "'"

--[[ Closes a sub's child list in the serialized pattern. Sub-lists NEST, so without a terminator
their sibling boundaries are lost: `a_{b_{c}, d}` and `a_{b_{c, d}}` both read as
`a,sub,b,sub,c,d`, and the two are different names.

A CALL NEEDS NO TERMINATOR, and this is worth saying so nobody adds one for symmetry. Only the root
base may take function-like arguments (docs/phase2_design.md 18d), so an argument list can never
contain another one, and it ends at the root's `sub` or at the end of the name - both decidable
from the next token. Drop that restriction and `f(),g(),(1),(2)` becomes ambiguous between
`f(g(x), y)` and `f(g(x, y))`, and this constant is no longer enough.

It cannot collide with a name: a quoted name keeps its quotes in the pattern, and a bare one is a
single letter.
@date 2026-09-10 08:20 ]]
local END = "end"
-- The membership sign's catalog desc (char.lua ncod 155), as a parameter cell must contain one.
local IN_DESC = "\\in"

-- ################################################################################################
-- Reading the tree
-- ################################################################################################

--[[ The glyph an atom carries, as its catalog `desc` ("a", "1", "'", "\\times"), or nil if the node
is not a symbol atom at all (an empty placeholder, or a composite).
@date 2026-09-08 08:55 ]]
local function atom_desc(node)
    if not node or node.type ~= vc.MEXPR_TYPE_SYMBOL then
        return nil
    end
    local entry = char.find_by_ncod(node.symb.code)
    return entry and entry.desc
end

--[[ ASCII only. Kept apart from is_letter below because a quoted name needs exactly this and not
the wider question - see is_quote_content. @date 2026-09-11 08:10 ]]
local function is_ascii_letter(d)
    return d ~= nil and #d == 1 and d:match("%a") ~= nil
end

--[[ Could this glyph stand for a variable? A LATIN LETTER OR A GREEK ONE.

Greek was refused until 2026-09-11, so `\\pi` could not be a name, could not be a free variable and
could not be an integral's variable - which is absurd for the alphabet mathematics keeps its
variables in. Author: "pi and the other greeks should also be a letter, meaning the glyps only are
also free".

BY DESC, through char.greek_letters, which is the catalog's own answer rather than a second opinion
formed here. Only the LETTERS: `\\sum` and `\\prod` are operators that happen to be drawn as Greek
capitals, they carry their own descs, and they are not in that set. @date 2026-09-11 08:10 ]]
local function is_letter(d)
    return is_ascii_letter(d) or (d ~= nil and char.is_greek_letter(d))
end

local function is_digit(d)
    return d ~= nil and #d == 1 and d:match("%d") ~= nil
end

--[[ A leading sign on a number literal. Both of char.lua's dashes answer to this - the ASCII
hyphen-minus (ncod 12) and the typographic minus (ncod 181) carry the same desc "-", so whichever
one was typed reads the same here.
@date 2026-09-10 01:05 ]]
local function is_sign(d)
    return d == "-" or d == "+"
end

--[[ The units' descs concatenated - the text a run of units spells, for matching a literal and for
error messages alike. ]]
local function units_text(units)
    local descs = {}
    for _, u in ipairs(units) do
        descs[#descs + 1] = atom_desc(u.atom) or "?"
    end
    return table.concat(descs)
end

--[[ One slot of a row, split into the atom that carries its identity and the decorations hung on
it. A supsub is ONE child of the row, so `a_b` is a single slot whose atom is `a` and whose sub is
`b` - and mexpru.slot_atom() is what looks through it (and through a dress) to find that atom.
Every walk over a row has to go through slot_atom or it reads the wrong thing; that blind spot has
produced seven live bugs so far (docs/phase2_design.md section 8).
@date 2026-09-08 08:55 ]]
--[[ A DRESS HANDS ON WHAT IS DONE TO IT. Author, 2026-09-11: "dresses divert the things that is
done to them to the underlying object".

Which limits this reads depends on how the row was BUILT, and there are two shapes for one thing:

    \\vec{F}_{n}     supsub(base = dress(F), sub = n)     the accent sits under the limits
    \\vec{F_{n}}     dress(target = supsub(F, sub = n))   the accent sits over them

Only the first was ever read. The second reported no sub at all, so `\\vec{F_{n}}` parsed as a bare
`F\\vec` of arity ZERO with the subscript silently discarded - and `\\vec{F_{n}}` and `\\vec{F_{m}}`
therefore keyed identically, which surfaced as "`F\\vec` is already defined" when both were written.

BOTH SHAPES NOW READ THE SAME, which is right rather than merely convenient: the difference between
them is how WIDE the accent is drawn (a narrow \\vec over the letter, a stretchy
\\overrightarrow over
the letter and its index), and the width of an accent is a typesetting choice, not a different
accent. `atom` still comes from slot_atom, which looks through both wrappers to the letter, and
`node` stays the OUTERMOST node so dress_suffix still finds the decoration - the accent remains part
of the name's identity exactly as before.
@date 2026-09-11 16:30 ]]
--[[ `u(_).ast_id` - which ast node the parse built out of this glyph. The mexpr is the artifact
that persists and the ast is scratch, so the tag lives on the side that lasts; `build` writes it
during the parse, wherever the unit and the node it built are both in hand. For resolving a
gesture: a click lands on a glyph, this says which node that glyph belongs to.

What the tags cover today - which is state, not design (see DESIGN.md): a glyph carries at most
one id, by the one field, and nothing checks a second write; several glyphs may name one node
(every digit of `123` carries the one NUM's id); a node may have no glyph of its own (an ADD or an
implicit MUL is written with no glyph naming it - structure is found by walking, not clicking); a
glyph may become nothing at all (brackets and commas are punctuation the tree reads and absorbs
without recording); and even a glyph a node was built from can go unstamped (a resolved name's
letters - build_named is not handed the glyphs).
@date 2026-09-11 18:30 ]]
local function tag_ast(u_or_node, ast_node)
    if not u_or_node or not ast_node or not ast_node.id then
        return ast_node
    end
    local node = u_or_node.node or u_or_node
    local u = node and mexpru.u(node)
    if u then
        u.ast_id = ast_node.id
    end
    return ast_node
end

--[[ WHICH MEXPR NODE DRAWS THIS AST NODE - its ink, exactly. The other direction from tag_ast: a
glyph names a node, but a node's ink may be several glyphs, and how such a set is recorded is not
decided yet. ast_mexpr, the one consumer, copies a name's ink rather than re-rendering it from the
identity string. A plain id, so nothing here is weak or invalidated.
@date 2026-09-12 02:00 ]]
local function tag_draws(node, ast_node)
    if not node or not ast_node or not ast_node.id then
        return ast_node
    end
    local u = mexpru.u(node)
    if u then
        u.ast_draws = ast_node.id
    end
    return ast_node
end

--[[ The node whose ink is the LEAF written at `u0`, which is not always the row slot it sits in: a
power wraps the leaf in a supsub, and that supsub draws the leaf AND its exponent; a declared
name's SUBSCRIPT wraps it the same way, and what the sub holds is the name's ARGUMENTS, not the
name - `\vec{F}_{k}` is the name `\vec{F}` applied to `k`, so the leaf is the base under the sub
and never the `k` (found live 2026-09-16: the declared-name paint coloured the subscript along
with the symbol, "the k subscript of F shouldn't be colored, only the symbol F"). The base alone
is the leaf, whichever side rode on it.
@date 2026-09-16 ]]
local function leaf_drawn_by(u0)
    if u0.sup or u0.sub then
        return u0.base
    end
    return u0.node
end

--[[ THE `ctx_parse` CONTAINER - what the parser cascade carries down, and THE ONE CREATOR for it.
Named `ctx_parse`, not `ctx`, because three containers here were called `ctx` and `ctx.ns` meant
something different in each. `vars` starts empty and fills as the parse proceeds. `free_order` is
DELIBERATELY unset here: it is a bigop's harvesting side-channel whose nil IS the off state -
initialising it would harvest every free variable by nobody.
@date 2026-09-12 14:30 ]]
local CTX_PARSE_SHAPE = sealed.declare("mexpr_ast", "ctx_parse", {
    ns         = "the namespace every node built by this parse is minted into",
    decls      = "what is in scope: the document's declarations, with the built-ins added",
    vars       = "name -> VAR node, the variables this parse has created so far",
    free_order = "a bigop's harvesting side-channel; ABSENT is the off state - see below",
})

local function new_parse_ctx(ns, decls)
    return CTX_PARSE_SHAPE.wrap{ns = ns, decls = decls, vars = {}}
end

--[[ THE `unit` CONTAINER - one row slot, as the parser sees it. THE ONE CREATOR for it. A DIFFERENT
table from mexpru's `u` despite both being called `u` in use: `u.sz` is a node's logical size,
`u0.sup` is this container's superscript slot. Sealed; the field strings below are the one list, and
declared-but-unset is the normal state for most of them - a plain letter carries `atom` and `node`
and nothing else. `quote_open` is written later, while a quoted name is being read.
@date 2026-09-12 19:45 ]]
local UNIT_SHAPE = sealed.declare("mexpr_ast", "unit", {
    atom         = "what the slot carries, looked through any dress or supsub (slot_atom)",
    node         = "the OUTERMOST node - dress_suffix reads the decoration off it",
    base         = "the supsub's base, carried for leaf_drawn_by alone",
    sup          = "the supsub's superscript row, when the slot is one",
    sub          = "its subscript row",
    call         = "set by read_pattern on a base unit it owns",
    quoted       = "the text between a pair of quotes, when this slot opens one",
    quoted_nodes = "the nodes that text came from",
    quote_open   = "the opening quote's own node, written when the pair is closed",
    prime        = "this slot is a prime mark",
})

--[[ The `decl` container - one declaration, as the document hands it to the parser. Declared here
though it is BUILT in editor_definition, because this is the layer that decides what a declaration
IS, and the dependency runs this way. `arity` is not stored: it is `#vars` on the pattern this came
from, and two places holding one number is how they come to disagree.
@date 2026-09-12 20:00 ]]
mexpr_ast.DECL_SHAPE = sealed.declare("mexpr_ast", "decl", {
    text       = "the pattern as serialized text - the KEY a use resolves against",
    name       = "the declared name on its own",
    arity      = "how many arguments it takes",
    tokens     = "the pattern's token list, carried rather than re-split from `text`",
    groups     = "its argument groups, carried for the same reason",
    box_index  = "which box declared it; added by content.declarations_before",
    builtin    = "this is a CONSECRATED name, not one the document wrote - set by "
                 .. "builtin_declarations and by nothing else",
})

--[[ @brief Builds a declaration. THE ONE CREATOR, called by editor_definition and by
-- |        builtin_declarations.
-- |
-- | @param fields  table - a literal with the DECL_SHAPE fields; it is sealed in place, not copied
-- | @return mexpr_ast.decl - `fields` itself
-- |
-- | @note The seal does NOT check the literal's keys: every key is already present when `wrap`
-- |       runs, so a misspelt `buitlin = true` passes silently. `check_keys` would catch it.
-- |
-- | @date 2026-09-13 18:45
--]]
function mexpr_ast.new_decl(fields)
    return mexpr_ast.DECL_SHAPE.wrap(fields)
end

--[[ The `use` container - a row read as a USE of a name. Sealed; it is what match_use and
resolve_use are handed, and `use.tokens` versus `use.args` is the whole of the matching.
@date 2026-09-12 19:45 ]]
local USE_SHAPE = sealed.declare("mexpr_ast", "use", {
    key      = "the pattern text this use spells, which is what a declaration is keyed by",
    tokens   = "its token list, walked against a declaration's position by position",
    args     = "the expression in each argument slot, in order",
    sups     = "powers applied to the reference, for the expression parser to re-apply",
    marks    = "the parse marks this read produced",
    consumed = "how many units it got through - only meaningful with opts.partial",
})

local function unit(child)
    --[[ THROUGH ANY DRESS FIRST, so both spellings of one thing arrive here as the same shape -
    see mexpru.undressed. A supsub reached this way is the same supsub whether the accent sat over
    the limits or under them. ]]
    local u = mexpru.u(mexpru.undressed(child))
    if u and u.kind == "supsub" then
        --[[ `base` is carried for leaf_drawn_by alone: the leaf's own ink is the base when a power
        rides on the slot. Nothing else reads it. ]]
        return UNIT_SHAPE.wrap{atom = mexpru.slot_atom(child), sup = u.sup, sub = u.sub,
                base = u.base, node = child}
    end
    --[[ `node` is the OUTERMOST node, never the undressed one: dress_suffix reads the decoration
    off it, and the decoration is part of a name's identity. ]]
    return UNIT_SHAPE.wrap{atom = mexpru.slot_atom(child), node = child}
end

--[[ Every element of a list checked against its shape - the one loop behind check_decls and
check_units. The elements are what get dereferenced downstream, so a wrong one is named by index
rather than merely carried.
@date 2026-09-14 ]]
local function check_list(list, shape, what)
    assert(type(list) == "table", what .. " must be a list")
    for i, item in ipairs(list) do
        shape.check(item, what .. "[" .. i .. "]")
    end
    return list
end

--[[ A declaration LIST - what a caller passes as "what is in scope". nil is refused here; callers
that allow an absent list test for it themselves, because for them nil means something ("just the
built-ins") rather than nothing.
@date 2026-09-12 20:40 ]]
local function check_decls(decls, what)
    return check_list(decls, mexpr_ast.DECL_SHAPE, what or "decls")
end

--[[ A unit list - built by row_units and sliced by the parser, so a wrong element means a slice
went wrong upstream rather than a caller mistyping.
@date 2026-09-12 20:20 ]]
local function check_units(units, what)
    return check_list(units, UNIT_SHAPE, what or "units")
end

--[[ Does any unit here carry a subscript - the test for "could this group be read as an application
of a name", which group_is_name_part and contains_definition both turn on. ]]
local function has_sub(units)
    for _, u in ipairs(units) do
        if u.sub then
            return true
        end
    end
    return false
end

--[[ What may stand inside a quoted name. Spaces are content here and layout everywhere else, which
is the whole reason quotes are scanned before spaces are dropped.

ASCII LETTERS ONLY, deliberately, even though a bare Greek glyph IS a letter everywhere else in this
file. A quoted name is packed by CONCATENATING the descs between the quotes, and a desc like
`\\pi` is several characters with a backslash in it - so `'a\\pi b'` would pack to a string nobody
could read back as the atoms it came from. Quotes exist to make a name out of ordinary characters;
a Greek variable needs no quotes to begin with.
@date 2026-09-11 08:10 ]]
local function is_quote_content(d)
    return d ~= nil and (is_ascii_letter(d) or is_digit(d) or d == "_" or d == " ")
end

--[[ QUOTES BIND FIRST: a quoted name is ONE object from the moment its opening quote is seen, so
its atoms never reach the space filter below and never have to be put back. Row-local - a quoted
name cannot span a subscript boundary.

THE CLOSING QUOTE IS THE UNIT THAT SURVIVES, because it is the one that may carry the decorations
(`'abc'_n` types as a sub on the closing quote); the packed name rides on it as `.quoted`, and
`.quoted_nodes` keeps the atoms so per-character painting survives the packing. A LONE QUOTE IS A
PRIME - no closer and no string content after it - while `'ab` is a name still being typed and keeps
the unterminated-name error, which is what preserves the red mark under a half-typed name.
@date 2026-09-10 11:20 ]]
local function pack_quotes(raw)
    local out, i = {}, 1
    while i <= #raw do
        if atom_desc(raw[i].atom) ~= QUOTE then
            out[#out + 1] = raw[i]
            i = i + 1
        else
            local close = nil
            for j = i + 1, #raw do
                if atom_desc(raw[j].atom) == QUOTE then
                    close = j
                    break
                end
            end

            if close and close > i + 1 then
                local text, nodes = {}, {}
                for j = i + 1, close - 1 do
                    text[#text + 1] = atom_desc(raw[j].atom) or "?"
                    nodes[#nodes + 1] = raw[j].node
                end
                local u = raw[close]
                u.quoted = table.concat(text)
                u.quoted_nodes = nodes
                u.quote_open = raw[i].node
                out[#out + 1] = u
                i = close + 1
            elseif is_quote_content(atom_desc(raw[i + 1] and raw[i + 1].atom)) then
                -- Content follows and no quote closes it: a name being typed, left to fail as one.
                out[#out + 1] = raw[i]
                i = i + 1
            else
                --[[ Alone. Emitted one at a time and merged below, so `'''` needs no lookahead
                arithmetic - each quote answers the same question about the atom after it. ]]
                raw[i].prime = 1
                out[#out + 1] = raw[i]
                i = i + 1
            end
        end
    end

    --[[ Adjacent primes are ONE decoration: `''` is a second, not two firsts. The LAST unit is the
    one kept, for the same reason the closing quote is - a subscript typed after them wraps it. ]]
    local merged = {}
    for _, u in ipairs(out) do
        local prev = merged[#merged]
        if u.prime and prev and prev.prime then
            u.prime = prev.prime + u.prime
            merged[#merged] = u
        else
            merged[#merged + 1] = u
        end
    end
    return merged
end

--[[ One row, as the units the parsers walk: quoted names packed whole, primes merged, and the
spaces that are left over dropped. SPACES GO ONCE, HERE - `f (x)` is the same name as `f(x)` - so no
site that walks units has to think about them; before this, one space broke the name parse in four
different ways depending on where it landed. A space inside a quoted name is content, not layout,
and pack_quotes has already swallowed it by the time this filter runs.
@date 2026-09-10 11:20 ]]
local function units_of(nodes)
    local raw = {}
    for _, ch in ipairs(nodes or {}) do
        raw[#raw + 1] = unit(ch)
    end

    local out = {}
    for _, u in ipairs(pack_quotes(raw)) do
        if atom_desc(u.atom) ~= " " then
            out[#out + 1] = u
        end
    end
    return out
end

--[[ The decorations wrapped around a slot's atom, as the suffix its base token carries.
DECORATIONS ARE PART OF A NAME - slot_atom looks through a dress, which is right for the cursor and
wrong for identity, so `\hat{a}` and `a` must not serialize the same. FOLDED INTO THE BASE TOKEN
rather than emitted beside it: a separate token would make `a` a prefix of `a,\hat`, and the
no-overlap rule refuses a name that extends one already defined. INNERMOST FIRST, so a doubly
dressed letter has one spelling.
@date 2026-09-10 11:50 ]]
local DOT_NAMES = {[1] = "\\dot", [2] = "\\ddot", [3] = "\\dddot"}

local function dress_suffix(node)
    local out = {}
    local n = node
    while n do
        local u = mexpru.u(n)
        if not u or u.bracket then
            break
        end
        if u.kind == "supsub" and u.base then
            n = u.base
        elseif u.kind == "dress" and u.target then
            --[[ Collected outermost-first by the walk and reversed below. Dots share the above slot
            with a named accent (mformula_new's own note), so at most one of the two is set. ]]
            if u.above_kind then
                out[#out + 1] = "\\" .. tostring(u.above_kind)
            elseif u.dots then
                out[#out + 1] = DOT_NAMES[u.dots] or ("\\dots" .. tostring(u.dots))
            end
            if u.bellow_kind then
                out[#out + 1] = "\\under:" .. tostring(u.bellow_kind)
            end
            n = u.target
        else
            break
        end
    end

    local rev = {}
    for i = #out, 1, -1 do
        rev[#rev + 1] = out[i]
    end
    return table.concat(rev)
end

local function row_children(node)
    local u = node and mexpru.u(node)
    if u and u.kind == "horiz" then
        return u.children or {}
    end
    -- A slot that is a bare node rather than a row still reads as a one-item row.
    return node and {node} or {}
end

-- ################################################################################################
-- Numbers
-- ################################################################################################

--[[ @brief A written decimal, as the exact rational ast.new_num() wants.
-- |
-- |     "12"     -> 12/1        "3.14"  -> 314/100        "-0.5" -> -5/10
-- |
-- | NOT REDUCED. 3.14 stays 314/100 rather than becoming 157/50, matching what
-- | docs/phase2_design.md section 4.2 fixes as the representation. Reducing is a normalisation,
-- | and normalisations belong to the equality machinery (section 9), not to reading a literal.
-- |
-- | LITERALS ONLY, and a literal is not the same thing as a number. Verbatim, 2026-09-07:
-- | "remember sqrt(2) is also a number". `sqrt(2)` reaches the bridge as `(2)^{1/2}`, an EXPRESSION
-- | with a constant value, and "is this a number" is a question about free variables that belongs
-- | where variables are resolved. This answers only "is this run of glyphs a written numeral".
-- |
-- | @details One leading `+` or `-` is read; "++1" and "+-1" fail. The arithmetic is integer
-- |          throughout, since a float denominator would poison every rational built from it.
-- |
-- | @param text  string - the glyphs' descs concatenated, e.g. "3.14"
-- | @return {m, n, sign} | nil - sign * m / n; nil for anything that is not a well-formed literal,
-- |         so `1.2.3` and a bare `.` are refused rather than silently becoming something
-- |
-- | @note Do not extend it to recognise constant expressions - that check belongs where variables
-- |       are resolved.
-- |
-- | @date 2026-09-13 18:45
--]]
function mexpr_ast.parse_number(text)
    local sign, body = 1, text
    if body:sub(1, 1) == "-" then
        sign, body = -1, body:sub(2)
    elseif body:sub(1, 1) == "+" then
        -- Explicit "+" is spelling, not value, the same way "007" is. Only ONE sign is stripped,
        -- so "++1" and "+-1" still fail the digit match below rather than being read as 1.
        body = body:sub(2)
    end
    if body == "" then
        return nil
    end

    local int_part, frac_part = body:match("^(%d*)%.(%d*)$")
    if not int_part then
        if not body:match("^%d+$") then
            return nil
        end
        return {m = tonumber(body), n = 1, sign = sign}
    end
    if int_part == "" and frac_part == "" then
        return nil                      -- a lone "."
    end

    -- Integer arithmetic throughout: 10^#frac in Lua 5.4 is a FLOAT, and a denominator that is not
    -- an integer would poison every rational built from it.
    local den = 1
    for _ = 1, #frac_part do
        den = den * 10
    end
    return {m = tonumber(int_part .. frac_part), n = den, sign = sign}
end

-- ################################################################################################
-- Parsing
-- ################################################################################################

local Parser = {}
Parser.__index = Parser

--[[ `sups` and `no_sups` are the seam between naming and expressions - see decorations().

`no_sups` DEFAULTS TRUE so every entry point that exists today behaves exactly as it did: a power
in a name is refused. An expression parser, when there is one, clears it and reads `sups` instead.
Defaulting the other way would have silently loosened parse_name and parse_domain at the same time.
@date 2026-09-10 01:45 ]]
--[[ Stands in `vars` for an argument position whose contents are an expression rather than a
parameter name. A table rather than a string so it can never collide with a real variable name, and
so `#vars` keeps counting positions the way a declaration does.
@date 2026-09-10 03:45 ]]
local ARG_SLOT = setmetatable({}, {__tostring = function() return "<arg>" end})

local function new_parser()
    --[[ `groups` is every argument group the parse walked, in traversal order and in BOTH modes.
    `exprs` is the use-site subset - the ones set aside unparsed - so the two are not the same list:
    a declaration parses its arguments and sets none aside, and still needs them recorded, because
    the "no definition inside a definition" check walks them. ]]
    --[[ `var_nodes` and `base_nodes` are the BOXES behind two things the pattern otherwise only
    knows as text: `vars` numbers the parameters and `name` spells the base, and neither can be
    drawn. Anything wanting to SHOW a name has to draw the mexpr the user typed - re-rendering
    `name` as if it were LaTeX puts an accent beside its letter instead of above it, which is the
    bug these lists exist to remove (editor_definition.lua's derived rows). ]]
    return setmetatable({vars = {}, var_nodes = {}, base_nodes = nil,
                         tokens = {}, marks = {}, sups = {}, exprs = {}, groups = {},
                         no_sups = true}, Parser)
end

--[[ THE THREE MARK STATUSES - the whole set, declared once so both sides of it agree.

WHY DECLARED AT ALL. A status is a magic string that leaves this file: editor_definition draws a
mark by looking its status up in MARK_COLORS, and a name that is not a key there yields nil, which
its `if color then` skips. So a typo - `"wrk"` - does not fail, it makes the mark silently not
appear, on the one feature whose whole job is telling the user where the parse went wrong.

Exported so the drawing side can be checked against it at load rather than agreeing by coincidence.
@date 2026-09-12 17:10 ]]
mexpr_ast.MARK_STATUSES = sealed.declare("mexpr_ast", "mark status", {
    ok   = "read and accepted",
    work = "inside something unfinished - an unclosed bracket, an unterminated quote. Not wrong "
           .. "yet, which is what most of typing looks like.",
    bad  = "this is the thing that breaks the rule",
})

--[[ Records what the parser made of one atom, for the editor to paint behind it:

    "ok"    read and accepted
    "work"  inside something that is not finished yet - an unclosed bracket, an unterminated
            quote. Not wrong, just incomplete, which is what most of typing looks like.
    "bad"   this is the thing that breaks the rule

Anything the parser never reached is simply absent, and stays unpainted. A LIST rather than a table
keyed by node, because a Lua table cannot be keyed by an mexpr_p - node identity has to go through
mexpru.same(), so there is no usable key.
@date 2026-09-08 08:55 ]]
function Parser:mark(node, status)
    --[[ THE STATUS IS CHECKED; the node is not required. A node the parser never reached is simply
    absent and stays unpainted, which is why nil is an ordinary argument here - but a status outside
    the three is not a quieter mark, it is an invisible one. ]]
    mexpr_ast.MARK_STATUSES.check_name(status, "status")
    if node then
        self.marks[#self.marks + 1] = {node = node, status = status}
    end
end

--[[ Everything from unit `i` onward, as "work": an unfinished construct swallows the rest of what
was typed, and none of it is wrong yet.
@date 2026-09-08 08:55 ]]
function Parser:mark_rest(units, i)
    check_units(units)
    for j = i, #units do
        self:mark(units[j].node, "work")
    end
end

function Parser:fail(msg, node)
    --[[ `node` is OPTIONAL - `parse_argument` fails with none when the argument is empty, since
    there is no glyph to point at. Checked when given. ]]
    if node ~= nil then
        mexpru.check_node(node, "node")
    end
    self.err, self.err_node = msg, node
    self:mark(node, "bad")
    return nil
end

function Parser:emit(tok)
    self.tokens[#self.tokens + 1] = tok
end

--[[ Registers one parameter position and emits its numbered slot. Every occurrence gets its own
number - `F_{m,m}` is two parameters that happen to be spelled the same. `nodes` is the boxes
standing at the position, carried so it can be DRAWN; the nodes are never identity (`f(x)` and
`f(z)` are one name).
@date 2026-09-11 02:10 ]]
function Parser:free_var(name, nodes)
    assert(type(name) == "string", "a free variable's name must be a string")
    for i, node in ipairs(nodes or {}) do
        mexpru.check_node(node, "nodes[" .. i .. "]")
    end
    self.vars[#self.vars + 1] = name
    self.var_nodes[#self.vars] = nodes
    self:emit("(" .. #self.vars .. ")")
end

--[[ Is this argument group literal structure of the enclosing name rather than an argument of it?

Only a DECORATED group can be - one carrying a subscript - and only while nothing answers to it on
its own. See parse_argument's use-site branch for why that single test is enough and why a bare leaf
never asks it.

Costs a nested parse and resolve, on a strictly smaller unit list, so the recursion terminates. It
answers false whenever there is nothing to resolve against, which keeps a parse with no declarations
reading exactly as it did before there was a rule at all.
@date 2026-09-10 09:10 ]]
function Parser:group_is_name_part(units)
    check_units(units)
    if not self.decls or #self.decls == 0 or not has_sub(units) then
        return false
    end
    local u = mexpr_ast.parse_use_units(units, self.decls)
    if not u then
        -- Not a name shape at all, so it is whatever the expression parser makes of it.
        return false
    end
    return mexpr_ast.resolve_use(u, self.decls) == nil
end

--[[ Takes a packed quoted name off `u`, marking the atoms it was built from.

The marks are why this exists rather than the caller just reading `.quoted`: the definition box
paints per character, so it needs to say which atoms were accepted and which one broke the rule.
That survived the packing precisely because `.quoted_nodes` kept them.
@date 2026-09-10 11:20 ]]
--[[ PRECONDITION: `u.quoted` is set. Both callers test `first.quoted` before coming here, and
`quoted_nodes` is written on the same line as `quoted` (row_units), so the two are never apart.
Stated rather than checked: this is a Parser method, and the checks in this project live at the API
edge, not on the locals behind it. @date 2026-09-12 17:30 ]]
function Parser:take_quoted(u)
    UNIT_SHAPE.check(u, "u")
    --[[ NOTHING BUT SPACES IS NOT A NAME. `'  '` has two characters of content and identifies
    nothing, and packing made this the only place left to say so: `''` never arrives here at all,
    since a pair with nothing between it lexes as a second rather than as a name. ]]
    if u.quoted:match("^ *$") then
        return self:fail("empty quoted name", u.node)
    end
    for _, node in ipairs(u.quoted_nodes) do
        local d = atom_desc(node and mexpru.slot_atom(node))
        --[[ Underscore included, and spaces: a quoted name is the only way to write a
        multi-character name, `max_lim` is how people spell those, and an underscore cannot be typed
        unquoted since "_" is the subscript key. ]]
        if not is_quote_content(d) then
            return self:fail("a quoted name may only contain letters, digits, underscores and "
                    .. "spaces", node)
        end
        self:mark(node, "ok")
    end
    -- Both quotes are punctuation and do not survive into the pattern; they are marked as read.
    self:mark(u.quote_open, "ok")
    self:mark(u.node, "ok")
    return u.quoted
end

--[[ Is this unit a bracket, and which way round? Bracket atoms carry u(_).bracket - nothing else
does (mexpru's own bracket model comment).
@date 2026-09-08 08:55 ]]
local function bracket_of(u)
    local uu = u.atom and mexpru.u(u.atom)
    return uu and uu.bracket
end

--[[ The units inside the bracket pair opened at `open_i`, and the index just past its close - or
nil when nothing closes it. THE ONE depth walk over bracket_of: read_pattern's call scan and
read_factor's bracket group are the same walk, and a wrong pairing here is a wrong tree.
@date 2026-09-14 ]]
local function collect_bracketed(units, open_i)
    local depth, j, inner = 1, open_i + 1, {}
    while j <= #units and depth > 0 do
        local b = bracket_of(units[j])
        if b then
            depth = depth + (b.is_open and 1 or -1)
        end
        if depth > 0 then
            inner[#inner + 1] = units[j]
        end
        j = j + 1
    end
    if depth ~= 0 then
        return nil
    end
    return inner, j
end

--[[ Is this unit a fraction, and if so its numerator/denominator rows. Frac atoms carry
u(_).kind == "frac" plus u(_).num/u(_).den (mexpru.frac's own bookkeeping) - nothing else does,
the same idiom bracket_of above uses for u(_).bracket.
@date 2026-09-10 ]]
local function frac_of(u)
    local uu = u.atom and mexpru.u(u.atom)
    return uu and uu.kind == "frac" and uu
end

--[[ Splits a row's units into comma-separated groups. Commas are the ONLY separator inside an
argument list; two atoms side by side with no comma is multiplication, which a name may not
contain (`F_{m,n}` yes, `F_{mn}` no).
@date 2026-09-08 08:55 ]]
local function split_commas(units, p)
    local groups, cur = {}, {}
    for _, u in ipairs(units) do
        if atom_desc(u.atom) == "," then
            if p then
                p:mark(u.node, "ok")
            end
            groups[#groups + 1] = cur
            cur = {}
        else
            cur[#cur + 1] = u
        end
    end
    groups[#groups + 1] = cur
    return groups
end

--[[ One argument: a single unit, which is either a literal (quoted string or number - NOT a
parameter) or a free variable, and which may itself carry decorations that recurse.
@date 2026-09-08 08:55 ]]
function Parser:parse_argument(units)
    check_units(units)
    if #units == 0 then
        return self:fail("empty argument", nil)
    end
    self.groups[#self.groups + 1] = units

    --[[ USE-SITE MODE: every argument position is a SLOT, whatever is written in it - the group is
    set aside for the expression parser and the position emits `(k)`, so a use site and a
    declaration count identically. EXCEPT WHEN THE GROUP IS PART OF THE NAME: since a definition
    may not contain another, a DECORATED group either resolves on its own (an independent argument)
    or it does not (part of the name) - never both, one test per group. A bare leaf is always an
    argument; only a decorated one asks.
    @date 2026-09-10 09:10 ]]
    if self.arg_slots and not self:group_is_name_part(units) then
        self.exprs[#self.exprs + 1] = units
        self.vars[#self.vars + 1] = ARG_SLOT
        --[[ Every unit of the group, not just its first: a use-site argument is a whole expression
        (`f(n+1)`), so "the boxes at this position" is all of them. Kept in step with the
        declaration branch below so nothing has to ask which mode built the pattern. ]]
        local nodes = {}
        for _, u in ipairs(units) do
            nodes[#nodes + 1] = u.node
        end
        self.var_nodes[#self.vars] = nodes
        self:emit("(" .. #self.vars .. ")")
        for _, u in ipairs(units) do
            self:mark(u.node, "ok")
        end
        return true
    end

    local first = units[1]
    local d = atom_desc(first.atom)
    local last_i = 1

    if first.quoted then
        local text = self:take_quoted(first)
        if not text then
            return nil
        end
        self:emit("'" .. text .. "'")
    elseif d == QUOTE then
        self:mark(first.node, "bad")
        return self:fail("unterminated quoted name - no closing '", first.node)
    elseif is_digit(d) or (is_sign(d) and is_digit(atom_desc(units[2] and units[2].atom))) then
        --[[ A number, read as an optional sign then a run of digits and dots: a literal, not a
        parameter. Numbers ARE strings for this purpose - "constants if you will".

        THE SIGN ONLY COUNTS WITH A DIGIT BEHIND IT, which is what the lookahead above is for. A
        bare "-" is not the start of a number, and treating it as one would swallow a minus that
        belongs to the expression and then report the confusing failure a line later. ]]
        local num = {}
        local first_i = last_i
        if is_sign(d) then
            num[#num + 1] = d
            last_i = last_i + 1
        end
        while last_i <= #units do
            local dd = atom_desc(units[last_i].atom)
            if is_digit(dd) or dd == "." then
                num[#num + 1] = dd
                last_i = last_i + 1
            else
                break
            end
        end
        last_i = last_i - 1
        local text = table.concat(num)
        --[[ Checked rather than accepted as typed: `1.2.3` is a run of digits and dots and is not
        a number, and letting it through would put something unreadable into the pattern. ]]
        local value = mexpr_ast.parse_number(text)
        if not value then
            return self:fail("`" .. text .. "` is not a number", units[first_i].node)
        end
        for i = first_i, last_i do
            self:mark(units[i].node, "ok")
        end
        self:emit(text)
    elseif is_letter(d) then
        --[[ A BARE LETTER IS A FREE VARIABLE; A DECORATED ONE IS PART OF THE NAME. `m` in `a_{m}`
        is a parameter, `b` in `a_{b_{2}}` is the literal token `b` - so the second names one thing
        of arity zero rather than a two-parameter pattern.

        The rule is what makes a nested sub readable at all. A parameter swallows whatever is
        written at its position, so if `b` were one, `b_{2}` would have to be a parameter carrying
        a subscript, and nothing in a pattern says what that would identify. Carrying a decoration
        is exactly the evidence that the letter is structure rather than a slot.
        @date 2026-09-10 08:20 ]]
        if first.sub then
            -- Literal structure, so its decorations are identity too - see dress_suffix.
            self:emit(d .. dress_suffix(first.node))
        else
            --[[ A PARAMETER, and a parameter's SPELLING was never identity - `f(x)` and `f(z)` are
            one name. An accent is part of that spelling, so `a_{\hat{m}}` is `a,sub,(1),end`, the
            same as `a_{m}`. Decorations only become identity where what they sit on is literal. ]]
            self:free_var(d, {first.node})
        end
        self:mark(first.node, "ok")
    else
        return self:fail("an argument must be a name, a quoted literal or a number", first.node)
    end

    --[[ THIS IS THE EXPRESSION BOUNDARY: an argument that is not a single name, literal or number
    is an expression (`a_{n+1}`, `a_{2n}`), and lands here as an error. NOT WIRED UP YET, and
    deliberately not half-wired - free_var()/emit() above have ALREADY run by the time we get here,
    so `n` in `a_{n+1}` is registered as a parameter before anything knows the group was an
    expression, and catching the failure would leave that behind.
    @date 2026-09-10 02:05 ]]
    --[[ Anything after the argument's own atom (and its decorations) is juxtaposition, i.e.
    multiplication, which is what separates `F_{m,n}` from `F_{mn}`. ]]
    if last_i < #units then
        return self:fail("juxtaposition inside a name - use a comma to separate arguments, "
                .. "or quotes to make one name", units[last_i + 1].node)
    end

    return self:decorations(units[last_i])
end

--[[ An argument list, already lexed: comma-separated, each group one argument.

TAKES UNITS, because a row is lexed exactly once. A call's arguments were collected as units while
scanning to the matching bracket, and re-deriving them from their nodes would undo the quote packing
that happened on the way in.
@date 2026-09-10 11:20 ]]
function Parser:parse_arg_units(units)
    check_units(units)
    -- An untouched slot holds a single empty placeholder; that is "no arguments yet", not an error
    -- worth stopping the whole parse for - the caller sees arity 0 for it.
    if #units == 1 and units[1].atom and units[1].atom.type == vc.MEXPR_TYPE_EMPTY_BOX then
        return true
    end
    for _, group in ipairs(split_commas(units, self)) do
        if not self:parse_argument(group) then
            return nil
        end
    end
    return true
end

--[[ The same, for a slot that is still a row: a sup/sub is unwrapped and lexed here.

Same builder as row_units, so the space rule cannot hold on one path and not the other - which is
exactly what happened when this loop was its own copy: `f (x)` was fixed and `a_{n }` was not,
because a subscript's arguments come through here instead.
@date 2026-09-08 08:55 ]]
function Parser:parse_arg_list(nodes)
    return self:parse_arg_units(units_of(nodes))
end

--[[ The decorations hanging off one unit, in the fixed order same-line -> sub. A SUPERSCRIPT IS
COLLECTED, NEVER CONSUMED, then refused while `no_sups` is set - and collected anyway because ONE
supsub node carries sup AND sub together: in `a_n^2` the sub is the name's and the sup is the
expression's, and only the name parser agreeing to read one and decline the other can split that
node. `sups` is that declined half, ready for the expression parser.
@date 2026-09-10 01:45 ]]
function Parser:decorations(u)
    UNIT_SHAPE.check(u, "u")
    --[[ `if not u then return true end` is gone. It could not fire from either caller - one passes
    `units[last_i]` with last_i a valid index, and the other's `base_unit` is set on every branch
    that does not return first - and what it did if it ever had was worse than nothing: `true` means
    "the decorations are fine", so a name whose base was never found would have been accepted. A nil
    here now errors on the next line, at the caller that lost it. ]]
    if u.sup then
        self.sups[#self.sups + 1] = {node = u.node, row = u.sup}
        if self.no_sups then
            return self:fail("a name may not carry a power - it takes a subscript or arguments",
                    u.node)
        end
    end
    if u.call then
        --[[ No step marker of its own: the "()" is already stuck to the NAME token, because that is
        how the user wrote the expected output - `f(x,y,z)` is `f(),(1),(2),(3)`, not
        `f,(),(1),(2),(3)`. A call has no step name because the brackets ARE the notation, and they
        are written against the name itself.

        The old note here worried about a name carrying both a power and a call (`a^2(x)`) and
        which of the two the "()" belonged to. That edge is gone rather than resolved: a name cannot
        carry a power at all any more, so the only decorations left are the call and the sub, and
        their order was never in question. ]]
        if not self:parse_arg_units(u.call) then
            return nil
        end
    end
    if u.sub then
        self:emit("sub")
        if not self:parse_arg_list(row_children(u.sub)) then
            return nil
        end
        -- Closes the child list this `sub` opened - see END on why nesting makes it necessary.
        self:emit(END)
    end
    return true
end

--[[ The units of a row, in order. Split out so the same reading serves a whole slot and the
left-hand side of a domain restriction. (read_pattern, below, is what describes the result a parse
of those units produces.)
@date 2026-09-08 08:55 ]]
local function row_units(node)
    return units_of(row_children(node))
end

--[[ A NAMED OPERATOR - `sin`, `log`, `ln` - or nil: a 1-tall vert whose single row holds
letters and nothing else. WHY A CONTAINER: `s`, `i`, `n` loose in a row is juxtaposition, which
this grammar reads as multiplication, so wrapping makes the name ONE atom - the same move quoting
makes for a
multi-character name. Any vert holding more than single letters is a stack, a real thing that means
something else, and is not a name. Spaces are already gone by here, so `s i n` reads as `sin`.
@date 2026-09-10 04:30 ]]
local function operator_name(atom)
    if not atom then
        return nil
    end
    local u = mexpru.u(atom)
    if u.kind ~= "vert" or not u.slots or #u.slots ~= 1 then
        return nil
    end
    local letters = {}
    for _, ch in ipairs(units_of(row_children(u.slots[1]))) do
        local d = atom_desc(ch.atom)
        if not is_letter(d) then
            return nil
        end
        letters[#letters + 1] = d
    end
    if #letters == 0 then
        return nil
    end
    return table.concat(letters)
end

local function is_untouched(units)
    return #units == 0 or (#units == 1 and units[1].atom
            and units[1].atom.type == vc.MEXPR_TYPE_EMPTY_BOX)
end

--[[ Reads a name pattern out of `units`, using parser `p`. Everything in `units` must belong to the
name: this is the routine both a name slot (the whole row) and a domain restriction's left-hand
side (the part before the membership sign) go through, so the rules cannot drift between them.
@date 2026-09-08 08:55 ]]
local function read_pattern(p, units)
    if is_untouched(units) then
        -- Nothing typed yet: not an error to paint, just nothing to say.
        return nil, "empty name", nil, p.marks
    end

    -- ---- the base ------------------------------------------------------------------------
    local first = units[1]
    local d = atom_desc(first.atom)
    local base_unit, next_i

    if bracket_of(first) then
        p:mark(first.node, "bad")
        return nil, "a name may not start with a bracket", first.node, p.marks
    elseif is_digit(d) then
        --[[ A NUMBER IS A BASE AGAIN: a NUMERAL is not a trie definition, so either `2(),(1)` is
        declared and takes the row or nothing is and the expression parser reads multiplication -
        no third reading. THE WHOLE RUN, or `1` and `12` branch against each other in the trie. ]]
        local digits, j = {}, 1
        while j <= #units and is_digit(atom_desc(units[j].atom)) do
            digits[#digits + 1] = atom_desc(units[j].atom)
            p:mark(units[j].node, "ok")
            j = j + 1
        end
        p.name = table.concat(digits)
        p.base_nodes = {}
        for k = 1, j - 1 do
            p.base_nodes[k] = units[k].node
        end
        base_unit, next_i = units[j - 1], j
    elseif first.quoted then
        local text = p:take_quoted(first)
        if not text then
            return nil, p.err, p.err_node, p.marks
        end
        --[[ The atoms BETWEEN the quotes, which is what the name is - the quotes themselves are
        punctuation and do not survive into the pattern either (take_quoted marks them read). ]]
        p.base_nodes = first.quoted_nodes
        p.name = text
        base_unit, next_i = first, 2
    elseif first.prime then
        --[[ Asked BEFORE the bare-quote case below, because a prime's atom is a quote: pack_quotes
        marks the unit rather than replacing its atom, so the two are told apart by `.prime` and
        never by what the atom is. ]]
        p:mark(first.node, "bad")
        return nil, "a name may not begin with a prime", first.node, p.marks
    elseif d == QUOTE then
        --[[ A quote that packing left alone is one with content after it and nothing closing it -
        a name in the middle of being typed. Painted on the OPENING quote, which is the thing that
        was never finished. ]]
        p:mark(first.node, "bad")
        return nil, "unterminated quoted name - no closing '", first.node, p.marks
    elseif operator_name(first.atom) then
        --[[ A named operator is a base like any other letter, just several letters long, so
        `sin(x)` keys as `sin(),(1)` exactly as `f(x)` keys as `f(),(1)`. Nothing downstream needs
        to know it was written as a vert - which is the point of making it an atom.

        Whether the name is one the system KNOWS (`sin`) or one somebody invented is not this
        function's question, and there is no second table for the ones it knows. A built-in is an
        INJECTED DEFINITION - it reaches resolution through the same declaration set as everything
        written by hand, so this reads the name and resolution answers, once. Author, 2026-09-10:
        "the whole idea is that definition rule what can and can't be seen as a named structure". ]]
        p.name = operator_name(first.atom)
        p.base_nodes = {first.node}
        p:mark(first.node, "ok")
        base_unit, next_i = first, 2
    elseif is_letter(d) then
        -- A LETTER, and only a letter: `1_u` as a NAME would collide with `1` the literal in every
        -- context where both could appear, and a grammar that has to ask which was meant has lost.
        p.name = d
        p.base_nodes = {first.node}
        p:mark(first.node, "ok")
        base_unit, next_i = first, 2
    else
        p:mark(first.node, "bad")
        return nil, "a name must begin with a letter or a quoted name", first.node,
                p.marks
    end

    --[[ ---- the decorations, which are part of the base's identity -------------------------
    Primes are their own units and follow the base in the row, so they are absorbed here; accents
    wrap the atom and come off the node. A subscript typed after a prime wraps the PRIME, so the
    decoration unit becomes the one the sub is read from. ]]
    local primes = 0
    while next_i <= #units and units[next_i].prime do
        primes = primes + units[next_i].prime
        p:mark(units[next_i].node, "ok")
        base_unit = units[next_i]
        if p.base_nodes then
            p.base_nodes[#p.base_nodes + 1] = units[next_i].node
        end
        next_i = next_i + 1
    end
    p.name = p.name .. dress_suffix(first.node) .. string.rep("'", primes)

    --[[ WHICH NODE HOLDS THE ARGUMENTS, so a drawing of the name alone can leave them out: a
    subscript wraps whichever unit it was typed after (the base, or the last prime), and what it
    holds is the name's ARGUMENTS - `p.name` never included them, so neither may the boxes that
    draw it. Found through mexpru.undressed, so both spellings (`\vec{F}_{n}` and `\vec{F_{n}}`)
    answer the same. The consumer drops it by SUBSTITUTION (editor_definition's name_drawings). ]]
    if p.base_nodes and #p.base_nodes > 0 then
        local inner = mexpru.undressed(p.base_nodes[#p.base_nodes])
        local iu = inner and mexpru.u(inner)
        if iu and iu.kind == "supsub" and iu.base then
            p.base_drop = inner
        end
    end

    -- ---- an optional call: ONE bracketed group, immediately after the base -----------------
    local call_row = nil
    if not p.no_call and next_i <= #units and bracket_of(units[next_i]) then
        local open = bracket_of(units[next_i])
        if not open.is_open then
            p:mark(units[next_i].node, "bad")
            return nil, "closing bracket with nothing open", units[next_i].node, p.marks
        end
        --[[ The guard that stood here - "a number cannot be applied, `2(x)` is multiplication" -
        went with the digit bases it existed for. A base is a letter now, so it could never fire
        again; `2(x)` fails one step earlier, at "a name must start with a letter". Removed rather
        than left as dead code that reads like a live rule. ]]
        --[[ Collect to the matching close. The contents become the call's argument row; the
        brackets themselves are punctuation and do not survive into the pattern. ]]
        --[[ COLLECTED AS UNITS, NOT NODES. These units are already packed - a quoted argument is
        one unit whose atoms are no longer in this list - so handing the nodes on and re-running
        units_of over them would rebuild the row from a node list the packing had emptied, and
        `f('a b', x)` would report an unterminated quote. Units in, units out; the row is lexed
        exactly once. ]]
        local inner, j = collect_bracketed(units, next_i)
        if not inner then
            --[[ Opened and never closed: the BRACKET is painted "bad", everything after it "work" -
            the site gets exactly one mark, so no two translucent rects stack. ]]
            p:mark(units[next_i].node, "bad")
            p:mark_rest(units, next_i + 1)
            return nil, "unclosed bracket in name", units[next_i].node, p.marks
        end
        -- Both brackets read fine; they are punctuation and do not survive into the pattern.
        p:mark(units[next_i].node, "ok")
        p:mark(units[j - 1].node, "ok")
        call_row = inner
        next_i = j
    end

    -- ---- nothing may follow ---------------------------------------------------------------
    --[[ UNLESS THE CALLER ASKED FOR A PREFIX. A declaration must be the whole slot, so trailing
    content is an error there; a USE sits in a row next to other factors, and the question it asks
    is not "is this row a name" but "where does the name end". `p.partial` is that question, and
    `consumed` is the answer - see read_factor, which is the only caller that asks it. ]]
    if next_i <= #units and not p.partial then
        p:mark(units[next_i].node, "bad")
        return nil, "a name may not be followed by anything else - `a^{'x'}y` is a product, "
                .. "not a name", units[next_i].node, p.marks
    end
    p.consumed = next_i - 1

    -- ---- emit -----------------------------------------------------------------------------
    -- (still inside read_pattern)
    --[[ The call marker rides on the name token (`f()`), not as a step of its own - see
    decorations() for why. ]]
    p:emit(p.name .. (call_row and "()" or ""))
    base_unit.call = call_row
    if not p:decorations(base_unit) then
        return nil, p.err, p.err_node, p.marks
    end

    return {
        name = p.name,
        vars = p.vars,
        arity = #p.vars,
        tokens = p.tokens,
        text = table.concat(p.tokens, ","),
        marks = p.marks,
        --[[ Empty for every caller today, since they all refuse a power outright. It rides on the
        result so that a caller which allows them does not need a second way in - see
        decorations(). ]]
        sups = p.sups,
        -- The argument groups a use-site parse set aside; always empty for a declaration, which
        -- parses its arguments rather than deferring them. See parse_argument's use-site mode.
        exprs = p.exprs,
        -- Every group, either mode - what check_declarations walks looking for a nested definition.
        groups = p.groups,
        --[[ The BOXES, for anything that draws a name rather than reading it - see free_var and
        base_under_limits. `var_nodes[k]` is the run of nodes standing at parameter k; `base_nodes`
        is the base with its accents and without its arguments. Both are the user's own mexpr, never
        a copy, so a caller must not edit through them. ]]
        var_nodes = p.var_nodes,
        base_nodes = p.base_nodes,
        --[[ The supsub among `base_nodes` whose limits are the name's ARGUMENTS, or nil. A drawing
        of the name alone replaces it with its own base; see the note where it is set. ]]
        base_drop = p.base_drop,
        -- How many units the name took, for a caller reading a name out of a longer row.
        consumed = p.consumed,
    }
end

--[[ @brief A row read as the DECLARATION of a name.
-- |
-- | THE LEFT-HAND SIDE OF A DEFINITION: the pattern, its literals and its numbered free variables.
-- | Superscripts are REFUSED here - a name has no exponent, so `f^2` is not a name - which is the
-- | asymmetry parse_use exists on the other side of. The whole row must be the name.
-- |
-- | @param fontset    fontset - NOT USED; kept so every public entry here reads the same way
-- | @param container  mexpru.container - checked
-- | @return pattern | nil, string, node, marks - the pattern: {name, vars, arity, tokens, text,
-- |         marks, sups, exprs, groups, var_nodes, base_nodes, base_drop, consumed}; or nil, the
-- |         reason it is not a name, the node to blame, and the marks painted so far
-- |
-- | @date 2026-09-13 18:45
--]]
function mexpr_ast.parse_name(fontset, container)
    mexpru.check_container(container)
    --[[ `fontset` IS NOT USED. It is here so every public entry in this file reads the same way -
    build() and parse_domain() do need one - and because removing it would renumber the arguments at
    every call site. Flagged 2026-09-12 rather than quietly kept: it is a parameter that does
    nothing, and a reader is entitled to know that before passing one. ]]
    local p = new_parser()
    return read_pattern(p, row_units(container.root))
end

--[[ The token an argument group would have contributed to a DECLARATION's pattern, or nil when
it is not a literal at all.

That is the whole of the matcher's question. A declaration writes literals into its key and numbers
only its free variables - `F_{1,m}` is `F,sub,1,(1)` - so to test a use against it, each argument
has to be able to say "I am the literal `1`" or "I am not a literal". Built from the same spellings
the declaration emitted (`emit(text)` for a number, `'...'` for a quoted name) so the two are
comparable as strings, which is the only comparison this codebase does.
@date 2026-09-10 05:40 ]]
local function arg_literal(units)
    -- A quoted name is ONE unit since 2026-09-10 (pack_quotes), and the quotes are part of the
    -- token a declaration emitted, so they go back on.
    if #units == 1 and units[1].quoted then
        return "'" .. units[1].quoted .. "'"
    end

    local joined = units_text(units)
    if mexpr_ast.parse_number(joined) then
        return joined
    end
    return nil
end

--[[ @brief Does this use match that declaration?
-- |
-- | WALKED POSITION BY POSITION, because a use site cannot build the key by itself: it knows it has
-- | `F`, four subscript arguments and three call arguments, but only the DECLARATION knows which of
-- | those positions are parameters and which are literal parts of the name. Author, 2026-09-10:
-- | "only the declaration gives the shape".
-- |
-- | A `(k)` in the declaration is a parameter and swallows whatever the use put there; anything
-- | else is a literal and the use must have written exactly that. Markers - the base, `sub`, `()` -
-- | must agree outright, which is what stops `F_{a}` matching `F(a)`.
-- |
-- | STRING EQUALITY on tokens both sides emitted the same way. No unification: a declaration's
-- | literal is part of its NAME, so a use that wrote something else has named something else.
-- |
-- | @param use          mexpr_ast.use - checked
-- | @param decl_tokens  {string} | nil - the declaration's token list; nil matches like `{}`, which
-- |                     matches only another empty one
-- | @return args, nil, spec | nil, string - the use's argument rows that land in PARAMETER
-- |         positions, and `spec`: per argument position, 1 where the declaration pinned a literal
-- |         and 0 where it left a parameter (what resolve_use ranks by); or nil and why not
-- |
-- | @date 2026-09-13 18:45
--]]
function mexpr_ast.match_use(use, decl_tokens)
    --[[ `use` is dereferenced on the next line, so it is required. `decl_tokens` is not: a
    declaration with no tokens is a real thing to test against, and `{}` matches only another empty
    one, which is the correct answer rather than a special case. ]]
    USE_SHAPE.check(use, "use")
    local ut, dt = use.tokens or {}, decl_tokens or {}
    if #ut ~= #dt then
        return nil, "different shape"
    end
    --[[ `spec` records, per argument position, whether the declaration pinned it to a literal (1)
    or left it open (0). It is what ranks two declarations that both match - see resolve_use. ]]
    local args, slot, spec = {}, 0, {}
    for i = 1, #dt do
        local u_tok, d_tok = ut[i], dt[i]
        local u_is_slot = u_tok:match("^%(%d+%)$") ~= nil
        if u_is_slot then
            slot = slot + 1
            if d_tok:match("^%(%d+%)$") then
                spec[#spec + 1] = 0
                args[#args + 1] = use.args[slot]
            else
                spec[#spec + 1] = 1
                --[[ The declaration put a LITERAL here, so the use must have written the same one.
                A variable or an expression in that position does not match: it would be naming a
                different thing that merely looks similar. ]]
                if arg_literal(use.args[slot] or {}) ~= d_tok then
                    return nil, "literal mismatch at " .. d_tok
                end
            end
        elseif u_tok ~= d_tok then
            return nil, "shape differs at " .. d_tok
        end
    end
    return args, nil, spec
end

--[[ Which of two matches is more specific: 1 if `a` is, -1 if `b` is, 0 if neither.

POSITION BY POSITION, LEFTMOST FIRST, a literal beating an open slot. Specificity is only a PARTIAL
order on its own - `a_{1,m}` and `a_{n,2}` both match `a_{1,2}` and neither dominates the other -
so a rule is needed to make it total, and the author's is the leftmost difference. His words,
2026-09-10: "that ambiguity in a_{1,m} a_{n,2} should be again rather logged and the first matching
will be considered more exact than the second parameter matching".

Zero comes back only for two declarations that pinned exactly the same positions, which is a real
tie and not something an order can break.
@date 2026-09-10 09:40 ]]
local function more_specific(a, b)
    for i = 1, math.max(#a, #b) do
        local x, y = a[i] or 0, b[i] or 0
        if x ~= y then
            return x > y and 1 or -1
        end
    end
    return 0
end

--[[ @brief Which declaration this use means: the most specific match, or why there is none.
-- |
-- | EVERY DECLARATION IS TRIED, in list order, since none can be looked up by a key the use cannot
-- | construct. Zero matches is "not declared".
-- |
-- | THE MOST RESTRICTIVE MATCH WINS - a literal pinned leftmost beats an open parameter (see the
-- | comment inside). Only a GENUINE TIE, two declarations pinning exactly the same positions, is an
-- | error, because picking one silently is how a formula ends up meaning something nobody wrote.
-- |
-- | @param use    mexpr_ast.use - forwarded to match_use, which checks it
-- | @param decls  {mexpr_ast.decl} | nil - checked element by element; nil is no declarations
-- | @return hit | nil, string, integer - {decl, args, spec, shadowed}, where `shadowed` lists the
-- |         texts of the other matches when there were several; or nil, the reason, and the number
-- |         of matches (0 for none, >1 for a tie)
-- |
-- | @note THE COUNT IS WHAT read_factor NEEDS: it tries several extents of a row and reads the ones
-- |       that do not resolve some other way, which would bury a tie as "not declared" if it could
-- |       only see that resolution failed.
-- |
-- | @date 2026-09-13 18:45
--]]
function mexpr_ast.resolve_use(use, decls)
    --[[ `use` is only FORWARDED to match_use, which checks it. The declarations are not: this
    walks `d.tokens` on each, so a wrong element is dereferenced here. ]]
    check_decls(decls, "decls")
    local hits = {}
    for _, d in ipairs(decls or {}) do
        local args, _, spec = mexpr_ast.match_use(use, d.tokens)
        if args then
            hits[#hits + 1] = {decl = d, args = args, spec = spec}
        end
    end
    if #hits == 0 then
        return nil, "no declaration matches", 0
    end
    if #hits == 1 then
        return hits[1]
    end

    --[[ THE MOST RESTRICTIVE MATCH WINS. Author, 2026-09-10: "let's try the most restrictive one".
    A declaration that pinned a position to a literal said more about what it names than one that
    left the position open, so `a_{1,m}` takes `a_{1,2}` from `a_{n,m}`.

    This REPLACED "exactly one candidate or it is an error" (his earlier rule, same day) for
    everything except a genuine tie. The tie is what is left of it: two declarations that pinned
    exactly the same positions are the same shape, and nothing here can choose between them.

    THE LOSERS COME BACK rather than being dropped, because the ranking is a stand-in for a check
    that does not exist yet. What should really decide between two matching declarations is their
    TYPES, and until there are types the honest thing is to say which others were possible. ]]
    local best = hits[1]
    for i = 2, #hits do
        if more_specific(hits[i].spec, best.spec) > 0 then
            best = hits[i]
        end
    end
    local shadowed, tied = {}, {}
    for _, h in ipairs(hits) do
        if h ~= best then
            local cmp = more_specific(best.spec, h.spec)
            shadowed[#shadowed + 1] = h.decl.text
            if cmp == 0 then
                tied[#tied + 1] = h.decl.text
            end
        end
    end
    if #tied > 0 then
        return nil, "matches " .. #hits .. " equally: " .. best.decl.text .. " / "
                .. table.concat(tied, " / "), #hits
    end
    best.shadowed = shadowed
    return best
end

--[[ THE `opts` parse_use_units TAKES - every option it understands, and nothing else.

Declared through sealed.lua like every other container here, and checked with `check_keys` rather
than `wrap`: an options table arrives already built from a call-site literal, so its keys - misspelt
ones included - are present before a seal could fire on them. See that function for why.

A misspelt option here is silently PERMISSIVE, which is what makes it worth checking at all:
`no_call` missed means a call IS read, and the use resolves against the wrong declaration.
@date 2026-09-12 18:30 ]]
local USE_OPTS = sealed.declare("mexpr_ast", "use opts", {
    no_call = "do not read a bracket group as a call - the caller knows it is not one",
    partial = "accept a use that stops early; `consumed` says how far it got",
})

--[[ @brief Reads a unit list as a USE of a name, rather than a declaration of one.
-- |
-- |     f(34)   ->  key "f(),(1)",    args {<the 34 row>}
-- |     a_{n+1} ->  key "a,sub,(1)",  args {<the n+1 row>}
-- |
-- | ONE KEY, and an argument NEVER contributes to it, whatever is written in it. Author,
-- | 2026-09-10: "the name of `f(34)`, evaluated in expr context is still `f(),(1)`, that is the
-- | signature of the function, it gives it it's identity, 34 is only the argument".
-- |
-- | WHICH DECLARATION IT RESOLVES TO IS A DIFFERENT QUESTION, answered by resolve_use - where a
-- | declaration that pinned the position, `F(),0`, wins over `F(),(1)` for `F(0)`.
-- |
-- | HALF THE JOB, deliberately. This hands back the argument rows untouched; it does NOT resolve
-- | or build anything. The declarations are consulted DURING the read only to decide whether a
-- | decorated group is an argument or part of the name.
-- |
-- | @details POWERS ARE ALLOWED, unlike in parse_name: `f^2(x)` is a use of `f`, and the power
-- |          comes back in `sups` for the expression parser to apply.
-- |
-- | @param units  {unit} - as row_units builds them
-- | @param decls  {mexpr_ast.decl} | nil
-- | @param opts   table | nil - checked by key against USE_OPTS:
-- |                 no_call  do not read a following bracket group as a call
-- |                 partial  the name may stop before the units do; `consumed` says where
-- | @return mexpr_ast.use | nil, string, node, marks - sealed {key, tokens, args, sups, marks,
-- |         consumed}; or nil, the reason the units are not a name, the node to blame, and marks
-- |
-- | @date 2026-09-13 18:45
--]]
function mexpr_ast.parse_use_units(units, decls, opts)
    assert(type(units) == "table", "parse_use_units needs a unit list, as row_units builds")
    assert(decls == nil or type(decls) == "table", "decls must be a declaration list, or nil")
    USE_OPTS.check_keys(opts, "opts")

    --[[ POWERS ARE ALLOWED HERE AND REFUSED IN A DECLARATION, and the asymmetry is the point:
    `f^2(x)` is a use of `f`, so the power is an operation ON the reference and comes back in
    `sups` for the expression parser to apply. A definition of `f^2` is not a name at all - a name
    has no superscript - which is what parse_name's `no_sups` default keeps saying. Same parser,
    opposite answer, because the question is different. ]]
    local p = new_parser()
    p.arg_slots = true
    p.no_sups = false
    --[[ The declarations are needed DURING the parse, not only after it: whether a decorated group
    is an argument or part of the name is decided by whether anything answers to it. ]]
    p.decls = decls
    --[[ `partial` lets the name stop before the units do, and `no_call` refuses to swallow a
    bracket group that follows the base. Together they are how read_factor asks for the two - and
    only two - extents a name can have in a row. ]]
    p.partial = opts and opts.partial
    p.no_call = opts and opts.no_call

    local res, err, node, marks = read_pattern(p, units)
    if not res then
        return nil, err, node, marks
    end
    return USE_SHAPE.wrap{key = res.text, tokens = res.tokens, args = res.exprs or {},
            sups = res.sups or {}, marks = res.marks, consumed = res.consumed}
end

--[[ @brief A whole row read as a USE of a name.
-- |
-- | THE CONTAINER FORM OF parse_use_units above, which carries the reasoning; this only turns the
-- | row into units first. Both exist because a relation's SIDE is a unit list with no container of
-- | its own.
-- |
-- | @param fontset    fontset - NOT USED; kept so every public entry here reads the same way
-- | @param container  mexpru.container - checked
-- | @param decls      {mexpr_ast.decl} | nil
-- | @return as parse_use_units, with no options
-- |
-- | @date 2026-09-13 18:45
--]]
function mexpr_ast.parse_use(fontset, container, decls)
    mexpru.check_container(container)
    --[[ `fontset` IS NOT USED. It is here so every public entry in this file reads the same way -
    build() and parse_domain() do need one - and because removing it would renumber the arguments at
    every call site. Flagged 2026-09-12 rather than quietly kept: it is a parameter that does
    nothing, and a reader is entitled to know that before passing one. ]]
    return mexpr_ast.parse_use_units(row_units(container.root), decls)
end

--[[ CASE 4: the relations, and the only thing that splits an expression in two.
@date 2026-09-10 05:40 ]]
local RELATIONS = {
    ["="]  = ast.new_eq,
    ["<"]  = ast.new_ineq_less,
    [">"]  = ast.new_ineq_greater,
    ["\\le"] = ast.new_ineq_leq,
    ["\\ge"] = ast.new_ineq_geq,
    --[[ Added 2026-09-10 alongside "Bigop scoping" (docs/phase2_design.md), general purpose rather
    than bigop-only - a bigop's sub/sup constraints are built through this exact same door. The
    full membership/inclusion family, six glyphs: whether a given one reaches the row as a single
    keystroke or a digraph (`\subseteq` is `\subset` then `=`) is irrelevant here - each is already
    one real glyph in char.lua's catalog by the time a row holds it, same as `\le`/`\ge` above. ]]
    --[[ `x \\to 0`, which is how a limit's subscript is written. It reaches the row as
    `\\rightarrow` - the arrow glyph the catalog has - and `\\to` is only LaTeX's shorter
    spelling of the same character, so there is nothing else to recognise. ]]
    ["\\rightarrow"] = ast.new_tends,
    [IN_DESC] = ast.new_in,
    ["\\ni"] = ast.new_ni,
    ["\\subset"] = ast.new_subset,
    ["\\subseteq"] = ast.new_subseteq,
    ["\\supset"] = ast.new_supset,
    ["\\supseteq"] = ast.new_supseteq,
}

--[[ AN OVERPRINTED RELATION - `\ne` - read as the one symbol the rest of the app already treats it
as: no font draws it, so the row holds TWO atoms (zero-advance `\not`, then `=`) where the reader
sees one. KEYED ON BOTH HALVES, not on "an overprint then a relation" - `\!` is also zero-advance
and negates nothing. Only `=` is paired, because ast.lua has INEQ_NEQ and no other negated node.
Read separately, `a \ne b` would build `a = b` - the exact opposite, in a well-formed-looking tree.
@date 2026-09-10 06:10 ]]
local OVERPRINT_RELATIONS = {
    ["\\not"] = {["="] = ast.new_ineq_neq},
}

--[[ The relation starting at unit `i`, as {op, size, desc}, or nil - plus a reason when the units
there are a relation nobody has a node for.

`size` is how many units it occupies, which is the whole reason this is a function and not a table
lookup: an overprinted relation is two units wide and the splitter has to skip both, or the negation
slash is left behind on one side of the relation it belongs to.
@date 2026-09-10 06:10 ]]
local function relation_at(units, i)
    local d = atom_desc(units[i].atom)
    if not d then
        return nil
    end
    if char.advance_of(d) == 0 then
        local nd = units[i + 1] and atom_desc(units[i + 1].atom)
        local by = OVERPRINT_RELATIONS[d]
        local op = by and nd and by[nd]
        if op then
            return {op = op, size = 2, desc = d .. nd}
        end
        if nd and (by or RELATIONS[nd]) then
            return nil, "the overprinted pair `" .. d .. nd .. "` has no node in the AST"
        end
        -- Not a relation at all; the factor reader will say what it made of it.
        return nil
    end
    if RELATIONS[d] then
        return {op = RELATIONS[d], size = 1, desc = d}
    end
    return nil
end

--[[ The variable node for `name`, made once per parse and referenced thereafter.

Every mention is a VREF to one VAR, which is what `x f(x)` needs: two occurrences of one variable,
not two variables. ast.new_vref takes an id rather than a name, so the AST enforces this shape - a
name cannot become a reference without a variable to point at.
@date 2026-09-10 06:20 ]]
local function var_ref(ctx_parse, name)
    local v = ctx_parse.vars[name]
    if not v then
        v = ast.new_var(ctx_parse.ns, name)
        ctx_parse.vars[name] = v
    end
    return ast.new_vref(ctx_parse.ns, v)
end

--[[ THE EXPRESSION CASCADE, one layer per precedence level:

    build_relation   splits on  =  <  >  \le  \ge      (case 4)
      build_sum      splits on top-level  +  -           (case 2)
        build_product  segments into factors             (multiplication)
          read_factor    one name-use, number, or bracket group

Each layer hands the layer below a UNIT LIST, never a container, which is what lets a relation's
side, a call's argument and a superscript's row all go through the same parser. Before this, an
argument had its own miniature parser that knew only "number" and "single letter", so `f(2x+1)`
failed in a place where the row parser would have succeeded - two parsers for one grammar, free to
drift apart.

The preamble checks on these LOCALS are deliberate, not left over: Lua has no type system, so each
cascade step re-validates what it is handed, and a bug in this file's own slicing crashes HERE,
named, instead of somewhere downstream.
@date 2026-09-10 04:30 ]]
local build_expr

--[[ Forward-declared: a bigop's sub/sup constraints (read_constraints) are built through
build_relation - the full cascade - since a constraint IS a relation (`i=1`, `i \in S`).
@date 2026-09-10 ]]
local build_relation

--[[ Forward-declared: a BRACKET's contents are parsed at the top of the cascade (read_factor), so
the name has to exist before that function is written. @date 2026-09-11 17:20 ]]
local build_connective

--[[ Forward-declared: a bigop's unbracketed body (read_bigop) is read at PRODUCT order - whatever
factors remain in the current term - so a top-level `+` is never in reach without explicit parens.
@date 2026-09-10 ]]
local build_product

--[[ `units[i..j]` as a list of its own. The unit tables are shared, not copied - nothing downstream
mutates them except `.call`, which read_pattern sets on a base unit it owns. ]]
local function slice(units, i, j)
    local out = {}
    for k = i, j do
        out[#out + 1] = units[k]
    end
    return out
end

--[[ The indices of `units` at bracket depth 0, in order - the one walk the top-level splitters
share: build_relation splits on the one relation there, build_connective on the first connective.
A bracket pair is stepped over whole; the caller decides what each index means to it.
@date 2026-09-14 ]]
local function top_level_indices(units)
    local out, depth = {}, 0
    for i, u in ipairs(units) do
        local b = bracket_of(u)
        if b then
            depth = depth + (b.is_open and 1 or -1)
        elseif depth == 0 then
            out[#out + 1] = i
        end
    end
    return out
end

--[[ The power written on a factor that is not a name - a number, a bracket group, a free variable.

A SUBSCRIPT IS REFUSED rather than ignored. On a declared name a subscript is part of the identity
and read_pattern has already consumed it; anywhere else it means something nobody has decided yet,
and dropping it would build a tree for a formula that was not written.
@date 2026-09-10 04:30 ]]
local function apply_power(ctx_parse, node, u)
    if not u then
        return node
    end
    if u.sub then
        return nil, "not parsed yet: a subscript on something that is not a declared name"
    end
    if u.sup then
        local exp, err = build_expr(ctx_parse, units_of(row_children(u.sup)))
        if not exp then
            return nil, err
        end
        return ast.new_exp(ctx_parse.ns, node, exp)
    end
    return node
end

--[[ The default every glyph otherwise carries (mexpr_t's own initializer), and the walk that sets
it. The declared-name orange itself lives in mexpru beside the differential bar's, because the
writer paints a call's built letters with the same value. @date 2026-09-16 ]]
local GLYPH_DEFAULT_COLOR = 0xffeeeeee

--[[ Sets every SYMBOL at or under `node` to `color`, touching nothing else: a rule keeps its own
colour (a differential's green bar is one), and a vert or a dress is walked through to the symbols
it draws. The one walk behind both the reset at the parse's start and the painting of a resolved
name's root. @date 2026-09-16 ]]
local function paint_symbols(node, color)
    if not node then
        return
    end
    if node.type == vc.MEXPR_TYPE_SYMBOL then
        node.color = color
    end
    for _, child in ipairs(mexpru.child_links(node)) do
        paint_symbols(child, color)
    end
end

--[[ Paints blue every glyph under `node` whose tagged ast node is a reference to one of `names` -
the bound-variable colour for a binder's caught apparitions (the author, 2026-09-16: "the
variable besides it should be blue, indicating an linked var and it's aparitions inside the
integral should be blue also"). The tags the parse left name which glyph draws which reference and
the reference names its variable, so "every x inside the integral" is exactly the glyphs whose
reference resolves to a variable called one of these. A global of the same name outside the
binder's own ink is not under this walk and keeps its orange; inside the scope the binder shadows
it, so blue is the honest reading there either way.
@date 2026-09-16 ]]
local function paint_bound_refs(ctx_parse, node, names)
    if not node then
        return
    end
    local id = mexpru.u(node).ast_draws
    if id then
        local n = ast.node_of(ctx_parse.ns, id)
        if n and n.type == ast.VREF then
            local var = ast.node_of(ctx_parse.ns, n[1])
            if var and names[var[1]] then
                paint_symbols(node, mexpru.BOUND_COLOR)
            end
        end
    end
    for _, child in ipairs(mexpru.child_links(node)) do
        paint_bound_refs(ctx_parse, child, names)
    end
end

--[[ A resolved name-use, as a node: its arguments built, and its powers wrapped around the result.

THE BASE GLYPH NAMES WHAT IT RESOLVED TO, the same two tags the free-letter branch writes, and for
the same two readers: ast_id so a click on a declared name says which node it is, ast_draws so the
writer can copy the name's own ink. Without the second one, a distributed copy of a declared
reference had nothing to draw - the write refused with "never drawn in the source" while the
transform itself had succeeded (reported live 2026-09-16). Tagged only when the base is one glyph's
ink - a letter with its dress, or an operator's vert - because that is what a copy can clone whole;
a quoted or digit-run base is several glyphs, and a copy of one of them would be a wrong drawing
rather than a refusal.
@date 2026-09-16 12:00 ]]
local function build_named(ctx_parse, use, hit, base_unit)
    local args = {}
    for _, a in ipairs(hit.args) do
        local node, aerr = build_expr(ctx_parse, a)
        if not node then
            return nil, aerr
        end
        args[#args + 1] = node
    end

    --[[ No arguments means a reference, not an application - `x` is a VREF, `f(x)` a CALL. The
    callee is the declaration's KEY, a string: the declaration lives in another box's namespace,
    and the key is what identifies it across the two. ]]
    local node
    if #args == 0 then
        node = var_ref(ctx_parse, hit.decl.text)
    else
        node = ast.new_call(ctx_parse.ns, hit.decl.text, table.unpack(args))
    end

    local d = base_unit and atom_desc(base_unit.atom)
    if d and (is_letter(d) or operator_name(base_unit.atom)) then
        tag_ast(base_unit, node)
        tag_draws(leaf_drawn_by(base_unit), node)
        -- The name's own glyphs go orange - the root alone, never the arguments below.
        paint_symbols(mexpru.undressed(leaf_drawn_by(base_unit)), mexpru.DECL_NAME_COLOR)
    end

    -- Powers wrap what they are applied to, innermost first.
    for i = #use.sups, 1, -1 do
        local exp, eerr = build_expr(ctx_parse, units_of(row_children(use.sups[i].row)))
        if not exp then
            return nil, eerr
        end
        node = ast.new_exp(ctx_parse.ns, node, exp)
    end
    return node
end

--[[ ONE FACTOR, starting at unit `i` - the node, and the index the next factor starts at; or nil,
nil, a reason. HOW FAR A FACTOR REACHES IS THE DECLARATIONS' ANSWER, not the row's: `a_{1}(x)` is a
call if something is declared with that shape and a product if `a_{1}` is declared alone, so the
extents this row admits are the ones that RESOLVE - and exactly one or it is an error, since two
readings are a genuine ambiguity. Only when nothing resolves is the factor a plain value: a numeral,
a bracket group, or a free variable.
@date 2026-09-10 04:30 ]]
--[[ THE TWO EXTENTS A NAME CAN HAVE, longest first: read_pattern reads a base, then AT MOST ONE
bracketed group, and then nothing - so a name ends where its base does or after that one group, and
there is no third place. That is what replaced a retry loop over every end position, all but two of
which could never parse.
@date 2026-09-10 12:40 ]]
--[[ EVERY GROUP BIG OPERATOR, BY HOW IT IS WRITTEN - a GLYPH ("\\sum", by atom_desc) or a WORD
("lim", by operator_name); nothing downstream cares which. A word operator is a BINDER, not a name:
`min_{x}` declares `x`, where `sin(x)` applies one. A declaration still wins - name resolution runs
before this table in read_factor. `\int` is deliberately absent: its variable comes from a trailing
differential, so read_integral reads it instead.
@date 2026-09-11 10:20 ]]
--[[ DERIVED from ast.GROUP_BIGOP_DRAW's reverse, rather than written out: spelling -> type is
the parse-side question, the draw table owns the spellings, and a second literal listing of the
same 13 rows is a mirror free to fall behind (the same fault the draw table was split out to
end). Added 2026-09-15 when the writer needed the forward direction. ]]
local BIGOP_BY_SPELLING = {}
for node_type, spelling in pairs(ast.GROUP_BIGOP_DRAW) do
    BIGOP_BY_SPELLING[spelling] = node_type
end

--[[ The constraint ROWS a sub or sup slot holds: a container's units are ONE constraint, unless
they are a single `vert` atom (mexpru.vert()'s own N-slots-stacked primitive, already user-buildable
via new_with_vert() - nothing new on the editing side), in which case each of its slots is its own
constraint. `container` may be nil (an untouched sub/sup), which is zero constraints, not one empty
one.
@date 2026-09-10 ]]
local function constraint_rows(container)
    if not container then
        return {}
    end
    local units = row_units(container)
    if is_untouched(units) then
        return {}
    end
    if #units == 1 then
        local uu = units[1].atom and mexpru.u(units[1].atom)
        if uu and uu.kind == "vert" and uu.slots then
            local rows = {}
            for _, slot in ipairs(uu.slots) do
                rows[#rows + 1] = row_units(slot)
            end
            return rows
        end
    end
    return {units}
end

--[[ Membership/inclusion is NOT symmetric the way `=` is: only the element side is ever eligible to
be a bigop's own variable, and a mirror relation (`\ni`, `\supset`) points the eligible side at the
OTHER operand. `=` and the numeric inequalities are absent on purpose - `i=j` spawning both sides is
the accepted behaviour there. Keyed by node type and read at ANY depth (not just the root), so a
boolean connective layer above a membership - when one exists - needs no change here.
@date 2026-09-10 ]]
local ASYMMETRIC_SPAWN_SIDE = {
    [ast.TENDS]    = 1, -- a \to b       - a is the one that varies; b is where it goes
    [ast.IN]       = 1, -- a \in b       - a is the element
    [ast.NI]       = 2, -- a \ni b       - b is the element  (== b \in a)
    [ast.SUBSET]   = 1, -- a \subset b   - a is the varying (sub)set
    [ast.SUBSETEQ] = 1,
    [ast.SUPSET]   = 2, -- a \supset b   - b is the varying (sub)set  (== b \subset a)
    [ast.SUPSETEQ] = 2,
}

--[[ Every name eligible to be spawned anywhere in `node` - a VREF's name counts, UNLESS it is only
reachable through the ineligible side of a membership/inclusion relation somewhere above it, in
which case that whole branch is never descended into at all. Not a resolution walk - it does not
care whether a name is free or declared, only whether it is mentioned in an eligible position -
`read_constraints` intersects this with `ctx_parse.free_order` to answer "and was it actually free".
@date 2026-09-10 ]]
local function harvest_eligible(ns, node, out)
    if not ast.is_node(node) then
        return
    end
    if node.type == ast.VREF then
        local target = ast.node_of(ns, node[1])
        if target and target.type == ast.VAR then
            out[target[1]] = true
        end
        return
    end
    local side = ASYMMETRIC_SPAWN_SIDE[node.type]
    if side then
        harvest_eligible(ns, node[side], out)
        return
    end
    for i = 1, #node do
        harvest_eligible(ns, node[i], out)
    end
end

--[[ Builds every constraint row a sub or sup slot holds, and harvests the free names that showed up
in each (the eligible side only, via harvest_eligible). `ctx_parse.free_order` is reset per
constraint and drained into one ordered, deduped list - the order is part of the tree, since these
names become the operator's variables in it.
@date 2026-09-10 ]]
local function read_constraints(ctx_parse, container)
    local rows = constraint_rows(container)
    local nodes, free_list, seen = {}, {}, {}
    local outer = ctx_parse.free_order
    for _, row in ipairs(rows) do
        ctx_parse.free_order = {}
        local node, err = build_relation(ctx_parse, row)
        if not node then
            ctx_parse.free_order = outer
            return nil, err
        end
        nodes[#nodes + 1] = node

        local eligible = {}
        harvest_eligible(ctx_parse.ns, node, eligible)

        --[[ WALKED IN FIRST-SEEN ORDER, which is load-bearing: these names fill the operator's
        variable slots in this order, and structural equality reads it. A `pairs` walk over a set
        here once built `\sum_{i=j}(i+j)` as `i,j` in one run and `j,i` the next - Lua randomises
        the string-hash seed per process. `seen` collapses duplicates, keeping the first. ]]
        for _, name in ipairs(ctx_parse.free_order) do
            if eligible[name] and not seen[name] then
                seen[name] = true
                free_list[#free_list + 1] = name
            end
        end
    end
    ctx_parse.free_order = outer
    return nodes, nil, free_list
end

--[[ One bound of an integral as a VALUE, not a constraint: `\\int_{0}^{1}` says where the
integration starts and stops, and 0 declares nothing - so build_expr, not build_relation, and
nothing here becomes a variable. nil with no error when there is no bound: an indefinite integral
is a real integral.
@date 2026-09-11 03:30 ]]
local function read_bound(ctx_parse, container, which, glyph)
    local rows = constraint_rows(container)
    if #rows == 0 then
        return nil, nil
    end
    if #rows > 1 then
        return nil, glyph .. "'s " .. which .. " bound is a stack - an integral takes one value "
                .. "there, not a list"
    end
    local node, err = build_expr(ctx_parse, rows[1])
    if not node then
        return nil, err
    end
    return node, nil
end

--[[ An integral: INT(var, from, to, body), the variable coming from the trailing differential.
THE PAIR IS WHAT MAKES THIS READABLE AT ALL - `\\int` and its `d` are a bracket pair, so the body is
exactly what lies between the halves and the variable exactly what follows the `d`; nothing is
scanned for or guessed. Not read_bigop: the variable arrives after the body, the bounds are VALUES
that spawn nothing, and the body ENDS at the closing half instead of swallowing the term. An
unpaired `\\int` (saved or pasted before the pairing existed) gets a refusal saying what to do.
@date 2026-09-11 03:30 ]]
local function read_integral(ctx_parse, units, i, glyph, sub_container, sup_container)
    local open = bracket_of(units[i])
    if not open or not open.is_open or not open.peer then
        return nil, nil, glyph .. " has no differential paired with it - retype it so its `d` is "
                .. "created with it (a saved or pasted integral does not carry the pairing yet)"
    end

    --[[ BY PEER, never by depth. resolve_bracket_pairs matches this way for the same reason: a
    depth walk invents a pairing nobody made, and here it would also stop at the wrong `d`. ]]
    local close_i
    for j = i + 1, #units do
        if units[j].atom and mexpru.u(units[j].atom) == open.peer then
            close_i = j
            break
        end
    end
    if not close_i then
        return nil, nil, glyph .. "'s differential is not in this row - the two halves were "
                .. "separated"
    end

    --[[ THE VARIABLE IS OUTSIDE THE PAIR, one unit past the `d`. `\\int f(x) dx` closes on the `d`
    and declares `x` after it, which is where the notation actually puts it. ]]
    local var_i = close_i + 1
    if var_i > #units then
        return nil, nil, glyph .. " has no variable after its `d`"
    end
    local vd = atom_desc(units[var_i].atom)
    if not is_letter(vd) then
        return nil, nil, glyph .. "'s variable must be a letter, not `" .. tostring(vd) .. "`"
    end
    --[[ WITH ITS DECORATIONS, exactly as everywhere else a variable name is built - `d\\vec{x}`
    integrates over `x\\vec`, which is not `x`. See var_ref's own callers. ]]
    local vname = vd .. dress_suffix(units[var_i].node)

    local body, body_err = build_expr(ctx_parse, slice(units, i + 1, close_i - 1))
    if not body then
        return nil, nil, glyph .. " needs an integrand: " .. tostring(body_err)
    end

    local from, from_err = read_bound(ctx_parse, sub_container, "lower", glyph)
    if from_err then
        return nil, nil, from_err
    end
    local to, to_err = read_bound(ctx_parse, sup_container, "upper", glyph)
    if to_err then
        return nil, nil, to_err
    end

    --[[ ast.new_int DECLARES the variable and catches the body's free mentions of it - so `x` in
    the integrand stops being free and starts meaning this integral's `x`. Built last for that
    reason: catching needs the body to exist. ]]
    --[[ THE CLOSING `d` IS GREEN and ITS VARIABLE BLUE - the differential's own colour on the
    structural mark, the bound-variable colour on what it links (the author, 2026-09-16: the
    palette is "globals get orange, green for structural", and a binder's variable "should be
    blue, indicating an linked var and it's aparitions inside the integral should be blue also").
    Every caught apparition in the integrand goes blue with it. Painted at the end of the
    validations, so an integral that does not read paints nothing; the parse's opening reset puts
    them back like any symbol. ]]
    units[close_i].atom.color = mexpru.DIFF_COLOR
    local var_leaf = mexpru.undressed(units[var_i].node)
    if var_leaf then
        var_leaf.color = mexpru.BOUND_COLOR
    end
    local bound = {[vname] = true}
    for k = i + 1, close_i - 1 do
        paint_bound_refs(ctx_parse, units[k].node, bound)
    end
    local node = ast.new_int(ctx_parse.ns, vname, to, from, body)
    --[[ THE VARIABLE'S OWN GLYPH IS TAGGED with the var it names, the tag every reference carries:
    the writer clones a name's ink from the tag, and without this one the `dx`'s x had no drawing
    to clone - a written integral would refuse on its last glyph. ]]
    if var_leaf then
        tag_draws(var_leaf, node[1])
    end
    --[[ Stops after the variable, unlike a group operator, which eats the rest of its term. The
    differential is a closing bracket and a closing bracket ends a factor, so
    `\\int_0^1 x dx \\cdot y` leaves `y` for build_product exactly as `(...)y` would. ]]
    return node, var_i + 1
end

--[[ A group big operator: reads the sub/sup constraint rows, spawns whichever names are free in
the sub and not the sup (sub-minus-sup), then reads the body at PRODUCT ORDER - the REST of this
factor's own term, same as any factor that eats what follows it. A top-level `+` never reaches here
(build_sum has already split it off), so `\sum_{i}i^2` reads its whole remaining term and reaching
past a `+` needs the parens that already make it one factor.

ONE SHAPE however the row was typed: a plain `\sum_{i=1}^{n}` and a `\sum\limits_{...}` are the
same node with its sides placed differently, and `unit()` hands back the glyph as `.atom` and the
limits as `.sup`/`.sub` either way. Only where the limits are DRAWN differs, and that was never this
parser's question.
@date 2026-09-10 ]]
local function read_bigop(ctx_parse, units, i, glyph, sub_container, sup_container)
    local node_type = BIGOP_BY_SPELLING[glyph]
    if not node_type then
        return nil, nil, "not parsed yet: " .. tostring(glyph)
    end

    local subs, sub_err, sub_free = read_constraints(ctx_parse, sub_container)
    if not subs then
        return nil, nil, sub_err
    end
    local sups, sup_err, sup_free = read_constraints(ctx_parse, sup_container)
    if not sups then
        return nil, nil, sup_err
    end

    local sup_free_set = {}
    for _, name in ipairs(sup_free) do
        sup_free_set[name] = true
    end
    local vars = {}
    for _, name in ipairs(sub_free) do
        if not sup_free_set[name] then
            vars[#vars + 1] = name
        end
    end
    if #vars == 0 then
        return nil, nil, glyph .. " has no new variable in its sub - everything free there is "
                .. "also free in its sup, so nothing is spawned"
    end

    local rest = slice(units, i + 1, #units)
    local body, body_err = build_product(ctx_parse, rest)
    if not body then
        return nil, nil, glyph .. " needs a body: " .. tostring(body_err)
    end
    --[[ A BODY THAT CAME OUT AS A CELL IS UNWRAPPED, the same fix read_derivative carries: a
    bracket group that is the body-product's one factor gets a CELL from maybe_cell, but the parens
    there are the BODY'S delimiters, not user grouping - and left on, the CELL made the whole
    formula unwritable (ast_mexpr refuses CELLs), so `\sum_{i=0}^{n}(i+i)` could not be written
    back at all. The node delimits its own body; the writer brackets an add-like body by
    precedence, the reparse's CELL comes back off, and the round trip holds. ]]
    if body.type == ast.CELL then
        body = body[1]
    end

    --[[ THE SPAWNED VARIABLES ARE BLUE - the bound-variable colour, on every mention the operator
    linked: the constraint rows that declared them and the body's caught apparitions (the palette
    ruling, 2026-09-16 - the integral's `dx` wears the same blue). The constraints' glyphs live in
    the operator's own sub/sup rows, not in this term's units, so those trees are walked too. ]]
    local bound = {}
    for _, name in ipairs(vars) do
        bound[name] = true
    end
    if next(bound) then
        if sub_container then
            for _, u in ipairs(row_units(sub_container)) do
                paint_bound_refs(ctx_parse, u.node, bound)
            end
        end
        if sup_container then
            for _, u in ipairs(row_units(sup_container)) do
                paint_bound_refs(ctx_parse, u.node, bound)
            end
        end
        for _, u in ipairs(rest) do
            paint_bound_refs(ctx_parse, u.node, bound)
        end
        --[[ AND THE DECLARATION IS MARKED, without retagging it: a big operator's declaration IS
        its first constraint mention (`k=0` declares k), and that glyph's reference tag is doing
        real work - a click resolves through it, the writer copies from it. So it keeps the tag
        and carries a SECOND marker, `u.ast_declares`, naming the var it spells; the link
        collector reads both. Found live 2026-09-16 as "the t is drawn bound but the k is not" -
        the sum's variables linked nothing while the integral's did. The marker is written AFTER
        the node is built, because the catch repoints the BODY's mentions to the spawned var
        while the constraint's own stays where it was - so the var is found through the body
        (post-catch, the real one) and only the GLYPH comes from the constraint. ]]
    end

    local node = ast.new_group_bigop(ctx_parse.ns, node_type, vars, sups, subs, body)
    if next(bound) then
        local var_of_name = {}
        local function find_spawned(n)
            if type(n) ~= "table" or not n.type then
                return
            end
            if n.type == ast.VREF then
                local v = ast.node_of(ctx_parse.ns, n[1])
                if v and bound[v[1]] and not var_of_name[v[1]] then
                    var_of_name[v[1]] = v.id
                end
                return
            end
            for k = 1, #n do
                find_spawned(n[k])
            end
        end
        find_spawned(body)
        local declared = {}
        local function mark_decl(node_g)
            if not node_g then
                return
            end
            local id = mexpru.u(node_g).ast_draws
            if id then
                local n = ast.node_of(ctx_parse.ns, id)
                if n and n.type == ast.VREF then
                    local v = ast.node_of(ctx_parse.ns, n[1])
                    local spawned = v and var_of_name[v[1]]
                    if spawned and not declared[v[1]] then
                        declared[v[1]] = true
                        mexpru.u(node_g).ast_declares = spawned
                    end
                end
            end
            for _, child in ipairs(mexpru.child_links(node_g)) do
                mark_decl(child)
            end
        end
        if sub_container then
            for _, u in ipairs(row_units(sub_container)) do
                mark_decl(u.node)
            end
        end
        if sup_container then
            for _, u in ipairs(row_units(sup_container)) do
                mark_decl(u.node)
            end
        end
    end

    -- The body consumed everything remaining in this term - nothing is left for build_product's
    -- own caller to read after this factor.
    return node, #units + 1
end

local function name_extents(ctx_parse, units, i)
    local tail = slice(units, i, #units)
    local out = {}
    local greedy = mexpr_ast.parse_use_units(tail, ctx_parse.decls, {partial = true})
    if greedy then
        out[#out + 1] = greedy
    end
    --[[ Only worth asking when the greedy read swallowed a call: without one the two readings are
    the same, and `f(x)` would otherwise be offered twice and report itself as ambiguous. ]]
    if greedy and greedy.consumed and greedy.consumed > 1 then
        local bare = mexpr_ast.parse_use_units(tail, ctx_parse.decls,
                {partial = true, no_call = true})
        if bare and bare.consumed ~= greedy.consumed then
            out[#out + 1] = bare
        end
    end
    return out
end

--[[ A DERIVATIVE - a fraction whose one `diff` bit is set (mexpru.mark_diff), read as the fourth
binder.

THE SIGNS ARE COLLECTED, NEVER SPAWNED: every `d` in the numerator and denominator is the
differential sign by construction - no variable may be named d here (the author, 2026-09-15) - so
the d's are skipped as syntax and never reach var_ref. The LETTERS beyond the denominator's sign
are the declared variables, each with its dress exactly as a name carries one everywhere else.

THE NUMERATOR IS A SIGN TO A POWER, for now - `d` or `∂`, optionally with an exponent (the
order). Anything else in it is not parsed yet rather than guessed at. The BODY is read at PRODUCT
order over the rest of the term, the bigop rule verbatim: product-like needs no wrapping, an add
needs its parens.

@date 2026-09-15 15:00 ]]
local function read_derivative(ctx_parse, units, i, u0, fr)
    local num_units, den_units = row_units(fr.num), row_units(fr.den)
    if #num_units == 0 or #den_units == 0 then
        return nil, nil, "a differential needs both its sign rows"
    end

    local first_desc = atom_desc(num_units[1].atom)
    local partial = (first_desc == "\\partial")
    if not (partial or first_desc == "d") then
        return nil, nil, "a differential's numerator is d or the diffsign, not `"
                .. tostring(first_desc) .. "`"
    end

    local order = 1
    if num_units[1].sup then
        local exp, eerr = build_expr(ctx_parse, units_of(row_children(num_units[1].sup)))
        if not exp then
            return nil, nil, "a differential's order did not read: " .. tostring(eerr)
        end
        if exp.type ~= ast.NUM or exp[2] ~= 1 or exp[1] < 1 then
            return nil, nil, "a differential's order must be a whole number"
        end
        order = exp[1]
    end
    if #num_units > 1 then
        return nil, nil, "not parsed yet: a differential's numerator is one sign to a power"
    end

    --[[ THE VARIABLES: every unit past the sign that is a letter, with its dress; every d or ∂ is
    another sign and skipped. Anything else - a digit, a bracket - is not parsed yet. ]]
    local vars = {}
    for j = 1, #den_units do
        local du = den_units[j]
        local d = atom_desc(du.atom)
        if d == "d" or d == "\\partial" then
            if (d == "\\partial") ~= partial then
                return nil, nil, "a differential mixes its signs - d and the diffsign"
            end
        elseif is_letter(d) then
            if du.sup or du.sub then
                return nil, nil, "not parsed yet: a decorated variable in a differential"
            end
            vars[#vars + 1] = d .. dress_suffix(du.node)
        else
            return nil, nil, "not parsed yet: `" .. tostring(d) .. "` in a differential's sign row"
        end
    end
    if #vars == 0 then
        return nil, nil, "a differential declares no variable - nothing follows its sign"
    end

    local rest = slice(units, i + 1, #units)
    local body, berr = build_product(ctx_parse, rest)
    if not body then
        return nil, nil, "a differential needs a body: " .. tostring(berr)
    end
    --[[ A BODY THAT CAME OUT AS A CELL IS UNWRAPPED, because the parens there are the BODY'S
    DELIMITERS, not the user's grouping: `d/dx(a(x+y))` is bracketed because an add-like body
    needs wrapping (the product-order rule), and a bracket group that is the body-product's one
    factor gets a CELL from maybe_cell. Left on, the CELL made the whole formula unwritable -
    ast_mexpr refuses CELLs - so every distribute anywhere in a formula containing such a body
    refused at the write (found live 2026-09-15, reported as "distribute doesn't work on the +
    inside the derivative"). The node itself delimits the body, exactly as a bigop's does; and
    the round trip still holds: emit writes an add-like body bracketed by precedence, the reparse
    makes the CELL again, and this unwrap takes it back off - same tree both ways. ]]
    if body.type == ast.CELL then
        body = body[1]
    end

    -- The one bit is the truth; the order, the signs and the variables were all just re-derived
    -- from the glyphs, and the body consumed the rest of the term as any factor-eater does.
    local node = ast.new_diff(ctx_parse.ns, partial, order, vars, body)
    --[[ THE VARIABLES ARE BLUE, beside their signs and in the body - the bound-variable colour the
    integral's `dx` wears (the same palette ruling, 2026-09-16): the signs stay plain (the bar
    already says what the fraction is - and a `d` is a sign here, never a linked variable passed
    downwards; found live 2026-09-16, the signs painted blue because `d` is also a letter), the
    linked variables and their caught apparitions go blue, and nothing here touches a global of
    another name. The sign test is the same one the variable collection above applies. EACH LETTER
    IS ALSO TAGGED with the var it declares - found through the body's caught references, since
    new_diff keeps only the names - so the link collector can tell a declaration from a mention. ]]
    local var_node_of = {}
    local function find_vars(n)
        if type(n) ~= "table" or not n.type then
            return
        end
        if n.type == ast.VREF then
            local v = ast.node_of(ctx_parse.ns, n[1])
            if v and not var_node_of[v[1]] then
                var_node_of[v[1]] = v
            end
            return
        end
        for k = 1, #n do
            find_vars(n[k])
        end
    end
    find_vars(body)
    local bound = {}
    for j, du in ipairs(den_units) do
        local d = atom_desc(du.atom)
        if d ~= "d" and d ~= "\\partial" and is_letter(d) then
            local leaf = mexpru.undressed(du.node)
            local name = d .. dress_suffix(du.node)
            if leaf then
                leaf.color = mexpru.BOUND_COLOR
                if var_node_of[name] then
                    tag_draws(leaf, var_node_of[name])
                end
            end
            bound[name] = true
        end
    end
    for _, u in ipairs(rest) do
        paint_bound_refs(ctx_parse, u.node, bound)
    end
    tag_ast(u0, node)
    return node, #units + 1
end

local function read_factor(ctx_parse, units, i)
    local hits = {}
    for _, use in ipairs(name_extents(ctx_parse, units, i)) do
        local hit, why, count = mexpr_ast.resolve_use(use, ctx_parse.decls)
        if hit then
            hits[#hits + 1] = {use = use, hit = hit, stop = i + use.consumed - 1}
        elseif count and count > 1 then
            --[[ AN AMBIGUITY IS REPORTED, NOT STEPPED OVER. An extent that fails to resolve means
            "this is not where the name ends, read on"; several declarations answering to ONE extent
            means the row itself is ambiguous, and carrying on would report it as `no declaration
            matches` - the opposite of what happened. ]]
            return nil, nil, why
        end
    end
    if #hits > 1 then
        local names = {}
        for _, h in ipairs(hits) do
            names[#names + 1] = h.hit.decl.text
        end
        return nil, nil, "two readings of this factor: " .. table.concat(names, " / ")
    end
    if #hits == 1 then
        -- `units[i]` is the extent's base glyph, for build_named to tag what it resolves to.
        local node, err = build_named(ctx_parse, hits[1].use, hits[1].hit, units[i])
        if not node then
            return nil, nil, err
        end
        return node, hits[1].stop + 1
    end

    local u0 = units[i]
    local d = atom_desc(u0.atom)
    local b = bracket_of(u0)
    local fr = frac_of(u0)

    -- ---- CASE 3a: a big operator - see read_bigop for the constraint/body handling ------------
    do
        --[[ Two shapes read as the same thing here - see read_bigop's own note. A bigop-kind unit
        (u0.atom not unwrapped by slot_atom) carries its glyph on bg.base; an ordinary supsub-kind
        one (e.g. `\sum_{i=1}^{n}` with no `\limits`) is already unwrapped, so `d` IS the glyph. ]]
        if d == "\\int" or d == "\\oint" then
            return read_integral(ctx_parse, units, i, d, u0.sub, u0.sup)
        end
        --[[ A GLYPH OR A WORD, asked in that order only because atom_desc is the cheaper question.
        `operator_name` answers for a 1-tall vert of letters, which is how this app writes `lim` and
        `argmax` (its own comment for why they are a container rather than loose letters). ]]
        local spelling = d or operator_name(u0.atom)
        if spelling and BIGOP_BY_SPELLING[spelling] then
            return read_bigop(ctx_parse, units, i, spelling, u0.sub, u0.sup)
        end
    end

    -- ---- CASE 3b: a fraction bar, which is a division whether or not \div was ever typed -----
    if fr then
        --[[ THE ONE BIT DECIDES WHICH READER: a fraction marked as a differential (its bar drew
        green, mexpru.mark_diff) is the fourth binder, not a division. ]]
        if fr.diff then
            return read_derivative(ctx_parse, units, i, u0, fr)
        end
        local num, nerr = build_expr(ctx_parse, row_units(fr.num))
        if not num then
            return nil, nil, nerr
        end
        local den, derr = build_expr(ctx_parse, row_units(fr.den))
        if not den then
            return nil, nil, derr
        end
        local node, err = apply_power(ctx_parse, ast.new_div(ctx_parse.ns, num, den), u0)
        if not node then
            return nil, nil, err
        end
        return node, i + 1
    end

    -- ---- CASE 3: a bracket group, which is a cell around whatever it holds ------------------
    if b then
        if not b.is_open then
            return nil, nil, "closing bracket with nothing open"
        end
        local inner, j = collect_bracketed(units, i)
        if not inner then
            return nil, nil, "unclosed bracket"
        end
        --[[ THE WHOLE CASCADE INSIDE A BRACKET, not just an expression. `(a=b)\\Rightarrow c` read
        as "not parsed yet" because this asked build_expr, which starts below the relations - so a
        parenthesis could hold arithmetic and nothing else. Brackets exist to let any complete thing
        stand where one factor goes, and a relation is a complete thing. Ruled 2026-09-11: "why
        can't you add it some precedence? that seems ok to do".

        build_connective is the top of the cascade, so the contents of a bracket are parsed exactly
        as a whole row would be. ]]
        local body, err = build_connective(ctx_parse, inner)
        if not body then
            return nil, nil, err
        end
        --[[ WHETHER THE BRACKETS SURVIVE IS NOT DECIDED HERE, because it depends on what this
        factor ends up sitting next to - see maybe_cell. What IS decided here: a power consumes
        them. `(a+b)^2` needs its brackets to mean what it says, so they are required by
        precedence and never become a CELL. ]]
        local node
        node, err = apply_power(ctx_parse, body, units[j - 1])
        if not node then
            return nil, nil, err
        end
        return node, j, nil, (node == body)
    end

    --[[ INFINITY, WHICH IS A NUMERAL WITH NO DIGITS - `(N, 1, 0, 1)`, one over zero. A number
    rather than a node type of its own, so every place that handles a NUM handles it, including
    build_product's negation. Beside the digit run rather than inside it: one atom, no digits, the
    branch's RESULT and none of its scanning.
    @date 2026-09-11 09:00 ]]
    if d == "\\infty" then
        local node, err = apply_power(ctx_parse, ast.new_num(ctx_parse.ns, 1, 0, 1), u0)
        if not node then
            return nil, nil, err
        end
        return node, i + 1
    end

    -- ---- a numeral ------------------------------------------------------------------------
    if is_digit(d) then
        local digits, j = {}, i
        while j <= #units do
            local dd = atom_desc(units[j].atom)
            if not (is_digit(dd) or dd == ".") then
                break
            end
            digits[#digits + 1] = dd
            j = j + 1
            --[[ A DECORATED DIGIT ENDS THE RUN: `2^{n}3` is `(2^n) \cdot 3`, not the numeral
            23 with a power on it. The decoration belongs to the digit it was typed on, and a
            numeral cannot be interrupted halfway and resumed. ]]
            if units[j - 1].sup or units[j - 1].sub then
                break
            end
        end
        local text = table.concat(digits)
        local v = mexpr_ast.parse_number(text)
        if not v then
            return nil, nil, "`" .. text .. "` is not a number"
        end
        local num = tag_ast(u0, ast.new_num(ctx_parse.ns, v.m, v.n, v.sign))
        --[[ EVERY DIGIT OF THE RUN names it, not only the first: `123` is one number and clicking
        any of its three glyphs is the same gesture. ]]
        for k = i, j - 1 do
            tag_ast(units[k], num)
        end
        local node, err = apply_power(ctx_parse, num, units[j - 1])
        if not node then
            return nil, nil, err
        end
        return node, j
    end

    -- ---- a free variable ------------------------------------------------------------------
    --[[ A LETTER NOTHING ANSWERS TO IS A FREE VARIABLE, wherever it is written. WHAT STANDS IN
    FOR THE MISSING BINDERS: until a scope stack exists, a bound variable and a mistyped one look
    identical here, and refusing both would refuse one that is legitimate. ]]
    if is_letter(d) then
        --[[ A LETTER IN FRONT OF A BRACKET IS MULTIPLICATION ONCE RESOLUTION HAS FAILED - safe
        because resolution has already happened above: `a(b+c)` is the CALL whenever anything is
        declared with that shape; only when nothing answers is it a product. ]]
        -- `ctx_parse.free_order`, when present, is a bigop's harvesting side-channel - the only
        -- reader of "was this mention free". A list, in order: these names become the operator's
        -- variables in arrival order. Ordinary parsing never sets it.
        if ctx_parse.free_order then
            ctx_parse.free_order[#ctx_parse.free_order + 1] = d
        end
        -- WITH ITS DECORATIONS, exactly as a declared name carries them - dropping the accent here
        -- would make `\vec{F}` and `F` the same VREF.
        local ref = tag_ast(u0, var_ref(ctx_parse, d .. dress_suffix(u0.node)))
        --[[ Recorded BEFORE the power wraps it: the reference is drawn by the letter, the power by
        the whole slot, and afterwards there is no way to tell those apart. ]]
        tag_draws(leaf_drawn_by(u0), ref)
        local node, err = apply_power(ctx_parse, ref, u0)
        if not node then
            return nil, nil, err
        end
        return node, i + 1
    end

    return nil, nil, "not parsed yet: " .. units_text(slice(units, i, #units))
end

--[[ The glyphs that say "multiply" out loud. Juxtaposition means the same thing, so these are
consumed and nothing else - `2 \cdot x` and `2x` build the identical tree.
@date 2026-09-10 04:30 ]]
local MUL_OPS = {["\\cdot"] = true, ["\\times"] = true}

--[[ Whether a bracket group's parentheses survive into the tree, as a CELL or as nothing. A CELL is
emitted exactly when the parentheses are NOT implied by precedence - required ones are absorbed into
the tree shape (`a(b+c)` is MUL(a, ADD(...)), nothing left to record), redundant ones are kept
because they carry the user's own grouping, which is what transforms drag around. Here "required"
means one thing: an ADD inside a product of several factors.

A LEAF GROUP PROMOTES ONLY WHEN IT LEADS ITS PRODUCT (ruled 2026-09-16, reversing the older
promote-always): `af(x)` with nothing declared is MUL(a, f, CELL(x)) while `afx` is
MUL(a, f, x) - two spellings, two trees, because the parens are the user's own grouping and
carrying them is what lets a transform write `af(x)` back instead of collapsing it to `afx`
(found live on exactly that distribute). The LEADING group still promotes - `(a)+b` is `a+b` -
there being nothing in front of it for the parens to group WITH.
@date 2026-09-16 10:30 ]]
local CELL_LEAF = {[ast.NUM] = true, [ast.VAR] = true, [ast.VREF] = true}

local function maybe_cell(ctx_parse, node, in_product, preceded)
    if in_product and node.type == ast.ADD then
        return node
    end
    if CELL_LEAF[node.type] and not preceded then
        return node
    end
    return ast.new_cell(ctx_parse.ns, node)
end

--[[ ONE TERM: the factors juxtaposed in `units`, multiplied together, with the term's sign as
its leading coefficient. The sign folds into a leading numeral (`-2x` is MUL(NUM(-2), x), `+2x`
leaves NUM(2) as itself) and otherwise becomes the first factor, NUM(1) or NUM(-1). The sign glyph
tags the number that carries it, whichever shape it took. A row of letters is a PRODUCT and never
one long name: a multi-character name is written quoted and an operator as a vert, so `bb` has no
single-name reading.
@date 2026-09-15 ]]
function build_product(ctx_parse, units, sign, sign_unit)
    CTX_PARSE_SHAPE.check(ctx_parse, "ctx_parse")
    check_units(units)
    local factors, bracketed, i = {}, {}, 1
    while i <= #units do
        local d = atom_desc(units[i].atom)
        if MUL_OPS[d] then
            if #factors == 0 then
                return nil, "a multiplication sign with nothing in front of it"
            end
            i = i + 1
            if i > #units then
                return nil, "a multiplication sign with nothing after it"
            end
        end
        local node, next_i, err, from_brackets = read_factor(ctx_parse, units, i)
        if not node then
            return nil, err
        end
        factors[#factors + 1] = node
        --[[ `or false`, never nil: a nil here is a HOLE, and the sign prepend below does
        table.insert(bracketed, 1, false), which shifts by #bracketed - a length Lua may answer
        with any border short of the real end when the table has holes. The TRUE marking the
        group landed one slot left, on the letter before it, and (found 2026-09-16, live as a
        CELL around that letter) the misplaced flag wrapped the WRONG factor in a cell. A false
        is as falsy as a nil to every reader here, and the array stays a sequence. ]]
        bracketed[#factors] = from_brackets or false
        i = next_i
    end
    if #factors == 0 then
        return nil, "nothing here"
    end

    if sign then
        --[[ The sign is its own leading coefficient - a NUM(1) or NUM(-1) factor, never merged
        into another numeral (the author, 2026-09-15: magnitudes never multiply). `+2x` is
        MUL(NUM(1), NUM(2), x) and `-2x` is MUL(NUM(-1), NUM(2), x); written back, the unit
        coefficient becomes the sign glyph and the digits follow, which reparses to exactly these
        shapes. The sign glyph tags the coefficient, which is also what makes a sign clickable as
        a button and a digit not: the coefficient leads the product, a value numeral sits one
        factor in.

        SIGN-NUMBERS JOIN THE ACCUMULATION (the author, 2026-09-15): a leading numeral whose
        magnitude is exactly 1 - the unit, or infinity, which is +1 or -1 over 0 - carries
        nothing but a sign, so the term's sign folds onto it instead of growing a factor: `-inf`
        is NUM(1, 0, -1), and `-(-inf)` never exists. ]]
        local f = factors[1]
        if f.type == ast.NUM and f[1] == 1 and (f[2] == 1 or f[2] == 0) then
            factors[1] = ast.new_num(ctx_parse.ns, 1, f[2], sign * (f[3] or 1))
            tag_ast(sign_unit, factors[1])
        else
            table.insert(factors, 1,
                    tag_ast(sign_unit, ast.new_num(ctx_parse.ns, 1, 1, sign)))
            table.insert(bracketed, 1, false)
        end
    end

    -- Decided last, since "required" is a question about the product this factor ended up in.
    -- `preceded` = not this product's first factor, which is what keeps a juxtaposed leaf group
    -- a CELL (maybe_cell's own note).
    local in_product = #factors > 1
    for k = 1, #factors do
        if bracketed[k] then
            factors[k] = maybe_cell(ctx_parse, factors[k], in_product, k > 1)
        end
    end

    if #factors == 1 then
        return factors[1]
    end
    return ast.new_mul(ctx_parse.ns, table.unpack(factors))
end

--[[ CASE 2. Splits the row into terms on the top-level `+` and `-`, each term a product whose
sign is its leading coefficient (DESIGN.md, "Glyphs draw, transforms walk"): `a+b` is
ADD(a, MUL(NUM(1), b)) and `a-b` is ADD(a, MUL(NUM(-1), b)); a sign before a numeral folds into
it, so `-2x` is MUL(NUM(-2), x). The first term of a row is unsigned and carries no coefficient;
an explicit leading sign signs it.

A SIGN IS A SEPARATOR ONLY WITH A TERM BEHIND IT. Leading, it belongs to the term in front of it,
and a run of minuses folds, so `- -x` is `x` - which keeps `2-1` (two terms) and `-1` (one term)
from needing separate treatment. TOP LEVEL ONLY, by bracket depth, so the `+` in `f(a+b)` belongs
to the argument.
@date 2026-09-15 ]]
local function build_sum(ctx_parse, units)
    if is_untouched(units) then
        return nil, "empty"
    end

    --[[ The sign glyphs are kept so each can tag the number that carries it, in build_product -
    never the ADD: no glyph names structure, and the transform layer finds the sum by walking the
    ast. A no-op `+` (after a minus) does not steal the tag from the glyph that set the sign. ]]
    local terms, cur, sign, sign_unit, depth = {}, {}, nil, nil, 0
    for _, u in ipairs(units) do
        local b = bracket_of(u)
        local d = atom_desc(u.atom)
        if b then
            depth = depth + (b.is_open and 1 or -1)
            cur[#cur + 1] = u
        elseif depth == 0 and is_sign(d) then
            if #cur > 0 then
                terms[#terms + 1] = {units = cur, sign = sign, sign_unit = sign_unit}
                cur, sign, sign_unit = {}, nil, nil
            end
            if d == "-" then
                sign = (sign == -1) and 1 or -1
                sign_unit = u
            elseif sign == nil then
                sign = 1
                sign_unit = u
            end
        else
            cur[#cur + 1] = u
        end
    end
    terms[#terms + 1] = {units = cur, sign = sign, sign_unit = sign_unit}

    local nodes = {}
    for _, t in ipairs(terms) do
        if #t.units == 0 then
            return nil, "a sign with nothing after it"
        end
        local node, err = build_product(ctx_parse, t.units, t.sign, t.sign_unit)
        if not node then
            return nil, err
        end
        nodes[#nodes + 1] = node
    end
    if #nodes == 1 then
        return nodes[1]
    end
    return ast.new_add(ctx_parse.ns, table.unpack(nodes))
end

build_expr = build_sum

--[[ IMPLICATION AND EQUIVALENCE, which bind LOOSER than every relation - so they sit above the
RELATIONS table, not in it, and join two RELATIONS rather than two expressions:
`a=b \Rightarrow c=d` is IMPLIES(EQ(a,b), EQ(c,d)). RIGHT-ASSOCIATIVE by recursion on the rest of
the row, so a chain needs no special case - unlike `a=b=c`, which build_relation still refuses for
want of a shape.
@date 2026-09-11 16:45 ]]
local CONNECTIVES = {
    ["\\Rightarrow"]     = ast.new_implies,
    ["\\Leftrightarrow"] = ast.new_iff,
}

function build_connective(ctx_parse, units)
    CTX_PARSE_SHAPE.check(ctx_parse, "ctx_parse")
    check_units(units)
    for _, i in ipairs(top_level_indices(units)) do
        local make = CONNECTIVES[atom_desc(units[i].atom)]
        if make then
            local lhs = slice(units, 1, i - 1)
            local rhs = slice(units, i + 1, #units)
            if #lhs == 0 or #rhs == 0 then
                return nil, "an implication needs something on both sides"
            end
            local l, lerr = build_relation(ctx_parse, lhs)
            if not l then
                return nil, lerr
            end
            -- The REST of the row, not just the next relation - see right-associative above.
            local r, rerr = build_connective(ctx_parse, rhs)
            if not r then
                return nil, rerr
            end
            return tag_ast(units[i], make(ctx_parse.ns, l, r))
        end
    end
    return build_relation(ctx_parse, units)
end

--[[ CASE 4: splits on the ONE top-level relation - bracket depth tracked, so the `=` inside
`f(a=b)` is not a splitter - or parses the row whole when there is none. One only: `a = b = c`
needs a shape nobody has chosen yet, and is refused rather than silently associated. ]]
function build_relation(ctx_parse, units)
    CTX_PARSE_SHAPE.check(ctx_parse, "ctx_parse")
    check_units(units)
    -- `skip_past` steps over the second unit of an overprinted pair: a size-2 relation was
    -- consumed at its first unit, and the pair's other half is a depth-0 unit of its own.
    local at, skip_past = nil, 0
    for _, i in ipairs(top_level_indices(units)) do
        if i > skip_past then
            local rel, why = relation_at(units, i)
            if not rel and why then
                return nil, why
            end
            if rel then
                --[[ A DECORATED RELATION IS REFUSED. An accent hung on `=` means something its
                author knows and this parser does not, and slot_atom looks straight through a
                dress - so left alone it would read as a plain `=` and drop the decoration without
                a word. That is the same failure the `\ne` pseudo-glyph above exists to prevent,
                arriving by the other route. ]]
                if mexpru.u(units[i].node).kind == "dress" then
                    return nil, "decorated relation (" .. rel.desc .. ") is not handled yet"
                end
                if at then
                    return nil, "more than one relation - chains are not handled yet"
                end
                at = {i = i, rel = rel}
                skip_past = i + rel.size - 1
            end
        end
    end
    if not at then
        return build_expr(ctx_parse, units)
    end

    local lhs = slice(units, 1, at.i - 1)
    local rhs = slice(units, at.i + at.rel.size, #units)
    if #lhs == 0 or #rhs == 0 then
        return nil, "a relation needs something on both sides"
    end

    local l, lerr = build_relation(ctx_parse, lhs)
    if not l then
        return nil, lerr
    end
    local r, rerr = build_relation(ctx_parse, rhs)
    if not r then
        return nil, rerr
    end
    --[[ The relation's own glyph names the node it makes - clicking the `=` selects the equality,
    which is the gesture every relation-level transform will want. ]]
    return tag_ast(units[at.i], at.rel.op(ctx_parse.ns, l, r))
end

--[[ THE PARSER'S ACTUAL OUTPUT: a real ast.lua node for `container`, or nil plus the reason.

Returns the node and the namespace it was built in. Everything in the tree is a genuine constructor
call - ast.new_eq, ast.new_call, ast.new_num, ast.new_vref - so anything that walks an AST can walk
this one, and there is no second representation to keep in step. The F4 viewer renders THIS rather
than describing the row again, which is what stops the two disagreeing.

Fails rather than approximates. An argument nobody has written a parser for stops the build with a
reason, because a placeholder node would be indistinguishable from an understood one to every
reader downstream.
@date 2026-09-10 06:20 ]]
--[[ THE BUILT-IN FUNCTIONS AND HOW MANY ARGUMENTS EACH TAKES - words that APPLY to an argument,
unlike `lim`/`min`, which declare a variable and are big operators. ARITY IS PART OF THE NAME
(`sin(),(1)` and `sin(),(1),(2)` are two declarations), so it is decided here rather than inferred;
one argument for everything except `gcd`. That is a judgement call about notation, not a fact about
the code.
@date 2026-09-11 12:10 ]]
local BUILTIN_ARITY = {
    sin = 1, cos = 1, tan = 1, cot = 1, sec = 1, csc = 1,
    arcsin = 1, arccos = 1, arctan = 1,
    sinh = 1, cosh = 1, tanh = 1, coth = 1,
    log = 1, ln = 1, exp = 1,
    det = 1, gcd = 2,
}

--[[ DELIBERATELY SHORTER than the list of macros LaTeX knows: every name here is SPENT - immutable,
so no document may ever mean anything else by it - which is cheap for `sin` and expensive for a word
somebody might use as a variable. char.operator_words is a separate, longer list of which macros
LATEX names; those still read, write and draw, they just carry no meaning. The two lists answer
different questions and are meant to differ. ]]

local builtin_cache, builtin_texts = nil, nil

--[[ @brief The built-in FUNCTION names with their arities, for listing them to a person.
-- |
-- | SORTED, because `pairs` over string keys is randomised per process, and a help page whose order
-- | changed between runs would be its own small bug.
-- |
-- | @return {{name: string, arity: integer}, ...} - a fresh list, by name
-- |
-- | @date 2026-09-13 18:45
--]]
function mexpr_ast.builtin_functions()
    local out = {}
    for word, arity in pairs(BUILTIN_ARITY) do
        out[#out + 1] = {name = word, arity = arity}
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

--[[ @brief The big operators written as WORDS - the binders, `lim` through `argmax`.
-- |
-- | THE GLYPH OPERATORS ARE LEFT OUT: those are one keystroke, not a word typed letter by letter,
-- | and they are already covered where the symbols are.
-- |
-- | @return {string, ...} - a fresh list, sorted for the same reason as builtin_functions
-- |
-- | @date 2026-09-13 18:45
--]]
function mexpr_ast.named_operators()
    local out = {}
    for spelling in pairs(BIGOP_BY_SPELLING) do
        if spelling:match("^%a+$") then
            out[#out + 1] = spelling
        end
    end
    table.sort(out)
    return out
end

--[[ @brief The built-ins as REAL DECLARATIONS - the same shape a definition box hands out.
-- |
-- | SO RESOLUTION CANNOT TELL THEM APART from something the user wrote: a built-in is an injected
-- | definition, reaching resolution through the same declaration set as everything written by hand.
-- |
-- | BUILT BY PARSING, not by writing the tuples out. A declaration is a token walk (`sin(),(1)`),
-- | and hand-writing one here would be a second opinion about what a token is. Parsing `\sin (x)`
-- | through the ordinary name parser guarantees a built-in keys identically to a use of it.
-- |
-- | THE ARGUMENT NAMES ARE MEANINGLESS - `x`, `y` - by rule: a parameter's spelling was never
-- | identity, `f(x)` and `f(z)` are one name.
-- |
-- | @details SORTED BY TEXT, because `pairs` over string keys is randomised per process and a list
-- |          that changed order between runs is the shape of a bug this project has had once
-- |          (read_constraints, 2026-09-10). BUILT ONCE and cached for the process.
-- |
-- | @param fontset  fontset - used to build the rows parsed; only the first call's matters, since
-- |                 the result is cached
-- | @return {mexpr_ast.decl, ...} - each with `builtin = true`; the CACHED list, not a copy
-- |
-- | @date 2026-09-13 18:45
--]]
function mexpr_ast.builtin_declarations(fontset)
    if builtin_cache then
        return builtin_cache
    end
    local out = {}
    local ARGS = {"x", "y", "z"}
    for word, arity in pairs(BUILTIN_ARITY) do
        local names = {}
        for k = 1, arity do
            names[k] = ARGS[k]
        end
        local c = mformula_latex.from_latex(fontset, mexpru.DEFAULT_SIZE,
                "\\" .. word .. " (" .. table.concat(names, ",") .. ")")
        local pat = c and mexpr_ast.parse_name(fontset, c)
        if pat then
            out[#out + 1] = mexpr_ast.new_decl{text = pat.text, name = pat.name,
                    arity = pat.arity, tokens = pat.tokens, groups = pat.groups, builtin = true}
        end
    end
    table.sort(out, function(a, b) return a.text < b.text end)
    builtin_texts = {}
    for _, d in ipairs(out) do
        builtin_texts[d.text] = true
    end
    builtin_cache = out
    return out
end

--[[ The built-ins FIRST, then whatever the document declares that does not collide with one. THE
CONSECRATED NAMES ARE IMMUTABLE: a document declaration whose key matches a built-in is DROPPED, not
honoured - these are notation, not defaults, and a document that could quietly redefine `sin` makes
every formula unsafe to read at a glance. Dropped by TEXT (the identity declarations compare by
everywhere), and built-ins go FIRST because list order is the tie-break in resolve_use.
@date 2026-09-11 16:00 ]]
local function with_builtins(fontset, decls)
    local out, taken = {}, {}
    for _, d in ipairs(mexpr_ast.builtin_declarations(fontset)) do
        out[#out + 1] = d
        taken[d.text] = true
    end
    for _, d in ipairs(decls) do
        if not (d.text and taken[d.text]) then
            out[#out + 1] = d
        end
    end
    return out
end

--[[ @brief Is `text` a consecrated KEY - `sin(),(1)` - that nothing in a document may claim?
-- |
-- | BY KEY, so `sin_{n}` is not one. is_builtin_word asks about the word instead, which is the
-- | stricter question and the one check_declarations uses.
-- |
-- | @param fontset  fontset - passed to builtin_declarations
-- | @param text     string - a declaration's pattern text
-- | @return boolean
-- |
-- | @date 2026-09-13 18:45
--]]
function mexpr_ast.is_builtin_name(fontset, text)
    if not builtin_texts then
        mexpr_ast.builtin_declarations(fontset)
    end
    return builtin_texts[text] == true
end

--[[ @brief THE PARSER'S ACTUAL OUTPUT: a row as a real ast.lua tree.
-- |
-- | THE TOP OF THE CASCADE - build_connective, since the connectives sit above the relations - and
-- | the place the mexpr-to-ast tags are written as it goes, so a click on a glyph can later name
-- | the node it produced.
-- |
-- | THE BUILT-INS ARE ADDED HERE rather than by the caller, so being in scope is a property of the
-- | language and not something a call site can forget. A document declaration colliding with one
-- | is dropped.
-- |
-- | @param fontset    fontset - needed for the built-in declarations
-- | @param container  mexpru.container - checked
-- | @param decls      {mexpr_ast.decl} | nil - what the DOCUMENT declares above this row; checked
-- |                   when given
-- | @param ns         ast.ns | nil - checked when given; a fresh namespace is made when missing
-- | @return node | nil, string | nil, ast.ns - ALWAYS THREE VALUES in the same order: `node, nil,
-- |         ns` or `nil, err, ns`
-- |
-- | @note `node, ns` on success would put the namespace in a different slot depending on the
-- |       outcome, and a caller destructuring all three would bind `ns` to nil on the happy path -
-- |       which is exactly what happened here first.
-- |
-- | @date 2026-09-13 18:45
--]]
function mexpr_ast.build(fontset, container, decls, ns)
    mexpru.check_container(container)
    --[[ `decls` is OPTIONAL - with_builtins turns nil into just the built-ins, which is what a
    document with no definitions above this row really has. `ns` is optional too and a fresh one
    is made below. Each checked only when given. ]]
    if decls ~= nil then
        check_decls(decls, "decls")
    end
    if ns ~= nil then
        ast.check_ns(ns)
    end
    ns = ns or ast.new_ns()
    --[[ THE DECLARED-NAME ORANGE IS A PARSE FACT, so the parse owns it end to end: this puts every
    symbol back to the default before the cascade runs, and build_named paints the roots that
    resolve. Painting is therefore pure - same tree, same declarations, same colours - and a name
    that stops resolving (a definition deleted above) loses its orange at the next parse rather
    than keeping it forever. Asked for exactly here, 2026-09-16: "make that change during/after
    validation, don't continuously verify". Rules are untouched; a differential's bar is not ours. ]]
    paint_symbols(container.root, GLYPH_DEFAULT_COLOR)
    local ctx_parse = new_parse_ctx(ns, with_builtins(fontset, decls or {}))
    --[[ ALWAYS three values, in the same order, success or not: `node, err, ns`. Returning
    `node, ns` on success and `nil, err, ns` on failure would put the namespace in a different
    slot depending on the outcome, and a caller that destructured all three would silently bind
    `ns` to nil on the happy path - which is exactly what happened here first. ]]
    --[[ build_connective, not build_relation: the connectives sit ABOVE the relations, so this is
    the real top of the cascade now. ]]
    local node, err = build_connective(ctx_parse, row_units(container.root))
    if not node then
        container._bound_links = nil
        return nil, err, ns
    end
    --[[ THE LINKS A BINDER DECLARES are collected here, for the drawing that arcs them together:
    for each variable, the glyph its declaration tags (a VAR node's tag - only a binder's own
    spelling carries one) and every glyph a reference to it tags. A name nothing declares - a
    global, a plain free letter - has no declaration glyph, so it forms no link and the walk needs
    no binder list of its own (the author, 2026-09-16: "link the variables by an arc behind the
    formula drawing"). Stored on the container beside the parse cache, refreshed by every parse
and dropped by a failed one, so it can never outlive the tree it names. ]]
    local links = {}
    local decls_of, refs_of = {}, {}
    local function collect(node_g)
        if not node_g then
            return
        end
        local declares = mexpru.u(node_g).ast_declares
        local id = mexpru.u(node_g).ast_draws
        if declares then
            decls_of[declares] = node_g
        end
        if id then
            local tagged = ast.node_of(ns, id)
            if tagged and tagged.type == ast.VAR then
                decls_of[id] = node_g
            elseif tagged and tagged.type == ast.VREF then
                refs_of[tagged[1]] = refs_of[tagged[1]] or {}
                refs_of[tagged[1]][#refs_of[tagged[1]] + 1] = node_g
            end
        end
        for _, child in ipairs(mexpru.child_links(node_g)) do
            collect(child)
        end
    end
    --[[ Walked in two passes' worth of tables rather than one, because a reference can sit BEFORE
    its declaration in the row - `\int x dx` writes the body's x first - and a one-pass entry
    would drop it. The merge keeps only variables a declaration glyph names. ]]
    collect(container.root)
    for id, decl in pairs(decls_of) do
        links[id] = {decl = decl, refs = refs_of[id] or {}}
    end
    container._bound_links = links
    return node, nil, ns
end

--[[ ONE ARGUMENT GROUP, described rather than parsed. Returns the label the viewer shows.

The three cases are exactly what the parser understands today, and the third is the honest one: a
group that is neither a number nor a single variable is real content nobody has written a parser
for yet, so it is shown AS TYPED rather than as a shape that would imply it had been understood.
@date 2026-09-10 04:50 ]]
local function describe_arg(units)
    local joined = units_text(units)

    if #units == 1 and is_letter(joined) then
        return "REF " .. joined
    end
    if mexpr_ast.parse_number(joined) then
        return "NUM " .. joined
    end
    return "<expr> " .. joined
end

--[[ How each node type prints in the viewer - OVERRIDES ONLY. A type with no entry falls back to
its own name (ast.type_name), so a node added to ast.lua is labelled the moment it exists; only the
names that should differ are listed. Before the fallback, every new type printed as "type 21" and
got reported as a puzzle, once per node added.
@date 2026-09-10 06:40 ]]
local NODE_LABEL = {
    [ast.INEQ_LESS]    = "LESS",
    [ast.INEQ_LEQ]     = "LEQ",
    [ast.INEQ_NEQ]     = "NEQ",
    [ast.INEQ_GREATER] = "GREATER",
    [ast.INEQ_GEQ]     = "GEQ",
    [ast.EXP]          = "POW",
    [ast.NULL]         = "(null)",
    --[[ INT renders through its own branch below, whose FIRST call is `line(NODE_LABEL[t])` - it
    was written assuming this entry and nobody ever added it, so F4 on any integral died with
    "attempt to index a nil value" (found live 2026-09-16, on an integral around a sum). ]]
    [ast.INT]          = "INT",
}

--[[ SUM/PROD/UNION/INTERSECT's own shape - (op, n_vars, n_sup, n_sub, var1..varN, sup1..supM,
sub1..subK, body), ast.lua's own "Bigop scoping" comment. The first three slots are plain counts,
not nodes - `render` cannot walk them generically the way it walks everything else, same reason
CALL already gets its own branch below for its callee string.
@date 2026-09-11 09:40 ]]
local GROUP_BIGOP_LABEL = {}
for _, node_type in pairs(BIGOP_BY_SPELLING) do
    --[[ The label IS the type's own name - there is no second vocabulary to keep in step, and an
    operator added to the spelling table above is labelled without touching this. ]]
    GROUP_BIGOP_LABEL[node_type] = ast.type_name(node_type)
end

--[[ One node, and its children under it - walking the REAL tree (`mexpr_ast.build`'s output), never
the row it came from, so the viewer cannot show a shape the parser did not build. THE SAME COLOUR
ROLES F5 USES, so an operator reads red in both panels and a variable blue-and-green in both.
`line` takes a plain string or a list of {text, role} pieces; `prefix` names the SLOT a node was
reached through ("sup: " before an integral's upper bound - the one node with two adjacent slots a
reader cannot tell apart).
@date 2026-09-11 07:00 ]]
local function render(ns, node, depth, out, prefix)
    local function line(text_or_parts, role)
        local parts
        if type(text_or_parts) == "string" then
            parts = {{text = text_or_parts, role = role}}
        else
            parts = text_or_parts
        end
        if prefix then
            table.insert(parts, 1, {text = prefix})
        end
        local text = {}
        for _, piece in ipairs(parts) do
            text[#text + 1] = piece.text
        end
        out[#out + 1] = {depth = depth, text = table.concat(text), parts = parts}
    end
    local t = node.type

    --[[ Not painted as an operator, because it is not one - it is the absence of an operand, and
    colouring it red would put it in the same class as the ADD above it. ]]
    if t == ast.NULL then
        line(NODE_LABEL[t])
        return
    end
    --[[ (I, var, from, to, body) - ast.INT's fixed shape, so the two bounds are at known slots and
    can be named. The generic walk below would print them in the right order and say nothing about
    which was which. ]]
    if t == ast.INT then
        line(NODE_LABEL[t], "op_sym")
        render(ns, node[1], depth + 1, out)
        render(ns, node[2], depth + 1, out, "sup: ")
        render(ns, node[3], depth + 1, out, "sub: ")
        render(ns, node[4], depth + 1, out)
        return
    end

    --[[ A DIFF NEEDS ITS OWN BRANCH, or the generic walk crashes on it: its first three slots are
    SCALARS (partial, order, count) and the variable names are STRINGS, none of which is a node to
    recurse into - found live 2026-09-15, F4 dying with "attempt to index a number value". The
    label carries the whole sign row, the way a group bigop's label carries its counts, and only
    the body is a child. ]]
    if t == ast.DIFF then
        local partial, order, n_vars = node[1] == 1, node[2], node[3]
        local names = {}
        for k = 1, n_vars do
            names[#names + 1] = tostring(node[3 + k])
        end
        local sign = partial and "\\partial" or "d"
        line({{text = "DIFF", role = "op_sym"},
              {text = " " .. sign .. (order > 1 and ("^" .. order) or "") .. " / " .. sign
                      .. " " .. table.concat(names, " ")}})
        render(ns, node[4 + n_vars], depth + 1, out)
        return
    end

    if t == ast.NUM then
        line({{text = "NUM", role = "op_sym"}, {text = " "},
              {text = ast.num_text(node), role = "num_value"}})
        return
    end
    if t == ast.VAR then
        line({{text = "VAR", role = "bind_sym"}, {text = " "},
              {text = tostring(node[1]), role = "var_name"}})
        return
    end
    if t == ast.VREF then
        --[[ Shown by the NAME it points at, not the id: an id is meaningless to a reader, and the
        var is in the namespace precisely so this lookup is possible. ]]
        local target = ast.node_of(ns, node[1])
        line({{text = "REF", role = "bind_sym"}, {text = " "},
              {text = string.format("%q", target and target[1] or ("#" .. tostring(node[1]))),
               role = "ref_name"}})
        return
    end
    if t == ast.CALL then
        line({{text = "CALL", role = "op_sym"}, {text = " "},
              {text = string.format("%q", tostring(node[1]))}})
        for i = 2, #node do
            render(ns, node[i], depth + 1, out)
        end
        return
    end
    if GROUP_BIGOP_LABEL[t] then
        local n_vars, n_sup, n_sub = node[1], node[2], node[3]
        line({{text = GROUP_BIGOP_LABEL[t], role = "op_sym"},
              {text = " " .. n_vars .. " var/" .. n_sup .. " sup/" .. n_sub .. " sub"}})
        local idx = 3
        for _ = 1, n_vars + n_sup + n_sub + 1 do -- +1 is the body, always last
            idx = idx + 1
            render(ns, node[idx], depth + 1, out)
        end
        return
    end
    line(NODE_LABEL[t] or ast.type_name(t) or ("type " .. tostring(t)), "op_sym")
    for i = 1, #node do
        render(ns, node[i], depth + 1, out)
    end
end


-- ################################################################################################
-- The definition trie
-- ################################################################################################

--[[ The definitions of one document, indexed by their token walk. WHAT IT IS FOR IS THE CHECKING,
not the lookup - resolution walks the declaration list directly, but "is this new definition a
prefix of one already here, or one of them of it" is a trie's own shape rather than a search.
@date 2026-09-10 10:10 ]]
local function trie_node()
    return {children = {}}
end

--[[ Is anything below this node a definition? The answer to "does the new one swallow an existing
one", which is the direction an ancestor check cannot see. ]]
local function has_marked_descendant(node)
    for _, child in pairs(node.children) do
        if child.decl or has_marked_descendant(child) then
            return true
        end
    end
    return false
end

--[[ Adds one definition, or says why it cannot be added. NO OVERLAPPING DEFINITIONS, in either
direction - the rule is about MEANING, not about whether a parser could tell them apart - which also
forbids arity overloading, since `f(),(1)` is a prefix of `f(),(1),(2)`.
@date 2026-09-10 10:10 ]]
local function trie_conflict(root, decl)
    local node = root
    for _, tok in ipairs(decl.tokens or {}) do
        if node.decl then
            return "`" .. decl.text .. "` extends `" .. node.decl.text
                    .. "`, which is already a name"
        end
        node = node.children[tok]
        if not node then
            return nil
        end
    end
    if node.decl then
        return "`" .. decl.text .. "` is already defined"
    end
    if has_marked_descendant(node) then
        return "`" .. decl.text .. "` is the start of a name already defined"
    end
    return nil
end

-- Commits a definition the checks have already cleared.
local function trie_add(root, decl)
    local node = root
    for _, tok in ipairs(decl.tokens or {}) do
        local nxt = node.children[tok]
        if not nxt then
            nxt = trie_node()
            node.children[tok] = nxt
        end
        node = nxt
    end
    node.decl = decl
end

--[[ Does this definition contain another one? If `b_n` is a definition, `a_{1,b_m,2}` may not be
one, because `b_m` inside it would read both as part of `a`'s name and as an application of `b`.
Refusing it here is what lets the USE site decide locally - never both readings. DECORATED GROUPS
ONLY: a bare letter is a parameter by rule, and the ambiguity needs a group readable as an
application, which takes a subscript.
@date 2026-09-10 10:10 ]]
local function contains_definition(decl, decls)
    for _, group in ipairs(decl.groups or {}) do
        local u = has_sub(group) and mexpr_ast.parse_use_units(group, decls)
        if u then
            local hit = mexpr_ast.resolve_use(u, decls)
            if hit then
                return "`" .. decl.text .. "` contains `" .. hit.decl.text
                        .. "`, which is already a name"
            end
        end
    end
    return nil
end

--[[ @brief Is this the name of a built-in - a WORD no document may claim?
-- |
-- | BY NAME, NOT BY KEY, so `sin_{n}` and `sin(x,y)` are refused alongside `sin(x)`. The WORD means
-- | sine; a document that could attach a second meaning to it under a different arity would be just
-- | as confusing as one that redefined it outright.
-- |
-- | @details Needs no fontset, unlike builtin_declarations, because it asks about the word rather
-- |          than the token walk - which is what lets check_declarations call it at all. Built-in
-- |          FUNCTIONS only; the named big operators are not in the list.
-- |
-- | @param name  string | nil - a declaration's bare name; nil is not one
-- | @return boolean
-- |
-- | @date 2026-09-13 18:45
--]]
function mexpr_ast.is_builtin_word(name)
    return name ~= nil and BUILTIN_ARITY[name] ~= nil
end

--[[ @brief Which of these declarations may coexist, and why the rest may not.
-- |
-- | CHECKED AS A SET, not one at a time, because the question is whether two collide - a name that
-- | is fine alone is refused beside one it is ambiguous with.
-- |
-- | ORDER IS THE DOCUMENT'S, and it decides which of two conflicting definitions survives: the
-- | earlier one - the same rule as content.declarations_before, applied to the definitions
-- | themselves. A refused definition is left out of the trie and the accepted list, so what comes
-- | back satisfies the invariants rather than being the set that was written.
-- |
-- | @details In order, a definition is refused for: a consecrated word; a trie conflict; containing
-- |          an accepted name; or making an already accepted one ambiguous.
-- |
-- | @param decls  {mexpr_ast.decl} - checked element by element
-- | @return {root, accepted, refused} - the trie, the accepted decls, and {decl, why} per refusal
-- |
-- | @note Only looks BACKWARDS. Inserting a box above existing ones can still break those below;
-- |       they are re-checked next frame and the later one is refused, without telling the user
-- |       which box became invalid - docs/phase2_design.md 18d.
-- |
-- | @date 2026-09-13 18:45
--]]
function mexpr_ast.check_declarations(decls)
    check_decls(decls, "decls")
    local root, accepted, refused = trie_node(), {}, {}
    for _, d in ipairs(decls or {}) do
        -- A CONSECRATED NAME is refused first, before any trie question: the word is not
        -- available. Refusing here rather than silently dropping it later is what lets the
        -- editor say WHY.
        local why = mexpr_ast.is_builtin_word(d.name)
                and ("`" .. tostring(d.name) .. "` is a built-in name and cannot be redefined")
        why = why or trie_conflict(root, d) or contains_definition(d, accepted)

        -- AND THE OTHER DIRECTION: would accepting this break one already accepted? `a_{n_{m}}` is
        -- legal while `n_{m}` does not exist, so defining `n_{m}` afterwards is what must fail.
        -- Only ever looks BACKWARDS - inserting a box above existing ones can still break the
        -- ones below, which are re-checked next frame.
        if not why then
            local would_be = {}
            for i, prev in ipairs(accepted) do
                would_be[i] = prev
            end
            would_be[#would_be + 1] = d
            for _, prev in ipairs(accepted) do
                local broke = contains_definition(prev, would_be)
                if broke then
                    why = "`" .. d.text .. "` would make `" .. prev.text .. "` ambiguous - "
                            .. broke
                    break
                end
            end
        end

        if why then
            refused[#refused + 1] = {decl = d, why = why}
        else
            trie_add(root, d)
            accepted[#accepted + 1] = d
        end
    end
    return {root = root, accepted = accepted, refused = refused}
end

--[[ @brief The parse of `container`, as indented lines for the F4 viewer.
-- |
-- |     EQ
-- |       CALL "F(),(1)"
-- |         NUM 0
-- |       REF "y"
-- |
-- | RENDERS THE REAL TREE. It calls build and walks the node that comes back, rather than
-- | describing the row a second time - so the viewer cannot show a shape the parser did not build.
-- |
-- | FAILURE IS SHOWN AS FAILURE. Whatever stops the build - a chained relation, something with no
-- | parser yet - becomes the one line shown. Nothing is approximated.
-- |
-- | @param fontset    fontset - forwarded to build
-- | @param container  mexpru.container - forwarded to build, which checks it
-- | @param decls      {mexpr_ast.decl} | nil - the LIST content.declarations_before gives
-- | @return {{depth: integer, text: string}, ...} - one "no tree: <reason>" line on failure
-- |
-- | @date 2026-09-13 18:45
--]]
function mexpr_ast.describe(fontset, container, decls)
    local out = {}
    local node, err, ns = mexpr_ast.build(fontset, container, decls)
    if not node then
        out[1] = {depth = 0, text = "no tree: " .. tostring(err)}
        return out
    end
    render(ns, node, 0, out)
    return out
end

--[[ @brief Parses a PARAMETER cell, which must be a membership and nothing else.
-- |
-- |         <name> \in <set>          n \in \N ,  v_{max} \in \R ^{2}
-- |
-- | A DOMAIN RESTRICTION: it names the variable and the set it is drawn from. Requested 2026-09-07:
-- | "the param boxes should reject anything else than apartenance of named to set". An expression
-- | that is not a membership restricts nothing, and is refused rather than half-understood.
-- |
-- | THE SET SIDE IS NOT CHECKED. It is handed back as the raw nodes after the membership sign and
-- | marked "ok" - read, not yet understood - because validating it means parsing a general
-- | expression (`\R ^{2}` is a power), and this reader was written before that parser existed.
-- |
-- | @details With no membership sign at all, everything typed is marked "work" rather than "bad":
-- |          a cell on its way to `n \in \N` spends every keystroke before the sign in that state.
-- |
-- | @param fontset    fontset - NOT USED, like parse_name's
-- | @param container  mexpru.container - checked
-- | @return {var, set, marks} | nil, string, node, marks - `var` is the name pattern, `set` the
-- |         mexpr nodes after the sign; or nil, the reason, the node to blame, and the marks
-- |
-- | @note A second form, `a = <constant>`, was floated and WITHDRAWN the same day - verbatim: "yeah
-- |       we get rid if that". Do not re-add it without asking.
-- |
-- | @date 2026-09-13 18:45
--]]
function mexpr_ast.parse_domain(fontset, container)
    mexpru.check_container(container)
    local p = new_parser()
    local units = row_units(container.root)

    if is_untouched(units) then
        return nil, "empty", nil, p.marks
    end

    -- The membership sign, at the top level of this row.
    local in_i
    for i, u in ipairs(units) do
        if atom_desc(u.atom) == IN_DESC then
            in_i = i
            break
        end
    end
    if not in_i then
        --[[ No membership at all. Everything typed is "in work" rather than wrong: a cell on its
        way to `n \in \N` spends every keystroke before the sign in this state, and painting it red
        would have the box shouting through most of normal typing. ]]
        p:mark_rest(units, 1)
        return nil, "a parameter must be a membership: <name> " .. IN_DESC .. " <set>",
                units[1].node, p.marks
    end

    local left, right = slice(units, 1, in_i - 1), slice(units, in_i + 1, #units)

    if #left == 0 then
        p:mark(units[in_i].node, "bad")
        return nil, "nothing before the membership sign", units[in_i].node, p.marks
    end

    local pat, err, node = read_pattern(p, left)
    if not pat then
        return nil, err, node, p.marks
    end

    p:mark(units[in_i].node, "ok")

    if #right == 0 or is_untouched(right) then
        -- The set has not been typed yet: unfinished, not wrong.
        return nil, "nothing after the membership sign", units[in_i].node, p.marks
    end

    local set_nodes = {}
    for _, u in ipairs(right) do
        set_nodes[#set_nodes + 1] = u.node
        p:mark(u.node, "ok")
    end

    return {var = pat, set = set_nodes, marks = p.marks}
end

return mexpr_ast

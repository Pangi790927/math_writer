--[[ ==================================== WHAT THIS FILE OFFERS ====================================
THE PARSE
build(fontset: fontset, container: mformula.container, decls: {decl}, ns: ast.ns)
      -> node | nil, reason, ns
    A ROW AS MEANING - the parser's actual output. Also tags each
    mexpr node with the ast node it names (`u.ast_id`), which is how a
    click later resolves to a node.
describe(fontset: fontset, container: mformula.container, decls: {decl}) -> {line, ...}
    The same parse as indented lines, for the F4 viewer.

NAMES
parse_name(fontset: fontset, container: mformula.container) -> pattern | nil, reason
parse_use(fontset: fontset, container: mformula.container, decls: {decl}) -> use | nil, reason
parse_use_units(units, decls: {decl}, opts: table) -> use | nil, reason
    A declaration versus a use. Superscripts are refused in the first
    and allowed in the second: `f^2` is not a name, but `f^2(x)` is a
    use of one.
match_use(use, decl_tokens)             -> args | nil
resolve_use(use, decls: {decl})         -> {candidate, ...}, verdict
check_declarations(decls: {decl})       -> accepted, refused
    Checked AS A SET: the question is whether two collide, so a name
    that is fine alone can still be refused beside another.

BUILT-INS
builtin_functions() / named_operators() -> {name = arity} sorted
new_decl(fields: table)                 -> decl
DECL_SHAPE                              the declaration's shape
    One declaration as the document hands it over. Declared here rather
    than in editor_definition, which builds it: this is the layer that
    decides what a declaration IS, and the dependency runs this way.

builtin_declarations(fontset: fontset)  -> {decl, ...}
is_builtin_name(fontset: fontset, text: string) -> reason | nil
is_builtin_word(name: string)           -> boolean
    The consecrated names, as REAL DECLARATIONS in the same shape a
    definition box hands out, so resolution has one path and not two.

PIECES
MARK_STATUSES                           {status -> meaning}
    The three a parse mark may carry: ok, work, bad. Declared here and
    checked by the drawing side at load, so the two cannot drift.

parse_number(text: string)              -> node | nil, reason
parse_domain(fontset: fontset, container: mformula.container) -> name, set | nil, reason
    A parameter cell, which must be a membership and nothing else.

--- internal, not on the module table --------------------------------------------------------------
    new_parse_ctx() THE ONE creator for the `ctx_parse` the cascade carries down
    unit()         the ONE creator for the parser's per-slot container - a DIFFERENT
                   table from mexpru's `u`, despite both being called `u` in use
    the unit list, the parser cascade (build_sum -> build_product ->
    read_factor), the pattern trie and the ast tagging
@date 2026-09-12 03:45
================================================================================================= ]]

--[[
mexpr_ast.lua - the bridge from the EDITED tree (mexpr) to MEANING.

Named to sit beside mexpr.lua (ast -> mexpr) so the pair is visible; see docs/phase2_design.md
section 3. This is its first piece: parsing a NAME PATTERN, which is what a definition box's first
slot holds.

WHAT A NAME PATTERN IS. Not an expression - a *declaration* of one name, written in the notation it
will be applied with, from which the parameters are read off. `f(x)`, `a_n`, `F_{m,n}`, `v_'max'`.
Everything that is not the name itself or a literal is a FREE VARIABLE, and the count of those is
the arity `n` the definition needs (docs/phase2_design.md section 10, and editor_definition.lua's
own header on the n+2 slots).

THE RULES, from the 2026-09-07 spec, with the examples that fix each one:

  ACCEPTED                          REJECTED
  a_b        letter, subscript      2(whatever)   must not start with a number applied to anything
  a_'maxlim' quoted literal index   ab            two atoms at the same level is multiplication,
  'abc'      quoted name                          not a name
  a(x)       call notation          F_{mn}        same, one level down: juxtaposition inside an
  1_u        decorated number                     argument is multiplication
  F_{m,n}    two arguments          a^{'abcd'}x   nothing may follow the base
  a^'abcd'   quoted literal power   (a)           must not start with a bracket

A bare `1` or `a` with nothing else IS a name (the simplest one). What `2(whatever)` violates is
not "starts with a digit" - `1_u` starts with a digit and is fine - it is that a number cannot be
APPLIED. Quotes are what separate a multi-letter NAME from a product: `'abc'` is one name, `abc`
is three variables multiplied. That also answers what section 6 left open as question (b) - how a
multi-letter subscript is written - `v_'max'` is a literal, `v_{max}` is v applied to m*a*x.

LITERALS ARE NOT PARAMETERS. A quoted string and a number are constants, so `a_'maxlim'` has arity
ZERO - it is a plain named variable that happens to be drawn with a subscript. `a_n` has arity one.

THE OUTPUT is a flattened pattern: the base name, then each notation step and the arguments it
takes, with free variables numbered in traversal order.

    a_{n_{m}}   ->  a,sub,(1),sub,(2)
    f(x,y,z)    ->  f(),(1),(2),(3)

A NAME HAS NO SUPERSCRIPT. It takes a subscript, or arguments, or both - never a power. Ruled
2026-09-10, reversing the earlier reading, in the author's own words: "names don't have sups, only
subs or function arguments (themselves)".

That is a rule about what a name IS, not a restriction on notation: a superscript is an operation
performed ON a name, so it belongs to the expression around the name rather than to the name
itself. `a^2` is `a` squared - the name is `a`. Which is also what settles the `a^2(x)` case the
old ordering note had to hedge about, and the ambiguity docs/phase2_design.md's "superscript rule"
raises: within a NAME there is nothing left to be ambiguous about.

TRAVERSAL ORDER IS same-line, then sub - `f(x)_q` reads its call arguments first, then its index.
The same order has to be used by whatever compares two patterns later, or two spellings of one
declaration will not match.
@date 2026-09-08 08:55
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
them is how WIDE the accent is drawn (a narrow \\vec over the letter, a stretchy \\overrightarrow over
the letter and its index), and the width of an accent is a typesetting choice, not a different
accent. `atom` still comes from slot_atom, which looks through both wrappers to the letter, and
`node` stays the OUTERMOST node so dress_suffix still finds the decoration - the accent remains part
of the name's identity exactly as before.
@date 2026-09-11 16:30 ]]
--[[ THE MEXPR REMEMBERS WHICH AST NODE IT PRODUCED - `u(_).ast_id`.

WHY THIS DIRECTION. The AST is scratch: it is built from a row, transformed, turned back into mexpr
and dropped. The mexpr is the artifact that persists. Author, 2026-09-11: "the mexpr needs to
remember the ast", and "the ast will not survive either way... the resulting mexpr must be proper".
So the tag lives on the side that lasts, and a stale one is impossible - `build` writes it as it
goes, so the tag always names the ast currently in hand.

WRITTEN DURING THE PARSE, not by a pass afterwards. A second walk would have to re-derive the
correspondence from the row, which is a parallel traversal free to drift from the real one - the
failure mexpr_ast.describe's own comment already records. Here the construction site has the unit
and the node it just built, both in hand, and there is nothing to keep in step.

WHAT IT IS FOR: resolving a gesture. A click lands on a glyph; this says which ast node that glyph
belongs to, which is how a transformation gets its parameters.

MANY-TO-ONE, and deliberately so: both `+` glyphs of `a+b+c` name the one ADD. Some nodes have no
glyph at all - an implicit MUL in `2ab` is written with nothing - and those simply go untagged; a
gesture reaches them by walking UP from a child, never by clicking them.
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

--[[ WHICH MEXPR NODE DRAWS THIS AST NODE - its ink, exactly, and nothing more of it.

DIFFERENT FROM tag_ast ABOVE, which answers "what did the user click on". A `+` NAMES its sum, and
every digit of `123` names the one number, because a gesture must work wherever you point. Neither
of those DRAWS the node it names: the `+` draws a third of the sum. This is the other direction, and
it has exactly one consumer - ast_mexpr, rebuilding a tree into glyphs, which for anything with an
IDENTITY must copy what was written rather than re-render it from the name.

WHY RE-RENDERING IS NOT AN OPTION: a variable's name is an assembled STRING (`p.name` = base text +
dress suffix + primes + sub). That is an identity key, not a drawing. Building glyphs back from it is
the same mistake the definition row already made once - `pattern_latex` fed token text to from_latex
and drew the arrow beside the `F` instead of over it.

A PLAIN ID, no node reference, so nothing here has to be weak or invalidated: the writer walks the
mexpr once and builds id -> node fresh each time it needs one.
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
power wraps the leaf in a supsub, and that supsub draws the leaf AND its exponent. The base alone is
the leaf. A subscript cannot arrive here - apply_power refuses one on anything that is not a declared
name - so the two cases below are all there are.
@date 2026-09-12 02:00 ]]
local function leaf_drawn_by(u0)
    if u0.sup then
        return u0.base
    end
    return u0.node
end

--[[ THE `ctx_parse` CONTAINER - what the parser cascade carries down, and THE ONE CREATOR for it.

NAMED `ctx_parse`, NOT `ctx`, for the reason ast_mexpr's `ctx_write` is named that: three different
containers here were called `ctx`, and `ctx.ns` meant something different in each. The plugin one
(transforms.ctx) keeps the bare name because it is the one that crosses files.

Its fields:
    ns          the namespace every node built by this parse is minted into
    decls       what is in scope: the document's declarations, with the built-ins added
    vars        name -> VAR node, the variables this parse has created so far
    free_order  DELIBERATELY ABSENT HERE. It is a bigop's harvesting side-channel, and its being
                nil is the OFF state - read_constraints sets it to {} for the span it wants
                collected and restores it after. Creating it here would make "when present" always
                true and every free variable would be harvested by nobody. Caught while writing
                this creator; no test covers that path.

`vars` starts EMPTY and fills as the parse proceeds - it is the parse's accumulating state, not its
input, which is why it is not a parameter here.

NOT SEALED: built here, read only inside this file, dropped when the parse ends. The same note
`unit` carries a few hundred lines up.
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

--[[ THE `unit` CONTAINER - one row slot, as the parser sees it. THE ONE CREATOR for it.

A DIFFERENT CONTAINER FROM mexpru's `u` TABLE, and the collision of names is worth stating plainly
because both are called `u` at their call sites: `u.sz` is a node's logical size, `u0.sup` is this
container's superscript slot. They are unrelated tables. This one is built here, lives only for the
length of one parse, and is never attached to a node.

Its fields, which is what a reader comes here for:

    atom      what the slot actually carries, looked through any dress or supsub (slot_atom)
    node      the OUTERMOST node, never the undressed one - dress_suffix reads the decoration off
              it, and the decoration is part of a name's identity
    base      the supsub's base, carried for leaf_drawn_by alone
    sup, sub  the supsub's own rows, when the slot is one
    call      set by read_pattern on a base unit it owns - the one field anything downstream mutates
    quoted, quoted_nodes, quote_open, prime
              set while reading a declaration's pattern; see read_pattern

NOT SEALED, unlike `u` and `ctx_parse`. Those two span files and are written by several; this one is
built, read and dropped inside this file, so a typo on it is visible in the same screenful that
created it. If it ever leaves mexpr_ast, it should be sealed the same way.
@date 2026-09-12 05:00 ]]
--[[ The `unit` container's declared fields. Sealed like every other container here - author,
2026-09-12, on take_quoted: "u is of a type no? and it is not checked".

`quote_open` has no entry among the constructor's own fields because it is written LATER, while a
quoted name is being read. Declared-but-unset is the normal state for most of these: a plain letter
carries `atom` and `node` and nothing else.
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

--[[ The `decl` container - one declaration, as the document hands it to the parser.

DECLARED HERE THOUGH IT IS BUILT IN editor_definition, because this is the layer that decides what a
declaration IS for resolution, and because editor_definition requires this file rather than the
other way round - declaring it there and checking it here would be a cycle.

`arity` is not stored: it is `#vars` on the pattern this came from, and two places holding one
number is how they come to disagree. `box_index` is added by content.declarations_before, which is
the only thing that knows where a declaration sits in the document.
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

--[[ Builds one. THE ONE CREATOR, called by editor_definition.declaration.
@date 2026-09-12 20:00 ]]
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

--[[ A declaration LIST, every element checked.

What a caller passes as "what is in scope". The elements are walked - `d.tokens` position by
position - so a wrong one is dereferenced rather than merely carried, which is why the list is
checked through rather than at the top. nil is refused here; the callers that allow an absent list
test for it themselves, because for them nil means something ("just the built-ins") rather than
nothing.
@date 2026-09-12 20:40 ]]
local function check_decls(decls, what)
    assert(type(decls) == "table", (what or "decls") .. " must be a declaration list")
    for i, d in ipairs(decls) do
        mexpr_ast.DECL_SHAPE.check(d, (what or "decls") .. "[" .. i .. "]")
    end
    return decls
end

--[[ Every element of a unit list, checked. Lists are built by row_units and sliced by the parser,
so a wrong element means a slice went wrong upstream rather than a caller mistyping - and the
element that is not a unit is the one worth naming, not the list.
@date 2026-09-12 20:20 ]]
local function check_units(units, what)
    assert(type(units) == "table", (what or "units") .. " must be a unit list")
    for i, u in ipairs(units) do
        UNIT_SHAPE.check(u, (what or "units") .. "[" .. i .. "]")
    end
    return units
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

--[[ QUOTES BIND FIRST, and this is the pass that says so.

A quoted name is ONE object from the moment its opening quote is seen, so the atoms between the
quotes never reach the space filter below and never have to be put back. That ordering was the other
way round until 2026-09-10 - spaces were dropped globally and `read_quoted` restored them from a
per-unit count - which worked and was backwards. Author: "why isn't the whole string read as a
single object? so 'a  bc d' should be just read as that when the first ' is encountered, until the
last ' is encountered".

ROW-LOCAL, deliberately. A quoted name cannot span a subscript boundary - in `'a_{b'}` the two
quotes are in different rows - so the scan runs per row, which is where this function already is.

THE CLOSING QUOTE IS THE UNIT THAT SURVIVES, because it is the one that may carry the decorations:
typing Ctrl+_ after `'abc'` wraps the closing quote, so `'abc'_n` is [', a, b, c, supsub(base=',
sub=n)]. Taking that unit whole keeps its sub, its sup and its node identity, and the packed name
rides on it as `.quoted`. The opening quote's own decorations are dropped - `'^{2}abc'` is
degenerate and inventing a meaning for it would be worse than losing it.

A LONE QUOTE IS A PRIME. Author, 2026-09-10: "only when ' are alone they form prime second third".
Alone means: no closing quote, and nothing following that could be string content - so `f'` and `f''`
are prime and second, while `'ab` is a string still being typed and keeps the unterminated-name error
it has always had. That distinction is what preserves the red mark under a half-typed name.

Per-character painting survives the packing: `.quoted_nodes` carries the atoms so the parser can
still mark each one.
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
spaces that are left over dropped.

SPACES GO ONCE, HERE, so nothing downstream has to think about them. `f (x)` is the same name as
`f(x)`; a space is how a formula is made readable, not part of what it identifies. Filtered at the
single place units are built rather than skipped at each site that walks them, because a space broke
the name parse in four DIFFERENT ways depending on where it landed - before a call bracket it read as
trailing content, inside a subscript as juxtaposition, before an argument as "not a name", after a
comma the same. Four symptoms of one thing, and four places to forget.

Author, 2026-09-10: "the only thing we jump over are spaces, we ignore those basically, at least for
this step".

AND THE ORDER IS WHY THERE IS NOTHING TO PUT BACK. A space inside a quoted name is content, not
layout, and pack_quotes has already swallowed it by the time the filter runs. The previous version
dropped every space first and restored the quoted ones from a per-unit count; this one never removes
them, which is one mechanism instead of two.
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

DECORATIONS ARE PART OF A NAME, and until 2026-09-10 every one of them was silently dropped:
slot_atom looks THROUGH a dress, which is right for the cursor and wrong for identity, so `\hat{a}`,
`\vec{a}` and `a` all serialized as `a` and were the same name. A formula using `\hat{p}` resolved to a
declaration of `p`, which is exactly the silent wrong answer the whole exact-identity scheme exists
to prevent.

FOLDED INTO THE BASE TOKEN rather than emitted beside it, and that is forced rather than chosen: a
separate token would make `a` a PREFIX of `a,\hat`, and the no-overlap rule refuses a name that extends
one already defined - so `a` and `\hat{a}` could not both be declared. As part of the token they are
siblings in the trie instead. Author, 2026-09-10, on why they are never optional at a use site: "if
you are defined with a hat, you allways use the hat, no?".

INNERMOST FIRST, so a doubly dressed letter has one spelling. The walk descends through supsub bases
and dress targets exactly as slot_atom does, so it sees the same chain slot_atom skipped.
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

--[[ A written decimal, as the exact rational ast.new_num() wants: {m, n, sign} meaning
sign * m / n.

    "12"     -> 12/1        "3.14"  -> 314/100        "-0.5" -> -5/10

NOT REDUCED. 3.14 stays 314/100 rather than becoming 157/50, matching what
docs/phase2_design.md section 4.2 fixes as the representation. Reducing is a normalisation, and
normalisations belong to the equality machinery (section 9), not to reading a literal - the two
spellings must be able to differ until something decides they do not.

Returns nil for anything that is not a well-formed literal, so `1.2.3` and a bare `.` are refused
rather than silently becoming something.

WHAT THIS IS NOT. It reads LITERALS only, and a literal is not the same thing as a number.
Verbatim, 2026-09-07: "remember sqrt(2) is also a number". `sqrt(2)` reaches the bridge as
`(2)^{1/2}` (section 6c - the radical is rewritten on input and never exists as a node), which is
an EXPRESSION that happens to have a constant value. So "is this a number" is a question about
whether an expression has any free variables, answerable only once expressions can be parsed and
their linked variables computed (section 6b's triple). This function answers the much smaller
question "is this run of glyphs a written numeral", which is what a lexer can know. Do not extend
it to try to recognise constant expressions - that check belongs where variables are resolved.
@date 2026-09-08 08:55 ]]
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

--[[ Records a free variable and emits its numbered slot. Every occurrence gets its own number:
`F_{m,m}` is two parameters that happen to be spelled the same, which is a thing the user can write
and which the definition has no reason to collapse.
@date 2026-09-08 08:55 ]]
--[[ Registers one parameter position. `nodes` is the boxes standing at it, in row order.

The NODES are not identity and never become identity - `f(x)` and `f(z)` are one name, which is the
whole point of a parameter. They ride along only so the position can be DRAWN: the definition editor
shows the name with a dot at each parameter, and the only way to draw a position is to know which
boxes occupy it. Callers that have no boxes to offer pass nothing and lose nothing.
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
    if not self.decls or #self.decls == 0 then
        return false
    end
    local decorated = false
    for _, u in ipairs(units) do
        if u.sub then
            decorated = true
            break
        end
    end
    if not decorated then
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

    --[[ USE-SITE MODE. At a use site every argument position is a SLOT, whatever is written in it -
    a free variable, a literal, or a whole expression like `n+1`. The group is set aside for the
    expression parser and the position emits `(k)`.

    Which makes this the simple case rather than the hard one, and that is worth saying because the
    obvious design was much worse: parse the argument, notice partway through that it is not a name,
    and undo. Deciding BEFORE parsing needs no rollback, and the group's contents are not this
    parser's business anyway - split_commas has already found where the argument ends, which is the
    only question a name pattern has about it.

    Numbering rides on `vars` so a use site and a declaration count positions identically: `f(34)`
    keys as `f(),(1)` because `f(x)` did.
    @date 2026-09-10 03:45 ]]
    --[[ EXCEPT WHEN THE GROUP IS PART OF THE NAME. `a_{n_{m}}` names one thing: `n` is literal
    structure, not a parameter (docs/phase2_design.md 18d). A use of it writes `a_{n_{5}}`, and the
    use site has to read `n` the same way or the two cannot match.

    THE DECISION IS LOCAL, AND THE INVARIANT IS WHAT MAKES IT SO. Author, 2026-09-10: "on
    expression walking, n_{5} would mismatch as a definition which will make n a base literal of
    the sub n_{m} and help match the whole expression". Since a definition may not contain another
    definition, `a_{n_{m}}` can only exist while `n_{m}` does not - so a decorated group either
    resolves on its own, and is an independent argument, or it does not, and is part of the name.
    Never both. No candidate set, no backtracking: one test per group.

    A BARE LEAF IS ALWAYS AN ARGUMENT, decorated is the only case that asks the question. Without
    that guard `a_{5}` would read `5` as literal structure and stop matching `a,sub,(1),end`, since
    a numeral resolves to nothing either.
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

    --[[ THIS IS THE EXPRESSION BOUNDARY, and the other one is the `else` above. An argument that
    is not a single name, literal or number is an expression - `a_{n+1}`, `a_{2n}`, `a_{f(n)}` all
    land here, `a_{-n}` lands on the else. Under an expression-enabled pass they stop being errors
    and become subtrees for the expression parser.

    NOT WIRED UP YET, and deliberately not half-wired: unlike the superscript seam, this one cannot
    just collect on the way past. free_var()/emit() above have ALREADY run by the time we get here,
    so `n` in `a_{n+1}` is registered as a parameter and emitted as `(1)` before anything knows the
    group was an expression. Catching the failure would leave that behind. See
    docs/phase2_design.md, "Operations inside a subscript", for what it takes and for the two
    semantic questions that have to be answered before it is worth writing.
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

--[[ The decorations hanging off one unit, in the fixed order same-line -> sub. `u.call` is set by
the caller when a bracketed group followed the base on the same line.

A SUPERSCRIPT IS COLLECTED, NEVER CONSUMED, and then refused while `no_sups` is set - which is
every caller today, so a power in a name is still an error at every level: an argument is part of
the name too, so `a_{n^{m}}` is no more a name than `a^{m}` is.

WHY COLLECT AT ALL, rather than just refusing. In a real expression `a^2` is the name `a` with a
power applied to it, so an expression parser has to see both halves. It cannot get them by taking
the superscript off the node first, because ONE supsub node carries sup AND sub together (see
unit() above): in `a_n^2` the sub belongs to the name and the sup belongs to the expression, and no
amount of node surgery separates them. The only thing that can split that node is the name parser
agreeing to read the sub, decline the sup, and SAY SO. That is what `sups` is - each entry is
{node, row}, in traversal order, and it is populated whether or not the refusal fires.

So this is a scope boundary, not a permanent illegality: a power is never part of a name, and an
expression parser will act on exactly the list this leaves behind. Groundwork requested 2026-09-10:
"prepare the waters... passed to a separate part of the parser, maybe returned and ignored when
parsing names, but actioned on when looking at real expressions".
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

--[[ Parses the name pattern in `container`.

Returns a table on success:
    {name = <string>, vars = {<string>, ...}, arity = <n>, tokens = {...}, text = "a,sub,(1)"}
or nil, <message>, <offending mexpr node> on failure. The node is what lets the editor highlight
the problem rather than only describing it (docs/phase2_design.md section 3).

A FOURTH value comes back either way: `marks`, a list of {node, status} saying what the parser made
of each atom it reached - "ok", "work" or "bad" (Parser:mark's own comment). On success it is also
on the pattern as `.marks`. That is what the definition box paints per character, so the user can
see how far a name got rather than only whether it arrived. ]]
--[[ The units of a row, in order. Split out so the same reading serves a whole slot and the
left-hand side of a domain restriction.
@date 2026-09-08 08:55 ]]
local function row_units(node)
    return units_of(row_children(node))
end

--[[ A NAMED OPERATOR - `sin`, `cos`, `log`, `ln` - or nil if this atom is not one.

WRITTEN AS A 1-TALL VERTICAL whose single row holds the letters. Ruled 2026-09-10: they "will stay
as the first row in a 1 tall vertical, containing the letters of the exact name, this sort of vector
will be what latex sees as those functions".

WHY A CONTAINER. `s`, `i`, `n` loose in a row is juxtaposition, which this grammar reads as
multiplication - `sin` would be `s*i*n` with nothing to tell them apart afterwards. Wrapping makes
the name ONE atom, which is the same move quoting makes for a multi-character name, and is TeX's own
fix for the same problem (docs/phase2_design.md section 10 calls `sin`/`log`/`det` and multi-letter
subscripts one problem with one fix).

SINGLE LETTERS ONLY IN THE ROOT, which is the whole validation: every slot of that row must be one
letter. Not digits, not a nested structure, not a quoted name. A vert holding anything else is a
stack - a real thing that means something else - and must not be mistaken for a name.

Spaces are already gone by here (units_of), so `s i n` reads as `sin` like everything else.
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
        --[[ A NUMBER IS A BASE AGAIN, reversing the morning's restriction to letters. The objection
        then was that `2(x)` collides with multiplication; it does not, because a NUMERAL is not a
        trie definition - either `2(),(1)` is declared and takes the row, or nothing is and the
        expression parser reads `NUM(2)` times a bracket group. There is no third reading. Author,
        2026-09-10: "if you define 2(),(1) it will steal the whole 2(x) as the name, not leeaving
        multiplication a change to break".

        THE WHOLE RUN, or `1` and `12` branch against each other in the trie and `12(x)` could
        resolve as `1` applied to something. The last digit's unit is the one that carries any
        decoration, the same way a quoted name's closing quote does. ]]
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
        --[[ A LETTER, and only a letter. Digits were allowed as a base until 2026-09-10 - `1_u`
        was a name, "if a strange one" - and the rule was reversed on reflection: author's own
        words, "all the names start at a letter or number, this is how I remember it, and now that
        I think more, a number is a bad idea, so only letters".

        It removes an ambiguity rather than a capability. `1_u` as a NAME collides with `1` the
        literal in every context where both could appear, and a grammar that has to ask which one
        was meant has already lost. ]]
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

    --[[ WHICH NODE HOLDS THE ARGUMENTS, so a drawing of the name alone can leave them out.

    Only the last box can: a subscript typed on a name wraps whichever unit it was typed after (the
    base, or the last prime), and what it holds is the name's ARGUMENTS. `p.name` never included
    them, so neither may the boxes that draw it.

    ONE RULE FOR BOTH SPELLINGS, via mexpru.undressed - the supsub is the node itself in
    `\\vec{F}_{n}`, and is wrapped in the dress in `\\vec{F_{n}}`. This used to swap the node for its
    own base instead, which worked only for the first: the second stopped at the dress, and the
    signature line of a definition drew `F\\vec_{n}` where it meant `F\\vec`.

    NAMED, NOT REMOVED, because the accent has to stay and there is no way to hand back "this dress
    but around something smaller" without building a node. The consumer drops it by SUBSTITUTION
    instead - editor_definition's name_drawings - which is the same hook the parameter dots already
    go through. ]]
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
        local depth, j, inner = 1, next_i + 1, {}
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
            --[[ Opened and never closed. The BRACKET is the error site and is painted "bad";
            everything after it is "in work" rather than wrong, which is what most of typing
            `f(x,y)` looks like on the way there.

            The split matters twice. It stops the whole tail reading as an error - the reason this
            was all "work" before - while still saying WHICH character the message is about, which
            it could not before: both call sites discard parse_name's error-node return, so a node
            that carries no "bad" mark is a node the user cannot be pointed at. And mark_rest starts
            one PAST the bracket so the site gets exactly one mark; marking it "bad" on top of a
            "work" would stack two translucent rects. ]]
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

--[[ A row read as the DECLARATION of a name.

The left-hand side of a definition: the pattern, its literals and its numbered free variables.
Superscripts are REFUSED here - a name has no exponent, so `f^2` is not a name - which is the
asymmetry parse_use exists on the other side of.

Returns the pattern, or nil plus the reason it is not a name.
@date 2026-09-12 03:45 ]]
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

    local descs = {}
    for _, u in ipairs(units) do
        descs[#descs + 1] = atom_desc(u.atom) or "?"
    end
    local joined = table.concat(descs)
    if mexpr_ast.parse_number(joined) then
        return joined
    end
    return nil
end

--[[ Does this use match that declaration? Returns the arguments that land in the declaration's
PARAMETER positions, or nil plus the reason it did not match.

WALKED POSITION BY POSITION, because a use site cannot build the key by itself and never could: it
knows it has `F`, four subscript arguments and three call arguments, but only the DECLARATION knows
which of those positions are parameters and which are literal parts of the name. Author, 2026-09-10:
"only the declaration gives the shape".

So the two token lists are walked together. A `(k)` in the declaration is a parameter and swallows
whatever the use put there; anything else is a literal and the use must have written exactly that.
Markers - the base, `sub`, `()` - must agree outright, which is what stops `F_{a}` matching `F(a)`.

The comparison is string equality on tokens the two sides emitted the same way. No unification, no
matching a literal against a placeholder in the other direction: a declaration's literal is a part
of its NAME, so a use that wrote something else has named something else.
@date 2026-09-10 05:40 ]]
function mexpr_ast.match_use(use, decl_tokens)
    --[[ `use` is dereferenced on the next line, so it is required. `decl_tokens` is not: a
    declaration with no tokens is a real thing to test against, and `{}` matches only another empty
    one, which is the correct answer rather than a special case.

    The `use` container - {tokens, args, sups, consumed} - stays unsealed because it never leaves
    this file; parse_use_units builds it and resolve_use and this function read it. The note `unit`
    carries applies: if it ever crosses a file boundary it should be sealed. ]]
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

--[[ Every declaration this use could mean, and the verdict.

EXACTLY ONE OR IT IS AN ERROR. Author, 2026-09-10: "you should walk the variable with multiple
candidates, at the end if you don't have exactly one candidate, then you have multiple match
errors". Zero is "not declared"; two or more is an ambiguity that has to be reported rather than
guessed at, because picking one silently is how a formula ends up meaning something nobody wrote.

`decls` is content.declarations_before(...).order - a LIST, walked in document order, since every
one of them has to be tried rather than looked up by a key the use cannot construct.

THE COUNT COMES BACK AS A THIRD VALUE on failure, because "none" and "several" are different
answers and a caller can act on the difference. read_factor is the one that needs it: it tries
several extents of a row and treats the ones that do not resolve as "read this some other way",
which would bury an ambiguity as "not declared" if it could only see that resolution failed.
@date 2026-09-10 05:10 ]]
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

--[[ Reads a row as a USE of a name rather than a declaration of one, and hands back the exact keys
it might be, most specific first.

    f(34)   ->  keys {"f(),34", "f(),(1)"},  args {<the 34 row>}
    a_{n+1} ->  keys {"a,sub,(1)"},          args {<the n+1 row>}

ONE KEY, not a set of candidates. An earlier draft offered two readings of `f(34)` - the literal
`f(),34` and the placeholder `f(),(1)` - and let the declaration table choose. That was wrong, and
the correction is worth keeping because the wrong version was plausible: author, 2026-09-10, "the
name of `f(34)`, evaluated in expr context is still `f(),(1)`, that is the signature of the
function, it gives it it's identity, 34 is only the argument".

So an argument NEVER contributes to identity at a use site, whatever is written in it. A literal
argument is still an argument, and this row's KEY is `f(),(1)` either way.

WHICH DECLARATION IT RESOLVES TO IS A DIFFERENT QUESTION, and this comment used to answer it
wrongly. It said `F(0)` stays `CALL("F(),(1)", NUM(0))` even when a specialisation `F(),0` is
declared - that was an elaboration nobody had ruled on, and the ruling went the other way, author
2026-09-10: "let's try the most restrictive one". The key a use builds is still the open one; what
answers to it is chosen by resolve_use, and a declaration that pinned the position wins. The two
were never the same question.

Returns nil plus a reason when the row is not a name in either reading, which is case 1's hard
error: a formula containing something that is not a name is invalid, not partially understood.

HALF THE JOB, deliberately. This answers "which names could this be" and hands back the argument
rows untouched; it does NOT resolve them or build anything. The expression parser's actual output is
a TREE - `f(34)` is `CALL("f(),(1)", NUM(34))`, or an error if that key is not declared - and this
function is the step before it: resolution against content.declarations_before() and the node
building both live above, because both need a namespace and a declaration table that a row alone
cannot supply. See docs/phase2_design.md, "Case 1 in full".
@date 2026-09-10 03:45 ]]
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

-- The whole row, which is what a caller with a container has. Both halves exist because a
-- relation's SIDE is a unit list with no container of its own.
--[[ A whole row read as a USE of a name.

The container form of parse_use_units below, which carries the reasoning; this only turns the row
into units first. Powers ARE allowed here and refused in a declaration - `f^2(x)` is a use of `f`
with an operation on it.
@date 2026-09-12 03:45 ]]
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
    `\\rightarrow` - the arrow glyph the catalog has - and `\\to` is only LaTeX's shorter spelling of
    the same character, so there is nothing else to recognise. ]]
    ["\\rightarrow"] = ast.new_tends,
    [IN_DESC] = ast.new_in,
    ["\\ni"] = ast.new_ni,
    ["\\subset"] = ast.new_subset,
    ["\\subseteq"] = ast.new_subseteq,
    ["\\supset"] = ast.new_supset,
    ["\\supseteq"] = ast.new_supseteq,
}

--[[ AN OVERPRINTED RELATION - `\ne` - read as the one symbol the rest of the app already treats it
as.

No font here draws `\ne`, because TeX has none either: it sets the zero-advance negation slash and
prints `=` on top. mformula_latex expands the macro that way on the way in, so the row holds TWO
atoms where the reader sees one.

THIS IS THE LAST PLACE THAT READ THEM SEPARATELY. `delete_overprint_unit` (mformula_new.lua) has
made the pair delete as one symbol since 2026-09-06 - reported live as "you can write != to get
negation, but deleting it leaves the / behind" - and `is_overprint` there is the same zero-advance
test used here, so the two cannot drift as the catalog changes. The parser is completing that rule,
not inventing one.

WHY IT MATTERED MORE THAN A PARSE FAILURE. Read one at a time, `\not` falls out as an unparsable
factor and `=` stays behind as an ordinary equals - so `a \ne b` builds `a = b`, the exact opposite
of what was written, in a tree that looks entirely well formed.

KEYED ON BOTH HALVES, not on "an overprint followed by a relation". `\!` is also zero-advance (it is
TeX's negative thin space, char.lua's adv_by_desc) and negates nothing, so `a \! = b` must not become
a NEQ. Only a pair that is listed builds; a pair that is not is refused with its reason.

ONLY `=` IS PAIRED. Author, 2026-09-10: "if I remember corectly only = has that stupid problem".
`\notin` and friends are refused rather than mapped, because ast.lua has INEQ_NEQ and no other
negated node - inventing a shape here would put something in the tree that no later pass can read.
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
@date 2026-09-10 04:30 ]]
local build_expr

--[[ Forward-declared alongside build_expr for the same reason: a bigop's sub/sup constraints
(read_constraints, near read_factor) are built through build_relation - the full cascade, not just
build_expr - since a constraint IS a relation (`i=1`, `i \in S`), not a plain expression.
@date 2026-09-10 ]]
local build_relation

--[[ Forward-declared for the same reason as build_relation just above: a BRACKET's contents are
parsed at the top of the cascade (read_factor, further down), so the name has to exist before that
function is written. @date 2026-09-11 17:20 ]]
local build_connective

--[[ Forward-declared for the same reason - a bigop's unbracketed body (read_bigop, near
read_factor) is read at PRODUCT order: build_product over whatever factors remain in the current
term, not build_expr over the whole thing, so a top-level `+` (already split off by build_sum before
build_product ever runs) is never in reach without explicit parens.
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

--[[ A resolved name-use, as a node: its arguments built, and its powers wrapped around the result.
@date 2026-09-10 04:30 ]]
local function build_named(ctx_parse, use, hit)
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

--[[ ONE FACTOR, starting at unit `i`. Returns the node and the index the next factor starts at, or
nil, nil and a reason.

HOW FAR A FACTOR REACHES IS THE DECLARATIONS' ANSWER, not the row's. `a_{1}(x)` is the call
`a_{1}(x)` if something is declared with that shape, and the product `a_{1} \cdot (x)` if `a_{1}` is
declared alone - the glyphs are identical and only the declaration tells them apart. So every
extent from here to the end of the row is offered to the name parser, and the ones that RESOLVE are
the readings this row admits.

EXACTLY ONE OR IT IS AN ERROR, the same discipline resolve_use already applies across candidates -
two extents that both resolve are a genuine ambiguity, and taking the longer one silently is how a
formula ends up meaning something nobody wrote.

Only when nothing resolves is the factor a plain value, and then it is a single thing: a numeral, a
bracket group, or a free variable.
@date 2026-09-10 04:30 ]]
--[[ THE TWO EXTENTS A NAME CAN HAVE, longest first, as parsed uses of the row from `i` on.

A NAME'S LENGTH IN UNITS IS NOT OPEN-ENDED, which is the whole reason this is a pair and not a
search. read_pattern reads a base, then AT MOST ONE bracketed group, and then nothing - and a
subscript rides on the base's own unit, consuming no units of the row at all. So a name ends either
where its base does, or after the one bracket group that may follow it. There is no third place.

That is what replaced the retry loop here (2026-09-10): it tried every end position from the whole
row down to one unit, re-reading the same prefix each time, when only two of those could ever parse.
Everything between them fails for a reason that was never interesting - trailing content, or a
bracket cut in half.
@date 2026-09-10 12:40 ]]
--[[ The operators this parser gives the constraint-list treatment ("Bigop scoping",
docs/phase2_design.md) - N variables, K sub constraints, M sup constraints. `\int` is deliberately
absent: its variable comes from a trailing differential, not a relation, so it is refused rather
than routed through this at all (§8/§9, docs/ast_parsing.md).
@date 2026-09-10 ]]
--[[ EVERY GROUP BIG OPERATOR, BY HOW IT IS WRITTEN. One table, two kinds of spelling:

    "\\sum"      a GLYPH, read off the atom with atom_desc
    "lim"       a WORD, read off a 1-tall vert with operator_name

Nothing downstream cares which it was. Both are a string the row hands over, both index this table,
and both go through read_bigop unchanged - the word operators needed no reader of their own, because
the only thing that differs about them is how their name is spelled on screen. Added 2026-09-11:
"now do the limit too, it should look like sum and also add min, max argmin argmax", and, on doing
it this way, "there is a lot of code in common in between those, make sure to keep it in common".

WHY A WORD OPERATOR IS NOT A NAME, though `sin` is. `sin(x)` APPLIES a name to an argument and keys
into the definition trie as `sin(),(1)`; `min_{x}` DECLARES `x` and binds it in what follows. The
first is a function, the second is a binder, and this table is the binders. A declaration still
wins over both - name resolution runs before this in read_factor - so someone who defines their own
`lim` gets it.
@date 2026-09-11 10:20 ]]
local BIGOP_BY_SPELLING = {
    ["\\sum"]    = ast.SUM,
    ["\\prod"]   = ast.PROD,
    ["\\bigcup"] = ast.UNION,
    ["\\bigcap"] = ast.INTERSECT,
    ["lim"]     = ast.LIM,
    ["limsup"]  = ast.LIMSUP,
    ["liminf"]  = ast.LIMINF,
    ["min"]     = ast.MIN,
    ["max"]     = ast.MAX,
    ["sup"]     = ast.SUP,
    ["inf"]     = ast.INF,
    ["argmin"]  = ast.ARGMIN,
    ["argmax"]  = ast.ARGMAX,
}

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

--[[ Membership/inclusion is NOT symmetric the way `=` is: `i \in S` has an element side and a set
side, and only the element side is ever eligible to be a bigop's own variable - found live testing
`\sum_{i \in S}(i)`, which spawned `S` alongside `i` for want of a sup to subtract it against (no
sup, no subtraction, and `S` is exactly as free as `i` at the point the constraint is built).

ONE SIDE PER TYPE, keyed by node type rather than guessed from shape - a mirror relation (`\ni`,
`\supset`, `\supseteq`) points the eligible side at the OTHER operand, since `a \ni b` means `b \in
a` and `a \supset b` means `b \subset a`. `=` and the numeric inequalities are absent on purpose -
`i=j` spawning both sides is the accepted, asked-for behaviour there (§18c), unchanged.

NOT KEYED TO "THE ROOT" - a relation cannot nest inside another today (build_relation refuses a
second one at a row's top level rather than building it nested, and one inside literal parens has no
parser at all), but that is a fact about what exists RIGHT NOW, not a rule to lean on. Author,
2026-09-10, catching exactly this: "I don't want the /in to be top-level only, what if we want to
write a bolean relation?" - boolean connectives (`\land`/`\lor`/`\lnot`) do not exist yet, but when
they do, `i \in S \land i \ne j` must still only spawn `i`. So this walks the WHOLE constraint tree
instead of checking one node: wherever a membership/inclusion relation turns up, at any depth, only
its eligible side counts from that point down; every other node type (today: ADD/MUL/EQ/INEQ_*/CALL/
... - tomorrow, also AND/OR/NOT) recurses into all of its children as before. Nothing here needs to
change when a boolean layer is added - it already falls out of "recurse into every child" being the
default for anything not in this table.
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
    if type(node) ~= "table" or not node.type then
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
in each - both sides of an ordinary relation, no left/right role assigned to either (§18c "Bigop
scoping"), but only the eligible side of a membership/inclusion relation wherever one appears
(harvest_eligible above). `ctx_parse.free_order` is reset per constraint and drained into one ordered,
deduped list per call - order is first-seen, which only matters for determinism, since the caller
unions this with nothing that cares about order (sub-minus-sup is a plain set operation).
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

        --[[ WALKED IN FIRST-SEEN ORDER, and that is load-bearing rather than tidy. These names
        become the operator's variables in THIS order, filling slots 4..4+N, so the order is part of
        the tree's shape - ast.to_string writes it, and structural equality reads it.

        This was a `pairs` walk over a SET until 2026-09-10 - a hash walk, and Lua randomises the
        string-hash seed per process, so `\sum_{i=j}(i+j)` built vars `i,j` in one run and `j,i` in
        the next. One formula, two trees, on a project whose identity scheme is exact structural
        equality.

        A LIST WITH DUPLICATES IS ENOUGH, which is why there is no companion set: `seen` below
        already collapses a name mentioned twice, and it keeps the FIRST occurrence, which is the
        order wanted anyway. ]]
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

--[[ One bound of an integral - its sub or its sup - as a VALUE.

Not a constraint, which is what the group operators read there. `\\sum_{i=1}^{n}` says where `i`
RUNS; `\\int_{0}^{1}` says where the integration STARTS AND STOPS, and 0 declares nothing. So this
goes through build_expr rather than build_relation, and nothing here is eligible to become a
variable - the integral gets its variable from the differential instead.

nil, with no error, when there is no bound at all: an indefinite integral is a real integral.
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

THE PAIR IS WHAT MAKES THIS READABLE AT ALL. `\\int` and the `d` that closes it are a bracket pair
(char.BRACKET_INTEGRAL, made together at typing time - test_integral_pair.lua), so the body is
exactly what lies between the two halves and the variable is exactly what follows the closing one.
Nothing is scanned for and nothing is guessed. That is the whole reason the pair exists: the design
this replaced walked forward from the operator looking for a `d` at the right depth, which cannot
tell an integrand ending in a variable named `d` from a differential, and cannot tell which of two
integrals a `d` belongs to. Author, 2026-09-10, on why it had to be a pair: "if paired and kept
paired, there is no way for someone to miss adding the integration variable, which is important".

WHY IT IS NOT read_bigop. Everything differs except the word "operator": the variable arrives after
the body rather than out of the sub, the sub and sup are VALUES rather than constraints and spawn
nothing, and the body ENDS - it stops at the closing half instead of swallowing the rest of the
term. The one thing shared is that the body is built before the variable is known, which
ast.new_int already requires of every caller (its own comment) precisely because of this operator.

WHAT AN UNPAIRED `\\int` GETS: a refusal naming the reason. One arrives from a document saved before
the halves were paired, or from pasted LaTeX, since the tags do not survive serialization yet - so
the message says what to do rather than blaming the formula.
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
    local node = ast.new_int(ctx_parse.ns, vname, to, from, body)
    --[[ Stops after the variable, unlike a group operator, which eats the rest of its term. The
    differential is a closing bracket and a closing bracket ends a factor, so `\\int_0^1 x dx \\cdot y`
    leaves `y` for build_product exactly as `(...)y` would. ]]
    return node, var_i + 1
end

--[[ A big operator: BIGOP_CONSTRUCTORS[glyph](vars, sups, subs, body). Reads the sub/sup constraint
rows, spawns whichever names are free in the sub side and not the sup side (sub-minus-sup - see
constraint_rows and "Bigop scoping" for why the sup cannot spawn its own), then reads the body at
PRODUCT ORDER - exactly what `build_product` would consume as the REST of this factor's own term,
brackets or not.

THE BODY-EXTENT QUESTION (docs/ast_parsing.md §8) IS SETTLED THIS WAY, not sidestepped. Author,
2026-09-10: *"keep product order as the solution, so sum[i]{i} should work, sum[i]{i^2} same,
sum[i]{i^2 + i} has no way to be explicitly constructed and in exchange would need paranthesis, but
allow the simple sums to build"*. The `+` in `\sum_{i=1}^n i + 1` was never actually reachable from
here in the first place - `build_sum` (case 2, ABOVE `build_product` in the cascade) already splits
a row into terms on every top-level `+`/`-` before `build_product` ever runs, so by the time a factor
reader sees this row at all, `\sum_{i=1}^n i` and `+ 1` are already two separate terms build_sum will
add. What was open was only how much of the REMAINING factors in the bigop's OWN term its body
should swallow - all of them, same as any other factor that eats what follows it (a coefficient, a
sign) - so `\sum_{i}i^2` reads its whole remaining term as the body via `build_product`, and reaching
past a `+` needs the explicit parens that already make it one factor (`\sum_i(i^2+i)`), exactly as
asked. `\sum_{i=1}^{n}(i+1)` and `\sum_{i=1}^{n} i` (no parens - reads as `SUM(...,i)`, one factor)
both parse now; only a bare `+`/`-` inside the body without parens still needs them.

WHICH KIND OF UNIT THIS EVEN IS varies with how the row was typed. Plain `\sum_{i=1}^{n}` (no
`\limits`) is an ORDINARY supsub whose base happens to be `\sum` - `slot_atom` unwraps it same as any
other decorated letter, so `atom_desc(u0.atom)` already IS the glyph and `u0.sub`/`u0.sup` already
ARE the constraints, no different from reading a numeral's own decorations. `\sum\limits_{i=1}^{n}`
(and anything already rebuilt as one - mformula_new's own "wants_limits" flag) is the SAME node
with its sides placed over and under instead of beside.

ONE SHAPE, since 2026-09-10, when the two node kinds were merged in the C++. `unit()` hands back the
glyph as `.atom` and the limits as `.sup`/`.sub` however the row was written. This function used to
need a `bigop_of` to read a second shape off `u0.atom` directly, and a `slot_atom` that refused to
unwrap it; there is only one shape now. Only where the limits are DRAWN differs, and that was never this
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
    local body, body_err = build_product(ctx_parse, rest, false)
    if not body then
        return nil, nil, glyph .. " needs a body: " .. tostring(body_err)
    end

    -- The body consumed everything remaining in this term - nothing is left for build_product's
    -- own caller to read after this factor.
    return ast.new_group_bigop(ctx_parse.ns, node_type, vars, sups, subs, body), #units + 1
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
        local bare = mexpr_ast.parse_use_units(tail, ctx_parse.decls, {partial = true, no_call = true})
        if bare and bare.consumed ~= greedy.consumed then
            out[#out + 1] = bare
        end
    end
    return out
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
        local node, err = build_named(ctx_parse, hits[1].use, hits[1].hit)
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
        local depth, j, inner = 1, i + 1, {}
        while j <= #units and depth > 0 do
            local bb = bracket_of(units[j])
            if bb then
                depth = depth + (bb.is_open and 1 or -1)
            end
            if depth > 0 then
                inner[#inner + 1] = units[j]
            end
            j = j + 1
        end
        if depth ~= 0 then
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

    --[[ ---- INFINITY, WHICH IS A NUMERAL WITH NO DIGITS ------------------------------------

    `(N, 1, 0, 1)` - one over zero. Author, 2026-09-11: "infty should also parse, it's a number like
    any other, give it a specific value in over 0 in denominator". A number rather than a node type
    of its own is what makes it cost nothing: every place that already handles a NUM handles this,
    including build_product's negation, which turns `-\\infty` into (N, 1, 0, -1) without being told
    anything new.

    Beside the digit run rather than inside it: `\\infty` is one atom carrying no digits at all, so
    it shares that branch's RESULT and none of its scanning. It takes a power the same way, since
    refusing one here would be a rule nobody asked for.
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
            --[[ A DECORATED DIGIT ENDS THE RUN: `2^{n}3` is `(2^n) \cdot 3`, not the numeral 23 with a
            power on it. The decoration belongs to the digit it was typed on, and a numeral cannot
            be interrupted halfway and resumed. ]]
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
    --[[ A LETTER NOTHING ANSWERS TO IS A FREE VARIABLE, WHEREVER IT IS WRITTEN. Author,
    2026-09-10: "yes, allow free variables at the top of a row too".

    This was contextual for one day - ordinary inside an argument, an error at the top of a row, on
    the reasoning that `f(x)` says nothing about `x` while a row consisting of `x` names something
    that does not exist. The context flag it needed is GONE rather than pinned to true, because a
    flag with one value reads as a live rule and is not one.

    WHAT REPLACES IT IS THE BINDERS, and they are not built. `sum`, `integral`, `product` and `lim`
    each declare a variable that binds inside their body over the outer scope (docs/phase2_design.md,
    "Free variables are contextual"). Until the builder carries a scope stack, a bound variable and
    a mistyped one look identical here - which is what the old flag was standing in for, badly: it
    refused both, and one of them was legitimate. ]]
    if is_letter(d) then
        --[[ A LETTER IN FRONT OF A BRACKET IS MULTIPLICATION ONCE RESOLUTION HAS FAILED. Ruled by
        the author, 2026-09-10: "a free letter in front of a bracket should mean multiplication
        after the resolution failed, so say a was not found or found to be an independent variable
        then a( is a.( a multiplication begining".

        RESOLUTION FIRST IS WHAT MAKES THAT SAFE, and it has already happened by the time control
        reaches here: every extent of this row was offered to the name parser above, so `a(b+c)` is
        the CALL whenever anything is declared with that shape. Only when nothing answers is it a
        product - which is also the reading that says something true about `a`, because a letter
        with no declaration is an independent variable, and an independent variable is not
        applicable to anything. ]]
        --[[ `ctx_parse.free_order`, when present, is a bigop's own harvesting side-channel (see
        `read_constraints` below) - the ONLY reader of "was this specific mention free, or did it
        resolve against a declaration". The tree itself cannot answer that after the fact: a free
        `n` and a declared bare `n` both end up as the identical VREF shape, since both go through
        `var_ref`. Recording it here, at the one place resolution has already failed, is cheaper and
        more honest than re-deriving it from a finished tree. Ordinary parsing never sets this field,
        so this is a no-op everywhere outside a bigop's own constraint reading.

        A LIST, IN ORDER, because these names become the operator's variables in the order they
        arrive - so the order is part of the tree rather than an implementation detail. It was a set
        until 2026-09-10, and draining a set means a hash walk.
        @date 2026-09-10 ]]
        if ctx_parse.free_order then
            ctx_parse.free_order[#ctx_parse.free_order + 1] = d
        end
        --[[ WITH ITS DECORATIONS, exactly as a declared name carries them. `ec{F}` and `F` are
        two different things, and a free variable is no more exempt from that than a declared one -
        dropping the accent here made them the same VREF, which is the same silent collision that
        made `\hat{a}` and `a` one name before decorations reached the pattern at all. ]]
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

    local descs = {}
    for k = i, #units do
        descs[#descs + 1] = atom_desc(units[k].atom) or "?"
    end
    return nil, nil, "not parsed yet: " .. table.concat(descs)
end

--[[ The glyphs that say "multiply" out loud. Juxtaposition means the same thing, so these are
consumed and nothing else - `2 \cdot x` and `2x` build the identical tree.
@date 2026-09-10 04:30 ]]
local MUL_OPS = {["\\cdot"] = true, ["\\times"] = true}

--[[ Whether a bracket group's parentheses survive into the tree, as a CELL or as nothing.

THE RULE IS OLDER THAN THIS PARSER, written 2026-09-06: a CELL is emitted exactly when the
parentheses are NOT implied by precedence. Required ones are absorbed into the tree shape - `a(b+c)`
is `MUL(a, ADD(...))` and there is nothing left to record, because the shape re-emits them. Redundant
ones are kept, because they are the only carrier of the user's own grouping, and grouping is what
transforms.lua drags around. Author's own words, same day: "cells are practically spawned on only
redundant paths, but will help the user arange it's transformations".

REQUIRED HERE MEANS ONE THING, because a bracket group is only ever read in factor position: an ADD
inside a product of several factors. Everything else this parser builds binds at least as tightly as
a product, so its brackets add nothing to the shape and are the user's.

A GROUP AROUND A LEAF IS NOT GROUPING. `(a)+b` promotes to `a+b` - the same 2026-09-06 note calls
that "lossy in the letter, not in the spirit", and it is: there is nothing inside to group, so the
parentheses carry no arrangement to preserve.
@date 2026-09-10 07:05 ]]
local CELL_LEAF = {[ast.NUM] = true, [ast.VAR] = true, [ast.VREF] = true}

local function maybe_cell(ctx_parse, node, in_product)
    if in_product and node.type == ast.ADD then
        return node
    end
    if CELL_LEAF[node.type] then
        return node
    end
    return ast.new_cell(ctx_parse.ns, node)
end

--[[ ONE TERM: the factors juxtaposed in `units`, multiplied together, with the term's sign applied.

THE SIGN IS A PROPERTY OF THE PRODUCT, not of the row. Author, 2026-09-10: "so -x transforms into
(MUL, NUM(-1), REF(x))... +/- is a property of the next NUM or NUM in MUL". A negative term whose
first factor is already a numeral folds into that numeral rather than growing a factor, so `-2x` is
`MUL(NUM(-2), REF(x))` and not `MUL(NUM(-1), NUM(2), REF(x))`.

WHY A ROW OF LETTERS IS A PRODUCT AND NEVER ONE LONG NAME: a multi-character name is written
quoted, and a named operator is written as a 1-tall vert (operator_name), so `bb` has no reading as
a single name. That is what those two constructs are FOR - without them this layer would be
guessing.
@date 2026-09-10 04:30 ]]
function build_product(ctx_parse, units, negative, neg_unit)
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
        bracketed[#factors] = from_brackets
        i = next_i
    end
    if #factors == 0 then
        return nil, "nothing here"
    end

    if negative then
        local f = factors[1]
        if f.type == ast.NUM then
            factors[1] = tag_ast(neg_unit, ast.new_num(ctx_parse.ns, f[1], f[2], -f[3]))
        else
            --[[ The sign becomes a factor, so the product it makes is what decides whether the
            other factors' brackets were required: `-(a+b)` is MUL(NUM(-1), ADD(...)) and those
            brackets are load-bearing, exactly as in `c(a+b)`. Hence the shift below. ]]
            table.insert(factors, 1, tag_ast(neg_unit, ast.new_num(ctx_parse.ns, 1, 1, -1)))
            table.insert(bracketed, 1, false)
        end
    end

    -- Decided last, since "required" is a question about the product this factor ended up in.
    local in_product = #factors > 1
    for k = 1, #factors do
        if bracketed[k] then
            factors[k] = maybe_cell(ctx_parse, factors[k], in_product)
        end
    end

    if #factors == 1 then
        return factors[1]
    end
    return ast.new_mul(ctx_parse.ns, table.unpack(factors))
end

--[[ CASE 2. Splits the row into terms on the top-level `+` and `-`, each term a product.

A SIGN IS A SEPARATOR ONLY WITH A TERM BEHIND IT. Leading, it belongs to the term in front of it -
`-x` is one negative term, not a subtraction with nothing on the left - and a run of them folds, so
`- -x` is `x`. That single rule is what keeps `2-1` (two terms) and `-1` (one term) from needing
separate treatment.

TOP LEVEL ONLY, by bracket depth, so the `+` in `f(a+b)` belongs to the argument.
@date 2026-09-10 04:30 ]]
local function build_sum(ctx_parse, units)
    if is_untouched(units) then
        return nil, "empty"
    end

    --[[ THE SIGN GLYPHS ARE KEPT, not just consumed, so each can be tagged with the node it
    belongs to - and the two signs belong to DIFFERENT nodes:

        `+`   belongs to the ADD           it is the operator
        `-`   belongs to the NUM           it is that term's sign, and the sign lives on the number

    Author, 2026-09-11: the minus is reached "by referencing the number that holds it". That is
    already how the tree is shaped - `a-b` is ADD(a, MUL(NUM(1,1,-1), b)) - so the tag follows the
    structure rather than inventing a place for it. ]]
    local terms, cur, cur_neg, cur_neg_unit, depth = {}, {}, false, nil, 0
    local plus_units = {}
    for _, u in ipairs(units) do
        local b = bracket_of(u)
        local d = atom_desc(u.atom)
        if b then
            depth = depth + (b.is_open and 1 or -1)
            cur[#cur + 1] = u
        elseif depth == 0 and is_sign(d) then
            if d == "+" then
                plus_units[#plus_units + 1] = u
            end
            if #cur > 0 then
                terms[#terms + 1] = {units = cur, negative = cur_neg, neg_unit = cur_neg_unit}
                cur, cur_neg = {}, (d == "-")
                cur_neg_unit = (d == "-") and u or nil
            elseif d == "-" then
                cur_neg = not cur_neg
                cur_neg_unit = u
            end
        else
            cur[#cur + 1] = u
        end
    end
    terms[#terms + 1] = {units = cur, negative = cur_neg, neg_unit = cur_neg_unit}

    local nodes = {}
    for _, t in ipairs(terms) do
        if #t.units == 0 then
            return nil, "a sign with nothing after it"
        end
        local node, err = build_product(ctx_parse, t.units, t.negative, t.neg_unit)
        if not node then
            return nil, err
        end
        nodes[#nodes + 1] = node
    end
    if #nodes == 1 then
        return nodes[1]
    end
    --[[ EVERY `+` NAMES THE ONE ADD. A right-click on any of them reaches the same node, which is
    what makes "distribute this sum" a gesture on the operator rather than on a span. ]]
    local add = ast.new_add(ctx_parse.ns, table.unpack(nodes))
    for _, pu in ipairs(plus_units) do
        tag_ast(pu, add)
    end
    return add
end

build_expr = build_sum

--[[ CASE 4. Splits on the one top-level relation, or parses the row whole when there is none.

TOP LEVEL ONLY - bracket depth is tracked, so the `=` inside `f(a=b)` is not a splitter. And ONE
only: `a = b = c` is ordinary mathematics but ast.new_eq takes two operands, so a chain needs a
shape nobody has chosen yet. Refused with a reason rather than silently associating one way.
@date 2026-09-10 06:20 ]]
--[[ IMPLICATION AND EQUIVALENCE, which bind LOOSER than every relation below them.

    a=b \\Rightarrow c=d      ->  IMPLIES(EQ(a,b), EQ(c,d))

They joined two RELATIONS, not two expressions, which is the whole reason they exist - so they
cannot sit in the RELATIONS table beside `=`. There they made that row "more than one relation" and
it was refused, which is to say implication did not work at all for the only thing anyone writes it
for. Added on request, 2026-09-11: "add implies and iff, I guess those are binary, similar to in and
the rest" - binary and plain they are; it is only their PRECEDENCE that differs.

RIGHT-ASSOCIATIVE, by splitting on the FIRST one and handing the rest of the row to this function
again: `a \\Rightarrow b \\Rightarrow c` reads as `a \\Rightarrow (b \\Rightarrow c)`, which is how
implication chains in logic. That also means a chain needs no special case, unlike the relations
below, where `a=b=c` is still refused for want of a shape nobody has chosen.

Typed as digraphs - `=` then `>`, and `<` `-` `>` upgraded by `=` - each arriving as ONE glyph, so
there is a single desc to match, the same as `\\le`.
@date 2026-09-11 16:45 ]]
local CONNECTIVES = {
    ["\\Rightarrow"]     = ast.new_implies,
    ["\\Leftrightarrow"] = ast.new_iff,
}

function build_connective(ctx_parse, units)
    CTX_PARSE_SHAPE.check(ctx_parse, "ctx_parse")
    check_units(units)
    local depth = 0
    for i = 1, #units do
        local b = bracket_of(units[i])
        if b then
            depth = depth + (b.is_open and 1 or -1)
        elseif depth == 0 then
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
    end
    return build_relation(ctx_parse, units)
end

function build_relation(ctx_parse, units)
    CTX_PARSE_SHAPE.check(ctx_parse, "ctx_parse")
    check_units(units)
    local depth, at = 0, nil
    local i = 1
    while i <= #units do
        local u = units[i]
        local b = bracket_of(u)
        if b then
            depth = depth + (b.is_open and 1 or -1)
        elseif depth == 0 then
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
                if mexpru.u(u.node).kind == "dress" then
                    return nil, "decorated relation (" .. rel.desc .. ") is not handled yet"
                end
                if at then
                    return nil, "more than one relation - chains are not handled yet"
                end
                at = {i = i, rel = rel}
                i = i + rel.size - 1
            end
        end
        i = i + 1
    end
    if not at then
        return build_expr(ctx_parse, units)
    end

    local lhs, rhs = {}, {}
    for k = 1, at.i - 1 do lhs[#lhs + 1] = units[k] end
    for k = at.i + at.rel.size, #units do rhs[#rhs + 1] = units[k] end
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
--[[ THE BUILT-IN FUNCTIONS AND HOW MANY ARGUMENTS EACH TAKES.

`sin`, `log`, `det` - words that APPLY to an argument, as opposed to `lim` and `min`, which declare
a variable and are big operators (BIGOP_BY_SPELLING). Nothing here binds anything.

ARITY IS PART OF THE NAME, so it has to be decided rather than inferred: `sin(),(1)` and
`sin(),(1),(2)` are two different declarations and a use matches one of them. One argument for
everything except `gcd` and `hom`, which are written of two. That is a judgement call about
notation, not a fact about the code - `gcd(a,b,c)` is also written by people, and it does not
resolve today.
@date 2026-09-11 12:10 ]]
local BUILTIN_ARITY = {
    sin = 1, cos = 1, tan = 1, cot = 1, sec = 1, csc = 1,
    arcsin = 1, arccos = 1, arctan = 1,
    sinh = 1, cosh = 1, tanh = 1, coth = 1,
    log = 1, ln = 1, exp = 1,
    det = 1, gcd = 2,
}

--[[ DELIBERATELY SHORTER THAN THE LIST OF MACROS LATEX KNOWS, and the difference is the point.

Every name here is SPENT: it is immutable (with_builtins), so nothing in any document may ever mean
anything else by it. That is cheap for `sin` and expensive for a word somebody might reasonably use
as a variable - so `dim`, `ker`, `deg`, `arg`, `hom`, `lg` and `Pr` were dropped on 2026-09-11:
"builtins should only be those we decided... I want to minimize the crossing with normal vectors".

THEY STILL ROUND-TRIP THROUGH LATEX. char.operator_words is a separate, longer list - which macros
LaTeX names - and `\\dim` still reads in, writes out and draws. It simply does not come with a
meaning attached, so a document is free to define one. The two lists answer different questions and
are meant to differ. ]]

local builtin_cache = nil

--[[ The built-in FUNCTION names with their arities, sorted - for anything that has to list them
to a person. Sorted for the same reason builtin_declarations is: `pairs` over string keys is
randomised per process, and a help page whose order changed between runs would be its own small bug.
@date 2026-09-11 12:40 ]]
function mexpr_ast.builtin_functions()
    local out = {}
    for word, arity in pairs(BUILTIN_ARITY) do
        out[#out + 1] = {name = word, arity = arity}
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

--[[ The big operators written as WORDS - the binders, `lim` through `argmax` - sorted, same reason.
The glyph operators are left out: those are one keystroke, not a word typed letter by letter, and
they are already covered where the symbols are.
@date 2026-09-11 12:40 ]]
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

--[[ The built-ins as REAL DECLARATIONS - the same shape a definition box hands out, so resolution
cannot tell them apart from something the user wrote.

That was the intention from the start; read_pattern's own comment states it - "a built-in is an
INJECTED DEFINITION - it reaches resolution through the same declaration set as everything written
by hand, so this reads the name and resolution answers, once" - and until now nothing produced them,
so `sin(x)` serialized correctly and then failed to build.

BUILT BY PARSING, not by writing the tuples out. A declaration is a token walk (`sin(),(1)`), and
hand-writing one here would be a second opinion about what a token is - the exact drift the
`tokens`/`groups` fields ride along on the pattern to avoid. Parsing `\sin (x)` through the ordinary
name parser guarantees a built-in keys identically to a use of it, because the same code produced
both.

THE ARGUMENT NAMES ARE MEANINGLESS - `x`, `y` - and that is not sloppiness but the rule: a
parameter's spelling was never identity, `f(x)` and `f(z)` are one name. Any letter would do.

SORTED, because `pairs` over string keys is randomised per process and declaration ORDER is the
tie-break when two candidates are equally specific. An unsorted list would rank ties differently
between runs, which is the shape of a bug this project has already had once (read_constraints,
2026-09-10).
@date 2026-09-11 12:10 ]]
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
    builtin_cache = out
    return out
end

--[[ The built-ins FIRST, then whatever the document declares that does not collide with one.

THE CONSECRATED NAMES ARE IMMUTABLE. `sin` means sine. Author, 2026-09-11: "builtins should only be
those we decided... The consacrated ones are special cases, this is imutable". So a document
declaration whose key matches a built-in is DROPPED, not honoured - the opposite of what this did
when it was first written, where the user's own `sin` replaced the built-in.

WHY THE REVERSAL IS THE RIGHT WAY ROUND. These are not defaults, they are notation: a reader
encountering `sin(x)` is entitled to read sine, and a document that could quietly redefine it makes
every formula in every other document unsafe to read at a glance. The cost is that `sin` is spent as
a name, which is exactly what "consecrated" means.

BUILT-INS GO FIRST IN THE LIST for the same reason: order is the tie-break between two equally
specific candidates (resolve_use's `more_specific`), so being first is what "wins" means here.

DROPPED BY TEXT, which is the identity declarations are compared by everywhere else - and dropping
rather than keeping both matters: two declarations sharing one key make every use of it report "two
readings of this factor", which is a strange way to be told a name is taken.
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

--[[ Is `text` one of the consecrated names - a key nothing in a document may claim?

Separate from with_builtins because the two answer different questions at different times: that one
assembles the list a parse resolves against, this one is what check_declarations asks BEFORE
accepting a definition, so the refusal can name the reason instead of the definition silently never
taking effect.
@date 2026-09-11 16:00 ]]
function mexpr_ast.is_builtin_name(fontset, text)
    for _, d in ipairs(mexpr_ast.builtin_declarations(fontset)) do
        if d.text == text then
            return true
        end
    end
    return false
end

--[[ THE PARSER'S ACTUAL OUTPUT: a row as a real ast.lua tree.

Core: the top of the cascade - build_connective, since the connectives sit above the relations - and
the place the mexpr-to-ast tags are written as it goes, so a click on a glyph can later name the
node it produced.

Params: `decls` is what the DOCUMENT declares; the built-ins are added HERE rather than by the
caller, so being in scope is a property of the language and not something a call site can forget.
`ns` is optional and a fresh namespace is made when it is missing.

Returns ALWAYS THREE VALUES in the same order, success or not: `node, err, ns`. Returning
`node, ns` on success and `nil, err, ns` on failure would put the namespace in a different slot
depending on the outcome, and a caller destructuring all three would silently bind `ns` to nil on
the happy path - which is exactly what happened here first.
@date 2026-09-12 03:50 ]]
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
    local ctx_parse = new_parse_ctx(ns, with_builtins(fontset, decls or {}))
    --[[ ALWAYS three values, in the same order, success or not: `node, err, ns`. Returning
    `node, ns` on success and `nil, err, ns` on failure would put the namespace in a different
    slot depending on the outcome, and a caller that destructured all three would silently bind
    `ns` to nil on the happy path - which is exactly what happened here first. ]]
    --[[ build_connective, not build_relation: the connectives sit ABOVE the relations, so this is
    the real top of the cascade now. ]]
    local node, err = build_connective(ctx_parse, row_units(container.root))
    if not node then
        return nil, err, ns
    end
    return node, nil, ns
end

--[[ ONE ARGUMENT GROUP, described rather than parsed. Returns the label the viewer shows.

The three cases are exactly what the parser understands today, and the third is the honest one: a
group that is neither a number nor a single variable is real content nobody has written a parser
for yet, so it is shown AS TYPED rather than as a shape that would imply it had been understood.
@date 2026-09-10 04:50 ]]
local function describe_arg(units)
    local descs = {}
    for _, u in ipairs(units) do
        descs[#descs + 1] = atom_desc(u.atom) or "?"
    end
    local joined = table.concat(descs)

    if #units == 1 and is_letter(descs[1]) then
        return "REF " .. joined
    end
    if mexpr_ast.parse_number(joined) then
        return "NUM " .. joined
    end
    return "<expr> " .. joined
end

--[[ How each node type prints in the viewer. Kept as one table rather than an if-chain so a node
type nobody rendered yet is a MISSING ENTRY - which shows as its raw type number instead of being
quietly skipped or crashing the overlay.
@date 2026-09-10 06:40 ]]
local NODE_LABEL = {
    [ast.EQ]            = "EQ",
    [ast.INEQ_LESS]     = "LESS",
    [ast.INEQ_LEQ]      = "LEQ",
    [ast.INEQ_NEQ]      = "NEQ",
    [ast.INEQ_GREATER]  = "GREATER",
    [ast.INEQ_GEQ]      = "GEQ",
    [ast.ADD]           = "ADD",
    [ast.MUL]           = "MUL",
    [ast.DIV]           = "DIV",
    [ast.EXP]           = "POW",
    [ast.CELL]          = "CELL",
    [ast.IN]            = "IN",
    [ast.NI]            = "NI",
    [ast.SUBSET]        = "SUBSET",
    [ast.SUBSETEQ]      = "SUBSETEQ",
    [ast.SUPSET]        = "SUPSET",
    [ast.SUPSETEQ]      = "SUPSETEQ",
    --[[ INT is not in GROUP_BIGOP_LABEL below: it keeps the fixed (var, from, to, body) shape
    rather than the counted one, so it needs no branch of its own and only a name. Without it F4
    printed "type 21". ]]
    [ast.INT]           = "INT",
    --[[ The absent operand of an indefinite integral - ast.NULL's own comment. It reaches here
    because it IS a node, which is the whole reason it exists; before it was one, `#node` stopped
    at the first hole and the integrand simply never appeared. Printed "type 30" until named.

    Written the way printf writes a null string, on request: "null in paranthesis, like printf on a
    null string". F4 supplies its own brackets because its lines are labels, not tuples - F5 gets
    the same word without them, since the tuple it sits in already has a pair. ]]
    [ast.NULL]          = "(null)",
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

--[[ One node, and its children under it. Walks the REAL tree - `mexpr_ast.build`'s output - rather
than the row it came from, which is the whole point: the viewer cannot show a shape the parser did
not build, because it has nothing else to read.
@date 2026-09-10 06:40 ]]
--[[ THE SAME COLOUR ROLES F5 USES - ast.to_string_lines names them and explains what the colours
mean; this only has to agree. Asked for 2026-09-11: "miror those colors (those for the operator into
f4)", so an operator reads red in both panels and a variable blue-and-green in both.

`line` takes either a plain string or a list of pieces, because most lines here are one label and
only four kinds have anything worth separating out.

`prefix` NAMES THE SLOT this node was reached through, and lands on its head line - "sup: " before
whatever the upper bound turned out to be. Only the integral uses it, because only the integral has
two adjacent slots a reader cannot tell apart: an indefinite one shows two identical `(null)` lines
in a row, and nothing but their order said which was which. Asked for 2026-09-11: "maybe for those
you could add them a sup: before the expression".

NOT DONE IN F5, deliberately. That view is the serialization itself - every line has to stay
byte-identical to what to_string writes - so a label there would be a lie about the format. F4 is
the reading aid (its own header says so), and this is exactly the kind of thing it is for.
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
    --[[ NODE_LABEL is an OVERRIDE, not the list: a type with no entry falls back to its own name,
    so a node added to ast.lua is labelled the moment it exists. The table keeps only the names that
    should differ from the constant - "POW" for EXP, "(null)" for NULL.

    The fallback earns its place: "type 21", "type 30" and "type 31" were all reported here as
    puzzles by the author, once per node added, because this table was a second list that had to be
    remembered. It is not one any more. ]]
    line(NODE_LABEL[t] or ast.type_name(t) or ("type " .. tostring(t)), "op_sym")
    for i = 1, #node do
        render(ns, node[i], depth + 1, out)
    end
end


-- ################################################################################################
-- The definition trie
-- ################################################################################################

--[[ The definitions of one document, indexed by their token walk.

WHAT IT IS FOR IS THE CHECKING, not the lookup. Resolution walks the declaration list directly
(resolve_use), and with the handful a document holds that costs nothing. What a list cannot answer
cheaply is the question the RULES ask - is this new definition a prefix of one already here, or one
already here a prefix of it - and that is a trie's own shape rather than a search.

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

--[[ Adds one definition, or says why it cannot be added.

NO OVERLAPPING DEFINITIONS, in either direction: neither a prefix of an existing one, nor one of
them a prefix of it. Author, 2026-09-10: "if you have a_{n} defined, why would a be allowed? it is
already a name of something, what would a_n being a sequence and a+1 mean at the same time?" - so
the rule is about MEANING and not about whether a parser could tell them apart. Two things named
`a` are two things named `a`.

The consequence, worth knowing rather than discovering: it also forbids arity overloading, since
`f(),(1)` is a prefix of `f(),(1),(2)`.

A THIRD CASE - several marked ancestors - cannot arise while this holds, since a node's ancestors
are a chain and two marked ones would already have violated it on the way in. It is not tested for
separately; the first ancestor found is the report.
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

--[[ Does this definition contain another one? The rule that makes a nested subscript readable.

If `b_n` is a definition, `a_{1,b_m,2}` may not be one, because `b_m` inside it would be readable
both as part of `a`'s name and as an application of `b`. Refusing it at the definition is what lets
the USE site decide locally: a decorated group either resolves on its own, and is an argument, or it
does not, and is part of the name - never both (Parser:group_is_name_part).

WALKED FROM EACH ARGUMENT, which is the author's own prescription - "an apriory tree search starting
at the argument". A group that is not a name shape cannot be a definition and is skipped.
@date 2026-09-10 10:10 ]]
local function contains_definition(decl, decls)
    for _, group in ipairs(decl.groups or {}) do
        --[[ DECORATED GROUPS ONLY. A bare letter is a parameter by rule and has no competing
        reading, so `a_{m}` is fine with `m` declared elsewhere - it is not naming that `m`. The
        ambiguity this rule exists for needs a group that could be read as an APPLICATION, which
        takes a subscript. Without this guard the rule swallows every ordinary parameter whose
        letter happens to be a name somewhere above. ]]
        local decorated = false
        for _, gu in ipairs(group) do
            if gu.sub then
                decorated = true
                break
            end
        end
        local u = decorated and mexpr_ast.parse_use_units(group, decls)
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

--[[ Every definition of a document, checked against the rules, in document order.

Returns the trie and a list of {decl, why} for the ones refused. A refused definition is NOT in the
trie and is left out of the accepted list, so what comes back is a set that satisfies the invariants
rather than the set that was written.

ORDER IS THE DOCUMENT'S, and it decides which of two conflicting definitions survives: the earlier
one. That is the same rule as content.declarations_before - a name means what was said above it -
applied to the definitions themselves.

WHAT THIS DOES NOT DO YET. Accepting a definition can break one BELOW it, since inserting a box
shifts what every later box can see, and this only ever looks backwards. The pass that answers "does
accepting this at position k break anything on either side of k" is described in
docs/phase2_design.md 18d and is not written.
@date 2026-09-10 10:10 ]]
--[[ Is this the name of a built-in - a word no document may claim?

BY NAME, NOT BY KEY, so `sin_{n}` and `sin(x,y)` are refused alongside `sin(x)`. The point is that
the WORD means sine; a document that could attach a second meaning to it under a different arity
would be just as confusing as one that redefined it outright, and the reader has no way to know
which was meant.

Needs no fontset, unlike builtin_declarations, because it asks about the word rather than the token
walk - which is also what lets check_declarations call it at all. @date 2026-09-11 17:20 ]]
function mexpr_ast.is_builtin_word(name)
    return name ~= nil and BUILTIN_ARITY[name] ~= nil
end

--[[ Which of these declarations may coexist, and why the rest may not.

Core: the document's declarations are checked AS A SET, not one at a time, because the question is
whether two of them collide - a name that is fine alone is refused beside one it is ambiguous with.
Returns accepted and refused lists, each refusal carrying its reason so the editor can say it.

Detail: a consecrated name is refused FIRST, before any conflict question, because the answer is
different in kind - not "this collides with another definition" but "that word is not available".
@date 2026-09-12 03:45 ]]
function mexpr_ast.check_declarations(decls)
    check_decls(decls, "decls")
    local root, accepted, refused = trie_node(), {}, {}
    for _, d in ipairs(decls or {}) do
        --[[ A CONSECRATED NAME IS REFUSED FIRST, before any trie question: it is not that this
        definition conflicts with another in the document, it is that the word is not available.
        Refusing here rather than silently dropping it later (with_builtins does that too, as the
        last line of defence) is what lets the editor say WHY. ]]
        local why = mexpr_ast.is_builtin_word(d.name)
                and ("`" .. tostring(d.name) .. "` is a built-in name and cannot be redefined")
        why = why or trie_conflict(root, d) or contains_definition(d, accepted)

        --[[ AND THE OTHER DIRECTION: would accepting this break one already accepted? The check
        above asks whether the NEW definition swallows an existing name; this asks whether the new
        definition IS one that an existing definition had swallowed. `a_{n_{m}}` is legal while
        `n_{m}` does not exist - so defining `n_{m}` afterwards must be what fails, not `a_{n_{m}}`
        retroactively.

        Author's own framing of what this is for, 2026-09-10: "accepting a new definition should
        not break any of the old ones". Re-checking each accepted definition against the set that
        would result is the literal reading, and cheap: a document holds a handful of these.

        STILL NOT THE WHOLE PASS. This only ever looks BACKWARDS, and definitions resolve by
        document position, so inserting a box ABOVE existing ones can still break the ones below
        it - they are simply re-checked on the next frame, from scratch, and the later one is the
        one refused. What is missing is telling the user WHICH box became invalid rather than
        silently dropping it; docs/phase2_design.md 18d carries that. ]]
        if not why then
            local would_be = {}
            for i, prev in ipairs(accepted) do
                would_be[i] = prev
            end
            would_be[#would_be + 1] = d
            for _, prev in ipairs(accepted) do
                local broke = contains_definition(prev, would_be)
                if broke then
                    why = "`" .. d.text .. "` would make `" .. prev.text .. "` ambiguous - " .. broke
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

--[[ The parse of `container`, as indented lines for the F4 viewer:

    EQ
      CALL "F(),(1)"
        NUM 0
      REF "y"

RENDERS THE REAL TREE. It builds an actual ast.lua node and walks that, rather than describing the
row a second time - so the viewer cannot show a shape the parser did not build. An earlier version
walked the row itself, which was a parallel traversal free to drift from the real one; for a tool
whose whole job is to say what the parser did, that is the one bug it must not have.

`decls` is content.declarations_before(...).order - the LIST, because resolution walks candidates
rather than looking up a key the use site cannot build.

FAILURE IS SHOWN AS FAILURE. Anything with no parser yet - addition, a bare parenthesis, a chained
relation - stops the build, and the reason is what appears. Nothing is approximated.
@date 2026-09-10 06:40 ]]
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

--[[ Parses a PARAMETER cell, which must be a membership and nothing else:

        <name> \in <set>          n \in \N ,  v_{max} \in \R ^{2}

Requested 2026-09-07: "the param boxes should reject anything else than apartenance of named to
set". A parameter cell is a domain restriction, so it names the variable and the set it is drawn
from; an expression that is not a membership does not restrict anything and is refused rather than
half-understood.

A SECOND form was floated and then WITHDRAWN the same day: a cell could also have been
`a = <string or constant>`, binding the parameter to a constant instead of restricting it to a set.
Verbatim on dropping it: "yeah we get rid if that". Membership is the only accepted form - do not
re-add the equality case without asking, it was considered and declined.

Returns {var = <name pattern>, set = {<mexpr nodes>}, marks = ...} or nil, message, node, marks.

WHAT IS NOT CHECKED: the SET side. It is handed back as the raw nodes after the membership sign,
because validating it means parsing a general expression (`\R ^{2}` is a power) and that parser
does not exist yet - see docs/phase2_design.md section 3, layer 2. Marking those nodes "ok" rather
than leaving them blank is deliberate: they were read, they are simply not yet understood, and
painting them as unreached would be a lie about how far the parse got.
@date 2026-09-08 08:55 ]]
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

    local left, right = {}, {}
    for i = 1, in_i - 1 do
        left[#left + 1] = units[i]
    end
    for i = in_i + 1, #units do
        right[#right + 1] = units[i]
    end

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

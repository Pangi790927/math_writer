# Phase 2 — linking the editor to the AST

## Introduction

Design decisions from the session of 2026-09-06, after the text editor was declared done
("the user interfacing editor passed it's stage, time for second stage"). **Nothing here is
implemented yet.** It is written down because all of it was decided in conversation and would
otherwise be lost — none of it is derivable from the code, because there is no code for it.

Phase 1 = `editor.lua` + `mformula_new.lua`: free typing, mexpr trees, LaTeX in and out.
Phase 2 = giving those formulas *meaning*.

> **THE GROUND MOVED, 2026-09-09.** `scripts/mexpr.lua` and `ast.to_latex()` were deleted as
> unreachable code. This document names both repeatedly — sections 8b, 11, 12 and 16 assume
> `mexpr.lua` exists and can be repaired. It does not exist any more. Nothing in the reasoning
> below is retracted by that: `ast -> mexpr` is still the direction section 12 wants, and it is
> still the inverse of the bridge. What changed is the cost line — it is a file to be WRITTEN, not
> a file to be fixed. The old one is in git (`git show c109aaf:scripts/mexpr.lua`) and is worth
> reading before starting, if only for the tuple-type dispatch. The prose is left as it was
> written, because the reasoning it records is what this document is for.

**The document has two halves, written the same day.** Sections 1-8 cover getting a formula INTO
the checked domain. Sections 9-17 ("Part two") cover what happens once it is there. Part two
**revises** part one in several places; every superseded statement is marked inline with a quoted
block where it appears, and section 16 lists them all in one table. Section 17 lists what is still
open.

**Everything here is provisional and expected to change.** The user's own framing for part two:
*we will see by example*. Treat every rule as a first draft that the first real formula is expected
to break. Where a decision is quoted verbatim, the quote is exact and must stay exact if it travels
(see `CLAUDE.md`, amendment to Law 3); the commentary around it is free to be rewritten.

## Intent

What phase 2 is *for*, in one paragraph, because several decisions below only make sense against it:

**This is a step-checker, not a solver.** The user performs the algebraic manipulation; the program
guarantees they cannot reach a wrong result. It does not search for proofs, does not decide
arbitrary claims, and does not try to be a theorem prover. Verbatim, 2026-09-06:

> the idea of the editor is exactly that the user makes the steps and we are here just to check the
> steps, we are not implementing an automatic solver or entire definition and theorem checker, but
> a by-step one

Three consequences shape everything that follows. Steps are made by **applying a transformation**,
so the result is correct by construction and needs no verification afterwards (section 13). The
**automatic rule set decides only how big one step may be** — what the user is allowed to leave
unwritten — not what is true (section 9). And **Lean is the external source of trust**: derivations
export as `calc` blocks, statements import as roots (section 14).

## Contents

**Part one — getting into the checked domain**

| # | section | what it settles |
|---|---|---|
| 1 | Three editors, and a one-way door | promotion as the checkpoint; immutable cells; roots and derived |
| 2 | LaTeX is the user-machine language | why `mexpr -> ast` is direct and never routed through LaTeX |
| 3 | The bridge: `mexpr_ast.lua` | the walker's signature, dispatch table and row parser |
| 4 | Settled decisions | juxtaposition, rationals, no SUB, CALL, context-dependent `=` |
| 5 | Names, application and identification | decorations as application, binding, the only binder |
| 6 | Definitions | declarations vs facts, two-phase parsing, recursion |
| 6b | The type system | types are sets, rules are relations, everything is a true statement |
| 6c | What the bridge will actually SEE | macros expanded on input that never reach the AST |
| 7 | Lean | first assessment: what lines up, what does not |
| 8 | The blind spot that keeps producing bugs | `mexpru.slot_atom`, and why every walk must use it |
| 8b | Known trap in the existing code | `mexpr.lua`'s dead `mexpr_bracket()` signature |

**Part two — the checked domain**

| # | section | what it settles |
|---|---|---|
| 9 | Equality — deciding it by normalization | canonical keys, the admission rule, alpha-equivalence, morphisms |
| 10 | Names, ids, and application | the id is the real name; object versus application |
| 11 | The parse | the licensing test, type synthesis, precedence climbing, when CELL survives |
| 12 | How a step is made | the ast<->mexpr mapping, selection, patching, justifications, namespaces |
| 13 | The trust boundary | the trusted kernel, and where the user overrode it |
| 14 | Lean — the interchange language | export derivations, import statements, coercion friction |
| 15 | Defects found in `ast.lua` | four, recorded not fixed |
| 16 | What part two revises in sections 1-8 | the one table to read if you only read one thing |
| 17 | Open questions carried by part two | seven, with the biggest called out |
| 17b | The acceptance corpus | seven identities from 2025 that all of this has to walk a user through |
| 18 | Inter-workings | how the pieces connect, and in what order they must be built |
| 19 | Conclusion | what is decided, what blocks, what to build first |

---

## 1. Three editors, and a one-way door

```
  text editor            free typing, unchecked          editor.lua          (exists)
       |
       |  promote
       v
  definition cell        immutable, checked              editor_definition.lua  (slot 1 exists)
  formula cell           immutable, checked              editor_formula.lua     (empty stub)
       |
       |  Ctrl+C  ->  LaTeX
       v
  text editor again      edit freely, re-promote
```

**Promotion is the checkpoint.** Inside a definition or formula cell you never type freely —
only *syntactic mutations*, which is where `transforms.lua` belongs.

> **The editors, settled 2026-09-06.** Four files, one `editor_*` family so they sort together
> (not the `definition_editor.lua` / `formula_editor.lua` order this document first used):
>
> | file | |
> |---|---|
> | `editor.lua` | **the shared half** — everything needed to render and drive ONE formula in a box: the caret/selection highlight, the reachable-position graph, slot markers, click-and-drag hit-testing, and the version check an undo step keys off |
> | `editor_text.lua` | the flat text/glyph-stream editor (this was `editor.lua` until the split) |
> | `editor_definition.lua` | the definition box's slots |
> | `editor_formula.lua` | empty on purpose — its header records what it will be and what it waits on |
>
> **The split was forced, not planned.** `editor_definition.lua` was written first on the reasoning
> that it shared "the shape of the interface and none of the implementation" with the text editor.
> That was wrong, and it showed up immediately as a definition box with no selection, no graph
> view, no wireframe view and no way to click into it — all four of which live in the text editor
> and none of which has anything to do with a character stream. The rule that fell out: if
> something is about *a formula in a box*, it belongs in `editor.lua`; if it is about *what kind of
> box*, it belongs in that kind's own file.
>
> **Undo stayed out of the shared half.** The text editor's formula undo is entangled with its own
> snapshot system, and what an undo step even IS in a definition box is undecided. The shared half
> reports only whether a keystroke changed the tree; each owner decides what to do about it.
>
> **The definition box's form is SETTLED** (2026-09-07: *"this is the general form of a
> definition, we will use this"*). One row of `NAME : dom, dom, ... -> RET`, arity derived from
> the name pattern, a generated shorthand on the line below, and every cell diagnosed in place.
> Changes from here should be treated as revisions to a settled design, not as filling it in.
>
> **Numbers.** `mexpr_ast.parse_number()` reads a written decimal as an exact, UNREDUCED
> rational - `3.14` is 314/100, per section 4.2 - because reducing is a normalisation and
> normalisations belong to section 9's equality machinery, not to reading a literal.
>
> It reads LITERALS only, and that is a smaller thing than a number. Verbatim: *"remember
> sqrt(2) is also a number"* - and `sqrt(2)` reaches the bridge as `(2)^{1/2}` (section 6c: the
> radical is rewritten on input and never exists as a node), an EXPRESSION whose value happens
> to be constant. So numberhood in the useful sense is "has no free variables", which is
> answerable only once expressions parse and section 6b's triple can be computed. The lexer
> must not be extended to guess at it.
>
> **Parameter cells are memberships, and only that.** Each is a domain restriction written the
> way it is read - `n \in \N`, naming the variable and the set it comes from - and
> `mexpr_ast.parse_domain()` refuses anything else, marking the offending character. A second
> form (`a = <string or constant>`, binding a parameter rather than restricting it) was floated
> on 2026-09-07 and withdrawn the same day, verbatim: *"yeah we get rid if that"*. Do not re-add
> the equality case without asking - it was considered and declined.
>
> **What exists.** A definition box shows its signature as one clickable row —
> `NAME : PARAM -> RETURNSET`, or `NAME \in RETURNSET` with no parameters — with the separators
> drawn as glyphs and every slot independently editable. Slots are positional: `slots[1]` is the
> name, `slots[#slots]` is the result, everything between is a parameter, so `#slots == n + 2`.
> **`n` is DERIVED**, by `mexpr_ast.parse_name()` reading the name slot and counting its free
> variables (literals - quoted strings and numbers - are constants, not parameters). The row
> reshapes to match: arity 0 renders as `NAME \in RETURNSET`, arity 2 as `NAME : A 	imes B ->
> RETURNSET`. A name is invalid for most of the time it is being typed, so **the row holds the last
> valid arity** and the only feedback while it does not parse is a red rule under the name slot,
> plus per-character marks painted behind the name: green for what the parser read and accepted,
> blue for what is inside something unfinished (an open bracket, an unterminated quote), red on the
> character that breaks the rule, and nothing at all on what it never reached - so how far a name
> got is visible, not just whether it arrived.
> A formula box still holds nothing.

**Cells are immutable.** Editing is not forbidden, it is *relocated*: you copy out as LaTeX,
edit in the text editor, and promote again as a new cell. Consequences:

- a cell's descendants can never be invalidated, because nothing upstream can change
- a cell can safely hold BOTH representations — mexpr for display, AST for meaning — built once
  at promotion and structurally unable to drift apart
- selection rules for copying may differ per editor type

A formula cell gains a **context** when created (the definitions in scope, hypotheses, etc.).

### Roots and derived

The vocabulary, settled 2026-09-06 — not "rules" and "formulas" but **true statements**, split
into **roots** and **derived**:

- a **root** has no parent: an axiom, a known theorem, or a hypothesis
- everything else is **derived** — exactly one parent, plus the transformation that produced it

That is the proof DAG stated in one word each, and it is the same distinction the data model
needs anyway: a root is a cell with no incoming edge.

Use these two words throughout rather than "rule", "relation" or "formula" — see 6b, where all
of those turn out to be the same kind of thing.

`ast.copy(ns, node, new_ns, keep_vars)` already exists and is exactly the primitive for
deriving a cell whose variables still mean the same variables.

---

## 2. LaTeX is the user-machine language — but NOT the internal bridge

Two different bridges, two different jobs. They were conflated once in discussion; keep them
apart.

**LaTeX: checked domain <-> text domain, for the user.** Copy out, edit, paste back. Right
choice — it is the one representation both a human and the machine read, and it is already
built.

**mexpr -> ast: direct, never via LaTeX.** The brute-force route (mexpr -> latex -> ast) was
considered and rejected:

- `ast.to_latex` existed but **there was no `ast.from_latex`** (and as of 2026-09-09 there is no
  `ast.to_latex` either — it was deleted unused; the asymmetry the argument rests on is unchanged,
  and in fact wider). The AST's round-trip pair is
  `to_string`/`from_string`, its own tuple format. So "via LaTeX" means writing a SECOND LaTeX
  parser — the expensive half — which would inherit none of `mformula_latex.lua`'s fixes and
  rediscover its own bugs.
- `mexpr.lua` is already ast -> mexpr. What is needed is its inverse, not a detour.
- LaTeX is lossy exactly where it hurts: bracket *pairing* flattens to plain characters and is
  re-derived on read.
- A string loses the cursor. Direct traversal lets a failure carry the real `mexpr_t` node, so
  "this can't be interpreted" becomes a highlight on screen instead of a character offset into
  generated text.
- A string round-trip can never be incremental; a tree walk can become so later.

### Consequence: LaTeX fidelity is now correctness, not convenience

Because LaTeX carries content in and out of the *checked* domain, any lossiness there corrupts
proof steps. The 2026-09-06 fixes (braces truncating a row, `\,` becoming a comma, a space
accumulating on every save/load cycle) were annoyances under the old framing and would be
silent corruption under this one. All are now *stable* — copy, paste, copy again gives the same
string — and pinned by tests.

**Still open and worth revisiting before the formula editor round-trips real content** (and see
section 10, where the `\sin \cos \log \lim` subset turns out to be the same problem as
multi-letter subscripts, with the same one-line fix): roughly
18 macros are still dropped silently on paste (`\ast \oplus \otimes \odot \star \dagger \mid
\asymp \prec \preceq \vdots \ddots \langle \rangle \lfloor \rfloor \lceil \rceil \quad`, plus
`\sin \cos \log \lim`). As a paste-from-outside nuisance these were deliberately deferred. As
holes in the interchange language they are a different matter. Most are single catalog rows now
that the TeXbook encoding translation is written down in `char.lua`.

---

## 3. The bridge: `mexpr_ast.lua`

Named to sit beside `mexpr.lua` (ast -> mexpr) so the pair is visible. Signature:

```lua
mexpr_ast.to_ast(fs, node, env)
        -> ast_node | nil, err_message, offending_mexpr_node

-- env = { ns, scope, defs, mode = "formula" | "definition" }
```

It is **not** a pure function of the tree. `mode` decides whether `=` binds or asserts; `defs`
decides whether `f(` is a call; `scope` resolves variable identity.

> **REVISED by part two, twice.** (a) The signature is incomplete: the ast<->mexpr **mapping** is a
> first-class OUTPUT of the parse, not something carried only on failure — selection, transformation
> and mexpr patching all need it (section 12). (b) The error return needs the clashing
> declaration's id alongside the offending node, or "you applied a string with brackets" cannot say
> *which* declaration it clashed with (section 11).

### Layer 1 — tree walk

Dispatch on `mexpru.u(node).kind`:

| mexpr | AST |
|---|---|
| `horiz` | whatever layer 2 returns |
| `frac` | `new_div(num, den)` |
| `supsub` | `new_exp` or `new_call` — see the superscript rule below |
| `vert` | `new_vec(...)` / `new_mat(r, c, ...)` |
| bracket pair | `new_cell(inner)` **only if the parens are redundant** — see below; pair via `.peer`, read through `mexpru.slot_atom` |
| symbol | a *token* for layer 2, not a node |
| empty box | a hole: fail here, carrying the node |
| `dress`, `bigop` | see gaps |

> **REVISED by part two.** A bracket pair does NOT always become a `CELL`. Parens implied by
> precedence are absorbed into the tree shape (`a(b+c)` is just `MUL(a, ADD(...))`, and
> `ast.to_latex`'s `maybe_wrap` re-emits them); only parens the user wrote *redundantly* survive as
> `CELL`, because they are the sole carrier of the grouping `transforms.lua` drags around. See
> section 11.

`mexpru.slot_atom` is mandatory for brackets: the closing half is frequently a supsub base
(`(a)^2`), invisible to any walk reading children directly. That blind spot had produced **seven**
separate live bugs by the close of phase 1 — see section 8, which lists them and states the rule
every new walk must follow.

### Layer 2 — row parser

A `horiz` is flat: `a+b*c` is five atoms with no structure, so each row needs precedence
climbing. Precedence already exists in `ast.precedence` (EXP 90, MUL/DIV 80, ADD 60,
relations 10).

Token classification goes in **one table keyed by `desc`**, matching the pattern that has held
up for `size_delta_by_desc`, `y_offset_by_desc` and `adv_by_desc`:

```lua
local TOKEN_CLASS = {
    ["+"]       = {op = ast.ADD},
    ["-"]       = {op = ast.ADD, negate = true},
    ["\\cdot"]  = {op = ast.MUL},
    ["="]       = {rel = ast.EQ},
    ["\\le"]    = {rel = ast.INEQ_LEQ},
    -- ...
}
```

Every atom already carries a correct, distinct `desc` after the 2026-09-06 catalog work, so the
token vocabulary is sitting there. This is also why the `\perp` vs `\bot` and `\equiv` vs
`\cong` distinctions were worth getting right.

---

## 4. Settled decisions

1. **Juxtaposition is multiplication.** Every letter is its own VAR; adjacency inserts MUL. A
   multi-character name can only come from decoration, not from adjacent letters.
2. **Numbers are rationals.** `new_num(ns, m, n, sign)` — `12` is `(12,1,1)`, `3.14` is
   `(314,100,1)`.
3. **No SUB, no unary minus.** `a-b` desugars to `ADD(a, MUL(NUM(-1), b))`; `-3` folds into
   `NUM`'s sign field. (Marked "yes, maybe, we will see" — revisit if it proves awkward.)
4. **`f(x)` is CALL**, and whether a head is a function is decided by its *declared type*, fixed
   by the solver — not sniffed from the syntax. So `2(a+b)` stays multiplication.
5. **`=` is context-dependent**: a *fixer* in a definition (it binds the name), a *mirror* in a
   formula (both sides are uses). Same glyph, two meanings, disambiguated by `env.mode`.

> **4 is REVISED by part two: strike "fixed by the solver".** Parsing cannot wait on a solver it
> feeds — the solver reads the AST, and the AST's shape depends on the answer. The head's form is
> fixed by its DECLARATION, declaration-before-use is mandatory, and an undeclared head is an error
> rather than an inference target. Section 11 has the full argument and the licensing test that
> keeps `2(a+b)` multiplication without any rule specific to numbers.

---

## 5. Names, application and identification

### All three decorations are application

```
a_n   ->  CALL(a-sub, n)      drawn as a subscript
a^n   ->  CALL(a-sup, n)      drawn as a superscript
a(n)  ->  CALL(a, n)          drawn with round brackets
```

**The notation is part of the NAME**, not per-call metadata and not a field on the declaration.
`a-sub` and `a` are different objects; if they are meant to be the same, that is a **theorem**.
Nothing is identified silently.

This closes what was listed as an unsolved gap ("subscripts have no AST node") — they need no
new node. It also avoids a serialisation problem: `ast.to_string` writes only the array part
plus `type` and `id`, silently dropping any named Lua field, so a per-node `notation` field
would not survive a save. A name survives, because names already serialise.

> **REVISED by part two — the head is `a`, not `a-sub`.** `a_n` is `CALL(a, n)`: ONE id, applied.
> `a` and `a_n` are different in the same sense `f` and `f(x)` are different — object versus
> application — not because they are different names. The notation lives on the **declaration**
> (the define box says `a` is a string, and strings are written with subscripts), which dodges the
> same serialisation problem a per-node field would have hit, since declarations serialise. The
> conclusion above survives intact: subscripts still need no new node. See section 10, which also
> records what this buys — the `a = a()`-until-`a[]` retraction problem disappears, and section 6's
> open questions (a) and (b) close and narrow respectively.

### Where the naming rule STARTS

The rule above governs the checked domain, and only there. **The text editor may substitute
whatever characters it likes, right up until the point where content becomes a root.**

That is the one-way door of section 1 doing its job. Before promotion there is no AST, no
namespace, no names - so there is nothing an identity rule could even be about. Everything phase 1
does to the glyphs on the way in is an INPUT METHOD, not a semantic decision:

    >=  becomes  \ge            NN  becomes  \N           ~  becomes  \sim
    !=  becomes  \not =         ..  becomes  \cdot        _| becomes  \perp
    \sqrt{x} becomes (x)^{1/2}          \cup + limits becomes \bigcup

None of those needs justifying against notation-is-name, because none of them happens to a root.
Identity begins the moment a cell is created, and from then on nothing is swapped silently -
promotion is exactly the checkpoint where "whatever the user typed" turns into "a specific named
thing".

(An earlier draft of this document flagged the \cup/\bigcup promotion as an unresolved contradiction
with section 5. It is not one. Recorded here because the mistake is an easy one to repeat: the
naming rule's boundary is PROMOTION, not the keyboard.)


### The superscript rule

Superscript is ambiguous — `a^2` is a power, `a^n` may be an application. The declared type
decides, and one rule resolves the awkward case:

> A superscript is an application only on an **un-applied head whose type is a function**.

So `a_n^2` reads as `(a_n)^2`: once `a` has taken its index, `a_n : R`, and `^2` can only be a
power. Matches convention, needs no new notation.

> **NARROWED, 2026-09-10: a NAME never carries a superscript at all.** Author's own words: "I
> changed my mind, names don't have sups, only subs or function arguments (themselves)".
> `mexpr_ast.lua`'s name parser now refuses one outright, at every level - `a^{'abcd'}` and
> `a_{n^{m}}` were both accepted before and are errors now.
>
> This does not retract the rule above, it shrinks what the rule has to cover. The ambiguity was
> only ever about a superscript attached to a *name*; with those gone, a superscript is always an
> operation on an expression, and "is this an application or a power?" is a question the expression
> parser asks, never the name parser. The `a^2(x)` case that `decorations()` used to hedge about -
> is the `()` the power's or the name's? - stops existing rather than being decided.

#### Where the powers go instead

Refusing them in names is only half an answer: outside a definition block, `a^2` and `f^{-1}(x)`
are ordinary things to write, and something has to read them. The seam is already in the parser,
inert, waiting for the half that does not exist yet.

**Why the name parser has to be the one to report them.** The obvious split - let the expression
parser take the superscript off and hand the rest to the name parser - does not work, and the
reason is structural rather than a matter of taste. `mexpr_ast.lua`'s `unit()` builds one entry per
row slot, and a supsub node carries `sup` **and** `sub` together. In `a_n^2` the sub belongs to the
name and the sup belongs to the expression, on one node. No node surgery separates them. The only
thing that can split that node is the name parser reading the sub, declining the sup, and saying
which sup it declined.

**So it does.** `Parser.sups` collects every superscript met, at any depth, as `{node, row}` in
traversal order. `Parser.no_sups` decides what happens next, and defaults to TRUE, so every caller
that exists today - `parse_name`, `parse_domain` - refuses a power exactly as before. An expression
parser clears it and reads the list instead.

**What that parser then owes.** Each entry is a power applied to whatever the name parser had built
when it hit that node, so the expression is `pow(<name so far>, <row>)`. That is also where the
"superscript rule" above finally applies - `f^{-1}` as an inverse rather than a reciprocal is a
question about the head's declared type, which is expression-level knowledge the name parser
deliberately does not have. It only ever answers "here is a name, and here are the powers I did not
consume".

Nothing reads `sups` yet. The refused-power cases in `test_name_pattern.lua` are what guard the
default: flip `no_sups` and they fire, which is the intended alarm rather than a nuisance.

#### The expression parser: four cases to start

Settled 2026-09-10 as the dispatch to build first, before any operator handling. Everything else -
multiplication, addition, precedence - is deliberately deferred; these four are the skeleton that
the rest hangs off.

| at this node | what happens |
|---|---|
| **1. a name** | read it, resolve it against the declarations above this box. If it is not a name, the whole formula is INVALID - that is a hard error, not a fallback. |
| **2. `+` / `-`** | a sign, which always ends up on a NUM - see below. |
| **3. `(`** | with no name in front it cannot be a call, so it opens a CELL - `ast.new_cell`. |
| **4. `=` and the inequalities** | the only splitter. Builds the relation - `ast.new_eq` or one of the five `new_ineq_*`. |

Case 1 is where everything already written comes together: build the candidate keys, look them up
in `content.declarations_before()`, and generate the reference plus whatever the declined
superscript said to do. Case 1 failing is what makes a formula invalid rather than partially
understood - there is no "unknown name" node.

**Case 1 in full: the parser's output is the TREE, not the key.** Clarified 2026-09-10 - a name
pass at a DECLARATION produces a key; the same pass at a USE produces a key *and* a tree, and the
tree is the answer. The key is consumed on the way, not returned.

| written | produces |
|---|---|
| `f(34)` | `CALL("f(),(1)", NUM(34))` - or an ERROR if `f(),(1)` is not in the database |
| `f(x)` | `CALL("f(),(1)", REF(x))` |
| `a_{n+1}` | `CALL("a,sub,(1)", ADD(REF(n), NUM(1)))` |
| `f^2(x)` | `POW(CALL("f(),(1)", REF(x)), NUM(2))` |

Four things that fall out of those rows, all of which the AST already supports:

- **The callee is the KEY STRING**, not a node. `ast.new_call(ns, fn, ...)` stores `fn` untyped, so
  `"f(),(1)"` goes straight in. That is the right shape rather than a convenient one: the
  declaration lives in another box's namespace, and the exact-equality rule makes the string the
  identity. Nothing needs resolving across namespaces at build time.
- **Occurrences are REFS, never the variable.** Author: "with ref not the var itself because the
  same x may appear above it in an equal, a multiplication, etc. (ex `xf(x)`)". So one `ast.new_var`
  per distinct name per expression, and every mention is an `ast.new_vref` to it. `new_vref` takes
  an id rather than a name, which forces exactly that structure - a name cannot become a reference
  without a variable to point at.
- **The superscript wraps the call, it does not join it.** `POW(CALL(...), NUM(2))` - the reference
  is built first and the declined `sups` are applied around it, which is what `Parser.sups` was
  collected for.
- **A missing definition is a hard error.** `f(34)` where `f(),(1)` was never declared does not
  degrade into an unknown-name node; the formula is invalid.

**Undefined variables, deferred.** "if a variable is not defined, it shall be treated as the freest
variable in the expression's domain, but that is a side efect we will look into later". So a `REF`
to something with no declaration is not an error the way a missing CALLEE is - it becomes a free
variable of the enclosing domain. The asymmetry is deliberate: a call names a definition that must
exist, a bare variable names something the expression itself may be quantifying over.

**Named operators - `sin`, `cos`, `log`, `ln` - are a 1-tall vertical.** Ruled 2026-09-10: they
"will stay as the first row in a 1 tall vertical, containing the letters of the exact name, this
sort of vector will be what latex sees as those functions".

WHY A CONTAINER AND NOT THREE GLYPHS: `s`, `i`, `n` sitting loose in a row is juxtaposition, which
this grammar already reads as multiplication - `sin` would be `s*i*n` and there is no way to tell it
apart after the fact. Wrapping the letters in something makes the name ONE unit, which is the same
move `'quoted'` makes for a multi-character name. The 1-tall vert is a container that already
exists (`mexpru.vert`, `kind = "vert"`), already draws as plain letters at one row, and already
survives save/load.

**What it touches, none of it done:**

- `unit()` needs a `vert` case beside its `supsub`/`bigop` ones, so a vert reaches the parser as an
  atom rather than falling through to "not a name".
- Resolution goes to a BUILT-IN table, not `declarations_before()`. `sin` needs no definition box;
  that is the difference between a named operator and a declared name, and it is why they are worth
  telling apart at all.
- A superscript still wraps it, so `sin^2(x)` is `POW(CALL("sin", REF(x)), NUM(2))` with no new
  rule - which is a good sign the representation is the right one.

**LaTeX, and a bonus.** `\sin` has no entry in `char.lua` today, so it is one of the ~18 macros
CLAUDE.md records as silently dropped on paste. Making `\sin` mean this vert closes that hole for
the whole family rather than adding glyphs one at a time.

**This closes an old question rather than opening a new one.** Section 10 already found that
`sin`, `arcsin`, `log`, `det` are the SAME problem as a multi-letter subscript - "one problem, one
fix" - and named the cure as TeX's own: make them single atoms. The 1-tall vert IS that atom, now
with a representation. Section 16's table lists this as question 6(b), "how is a multi-letter
subscript written at all?", narrowed to the general multi-letter-name problem; it can be answered
the same way.

**Which raises the one thing to settle: there would then be TWO ways to write a multi-letter name.**
A quoted literal (`'maxlim'`, already implemented, arity 0, part of the name grammar) and a 1-tall
vert. They overlap exactly on "several letters that must read as one thing". Plausible split: the
quoted form names a VALUE and the vert names an OPERATOR, which is why one lives in the name pattern
and the other is applied to arguments. But if that is the split it should be written down, because
otherwise the two will be used interchangeably and `a_{'maxlim'}` and `a_{<vert maxlim>}` will end
up as different keys for the same intent - and the exact-equality rule means they would never
resolve to each other.

**Open:** a 1-tall vert whose letters spell nothing known. It is the natural way to write a
user-named operator, but `to_latex` then has to choose between `\operatorname{foo}` and the
existing `\stack{foo}` - and `\stack` is this codebase's own invented macro for verts generally,
so the two readings collide on exactly the 1-row case. Worth settling before the writer is touched,
because a wrong choice round-trips silently into the save file.

**Case 2 in full: a sign is a property of a NUM, never a node of its own.** Author, 2026-09-10:

> so `-x` transforms into `(MUL, NUM(-1), REF(x))`, the idea is that we will fix references
> afterwards, link the ref to the scoped-var and that `+/-` is a property of the next NUM or NUM in
> MUL, this I think should fix the sign

So the sign is never an operator and never a wrapper. It lands on a number - an existing one where
there is one, a synthesized `NUM(-1)` where there is not:

| written | becomes | why |
|---|---|---|
| `-5` | `NUM(-5)` | the literal carries its own sign, as `parse_number` already reads it |
| `-x` | `MUL(NUM(-1), REF(x))` | nothing to fold into, so the sign becomes a factor |
| `-2x` | `MUL(NUM(-2), REF(x))` | folds into the number that is already there, NOT `MUL(NUM(-1), NUM(2), ...)` |

The last row is the point of the rule: there is only ever ONE signed number, so two spellings of the
same product cannot produce two different trees. It also means no unary-minus node exists to reason
about later - negation is multiplication by a negative literal, and nothing else in the AST has to
know the difference.

**References are unresolved when built.** `REF(x)` is created as a name, and linking it to the
scoped variable is a later pass - the same shape as the specialisation links above. The parser's job
is to say WHAT was referred to, not to have found it.

**This is what makes `ast.lua` live again.** Its constructors - `new_eq`, the five `new_ineq_*`,
`new_cell`, `new_num`, `new_var`, `new_vref`, `new_call` - have had no reachable caller since
`mexpr.lua` was deleted (2026-09-09). The four cases above are their first real consumer, and the
tuple shapes at the top of that file are the contract to build against.

#### Operations inside a subscript

`a_{n+1}` is an ordinary thing to write and is not a name: the subscript holds an expression. The
detection rule is the author's, 2026-09-10, and it is a good one because it needs no new
machinery - *"when reaching a point where a free var should be and we find something else, well
that is an expression"*.

**Where that point is, measured rather than assumed.** The name grammar gives up in exactly two
places, both inside `parse_argument`:

| input | where it stops |
|---|---|
| `a_{n+1}`, `a_{2n}`, `a_{f(n)}` | *"juxtaposition inside a name"* - the trailing `last_i < #units` check |
| `a_{-n}` | *"an argument must be a name, a quoted literal or a number"* - the `else` branch |

Those two sites are the whole boundary. An expression-enabled pass turns them from failures into
handoffs, gated by a flag in the parser the same way `no_sups` gates powers.

**Why it is not built yet, and this is the part worth knowing.** The superscript seam could be
added for free because a name parser never consumes a superscript - collecting one costs nothing.
This seam is not free: `free_var()` and `emit()` run **before** the juxtaposition check, so by the
time `a_{n+1}` is known to be an expression, `n` has already been registered as a parameter and
emitted as `(1)`. Catching the failure at that point leaves that behind, and the pattern would
report an arity that came from inside an expression.

Two ways out, neither free:

- **Classify, then parse.** Decide "is this group one simple argument?" before parsing it. The
  catch is that classification is not cheap - a quoted name spans several units, so the classifier
  has to walk the group the same way the parser does, and now there are two definitions of what an
  argument looks like.
- **Parse transactionally.** Let `parse_argument` note where the accumulators stood on entry and
  truncate back to it if the group turns out not to be simple, then hand the whole group over.

The second is right, and cheaper than it first looks: **all four accumulators are append-only**.
`vars`, `tokens`, `marks` and `sups` are only ever written as `list[#list + 1] = x`, with no
removal anywhere in the file - so a savepoint is four integers and a rollback is four truncations,
and it is an EXACT undo rather than an approximation. The parser can go on emitting as it goes; it
just rewinds when the group turns out to have been an expression. No buffering, no second
definition of what an argument looks like.

That property is worth protecting: the moment anything starts rewriting or reordering those lists
in place, rollback silently stops being exact, and an argument that failed halfway would leave
debris in the pattern.

**Two questions to answer before writing either.** Both decide identification, so they cannot be
left to the implementation:

1. **What does an expression argument contribute to the pattern text?** `a_{n}` is `a,sub,(1)`.
   What is `a_{n+1}`? If it is anything structural, two spellings of the same index have to produce
   the same text or they will not identify.
2. **Is `n` in `a_{n+1}` a parameter of `a`?** If yes, arity counts free variables through
   expressions and `a_{n+1}` has arity one. If no, `a_{n+1}` is a name of arity zero that happens
   to mention `n`, and the `n` binds to the surrounding scope instead. This is the same question
   section 6 asked about `v_'max'`, one level deeper.

#### Answered: a use is a REF, and both questions dissolve

Author, 2026-09-10, on what `f(34)` means when `f(x)` has been declared:

> the name `f(),(1)` is a name of a variable, like all variables, this variable is referenced and
> used in a call, as such `CALL(REF('f(),(1)'), NUM(34))` [...] we still need the `function`
> signature

That settles both questions above, and it does so by moving them:

- **Question 1 dissolves.** An expression argument contributes nothing to a pattern text, because at
  a use site no pattern is being *built*. A pattern is only ever produced by a DECLARATION. A use
  site produces a key and looks it up.
- **Question 2 answers "no".** Parameters exist only in declarations. `n` in `a_{n+1}` is not a
  parameter of `a`; it is a free variable of the surrounding scope, inside an expression that
  happens to sit in a subscript. The use is `INDEX(REF("a,sub,(1)"), <expr n+1>)` - arity comes from
  the declaration, and the use site only supplies subtrees.

**The same walk builds the key.** To resolve `f(34)`, the parser walks it exactly as it walks a
declaration and emits `(k)` for each argument position regardless of what is in it, keeping the
argument subtrees aside. `f(34)` -> key `f(),(1)`, arguments `[NUM(34)]`. `a_{n+1}` -> key
`a,sub,(1)`, arguments `[<n+1>]`. The declaration's own text is the same string, which is what makes
the lookup a string compare rather than a tree match.

> **SUPERSEDED, 2026-09-10, and the candidate-key idea goes with it.** The paragraphs from here to
> the end of this subsection argued that a use site cannot tell `f(),34` from `f(),(1)` and so must
> offer both. It does not have to: **an argument never contributes to identity.** Author: "the name
> of `f(34)`, evaluated in expr context is still `f(),(1)`, that is the signature of the function,
> it gives it it's identity, 34 is only the argument".
>
> A use site therefore produces exactly ONE key - the signature - whatever is written in the
> argument positions. `f(34)`, `f(x)` and `f(n+1)` are all `f(),(1)`. `F(0)` in an expression is
> `CALL("F(),(1)", NUM(0))` even where a specialisation `F(),0` has been declared; the two are
> related by expression matching later, not by a reference picking a different name now. No
> specificity ordering, no candidate list, nothing for the declaration table to disambiguate - it
> answers "does this signature exist", and a miss is a hard error.
>
> The argument below is kept rather than deleted because its other conclusion still holds and still
> matters: `F(0)` and `F(n)` really are both legal DECLARATIONS. Only the use-site half was wrong.

**Where the signature is genuinely needed** - and this is the part that cannot be removed. Literals
stay in the key while parameters become placeholders (`a_'maxlim'` is arity zero, text
`a,sub,'maxlim'`). So a use site reading `f(34)` cannot tell on its own whether it means:

- a call on the declared `f(),(1)` with the argument 34, or
- a reference to a variable whose *name* is literally `f(),34`.

Both are well-formed keys for the same input. Only the declarations in scope decide, so a use site
produces CANDIDATE keys - placeholder-form and literal-form - and resolution picks between them.
That is the concrete content of "we still need the function signature": not type-checking, but
disambiguating what was even referred to.

**And both keys are ordinary, not one real and one theoretical.** `F(0)` is a legal declaration
today - measured 2026-09-10, it produces text `F(),0` with arity 0, exactly as `F(n)` produces
`F(),(1)` with arity 1. Which is to say the two forms are how a RECURSION is written:

```
F(0) = 1
F(n) = n * F(n-1)
```

Two declarations, both in scope, differing only in whether the argument position holds a literal or
a parameter. So candidate keys are not a defence against a contrived input - without them the base
case of a recursion cannot be referred to at all.

**Which forces a specificity rule.** With both declared, a use site reading `F(0)` produces the
candidates `F(),0` and `F(),(1)`, and both exist:

> **The literal form wins when it is declared.** `F(0)` means the base case; `F(3)` falls through to
> `F(),(1)` because `F(),3` was never declared.

That is the only reading that makes the recursion above mean what it looks like.

**IDENTITY IS EXACT STRING EQUALITY. There is no unification, ever.** Author, 2026-09-10: "it is
important to state `f(),(1)` is not the same string as `f(),34`, those two are exact deduced
names+shape, so if they don't match they don't match".

This is the rule the whole scheme rests on, and it is worth being blunt about because "specificity"
invites the opposite reading. `F(),0` and `F(),(1)` are two different names. Nothing matches a
literal against a placeholder, nothing treats `(1)` as a wildcard, and no lookup ever asks "is
there a declaration this could unify with". A pattern text is a name plus its shape, deduced
exactly, and two texts are the same name only when they are the same string.

So resolution is a dictionary lookup and nothing more. What the use site does is produce SEVERAL
exact keys - one reading of the row per candidate - and try each against the table by equality. The
"literal form wins" rule above is about the ORDER the use site offers its own candidates in, not
about one key matching another. Two things follow that are worth having:

- Lookup stays a hash hit. No search, no backtracking, no cost that grows with the number of
  declarations in scope.
- A near miss is a miss, loudly. `F(),3` simply is not there, and the answer is "no such name"
  rather than a silent fall-through to something that looked close enough.

The specialisation link below is therefore an EXPLICIT relation between two distinct names,
established deliberately, never a similarity noticed at lookup time.

Only the single-argument case has been thought through. Two literal positions, or a mixture
(`G(0,n)` beside `G(m,n)`), multiply the candidate keys a use site has to offer, and the ORDER it
offers them in needs stating properly before anything relies on it - it is an ordering over exact
keys, not a matching problem.

**A specialisation is not a rival declaration - it LINKS to the one it specialises.** Author,
2026-09-10:

> definitions will be later checked by expression matching first, case in which that definition
> will require to link to the more encompasing one, practically specializations of sort. Not sure
> I would ever use that, but if needed I have it as an option, else I don't see why people would
> define f(x) and afterwards f(34)

So `F(),0` is not a separate variable that happens to look like `F(),(1)`; it is `F(),(1)` at a
particular argument, and it should carry a reference saying so. That link is what later makes the
pair checkable rather than merely resolvable - the specialisation can be matched against the
general form's own expression, which is the difference between "these two names both exist" and
"this one is the n = 0 case of that one".

It also explains why the standalone case looks strange: `f(34)` declared with no `f(x)` above it is
a legal name and always was, but nobody writes one on purpose. The literal form earns its keep as
a specialisation, not on its own.

**Open, and it is a scheduling problem rather than a semantic one.** Scope is "boxes above", so a
specialisation can only link to a general form written EARLIER in the document. But a base case is
usually written first:

```
F(0) = 1            <- wants to link upward to something not declared yet
F(n) = n * F(n-1)
```

Three ways out, none chosen: require the general form first (fights how people write); let
specialisations look downward, which is a hole in the scope rule and would need its own
justification; or resolve links in a second whole-document pass, leaving the first pass to collect
declarations and the second to relate them. The third keeps the scope rule intact and matches how
the passes are already split, but it means a specialisation's link is not available at the moment
its box is parsed.

This costs nothing, because it is the order the passes already run in. Author, same day: *"this is
happening when parsing expressions not names, so the expression parser can reuse exactly all the
information it has learned from the previous pass"*. Declarations are read first and produce the
patterns; the expression pass runs after them with that table in hand. So the lookup is not a new
dependency to be arranged - it is the previous pass's output being used for the thing it was built
for, and the name parser stays a pure function of one row.

**And it makes the superscript seam consistent.** A power at a use site is an operation on the
reference, not part of the key, which is why `Parser.sups` hands back the rows it declined rather
than folding them into the name. Both seams say the same thing from different sides - a name is
what a declaration produced; everything else around it at a use site is expression.

**But "power" is only one reading of a superscript, and the parser must not assume it.** Author,
2026-09-10:

> if `^(n)`, then it is differentiation, `^'`, `^''`, are all derivatives, `^n` is the result of
> the function to the n'th power so pow as you've said, or whatever the user decides

So a superscript on a reference is NOTATION SELECTING AN OPERATION, not a fixed one:

| written | means |
|---|---|
| `f^{(n)}` | the nth derivative |
| `f^{'}`, `f^{''}` | first, second derivative |
| `f^{n}` | `POW(...)` - the result raised to n |
| ...whatever else is declared | ...whatever it was declared to mean |

`POW` was the example, never the rule. What the parser owes is the row it declined plus enough
context to say WHICH notation it was, and the decision of what that notation does belongs with the
user's own declarations - the same way the name pattern itself is user-declared rather than
built in. A parser that hardcoded `POW` would make derivative notation unwritable, which is the
same mistake as hardcoding what a name may look like.

Either way the result is a subterm: the function with its superscript applied becomes one operand
of whatever expression encloses it.

### Identification is four checks

1. same head name (resolved to a VAR id — **names are never compared directly**)
2. same arity (`a_n` and `a_{n,m}` fail here and never reach matching)
3. arguments match (term matching, `n := 1`)
4. the substitution is well-typed (`1 : N` is what licenses it)

### Subsumption is directional

`a_n` (with `n` universally quantified) **subsumes** `a_1`; the reverse does not hold. This is
an instantiation order, not symmetric equality, and the two directions are used for opposite
things by a solver — specialising a known general fact, versus generalising something proved
for an arbitrary `n`. Do not call both "equal".

### Binding

Variable identity comes from binding, not spelling. The AST already supports this:
`ast.new_var(ns, name)` creates a VAR with its own `id`; `ast.new_vref(ns, ref)` holds that id.
`ast.copy`'s `keep_vars` flag shows the author separated "same spelling" from "same variable"
from the start.

The walker carries a **scope chain**. First occurrence in a scope binds; later ones reference.
A binder pushes a child scope.

**The bigop is the only binder.** `a = \sum\limits_{a=0}^{k} a`:

```
EQ
├── VAR#1 "a"                 outer scope, free
└── SUM
    ├── index VAR#2 "a"       binder: new scope, shadows #1
    ├── from  NUM 0
    ├── to    VREF -> k       free, resolves outward
    └── body  VREF -> #2      the INNER a
```

`#1` and `#2` are both spelled `a`, have different ids, and `ast.same_var` (to be written)
compares ids, returning false.

**This revises an earlier recommendation.** "Defer bigops" was wrong: a sum is the only binder,
and binding is where scopes come from, so a binder node is needed *before* the bridge is
meaningful. It needs five slots — `operator, index-var, from, to, body` — which is NOT the
shape mexpr uses (three slots, operand as a following sibling in the row, because that is how
TeX lays it out). The walk must pull the operand in from the row and split `a=0` in the lower
slot into index and start value. This is the first place the layout tree and the meaning tree
genuinely disagree.

Other gaps (dresses, `\in`, `\approx`, relations beyond the six) can still be deferred — none of
them binds anything.

---

## 6. Definitions

```
a_n : N -> R  ;  a_n = 2^n
      ^type         ^optional axiom ("an initialization theorem of sorts")
```

A definition box emits **a declaration** (name, type) and **zero or more facts**. These are
different kinds of thing: one extends the namespace, the other extends what is provable.

Definition blocks are also where the **typing rules** are written — see section 6b, which is
what makes them the centre of the system rather than a preamble to it.

**Parsing is two-phase**, and this is the only place the env is built mid-parse:

1. register the name and its type from the pattern left of `:`
2. parse the equations with that name already in scope

which is what makes recursion work (`a_0 = 1 ; a_n = 2*a_{n-1}`). The optional part is a
**list** of equations, not one.

### Open questions

**(a) Can an index range over a finite set of labels?** `a_n : N -> R` has an infinite domain,
but physics-style writing needs `F_g`, `F_e` — labels from a small fixed set. Does the type
syntax allow `F-sub : {g,e} -> R`?

> **ANSWERED by part two: yes, and no new syntax is needed.** The subscript is application
> (section 10), and section 6b already makes `{g,e}` a type by making types sets, so `F : {g,e} -> R`
> gives `F_g` as an application at the element `g`. Note the head is `F`, not `F-sub`.

**(b) How is a multi-letter subscript written at all?** Juxtaposition is multiplication, so
`v_{max}` parses as `CALL(v-sub, m*a*x)`. Either labels need their own notation, or a subscript
holding a label is parsed differently from one holding an index expression — and only the
declared domain can tell which, which loops back to (a).

> **NARROWED by part two, still open.** With (a) answered, this stops being about subscripts and
> becomes the general **multi-letter name** problem — the same one as `sin`, `arcsin`, `log`, `det`.
> One problem, one fix, and the cheap fix is TeX's own: make them single atoms in `char.lua` (they
> are already on section 2's dropped-macro list), so the bridge meets one token and no shape
> recognition is needed. See section 10.

---

## 6b. The type system — and why everything is a theorem

Decided 2026-09-06, and it changes what the AST needs more than any other decision here.

### Types are NOT AST nodes

There is a separate relation, `name is-type`. `R` is a type name; `x elem R` says the type of
`x` is "element of R". Types then **flow through the AST** by rules attached to operations: if
`a elem R` and `n elem N` then `a + n elem R`.

So the AST needs no type nodes, no arrow nodes, no product nodes. Three requirements that
looked structural simply disappear — a `VAR` does not grow a type slot, a declaration is a row
in a side relation rather than a node, and `to_string`'s positional-only format stops being a
constraint on any of this.

### Types are sets

`elem` is membership, subtyping is subset, and `{g,e}` from section 6 is a type by the same
token. The type layer therefore *reuses* the set machinery instead of running beside it.

This promotes two relations from cosmetic to load-bearing: **`\in` is the typing judgement and
`\subseteq` is subtyping**, written in the user's own notation. Type facts are ordinary formulas.

### Three things flow, not one

An expression yields a triple, computable in one walk over the tree:

1. the **linked variables** — which names it depends on
2. the **type**, filtered through the operations
3. the **value** of the mapping, where determinable

The value domain needs an "unknown" element (a symbolic `a` has no value), so it is partial
evaluation rather than evaluation. "Same name — name including structure — with the same
inputs gives the same type and the same value" is referential transparency, and the immutable
cells of section 1 are what actually guarantee it.

### Rules are RELATIONS, not functions

Types flow *up*; a fact like `a + n elem N` constrains `a` *downward*. Bottom-up propagation
cannot use such a fact, constraint solving can — and solving is already wanted ("`f`'s type will
be fixed by a solver, to find var", section 4.4).

> **The 4.4 quote above is one part two struck** (see the box in section 4). The solver keeps
> everything this subsection gives it — downward constraints from user-stated facts, finding
> values, reporting uncovered operations — but it never decides a head's form and never decides
> tree shape, because parsing feeds it and cannot wait on it. Unknown during parse is an ERROR;
> under-determined after parse is a CONSTRAINT. See section 11.

The two are compatible: propagation is the special case where every leaf's type is known. But
only **if the rules are written as relations from the start**. A rule written as a function,
`add(R, N) -> R`, runs one way only; written as a relation over the triple it runs in whichever
direction has enough information. Retrofitting direction into a table of functions means
rewriting every rule, so this is settled now even though the solver comes later.

### Where the easy rule breaks

For closed operators a rule is just the **join over the subset lattice** `N < Z < Q < R < C` —
`R + N` is `R` because `R` is the join. But not everything is closed:

```
N / N   is not N     division promotes to at least Q
N - N   is not N     subtraction needs Z
R ^ R   is not always R    a negative base with a fractional exponent leaves the reals
```

`EXP` is *partial*, so the system must take a position: emit a constraint (`base > 0`), widen to
`C`, or refuse. That decision is not yet made.

### Everything is a true statement

The unifying move, taken from Bourbaki: **rules, relations and formulas are the same kind of
thing.** They are all *true statements* — some roots, some derived (section 1). A typing rule is not a Lua table entry — it is a
statement in the user's own language, written in a **definition block**, stored as an AST, and
handled by the same machinery as everything else. Defining rules is practically what definition
blocks are *for*. Each rule then becomes a **requirement**: using `+` on two operands is
licensed only if some rule covers those types, and an uncovered case is reported as a missing
requirement rather than silently typed.

That inverts the usual framing. The type checker does not *compute* a type so much as *find a
rule licensing this node*, or say what is missing.

(Bourbaki's own foundations are widely considered clunky — pre-type-theory, set-theoretic, with
some famously unusable encodings. What is being taken here is the organising principle, not the
encoding, and that principle is close to how modern proof assistants unify propositions and
types. See section 7.)

A typing rule is therefore a **root**: an axiom the user writes in a definition block, not
something the program knows a priori.

> **PROVISIONALLY REVERSED by part two, and this is the biggest open conflict in the document.**
> Verbatim, later the same day: *"I won't actually hold it as an axiom like that, that would be
> wasteful"* and *"the same + contains the types backed in"* — i.e. `+` knows its own typing, the
> program DOES know it a priori, and there is no user-written rule to be a root. Read as SCOPING
> ("at least for now" — built-in typing for the algebraic core, user-written rules possibly later)
> rather than a full reversal, but that reading is **not confirmed**. See sections 14 and 16, and
> open question 4 in section 17.
>
> Note what survives either way: the *inversion* above — "find a rule licensing this node, or say
> what is missing" — is untouched, and part two shows it is the same lookup the PARSER makes when
> it decides CALL versus MUL (section 11). Two subsystems collapse into one.

### Consequence: the logic layer is NOT deferrable

This reverses earlier advice in this document, and it is the second time the same reversal has
happened — first with binders (section 5), now here. The pattern is worth noticing: each time,
what looked like an advanced feature to defer turned out to be the foundation.

If rules are formulas, then **propositions, implication and quantifiers are needed to write the
very first typing rule.** "For all x, y: x elem R and y elem N implies x + y elem R" cannot be
stated without them. They are not phase-3 work; they gate the type system, which gates
definitions.

> **HALF REVISED by part two.** If typing is built in (see the box above), this particular reason
> evaporates — no typing rule is ever stated, so none needs quantifiers. **The conclusion stands on
> its other leg:** you cannot state a theorem with hypotheses, and cannot import a single mathlib
> lemma, without propositions, implication and quantifiers (section 14). What changes is the
> ORDERING — the type checker can now be built before the logic layer instead of after.

### Open: bootstrapping

If typing rules are formulas, and formulas are type-checked, that is circular. Either a base
set of rules is primitive and unchecked (axioms), or checking is staged. Not yet decided, and it
should be before the first rule is written.

> **CLOSED by part two, conditionally.** If `+` carries its own typing, base rules are primitive
> and the circularity never forms. This question only reopens if open question 4 (section 17)
> settles the other way.

## 6c. What the bridge will actually SEE

Several LaTeX macros are expanded on the way IN and never exist as nodes, so `mexpr_ast.lua` will
never meet them. Listing them because the obvious instinct - "the AST needs a radical node, a
not-equal node" - is wrong for every one of these.

    \sqrt{x}      is already  (x)^{1/2}      a bracket pair and a supsub, nothing more
    \sqrt[3]{x}   is already  (x)^{1/3}
    \ne           is already  \not =         two atoms, the first zero-width
    \notin        is already  \not \in
    \mapsto       is already  \mapstochar \rightarrow
    \ldots        is already  . . .          three separate atoms
    \cdots        is already  three \cdot atoms
    \cup + limits is already  \bigcup         (an input method, see 5)

So: no radical node, and no composite-relation nodes. What the walk meets is ordinary atoms.

The flip side is that some of these lose information the AST might want. `(x)^{1/2}` does not say
"this was a square root", and `\not` followed by `=` does not say "this is one relation"
- the walk has to recognise the SHAPE if the AST is to carry `\ne` as a single relation
rather than a negated equality. Both readings are defensible; the second is closer to how a solver
would want it.

## 7. Lean

Asked whether this could talk to Lean. Verdict: the *proof structure* is already Lean-shaped
almost by accident; the *logic layer* does not exist, and that is the whole distance.

**Lines up:** declarations are nearly identical (`a : N -> R` vs `def a : Nat -> Real` — written
`a-sub` when this section was first drafted, before section 10 established the head is plain `a`);
"one transformation per cell" is exactly Lean's `calc` block; "equivalences must be proved" is
Lean's stance; binding-by-identity matches.

**Does not:** the AST has no propositions, no `forall`/`exists`, no implication — hypotheses and
theorems have nowhere to live yet. Notation-as-identity cuts against Lean, where notation is a
display layer over one constant. And dependent types are where Lean's power is; simple arrows
reach the easy fraction only.

> **The notation objection is DISSOLVED by part two.** With the id as the real name, the notation
> fixed by the declaration, and `a` vs `a_n` being object versus application (section 10), there is
> now exactly one constant per name with a display convention attached to its declaration — which
> IS Lean's model. The missing logic layer remains the real distance.

**Realistic integration, cheapest first:** emit `calc` skeletons with `sorry` per step; then
emit justifications, where `by ring` / `field_simp` / `linarith` / `norm_num` plausibly close
most routine algebra without mapping lemmas by hand; then import; then live checking.

**Do not design for Lean now.** But add the two things that make the cheapest level possible
later, because retrofitting them is expensive:

> **REVERSED by part two.** Verbatim, later the same day: *"I was thinking making lean the latex of
> part 2"*, and the decision was taken — **Lean is the target for the checked domain.** Section 14
> is that decision worked out: what the LaTeX analogy buys (export derivations as `calc`, import
> STATEMENTS not proofs), where it breaks (a Lean reader is a Lean elaborator, which will not be
> written here), and the one genuine friction that survives (subtyping versus coercion). The two
> items below are still exactly right — they are now requirements rather than hedges, joined by a
> third: a rule's identity must be allowed to be EXTERNAL (`mathlib:mul_comm`), or an imported
> lemma cannot be cited in a justification.

1. **a proposition kind in the AST**, distinct from terms — `a = b` as a *claim* is not the same
   node as `a = b` as an equation being manipulated. Note section 6b needs this anyway and much
   sooner: a typing rule is a formula, and cannot be stated without propositions, implication
   and quantifiers. So this is not a concession to Lean; Lean just happens to want the same thing.
2. **a justification field on every derived cell** — which transformation, with parameters.
   Needed for provenance and undo anyway, and it is exactly what a `calc` step's `:= by ...`
   consumes.

With those two, the first level is a serialiser rather than a redesign.

*(Lean and mathlib move quickly and this was written against a knowledge cutoff — verify tactic
names and export tooling before relying on them.)*

---

## 8. The blind spot that keeps producing bugs

`mexpru.slot_atom()` exists because a bracket's closing half is frequently a supsub BASE - `(a)^2`
puts the `)` inside the supsub, invisible to any walk that reads `children` directly.

By the close of phase 1 that one blind spot had produced **seven** separate live bugs: cascade
delete taking the wrong partner, scan_bracket reporting an unrelated boundary, the wrap counter
mis-balancing, the sprint skipping a bracket carrying an exponent, pairs not growing under an
exponent, and `scan_bracket` itself still reading around it as late as 2026-09-06.

Every row walk in the codebase now goes through it. **Any new walk must too** - including every walk
in the bridge. This is the single most reliable source of defects in this code.

## 8b. Known trap in the existing code

> **SETTLED, 2026-09-09, by deletion.** `mexpr.lua` is gone — see the note in the introduction.
> The trap below no longer sits in the tree; it becomes a requirement on whatever replaces the
> file, which is why the reasoning is kept rather than struck out.

`mexpr.lua`'s header records that its four `vc.mexpr_bracket()` calls still use a signature that
no longer exists (the C++ split it into `mexpr_bracket_left`/`_right`), reachable only through
`main.lua`'s dead demo. They must be fixed before `ast -> mexpr -> ast` can serve as a test
oracle for CELL/VEC/MAT.

That oracle is worth having: **`ast -> mexpr -> ast` should be identity**, so every expression
`mexpr.lua` can draw becomes a bridge test with no hand-written expectation.

> **REVISED by part two: this is no longer only about a test oracle.** If a step patches its mexpr
> by REGENERATING the changed subtree through `mexpr.lua` (section 12, the recommended option),
> then ast -> mexpr runs on every step that touches a bracket. Those four calls move from
> dead-demo-only to the critical path.
>
> Note also that the reverse direction is NOT an oracle: `mexpr -> ast -> mexpr` cannot be identity,
> because layout choices do not survive the trip. And because the accepted mexprs are a strict
> SUBSET of all possible ones, the rejection set needs its own tests — each recording the assumption
> about why that shape is meaningless, not merely asserting an error code.

---
---

# Part two — the checked domain

**PROVISIONAL. Expect all of it to change.** Everything below was decided in conversation on
2026-09-06, in one sitting, against no implementation at all. It is written down because it would
otherwise be lost, not because it is settled. Several parts already revise sections 1-8 above (see
section 16 for the list), and the user's own framing for the whole half was: *we will see by
example*. Treat every rule here as a first draft that the first real formula is expected to break.

Sections 1-8 above describe getting a formula INTO the checked domain. Sections 9-19 describe what
happens once it is there: how two expressions are compared (9), how names and application work
(10-11), how a step is made (12), what is trusted (13), how any of it leaves for Lean (14) — then
what this half revises (15-17), how the pieces connect (18), and where it all stands (19).

---

## 9. Equality — deciding it by normalization

### What equality is FOR

Not for solving. The tool does not search for a proof and does not decide arbitrary claims. The
user makes the steps; the code checks them. Verbatim, 2026-09-06:

> the idea of the editor is exactly that the user makes the steps and we are here just to check the
> steps, we are not implementing an automatic solver or entire definition and theorem checker, but
> a by-step one, we only need to ensure that a. the user can do the transformations steps with
> checks and b. that the user can tell the code (probably by adding normalizations and morphisms)
> to the lua code such that the steps are made yeasier.

So the job of the automatic rule set is narrow and should be stated that way:

**The active rule set defines what the user is allowed to leave unwritten.** Nothing more. It does
not decide what is true; it decides how big one step may be.

The worked example, verbatim:

> equality will be needed for a range of steps for example eliminating like terms, a transformation
> would be something like a^2 + 2ab + b^2 - 2ba -> a^2+b^2, by removing 2ab = -2ba, this step may be
> explicit or implicit and the user needs the liberty to choose between both, so he decides if +2ab
> reduces automatically with -2ba, (this also allows as if we keep the delimitation to let the user
> decide if ab=ba)

That step needs two rules active — commutativity of MUL to see the like terms, and coefficient
collection to cancel them. With commutativity OFF the step **must fail**, and that is the feature,
not a limitation: it is what keeps the tool usable for matrices, quaternions, anything where
`ab != ba`.

Equality is also needed even in a pure transform-applied workflow (section 12): "eliminate like
terms" has to FIND `2ab` and `-2ba` as like terms before it can offer itself. So the machinery is
load-bearing regardless of whether the user is ever allowed to type a result for checking.

### It has a name (several)

Worth recording so nobody re-derives the literature:

- deciding equality by rewriting each side to a canonical representative is **normalization**, and
  the rule set is a **term rewriting system**. It works only if the system is **convergent** =
  *terminating* (rewriting stops) + *confluent* (application order does not change the result).
- turning a pile of equations into a convergent system is **Knuth-Bendix completion**. Orienting a
  symmetric equation into a directed rule is the step that matters here.
- sorting the arguments of a commutative operator is **AC canonicalization** (associative-
  commutative). Mathematica ships the two halves as symbol attributes: `Orderless` (sort the
  arguments = commutativity) and `Flat` (splice nested calls = associativity).
- the general "try, fail, rewrite, retry" loop over rules NOT known to be convergent is **equality
  saturation**, over an **e-graph** with **congruence closure** (`egg` is the reference
  implementation). This is the expensive road and the design below deliberately avoids it.
- registering rules per type makes it a **many-sorted equational theory**.

### The admission rule (this is the load-bearing decision)

Two algorithms were described in conversation and only one is affordable:

1. `norm(a) == norm(b)` — normalize each side once, compare once.
2. for each morphism `M`, test `M(a) == M(b)` — a retry loop.

(2) is incomplete with more than one morphism: a difference may need sort AND flatten AND constant
folding applied together, and no single `M` gets there. Fixing that honestly means searching
combinations, which is where e-graphs come from.

(1) is available because of a restriction the user stated independently: keep only the theorems
that take a node and result in exactly one node. Formalised:

> **A rule may join the AUTOMATIC set only if it is a normalizer** — idempotent, and confluent with
> every other rule already in that set. Then the whole set is applied to fixpoint on each side,
> once, and the comparison happens exactly once.

Rules that do not qualify are not automatic. They are explicit transforms the user invokes, which
is `transforms.lua`'s job anyway. That gives a clean two-tier system instead of one blurry one.

Two payoffs: the normal form is **cacheable and hashable**, so a cell can carry its canonical key
and equality is O(1) after the first computation; and the justification stays honest, because an
automatic equality records ONE step named after the procedure rather than fifty rewrites. That is
what Lean's `ring` / `ac_rfl` do, and it drops straight into section 7's justification field.

### The pipeline

```
canon:   strip CELL  ->  flatten ADD/MUL  ->  sort  ->  compare
```

- **strip CELL** first, because redundant parentheses survive into the tree (section 11) and
  `(a+b)+c` must be able to meet `a+b+c`.
- **flatten** is the associativity half. The parser already builds flat n-ary ADD/MUL by
  construction, so this only matters after a transform has reintroduced nesting.
- **sort** is the commutativity half, and is only in the automatic set if the user put it there.

### Two invariants

**Normalize the comparison, never the content.** If normalization wrote back into the stored tree,
then with coefficient collection enabled, typing `a^2 + 2ab + b^2 - 2ba` would immediately become
`a^2 + b^2` — and the intermediate expression the user wanted to SHOW would be unwritable precisely
because the rule that checks it is on. So the cell stores exactly what the user wrote; normalizers
run inside the equality check, on a throwaway, and never write back.

**The normal form is a KEY, not a tree.** Two independent reasons:

- `ns.by_id` never releases and `last_id` only climbs, so building a sorted AST copy on every
  comparison would permanently grow the namespace.
- the invariant above — a key cannot accidentally be stored.

So the primitive is `canon_key(ns, node) -> string`, not `normalize(ns, node) -> ast`. A real
normalized tree is built only when the user must SEE the step.

### The total order that sorting needs

Sorting needs a total order over AST nodes, and it must distinguish two uses of `id`:

- **`node.id`** — the trailing `:N` written by `ast.to_string`, assigned by `ast.new` from
  `ns.last_id`. Allocation bookkeeping. **Excluded from the key for every node type.** Two
  structurally identical terms built at different times have different ids; an id-based comparator
  on structural nodes makes `sort(a)` and `sort(b)` disagree and the whole scheme fails silently.
- **`VREF[1]`** — `(&, ref_id)`. That id IS the content of the node. **In the key.**
- **a `VAR`'s own `.id`** — the binding site's identity. Content, exceptionally; the `name` field
  is decoration and never enters a comparison.

So the comparator ignores ids at structural nodes and ranks on them at the leaves. This is what
makes the two `c`s of `c = 3` and `lim [c->0] {c}` different terms: the VREFs carry different
`ref_id`s and the spelling `c` never participates.

Consequence to accept: because free variables order by id, the sorted order of a sum is
arbitrary-looking (`a + b` may canonicalize to `b + a` because `b` was allocated first). Harmless
while the normal form is an unseen key. If a sorted sum is ever DISPLAYED it needs a second,
presentation order (by name, say) kept separate from the comparison order.

### Alpha-equivalence

The same example cuts both ways. `lim [c->0] {c}` and `lim [d->0] {d}` are the same statement and
must compare equal, but pure id comparison says they are not. Names cannot rescue this (they are
not identity) and raw ids cannot (they are too fine).

Fix, cheap in a key-not-a-tree scheme: **de Bruijn indices in the key only.** The AST keeps
`VAR`/`VREF` unchanged; `canon_key` substitutes while walking:

- entering a binder pushes its `VAR` id on a stack
- a `VREF` whose `ref_id` is on the stack prints as its depth — `#0`, `#1`
- a `VREF` that is not prints as its raw id — free, and globally identified

All three cases at once: free `c` distinct from bound `c`; bound `c` equal to bound `d`; two
independently created global `c`s still distinct, which is correct because they ARE different
variables.

Safe with sorting **only because the bigop is the only binder** (section 5) — sorting siblings never
changes binder depth. That stops holding the moment two binders can be reordered. Recorded as an
assumption so it is checked rather than discovered.

Open: is alpha-equivalence automatic, or a rule the user enables? Argument for automatic: the
alternative is that renaming a summation index produces a statement you have to re-prove.

### A morphism is three things, not one

The user will extend the rule set. What is added should be decomposed:

- **the statement** — `ab = ba`. A root in the user's own notation, symmetric, assumed or proved
  like anything else.
- **the orientation** — a normalizer is directed (sort the arguments); the theorem is not.
  Orienting equations into terminating rules is the Knuth-Bendix step and is a real choice living
  outside the statement.
- **the policy** — automatic or explicit, per document.

Keeping them separate is what lets section 6b's "everything is a true statement" survive while the
practical knob still exists. It is also what keeps the trusted kernel from growing — see section 13.

Mathlib's `simp` set is exactly this object: curated statements, oriented, with an automatic
attribute. The correspondence is not an analogy.

### Open: the defaults

**Undecided.** Verbatim: *"we are yet to decide if the user would want to identify (a+b)+c as the
same things as a+b+c"*. It is not a global yes/no but a per-document policy, and the case where
re-association must be OFF is exactly the one the CELL decision protects — a user whose subject
matter IS associativity and who needs `(a+b)+c` to stay visibly distinct while manipulating it.

Suggested (not decided) default: strip-CELL and flatten ON, commutativity OFF. Grouping noise is
never the point; commutativity often is.

---

## 10. Names, ids, and application — revises section 5

### The id is the real name

The glyph is decoration. Two variables may both draw as `c`; the user tells them apart by scope,
the code tells them apart by id. This is deliberate — the alternative is showing the user
`a_id2312`, which is what the name actually is.

Consequences:

- **renaming is free.** Changing what a variable displays as touches nothing: no re-derivation, no
  cell invalidation, no key change.
- **display names need not be unique.** Two different `c`s on screen is the normal case;
  disambiguating them is a RENDERING job (hover, colour, an explicit marker on demand), not a model
  job.
- **`ast.from_string` refusing to merge namespaces on an id collision is correct behaviour.** Two
  independently saved documents genuinely cannot merge, because their ids are different names that
  happen to be spelled the same. Merging must be an explicit identification step, not a load.

### `a` versus `a_n` is object versus application

Section 5 recorded `a_n -> CALL(a-sub, n)` with `a-sub` a SEPARATE NAME. **That is revised.** The
head is plain `a`. Verbatim, 2026-09-06:

> as such a and a_n are different, in the same sense in which f and f(x) are different things

So a define box saying `a` is a string makes `a` the sequence itself and `a_n` one cell of it —
different things by construction, no identification theorem needed, exactly as nobody thinks
`f = f(x)`.

```
a_n   ->  CALL(a, n)        one id, applied; subscript is how application is WRITTEN
```

### Notation lives on the declaration

Section 5's "notation is part of the name" existed to avoid a per-node `notation` field, since
`ast.to_string` writes only the array part plus `type` and `id` and would silently drop a named Lua
field. Under the revision the notation is on neither the node nor the name — it is on the
**declaration**. The define box says `a` is a string, and strings are written with subscripts; it
says `f` is a function, and functions are written with round brackets. Declarations serialize, so
the original problem does not arise.

Three things fall out, all improvements:

- **The retraction problem disappears.** An earlier sketch had `a = a()` holding automatically
  *until* an `a[]` declaration appeared — non-monotonic, and in direct conflict with section 1's
  guarantee that a cell's descendants can never be invalidated. Under one-declaration-fixes-one-form
  a later `a[]` is a DIFFERENT declaration and therefore a different id; existing statements keep
  pointing at the old one and nothing is retracted.
- **Section 6's open question (a) is answered.** "Can an index range over a finite set of labels?"
  Yes, trivially: the subscript is application, so `F : {g,e} -> R` makes `F_g` an application at
  the element `g`, and section 6b already made `{g,e}` a type by making types sets. No new syntax.
- **Section 6's open question (b) narrows.** `v_{max}` needs `max` to be a NAME, not `m*a*x`, and
  only the declared domain can say which. So (b) stops being "how do subscripts parse" and becomes
  "multi-letter names exist for elements of finite label sets" — which is the SAME problem as `sin`,
  `arcsin`, `log`, `det`. One problem, one fix. The cheap fix is TeX's own: make them single atoms
  in `char.lua` (they are already on section 2's list of ~18 dropped macros), so the bridge meets
  one token and no shape recognition is needed.

Section 5's superscript rule survives untouched: `a_n^2` reads as `(a_n)^2` because `a_n` is
already applied and has type `R`, so `^2` can only be a power. That rule was already phrased in
terms of an un-applied head whose type is a function, which is precisely this model.

### Wrong form is an error, not a reinterpretation

Verbatim, 2026-09-06:

> so, the parser knows the definitions prior to parsing, as such a(x) will be flagged as an
> absurdity as the string 'a' can't be called

The parser never silently finds another reading. It says: you applied a string with brackets.

---

## 11. The parse — a worked trace, and what it implies

The canonical example, verbatim, 2026-09-06:

> 2(a+b) the parser starts: sees 2 -- this is a number, we will start parsing a number, as such 2 is parsed and we continue
> ( is meet, the previous token is 2 a number, numbers can't call, as such this must be the multiplication, we consider the interior of the () as a multiplication term
> we go inside, we find a, a variable by a prior definition, a real
> we find +, the previous was a variable, real, can be added, start an add node
> the following is b, a number, add it to the existing add
> ) the add expression is done, so (MUL, (NUM, 2), (ADD, ref-a, ref-b))
>
> a(x) a is a string
> ( is meet, a string can't be multiplied, a string can't be called -> error

### The licensing test

Everything in that trace is one lookup, asked twice:

```
<primary>  then  '('   ->  can the left thing be CALLED?         yes -> CALL
                       ->  else can it be MULTIPLIED?            yes -> MUL
                       ->  else                                       absurdity
```

`2` fails the first and passes the second. `a : string` fails both. No special case for numbers, no
"applicability" predicate — just the type's admissible operations. The `+` step is the same lookup
again ("previous was a real, can be added").

**This is section 6b's inversion, and it means the parse decision and the type check are the same
lookup.** Section 6b: *"the type checker does not compute a type so much as find a rule licensing
this node, or say what is missing."* Two subsystems collapse into one. This also preserves section
4.4's `2(a+b)` staying multiplication, with no rule specific to numbers.

The error must carry both halves: the offending mexpr node AND the clashing declaration's id, so
the editor can highlight the call you wrote and the define box that says `a` is a string. Section
3's return (`nil, err, offending_mexpr_node`) is not enough on its own.

### Types are synthesized during the parse

Verbatim, 2026-09-06:

> types will be deduced on the fly, the idea is that some things have types by definition, so for example a-ref has the type of a, when we get to "a+" we already know some things about the type, a is a real, + enters a state wheere it exepcts something add-compatible with a real, so if b is given, then it's ok, it is accepted, so practically on the recursion start the type is not known but by the recursion's end, the type will be knwonw

That is **bidirectional type checking**: types synthesize upward from leaves, and an operator pushes
an expected type down onto what follows. No solver, no second pass.

What it requires: **every leaf's type is known before the walk reaches it.** Compound types are
deduced; leaf types are declared. So declaration-before-use is mandatory — an undeclared head is an
error, not an inference target — and the recursion always terminates in declarations.

**One exception:** a binder-bound variable has no declaration. In `\sum_{i=0}^{n}`, `i` gets its
type from the range. The binder is the declaration for its own scope, which means the bigop's parse
must establish `i`'s type from `0..n` BEFORE walking the body — a fourth thing the bigop does
beyond the slot-reshuffling section 5 already flags.

**This revises section 4.4's "fixed by the solver".** Parsing cannot wait on a solver it feeds: the
solver reads the AST, and the AST's shape depends on the answer. The solver keeps everything
section 6b gave it — downward constraints from user-stated facts, finding values, reporting
uncovered operations — but it never decides tree shape. Unknown during parse is an ERROR;
under-determined after parse is a CONSTRAINT.

### Precedence climbing, and where the check actually fires

`a + b * c` was worked out in conversation and lands on the standard algorithm: **precedence
climbing** (equivalently Pratt parsing). `ast.precedence` already carries the numbers (EXP 90,
MUL/DIV 80, ADD 60, relations 10). "Wait for the node `b` to close, `a+b` is incomplete because `*`
follows, transition `b` into `(MUL, b, ...)`" is the left-denotation step.

Two timing rules that the simple trace does not expose:

- **the operator's type check completes at FOLD, not at the token.** At `+` you can only ask the
  weak question (is `a` addable at all?); the licensing check for `ADD(a, MUL(b,c))` and its result
  type happen when the fold completes. Checking the wrong pair accepts things it should not.
- **the CALL-vs-MUL check fires on the preceding PRIMARY, not the preceding token.** In `a_n (x)`
  the thing being called-or-multiplied is the whole application `a_n`. That type is available
  precisely because it is a completed subtree.

### CELL — when parentheses survive

Verbatim, 2026-09-06:

> cell will be emited sometimes so (a+b)+c will be valid, and also ((a+b)+c), but a(b+c) is never valid without a cell, so no need for it, I think, cells are practically spawned on only redundant paths, but will help the user arange it's transformations

The rule:

> **A `CELL` is emitted exactly when the parentheses are NOT implied by precedence.**

Required parens are absorbed into the tree shape — `a(b+c)` is `MUL(a, ADD(...))` and there is
nothing to record, because `ast.to_latex`'s `maybe_wrap` (`scripts/ast.lua:480`) re-emits them from
precedence alone. Redundant parens are kept, because they are the only carrier of the user's
grouping, and grouping is what `transforms.lua` drags around.

So `(a+b)+c` is `ADD(CELL(ADD(a,b)), c)` and stays distinct from the flat `ADD(a,b,c)`.

Consequences:

- `maybe_wrap`'s "if parent is CELL, it already provides parentheses" branch
  (`scripts/ast.lua:484`) becomes dead once the bridge stops emitting CELL for required parens —
  delete it rather than leave a trap.
- **CELL is meaning-transparent**: always erased in the canonical key (section 9), never erased in
  the tree.
- redundant parens the user did NOT write do not appear; `(a)+b` promotes to `a+b`. Lossy in the
  letter of section 2, not in the spirit — meaning is preserved exactly.

`;` as a matrix column delimiter is an mexpr / input-method question and does not reach the AST;
`ast.new_mat(ns, rows, cols, ...)` already takes the shape positionally.

### One walk, three outputs

Section 6b says three things flow — linked variables, type, value — "computable in one walk over
the tree". With types deduced during parsing, **that walk IS the bridge walk**. One traversal
produces the AST, its types, its variable dependencies, and whatever partial evaluation is
determinable, all at promotion. Because cells are immutable (section 1), none of it is ever
recomputed and none of it can drift from the tree it describes.

It also feeds section 9 directly: the type a node needs in order to look up its registered
normalizers is already sitting on it.

---

## 12. How a step is made

Verbatim, 2026-09-06:

> how it works: ast from mexpr as ast = parse(mexpr, rules), what this does is create a mapping between an ast-node and one or more mexpr-nodes, the user selects an mexpr which in turn selects the associated ast (as a copy) and does one of the transformations in trasnform.lua, now the new ast has the same meaning as the old ast but is morphed, we finaly copy -echivalate the mexpr and we fix it to match the copy-ast and we make a new box with it, this is how boxes are made from the formula box, so each formula box will be a step in the derivation

So each formula box is one step in the derivation, and the DAG of section 1 is the sequence of
boxes. (Referencing older theorems: deferred, explicitly.)

### The mapping is a first-class output, not an error-path detail

Section 3 carries an mexpr node only on failure. It must be carried on **success, for every node** —
it is what makes selection, transformation and patching possible.

It is many-to-many in both directions, including zero:

- **implicit MUL has no operator atom at all** — `2ab`'s MUL maps to no glyph, only to its
  operands' spans.
- **a CELL maps to two atoms**, and per section 8 the closing one is routinely buried as a supsub
  base (`(a)^2`). Building the map is exactly the walk that must go through `mexpru.slot_atom` or
  it will attach the `)` to the wrong node.
- **both brackets select the same CELL** going the other way.
- digraph relations (`\ne` = `\not` then `=`) are two atoms for one node — but this is mexpr's
  business and is already handled there.

### Selection

**Not every mexpr selection is an AST node.** A selection of `b +`, or a span crossing a bracket
boundary, has no meaning. Such selections should ERROR and point at the error rather than being
silently widened.

**A transform's target is not a single node.** Verbatim:

> aah, depends on target it can be more, it's mostly, set of nodes, childs and parents, and operation, and that on the ast node not on the mexpr node, so the ast holds syntax, not the mexpr, the mexpr only makes sure the brackets are closed nicely and some other things

So: **the AST holds the syntax; mexpr only guarantees the brackets close.** A transform target is a
set of AST nodes, possibly across levels, plus an operation.

Given ids are the real names (section 10), a selection is therefore **a set of integers**. Note that
flattening makes the common case a sub-multiset of one node's children — selecting `b + c` inside
`ADD(a,b,c)` picks children, not a node — and that is what term-dragging mostly is, so
`transforms.lua` should take that shape from the start.

### Patching the mexpr

Two ways to "fix it to match the copy-ast":

- **hand-patch the mexpr** to mirror what the transform did — fast, but the two representations are
  then maintained by two separate pieces of code, and section 1's "structurally unable to drift
  apart" becomes a property that must be re-proved per transform.
- **regenerate the changed subtree** through `mexpr.lua` (ast -> mexpr) and splice it in — untouched
  regions keep their original mexpr nodes and the user's layout; the changed region is correct by
  construction because only one piece of code ever builds mexpr from AST. Every transform becomes
  displayable with no per-transform layout code.

Recommended: the second.

**Cost: section 8b stops being harmless.** `mexpr.lua`'s four `vc.mexpr_bracket()` calls use the
signature the C++ split into `mexpr_bracket_left`/`_right`. Today that is dead-demo-only. On this
path, ast -> mexpr runs on every step that touches a bracket, so those four calls are on the
critical path.

### The justification

```
justification = (transform, set of source-cell ids, rule set used)
```

All three are stable forever because the source cell is immutable: ids cannot be reassigned, and the
rules were RECORDED rather than looked up. A step checked today stays checked even if the user turns
commutativity off tomorrow — which is required, because section 1 guarantees descendants can never
be invalidated.

"Implicit" therefore stops meaning "no record" and starts meaning "the tool filled the record in for
you". The user's choice between explicit and implicit is about typing effort, never about what is on
the record.

A rule's identity should be allowed to be **external** — see section 14.

### Namespace lifetime

Verbatim, 2026-09-06:

> The idea is that a formula will have a namespace sorounding it, namespace that it will take further to the next transformation in part (a defined f: f(x) = x^2 will be remembered between steps, but the i in sum[i=0->n]{k+i} will be forgoten if the sum dissapears between transformations)

and, on why cleanup is wanted at all:

> it needs it to not get cramped up, so old sums or integrals or whatever should be forgoten down the line so to not take ridiculous ammounts of space, but that is a cleanup in-between ast trees

**One invariant this imposes:** duplicating a subtree that contains a binder must **freshen the
binder's id**. Splitting `\sum_i (k+i)` into two sums that both keep id `i` gives two binders
claiming one variable, and `ast.same_var` would conflate them. Free variables must be KEPT (that is
the point of carrying the namespace forward — `f` stays `f`); bound ones must be FRESHENED. Same
copy, opposite treatment.

**What is actually collectible is smaller than it looks.** Cells are immutable and a derived cell
keeps its parent, so an old tree is still live — that is what makes descendants un-invalidatable. If
a `\sum` existed in cell N and is gone in cell N+1, cell N still holds it. Reachability must
therefore be rooted at EVERY retained cell, not at the latest tree, and the only genuinely
collectible ids are scratch minted inside a step that never became a cell.

The cheap way to get the rest: **a namespace per cell**. Dropping a cell drops its namespace, and
Lua's own GC reclaims whatever only that cell referenced; shared free variables survive because
`ast.copy`'s `keep_vars` path inserts the SAME `VAR` object into the new namespace
(`scripts/ast.lua:83`). No reachability pass, no manual sweep, no risk of freeing something a parent
still points at.

**Open:** are cells ever PRUNED — a superseded branch of the derivation dropped along with
everything only it referenced? That is what would actually reclaim old integrals, and it costs the
proof of anything downstream. Undecided. If cells are never pruned, space grows with the derivation
and that is the honest price of immutability.

---

## 13. The trust boundary

The step mechanism of section 12 is *transform-applied*: the user picks a move, the code computes
the result. Verbatim, 2026-09-06:

> that's the idea, the user will not be able to f-up, that's the whole point, and in that way the user will be able to do algebric manipulations without reaching a wrong result, well at least not via those "checked" transformations

That is soundness by construction, and there is nothing to verify afterwards — the justification is
the transform plus its arguments. It also means **every soundness bug in the system lives in
`transforms.lua`**. That file is the trusted kernel: nothing else can produce a wrong result, and
anything wrong in it is invisible, because the whole promise is that the output needs no checking.

Two consequences, both the standard LCF-style answer:

**Keep the kernel small.** A few primitive transforms, audited hard; compound moves ("collect like
terms") as scripts over primitives, not new primitives. A wrong script then fails instead of lying.

**Prefer rules-as-axioms over rules-as-code.** A morphism decomposed as statement + orientation +
policy (section 9) adds NO code: there is one kernel transform, "rewrite by a stated equation",
parameterized by which equation. The kernel does not grow when the rule set grows, and an unsound
rule is visibly an unsound AXIOM the user wrote rather than a silent bug in a rewrite function.

**Where the user overrode this**, verbatim, 2026-09-06:

> yeah, we will trust the user when it writes code, but not when it does math, trust me I know, I will be the user

Accepted, and correct for a single-user tool. The guarantee is therefore scoped: *no wrong result
via a checked transform*. A rule added as Lua code sits outside it. Note that Lean export (section
14) turns this from a scoping caveat into a non-issue, because Lean becomes the recheck — which is
the same architecture Lean itself uses internally, where tactics are arbitrary user code whose
output is validated by a small kernel.

---

## 14. Lean — the interchange language of the checked domain

Verbatim, 2026-09-06:

> I was thinking making lean the latex of part 2

and:

> I mean Lean would be a source of trust for it a sort of manual mode for Lean and/or a sort of displayer for some of lean's proofs (this last one is a huge maybe)

**Decision: yes, Lean is the target.** Provisional like everything here, but it is now a design
constraint rather than a someday-maybe, and it revises section 7's "do not design for Lean now".

### Where the LaTeX analogy holds and where it breaks

LaTeX works for phase 1 because BOTH directions exist — `mformula_latex.lua` reads and writes, which
is what makes "copy out, edit freely, paste back" a loop.

For Lean, writing is easy and reading is not. A Lean reader is a Lean **elaborator** — implicit
arguments, typeclass resolution, unification, coercions, notation scopes. That is not a side
project; it is the hard part of Lean. Section 2's own argument against routing mexpr through LaTeX
("that means writing a SECOND parser — the expensive half") applies here with much more force.

So the round-trip shape does not transfer, but the value does, split in two:

- **Export: derivations.** The step chain — one parent, one transformation, a justification — is a
  Lean `calc` block essentially unchanged. Cheap, and section 7 already grades it level one.
- **Import: statements, NOT proofs.** You do not need mathlib's proofs; you need its true
  statements as roots. Importing a statement is far cheaper than importing a proof and is where the
  value is. No elaborator required — statements can come through Lean's own printing /
  metaprogramming side rather than being parsed here.

"Displayer for Lean proofs" splits by structure: a `calc` block is shallow and regular and
displaying one is plausible; an arbitrary tactic proof only has meaning after elaboration, so that
would mean running Lean and reading its internal state. The user's own "huge maybe" is calibrated
correctly.

The genuine external value is the **manual mode** framing: Lean is awkward to drive by hand for
ordinary algebra, and a WYSIWYG term-dragger that emits a checked `calc` block fills a real gap.

### What this session already fixed in Lean's favour

Section 7 lists *"Notation-as-identity cuts against Lean, where notation is a display layer over one
constant"* as a genuine mismatch. **That objection has dissolved.** With id-as-the-real-name,
declaration-fixes-the-form, and `a` vs `a_n` being object versus application (section 10), there is
now exactly one constant per name with a display convention attached to its declaration — which IS
Lean's model.

### The typing judgement is NOT a mismatch

An earlier reading of section 6b suggested one: if `x \in R` were a PROPOSITION (provable,
refutable, usable as a hypothesis) it would have no Lean counterpart, because `x : Real` is a
judgement checked before propositions exist. That reading is wrong for this system. Verbatim,
2026-09-06:

> I won't actually hold it as an axiom like that, that would be wasteful, code will remember that x \in R by remembering that is has type R, same as lean's x : Real, or more precisely, when exporting x, x must be exported as a x : Real lean expression, whatebver that is, I don't know lean very much, so the same + contains the types backed in.

So `\in` is DISPLAY for a slot the code holds; the slot is the same one Lean holds. Export writes
`x : Real` and nothing is lost. **This also revises section 6b** — see section 16.

### What remains as real export friction: coercion

The one genuine mismatch, and it does not depend on section 6b at all. `N < Z < Q < R < C` with a
join is a SUBSET relation; Lean has no subtyping. `x + n` with `x : Real, n : Nat` requires an
inserted cast plus cast-pushing lemmas to normalize. Every place this system silently widens, the
exporter must decide where the cast goes.

Cheapest dodge, probably right for algebraic manipulation: **export everything at the join type.**
If the derivation lives in `R`, declare every variable `: Real` in the header and emit no casts at
all. The information that `n` was a natural is lost, which costs nothing for `ring`-shaped goals.

More generally: the type layer is **discarded at the boundary**, not translated. This system's type
checker catches the user's mistakes inside the editor; Lean re-derives its own typing from the
ascriptions. The same work done twice, independently, which is fine and arguably desirable.

### Export shape

A header, then the claim, then the steps:

```
variable (a b : Real)          -- free variables at their types
                               -- imported lemma names as needed
theorem step_17 : a^2 + 2*a*b + b^2 - 2*b*a = a^2 + b^2 :=
  calc ...                     -- one line per cell, each carrying its justification
```

For pure algebraic manipulation the header is often just the `variable` line — no definitions, no
imports, because `a` and `b` are arbitrary reals and the whole thing is a `ring` identity. That is
the smallest useful export and it is genuinely small.

### Name mangling is required

Display names need not be unique (section 10); **Lean identifiers must be.** So export needs a
mangling pass: id -> a fresh valid Lean name (`c`, `c_1`, `c_2`), with the mapping kept so results
can be read back against the on-screen display. This is the first place where "the id is the real
name and the glyph is decoration" has to be made literally true in output.

### External rule identity

Add now, cheap; retrofit later, expensive — same category as section 7's existing two items.

A rule's identity should be allowed to be **external**: `mathlib:mul_comm`, not only `root #17`.
mathlib is Lean's mathematics library and its theorems are referred to by global names — `mul_comm`
states `a * b = b * a`; `add_assoc`, `sub_eq_add_neg`, `pow_succ` are others in the same style.

Why it belongs in the identity field:

- **provenance** — "this step used commutativity" reads very differently depending on whether
  commutativity was ASSUMED by the user or PROVED in mathlib. Same rule, different trust. A bare
  `root #17` erases the distinction.
- **export** — a rule carrying `mul_comm` lets the exporter emit `mul_comm`; a local id forces it to
  re-prove or emit `sorry`.
- **agreement across documents** — two files importing the same lemma should agree it is the same
  rule, which local ids can never express, being namespace-relative by construction (the same reason
  `from_string` refuses to merge namespaces).

One optional string on a structure already being built. Nothing depends on it now; import and export
both depend on it later.

### What still blocks all of it

**No propositions, no `\forall`, no implication.** Cannot state `\forall x y, x*y = y*x`, therefore
cannot import a single mathlib lemma, therefore cannot emit a `calc` whose steps have hypotheses.
The node itself is easy — it is a binder, and the bigop already establishes that machinery.

The architectural question is the one section 7 was pointing at: **is a proposition a separate sort
from a term?** `a = b` as a CLAIM and `a = b` as an equation being dragged across are not the same
object even though they draw identically. Lean answers with `Prop` as its own universe. Section 6b's
"types are sets" currently has a Prop-shaped hole — a proposition is not an element of a set. Open:
whether propositions get their own sort alongside the set-types, or truth values become a set like
any other (expressible, but pushes toward a Boolean-valued model and away from Lean).

*(Standard caveat, as in section 7: `mul_comm` and the cast lemmas are stable, long-lived mathlib
names, but Lean and mathlib move quickly and this was written against a knowledge cutoff. Verify
anything more specific before relying on it.)*

---

## 15. Defects found in `ast.lua` while designing the above

**`ast.from_string` could not read any tree of more than one node** - found and FIXED 2026-09-10,
while adding SUM/PROD/INT; older than them and unrelated to them.

`ast.new()` allocated AND registered an id before the serialized id was applied, so reading a node
with id *n* pushed `last_id` to *n+1*, the next node allocated *n+1*, and applying its own serialized
id *n+1* found it already taken - `"ID n+1 is already taken in namespace"`. Since `to_string` writes
consecutive ids for a real tree, every tree it produced failed to read back.
`(+, (N, 1, 1, 1:1), (N, 2, 1, 1:2):3)` was the shortest reproduction.

The fix was not the collision check but the shape behind it: **`ast.new(ns, type, id)` takes the id
as a parameter**, so it is decided before anything is registered. The old correction-afterwards also
left a phantom entry - the node stayed in `by_id` under the id it was allocated first, so a
successfully-read node was registered twice, under two ids, one of which nothing would ever look up.
Both faults had the same cause and both are gone.

**What this says about the rest of the file:** the serializer and the deserializer had evidently
never been round-tripped against each other, in a file whose stated job is to be the base that
"serialization, deserialization and the transforms are all written against". `test_bigop_nodes.lua`
now carries the first round-trip assertion ast.lua has ever had. It exercises one node type; the
others are still unguarded.



Not fixed — the user's position, verbatim, 2026-09-06: *"we will fix them problems as they arise,
ast is kinda a stub for now"*. Recorded so they are found rather than rediscovered.

1. **`ast.copy` produces nodes with no `id`.** `scripts/ast.lua:77` builds `ret = { type =
   node.type }` and line 78 registers it in `new_ns` under `node.id`, but `ret.id` is never
   assigned. So `ns.by_id[n]` points at a node whose own `.id` is `nil`. Downstream: `to_string`
   writes `:nil`, and a copy-of-a-copy fails the `type(node[i]) == "table" and node[i].id` guard on
   line 80, so children get copied BY REFERENCE into the new namespace instead of duplicated.
   This one arises at the FIRST derived cell, since section 1 names `ast.copy` as the primitive for
   making one, and "the id is the real name" makes a node without an id meaningless.
2. **`keep_vars = false` is an unimplemented stub** — `scripts/ast.lua:84-88` raises `error("TODO: I
   didn't need it until now, but I must find a way to create the new vars inside the new namespace,
   or figure out a different solution like to specify what are the new vars in the new
   namespace")`. Binder freshening (section 12) is exactly that path.
3. **A single `keep_vars` boolean cannot say "keep free, freshen bound"** — it is one flag for the
   whole tree, so the correct behaviour for duplicating a binder is unreachable even once the stub
   is filled. It probably wants a per-variable predicate or an explicit set of ids to freshen; the
   scope chain already knows which are which.
4. **`ast.from_string` looks unable to round-trip at all, and nothing tests it.**
   `scripts/ast.lua:431-447`: `ast.new` assigns an auto id from `ns.last_id` and registers the node
   in `ns.by_id`, and only THEN does the id-override run, checking `if ns.by_id[node_id] then
   error("ID ... is already taken")`. On a fresh namespace the parse order reproduces the original
   creation order, so the stored id and the auto id coincide and the first leaf collides with
   ITSELF. Even when it does not, the auto-id entry is never removed, leaving a stale alias that can
   trigger a spurious "already taken" later. **Traced, not run** — `from_string` has no caller
   outside `ast.lua` and no test covers it, which is exactly the "no alarm pointed at it" shape
   CLAUDE.md warns about. A `tests/lua/test_ast_roundtrip.lua` pinning `to_string -> from_string ->
   to_string` as identity would give it somewhere to fire; it is the natural companion to the
   `ast -> mexpr -> ast` oracle of section 8b.

---

## 16. What part two revises in sections 1-8

| section | was | now |
|---|---|---|
| 3 | mexpr node carried only on failure | the ast<->mexpr **mapping** is a first-class output of `parse`, needed for selection and patching (12) |
| 3 | bracket pair -> `new_cell(inner)` | `CELL` only for parens NOT implied by precedence (11) |
| 4.4 | head's function-ness "fixed by the solver" | fixed by the DECLARATION; the solver never decides tree shape, and unknown-at-parse is an error (11) |
| 5 | `a_n -> CALL(a-sub, n)`, notation is part of the NAME | `a_n -> CALL(a, n)`; one id, notation fixed by the DECLARATION; `a` vs `a_n` is object vs application (10) |
| 5 | subscripts need no new node — because they are a different name | still no new node — because they are an application (10) |
| 6 (a) | open: can an index range over a finite set of labels? | **answered** — yes, the subscript is application and `{g,e}` is a type (10) |
| 6 (b) | open: how is a multi-letter subscript written? | narrowed to the general multi-letter-name problem, same as `sin` / `log` / `det` (10) |
| 6b | a typing rule is a ROOT the user writes in a define box | **provisionally reversed** — `+` carries its types; see the open question below |
| 6b | open: bootstrapping circularity | **closes** if typing is built in — base rules are primitive (14) |
| 6b | the logic layer is not deferrable, because typing rules are formulas | half that argument dissolves; propositions are still needed for hypotheses, theorems and any Lean import (14) |
| 7 | "do not design for Lean now" | Lean is the target for the checked domain (14) |
| 7 | notation-as-identity cuts against Lean | **dissolved** — one constant per name, display on the declaration (14) |
| 8b | `mexpr_bracket()` signature rot is harmless today | on the critical path once mexpr is patched by regeneration (12) |

**The 6b question needs answering before anything is built on it.** Section 6b states *"A typing
rule is therefore a root: an axiom the user writes in a definition block, not something the program
knows a priori."* The 2026-09-06 statement *"the same + contains the types backed in"* is the
opposite: `+` knows its own typing, the program does know it a priori, and there is no user-written
rule to be a root. Read here as SCOPING ("at least for now" — built-in typing for the algebraic
core, user-written rules possibly later) rather than reversal, but that reading is not confirmed.

---

## 17. Open questions carried by part two

1. **Which rules are automatic by default?** Verbatim: *"we are yet to decide if the user would want
   to identify (a+b)+c as the same things as a+b+c"*. Suggested but not decided: strip-CELL and
   flatten on, commutativity off (9).
2. **Is alpha-equivalence automatic or opt-in?** (9)
3. **Are cells ever pruned?** The only thing that would actually reclaim space, at the cost of the
   proof of anything downstream (12).
   *Partly answered for the newest cell.* Undo needs no machinery of its own: it is dropping the
   last cell. This was written down as a design target in 2025, in the archived copy of
   `experiment_copac/main.lua` (removed with the earlier rewrites in commit `1e201f7`), verbatim: *"obs: There needs not be any complicated ctrl+z because the steps are allways above,
   so a ctrl+z is practically: remove the current eq-state and goto prev one"* - and under the
   immutable-cell DAG of section 1 it is no longer a target but a RESULT: a cell with no children
   has nothing depending on it, so dropping it invalidates nothing. What stays open is pruning a
   cell that DOES have descendants.
4. **Typing rules: built in, or user-written statements?** The section 6b conflict above (16).
5. **Are propositions a separate sort from terms?** Section 6b's "types are sets" has a Prop-shaped
   hole (14).
6. **Is typed-and-checked ever a mode?** Every step described here is transform-applied and correct
   by construction. Letting the user TYPE the next line and having the tool verify it follows is a
   strictly harder job — deciding equality between two arbitrary expressions rather than finding
   like terms within one. Not currently in scope.
7. **`EXP` is partial** (section 6b, unchanged): emit a constraint, widen to `C`, or refuse.

---

## 17b. The acceptance corpus — what "we will see by example" means

Recovered 2026-09-06 from the second rewrite's `main.cpp`, where it sat under the heading
`/* All of those must work: */`. That code was removed in commit `1e201f7`, so the list is
reproduced here in full and nothing needs retrieving. It predates every design decision in this
document by two rewrites, and it is the concrete target the whole of part two is abstract about:

```
(a+b)^2 = a^2+2ab+b^2
(a-b)^2 = a^2-2ab+b^2
a^2-b^2 = (a+b)(a-b)
2(a^2+b^2) = (a+b)^2 + (a-b)^2
(a+b)^3 = a^3+3a^2b+3ab^2+b^3
(a-b)^3 = a^3-3a^2b+3ab^2-b^3
```

**Use these as the worked examples.** Every rule in sections 9-13 was written with no formula to
argue back; these seven are the argument. Notably they need nothing exotic — commutativity,
coefficient collection and distribution, which is exactly the automatic rule set of section 9 and
nothing beyond it. If the design cannot walk a user through `(a+b)^2` step by step, it is wrong
somewhere, and that is a cheaper way to find out than building all of it first.

They are also the natural first tests. Per `CLAUDE.md`, a test records an ASSUMPTION rather than an
output - so what each of these pins is not "the answer is `a^2+2ab+b^2`" but "this manipulation is
expressible as a sequence of checked steps, with these rules active".

That same file also carried a pointer to a wider corpus, verbatim:

> /* TODO: sa mearga toate manipularile de aici: https://www.youtube.com/@tesan3377/playlists */

---

## 18. Inter-workings — how the pieces connect

The sections above each settle one thing. This one is about how they touch, because most of the
real constraints live between them rather than inside them.

### The pipeline

```
  TEXT EDITOR                     free glyphs, no meaning, input methods apply   (phase 1, exists)
       |
       |  PROMOTION - the one-way door, and the only checkpoint          (1)
       v
  parse(mexpr, defs)                                                     (3, 11)
       |
       |  ONE walk produces FOUR things, none of which can drift apart:
       +--> ast              the meaning tree; holds the syntax           (4, 10, 11)
       +--> types            synthesized bottom-up during the same walk   (6b, 11)
       +--> linked vars      which names it depends on                    (6b)
       +--> mapping          ast node <-> one or more mexpr nodes         (12)
       |
       v
  CELL  = { mexpr, ast, types, mapping, context }   immutable, forever   (1)
       |
       |  user selects mexpr -> mapping -> set of ast ids                 (12)
       |  transform from transforms.lua applies to the ast                (13)
       |  changed subtree regenerated through mexpr.lua and spliced       (12, 8b)
       v
  NEW CELL + justification = (transform, source ids, rule set)            (12)
       |
       |  the chain of cells IS the derivation DAG                        (1)
       v
  EXPORT: variables header + theorem + calc block                         (14)
```

### Who depends on whom

- **Equality (9) serves transforms (13), not the user.** Even with no typed-and-checked mode, a
  transform must FIND `2ab` and `-2ba` as like terms before it can offer itself. So the normalizers
  are on the critical path of the very first interesting transform, not a later nicety.
- **The type layer (6b, 11) gates equality (9).** Morphisms are registered per type and inherit
  DOWN the subtype lattice (a rule stated for all of `R` applies to `N`, because `N` is a subset and
  the rule is universally quantified over it — this is what makes MUL commutative for reals and not
  for matrices). So a node's type must be known before its rule set can be looked up, which is why
  types are computed during the parse and cached on the immutable cell.
- **Parsing (11) gates the type layer, and the type layer gates parsing.** Not a circularity: leaf
  types come from DECLARATIONS (declaration-before-use is mandatory), compound types are synthesized
  as the walk unwinds, and the parse decision "CALL or MUL or absurdity" is the same licensing
  lookup the type checker makes. One mechanism, consulted at two moments.
- **Immutability (1) is what makes justifications (12) permanent.** A justification names source ids
  and a rule set. Both stay valid only because the parent cell can never change and ids are never
  reused. This is also why the `a = a()`-until-`a[]` retraction sketch had to be dropped (10) — it
  would have invalidated a cell from downstream.
- **The mapping (12) is what makes the error path (3) and selection (12) the same machinery.** A
  parse failure highlights an mexpr node; a selection resolves an mexpr node to ast ids. Both are
  the mapping, read in opposite directions.
- **`mexpru.slot_atom` (8) constrains every walk added by any of the above.** The bridge walk, the
  mapping walk, the selection walk. Seven live bugs came from ignoring it; nothing about phase 2
  makes that blind spot less likely.
- **Lean (14) consumes the justification field (12) and the external rule identity (14), and is
  blocked by the missing logic layer (6b, 7).** It touches nothing else — the type layer is
  discarded at the boundary rather than translated.

### Build order this implies

The dependencies above are not symmetric, and they suggest one order:

1. **The logic layer** — propositions, implication, quantifiers. Blocks Lean entirely, and blocks
   typing rules if open question 4 settles that way. Cheapest thing that unblocks the most.
2. **`mexpr_ast.lua`'s walk**, producing all four outputs at once. Everything downstream reads them.
3. **`canon_key`** — the comparison key, with strip-CELL and flatten only. Sorting can come later;
   the key's shape cannot.
4. **Two or three primitive transforms** plus the justification record, to prove the step loop end
   to end on one real formula.
5. **Lean export** of that one derivation. It is a serialiser once 1-4 exist, and it turns the
   trust boundary (13) from a caveat into a rechecked guarantee.

`transforms.lua`'s remaining cases are deliberately NOT on this list — CLAUDE.md flags them as
exploratory design work, not a gap to fill.

---

## 18c. The expression cascade, as built (2026-09-10)

Cases 1 to 4 of section 7's table are implemented in `scripts/mexpr_ast.lua`, plus multiplication,
which that table never listed because juxtaposition has no glyph to hang a case on. Four layers,
one per precedence level, each handed a **unit list** rather than a container:

```
build_relation   splits on  =  <  >  \le  \ge      case 4
  build_sum      splits on top-level  +  -         case 2
    build_product  segments into factors           multiplication
      read_factor    one name-use, numeral, or bracket group    cases 1 and 3
```

The unit list is what makes it one parser rather than four. A relation's side, a call's argument
and a superscript's row are all unit lists, so all three go through the same layers. Before this
an argument had a separate miniature parser that knew only "numeral" and "single letter", which is
why `a_{1}=1` failed on its right-hand side while `f(1)` had worked for days: two parsers for one
grammar, drifting.

### How far a factor reaches is the declarations' answer

`a_{1}(x)` is the call `a_{1}(x)` when something is declared with that shape, and the product
`a_{1} \cdot (x)` when `a_{1}` is declared alone. The glyphs are identical; only the declaration
separates them. So `read_factor` offers **every extent** from its start to the end of the row to
the name parser, and the extents that RESOLVE are the readings the row admits.

That makes it the same rule as `resolve_use`'s, one level up: **exactly one or it is an error**. Two
extents that both resolve are a genuine ambiguity in the formula, not a preference to settle by
taking the longer one.

One consequence had to be built deliberately rather than falling out: an extent that resolves to
*several* declarations is an ambiguity, while an extent that resolves to *none* means "the name
ends somewhere else, read on". Both are "resolution failed" to a caller that only sees nil, so
`resolve_use` returns the match COUNT as a third value and `read_factor` reports the ambiguity
instead of walking past it into "no declaration matches" - which is the opposite of what happened.

### Why juxtaposition can mean multiplication at all

Because a multi-character name has two other spellings, and both were built first: quoted
(`'max lim'`, section 6) and the 1-tall vert for `sin` (section 10). With those in place `bb` has no
reading as one name, so a run of single letters is a product with nothing to decide. Without them
this layer would be guessing, and no amount of care in it would help.

### An unresolved letter is a free variable, wherever it is written

This was contextual for one day - ordinary in an argument, an error at the top of a row - on the
reasoning that `f(x)` says nothing about `x` while a row consisting of `x` names something that
does not exist. Author, 2026-09-10: *"yes, allow free variables at the top of a row too"*. The flag
that carried the distinction (`ctx.free_ok`) is gone rather than pinned, since a flag with one value
reads as a live rule and is not one.

**What the old rule was standing in for is the binders**, and it did it badly: it refused a bound
variable and a mistyped one alike, because nothing here can yet tell them apart. See "Free variables
are contextual, and binders are what will bind them" below for what has to exist first.

**The cost, jointly with the juxtaposition rule above:** a call to a function nobody declared is no
longer an error. `F(0)` with nothing declared reads as `MUL(REF(F), NUM(0))` - flat, since a group
around a leaf carries no grouping, so it is the same tree as `F 0`. Nothing downstream can tell the
difference; only the declarations can.

Accepted rather than open, author 2026-09-10: *"I agree with the implication that F becomes
multiplication, it is what it is, maybe we should deny such a syntax, but not for now"*. If it is
denied later, the narrowest form is "a letter immediately followed by an open bracket, with no
declaration of that letter at all" - which is distinct from `a` being declared as a plain variable,
where the product is genuinely what was written. `test_ast_view.lua` asserts the fork so it stays
visible either way.

**A free letter in front of a bracket is multiplication, once resolution has failed.** Author,
2026-09-10: *"a free letter in front of a bracket should mean multiplication after the resolution
failed, so say a was not found or found to be an independent variable then a( is a.( a
multiplication begining"*. So `g(x)` with `g` undeclared is `MUL(REF(g), CELL(REF(x)))`.

The safety is in the ordering, not in the rule: every extent has already been offered to the name
parser by the time this is reached, so a declared `g(x)` is still a CALL and only an unresolved one
becomes a product. And the product is the reading that says something true - a letter with no
declaration is an independent variable, and an independent variable is not applicable to anything.

This reversed the opposite call made a few hours earlier the same day, which made an unresolved
`a(...)` an error on the grounds that a missing declaration was likelier than a product. Recorded
because the reversed version was plausible, and `test_ast_view.lua` carries the same note where its
assertion flipped.

### The sign is a property of the product

Author, 2026-09-10: *"so -x transforms into (MUL, NUM(-1), REF(x))... +/- is a property of the next
NUM or NUM in MUL"*. A negative term folds into its leading numeral when it has one and grows a
`NUM(-1)` factor when it does not, so `-2x` is `MUL(NUM(-2), REF(x))` and `-x` is
`MUL(NUM(-1), REF(x))`. A sign is a separator only with a term behind it; leading, it belongs to
the term in front of it, and a run of them folds.

### CELL — the rule of 2026-09-06, restored

The bridge emitted a CELL for every bracket group for one day. That contradicted a rule written four
days before this parser existed ("CELL — when parentheses survive", section 11), and the author
caught it on the tree: *"the cell should be implied here, it is a jump from mul to add, it doesn't
need a cell"*.

The rule, unchanged: **a CELL is emitted exactly when the parentheses are NOT implied by
precedence.** What implementing it turned out to need:

- **"Required" has one meaning here**, because a bracket group is only ever read in factor position
  (`read_factor` is the only reader of brackets). So required = an ADD inside a product of several
  factors. Everything else this parser builds binds at least as tightly as a product.
- **The decision is made last, in `build_product`**, not where the brackets are read - because
  "required" is a question about the product the factor ended up in, and that is not known until
  the factors are all collected. The sign counts as a factor for this: `-(a+b)` is
  `MUL(NUM(-1), ADD(...))` and those brackets are load-bearing exactly as in `c(a+b)`.
- **A power consumes them.** `(a+b)^2` needs its brackets to mean what it says, so they are absorbed
  into `POW(ADD(...), NUM(2))` and never become a CELL.
- **A group around a leaf promotes.** `(a)+b` is `ADD(a, b)` - the section-11 note calls this "lossy
  in the letter, not in the spirit", and it is: there is nothing inside to arrange.

Worked, matching section 11's own example: `(a+b)c` is `MUL(ADD(a,b), c)`, `(a+b)+c` is
`ADD(CELL(ADD(a,b)), c)`, `(ab)c` is `MUL(CELL(MUL(a,b)), c)`.

### SUM, PROD, INT — the first nodes that declare a name

Added to `ast.lua` 2026-09-10. One shape for all three:

```
(S, var, from, to, body)      \sum_{var=from}^{to} body
(P, var, from, to, body)      \prod_{var=from}^{to} body
(I, var, from, to, body)      \int_{from}^{to} body d(var)
```

> **REVISED below, for SUM/PROD only.** "Bigop scoping" (after "Free variables are contextual..."
> below) replaces `var, from, to` with a constraint list for `SUM`/`PROD` (and the not-yet-added
> `UNION`/`INTERSECT`) - `from`/`to` turned out to be one relation each (`=` and a bare bound), not
> general enough for `i<n`, `i \in S`, or more than one variable. `INT` is explicitly EXCLUDED from
> that change and keeps needing its own shape - its variable comes from a trailing differential, not
> from a constraint at all, so nothing about its sub/sup was ever "a relation" to generalize.

**They declare rather than consume.** Author: *"int declares a variable name, it offers the insides
a new reference, itself, the idea is that we will have our free variables that buble up outside of
the root, while some vars get catched by bigops"*; and *"bigop ops need to create a var, probably
reuse new_var, the idea is that in this way we will achieve our binding"*. So the constructor takes
a NAME, not a variable: it calls `ast.new_var` itself, and there is no way to build one whose slot 1
belongs to somebody else.

**The body is built first, and the binding is a CATCH.** `new_sum(ns, "i", from, to, body)` walks
the body once and repoints every free mention of `i` at the variable it just made. After that the
binding is ordinary structure - a VREF carrying slot 1's id - so nothing walking the body needs to
know it is inside a binder, and there is no second scope mechanism to keep in step.

**The integral is what forces that order.** `\int_0^1 x dx` names its variable AFTER the body: the
`dx` at the end is the declaration. Any design that handed the variable down to a body-builder could
not read an integral at all, because the name is not known yet when the body starts. Catching
afterwards serves all three operators and asks the caller for nothing - build the body with `x`
free, then say who binds it.

**Free means not already claimed by a nearer binder.** A nested operator declaring the same name
shadows the outer one, so its body is skipped - but not its BOUNDS, which are written outside its
own scope. In `\sum_{i=1}^{n}` the `1` and the `n` are not in `i`'s scope. That is the one part of
catching that can be got wrong silently (the tree stays well formed and means something else), so
`test_bigop_nodes.lua` guards it directly.

**Free variables are then one walk.** The free variables of an expression are what its children
returned, minus each binder's own `var`. A name no binder claims keeps travelling outward past the
root, where it is a free variable of the whole formula - which is what the "Free variables are
contextual" note above was waiting for.

**One shape including the integral**, whose variable is written as `dx` after the body rather than
under the sign. Where the name is WRITTEN is the input method's problem; what it MEANS is identical
for all three, and a separate tuple for the integral would make every consumer handle it twice.

**Not parsed yet.** `mexpr_ast` has no bigop case. The open question is how far a big operator's
body reaches along a row - `\sum_{i=1}^{n} i + 1` is either `SUM(...) + 1` or `SUM(..., i+1)`, and
that is a notation decision, not something the grammar can settle on its own.

One thing the parser will have to watch when it lands: `mexpr_ast`'s `var_ref` keeps ONE `ast.new_var`
per name per formula, so `x` inside a binder and `x` outside it are currently the same node. Catching
only walks the body, so the outer mention is untouched and the two end up correctly distinct - but
that is a property of where the walk goes, not of the cache, and a future change to either could
break it without a word.

### `\ne` — the parser was the last place still reading it as two things

No font in this project draws `\ne`, because TeX has none either: it sets the zero-advance negation
slash and prints `=` on top, and `mformula_latex`'s `MACRO_EXPANSIONS` expands the macro that way on
the way in. So the row holds TWO atoms where the reader sees one symbol.

**The editor settled this in 2026-09-06 and the parser had not caught up.** `delete_overprint_unit`
(`mformula_new.lua`) makes the pair delete as ONE symbol, added after the live report *"you can
write != to get negation, but deleting it leaves the / behind"* - and `test_digraphs.lua` had
asserted the old two-atom behaviour as a feature, which is this repo's standing example of a test
defending a defect. Author, restating it here 2026-09-10: *"ne is not independently deletable and
neither should it be"*. So the pair is one symbol everywhere the app touches atoms one at a time,
and `mexpr_ast` was simply the last such place.

**Why it mattered more than an ordinary parse failure.** Read one at a time, `\not` falls out as an
unparsable factor and `=` stays behind as an ordinary equals - so `a \ne b` builds `a = b`, the
exact opposite of what was written, in a tree that looks entirely well formed.

**No new glyph.** Author, 2026-09-10: *"I don't really want a new glyph"*. `char.lua` gains no row
and the document model is untouched; `relation_at()` reports that the relation at this position is
two units wide, and reuses the same zero-advance test (`char.adv_by_desc[desc] == 0`) that
`is_overprint` uses, so the two cannot drift as the catalog changes.

**Keyed on both halves, not on "an overprint followed by a relation".** `\!` is zero-advance too -
it is TeX's negative thin space - and negates nothing, so `a \! = b` must not become a NEQ. Only a
listed pair builds; an unlisted one is refused with its reason.

**Only `=` is paired.** Author: *"if I remember corectly only = has that stupid problem"*. `\notin`
and friends are refused rather than mapped, because `ast.lua` has `INEQ_NEQ` and no other negated
node - inventing a shape here would put something in the tree that no later pass can read.

### Free variables are contextual, and binders are what will bind them

Recorded 2026-09-10, author: *"free variables are yes contextual first, as in those only need to fit
the function domain and two will be posibly linked, sum, integral, product, lim, those all will
declare variables that will bind to those names inside of them (the outer scopes of course)"*.

Two things follow, neither implemented:

1. **A free variable in an argument is constrained by the DOMAIN, not by a declaration.** `f(x)`
   requires `x` to fit `f`'s domain and nothing more, which is why an undeclared letter is ordinary
   there. The domain check is section 6's `<name> \in <set>` machinery, not this parser's.
2. **Big operators are binders.** `sum`, `integral`, `product`, `lim` each declare a variable that
   binds inside their body, shadowing the outer scope. The editor already builds them (`mexpru`'s
   bigop), so the units are there; what is missing is a scope stack in the builder, and the rule
   that a name resolves against the innermost binder first and only then against
   `content.declarations_before()`. Until that exists, a bound variable is indistinguishable from a
   free one, which is why the top of a row still refuses an undeclared letter.

### Bigop scoping — how sub/sup constraints spawn variables

Recorded 2026-09-10, in conversation, before any of it is built. Answers the "what is missing is a
scope stack" gap the previous note left open, for `\sum`/`\prod`/`\bigcup`/`\bigcap` specifically -
`\int` is excluded throughout, see below.

**`\in`/`\ni`/`\subset`/`\subseteq`/`\supset`/`\supseteq` all become real relation nodes,
general-purpose, not bigop-only.** Same shape as `EQ` - `ast.new_in`, `ast.new_ni`, `ast.new_subset`,
`ast.new_subseteq`, `ast.new_supset`, `ast.new_supseteq`, each with its own type constant and its own
entry in `type_to_symbol`/`symbol_to_type`/`build_relation`'s shared `RELATIONS` table - usable
anywhere a formula can hold a relation, not carved out as a bigop-only micro-parser the way
`mexpr_ast.parse_domain`'s membership check is. The full family, not just `\in`/`\subseteq`, per the
author catching an incomplete first pass: *"subseteq is not the only one... you should add all the
others in the list, the member_of, member_in ones, and all the includes"*. Three of the six are
exact mirrors of the other three (`a \ni b` means `b \in a`, `a \supset b` means `b \subset a`,
`a \supseteq b` means `b \subseteq a`) but each still gets its own type and constructor with operands
kept in written order, never silently swapped - the same precedent `INEQ_LESS`/`INEQ_GREATER`
already set for `<`/`>`.

**A constraint is nothing more than one of those relation nodes, kept in the tree.** Not consumed
and discarded - the bigop remembers it, for display and eventually for domain reasoning, even though
building it also has a side effect (below). One `horiz` in a sub/sup slot is one constraint; finding
a `vert` there instead (`mexpru.vert()`'s existing N-slots-stacked primitive, already user-buildable
via `new_with_vert()` - nothing new needed on the editing side) means one constraint per slot. So a
bigop's shape moves to something like `(op, {vars}, {sub constraints}, {sup constraints}, body)` - K
sub constraints, M sup constraints, N spawned variables, in place of the single `var, from, to`.

**The spawned variables are the free names in the constraints, sub minus sup.** Build every sub
constraint's ast node, harvest every free name anywhere in it (both sides, no left/right role to
assign), union across all K. Do the same for the M sup constraints. `spawned = sub-union -
sup-union`. Whatever a sup removes is not bound here at all - it falls out as an ordinary free
variable of the surrounding formula. "Free" already excludes anything in
`content.declarations_before()` or bound by an ENCLOSING bigop - author: *"so previously defined
names are not free, this is maybe important to note... this includes obviously the other BIGOPS
that are above this one"* - which is exactly the scope-stack, innermost-binder-first rule the
previous note named as missing, now made concrete by a real consumer rather than deferred again.

**Why sub-minus-sup, and not sub parsed in sequence with sup threaded through it.** The first shape
tried was simpler - collect every free name in a sub constraint, register it immediately, so a later
constraint (or the sup) sees it as already bound. It fails on exactly the case the author flagged as
the one to worry about:

```
\sum_{i=0,\ j=N}^{N} (i + (N-j))
```

`j=N`'s right side, `N`, is just as undeclared as `j` at the moment that constraint is read -
nothing has registered anything yet, so sequential threading captures `N` as a spawn candidate
regardless of the sup, before the sup is even looked at. Author: *"I want if N is not referenced by
anyone else than the sum to be a free variable... I think the sup will only remove it's newer
would-be-spawned objects from the said list"*. Only computing the sup's OWN free set independently
and subtracting it afterward catches this - `N` is free in both, so it cancels out of the sub side
and surfaces as an ordinary free variable, exactly as intended. Ordering within the sub side alone
was checked and doesn't matter: a name a later sub constraint re-mentions after an earlier one
already spawned it just lands in the same union set either way.

**`\int` is not part of any of this.** Its bounds are bare expressions, never a relation to harvest
a name out of - classically `\int_a^b f(x)\,dx` has no constraint under the sign at all. Author:
*"the integral will need to colect the names from the dx, dy, etc. term at the end of the integral,
we will need a special case for that one"*. Still fully open, deliberately not designed further
here - a separate mechanism (reading a trailing `d<name>`, possibly several for a multiple integral)
that this section's constraint machinery has nothing to say about.

**Membership/inclusion is not symmetric, and the fix has to survive connectives that don't exist
yet.** Found live testing `\sum_{i \in S}(i)`: it spawned `S` alongside `i`, since `S` is exactly as
free as `i` and there is no sup to subtract it against. `i \in S` has an element side and a set side,
and only the element side is ever eligible - `ASYMMETRIC_SPAWN_SIDE` in `mexpr_ast.lua` says which
operand per type (the mirrors point at the OTHER operand: `\ni`/`\supset`/`\supseteq` are eligible on
slot 2, the rest on slot 1). `=` and the inequalities stay symmetric on purpose - `i=j` spawning both
sides is the accepted behaviour from earlier in this section, unchanged.

The first version of this checked only the constraint's ROOT node type, reasoned to be safe because
`build_relation` cannot nest one relation inside another today. Author, catching that reasoning
before it shipped: *"I don't want the /in to be top-level only, what if we want to write a bolean
relation?"* - boolean connectives (`\land`/`\lor`/`\lnot`) do not exist yet, but `i \in S \land i \ne
j` must still only spawn `i` once they do, and a root-only check would need revisiting the day they
land. `harvest_eligible` instead walks the WHOLE constraint tree: wherever a membership/inclusion
relation turns up, at any depth, only its eligible side is descended into from there; every other
node type recurses into all of its children, which already includes a future AND/OR/NOT with zero
changes needed here - "recurse into every child" is the default for anything not in the table, not a
special case for today's node set.

On whether the eligible side must itself be a bare name: author, confirming it need not be -
*"of course the side the operator is facing must be a variable, or else in the future the type
checker will fail, but it shoulde be allowed to be composed"*. So `harvest_eligible` recurses freely
into whatever expression sits there (`i+1 \in S` harvests `i`) rather than requiring a single token;
whether the result is well-typed is the not-yet-built type checker's question (§6's "Types" gap),
not this layer's.

**What is still open after this.** How far a bigop's body reaches along the row (the note above this
one, unchanged - a notation question, not a scoping one) - `mexpr_ast.lua`'s `read_bigop` sidesteps
it for now by requiring the body to be an explicit bracket group right after the operator, refusing
rather than guessing, same discipline a chained relation already gets. The integral's
differential-reading mechanism, entirely - though see the note just below, which changes what
"entirely" means. The `vert`-stack multi-constraint path is written and reviewed but has not been
exercised live - there is no LaTeX text for it, only direct `mexpru` construction. All the rest of
this section IS implemented: the relation family, the tuple shape (a flat `(op, n_vars, n_sub, n_sup,
var1..varN, sub1..subK, sup1..supM, body)`, chosen over three nested list-nodes because it mirrors
`MAT`'s own existing `(M, m, n, a1...a[m+n])` counts-up-front idiom and needs no new node type), and
`read_bigop` for `\sum`/`\prod`/`\bigcup`/`\bigcap`. `\int` is excluded throughout, per the next note.

### The integral's differential - a real idea, not yet built

Floated in the same conversation, once the constraint mechanism above made it clear `\int` needed a
genuinely different answer rather than a missing piece of the same one. Two things ruled out first:
there is no dedicated "differential d" glyph in `char.lua` - only the ordinary lowercase letter `d`,
indistinguishable from a variable someone names `d` - though the project already has precedent for
minting a dedicated glyph for exactly this kind of confusion (`\partial`, deliberately kept separate
from `d` for partial derivatives, `char.lua`'s own "the other than d" comment). Real LaTeX has this
same ambiguity and resolves it by convention, not by grammar.

**The idea: treat `\int` as an implicit bracket that closes on `d<letter>`, not as another
constraint-list bigop.** Author: *"treat integrals like a paranthesis in some limited sense and have
the d be the end of the integral... the var name is whatever is next to the right of 'd'"*. Concretely
- scan forward from the integral's position, tracking bracket depth the same way `build_sum`/
`read_factor` already do for an ordinary bracket group, until a `d` atom immediately followed by
exactly one letter atom appears at THAT depth; that pair closes the integral, the letter is the
variable, everything scanned in between is the body. A `d` inside a nested bracket
(`\int(a+d)\,dx`) never fires early, because it sits at a deeper depth than the integral's own scan.

**This needs no change to `ast.lua`'s `INT` shape at all.** It stays `(var, from, to, body)`,
untouched - a double integral (`\int\int f\,dx\,dy`) falls out as two nested `INT` nodes from two
separate `\int` symbols, the same way nesting already works for everything else in this file. All the
work would be a new forward-scan in `mexpr_ast.lua`; nothing in the AST layer changes.

**The one residual ambiguity is accepted, not solved.** A body that ends with a genuine
juxtaposition-product against a variable actually named `d` (`\int d \cdot x`, no differential
intended) cannot be told apart from `\int \, dx` - same as TeX itself cannot. Narrow in practice,
since everyone already avoids naming a variable `d` for exactly this reason, and not worth
engineering further around.

Not implemented - deliberately sequenced after the constraint-list mechanism above rather than
alongside it, to avoid two designs in flight on the same file at once.

### Declaration identity - age, generation, and a persistent namespace

Recorded 2026-09-10, in conversation, before any of it is built. Grew out of testing F5 (a new
debug key showing `ast.to_string`'s raw serialization, alongside F4's tree view): `CALL` embeds its
declaration's serialized text directly (`ast.new_call(ctx.ns, hit.decl.text, ...)`), which section
10's own rule already rules against - *"the id is the real name... the code tells them apart by
id"* - `VAR`/`VREF` already follow that, `CALL` never did.

**The first fix considered and dropped: a parallel `ctx.decl_ids`/`ns.decl_by_id` cache**, minting a
per-parse number for each declaration alongside the existing `ns.by_id`. Correct as far as it went,
but pointless duplication once compared against the obvious alternative: mint a real `ast.lua` node
for the declaration (`ast.new(ns, ast.DECL)` or similar), the same way `VAR` already exists for a
variable, and let `CALL` hold *that* node's `.id` - resolved through the `ns.by_id` `CALL` already
needs to consult, no second table. Author, cutting straight to this: *"so what is the point of this
instead of using what is already inside ast.lua and building the ast from the definition up"*.

**Then the harder half: should that node be cached, surviving past one parse?** Author: *"maybe we
can even cache that ast such that it only is rebuilt on definitions that move, but that will happen
later I guess"*. Deferred, but the shape of it got worked out anyway, because it answers a question
"Bigop scoping" left unresolved about identity across time (there, resolved narrowly - a bigop's
OWN variables never need to survive past one parse; a document-wide declaration is a different
animal, since two SEPARATE formulas' parses both need to resolve against the SAME one).

**Age - the box's own id, fixed at birth, never changing for that box's life** (the same mechanism
`content.lua`'s formula boxes already have - `box.fml.id`, from a counter derived from what's
already in the document). Author: *"how about if an ast var got an age (the box it lives in), as
such, the namespace will hold the ids, with the names and the age"*. This is what makes identity
safe to key on WITHOUT falling into the trap "Bigop scoping"'s own text-collision worry named: delete
a box declaring `f(x)`, later create an unrelated box that also happens to say `f(x)` - same text,
but a different age, so never confusable, with no need to compare spelling at all.

**Generation - the declaration NODE's own id, which bumps every time the box's content is edited.**
Author: *"reconstructing a definition: allow a delete of a var, it gets rid of the last one and
re-creates it (look the last_id is increasing only), this way you would reconstruct the node and
when the ast is re-formed on demand it has access to exactly all the definitions it needs based on
age and also actualized"*. Never mutate a declaration node in place - tear it down and rebuild it on
every edit - and staleness detection falls out for free from `ast.new()`'s own monotonic counter,
no separate version field needed: anything holding an old generation's id can tell, by comparison
alone, that it predates the current one and needs rebuilding.

**Age and generation answer two different failure modes, together.** Age says whether a reference
is even looking at the right BOX at all (the text-collision case). Generation says whether it is
looking at a STALE EDIT of the right box (the in-place-edit case). Neither alone covers both; a
reference needs to carry both to know which kind of "no longer valid" it is looking at, if either.

**This is what turns `ns` from a per-parse throwaway into a persistent, document-wide registry.**
Today `ast.new_ns()` is fresh on every single `mexpr_ast.build()` call, and nothing needs to survive
past it - which is fine for `VAR`/`VREF`, since nothing outside one formula's own tree ever needs to
resolve one. A declaration is referenced FROM other formulas' separate parses, so it cannot live in
a namespace that dies with the parse that first created it. Age-tagging is what makes a persistent
`ns` safe to query directly rather than re-derived from a fresh walk every time: *"and it allows us
to simply ask the ns for function names"* - a lookup for box K's own visible declarations becomes a
plain filter, `age <= K's age`, no re-walking `content.declarations_before` from scratch.

**The trie gets the same treatment.** `check_declarations`'s trie (§18d) is rebuilt from scratch on
every call today, over whatever `declarations_before` already filtered to "visible from here."
Under a persistent `ns`, the trie can instead be ONE incrementally-grown structure for the whole
document - inserted once per declaration, never rebuilt - with a lookup for box K simply skipping,
mid-walk, any node whose age is too young for K, as if it were never inserted at all. Visibility
becomes a property of the walk, not of what is structurally present.

**Open, not resolved: conflict-checking (`trie_conflict`, and the backward "would this break an
already-accepted one" check) needs to become age-aware too, not just position-aware.** Two
declarations whose age-windows never overlap for any common consumer should not be flagged as
conflicting just because they sit near each other in an incrementally-built trie - today's check
runs once over a set already pre-filtered to "visible together," which a persistent, age-walked
trie no longer hands it for free. Position still has a job alongside age even once this exists -
it is what breaks the tie when two same-age-window declarations DO coexist and conflict, which age
alone cannot decide. Author, accepting the open end: *"sure"*.

None of this is implemented. `ast.lua`'s `CALL` still embeds raw text today; `ns` is still fresh per
parse; the trie is still rebuilt from scratch per lookup. This section exists so the reasoning is
not lost before any of it changes.

### What this settles from earlier sections

- **"Operations inside a subscript" (above) is answered by the cascade, not by the rollback it
  designed.** `a_{n+1}` is `CALL("a,sub,(1)", ADD(REF(n), NUM(1)))` today, exactly as the Case 1
  table predicted. The transactional-rollback machinery that section works out in detail was for
  making the DECLARATION parser accept an expression argument; a use site never needed it, because
  `parse_argument`'s use-site mode sets the group aside unparsed and emits `(k)`. The rollback
  design still stands for the declaration side, and is still unbuilt.
- **`ast.lua` has a real consumer again.** `new_add`, `new_mul`, `new_cell`, `new_exp`, `new_num`,
  `new_var`, `new_vref`, `new_call` and the relations are all reachable from a typed formula.

### Still not parsed

`\div` written inline (the fraction node itself is parsed as of 2026-09-10 - see the fraction note
under "The expression cascade" in `docs/ast_parsing.md` section 6; scoped down on purpose, author:
*"I want to ignore for now any fraction that is not made by a 'towering' fraction, so a/b, ignore
it, error on it, frac{a}{b}, it's ok, parse it"*), the `\ne` pseudo-glyph (section 7's note - it
arrives as a dress over `=` and is refused rather than read as `=`), a subscript on anything that is
not a declared name, and relation chains (`a = b = c`, which needs a shape nobody has chosen). Each
fails with its reason rather than approximating, and F4 shows the reason.

## 18d. The definition trie, and the one serialization that serves both modes

Written by the author 2026-09-10 and reviewed the same day; this section is that document with the
corrections agreed in review folded in, and it supersedes the ad-hoc description of key building in
section 10.

**For what the parser DOES, read `docs/ast_parsing.md`** - that file is the reference and is kept
current with the code. This section is the decision record: the arguments, the author's own words,
and the readings that were tried and dropped. Where the two disagree, the reference is right.

### The shape of the idea

Definitions live in a **trie**, keyed by the token walk of their name pattern. The walk order is the
same whether a name is being DEFINED or USED — base, then function-like arguments, then the sub —
so one serialization inserts and looks up, and the two cannot drift.

```
f(x, y, z, 'abc')     ->  f(),(1),(2),(3),'abc'
a_{m, n}              ->  a,sub,(1),(2),end
```

Free variables are numbered by position; literals keep their spelling. `sub` is a COMMAND, not a
character: it says the children of the base follow.

**What the trie buys, and it is more than lookup speed.** Today `read_factor` finds how far a name
reaches by offering every extent of the row to the name parser and keeping the ones that resolve -
O(n) re-parses per factor. A trie is fed the units once, and "this node carries a definition" IS the
set of legal stopping points. Extent-finding and resolution become the same walk.

### `end`, and why a sub needs a terminator

Sub-lists nest, so without a terminator sibling boundaries are lost:

```
a_{b_{c}, d}   ->  a,sub,b,sub,c,d        -- is `d` a child of b, or of a?
```

So a sub emits `end` when its child list closes. Author's own worked example, corrected:

```
1_{2_{3_{4_a}}, 5_{6_{b}}}
->  1,sub,2,sub,3,sub,4,sub,(1),end,end,end,5,sub,6,sub,(2),end,end,end
```

(`a` is `(1)`, `b` is `(2)`; the six `end`s close the lists of 4, 3, 2, then 6, 5, 1.)

**A call needs no terminator**, and this is worth writing down so nobody adds one for symmetry.
Only the ROOT base may take function-like arguments (author, 2026-09-10: *"only the root base of a
definition is allowed to have function like parameters"*), so an argument list can never contain
another one, and it ends at the root's `sub` or at the end of the name - both decidable from the
next token alone. Without that restriction `f(),g(),(1),(2)` is genuinely ambiguous between
`f(g(x), y)` and `f(g(x, y))`.

**A comma never reaches the serialization.** It delimits children in a sub list and parameters in a
call, and the token structure records what it separated: every child is self-delimiting, being
either a leaf token or a `sub`…`end` pair.

### What is a parameter and what is part of the name

The rule every example obeys, stated because it is the crux and was previously only implied:

> **A BARE letter is a free variable. A letter carrying a sub or a call is a literal base.**

So `m` in `a_{m}` is `(1)`, while `b` in `a_{b_{2}}` is the literal token `b`. Numbers and quoted
names are always literal.

**Numbers may be a base again**, reversing the 2026-09-10 morning ruling that restricted bases to
letters. The objection then was that `2(x)` collides with multiplication; the trie answers it,
author's words: *"if you define 2(),(1) it will steal the whole 2(x) as the name, not leaving
multiplication a chance to break"*. It is deterministic because a NUMERAL is not a trie definition -
either `2(),(1)` is defined and takes the row, or nothing is and it falls back to `NUM(2) · (x)`.
There is no third reading.

One condition rides along: the base token for a numeral is the WHOLE digit run, or `1` and `12`
branch against each other in the trie.

### Inserting a definition

Following the serialized tokens as a path:

1. **A new node** — the happy case; the node is marked as a definition.
2. **A marked ancestor exists** — refused. Overlapping definitions are not allowed.
3. **Several marked ancestors** — cannot happen if (2) is enforced, since a node's ancestors are a
   chain and two marked ones would already have violated it. Keep it as a consistency check on the
   invariant rather than as a case of its own.

**Why (2) is a flat refusal rather than the narrower rule review proposed.** Review argued that a
prefix is only DANGEROUS when the continuation begins with `()`, because only a bracket group can be
re-read as multiplication - a trailing sub is welded to its atom and can never be left over. True
for parsing, and beside the point: author, 2026-09-10, *"if you have a_{n} defined, why would a be
allowed? it is already a name of something, what would a_n being a sequence and a+1 mean at the same
time?"*. The rule is about meaning, not about ambiguity. Two things named `a` are two things named
`a` whether or not a parser can tell them apart.

Consequence to know: this also forbids arity overloading, since `f(),(1)` is a prefix of
`f(),(1),(2)` - no `\log(x)` alongside `\log(b,x)`.

**No definition inside a definition.** If `b_n` is defined, `a_{1,b_m,2}` is refused, because
`b_m` would then be readable both as part of `a`'s name and as an application of `b`. Checked by
walking the trie from each argument.

This check is NOT stable at insertion time, and the fix is a separate pass. Definitions resolve by
document POSITION (`content.declarations_before`), so a definition added ABOVE an existing one can
break it retroactively. So the check belongs in a step that runs after a definition parses cleanly
and asks "does accepting this at position k break anything on either side of k" - both directions,
not only upward. Author, on wanting it: *"can we maybe do a check and research all the definition
from above when finalizing a definition? the idea is that accepting a new definition should not
break any of the old ones?"*. TODO; not built.

### Walking a use

A literal branch and a parameter branch can sit at the same trie position, and neither is an
ancestor of the other, so non-overlap does not separate them:

```
a_{1,m}   ->  a,sub,1,(1),end          trie after `a,sub`:  { "1", "(1)" }
a_{n,m}   ->  a,sub,(1),(2),end
```

The use `a_{1,5}` walks both: `1` matches the literal, and `1` is also a valid expression for `(1)`.
Two live paths, two definitions found.

**The most restrictive match wins.** Author, 2026-09-10: *"let's try the most restrictive one"*. A
literal beats a parameter at the same position, so `a_{1,m}` takes `a_{1,5}`.

**THE STRUCTURAL BRANCH IS NOT A BRANCH AT ALL**, and review had this wrong. Whether a decorated
group like `n_{5}` is an argument or part of the enclosing name looked like a second place the walk
had to fork - it is not, because the no-definition-inside-a-definition rule makes the two readings
mutually exclusive. Author, 2026-09-10: *"on expression walking, n_{5} would mismatch as a definition
which will make n a base literal of the sub n_{m} and help match the whole expression"*. So it is one
local test per group: does anything answer to this group on its own? No candidate set, no
backtracking, and the rule that makes it sound is the same one that was already there for a
different reason.

**Ties are broken leftmost-first, and logged.** Specificity is a partial order - `a_{1,m}` and
`a_{n,2}` both match `a_{1,2}` and neither dominates - so the comparison runs position by position
and the first difference decides. Author: *"that ambiguity in a_{1,m} a_{n,2} should be again rather
logged and the first matching will be considered more exact than the second parameter matching"*.
The log is what a type pass will later re-examine; types are what should really be choosing here,
and they do not exist yet.

**This replaces "exactly one candidate or error"** for name resolution (section "Every declaration
this use could mean"). With a trie, two definitions with the SAME serialization collide at
insertion, so the only multi-match left is specificity, and specificity now ranks rather than
refuses. "Exactly one or error" survives for identical keys alone.

### Everything that is not a name

Unchanged from what is already built, and restated here because the author's document ends with it:
a row that does not resolve to a name falls back to numerals and expressions - NUM, ADD, MUL, and
the big operators. Parentheses that precedence already requires are absorbed into the shape;
redundant ones are kept as an explicit CELL (see "CELL — the rule of 2026-09-06, restored"). The
author's phrasing, "MUL holding an ADD implies a parenthesis", is the common case of that rule
rather than the whole of it: a power absorbs them too, and a group around a leaf promotes.

### Order of work

1. **The serialization**: `end` terminators, and the bare-letter-vs-decorated-letter rule. Changes
   every key, and is safe to do now only because keys are not persisted - they are rebuilt from the
   document each frame. That stops being true the moment an AST is saved, since a CALL's callee IS
   the key string.
2. **The trie**, with the frontier walk and specificity ranking, replacing `resolve_use`'s linear
   scan and `read_factor`'s extent loop together.
3. **The position-aware "does this break the others" pass.**

## 19. Conclusion

**What is decided.** Promotion is the checkpoint and cells are immutable. The bridge is a direct
tree walk, never a LaTeX detour, and it emits ast + types + linked variables + mapping in one pass.
The id is the real name; the glyph is decoration; `a` and `a_n` are object and application. A
declaration fixes a name's form, and using the wrong form is an error rather than a reinterpretation.
Parentheses implied by precedence are absorbed into the tree; redundant ones survive as `CELL`
because they carry the user's grouping. Equality is decided by normalizing to a comparison key that
is never written back, and the automatic rule set decides only what may be left unwritten. Steps are
transform-applied and therefore correct by construction, which makes `transforms.lua` the trusted
kernel. Lean is the interchange language of the checked domain.

**What blocks.** The logic layer — propositions, `\forall`, implication. It has no home in the AST
today, and it gates Lean import, Lean export of anything with a hypothesis, and (depending on open
question 4) the type system itself. Everything else in this document can be built around a hole;
this one cannot be built around.

**What is genuinely unsettled**, and should not be guessed at by a later session: whether typing
rules are built in or user-written (question 4), whether propositions are their own sort
(question 5), which rules are automatic by default (question 1), and whether cells are ever pruned
(question 3). Section 17 has all seven.

**What is most likely wrong.** This is a design written in one conversation with no implementation
to argue back. The parts most exposed are the ones with the most machinery and the least contact
with a real formula: the normalizer admission rule (9), the claim that one walk can produce all four
outputs without a second pass (11), and the assumption that patching mexpr by regeneration keeps
layout stable enough to be invisible (12). Each is written down here precisely so that when the
first real formula contradicts it, the contradiction is legible — which is what `CLAUDE.md` says
tests are for, applied to prose.

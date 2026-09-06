# Phase 2 — linking the editor to the AST

## Introduction

Design decisions from the session of 2026-09-06, after the text editor was declared done
("the user interfacing editor passed it's stage, time for second stage"). **Nothing here is
implemented yet.** It is written down because all of it was decided in conversation and would
otherwise be lost — none of it is derivable from the code, because there is no code for it.

Phase 1 = `editor.lua` + `mformula_new.lua`: free typing, mexpr trees, LaTeX in and out.
Phase 2 = giving those formulas *meaning*.

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
  definition cell        immutable, checked              definition_editor.lua  (to write)
  formula cell           immutable, checked              formula_editor.lua     (to write)
       |
       |  Ctrl+C  ->  LaTeX
       v
  text editor again      edit freely, re-promote
```

**Promotion is the checkpoint.** Inside a definition or formula cell you never type freely —
only *syntactic mutations*, which is where `transforms.lua` belongs.

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

- `ast.to_latex` exists but **there is no `ast.from_latex`**. The AST's round-trip pair is
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

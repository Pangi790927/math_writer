# Phase 2 — linking the editor to the AST

Design decisions from the session of 2026-09-06, after the text editor was declared done
("the user interfacing editor passed it's stage, time for second stage"). Nothing here is
implemented yet. It is written down because all of it was decided in conversation and would
otherwise be lost.

Phase 1 = `editor.lua` + `mformula_new.lua`: free typing, mexpr trees, LaTeX in and out.
Phase 2 = giving those formulas *meaning*.

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

**Still open and worth revisiting before the formula editor round-trips real content:** roughly
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

### Layer 1 — tree walk

Dispatch on `mexpru.u(node).kind`:

| mexpr | AST |
|---|---|
| `horiz` | whatever layer 2 returns |
| `frac` | `new_div(num, den)` |
| `supsub` | `new_exp` or `new_call` — see the superscript rule below |
| `vert` | `new_vec(...)` / `new_mat(r, c, ...)` |
| bracket pair | `new_cell(inner)` — pair via `.peer`, read through `mexpru.slot_atom` |
| symbol | a *token* for layer 2, not a node |
| empty box | a hole: fail here, carrying the node |
| `dress`, `bigop` | see gaps |

`mexpru.slot_atom` is mandatory for brackets: the closing half is frequently a supsub base
(`(a)^2`), invisible to any walk reading children directly. That blind spot has produced five
live bugs so far.

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

**(b) How is a multi-letter subscript written at all?** Juxtaposition is multiplication, so
`v_{max}` parses as `CALL(v-sub, m*a*x)`. Either labels need their own notation, or a subscript
holding a label is parsed differently from one holding an index expression — and only the
declared domain can tell which, which loops back to (a).

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

### Consequence: the logic layer is NOT deferrable

This reverses earlier advice in this document, and it is the second time the same reversal has
happened — first with binders (section 5), now here. The pattern is worth noticing: each time,
what looked like an advanced feature to defer turned out to be the foundation.

If rules are formulas, then **propositions, implication and quantifiers are needed to write the
very first typing rule.** "For all x, y: x elem R and y elem N implies x + y elem R" cannot be
stated without them. They are not phase-3 work; they gate the type system, which gates
definitions.

### Open: bootstrapping

If typing rules are formulas, and formulas are type-checked, that is circular. Either a base
set of rules is primitive and unchecked (axioms), or checking is staged. Not yet decided, and it
should be before the first rule is written.

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
"this was a square root", and `
ot` followed by `=` does not say "this is one relation" - the walk
has to recognise the SHAPE if the AST is to carry `
e` as a single relation rather than a negated
equality. Both readings are defensible; the second is closer to how a solver would want it.

## 7. Lean

Asked whether this could talk to Lean. Verdict: the *proof structure* is already Lean-shaped
almost by accident; the *logic layer* does not exist, and that is the whole distance.

**Lines up:** declarations are nearly identical (`a-sub : N -> R` vs `def a : Nat -> Real`);
"one transformation per cell" is exactly Lean's `calc` block; "equivalences must be proved" is
Lean's stance; binding-by-identity matches.

**Does not:** the AST has no propositions, no `forall`/`exists`, no implication — hypotheses and
theorems have nowhere to live yet. Notation-as-identity cuts against Lean, where notation is a
display layer over one constant. And dependent types are where Lean's power is; simple arrows
reach the easy fraction only.

**Realistic integration, cheapest first:** emit `calc` skeletons with `sorry` per step; then
emit justifications, where `by ring` / `field_simp` / `linarith` / `norm_num` plausibly close
most routine algebra without mapping lemmas by hand; then import; then live checking.

**Do not design for Lean now.** But add the two things that make the cheapest level possible
later, because retrofitting them is expensive:

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

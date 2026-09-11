# AST parsing — how a typed formula becomes an `ast.lua` tree

Reference for `scripts/mexpr_ast.lua`: what it reads, what it produces, and which rules decide the
cases where a row could mean two things. Written 2026-09-10.

`docs/phase2_design.md` is the *design record* — why these decisions were made, in the author's own
words, including the ones that were reversed. This file is the *current state*: what the parser
does today. Where the two disagree, this one is wrong and should be fixed.

**Status legend** — 🟢 implemented and tested · 🟡 partly · 🔴 designed, not built.

---

## 1. The two modes

One parser, two questions.

| mode | asks | entry point |
|---|---|---|
| **definition** | what does this name pattern *identify*? | `mexpr_ast.parse_name` |
| **expression** | what does this row *mean*, given what is declared above it? | `mexpr_ast.build` |

Both walk the same `mexpr` row through the same code, and both produce the same kind of token
walk for a name — which is the point: a definition and a use of it have to serialize identically or
they cannot be matched.

The declarations in scope come from `content.declarations_before(state, i)` — the definition boxes
**above** box `i`, in document order, after the rules of §4 have refused the ones that cannot
coexist.

**A definition is the only mechanism.** 🟡 Author, 2026-09-10: *"the whole idea is that definition
rule what can and can't be seen as a named structure"*. Anything the system knows without being
told — `sin`, or the derivative `f'` once something decides `f` may be differentiated — arrives as
an **injected definition** in that same set, not as a second table the parser consults. So the
parser has no notion of built-ins, of derivatives, or of specialisation: it reads a name, and
resolution answers or does not.

Nothing injects yet. Two things the mechanism needs that do not exist:

- **A position.** Scope is positional and §4 resolves conflicts by "the earlier one wins", so an
  injected definition has to sit somewhere in document order — at the top for a built-in, presumably
  next to the box that licensed it for a derivative.
- **A provenance.** A refusal currently points at the box that wrote the definition. An injected one
  has no box, so a conflict with it has to be able to say where it came from, or the user is told
  their name is taken by something they cannot find.

## 2. Reading a row

A row is a list of **units** (`units_of`). One unit is one slot of the row plus whatever is
decorating it: `a_b` is a single unit whose atom is `a` and whose `sub` is `b`. Every walk goes
through `mexpru.slot_atom` to find the atom under a supsub or a dress — skipping that is the blind
spot that has produced seven live bugs (`phase2_design.md` §8).

**Quotes bind first, then spaces are dropped.** A quoted name is packed into ONE unit the moment
its opening quote is seen, so the atoms between the quotes never reach the space filter — a space
inside a quoted name is content, and there is nothing to put back. 🟢

The pack is **row-local**: a quoted name cannot span a subscript boundary, since in `'a_{b'}` the
two quotes are in different rows. The unit that survives is the **closing** quote's, because that is
the one a subscript typed afterwards wraps — `'abc'_n` is `[', a, b, c, supsub(base=', sub=n)]`. It
carries the inner atoms as `quoted_nodes`, so the definition box still paints per character.

Outside a quoted name a space is layout, and goes. `f (x)` and `f(x)` are the same name. This
mattered more than it sounds: a space broke the name parse in four different ways depending on where
it landed, which is why the filter is at the single place units are built.

*(Until 2026-09-10 the order was reversed — every space was dropped and the quoted ones restored
from a per-unit count. It worked, and it was two mechanisms where one does.)*

## 3. The name serialization

A name pattern becomes a comma-joined token walk. Walk order is always **base → call arguments →
subscript**, and it is identical in both modes.

```
f(x, y, z, 'abc')     ->  f(),(1),(2),(3),'abc'
a_{m, n}              ->  a,sub,(1),(2),end
F_{1,'ab',n,m}(t,v)   ->  F(),(1),(2),sub,1,'ab',(3),(4),end
a_{n_{m}}             ->  a,sub,n,sub,(1),end,end
```

- **Free variables are numbered by position**, `(1)`, `(2)`, … Their spelling is not part of the
  name: `f(x)` and `f(z)` are the same name.
- **Literals keep their spelling** — numbers as written, quoted names with their quotes.
- **`()` rides on the base token**, so a call and a subscript can never be confused: `f(),(1)` is
  not `f,sub,(1),end`.
- **`sub` is a command**, not a character: the children of the base follow.

### `end` closes a subscript's child list 🟢

Sub-lists nest, so without a terminator sibling boundaries are lost — `a_{b_{c}, d}` and
`a_{b_{c, d}}` would both read as `a,sub,b,sub,c,d`.

**A call list needs no terminator.** Only the root base may take function-like arguments, so an
argument list can never contain another one, and it ends at the root's `sub` or at the end of the
name — both decidable from the next token. Drop that restriction and `f(),g(),(1),(2)` becomes
ambiguous between `f(g(x), y)` and `f(g(x, y))`.

### Decorations are part of the base token 🟢

An accent or a prime on a name's base belongs to its identity, and rides **inside** the base token:

```
\hat{a}       ->  a\hat
a''           ->  a''
\hat{a}''     ->  a\hat''
\hat{a}_{m}   ->  a\hat,sub,(1),end
a'_{m}        ->  a',sub,(1),end
```

**Inside the token, not beside it**, and that is forced rather than chosen: as a separate token, `a`
would be a *prefix* of `a,\hat`, and §4 refuses a name that extends one already defined — so `a` and
`\hat{a}` could not both exist. Inside, they are siblings.

**Canonical order**: accents innermost-first, then primes. Without a fixed order one name serializes
two ways and stops identifying.

**A lone quote is a prime.** `'` and `''` have no closing quote and nothing after them that could be
string content, so they are primes rather than a name being typed; `'ab` has content following and
stays an unterminated name, keeping its error and its red mark.

*(Every accent was silently dropped until 2026-09-10 — `\hat{a}`, `\vec{a}` and `a` all serialized
as `a`, so a formula using `\hat{p}` resolved to a declaration of `p`. `slot_atom` looks through a
dress, which is right for the cursor and wrong for identity.)*

### Bare versus decorated 🟢

> **A bare letter is a free variable. A letter carrying a subscript is a literal base.**

So `m` in `a_{m}` is `(1)`, while `n` in `a_{n_{m}}` is the token `n` and that pattern has **one**
parameter, not two. Numbers and quoted names are always literal.

**A decorated parameter is still a parameter.** `a_{\hat{m}}` is `a,sub,(1),end`, the same as
`a_{m}` — a parameter's spelling was never identity, and an accent is part of that spelling. A
decoration becomes identity only where what it sits on is literal, so `a_{\hat{m}_{p}}` is
`a,sub,m\hat,sub,(1),end,end`.

The rule is what makes a nested subscript readable at all: a parameter swallows whatever is written
at its position, so if `n` were one, `n_{m}` would be a parameter carrying a subscript, and nothing
in a pattern says what that identifies.

### Bases 🟢

A letter, a quoted name, a named operator, or a number. A named operator (`sin`, `log`) is a 1-tall
vertical whose single row holds the letters, and it becomes **one token** — that is what the
construct is for, since `s`, `i`, `n` loose in a row is a product.

**A number may be a base**, and the base token is the **whole** digit run — `12` is one base,
not `1` applied to `2`, or `12(x)` could resolve against a declaration of `1`.

`2(x)` is deterministic despite looking like the ambiguity that once banned digit bases: a numeral is
not a trie definition, so either `2(),(1)` is declared and takes the row, or nothing is and it falls
back to `NUM(2) · (x)`. There is no third reading. *(Legal, then banned, then legal again, all on
2026-09-10 — `test_name_pattern.lua` carries the round trip.)*

## 4. Which definitions may coexist 🟢

`mexpr_ast.check_declarations` indexes the definitions of a document in a trie and refuses the ones
that break either rule. **What was written is not what is in scope** — a refused definition is
dropped, and the earlier one wins, the same way a name means what was said above it.

This is not tidiness. The rules are what make §5's local decision correct.

### No overlapping definitions

Neither a prefix of an existing name, nor the start of one:

```
a        then  a_{n}       -- refused: extends a name already defined
a_{n}    then  a           -- refused: is the start of a name already defined
f(x)     then  f(x,y)      -- refused: same shape, so arity overloading is out
a_{1,m}  then  a_{n,m}     -- accepted: different branches, neither a prefix
```

This is about *meaning*, not parseability — two things named `a` are two things named `a` whether
or not a parser could tell them apart. The price is arity overloading; `\log(x)` alongside
`\log(b,x)` is the case that will eventually argue for narrowing it.

### No definition inside a definition

If `n_{m}` is a name, `a_{n_{m}}` may not be one — `n_{m}` inside it would be readable both as part
of `a`'s name and as an application of `n`. Checked **both directions**, so with `a_{n_{m}}` already
in place it is `n_{m}` that gets refused.

Only **decorated** groups ask the question. A bare letter is a parameter by rule and has no
competing reading, so `a_{m}` is fine with `m` declared elsewhere.

🟡 The check runs over the definitions above a box, re-derived every frame, so a box inserted above
others re-decides the whole set. What is missing is telling the user *which* box became invalid
rather than silently dropping it.

## 5. Resolving a use 🟢

A use site emits `(k)` for each argument group — an argument never contributes to a name's
identity, whatever is written in it, so `f(34)` keys as `f(),(1)` exactly as `f(x)` did.

**Except for a decorated group that is part of the name.** `a_{n_{5}}` has to read `n` as literal
structure to match `a_{n_{m}}`. The decision is **local, one test per group**, with no candidate set
and no backtracking:

> a decorated group either resolves on its own — and is an argument — or it does not, and is part of
> the name.

§4's rules are exactly what guarantee those are never both true. A **bare leaf never asks**: without
that guard `a_{5}` would call `5` literal structure and stop matching `a,sub,(1),end`.

```
a_{n_{5}}   with a_{n_{m}} declared    ->  CALL "a,sub,n,sub,(1),end,end" (NUM 5)
a_{n_{5}}   with a_{x}, n_{m} declared ->  CALL "a,sub,(1),end" (CALL "n,sub,(1),end" (NUM 5))
```

### Matching, and the most restrictive winner

`match_use` walks the use's tokens against a declaration's, position by position. A `(k)` in the
declaration swallows whatever the use put there; anything else is a literal the use must have
written exactly. Markers — base, `sub`, `()`, `end` — must agree outright.

When several declarations match, **the most restrictive wins**: one that pinned a position to a
literal said more than one that left it open.

```
F(0)     with F(x), F(0)      ->  F(),0          (F(),(1) shadowed)
F(9)     with F(x), F(0)      ->  F(),(1)
a_{1,2}  with a_{1,m}, a_{n,2} ->  a,sub,1,(1),end
```

Specificity is only a *partial* order — neither `a_{1,m}` nor `a_{n,2}` dominates for `a_{1,2}` — so
the comparison runs position by position and the **leftmost difference decides**. The losers come
back on the hit as `shadowed`, because what should really be choosing here is types, and there are
none yet.

**Exactly one or it is an error** survives only for a genuine tie: two declarations that pinned the
same positions are the same shape, and no order separates them.

## 6. The expression cascade 🟢

Four layers, one per precedence level. Each is handed a **unit list**, never a container, which is
what lets a relation's side, a call's argument and a superscript's row go through the same parser.

```
build_relation   splits on  =  <  >  \le  \ge  and the \ne pseudo-glyph
  build_sum      splits on top-level  +  -
    build_product  segments into factors
      read_factor    one name-use, numeral, bracket group, or fraction
```

**Extent** — how far a name reaches along a row — has exactly **two** candidates, not a search
space. 🟢 `read_pattern` reads a base, then at most one bracketed group, then nothing; a subscript
rides on the base's own unit and costs no row units. So a name ends either where its base does, or
after the one bracket group that may follow it. `read_factor` asks for both and resolves each.

Which one wins is the declarations' answer: `f(x)` is a CALL with `f(y)` declared and a product with
`f` declared. Both declared is an ambiguity rather than a preference — the two readings differ in
extent, so specificity (§5) has nothing to compare.

*(This was a search until 2026-09-10: every end position from the whole row down to one unit,
re-parsing the same prefix each time. The plan was to replace the search with an incremental trie
walk; what the work actually found is that there was never a search to replace — only two of those
end positions could ever parse, and everything between them failed for reasons that were never
interesting.)*

**A fraction bar is a division, whether or not `\div` was ever typed.** 🟢 `\frac{a}{b}` reaches the
AST as `new_div(num, den)`, num and den each built by recursing `build_expr` over that slot's own
row - so `\frac{a+2}{b+2}`, nesting, and a fraction inside a call argument all just work through the
ordinary cascade. A power applied directly to the frac (`\frac{a}{b}^{2}`) and one applied to
explicit parens around it (`(\frac{a}{b})^{2}`) build the *same* tree - the parens are absorbed by
the power exactly as `(a+b)^2`'s are (§7), nothing frac-specific about it.

**`\div` written inline is deliberately not the same door.** `a \div b` still refuses with a reason
(§9) rather than folding into a division tree. Author, 2026-09-10, scoping it down before it was
built: *"I want to ignore for now any fraction that is not made by a 'towering' fraction, so a/b,
ignore it, error on it, frac{a}{b}, it's ok, parse it"*.

**Signs** are a property of the product: `-2x` is `MUL(NUM(-2), REF(x))` (folded into the leading
numeral) and `-x` is `MUL(NUM(-1), REF(x))`. A sign is a separator only with a term behind it.

**`\infty` is a number, spelled `NUM(1, 0, +1)`** — one over zero. Author, 2026-09-11: *"infty
should also parse, it's a number like any other, give it a specific value in over 0 in denominator"*.
It gets no node type, no arithmetic branch and no sign handling of its own: `-\infty` goes through
the same "negate a leading numeral in place" rule as `-2`, and comes out `NUM(1, 0, -1)`. The debug
views gloss a zero denominator as `inf`, but only for a numerator of 1 — `0/0` prints raw rather
than being read as something nobody built.

**Greek glyphs are letters** (`char.greek_letters`), so `\pi` is a free variable, `\mu_{n}` a
declarable name and `\theta` an integration variable. `\sum` and `\prod` are *not* in that set:
they are operators that happen to be drawn as Greek capitals, and carry their own descs. Inside a
quoted name the rule is narrower — ASCII only, since a quoted name packs by concatenating descs and
`\pi` is several characters with a backslash in them.

**Juxtaposition is multiplication**, which is possible only because a multi-character name has two
other spellings — quoted, and the operator vertical. `bb` has no reading as one name.

**A free letter before a bracket is multiplication once resolution has failed.** `g(x)` with `g`
undeclared is `MUL(REF(g), REF(x))`. The safety is in the ordering: a declared `g(x)` is still a
CALL, and only an unresolved one becomes a product.

**An unresolved letter is a free variable**, wherever it is written. 🔴 What should eventually
constrain it is the binders (§8) and the domain machinery; neither exists, so an undeclared name and
a typo are currently indistinguishable.

### `\ne` 🟢

No font here draws one — TeX has none either, and builds the symbol by overprinting the zero-advance
negation slash with `=`. So the row holds **two atoms**, and reading them separately would leave `=`
behind as an ordinary equals: `a \ne b` would build `a = b`.

The pair is read as one relation, using the same zero-advance test (`char.adv_by_desc[d] == 0`) that
`mformula_new`'s `delete_overprint_unit` has used since 2026-09-06 to make it *delete* as one. Keyed
on **both** halves, so `\! =` — also zero-advance, and negating nothing — does not become a `NEQ`.
Only `=` is paired; `\notin` is refused, because `ast.lua` has `INEQ_NEQ` and no other negated node.

## 7. CELL — when parentheses survive 🟢

> A `CELL` is emitted exactly when the parentheses are **not** implied by precedence.

Required ones are absorbed into the tree shape; redundant ones are kept, because they are the only
carrier of the user's own grouping, and grouping is what `transforms.lua` drags around.

```
(a+b)c      ->  MUL(ADD(a,b), c)              required by the product
-(a+b)      ->  MUL(NUM(-1), ADD(a,b))        the sign counts as a factor
(a+b)^{2}   ->  POW(ADD(a,b), NUM(2))         a power absorbs them
(a+b)+c     ->  ADD(CELL(ADD(a,b)), c)        redundant, kept
(ab)c       ->  MUL(CELL(MUL(a,b)), c)        redundant, kept
(a)+b       ->  ADD(a, b)                     nothing inside to group
```

The decision is made **last**, in `build_product`, because "required" is a question about the
product the factor ended up in, and that is not known until the factors are collected.

## 8. Big operators 🟡

`ast.lua` has `SUM`, `PROD`, `UNION`, `INTERSECT` and `INT`. Only `INT` still has the original single
shape:

```
(I, var, from, to, body)
```

`SUM`/`PROD`/`UNION`/`INTERSECT` share a different one, N variables and a constraint list per side
rather than one var and a bare from/to - see "Bigop scoping", `phase2_design.md` section 18c, for the
full record:

```
(op, n_vars, n_sub, n_sup, var1..varN, sub1..subK, sup1..supM, body)
```

All five are the first nodes that **declare** a name. The constructor takes names, makes the
variables itself, and **catches** free mentions of each across every sub, every sup and the body -
repointing them at the variable it made. Afterwards the binding is ordinary structure, so nothing
walking the body needs to know it is inside a binder.

The body is built first and caught afterwards because `\int_0^1 x dx` names its variable *after* the
body. A nearer binder of the same name shadows the whole group - subs, sups and body together, one
scope - not just the body the old shape split off.

**Nine operators are written as WORDS rather than as a glyph** — `lim`, `limsup`, `liminf`, `min`,
`max`, `sup`, `inf`, `argmin`, `argmax`. They are binders exactly like `\sum`: same group shape, same
constraint lists, same spawning, same reader. The only difference is how the name is spelled on
screen — a 1-tall vert holding the letters (`operator_name`) instead of one glyph — so
`BIGOP_BY_SPELLING` is keyed by either and `read_bigop` never learned about them.

A word operator is not the same thing as `sin`/`log`/`det`, which are also words: those **apply** to
an argument and key into the definition trie as `sin(),(1)`, while these **declare** a variable in
their subscript. A declaration still wins over both, since name resolution runs first.

**The 25 built-in functions are INJECTED DECLARATIONS** (`mexpr_ast.builtin_declarations`), added by
`build` itself so being in scope is a property of the language rather than something a call site can
forget. They are produced by *parsing* `\sin (x)` through the ordinary name parser, so a built-in
keys identically to a use of it. Consequences that fall out for free, rather than needing code:
resolution ranks them by the same specificity rule, the argument goes through the whole expression
cascade (`sin(2x+1)`), and a user's own declaration of the same text **replaces** the built-in
instead of colliding with it.

Arity is part of the name, so it is a decision: one argument for all of them except `gcd` and `hom`.
`\gcd (a)` therefore does not resolve. A bare `\sin` with nothing applied is not an expression.

`\lim_{x \to 0}` needs the arrow, so `TENDS` is a relation like membership — asymmetric, spawning
only the side that varies. Typing `-` then `>` produces the single `\rightarrow` glyph (`DIGRAPHS`),
so there is one spelling to recognise.

**They serialize as LaTeX operators**, not as matrices. `char.operator_words` is the list LaTeX
already names (`\lim`, `\sin`, `\Pr`, …); anything else — `argmin` among them, since LaTeX defines
no such macro — goes out as `\operatorname{...}`, which is what amsmath provides for exactly this.
Both spellings read back into the vert, so pasting a limit out of a paper now works. `\operatorname*`
is read as display placement, the same thing `\limits` says.

*Known cosmetic difference:* LaTeX sets these upright, this app draws them in the same italic letters
as everything else, so an export looks slightly different from the screen. Kept deliberately —
drawing them upright means substituting glyphs inside the vert at typing time, which changes what
`operator_name` reads and what a save contains.

**`mexpr_ast` has two operator cases, and they share nothing but the word.** `read_bigop` handles the
group shape — `SUM`/`PROD`/`UNION`/`INTERSECT` plus the nine words above; `read_integral` handles
`\int`/`\oint`. Both recognize either form
a row can produce an operator in: an ordinary supsub whose base is the glyph (`\sum_{i=1}^n`, no
`\limits`), and the same node with its sides placed over and under (`\sum\limits_{...}`) - same
meaning, only where the limits are drawn differs.

**An integral reads its variable from the differential, not from its sub** (🟢 since 2026-09-11).
`\int` and the `d` that closes it are a BRACKET PAIR (`char.BRACKET_INTEGRAL`), made together at
typing time, so:

- the body is exactly what lies between the two halves - it ENDS at the `d`, unlike a group
  operator's body, which swallows the rest of its term;
- the variable is exactly the unit after the closing half, with its decorations;
- the sub and sup are VALUES read through `build_expr`, not constraints, and declare nothing. An
  integral with neither is an ordinary integral: both slots hold an `ast.NULL` (serialized
  `(null:id)`), which is a real leaf node rather than an empty slot - a nil there makes Lua's `#`
  stop short and every generic walk over the node silently skip its body.

Nothing is scanned for. That is the whole point of the pair - a forward scan for a `d` cannot tell an
integrand ending in a variable named `d` from a differential, nor which of two integrals a `d`
belongs to. Author, 2026-09-10: *"if paired and kept paired, there is no way for someone to miss
adding the integration variable, which is important"*.

**The pairing survives a save**, because the differential is written `\,d` and read back as the
closing half - real LaTeX, and the conventional spelling, so the export still renders elsewhere and a
paper's own `\int f(x)\,dx` now pastes in as a real pair. The mark binds only while an integral is
open on the reader's bracket stack, so a `\,` typed anywhere else stays the thin space it is.
Author, 2026-09-11: *"this is only present in the export we forget it and link with the integral"*.

An integral written before that (a bare `xdx`) is **refused with a reason** rather than repaired by
guessing, and has to be retyped once.

**Each sub/sup slot is one or more constraints.** A single `horiz` is one; a `vert` stack found there
(already a general, user-buildable primitive - `mformula_new.new_with_vert()`) is one constraint per
slot. Each constraint is built as a real relation node through the ordinary cascade (§6/§7 above,
whatever `=`/`<`/`\in`/etc. produces) and kept in the tree, not discarded once its variables are
known.

**Spawned variables are the sub's free names minus the sup's**, harvested per constraint (both sides
of an ordinary relation - `i=j` with both undeclared spawns both, together) via a `ctx.free_order`
side-channel list, appended at the one place resolution already fails (`read_factor`'s free-letter
branch) - walking the finished tree cannot tell a free reference from a declared one after the fact,
since both produce the identical VREF shape.

**A list, and in written order, because the order is part of the tree.** These names become the
operator's variables in slots 4..4+N, so `\sum_{i=j}` and `\sum_{j=i}` are different trees and
`ast.to_string` writes the difference. It was a *set* drained with `pairs` until 2026-09-10, and Lua
randomises its string-hash seed per process, so one formula built `i,j` in one run and `j,i` in the
next - a nondeterministic tree, under an identity scheme that is exact structural equality. Nothing
caught it because `test_bigop_nodes.lua` hands `vars` in by hand and so only ever tested the
constructor; `test_bigop_parse.lua` exists to cover the path that decides the order.

**Membership/inclusion is the one asymmetric case.** `i \in S` has an element side and a set side,
and only the element side is ever eligible to be spawned - `\sum_{i \in S}(i)` spawning `S` alongside
`i` (nothing in the sup to subtract `S` against) was found live and fixed the same day
(`ASYMMETRIC_SPAWN_SIDE`, `mexpr_ast.lua`).

**`harvest_eligible` walks the WHOLE constraint tree**, not just its root — wherever a
membership/inclusion relation appears, at any depth, only its eligible side is descended into from
there; everything else recurses into all of its children.

A root-only check was tried first and would work today, since `build_relation` scans a row's whole
top level before recursing and so cannot produce a nested relation. It was rejected anyway: boolean
connectives (`\land`/`\lor`/`\lnot`) do not exist yet, and `i \in S \land i \ne j` must still spawn
only `i` on the day they land. "Recurse into every child" is the default for anything not in the
table, so a future AND/OR/NOT needs no change here — whereas a root check would need finding again.
Don't simplify it back.

**The body is the next multiplication-like term, and parentheses are optional.** The operator is a
factor like any other, and it swallows the REST of its own product term - exactly what
`build_product` would have read there. Author, 2026-09-11: *"the way it should be managed is as a
rest of an multiplication, or better as the next term after the supsub(sigma) to be a
multiplication-like term, paranthesis are an option, but optional"*.

So `\sum_{i=1}^{n} i`, `\sum_{i=1}^{n} i^2` and `\sum_{i=1}^{n} 2i` all parse with no brackets at
all. A top-level `+`/`-` is not reachable from here in the first place: `build_sum` sits ABOVE
`build_product` in the cascade and has already split the row into terms before any factor reader
runs, so `\sum_{i=1}^{n} i + 1` is `SUM(..., i) + 1` - the addition is the sum's SIBLING, not its
body. Writing the other reading needs the parens that make it one factor, `\sum_{i=1}^{n}(i+1)`,
which is the only thing brackets are still required for.

🟡 rather than 🟢 for one remaining reason: the `vert`-stack multi-constraint path has been reviewed
but not exercised live - there is no LaTeX text for it, only direct `mexpru` construction, which
nothing has done yet. (The body-extent question that used to be the second reason was settled
2026-09-10; `read_bigop`'s own comment carries the author's wording for it.)

## 9. Also not built

- 🔴 `\div` written inline (`a \div b`) - refused with a reason, same as any other unrecognized
  atom. Only the fraction node reaches the AST (§6) - see the note there for why the gap is
  deliberate for now, not an oversight.
- 🔴 Relation chains: `a = b = c` needs a shape nobody has chosen; `ast.new_eq` takes two operands.
- 🔴 A subscript on anything that is not a declared name.
- 🔴 Expression arguments in a *declaration* (`phase2_design.md`, "Operations inside a subscript").
  A use site handles them; a declaration would need the transactional rollback described there.
- 🔴 Types. They are what should decide between two matching declarations (§5) and what should
  constrain a free variable (§6).
- 🔴 Injected definitions (§1) — built-ins, derivatives, specialisation links. The parser is already
  written as though they exist; nothing produces them.

Everything above fails with a reason rather than approximating, and **F4** shows that reason next to
whatever tree was built.

## 10. Where the tests are

| file | guards |
|---|---|
| `test_name_pattern.lua` | the serialization, per pattern |
| `test_name_use.lua` | reading a row as a use rather than a declaration |
| `test_resolve_use.lua` | matching a use against declarations |
| `test_declaration_rules.lua` | §4 and §5 — which definitions coexist, and ranking |
| `test_ast_view.lua` | the built tree, end to end, as F4 renders it |
| `test_bigop_nodes.lua` | §8's node shape and binding, built directly |
| `test_bigop_parse.lua` | §8 from a typed row: which names spawn, in which order |
| `test_decorated_names.lua` | accents and primes as identity; quoted names packed whole |
| `test_operator_name.lua` | the `sin` vertical |
| `test_declarations_scope.lua` | which declarations a box can see |

Per `CLAUDE.md`, these are **tripwires over assumptions**, not proof. Several carry a record of the
day their assumption stopped holding; read those before making one pass again.

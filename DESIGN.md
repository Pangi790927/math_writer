# math_writer - design decisions

Dated decisions that shaped a layer of this project. The code shows what IS; this file records
what was CHOSEN, why, and the cases that tested it. Referenced from CLAUDE.md. Add an entry when
a decision like these is made, and read the relevant entry before reversing one. A title is 3-5
words describing what the text contains, ignoring prepositions. An entry records a decision the
author has ruled on - an observation or an open question is not a decision, and waits until it
is settled. Nor is what the code happens to do today a decision: the code is current state, and
only a design the author states goes in.

---

## Glyphs draw, transforms walk    (2026-09-15)

The mexpr knows drawing; the ast knows structure. A glyph's tag names only the node it draws,
never structure above it, and a sign glyph tags its term's leading coefficient - `+abc` creates
the mul term `+1,a,b,c`, and a minus tags the implicit `-1`. Which sum, which product a click
belongs to is the transform layer's question, answered by walking the ast from the node the
click resolved to - not by anything the parser records.

A sign is always its own coefficient - a unit `NUM(1)` or `NUM(-1)` leading the term's product,
never merged into another numeral. Magnitudes never multiply (`-2x3` is never `-6`); what folds
is signs with signs, auto-reduced for now - one day a double negative may be allowed to stand.
A sign glyph is also THE BUTTON: offers come only from signs, and the walk starts at the sign's
coefficient (the author: "a + is visualy the button, the same is -").

### Misdiagnosed right-click bug (2026-09-11, reopened 2026-09-15)

Right-clicking `d` in `a(b+d)` offered distribute and applying it broke. The symptom was real.
The fix of the day cut the design instead of finding the fault: offers were restricted to
operator glyphs and `+` was tagged straight to the ADD, so the climb died. Reversed 2026-09-15
by the author - the climb is the design. The actual fault, why or where the right-click broke,
was never found and is still open: it must be found, not routed around, when the climb returns.

---

## Local distribution, upward splice    (2026-09-15)

One click flattens one sum: distribution is local, and a bracketed sum inside a term stays for
the next click - "the user may do that repeatedly himself". When the distributed product was
itself a whole term of a sum, the expanded terms join that sum where their product sat, each
taking the sign of the position it lands in - an ADD cannot be a term of an ADD, and bracketing
it would build a CELL the tree does not have. Nothing new is distributed by the splice; the one
distribution done is only expressed where its result lives. Distribution also passes through
CELLs, the user's own brackets around the sum, which the distribution makes implied.

Transformations are WRITTEN as small named parts meant to be combined - the author, 2026-09-15:
"we want to split them into parts that we want to combine later on". Each part is a named
sub-transformation with its grammar in its comment (distribute's are `through_cells`,
`split_term`, `term_with_coeff`, `splice_up`), and new transformations are written this way:
assembled from existing parts where they fit, adding a part only for what is genuinely new.

---

## The lock, a trust bit    (2026-09-15)

The formula box's lock is a MUTEX on trust. CLOSED means trusted, and closing CHECKS that trust
first - the formula must parse into an ast, so a closed lock is never a claim the tree cannot
back. OPEN means trustedness is gone: the cell is dirty and editable, and an untrusted node can
claim a lineage in neither direction - closing drops the children (a locked box keeps nothing
derived from content it now freezes), and opening a ROOT drops parent and children both. Opening
a PARENTED box keeps the step first: a trusted copy takes the original's chain position (parent
upward), and the original drops its links and sits directly below the copy, where the writing
continues "to be closer with what you left behind in the derivation".
A transformation's child box is born locked: a step in a derivation, never a draft. Whoever
wants a lineage kept copies first - ctrl+d, the identity derivation - and unlocks the copy.

TRUSTED IS NOT PROVEN: a paste is verified against the ast like the lock is, so a pasted cell may
keep its lock - but a paste drops ALL chains, parent and children alike, because the from-to
convention demands a proven derivation and "a just copied in function is not a derivation"
(the author, 2026-09-15). Parse-validity and lineage are different claims, and only a
transformation earns the second.

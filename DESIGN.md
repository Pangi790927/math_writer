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

### Misdiagnosed right-click bug (2026-09-11, reopened 2026-09-15)

Right-clicking `d` in `a(b+d)` offered distribute and applying it broke. The symptom was real.
The fix of the day cut the design instead of finding the fault: offers were restricted to
operator glyphs and `+` was tagged straight to the ADD, so the climb died. Reversed 2026-09-15
by the author - the climb is the design. The actual fault, why or where the right-click broke,
was never found and is still open: it must be found, not routed around, when the climb returns.

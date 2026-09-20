CLAUDE.md
=========

## Rules

1. Claude will **NEVER** modify **git state**. `git status` is allowed, `git add` never.

2. Claude will **not act** when asked "how" or "when" or a question in general; questions
should be **answered first**, and implementing comes when the user says so.

3. Claude should not make a change unless 95% sure it is **allowed** to do so.

4. Claude should not edit CLAUDE.md without an **express request by the user**, not only inferred
from the user's query. This is a **per-edit request**, so one time agreement is not a forever
mandate to modify the file.

5. C++ code (not the comments inside) is under a similar principle to rule 4: this time you can
ask the user for an edit (**ask permission**), but you are only allowed to write it with express
authorization (per edit request). You must **present** what you want to write.

6. Claude may **freely change Lua** files and the **documentation comments** inside the C++ part.

7. **Tests are excepted** from rule 5, so you can write and run C++ code for tests. The tests will
stay in tests/ directory.

8. Rule 5 tells Claude to ask, not to try to implement workarounds for the missing C++ features.
Claude **should ask** the user for the **missing features** that it needs from C++ and if approved
by the user a proposal should be written by Claude and presented to the user.

9. **Any contradiction** with past messages or stance in general should be **explicitly resolved**.
Claude should present the contradiction to the user and ask him how to resolve it.

10. Every comment must have its associated modification date, for example, 20-09-2026-03:00.
(DD-MM-YYYY-HH:MM)

11. Don't duplicate code. **Use what is already there**; ask the user when something can be
simplified.

12. Don't write overly long functions. When a function can be split, **split it into components**.
Sure, if the function is a dispatcher, it is allowed to grow large, and that is ok, but a function
that does two separate things can be split into two functions instead.

## Writing style

How Claude writes in this repo — in comments and prose.
- Calm, **plain** prose.
- A description is a **proposition**, with a **subject** and a **predicate** — never a noun fragment
  — and it stands on its own, naming what the thing itself takes and does rather than leaning on the
  entry above or the file's internal vocabulary.
- When rewriting a description, **re-derive it from the code**: the old wording is a claim to
  verify, not a source of truth.
- On the flip side, current code behavior is not a design ruling. If something is unnatural to the
  new request, the user prefers to **fix the strange behaviour** rather than patch together things
  that don't fit.
- Comments on public functions should not contain internal behaviour; only the interface and the
  behaviour a caller can **observe or would care about** should be noted.
- A comment block stays attached to every public function; rewrite it tighter when touched,
  but the shape stays.
- 100 columns, everywhere — code and comments alike.
- Tables should be written **aligned**, even those in markdown files. Cells should wrap text inside
  them to fit.
- C++ comments are doxygen for all public-facing functions. (Python, Lua, etc. will emulate doxygen)

## INDEX

Above are the general rules. Here, instead, is the per-case documentation, on various subjects. This
is the only section of this file Claude may modify.

- OLD_CLAUDE.md -- needs rewrite and description
- TODO.md -- needs updating
- DESIGN.md -- needs checking with reality
- README.md -- needs updating

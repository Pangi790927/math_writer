# CLAUDE.md — math_writer

Repo-specific instructions for Claude Code. Read `README.md` first for what this project *is*;
this file is about how to work in it. These rules are specific to this repo and layer on top of
(don't replace) your standing global working preferences.

## Editing rules

- **`.cpp` / `.h` / makefiles: suggest, don't edit — by default.** Explain how something should be
  done; the human implements it themselves. Once it's written, review it for bugs/inconsistencies.
  This matches the standard working style already in place — restated here so the repo is
  self-contained for any session reading it.
  **Per-instance override:** if explicitly told, for that specific change, to add/write it
  directly ("add it", "make the change", etc.), do so. This is a one-off override, not a standing
  permission — it doesn't carry over to the next change; the default reverts right after.
- **`.lua` files are Claude's domain.** You may write and edit these directly — but ask first
  before making a change, don't just do it unprompted. This is the one carve-out from the rule
  above.
- **Documentation (`README.md`, `CLAUDE.md`) is Claude's to write directly**, no need to ask.
- **git structure is read-only.** `git status`/`diff`/`log`/`show` etc. are fine any time. Never
  `add`/`commit`/`push`/`stash`/`checkout`/`reset --hard` or anything else that touches history or
  the index.

## Build

Needs three sibling checkouts next to this directory: `../imgui`, `../implot`, `../utils`
(the last is `virt_composer`, the Lua↔C++ interop framework this whole project sits on). Nothing
here vendors or fetches them.

```bash
make        # root makefile dispatches to linux.makefile or windows.makefile based on OS
```

## Architecture, quick pointer

C++ core (`char_draw_composer.h` = fonts/glyphs, `math_expr_composer.h` = expression layout) is
exposed to Lua via `virt_composer`. The actual math model lives in Lua: `ast.lua` (the AST),
`char.lua` (glyph catalog), `mexpr.lua` (AST → drawable tree), `transforms.lua` (algebraic
term-dragging, WIP). Full detail and data-flow diagram in `README.md`.

## Known WIP / intentionally incomplete

- `transforms.lua` — term-dragging is deliberately unfinished, flagged in-file. Don't fill in the
  remaining cases without asking first; this is exploratory design work still being thought
  through, not a bug to fix.
- Fraction layout (`mexpr_frac` in `math_expr_composer.h`, and its caller in `mexpr.lua`) has open
  rough edges noted in comments.
- No editing/undo/redo/save-load yet — everything currently on screen comes from the hardcoded
  demo in `main.lua`'s `test_draw()`.

## Debugging

- `DBG()` / `DBG_SCOPE()` (from `../utils/`) write to `logfile.log`, rotated to `logfile.old.log`.
- `main.cpp` calls `ImGui::ShowMetricsWindow()` unconditionally in the main loop.

# Math Writer

## Introduction

An interactive, WYSIWYG mathematical expression editor built on
[Dear ImGui](https://github.com/ocornut/imgui), with a C++ rendering core and a math model written
entirely in Lua.

This is the third rewrite of the underlying model. Two earlier attempts are preserved under `old/`;
both turned out too complicated to serialize or transform cleanly, which is why the current AST is
deliberately dumb - plain tuples, each with a unique id - and everything interesting lives in Lua,
where it can be changed without recompiling.

## Intent

The goal is not to *render* formulas. Plenty of things render formulas.

The goal is to let you point at a term inside an expression and **legally move it**: drag a term out
of a sum, factor it out of a product, cancel it across a fraction - with the program guaranteeing
the math stays correct at every step, and every step undoable.

That splits the project in two:

- **Phase 1 - the editor.** Type mathematics as fast as you type text, in a structure that knows it
  is mathematics. **Done.**
- **Phase 2 - the meaning.** Give those formulas an AST, a type system, and a set of checked
  transformations, so a manipulation can be *performed* rather than retyped. **Designed, not built.**

Phase 2's intent in one line: it is a **step-checker, not a solver**. The user does the algebra; the
program makes it impossible to reach a wrong result. See `docs/phase2_design.md`.

## Contents

| section | |
|---|---|
| [Status](#status) | what works today, what does not |
| [Concept](#concept) | the tuple AST, and why it is deliberately simple |
| [Architecture](#architecture) | the C++ core and the Lua layer, file by file |
| [Inter-workings](#inter-workings) | how a keystroke becomes pixels, and how the layers depend on each other |
| [Project layout](#project-layout) | the directory tree |
| [Building and running](#building-and-running) | `make`, presentation mode, headless `--test` mode |
| [Tests](#tests) | 50 Lua tests over a headless harness |
| [Documentation](#documentation) | where the design decisions actually live |
| [Conclusion](#conclusion) | where the project stands and what comes next |

## Status

**Phase 1 is complete** - declared so on 2026-09-06, commit *"the user interfacing editor passed
it's stage, time for second stage"*.

**Working:**

- **Structured formula editing** - typing, cursor navigation, selection, delete/backspace across
  every node kind. The edited tree *is* the drawable tree (`mexpr_t` held live), not a separate
  model re-derived on every change.
- **Node kinds**: fractions, superscript/subscript, big operators (`\sum`, `\int`) with limits,
  vertical stacks (matrices, cases), accents and decorations ("dresses"), and brackets that grow to
  fit their contents - round, square, curly, with a procedurally built tall-bracket fallback.
- **Entangled bracket pairs** - the two halves know about each other, so deleting, wrapping,
  rescaling and cascading all keep them consistent.
- **Undo / redo**, and **save / load** of the whole document.
- **LaTeX in both directions** - copy out, edit elsewhere, paste back. Round-trip stable and pinned
  by tests.
- **Multiple boxes** stacked vertically against a left rail, click to activate, click the margin to
  add another.
- **Digraph input methods** - `>=` becomes `\ge`, `!=` becomes `\not =`, `..` becomes `\cdot`, and
  so on; `\sqrt{x}` is rewritten to `(x)^{1/2}` on the way in.
- **Zoom**, per-size baseline alignment, and line-wrapping across the window's right edge.
- **Computer Modern + AMS font loading**, with real glyph metrics.
- **Headless operation** - the app can run with no visible window and be driven over a TCP pipe,
  including taking screenshots. This is how a coding session tests it without touching the
  developer's screen.
- **An input "flight recorder"** and a **frame profiler**, both written after real incidents.

**Not there yet:**

- **Meaning.** Formulas are glyph structure, not mathematics. Nothing connects the editor to
  `ast.lua` yet - that bridge (`mexpr_ast.lua`) is designed in `docs/phase2_design.md` and does not
  exist.
- **The transform engine** (`transforms.lua`) - term-dragging is intentionally unfinished. It is
  exploratory design work, not a bug to fix; do not fill in the remaining cases without asking.
- **Roughly 18 LaTeX macros** are still dropped silently on paste (`\ast \oplus \otimes \vdots
  \langle \lfloor \quad \sin \lim` and friends). Deliberately deferred as a paste-from-outside
  nuisance - though phase 2 raises their priority, since some of them stop being decoration and
  start being names.
- `ast.lua` itself is closer to a stub than a finished component; four concrete defects are recorded
  in `docs/phase2_design.md` section 15, unfixed on purpose until something needs them.

## Concept

Expressions are encoded as simple tuples, each carrying a unique id so it can be referenced, copied
and targeted by a transform:

```
(=, a1, a2)              equality
(+, a1, a2, a3, ...)     sum
(*, a1, a2, a3, ...)     product
(/, a1, a2)              division
(^, a1, a2)              exponentiation
(N, m, n, sign)          rational number m/n
(@, f, a1, ...)          function call
(#, name)                named variable
(&, id)                  variable reference
(V, ...)  (M, m, n, ...) vector, matrix
```

The AST stays dead simple; all the "how do I draw this" and "how do I legally rearrange this" logic
lives in Lua. The **id is the real identity** of a variable - not its name. Two variables can both
draw as `c` and be entirely different things, told apart by scope on screen and by id in the code.

## Architecture

Two layers, bridged by `virt_composer` (a sibling project at `../utils/`) which exposes C++ objects
and methods to Lua.

### C++ core - rendering, platform, and instrumentation

| file | |
|---|---|
| `char_draw_composer.h` | `fontset_t`: font loading, `(size, code)` -> glyph, drawing and measuring |
| `math_expr_composer.h` | `mexpr_t`: the drawable node tree and all layout (`mexpr_binexpr`, `mexpr_frac`, `mexpr_supsub`, `mexpr_bigop`, `mexpr_bracket_left`/`_right`, `mexpr_merge_h`/`_v`) |
| `imgui_composer.h` | ImGui bindings exposed to Lua |
| `app_mode.h` | presentation mode vs `--test` mode, and the file-path prefixing that keeps them apart |
| `debug_input_pipe.h/.cpp` | headless driving: a TCP line protocol on `127.0.0.1:47821`, plus `screenshot` and `quit` |
| `async_log_composer.h` | logging from a writer thread, so a keystroke never costs a syscall |
| `perf_composer.h` | per-frame profiler with a worst-frame snapshot |
| `main.cpp` | GLFW/ImGui init, Lua state setup, main loop |

Every long-lived object derives from `vc::object_t` (in `../utils/virt_object.h`) - a `shared_ptr`
reference type with a private-tag constructor, so instances are only ever built through a class's
own `create()` factory.

### Lua layer - the editor and the math model (`scripts/`)

| file | |
|---|---|
| `mformula_new.lua` | **the structured expression editor.** Holds `mexpr_t` itself as the live edited tree, rather than a parallel model re-derived on every change |
| `mformula_latex.lua` | LaTeX-subset serialization for that tree - `to_latex()` and `from_latex()`, both directions |
| `editor.lua` | the flat text/glyph-stream editor; formulas embed inline in the flow like one wide glyph |
| `content.lua` | the box-management shell - independent boxes, the left rail, click-to-activate |
| `mexpru.lua` | wraps the raw `vc.mexpr_*` creators so every node carries a Lua table in its `u` field; owns `slot_atom`, which every row walk must use |
| `char.lua` | the glyph catalog - ASCII, LaTeX-named symbols, Greek, bracket pieces - mapped onto the Computer Modern and AMS font files |
| `ast.lua` | the tuple AST: namespaces, copy, (de)serialization, LaTeX export |
| `mexpr.lua` | the older `ast -> mexpr` path; **not on any live code path** and carrying a known dead bracket signature |
| `transforms.lua` | where the term-dragging algebra will live - design notes plus unfinished code, deliberately |
| `input_recorder.lua` | the flight recorder: one line per distinct input event, written by the async log thread |
| `prof.lua` | Lua front end for `perf_composer.h`; `prof.wrap()` instruments a function without touching its call sites |
| `main.lua` | entry points called by `virt_composer` |

## Inter-workings

### A keystroke, end to end

```
  ImGui input                                                       main.cpp
      |
      v
  content.lua           which box is active?
      |
      v
  editor.lua            flat glyph stream; a formula is one wide item in the flow
      |                 (while a formula is active, ALL input goes to it)
      v
  mformula_new.lua      edits the live mexpr_t tree; a horiz cannot be mutated in
      |                 place, so an edit rebuilds it and propagate_rebuild() splices
      |                 the result up to the root
      v
  mexpru.lua            every node made here carries a Lua table in `u`
      |
      v
  math_expr_composer.h  layout: position children, compute bounding boxes
      |
      v
  char_draw_composer.h  glyph lookup + ImGui draw calls
```

### How the layers depend on each other

- **The edited tree is the drawn tree.** `mformula_new.lua` holds `mexpr_t` directly. There is no
  separate Lua model to fall out of sync - the cost is that every edit is a rebuild-and-splice,
  because `mexpr_merge_h` recomputes every child's offset.
- **`u` is where all per-node bookkeeping goes.** `mexpru.lua` exists so that a C++ node can carry
  Lua state (its `kind`, its bracket peer, and so on) without adding fields to the C++ type.
- **`mexpru.slot_atom` is mandatory for every row walk.** A bracket's closing half is frequently a
  superscript *base* - `(a)^2` puts the `)` inside the supsub, invisible to any walk reading
  `children` directly. That single blind spot produced **seven** separate live bugs during phase 1.
  Any new walk must go through it.
- **LaTeX is the way content leaves and re-enters the editor**, which is why round-trip stability is
  tested rather than assumed. Under phase 2 it stops being a convenience and becomes correctness.
- **`ast.lua` is currently an island.** Nothing in the live editor touches it. Connecting it is
  exactly what phase 2 is.

## Project layout

```
math_writer/
├── main.cpp                    Entry point: ImGui/GLFW init, Lua state setup, main loop
├── char_draw_composer.h        Font loading, glyph metrics, character drawing
├── math_expr_composer.h        Expression tree, layout, and drawing
├── imgui_composer.h            ImGui bindings for Lua
├── app_mode.h                  Presentation vs --test mode
├── debug_input_pipe.h/.cpp     Headless input pipe, screenshots, clean quit
├── async_log_composer.h        Async (writer-thread) logging
├── perf_composer.h             Frame profiler
├── scripts/                    The Lua layer - editor, glyph catalog, AST, LaTeX (see above)
├── tests/                      Headless harness + 50 Lua tests
├── docs/                       phase2_design.md, plus reference PDFs (TeXbook, Jackowski)
├── fonts/                      Computer Modern + AMS TTFs
├── math_writer.yaml            Config: points virt_composer at scripts/main.lua
├── makefile / linux.makefile / windows.makefile
├── GLFW/, glfw3.dll, glfw3.lib Windows build's bundled GLFW 3.4 headers + import lib
├── experiment_copac/           A separate small experiment, its own main and makefile
└── old/                        Two earlier, abandoned attempts at this project
```

### External dependencies (sibling checkouts, not vendored here)

```
../imgui/     Dear ImGui
../implot/    ImPlot
../utils/     virt_composer - the Lua<->C++ interop framework this project is built on
```

Nothing here fetches or vendors them; they must exist as siblings of this directory.

## Building and running

```bash
make            # root makefile dispatches to linux.makefile or windows.makefile based on OS
./main.exe      # Windows; ./a.out on Linux
```

Also requires a system GLFW, OpenGL and Lua.

### Two run modes

- **no arguments - presentation mode.** The visible instance. Real window, no debug pipe, files
  where they have always been.
- **`--test` - the instance a coding session drives.** The window is never shown, the debug pipe
  listens, and every file it touches moves under `test_run/` (its own save file, logs, ImGui state).
  The two modes share nothing, so a test run cannot overwrite the real document and the two cannot
  fight over the pipe's port.

**If you are an automated session: read `CLAUDE.md` before launching this app.** There are hard
rules about never showing the window, never stealing focus, and never leaving the process to be
killed rather than quit cleanly. They exist because each was violated once.

## Tests

```bash
python tests/run_tests.py              # build (if needed) + run everything
python tests/run_tests.py navigation   # only tests whose filename contains "navigation"
python tests/run_tests.py --list       # list discovered tests without running them
```

50 tests live in `tests/lua/*.lua`, each a `run_test()` that requires `scripts/*.lua` the same way
the real app does. A small headless C++ harness (`tests/harness/`) registers the same Lua bindings
the app registers and runs them with no windowing involved. Adding a test is dropping a new
`tests/lua/test_*.lua` - no registration needed. See `tests/README.md`.

**What the tests are for**, because it shapes how they are written: a test here raises an *alarm* so
that a later contradiction with an older assumption gets caught. It is not proof of correctness. So
tests carry long comments recording the **assumption** and why it held - because when one fires, the
next reader has to judge whether the contradiction is a bug or a deliberate change. A green suite
means "what I asserted still holds", never "it works".

## Documentation

- **`docs/phase2_design.md`** - the design of phase 2, and by far the most important document here.
  It records decisions that are not derivable from any code, because there is no code for them yet:
  the three editors and the one-way promotion door, immutable cells forming a proof DAG, why
  `mexpr -> ast` must be direct rather than routed through LaTeX, how equality is decided by
  normalization, what is trusted and what is not, and what it would take to talk to Lean. **Read it
  before touching `ast.lua`, `mexpr.lua` or `transforms.lua`.** All of it is provisional.
- **`CLAUDE.md`** - how to work in this repo: editing rules, build gotchas, and the hard rules about
  running the app headlessly.
- **`tests/README.md`** - the harness and how to add a test.

## Conclusion

The editor half is finished and behaves: mathematics can be typed, navigated, saved, undone, and
carried in and out as LaTeX, with 50 tests holding the assumptions in place.

What it cannot do is *understand* any of it. Every formula is still glyph structure - a beautiful
arrangement of Computer Modern with no notion that `a + b` is a sum. Phase 2 is the whole distance
from there to a program that can be handed a term and asked to move it legally, and its design is
written down in full in `docs/phase2_design.md` while none of it is implemented.

The nearest concrete step is the bridge, `mexpr_ast.lua`: one walk that turns the live editor tree
into an AST, its types, its variable dependencies, and the mapping between the two - which is what
everything downstream reads.

## License

MIT (see `LICENSE`). Bundled fonts carry their own licenses under `fonts/licences/`.

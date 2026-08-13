# Math Writer

An interactive, WYSIWYG mathematical expression editor built on [Dear ImGui](https://github.com/ocornut/imgui). The goal isn't just to *render* formulas — it's to let you point at a term inside an expression and legally move it: drag a term out of a sum, factor it out of a product, cancel it across a fraction, all while the math stays correct and every step is undoable.

## Status

Early, active development. Today the app boots straight into a hardcoded demo (`main.lua`'s `test_draw()`) that builds a handful of ASTs and expression trees and renders them — there's no editing yet.

**Working:**
- Font loading and glyph rendering (Computer Modern TTFs), with per-size baseline alignment
- Expression layout: binary/unary operators, superscript/subscript, fractions, big operators (∑, ∫) with bounds, brackets that grow to fit their contents (round/square/curly, including a procedurally-built tall-bracket fallback), horizontal/vertical merging
- Line-wrapping of expressions across the window's right edge
- A tuple-based AST (`ast.lua`) with namespaces, copy, serialize/deserialize, and LaTeX export
- AST → drawable-expression conversion (`mexpr.lua`)

**Not there yet:**
- Any user input/editing — everything currently drawn is constructed in Lua code, not by interacting with the app
- Undo/redo
- Save/load
- The actual term-dragging transform engine (`transforms.lua`) — the AST node types and case-by-case rules are sketched out in comments, but the code is intentionally unfinished

## Concept

From the project's own design notes (`main.cpp`): expressions are encoded as simple tuples — `(=, a1, a2)` for equality, `(+, a1, a2, ...)` for a sum, `(N, m, n, sign)` for a rational number, and so on — each carrying a unique id so it can be referenced, copied, and targeted by a transform. The idea is to keep the AST itself dead simple and push all the "how do I draw this" and "how do I legally rearrange this" logic into Lua, so behavior can be scripted and iterated on without recompiling.

This is stated to be the third rewrite of the underlying model, after two earlier attempts (preserved under `old/`) turned out too complicated to serialize or transform cleanly.

## Architecture

Two layers:

**C++ core** (`char_draw_composer.h`, `math_expr_composer.h`) — the rendering engine, exposed to Lua through the `virt_composer` framework (a sibling project at `../utils/`):
- `fontset_t` owns the loaded fonts and maps a `(size, code)` pair to a glyph — drawing and measuring one.
- `mexpr_t` is a tree of drawable nodes (symbol / line-strip / empty-box / internal), each with a bounding box relative to its own baseline. Layout functions (`mexpr_binexpr`, `mexpr_frac`, `mexpr_supsub`, `mexpr_bigop`, `mexpr_bracket`, `mexpr_merge_h`/`_v`) position child nodes by hand-tuned baseline/spacing math.
- Every long-lived object derives from `vc::object_t` (in `../utils/virt_object.h`), a `shared_ptr`-based reference type with a private-tag constructor — instances are only built through a class's own `create()` factory.

**Lua layer** — the actual math model and glue:
- `ast.lua` — the tuple-based AST, namespaces, (de)serialization, LaTeX export
- `char.lua` — the glyph catalog (ASCII, LaTeX-named symbols, Greek letters, bracket-piece descriptors) mapped onto Computer Modern font files
- `mexpr.lua` — walks an AST and calls into the C++ layer to build a drawable `mexpr_t` tree
- `transforms.lua` — where the term-dragging algebra will live; currently design notes plus unfinished code, not wired up anywhere yet
- `main.lua` — the app's entry points (`test_init`, `test_draw`), currently just a demo

### Data flow

```
main.lua (test_draw)
    → ast.lua            build/modify the AST
    → mexpr.lua           AST node  →  mexpr_t tree
    → math_expr_composer.h   layout: position child nodes, compute bounding boxes
    → char_draw_composer.h   glyph lookup + ImGui draw calls
```

## Project layout

```
math_writer/
├── main.cpp                    Entry point: ImGui/GLFW init, Lua state setup, main loop
├── main.lua                    Lua entry points (test_init / test_draw demo)
├── char_draw_composer.h        Font loading, glyph metrics, character drawing
├── math_expr_composer.h        Expression tree, layout, and drawing
├── ast.lua                     AST node types, construction, (de)serialization, LaTeX export
├── char.lua                    Glyph catalog and font-set loading
├── mexpr.lua                   AST → mexpr_t conversion
├── transforms.lua              Algebraic term-dragging (WIP, unfinished)
├── math_writer.yaml            Config: points virt_composer at main.lua
├── makefile / linux.makefile / windows.makefile
├── GLFW/, glfw3.dll, glfw3.lib Windows build's bundled GLFW 3.4 headers + import lib
├── fonts/                      Computer Modern + AMS TTFs used for rendering
├── docs/                       Reference PDFs (The TeXbook, Jackowski's TeX typography paper)
└── old/                        Two earlier, abandoned attempts at this project
```

### External dependencies (sibling checkouts, not vendored here)

```
../imgui/     Dear ImGui
../implot/    ImPlot
../utils/     virt_composer — the Lua↔C++ interop framework this project is built on
```

## Building & Running

```bash
make        # root makefile dispatches to linux.makefile or windows.makefile based on OS
./a.out     # ./a.exe on Windows
```

Requires `../imgui`, `../implot`, and `../utils` to exist as sibling directories, plus a system GLFW, OpenGL, and Lua. See `CLAUDE.md` for build environment gotchas if something that used to link stops linking.

## License

MIT (see `LICENSE`). Bundled fonts carry their own licenses under `fonts/licences/`.

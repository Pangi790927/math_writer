# TODO

Work that is decided but not built. Phase 2's design lives in `docs/phase2_design.md`; this file is
for the editor-side work that does not belong there.

Provenance note: most of this came out of a 2026-09-06 review of `old/` — the two abandoned
rewrites — checking what those versions wanted that the current one does not have. The items kept
are listed here; the ones deliberately dropped are recorded at the bottom so the same review does
not get run twice.

---

## 1. Bold and italic in text boxes

**Status: regression.** `old/comments.h` had this working, with `is_bold` / `is_italic` state and
live keybinds, and `old/main.cpp`'s own comment blocks demonstrate it ("This is bold text. This is
italic text."). It did not survive the port to `editor.lua`.

- `Ctrl+B` toggles bold, `Ctrl+I` toggles italic, applying from the cursor onward the way the old
  box did.
- The fonts are already loaded and unused: `char.lua` maps `capi.FONT_BOLD` to `cmbx10.ttf` and
  `capi.FONT_ITALIC` to `cmti10.ttf`.
- `Ctrl+B` is currently unclaimed. `mformula_new.lua`'s accent block (around line 3350) already
  records that it was left free "for a bold that does not exist yet" — the bar accent went to
  `Ctrl+G` specifically to keep it available.
- **Not wanted:** `old/comments.h`'s third styling keybind, `Ctrl+-` / `Ctrl+=` for a per-character
  font level. Ctrl+MouseWheel zoom already covers that ground.

Reference implementation if it helps: `git show HEAD:old/comments.h`, the `Ctrl+B` / `Ctrl+I`
handlers.

---

## 2. Radial menu for creating a box

**Replaces the current insert-immediately behaviour.** Today `Ctrl+N` (`content.lua:328`) and a
click in the left rail zone (`content.lua:404`) both insert a text box straight away. Neither can
express *which kind* of box, and there are about to be three kinds (text, formula, definition — see
`docs/phase2_design.md` section 1).

### Behaviour

Two entry points, both opening the same menu:

- **`Ctrl+N`** — the menu opens at the position where the new box would appear.
- **Clicking the left rail line** — the menu opens there, and selection is by **drag-click**: press,
  drag out into a sector, release to choose.

### Geometry

```
                    +-------------+
                    |    TEXT     |      gray
                    |   (above)   |
              +-----+------+------+-----+
              |    ( center circle )    |     r  = 50px
              |  FORMULA  |  DEFINITION |     R  = 3.0 * r  = 150px
              |   blue    |    green    |     R' = 3.2 * r  = 160px on hover
              +-------------------------+
```

- a small circle at the centre, radius **50px**
- **three sectors** radiating outward from it, **120 degrees each**, outer radius **3x** the centre
  circle's radius
- one sector points **up**; the other two are the **left and right** ones
- colours: **gray = text box**, **blue = formula box**, **green = definition box**
- a hovered sector grows to **3.2x** the centre radius
- releasing / clicking on a sector creates that kind of box at the menu's position

**One thing to confirm before implementing:** with one sector centred straight up and all three
120 degrees wide, the other two necessarily centre on lower-left and lower-right rather than
horizontal left and right. That is the only arrangement three equal sectors allow with one pointing
up, so it is assumed here — say if the intent was a different split.

### Depends on

Formula and definition boxes existing as box kinds. `content.insert_box` (`content.lua:109`) is
already flagged in its own comment as "the seam for adding other box kinds later", so the menu can
be built against a stub that creates a text box for all three sectors, and wired up as the other
kinds arrive.

---

## 3. Fraction-in-fraction spacing

**Open across all three rewrites.** `old/main.cpp`, verbatim:

> /* TODO: fix the fact that the additional space is taken into account for next elements
> (example fractions in fractions) */

Its two siblings in that same block are marked DONE; this one never was. `CLAUDE.md` independently
notes that fraction layout "has open rough edges noted in comments" — likely the same defect,
surviving two ports.

Worth knowing: `old/math_drawing.h` had a global `mathd_draw_boxes` flag that drew every node's
bounding box. `math_expr_composer.h` has no equivalent, and it is the obvious tool for this bug.

---

## Notation reachable with what exists

Recorded because `old/main.cpp` listed these as missing elements and the review flagged them as
gaps — they are not. Each is reachable today with existing machinery plus a catalog row in
`char.lua`, so none needs a new node kind:

| wanted | how |
|---|---|
| `d/dx` | a fraction of ordinary glyphs |
| `f'`, `f''`, `f^(n)` | a supsub with a prime glyph in the superscript |
| transpose | a supsub with `T` |
| `min`, `max`, `argmin`, `argmax`, `lim` | operator names — the same single-atom fix as `\sin` / `\log`, see `docs/phase2_design.md` section 10 |
| system of equations / inequations | a curly bracket wrapping a `vert` |
| matrix determinant | a bar bracket wrapping a `vert` |
| abs / norm | already done — `MEXPR_BRACKET_BAR` |

The AST side of several of these is a different question and belongs to phase 2.

---

## Deliberately not doing

From the same `old/` review, so it is not re-proposed:

- **Per-box context menu.** `old/content.h` drew a hamburger at each box's top-right corner opening
  a popup. Not wanted.
- **Font-remapping files and per-object drawing-rule files.** `old/main.cpp`'s top TODO wanted
  characters and math objects declared in data files with namespaces, names, scripted drawing rules
  and composition rules. Superseded — the current view of how objects get declared is
  `docs/phase2_design.md` sections 6 and 10.
- **Per-character font levels** (`Ctrl+-` / `Ctrl+=`). Covered by Ctrl+MouseWheel zoom.
- **Fast/circular select menu for symbols.** The radial-menu idea landed on box creation instead
  (item 2 above); there is no plan for a symbol picker.
- **Configurable keybinds.** Still wanted eventually — `mformula_new.lua` notes they are "due to
  become customisable" — but not scheduled.

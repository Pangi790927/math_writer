# TODO

Work that is decided but not built. Phase 2's design lives in `docs/phase2_design.md`; this file is
for the editor-side work that does not belong there.

Provenance note: most of this came out of a 2026-09-06 review of the two abandoned rewrites, which
were deleted in commit `1e201f7` ("old is superseeded") once the review was done. **This file is
written to stand on its own** — whatever those versions had that is still wanted is described
here in full, so nothing below needs the deleted files to be understood. Filenames from them are
quoted only as attribution. The items deliberately dropped are recorded at the bottom, so the same
review does not get run twice.

---

## 1. Bold and italic in text boxes

**Status: regression.** The second rewrite had this working, and its own saved comment blocks
demonstrate it ("This is bold text. This is italic text."). It did not survive the port to
`editor.lua`.

### What it did, and the one behaviour worth keeping

- `Ctrl+B` toggled bold, `Ctrl+I` toggled italic, applying from the cursor onward.
- **The two were mutually exclusive** — setting bold cleared italic and vice versa. That was not
  an oversight: the Computer Modern set here has `cmbx10` (bold) and `cmti10` (italic) and **no
  bold-italic face**, so "both" was never a state that could be drawn. Keep the exclusivity unless
  a bold-italic font is added.
- Styling was stored **per character**, as two bits (`bold:1`, `ital:1`) in the same bitfield that
  held which font and which size level that character used — not as a span or range model.

### What this needs that does not exist yet

`char.lua` already maps `capi.FONT_BOLD` to `cmbx10.ttf` and `capi.FONT_ITALIC` to `cmti10.ttf`,
and both are loaded and unused. The obstacle is downstream of that:

- `editor.lua` stores an item as `{code = <ncod>}` and draws it with
  `fontset:char_draw({size = eff_sz, code = item.code}, ...)`.
- in `char_draw_composer.h` the drawn `char_t` is only `{size, code}`, and the font is resolved
  inside C++ as `fonts[c.size-1][code_to_font_loc[c.code].font-1]`.

So **an ncod maps to exactly one font**, and there is no way from Lua to draw the same character in
a different face. The old version did not hit this because its own `char_t` carried `fnum`, `bold`
and `ital` per character.

Two ways out, and the choice is not Claude's to make (`CLAUDE.md`, law 1 — ask for what is
missing from C++ rather than working around it):

1. **expose a font override** on `char_draw`/`char_get_sz` — a `char_t` field, or a fontset
   method that draws a given code in a given face; or
2. **add catalog rows** for the bold and the italic variant of every letter, giving each its own
   ncod — no C++ change, but it multiplies the ncod space and pushes a display concern into
   character identity.

**Open question for the user: which one?** Nothing should be built here until that is answered.

`Ctrl+B` is currently unclaimed and was deliberately kept free — `mformula_new.lua`'s accent
block (around line 3350) records that the bar accent went to `Ctrl+G` specifically to leave
`Ctrl+B` for "a bold that does not exist yet".

**Not wanted:** that version's third styling keybind, `Ctrl+-` / `Ctrl+=`, which stepped a
character through five discrete font levels. Ctrl+MouseWheel zoom already covers that ground.

---

## 2. Radial menu for creating a box — DONE 2026-09-06

**Built.** `Ctrl+N` and a press in the left rail zone both open the menu instead of inserting a
text box outright; three kinds spawn (text, formula, definition), and the two new ones are
placeholders with no controls. What follows is the spec as built, kept because the geometry and
the two gestures are decisions, not accidents.

Implementation notes worth keeping:

- **A box's kind is carried by the ABSENCE of `box.editor`, not by a `kind` check.** Every place
  that types into, measures, rescales or serialises a box already reaches through `box.editor`, so
  a nil there makes a box inert everywhere at once. `tests/lua/test_box_kinds.lua` pins that
  assumption and says what breaks if formula/definition boxes ever get an editor of their own.
- **The save format grew a kind prefix** (`text 12\n...` where it was a bare `12\n...`). A bare
  length still loads, as a text box, so old documents are unaffected.
- **Wedges are drawn as half-overlapping opaque quads.** No arc or convex-polygon fill is exposed
  to Lua, so each wedge is a strip of `AddQuadFilled`. Two quads meeting exactly on a shared edge
  show a thin transparent seam (ImGui antialiases every filled edge), hence the overlap; the
  overlap in turn requires the colours be fully opaque, or it blends twice and shows as a brighter
  spoke instead. Both were seen on screen before being fixed.
- **A rail drag arms at 24px from the PRESS POINT, not from the menu centre.** The menu is clamped
  to stay on screen, so pressing on the rail (x=64) puts the centre at x=168 and leaves the cursor
  already inside the lower-left wedge. Measuring from the centre made a bare rail click spawn a
  formula box instantly.

Still open here: formula and definition boxes do nothing at all beyond being coloured. What they
are eventually for is `docs/phase2_design.md` section 1 — immutable, checked cells behind a
one-way promotion door.

### Behaviour

Two entry points, both opening the same menu:

- **`Ctrl+N`** — the menu opens at the position where the new box would appear, and stays open:
  click a sector to choose. There is no button held down, so there is nothing to release.
- **Pressing the left rail line** — **drag-click**: press, drag out into a sector, release to
  choose. A press that is released without travelling 24px is treated as a plain click and leaves
  the menu open in the click-then-click mode above, rather than cancelling — a rail click used to
  insert a box, and having it appear to do nothing at all would read as broken.

### Keyboard

The arrows point at where each wedge actually sits on screen, so the mapping needs no learning:

| key | selects |
|---|---|
| Up | gray — text box (the wedge centred straight up) |
| Left | blue — formula box (lower-left) |
| Right | green — definition box (lower-right) |
| Down | the centre "x" — cancel |
| Enter / keypad Enter / Space | commit whatever is selected |
| Escape | cancel outright, from any state |

Moving the mouse drops the keyboard selection so hover takes back over; pressing an arrow in the
same frame as a mouse twitch still wins. With nothing selected, Enter/Space closes without
creating anything, same as choosing the "x".

**The centre gets the same "about to be picked" feedback the wedges do.** It cannot grow outward —
its radius is where the wedges start — so instead the X itself grows: longer arms, thicker
strokes, a white cross, a white ring and a lighter fill. Active on mouse hover over the centre as
well as on Down. Keep the centre's lit colour NEUTRAL: the wedges are gray/blue/green and a tinted
centre reads as one of them (the first attempt came out navy, because the packing is 0xAABBGGRR
and it was written as though it were 0xAARRGGBB).

Choosing a text box makes it active; choosing the other two does not, since there is nothing to
type into.

### Geometry

```
                         TEXT
                         gray                 r  = 50px   centre circle
                     (centred on              R  = 3.0 * r = 150px   sector radius
                      straight up)            R' = 3.2 * r = 160px   hovered sector
                    \    90 deg    /
                     \     |      /
                      \    |     /
                       \   |    /
            150 deg -----( r )----- 30 deg
                       /       \
                      /         \
             FORMULA /           \ DEFINITION
              blue                  green
            (centred 210)         (centred 330)
```

- a small circle at the centre, radius **50px**
- **three sectors** radiating outward from it, **120 degrees each**, outer radius **3x** the centre
  circle's radius
- the first sector is **centred on the up direction** — straight up, not the up-right diagonal
  (confirmed 2026-09-06). Since all three are 120 degrees wide, that fixes the other two: they
  centre on **210 and 330 degrees**, i.e. lower-left and lower-right.
- sector boundaries therefore fall at **30, 150 and 270 degrees**
- colours in that order: **gray = text box** (up), **blue = formula box** (left),
  **green = definition box** (right)
- a hovered sector grows to **3.2x** the centre radius
- releasing / clicking on a sector creates that kind of box at the menu's position

### Colours

Both the wedges and the spawned box's background come from one table, `KIND_COLORS` in
`content.lua`. Note ImGui packs colours as **0xAABBGGRR** — alpha, then blue, green, red — which is
easy to get backwards; each entry has its RGB spelled out beside it.

---

## 3. Fraction-in-fraction spacing

**Open across all three rewrites.** The second rewrite's own TODO, verbatim:

> /* TODO: fix the fact that the additional space is taken into account for next elements
> (example fractions in fractions) */

Its two siblings in that same block were marked DONE; this one never was. `CLAUDE.md` independently
notes that fraction layout "has open rough edges noted in comments" — likely the same defect,
surviving two ports.

Worth knowing while chasing it: that version carried a single global flag which, when set, made
every node draw its own bounding box. `math_expr_composer.h` has no equivalent today, and it is the
obvious tool for a spacing bug — a node claiming more height than it draws is visible
instantly, and close to invisible otherwise.

---

## Notation reachable with what exists

Recorded because the earlier rewrites listed these as missing elements and the review flagged them
as gaps — they are not. Each is reachable today with existing machinery plus a catalog row in
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

From the same review, so none of it gets re-proposed:

- **Per-box context menu.** The earlier version drew a hamburger button at each box's top-right
  corner, opening a popup of per-box options. Not wanted.
- **Font-remapping files and per-object drawing-rule files.** The earlier top-level TODO wanted
  characters and math objects declared in *data files* carrying namespaces, names, a scripted
  drawing rule per object, and composition rules (arity, associativity). Superseded — the
  current view of how objects get declared is `docs/phase2_design.md` sections 6 and 10.
- **Per-character font levels** (`Ctrl+-` / `Ctrl+=`). Covered by Ctrl+MouseWheel zoom.
- **Fast/circular select menu for symbols.** The radial-menu idea landed on box creation instead
  (item 2 above); there is no plan for a symbol picker.
- **Configurable keybinds.** Still wanted eventually — `mformula_new.lua` notes they are "due to
  become customisable" — but not scheduled.

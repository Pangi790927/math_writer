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
- **`imgui_composer.h` is a LEAF - Claude may edit it freely.** The blanket "don't touch C++" rule
  above is not about the language, it is about the CORE: `char_draw_composer.h`,
  `math_expr_composer.h`, `virt_composer` and `main.cpp` are where the project's real structure
  lives, and a session does not have the full picture of it. The ImGui wrapper is the opposite -
  it only exposes ImGui to Lua, nothing depends on its shape, and a wrong export is visible and
  reversible immediately. User's own words, verbatim, 2026-09-07: "You can edit the imgui wrapper,
  it's ok, it's a leaf of the project, this is a more unclear term so don't give it too much
  thought, but that is why you are not allowed to touch c++ freely is because it is the core of the
  project, but you don't have the full image, so I actually put the core into the c++ part and tell
  you generically not to touch c++". So: leaf = edit; core = still suggest-don't-edit.
- **Don't change how the app BEHAVES unless told to, explicitly, for that behaviour.** Refactors
  that route existing input through a new layer must preserve what every key does today, including
  the accidental cases. User's own words, verbatim, 2026-09-07: "don't change how the app behaves
  with those changes, not anywhere else than I say so explicitly at least, ask me iif something
  should stay or not". This killed the "make modifier matching exact" idea (2026-09-07): making
  bindings exact would have silently retired Shift+Enter, Shift+Space, Ctrl/Shift+Backspace and
  AltGr+letter Greek, none of which anyone asked to remove - see the keymap registry's own
  three-state modifier fields, which exist to reproduce today's behaviour exactly.
- **`.lua` files are Claude's domain.** You may write and edit these directly — but ask first
  before making a change, don't just do it unprompted. This is the one carve-out from the rule
  above.
- **Documentation (`README.md`, `CLAUDE.md`) is Claude's to write directly**, no need to ask.
- **git structure is read-only.** `git status`/`diff`/`log`/`show` etc. are fine any time. Never
  `add`/`commit`/`push`/`stash`/`checkout`/`reset --hard` or anything else that touches history or
  the index.
## LAWS FOR CLAUDE

The heading itself is now a citation, not commentary — user's own words, verbatim, 2026-09-08:
"LAWS FOR CLAUDE will be a citation now, you keep removing it, so I will make it a citation so that
you will stop and keep it." All caps, exactly as given — his own words, verbatim, same message:
"all caps, all citations are all caps." Per the amendment to Law 3 below, that fixes this exact
wording and case; don't reword or re-case it to "Three Laws", "Laws of Claude", "Laws for Claude",
or anything else in a future edit.

The laws Pangi set for how Claude works, meant to spread and apply the same way in every repo of
his — numbered, not capped at any count, so a new one can be added later without renumbering the
header. See the amendment to Law 3 for how a citation may travel vs. how commentary may.

1. **Ask for what you don't have.** When a lower layer (C++/`virt_composer` here) doesn't expose a
   capability the current layer needs, ask before working around it — don't silently invent a
   workaround and build further logic on top of it.

   User's own words, verbatim, 2026-09-04: "ASK FOR WHAT YOU DON'T HAVE FROM C++, DON'T IMPLEMENT
   IT YOURSELF WITHOUT GUIDANCE, DON'T ASSUME YOU CAN'T HAVE IT."

   Hit directly that day: `mexpru.lua`'s `same(a, b)` papers over `mexpr_t` having no `__eq`
   registered by comparing `tostring()` output instead; new bracket-pairing code got built on top
   of that hack without ever questioning whether real identity comparison could just be exposed
   from C++ — don't repeat that.

   Second occurrence, a different repo: user's own words, verbatim, 2026-09-08, `bbb_repo` project:
   "YOU ARE TO NOTIFY ME IF SOMETHING DOESN'T FIT BECAUSE OF A SMALL CHANGE, NO MORE DUPLICATING
   CODE FOR NO REASON!!!!!!!" If an existing class/utility/function is a near-fit for a new need but
   has one hardcoded assumption blocking reuse, say so and extend it — don't silently write a
   second, parallel mechanism that duplicates most of the same logic to route around the mismatch.
   What this looked like in practice: `LockedCache` only ever wrote to one hardcoded directory;
   instead of adding a `base_dir` parameter and reusing it, a whole separate sentinel-file mechanism
   got invented from scratch for a need that was 90% identical to something already built two
   minutes earlier in the same session.

2. **Contradictions are the author's to resolve.** On spotting a contradiction in what the user has
   said, surface it and ask; do not pick a side quietly.

   User's own words, verbatim, 2026-09-04: "ANY CONFLICT/CONTRADICTION OF WHAT I SAY IS SOLVED BY
   ME, SO IF YOU DETECT A CONTRADICTION, ASK ME!" — clarified scope, also verbatim: "a contradiction
   in what I say of course" (i.e. this message vs. an earlier one, not a mismatch between the user's
   intent and what the code actually does — that's ordinary review). Never silently pick a side,
   paper over it, or guess which one still holds — surface it and ask. Also in the global
   `~/.claude/CLAUDE.md` ("Working style" section) as the general, all-projects form of this rule.

3. **In a Pangi repo, check these laws are acknowledged, and offer to spread them.** The first time
   in a session you're clearly working in a git repo authored by Pangi (commit history or `git
   config user.name`/`user.email` has "Pangi", case-insensitive), check whether that repo's own
   CLAUDE.md acknowledges the laws in some form. If it doesn't: **tell Pangi, don't silently add
   it** — CLAUDE.md is normally yours to write without asking; this specific case is explicitly
   "remind me", not "just do it". Then offer to add a reference if he wants one started. Once per
   session is enough. This file is that acknowledgement for `math_writer`.

   User's own words, verbatim, 2026-09-04: "if a git is by me (see name Pangi) then you will remind
   me if those three laws are not set, or acknowledged in some way." — and, on why the laws exist at
   all, also verbatim: "this will be the laws for claude, ok? and they would spread through my pc
   and grow, this is the 3rd rule of claude."

   **Amendment — verbatim citation is verbatim; commentary is not.** User's own words, verbatim,
   2026-09-06: "THE ORIGINAL STATEMENT MUST MATCH EXACTLY WHEN COPIED - THIS IS ALSO AN RIGINAL
   CITATION - BUT COMMENTS MAY VARY, INTERPRETATIONS..." When a law spreads into another repo's
   CLAUDE.md, the quoted original statements travel character for character — no tidying, no fixing
   typos, no paraphrase standing in for the quote (including this amendment's own "AN RIGINAL",
   reproduced intact, deliberately). What surrounds a citation — summary, example, scope, file
   pointer — is commentary, and may be rewritten per repo to fit what that repo does. Inside the
   quote marks, nothing moves; outside them, everything may.

   Which quotes count as a citation, resolved 2026-09-08: only the ones in ALL CAPS. User's own
   words, verbatim: "all caps, all citations are all caps." A quote given in lowercase or mixed
   case elsewhere in this file (the git-authorship line and the old "laws for claude" aside in
   Law 3, the scope note in Law 2) is commentary-grade, not locked — reword or drop it freely if a
   repo needs to. User's own words, verbatim, on this exact point: "if a git is by me... — no, all
   caps are the citations that you are not to move, change whatever, the rest I don't care about."

## Build

Needs three sibling checkouts next to this directory: `../imgui`, `../implot`, `../utils`
(the last is `virt_composer`, the Lua↔C++ interop framework this whole project sits on). Nothing
here vendors or fetches them.

```bash
make        # root makefile dispatches to linux.makefile or windows.makefile based on OS
```

## What the tests are FOR

Stated by the user, 2026-09-06: **a test raises an alarm so an eventual contradiction with an older
test or assumption gets caught.** Not proof of correctness - a tripwire across an assumption.

Three consequences that decide how to write and how to react to them:

- **A test asserting behaviour just written is nearly worthless.** It can only confirm itself. The
  ones that earn their keep are OLD. So write down the ASSUMPTION and why it holds, not the output.
  That is why tests here carry long comments: when one fires, the next reader needs to know what
  was assumed in order to judge whether the contradiction is a bug or a deliberate change.
- **When an old test fires, do not just make it pass.** That disarms the alarm silently. Record why
  the assumption stopped holding - `test_latex_roundtrip.lua`'s case4b is the worked example: it
  asserted "a space is dropped" for a real technical reason, and now explains both that reason and
  the decision that overrode it.
- **A test can assert a bug as correct**, and then it actively defends the defect. That happened:
  `test_digraphs.lua` claimed "two atoms, so each can be deleted on its own" as a feature, and it
  was the bug reported the next day. Green means "what I asserted still holds", never "it works".

Two things slipped through phase 1, and both fit the pattern: one had no alarm (nothing runs the
draw path, so a nil-call there was invisible - now covered by `test_no_use_before_define.lua`), and
one had an alarm pointed the wrong way.

## Automated tests

```bash
python tests/run_tests.py    # build (if needed) + run everything; see tests/README.md for options
```

The test logic lives in `tests/lua/*.lua` (each a `run_test()`, requiring `scripts/*.lua` the same
way the real app does); a small headless harness (`tests/harness/`) loads and runs them without
any windowing/GLFW involved. Add new tests by dropping a new `tests/lua/test_*.lua` file - no
registration needed.

## Architecture, quick pointer

C++ core (`char_draw_composer.h` = fonts/glyphs, `math_expr_composer.h` = expression layout) is
exposed to Lua via `virt_composer`. The actual math model lives in Lua: `ast.lua` (the AST),
`char.lua` (glyph catalog), `mexpr.lua` (AST → drawable tree), `transforms.lua` (algebraic
term-dragging, WIP). Full detail and data-flow diagram in `README.md`.

## Where the project is

**Phase 1 (the text editor) is done** — declared so 2026-09-06, commit "the user interfacing
editor passed it's stage, time for second stage". Typing, navigation, brackets, accents, big
operators, undo/redo, save/load and LaTeX in both directions all work; `tests/` covers them.

**Phase 2 is linking the editor to the AST**, and its design is written up in
**`docs/phase2_design.md`** — read that before touching `ast.lua`, `mexpr.lua` or `transforms.lua`.
It records decisions made in conversation that are not derivable from the code: three editors with
a one-way promotion door, immutable cells forming a proof DAG, why `mexpr -> ast` must be direct
rather than routed through LaTeX, how names and subscripts identify, and what would be needed to
talk to Lean. Nothing in it is implemented yet.

## Known WIP / intentionally incomplete

- `transforms.lua` — term-dragging is deliberately unfinished, flagged in-file. Don't fill in the
  remaining cases without asking first; this is exploratory design work still being thought
  through, not a bug to fix.
- Fraction layout (`mexpr_frac` in `math_expr_composer.h`, and its caller in `mexpr.lua`) has open
  rough edges noted in comments.
- `mexpr.lua`'s four `vc.mexpr_bracket()` calls use a signature the C++ no longer has (it split
  into `mexpr_bracket_left`/`_right`). Only reachable from `main.lua`'s dead demo, so harmless
  today — but they must be fixed before `ast -> mexpr -> ast` can serve as a test oracle. See
  that file's own header.
- Roughly 18 LaTeX macros are still dropped silently on paste (`\ast \oplus \otimes \vdots
  \langle \lfloor \quad \sin \lim` and friends). Deferred deliberately as a paste-from-outside
  nuisance; `docs/phase2_design.md` explains why phase 2 raises their priority.

## Debugging

- `DBG()` / `DBG_SCOPE()` (from `../utils/`) write to `logfile.log`, rotated to `logfile.old.log`.
- `main.cpp` calls `ImGui::ShowMetricsWindow()` unconditionally in the main loop.

## Live testing `main.exe` — READ BEFORE LAUNCHING IT

The user runs on two monitors and their **primary monitor is theirs** — they use it for other
things (games included) while a session runs. `main.exe`'s window must **never** appear anywhere
on their screen, and must **never** steal focus, not even for an instant — this was a long,
multi-round point of friction confirmed directly with the user on 2026-09-04. An earlier version
of this section described an elaborate `SetWinEventHook`-based scheme to catch and reposition
windows after the fact — **that whole approach is obsolete, don't use it.** The app already has a
proper, built-in headless mode (`debug_input_pipe.cpp`/`.h`, `imgui_helpers.h`) — use that instead.

**Always launch with `--test`.** Two modes exist (`app_mode.h`, 2026-09-05): no arguments is
PRESENTATION - the instance the developer runs, visible window, no debug pipe, files where they
always were. `--test` is the instance a session drives: window never shown, debug pipe listening,
and every file it touches moved under `test_run/` (its own `math_writer.save`, `logfile.log`,
`input_history.log`, `perf_spikes.log`, `imgui.ini`). The two no longer share anything, so a test
run cannot overwrite the developer's document and the two cannot fight over the pipe's fixed port.

`--test` sets `VC_WINDOW_START_HIDDEN`/`VC_WINDOW_STAY_HIDDEN` itself if they are unset, so the
window cannot appear just because a launcher forgot them. Passing them explicitly still works and
still wins.

```powershell
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = "C:\Users\apangratie\workspace\math_writer\main.exe"
$psi.Arguments = "--test"
$psi.WorkingDirectory = "C:\Users\apangratie\workspace\math_writer"
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$proc = [System.Diagnostics.Process]::Start($psi)
```
- `VC_WINDOW_START_HIDDEN=1` creates the GLFW window with `GLFW_VISIBLE=false` from the start (no
  flash at a default position) — this part already existed before this session.
- `VC_WINDOW_STAY_HIDDEN=1` (added this session) makes `reveal_window()` skip its `ShowWindow`
  call entirely — the window is **never** shown, for the app's whole lifetime. It still renders
  every frame (`glfwSwapBuffers` doesn't care about visibility) — use the `screenshot <path>`
  `debug_input_pipe` command (added this session, writes an uncompressed BMP via `glReadPixels`)
  to see what's on screen, instead of ever showing a real window.
- **`CreateNoWindow = $true` is not optional.** Without it, `main.exe` (a console-subsystem app)
  inherits whatever console the launching process already has — including, in this environment,
  the same terminal window this Claude Code session runs in. `hide_console()` (gated by the same
  `VC_WINDOW_START_HIDDEN`) then hides *that* — i.e. hides the user's own visible terminal, not
  some separate console. This actually happened and badly startled the user. `CreateNoWindow=true`
  means `main.exe` gets no console at all, so `hide_console()`'s `GetConsoleWindow()` returns null
  and it's a safe no-op.
- Never call `SetForegroundWindow` on this window, never bring it forward for a screenshot, and
  don't reintroduce window-hiding/repositioning hacks from the launcher side — the app-side
  mechanism above is simpler and was purpose-built for exactly this (see `debug_input_pipe.h`'s
  own top comment: "without touching the developer's actual input devices or stealing window
  focus"). If it's ever insufficient, extend it there, don't work around it externally.

**End a headless run with the pipe's `quit` command, not `taskkill`.** `quit` raises the same signal
the window's close button does, so the app unwinds through its NORMAL shutdown: `test_shutdown`
writes `test_run/math_writer.save`, and the async log (`async_log_composer.h`) drains and joins its writer
thread. A `taskkill` skips all of that. (It used to also mean
`math_writer.save` needed a `git checkout --` after every run; the `--test` split fixed that at the
root - a test instance no longer writes the real document at all.) Ctrl+Q does NOT work from the pipe: `main.cpp` polls
it with `glfwGetKey()`, which reads the real OS keyboard, and a hidden window ignores `WM_CLOSE`
too - `quit` (added 2026-09-05) is the only clean exit available headlessly. (That quit key was
ESCAPE until 2026-09-07; it moved to Ctrl+Q because Escape is a meaningful in-app key in three
places - leaving a formula, closing the radial menu, leaving a definition's shorthand - so pressing
it to back out of a formula also closed the application. The pipe consequence is unchanged either
way.)

Driving input still goes through the same TCP pipe (127.0.0.1:47821, see `debug_input_pipe.cpp`
for the line protocol) — `io.AddKeyEvent`/`AddInputCharacter`/etc. only ever touch this process's
own ImGui state, never real OS-level input, so none of this ever reaches anything else running on
the machine.

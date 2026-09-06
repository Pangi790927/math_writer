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
- **When Lua needs a capability C++/`virt_composer` doesn't expose, ask before working around it.**
  User's own words, verbatim, 2026-09-04: "ASK FOR WHAT YOU DON'T HAVE FROM C++, DON'T IMPLEMENT IT
  YOURSELF WITHOUT GUIDANCE, DON'T ASSUME YOU CAN'T HAVE IT." Hit directly that day: `mexpru.lua`'s
  `same(a, b)` papers over `mexpr_t` having no `__eq` registered by comparing `tostring()` output
  instead; new bracket-pairing code got built on top of that hack without ever questioning whether
  real identity comparison could just be exposed from C++ — don't repeat that.
- **Any conflict/contradiction in what the user says is theirs to resolve — ask, don't guess.**
  User's own words, verbatim, 2026-09-04: "ANY CONFLICT/CONTRADICTION OF WHAT I SAY IS SOLVED BY
  ME, SO IF YOU DETECT A CONTRADICTION, ASK ME!" — clarified scope, also verbatim: "a contradiction
  in what I say of course" (i.e. this message vs. an earlier one, not a mismatch between the user's
  intent and what the code actually does - that's ordinary review). Never silently pick a side,
  paper over it, or guess which one still holds - surface it and ask. Also in the global
  `~/.claude/CLAUDE.md` ("Working style" section) as the general, all-projects form of this rule.
- **Law 3 — in a Pangi repo, check these laws are acknowledged, and offer to spread them.** The
  first time in a session you're clearly working in a git repo authored by Pangi (commit history
  has an author name/email containing "Pangi", case-insensitive, or `git config
  user.name`/`user.email` does), check whether that repo's own CLAUDE.md acknowledges the three
  laws in some form — a reference, a summary or a link back to `~/.claude/CLAUDE.md` is enough. If
  it doesn't: **tell Andrei, don't silently add it.** CLAUDE.md is normally yours to write without
  asking; this specific case is explicitly "remind me", not "just do it" — his word. Then offer to
  add a reference if he wants one started. Once per session is enough — don't re-check every
  message, don't nag a repo that already acknowledges them. This file is that acknowledgement for
  `math_writer`.
  User's own words, verbatim, 2026-09-04: "if a git is by me (see name Pangi) then you will remind
  me if those three laws are not set, or acknowledged in some way." — and, on why the laws exist at
  all, also verbatim: "this will be the laws for claude, ok? and they would spread through my pc and
  grow, this is the 3rd rule of claude."
- **Amendment to Law 3 — verbatim citation is verbatim; commentary is not.** User's own words,
  verbatim, 2026-09-06: "THE ORIGINAL STATEMENT MUST MATCH EXACTLY WHEN COPIED - THIS IS ALSO AN
  RIGINAL CITATION - BUT COMMENTS MAY VARY, INTERPRETATIONS..."
  What this binds, and what it frees: when a law spreads into another repo's CLAUDE.md, the quoted
  original statements travel **character for character** — no tidying, no fixing typos, no
  modernising the wording, no "cleaner" paraphrase standing in for the quote. That includes the
  amendment above, which is itself an original citation and is reproduced here with its own typo
  ("AN RIGINAL") intact, deliberately. What surrounds a citation — the summary in your own words,
  the worked example, the reasoning about scope, the pointer to the file where it bit — is
  commentary, and commentary may be rewritten, expanded, shortened or re-argued per repo to fit
  what that repo actually does. The line is simply: inside the quote marks, nothing moves; outside
  them, everything may.

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
root - a test instance no longer writes the real document at all.) Escape does NOT work from the pipe: `main.cpp` polls
it with `glfwGetKey()`, which reads the real OS keyboard, and a hidden window ignores `WM_CLOSE`
too - `quit` (added 2026-09-05) is the only clean exit available headlessly.

Driving input still goes through the same TCP pipe (127.0.0.1:47821, see `debug_input_pipe.cpp`
for the line protocol) — `io.AddKeyEvent`/`AddInputCharacter`/etc. only ever touch this process's
own ImGui state, never real OS-level input, so none of this ever reaches anything else running on
the machine.

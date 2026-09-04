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

## Build

Needs three sibling checkouts next to this directory: `../imgui`, `../implot`, `../utils`
(the last is `virt_composer`, the Lua↔C++ interop framework this whole project sits on). Nothing
here vendors or fetches them.

```bash
make        # root makefile dispatches to linux.makefile or windows.makefile based on OS
```

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

## Live testing `main.exe` — READ BEFORE LAUNCHING IT

The user runs on two monitors and their **primary monitor is theirs** — they use it for other
things (games included) while a session runs. `main.exe`'s window must **never** appear anywhere
on their screen, and must **never** steal focus, not even for an instant — this was a long,
multi-round point of friction confirmed directly with the user on 2026-09-04. An earlier version
of this section described an elaborate `SetWinEventHook`-based scheme to catch and reposition
windows after the fact — **that whole approach is obsolete, don't use it.** The app already has a
proper, built-in headless mode (`debug_input_pipe.cpp`/`.h`, `imgui_helpers.h`) — use that instead.

**The correct way to launch it, always:**
```powershell
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = "C:\Users\apangratie\workspace\math_writer\main.exe"
$psi.WorkingDirectory = "C:\Users\apangratie\workspace\math_writer"
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.EnvironmentVariables["VC_WINDOW_START_HIDDEN"] = "1"
$psi.EnvironmentVariables["VC_WINDOW_STAY_HIDDEN"] = "1"
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

Driving input still goes through the same TCP pipe (127.0.0.1:47821, see `debug_input_pipe.cpp`
for the line protocol) — `io.AddKeyEvent`/`AddInputCharacter`/etc. only ever touch this process's
own ImGui state, never real OS-level input, so none of this ever reaches anything else running on
the machine.

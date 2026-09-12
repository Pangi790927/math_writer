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

## The API manifest

Every `scripts/*.lua` **starts** with a **manifest block** - a comment headed `WHAT THIS FILE
OFFERS`, listing the file's public surface and nothing else, so the interface can be read without
reading the file. Established 2026-09-12 at the author's request, starting with `editor.lua`.

**It goes FIRST, above the prose header**, on the author's call the same day: what you can call is
what you open a file to find out, and the explanation of what the module IS reads better once you
know what it offers. (`test_api_manifest.lua` matches the banner wherever it sits, so the order is a
convention rather than something the tripwire enforces.)

- **Only what a caller can reach.** A `local` helper never appears in the list of entries; the
  internals are named, bare, in a short trailer (`--- internal, not on the module table ---`) so a
  reader can see the file has a private half without being told what it does.
- **EVERY parameter carries a TYPE**, since the manifest is a comment either way: `draw(container:
  mformula.container, sz: size, pos: {x, y}) -> box`. A sealed container's type is its
  `owner.name`. **Every** parameter, not just the first - `copy(ns: ast.ns, node: node, new_ns:
  ast.ns, keep_vars: boolean)`; an untagged one is the one a reader has to go and look up, which is
  the whole thing the manifest exists to save. Caught by the author 2026-09-12 on `ast.copy`'s
  `new_ns`.
- **`test_api_manifest.lua` checks the parameter NAMES and their order against the real signature**,
  for a module's functions and a plugin's `offer`/`apply` alike. Six entries were simply wrong when
  that check was written - `ast.ns_insert_object(ns, node)` against a real `(ns, id, obj)`,
  `ast.new(ns, type)` against `(ns, type, id)`, `editor_text.push_undo` missing its `coalesce_key`.
  The types themselves are the manifest's own: there is nothing in Lua source to verify them
  against, so they are checked by reading.
- **Entries are BRIEFS, not descriptions.** One or two lines: what the function promises, and the
  one thing a caller gets wrong otherwise. Detail, reasoning and history stay on the function's own
  comment, which is where they already are. A manifest that restates the file is a second copy of
  it, and the copy is what rots.
- **The manifest is small BECAUSE the function's own header is full.** Author's own words, verbatim,
  2026-09-12: "manifest small, the functions that where named will now have large descriptions where
  you find them". A manifest entry is a pointer, and it is only worth having if scrolling down to
  the function finds the whole contract there - brief, core, detail, params and returns, per the
  comment skill. Every name in a manifest must carry a dated header at its definition; a thin one
  makes the manifest a promise the file does not keep. `test_api_manifest.lua` checks presence and a
  `@date`; whether the sections are any good is a reading, and stays one.
- **It does not replace the file's prose header.** Those are two blocks with two jobs and two
  dates: the manifest says what you may call, the header below it says what the module IS and what
  is deliberately NOT in it. Adding a manifest does not license rewriting the header.
- **`@date` on both**, per the comment skill (`../utils/ai/skills/writing-comments`, installed as
  the `pangi-ai` plugin). A manifest edited later takes the date of the edit.
- **"Public" means reachable, not `M.foo`.** A transform plugin has no module table - it hands its
  `offer` and `apply` to `transforms.register`, and transforms.lua is the only caller either ever
  gets. Those are external and are named as entries; being `local` is an artefact of how a plugin is
  delivered, not a claim that nobody outside calls them. Corrected by the author 2026-09-12, after
  the first plugin manifest filed both as internal. `test_api_manifest.lua` reads the spec table for
  exactly this reason.
- **`tests/lua/*.lua` are exempt.** All 87 of them expose exactly one `run_test()` and nothing
  else, so a manifest would say the same vacuous thing 87 times.
- **`tests/lua/test_api_manifest.lua` is the tripwire.** It reads every migrated script as text and
  fails when a public function is not named in that file's manifest. Its `MIGRATED`/`PENDING` lists
  are also the rollout tracker: moving a filename from one to the other is the last step of
  migrating a file. The alarm matters because the failure is silent and one-directional - a
  function added later simply does not appear, and the block still reads as complete.

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

## Transform plugins

A transformation is a file in `scripts/transforms/`. Added 2026-09-12.

- **`transforms.lua` is a registry and a dispatcher, and holds no algebra.** Everything runs one
  transformation the same way: `transforms.apply(id, ns, root, params)`. No caller names a plugin,
  and no caller writes a `pcall`.
- **A plugin refuses by throwing `transforms.check`**, which the dispatcher converts to `nil,
  reason` at the boundary. A refusal carries a tagged table so a genuine crash can be told apart and
  **re-raised** rather than shown as a menu tooltip.
- **The folder decides what EXISTS; `transforms.save` decides what RUNS.** The folder is scanned at
  load through `vc.path_list_dir` (`path_composer.h`, app-local). A plugin is **off** unless it
  declares `default_active` - author's own words, verbatim, 2026-09-12: "off by default, we will
  enable all the plugins that we will create, but for it in at large, the user will need to check
  it". Dropping a file in can never change what the editor does until it is ticked.
- **F2's third section is where it is ticked.** `transforms.save` is `DATA_PREFIX`'d like
  `keymap.save` and `glyphmap.save`, so `--test` writes `test_run/transforms.save` and cannot touch
  the presentation instance's list. It records only divergences from each plugin's own default.
- **`transforms.lua` never writes a file.** `main.lua` owns the path and the I/O, the same way it
  does for the keymap - a module that writes files cannot be loaded by a test without a file
  appearing somewhere.
- **The test harness needs `scripts/` mirrored next to it.** `vc.path_list_dir` resolves against the
  executable, and `tests/harness/build/test_harness.exe` is not where the repo is; `run_tests.py`'s
  `sync_scripts()` copies `scripts/` there before every run. Without it the harness finds no plugins
  while the app finds them all.

## Sealed containers

A table created in one file and written from several is declared, and its field set is fixed.
Added 2026-09-12 at the author's request.

- **One creator per container, and it does the sealing.** `sealed.declare(owner, name, fields)`
  returns a shape; the creator ends in `SHAPE.wrap{...}`. The field list IS the documentation -
  one list, not a list plus a comment that can disagree with it.
- **The rule**, author's own words, verbatim, 2026-09-12: "it allows the curent ones not to be set,
  so u.bracket can return nil if never set, only that u.bracjet will be rejected with an exception
  such that invalid table members are fixed". A declared field that was never set reads nil, as it
  always did; an undeclared name is refused on read AND on write. The table looks the same to every
  caller it had before.
- **A refusal means the declaration is out of date**, not that the caller should route around it.
- **The name says which container it is.** Four different tables used to be called `state`; they
  are now `state_doc`, `state_text`, `state_definition`, `state_formula`, `state_help`,
  `state_keymap`, and the name is the same at every call site. `node` and `entry` still each name
  two unrelated containers - not yet done.
- **Sealed today** (eleven): `u` (mexpru), `ns` and `node` (ast), `ctx` and `spec` (transforms),
  and the six states above.
- **A container with a positional part is sealed in ARRAY MODE** (`opts.array`): integer keys pass
  untouched, string keys must be declared. An ast node is the case - `type` and `id` are its whole
  named surface, and its children are positional and unbounded, so there is nothing there to
  declare. It catches `node.typ` and `node.parent`; it does not check a child's count or type.
- **EVERY public function gets its OWN signature entry - no bare-name groups.** A name listed bare
  in a family ("new_in  new_ni  new_subset") reads as documented while carrying no parameters at
  all, and `test_api_manifest.lua` used to accept the bare mention, so the parameter check skipped
  it entirely. Sixty-six names were hiding that way, including every relation constructor in
  ast.lua - none of them typed, none of their operands checked. Author, 2026-09-12: "all those dont
  get properly declared in the manifest and don't check lhs, rhs". The check now requires `fn(` for
  anything the source defines as a function; a DATA TABLE is exempt, since it is not callable.
- **Argument checks are a PREAMBLE, and they belong to the API function - never to a local.**
  Author, 2026-09-12: "do preamble checks, but only in the api calls, not in locals". A local that
  several public functions funnel through is tempting, because it is the one place they all reach;
  it is still the wrong place, because the contract belongs to what a caller can see.
- **A GENERATED public function still owns its preamble.** `ast.new_sum`, `new_prod`, `new_lim` and
  the rest of the group big operators are built in a loop as `ast["new_" .. name] = function(...)`,
  so there is no `function ast.new_sum(...)` line to write a check on - and they had none at all
  until this was noticed. The loop body IS the API function: the preamble goes there, written out
  rather than factored into a local.
- **A LOOKUP RESULT that gets indexed is checked where it is indexed.** `ns.by_id[id]` is a node by
  contract, and a contract is not a check: `ast.shape`'s VREF branch read `var[1]` off whatever came
  back, so a poisoned entry would have produced a wrong SHAPE - and shape's whole job is answering
  "are these two the same expression", where a wrong answer is worse than a crash. Three such sites
  in ast.lua, all checked now. A nil result is still an ordinary answer: an unresolved reference
  falls back to the raw id.
- **Delete a guard the preamble made dead.** `ns and ns.by_id and ns.by_id[...]` cannot fire once
  the function has checked `ns`, and a guard that can never fire only hides the day the thing it
  guarded really is missing.
- **A GENERATED public function is found by ASKING the module, not by reading it.**
  `test_api_manifest.lua` is static by design, but a function built in a loop has no definition line
  to read: `ast["new_" .. name] = function(...)` produced thirteen constructors and `mexpru`'s
  WRAPPED loop twelve more, and all twenty-five were invisible to every check built on the text
  scan. A second, clearly-marked pass requires the module and diffs its real function keys against
  what the scan found. It must be NAMED in the manifest; a signature and a per-function header are
  not required, because there is no definition line for either to sit on - the loop carries one
  comment for the whole family.
- **"Named" means listed as an ENTRY, not mentioned in prose.** Entries start at column zero and
  prose is indented; a plain substring search was satisfied by ast.lua's own sentence explaining
  that generated functions have no definition line, so the check passed while the family was
  undocumented. Whole-word too, so `new_sup` cannot answer for `new_sum`.
- **A public TABLE gets a reader function; callers do not index it.** Author, 2026-09-12: "instead
  of a public array... this way we are sure of what it is", and "this is a wide problem across the
  project". A table indexed from other files makes every caller responsible for the key, the
  default, and what a nil means - and none of that is written where a reader finds it.
  `ns.by_id[id]` is now `ast.node_of(ns, id)`, which CHECKS what it found: reaching in directly is
  what let a non-node sit in a namespace unnoticed and produce a wrong `ast.shape`.
  `char.size_delta_by_desc[desc]` appeared at ten call sites, each with its own idea of what an
  absent entry meant; it is `char.size_delta(desc)`, where the default lives once. The tables stay
  public - they are DATA and something has to enumerate them - but one entry is asked for, not
  reached for.
- **A function that USES a value owes the check; one that only forwards it does not.** Author,
  2026-09-12, on `ast_gestures.options` - "probably not... the other two are already checked by
  ast_for". `options` passes all four arguments straight into functions that check them and touches
  none itself, so a check there would be the same guard twice on one path. `preview` and `run` read
  `option` before anything else happens to it, so they check that one and nothing else.
- **Check at the boundary with code this project did not write.** `transforms.offers` validates what
  a PLUGIN handed back, because a plugin building its option by hand instead of through
  `transforms.option` would otherwise produce something that draws correctly in the menu and refuses
  when run - a failure two gestures away from its cause.
- **A TREE WALK does not list the child fields itself.** `mexpru.child_links(node)` is the one
  definition of "what is below this node", derived from the same place the `u` fields are declared.
  `ast_mexpr.origins` listed eight of them by hand, which made it a second declaration of the node
  shape, free to fall behind the first - and the failure would not have been loud: an incomplete map
  means the writer re-renders glyphs it could not find instead of copying them, and the symptom is a
  decoration or a spacing quietly lost on a rebuild. A load-time assertion ties the link list to
  `U_FIELDS`, so a typo there fails at require rather than at a redraw.
- **`fontset` is deliberately NOT checked.** It is C++ userdata with no field to probe, and
  virt_composer raises its own error when handed the wrong thing - author, 2026-09-12: "virt
  composer has it's own errors thrown, leave it". A structural probe invented here would be a guess
  dressed as a guarantee.
- **A missing required argument must RAISE, never degrade to an empty answer.**
  `ast_mexpr.var_origins` began `if not ns or not ns.by_id then return out end`, which turned a
  missing namespace into an empty map - indistinguishable from "this tree has no references", so the
  writer would go on to re-render every name instead of copying it, and the symptom would be
  decorations lost rather than an error. An empty result that means two different things is the same
  silence a nil field was.
- **One name, one container - `ctx` too, not just `state`.** Three different containers were called
  `ctx`: a plugin's, the parser's in mexpr_ast, and the writer's in ast_mexpr, with no field in
  common. They are `transforms.ctx`, `ctx_parse` and `ctx_write` now; the one that CROSSES FILES
  keeps the bare name, since it is the one a reader meets without context. A file-internal container
  still gets a name and a creator, even when it does not get a seal.
- **Moving a field into a creator can change behaviour - check whether ABSENT is a state.**
  `ctx_parse.free_order` is nil normally and set to `{}` only for the span a bigop wants harvested;
  `if ctx_parse.free_order then` is the off switch. Initialising it in the creator would have made
  that gate always true, and the suite stayed green - no test covers it. Caught by reading the uses,
  not by running.
- **A CONCEPT gets one definition, not one per file.** "The end of a row" was written out three
  times - `mformula_new.cursor_to_end`, `mformula_latex.from_latex`, `ast_mexpr.container` - each
  reaching into `u.children` and indexing it by hand, and only ONE of the three had the empty-row
  fallback. It is `mexpru.last_slot(node)` now, which answers with the row itself when it is empty,
  so a cursor is never set to nil.
- **Before sealing a type, find EVERY producer of it.** `mformula_new.draw` and `.measure` returned
  two look-alike tables - `{width, top, bottom, cursor_top, cursor_h}` and `{width, top, bottom}` -
  and `editor.formula_click_rect` took whichever the caller had. Sealing only draw's made the check
  reject half its real input, and the editor went blank. They are one declared type now, with the
  caret fields simply unset when measuring, which is what let that function check at all.
- **An options table that arrives already built is checked BY KEY, not sealed.** A seal catches a
  key that is not there yet; `opts` is a literal at each call site, so a misspelt key is already
  present and `setmetatable` after the fact catches nothing. `editor.draw_formula` walks what the
  caller passed against `DRAW_OPTS` - and a misspelt option is not harmless: `active` misspelt makes
  a formula silently uneditable.
- **The forwarding exemption ends where the forward is CONDITIONAL.** `keymap.filter_ids` passes
  its filter to `filter_matches`, which checks it - but only for actions that HAVE a bind, and never
  for the nil-filter branch. A malformed filter over a keymap with nothing bound came back `{}`,
  which is what a valid filter matching nothing returns. It checks at the top now. A forwarder is
  exempt only when every path forwards.
- **Validation goes through `sealed.lua`. Do not hand-roll `assert(SOME_TABLE[x], ...)`.**
  Four of those accumulated, each with its own wording, before the mechanism grew to cover them -
  author, 2026-09-12: "what is this, why not the sealed?" and "you did that aberation starting from
  here?". A shape now answers four questions, all from one declaration and one error format:
  `wrap` seals a table, `check_keys` validates an ALREADY-BUILT one (an options literal, which a
  seal cannot police because its keys are present before the seal is on), `check_name` validates one
  enum-shaped value, and `check_covers` asserts a mirroring table has an entry for every declared
  name. The last two are the ends of one question - a status with no colour is an invisible mark, a
  colour with no status means the two have drifted - and neither implies the other.
- **Declare a file's shapes TOGETHER, near the top.** `USE_SHAPE` was declared beside the function
  that builds it and used two hundred lines earlier, which Lua resolves as a nil global. ast.lua
  already groups `ns` and `node`; mexpr_ast now groups `ctx_parse`, `unit`, `decl` and `use` the
  same way. A shape is a declaration, not a local helper - it belongs with the other declarations.
- **`test_no_use_before_define.lua` covers 21 files, not 10.** A `local function` called before its
  declaration shipped in mexpr_ast and the suite said nothing, because the file was simply not on
  that test's list. The list was the gap, not the check.
- **A LIST argument is checked THROUGH, not at the top.** `check_units` and `check_decls` walk every
  element, because the elements are what get dereferenced - `d.tokens`, `u.atom` - so a wrong one
  is used rather than merely carried, and naming which index went wrong is most of the diagnosis.
- **An ACCESSOR validates what it resolves.** `mexpru.u(ref)` hands back whatever the node
  captured; it now answers nil for a node that captured nothing, and RAISES for anything that is not
  a sealed `u` - author, 2026-09-12: "if it's not the u's type error out, if nil return nil, else
  return it". A plain table in there means something bypassed the one creator, and every field
  guarantee the file makes is void for it. Same shape as `ast.node_of`.
- **`test_no_use_before_define.lua` covers `local X = ...` at FILE SCOPE, not only `local
  function`.** The same fault landed twice in one session - a shape declared below a function that
  reads it - and the suite passed both times, because only the call form was checked. File scope
  only: a value local inside a function body is re-declared constantly (`local u`, `local bb`) and
  tracking those makes the check scope-blind and pure noise.
- **An INTEGRITY check is for an argument nothing downstream would catch.** `propagate_rebuild`
  walks `old_node` upward and detaches it; `cut` detaches what it is given. Neither hands the node
  to anything that validates it, so a wrong one fails several lines in as a method call on a nil
  field. Their siblings need none: `new_node` reaches update_positions, which passes it to `u()`,
  and that says what it found.
- **A "shaped exactly like X" comment is a type waiting to be declared.** `mexpru.redress` took
  either a dress node's own `u` or a bare spec that mformula_new's comment described as "shaped
  exactly like a dress node's own u table" - the same five fields, built by hand at two sites. The
  check could not be written while that was a promise. `mexpru.dress_spec` makes it one type, the
  way `measure` was made to return a `box`.
- **A type named in a manifest must be one something CHECKS.** `ns_insert_object(ns: ast.ns, id:
  id, obj: node)` advertised `node` while nothing verified it - author, 2026-09-12: "node is not
  checked". Writing a type down is a claim; if no `SHAPE.check` stands behind it, it is a comment
  pretending to be a guarantee.
- **Wrap at construction, not on the way out.** `ast.new` seals the node BEFORE registering it,
  because `ns_insert_object` checks what it is handed and an unwrapped node is not one yet. It also
  means the constructor's own writes go through the seal.
  `container` (mformula), content's `box`, mexpr_ast's parser `p` and `unit`, and
  mformula_latex's `subst` are documented or pending, not sealed.
- **`tests/lua/test_container_fields.lua` is the tripwire.** The seal is a RUNTIME guard and the
  draw path is not exercised by any test, so a field used only while drawing would pass the suite
  and throw on screen. The test reads `sealed.all()` and the sources statically.
- **Cost**: both metamethods fire only while a key is ABSENT, so the check is paid on a field's
  first write and on reads of fields an object does not have - never on the ones it does.
- **The owner is part of the type.** `shape.type_name` is `owner.name` - `content.state_doc`, not
  `state_doc` - because two files may reasonably call their container the same thing. The metatable
  IS the type, so a table with exactly the right fields is still refused: identity, not shape.
- **EVERY entry point that takes one checks it**, `SHAPE.check(x)` on the first line, and that
  includes SECONDARY parameters - `ast.copy` checks `new_ns` as well as `ns`. Left to the inner
  call, the error names a line inside the callee instead of the argument the caller got wrong.
  The field seal cannot catch a swap at all: `state_text` and `state_definition` both declare
  `undo`, so passing one for the other reads every shared field and goes quietly wrong. The error
  names both types: `content: expected content.state_doc, got editor_text.state_text`.
- **NO EXCEPTIONS, and the reasoning that asks for one is the tell.** `ast.ns` was left unsealed
  first time round on the argument that only `ast.new` and `ns_insert_object` touch it. That is the
  same argument that would excuse `u` ("only mexpru") and `ctx` ("only transforms"), and it is
  exactly the reasoning that left `state_text` open to `content.lua` writing four fields into it.
  Overruled by the author, 2026-09-12.
- **An unknown field CRASHES. There is no collect-and-continue mode**, and one was proposed and
  refused the same day - author's own words, verbatim, 2026-09-12: "no, an unknown thing should
  crash, not silently continue". A guard with an off switch is a guard you find switched off. The
  cost is that a field on a path nobody has run yet surfaces in use rather than up front; that is
  the trade, taken deliberately.
- **Do not derive a field list by grepping the container's own file.** That method is blind to a
  field written from ELSEWHERE under a different variable name, and it shipped a broken editor on
  2026-09-12: `content.lua` writes `_cursor_sig_a/b/c` and `_scroll_to_caret` onto a text box's
  state through a local called `ed`, because scroll-into-view belongs to the document while its
  per-box state belongs to the box. The document draw threw every frame; F1/F2 still drew, so the
  screen blinked. **Verify by running the app on a real document**, not by grepping a log - and
  look at the screenshot.

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
`char.lua` (glyph catalog), `transforms.lua` (algebraic term-dragging, WIP). Full detail and
data-flow diagram in `README.md`.

## Where the project is

**Phase 1 (the text editor) is done** — declared so 2026-09-06, commit "the user interfacing
editor passed it's stage, time for second stage". Typing, navigation, brackets, accents, big
operators, undo/redo, save/load and LaTeX in both directions all work; `tests/` covers them.

**Phase 2 is linking the editor to the AST.** Two documents, different jobs:

- **`docs/ast_parsing.md`** — what the parser DOES today: the name serialization, which
  definitions may coexist, how a use resolves, the expression cascade. Read this one to work on
  `mexpr_ast.lua`; it marks every item implemented / partly / designed-only.
- **`docs/phase2_design.md`** — the design RECORD, and read it before touching `ast.lua`
  or `transforms.lua`. It records decisions made in conversation that are not derivable from
  the code: three editors with a one-way promotion door, immutable cells forming a proof DAG,
  why `mexpr -> ast` must be direct rather than routed through LaTeX, how names and subscripts
  identify, and what would be needed to talk to Lean.

## Known WIP / intentionally incomplete

- `transforms_old.lua` — term-dragging is deliberately unfinished, flagged in-file. Don't fill in
  the remaining cases without asking first; this is exploratory design work still being thought
  through, not a bug to fix. **Moved out of `transforms.lua` on 2026-09-12**, unchanged, when that
  file became the plugin registry; nothing requires it. Three faults found during the move are
  recorded in its header and deliberately NOT repaired, since repairing frozen WIP unasked is what
  the rule above forbids.
- Fraction layout (`mexpr_frac` in `math_expr_composer.h`, and its caller `mexpru.mexpr_frac`) has
  open rough edges noted in comments.
- **`scripts/mexpr.lua` was deleted 2026-09-09** as unreachable — nothing required it but
  `main.lua`'s dead `demo_draw()`. It was the only `ast -> mexpr` writer, so `docs/phase2_design.md`
  section 12 ("regenerate the changed subtree through mexpr.lua") now describes a file to be
  written rather than repaired. It is still in git: `git show c109aaf:scripts/mexpr.lua`. Its four
  `vc.mexpr_bracket()` calls used a signature the C++ no longer has, which is part of why it went.
- `ast.lua`'s `to_latex()` went the same day and for the same reason. LaTeX in the running app is
  `mformula_latex.lua`'s, over the mexpr tree, and is unaffected.
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

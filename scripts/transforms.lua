--[[ ==================================== WHAT THIS FILE OFFERS ====================================

register(spec: transforms.spec)         -> nothing
    Adds one transformation. Called by a plugin at require time and by
    nothing else. `spec` is {id, label, params, offer, apply}.

apply(id: id, ns: ast.ns, root: ast.node, params: {name=id}) -> new_root | nil, reason
    THE ENTRY POINT. Finds the plugin, checks its params are present,
    runs it inside the sentinel. The source tree is never mutated.

offers(ns: ast.ns, root: ast.node, node: ast.node | nil) -> {option, ...}
    Every plugin's answer to "what applies at this ast node", in
    registration order. An option is {id, label, params} - ids, never
    closures. An empty list is the ordinary answer, and a nil `node` -
    a click that resolved to none - is one of the ways to get it.

list()                                  -> {spec, ...}
get(id: id)                             -> spec | nil
    The registry itself, for anything that wants to name what exists.
    `list` is in plugin-folder order, which is menu order.

is_active(id: id)                       -> boolean
set_active(id: id, on: boolean)         -> existed
    Whether a transformation offers and runs, and the only way to
    change it. A plugin is OFF unless it declares default_active.

serialize()                             -> text
load(text: string)                      -> applied, skipped
dirty() / clear_dirty()                 -> boolean / nothing
    The activation state as `transforms.save` holds it: divergences
    from each plugin's default, one `id<TAB>on|off` per line. `load`
    never registers anything - it only flips flags on plugins the
    folder scan already found, and skips ids nothing answers to.

option(id: id, label: string, params: {name=id}) -> transforms.option
check_option(option: transforms.option) -> option
    One transformation that COULD be run here. A plugin's offer()
    returns one; it carries IDS, never nodes, so it survives being held
    in a menu across frames without keeping a tree alive.

check_ctx(ctx: transforms.ctx)          -> ctx
    Asserts a plugin was handed the real ctx. For the first line of an
    offer() or an apply().

check(cond: any, msg: string, ...)      -> cond
    FOR PLUGINS ONLY. Refuses, from inside apply() or offer(), by
    throwing a tagged table that `apply` above converts to nil+reason.
    `msg` is formatted with ... when extra arguments are given.

--- internal, not on the module table --------------------------------------------------------------
    make_ctx()     the ONE creator for the `ctx` a plugin receives, and where its
                   seal is attached; CTX_FIELDS beside it declares the shape
    is_refusal, guarded, missing_param, CTX_SHAPE, SPEC_FIELDS, SPEC_SHAPE,
    PLUGIN_DIR
@date 2026-09-12 01:25
================================================================================================= ]]

--[[
transforms.lua - THE REGISTRY: every algebraic transformation the editor can run, and the one door
they are all run through.

NO ALGEBRA LIVES HERE. A transformation is a file in scripts/transforms that registers itself, and
this file only knows how to find one, hand it a tree, and survive what it does. That split is
the point: adding a transformation must not mean editing the menu, the gesture resolver and a
dispatch table in three places, which is exactly what it meant before.

THE SENTINEL IS HERE AND ONLY HERE. A plugin refuses by throwing (see `check`), and this file is
the single place that catches. A caller therefore never writes a pcall and never learns a plugin's
name: ast_gestures asks for options and runs one by id, and which plugin that reaches is decided
here.

A REFUSAL IS NOT AN ERROR, and telling them apart is the whole reason the throw carries a table
rather than a string. "Distribute needs a product around the sum" is an ordinary answer - the
gesture landed somewhere it does not apply - and comes back as nil plus that reason. A nil index
inside a plugin is a bug, and is re-raised with its traceback rather than being quietly rendered as
a menu tooltip. Swallowing both alike is how a broken transformation goes unnoticed for a week.

@date 2026-09-12 01:25
]]

local vc = require("virt_composer")
local ast = require("ast")
local sealed = require("sealed")

local transforms = {}

--[[ PUBLISHED BEFORE THE PLUGINS AT THE BOTTOM ARE LOADED, and that is the only reason this line
exists. A plugin's first act is require("transforms"), and this file's last act is requiring the
plugins - a cycle. Lua writes package.loaded only when a module RETURNS, so without this the plugin
would re-enter this file from the top and register into a second, discarded table. Assigning it
here means the table a plugin receives is already the one everybody else will get.
@date 2026-09-12 01:25 ]]
package.loaded["transforms"] = transforms

local REGISTRY, ORDER = {}, {}

--[[ Set when an activation flag moves, cleared by whoever writes the file.
@date 2026-09-12 02:40 ]]
local dirty = false

--[[ The tag that separates "does not apply here" from "this plugin is broken".

A METATABLE RATHER THAN A FIELD, because a field can be produced by accident: a plugin that throws
a table of its own, or an error object from some library, could carry a `refusal = true` without
meaning to. Nothing acquires this metatable except `check` below, so identity against it is proof
of where the throw came from.
@date 2026-09-12 01:25 ]]
local REFUSAL = {}

local function is_refusal(e)
    return type(e) == "table" and getmetatable(e) == REFUSAL
end

--[[ Refuses the transformation in hand, from inside a plugin.

THE ONLY WAY A PLUGIN MAY SAY NO. It throws, so the plugin's own code after it does not run and
does not have to be written as a chain of early returns - which is what lets a transformation read
as the algebra it performs rather than as a wall of guards. `apply` below turns the throw back into
an ordinary nil+reason at the boundary, so nothing outside this file ever sees an exception.

Params: `cond` is returned unchanged when truthy, so the call can stand in an expression. `msg` is
the reason a human will read, in a menu or a log; it is `string.format`ed with the remaining
arguments when any are given, and taken literally when none are - so a message containing a stray
`%` is safe as long as nothing is being interpolated into it.

Note: level 0 on the throw, so Lua does not prefix the message with this file and line. The reason
is shown to a user, and "transforms.lua:84: distribute needs a sum" is not a sentence.
@date 2026-09-12 01:25 ]]
function transforms.check(cond, msg, ...)
    if not cond then
        local text = select("#", ...) > 0 and string.format(msg, ...) or msg
        error(setmetatable({msg = text}, REFUSAL), 0)
    end
    return cond
end

--[[ THE `spec` CONTAINER - one transformation's registration. Its creator is the plugin itself:
a plugin writes the table inline in its transforms.register call, and `register` below seals it, so
the seal lands on a table this file did not build.

`active` is the one field the registry writes after registration; everything else is the plugin's.

A plugin that misspells `defualt_active` registers silently as off, and that is the failure this
declaration exists to catch - but the SEAL cannot catch it, and the comment here claimed it did
until 2026-09-12. `wrap` only refuses keys that are not there yet, and a spec is a table literal
inside the plugin's own register call, so every key it will ever have is present before the seal
goes on. `register` runs `check_keys` over it instead, which is the same split already made for an
options literal.
@date 2026-09-12 20:10 ]]
local SPEC_FIELDS = {
    id             = "the name apply() and an option carry. Unique; a second registration is refused.",
    label          = "what a menu shows. Plain text.",
    params         = "list of parameter NAMES apply requires; checked before the plugin runs",
    offer          = "offer(ctx) -> option | {option,...} | nil. Optional.",
    apply          = "apply(ctx) -> new_root. The algebra. Refuses with transforms.check.",
    default_active = "true to ship switched on. Absent means OFF - see register below.",
    active         = "whether it currently offers and runs. Written by the registry, not the plugin.",
}
local SPEC_SHAPE = sealed.declare("transforms", "spec", SPEC_FIELDS)

--[[ Adds one transformation to the registry.

CALLED AT REQUIRE TIME, from the bottom of a plugin file, and never from anywhere else. The folder
scan at the end of this file requires every plugin, so the registry is fully populated the moment
this file finishes loading and nothing has to worry about one appearing halfway through a frame.

`spec` fields:
    id      the name apply() and an option carry. Must be unique; a second registration under the
            same id is a programming error and is refused loudly rather than silently winning.
    label   what a menu shows. Plain text.
    params  list of parameter NAMES the apply below requires. Checked by apply() before the plugin
            runs, so a plugin never writes "did I get my arguments" itself.
    offer   optional. offer(ctx) -> option | {option, ...} | nil. What this transformation can do
            at the ast node the user pointed at.
    apply   apply(ctx) -> new_root. The algebra. Refuses with transforms.check.

REGISTRATION ORDER IS KEPT and is what `offers` and `list` iterate, so the order transformations
appear in a menu is the order the folder scan found them in - which vc.path_list_dir sorts, so it is
the same on every machine, and is not however Lua happens to hash the ids.
@date 2026-09-12 01:25 ]]
function transforms.register(spec)
    assert(type(spec) == "table" and spec.id, "a transform spec needs an id")
    --[[ BEFORE anything reads a field, and it cannot be left to the seal at the bottom: the spec
    arrives fully built from the plugin's own file, so `wrap` never fires on the keys it already
    has. Keyed by the id rather than by the type name, because this throws during the folder scan
    at require time and WHICH PLUGIN is the first thing the reader needs. ]]
    SPEC_SHAPE.check_keys(spec, spec.id)
    assert(type(spec.apply) == "function", "transform '" .. spec.id .. "' has no apply")
    assert(not REGISTRY[spec.id], "transform '" .. spec.id .. "' is already registered")
    --[[ OFF UNLESS THE PLUGIN ASKS OTHERWISE. Author, 2026-09-12: "off by default, we will enable
    all the plugins that we will create, but for it in at large, the user will need to check it".
    So a file dropped into the folder is found, listed and inert until somebody ticks it - dropping
    a file in cannot change what the editor does. The ones shipped here declare default_active and
    are on from the first run; `transforms.save` then records only what the user changed. ]]
    spec.active = (spec.default_active == true)
    --[[ Sealed AFTER `active` is set, so the registry's own write does not have to be a special
    case, and from here on a plugin file cannot grow a field the registry does not know. ]]
    SPEC_SHAPE.wrap(spec)
    REGISTRY[spec.id] = spec
    ORDER[#ORDER + 1] = spec
end

--[[ Whether `id` currently offers and runs.

Core: the one question the dispatcher asks before doing anything on a plugin's behalf, and the one a
panel renders as a tick. An unknown id is not active - a saved file naming a plugin that has since
been deleted answers false rather than throwing.

Params: `id` as registered. Returns a boolean, never nil, so it can be used directly as a condition.
@date 2026-09-12 02:30 ]]
function transforms.is_active(id)
    local spec = REGISTRY[id]
    return (spec ~= nil) and spec.active == true
end

--[[ Turns a transformation on or off.

Core: THE ONLY WAY THE SET OF AVAILABLE TRANSFORMATIONS CHANGES at runtime. Everything else reads
`active`; this writes it. Taking one off removes it from every future menu and makes apply refuse it
by name, so an option left over in a menu from before the change cannot still run it.

Detail: it does not persist anything. Writing `transforms.save` is main.lua's, the same way the
keymap and the glyph map are written by their owner rather than by the module that holds them - a
module that writes files cannot be loaded by a test without a file appearing somewhere.

Params: `id` as registered, `on` truthy to activate. Returns true when the id existed, false when
nothing answered to it - which a caller loading a saved file wants to know about.
@date 2026-09-12 02:30 ]]
function transforms.set_active(id, on)
    local spec = REGISTRY[id]
    if not spec then
        return false
    end
    local want = (on == true)
    if spec.active ~= want then
        spec.active = want
        dirty = true
    end
    return true
end

--[[ Has the activation state changed since it was last written?

Core: the signal main.lua watches so `transforms.save` is written when there is something to write
and not once per frame - the arrangement keymap and glyphmap already use, and the reason all three
can be saved from the same place on the same condition.

Detail: set by set_active only when a flag actually MOVES, so ticking a box and un-ticking it leaves
nothing to save. Loading a file does not dirty anything: what was just read is by definition what is
on disk.

Returns a boolean. `clear_dirty` is called by whoever did the writing.
@date 2026-09-12 02:40 ]]
function transforms.dirty()
    return dirty
end

--[[ Declares the activation state written, so `dirty` goes quiet until something moves again.

Core: called by WHOEVER DID THE WRITING and nobody else - main.lua, immediately after it has put
transforms.serialize()'s text on disk. Clearing it without writing loses a change silently, which is
the only way to misuse this.

Detail: not called by `load`, which clears the flag itself for a different reason - what was just
read is already what is on disk, so there was never anything to write back.
@date 2026-09-12 02:50 ]]
function transforms.clear_dirty()
    dirty = false
end

--[[ One registered transformation's spec, by id.

For anything that needs to say something ABOUT a transformation rather than run it - render its
label in a menu, check an id in a saved file still names something that exists, report what a
logged option referred to.

Detail: the spec is handed back live, not copied, so a caller holds the registry's own table. Read
it; writing through it changes the transformation for everybody, which is how `active` will be
toggled later and is not something any current caller should be doing.

Params: `id` as registered. Returns the spec, or nil when nothing answers to that id - which is an
ordinary answer for an id that came from outside this process, a saved file or a stale option.
@date 2026-09-12 02:05 ]]
function transforms.get(id)
    return REGISTRY[id]
end

--[[ Every registered transformation, in registration order.

THE ORDER IS THE PLUGIN LIST'S ORDER, which is the order the require lines at the bottom of this
file run in - so what a menu shows is arranged by editing that list, not by however Lua happens to
hash the ids. `offers` walks the same sequence, so a menu and this list can never disagree about
precedence.

Detail: the live array, not a copy - same caution as `get` above. Its length is the number of
transformations the application has, which is what a panel listing them wants.

Returns the list; empty only if no plugin loaded at all, which means the require lines at the bottom
are gone rather than that nothing applies.
@date 2026-09-12 02:05 ]]
function transforms.list()
    return ORDER
end

--[[ THE `option` CONTAINER - one transformation that COULD be run here.

Declared because it crosses more boundaries than anything else in this area: a PLUGIN builds it,
transforms.offers collects it, content.lua draws it in a menu and holds it across frames, and
ast_gestures hands it back to apply. Five files, and until now nothing said what it holds - a plugin
writing `parms` instead of `params` would have produced an option that drew correctly in the menu
and then refused when run.

IDS, NEVER NODES, and that is what the fields are for: an option has to survive being shown, held
between frames and logged, without keeping a whole tree alive behind it.
@date 2026-09-12 13:00 ]]
local OPTION_FIELDS = {
    id     = "which transformation - the registered id apply() takes",
    label  = "what the menu shows. Plain text.",
    params = "{name = ast id}, the arguments apply() will be given",
}
local OPTION_SHAPE = sealed.declare("transforms", "option", OPTION_FIELDS)

--[[ Builds one. THE ONE CREATOR, for a plugin's offer() to return.

Params: `params` maps each name the plugin declared to the ast id it resolved. Returns the option.
@date 2026-09-12 13:00 ]]
function transforms.option(id, label, params)
    return OPTION_SHAPE.wrap{id = id, label = label, params = params}
end

--[[ Asserts one, for a function that takes an option rather than making it. @date 2026-09-12 13:00 ]]
function transforms.check_option(option)
    return OPTION_SHAPE.check(option, "option")
end

--[[ THE `ctx` CONTAINER'S DECLARED FIELDS - what a plugin receives, and the only things it may ask
for.

Declared and sealed for the same reason mexpru's `u` table is: `ctx` is built here and read in every
plugin file, so it spans the boundary this project has the least visibility across - a plugin is
meant to be droppable, and a dropped-in file reading `ctx.nodes` because it guessed the name would
get nil and behave wrongly rather than say so.

A DECLARED FIELD THAT IS NIL IS NORMAL: `ctx.params` is absent for an offer, because parameters are
what an offer PRODUCES. An undeclared name is refused, on read and on write.
@date 2026-09-12 04:55 ]]
local CTX_FIELDS = {
    ns      = "the namespace `root` lives in; new nodes are minted into it",
    root    = "the whole tree, not the node the gesture named",
    node    = "the ast node the pointer resolved to - set for offer(), absent for apply()",
    params  = "{name = ast id} as an option carries them - set for apply(), absent for offer()",
    check   = "transforms.check, so a plugin refuses without requiring this file back for it",
    parents = "parent_map(root), MEMOIZED and called as a function",
}

--[[ READ-ONLY, which is stricter than the other containers: there is no legitimate reason for a
plugin to write into the context it was handed, and one that did would be communicating through a
side channel instead of its return value. @date 2026-09-12 05:45 ]]
local CTX_SHAPE = sealed.declare("transforms", "ctx", CTX_FIELDS, {readonly = true})

--[[ Asserts that a plugin was handed the ctx this file builds, and not something else.

FOR A PLUGIN'S OWN ENTRY POINTS, so `offer` and `apply` check their argument the way every other
function taking a sealed container does. Today only this file calls them, so the check is documentary
as much as defensive - but a plugin is meant to be DROPPABLE, and the author of the next one has
nothing else telling them what `ctx` is at the moment they write `function offer(ctx)`.

Returns `ctx` so it can stand as the first line of a function. Raises, naming both types, when it is
anything else.
@date 2026-09-12 07:40 ]]
function transforms.check_ctx(ctx)
    return CTX_SHAPE.check(ctx, "ctx")
end

--[[ Builds the ctx one plugin call receives. THE ONE CREATOR for that container.

`parents` IS A FUNCTION, not a table, and memoized: ast.parent_map walks the whole tree, most
transformations need it and some do not, and two plugins in one gesture should not build it twice.
Calling it is free after the first time.

WHOLLY READ-ONLY, which is stricter than the `u` table: there is no legitimate reason for a plugin
to write into the context it was handed, and a plugin that did would be communicating through a
side channel instead of its return value.
@date 2026-09-12 04:55 ]]
local function make_ctx(ns, root, params, node)
    local cached
    return CTX_SHAPE.wrap({
        ns = ns,
        root = root,
        node = node,
        params = params,
        check = transforms.check,
        parents = function()
            cached = cached or ast.parent_map(root)
            return cached
        end,
    })
end

--[[ Runs `fn(ctx)` inside the sentinel, and reports which of the three things happened.

Returns ok, value: ok true with the plugin's result; ok false with a REASON when the plugin refused.
A genuine error is not returned at all - it is re-raised here, with the traceback captured at the
point it was thrown rather than at this stack level, where the useful frames are already gone.

WHY A BUG IS RE-RAISED rather than folded into the refusal channel: a transformation that crashes
would otherwise show up as a politely greyed-out menu entry, indistinguishable from one that simply
does not apply, and nothing would ever report it. Loud is correct here - the repo treats a fired
alarm as the point, not as damage.
@date 2026-09-12 01:25 ]]
local function guarded(fn, ctx)
    local function handler(e)
        if is_refusal(e) then
            return e
        end
        return {internal = tostring(e) .. "\n" .. debug.traceback("", 2)}
    end
    local ok, res = xpcall(fn, handler, ctx)
    if ok then
        return true, res
    end
    if is_refusal(res) then
        return false, res.msg
    end
    error(res.internal, 0)
end

local function missing_param(spec, params)
    for _, name in ipairs(spec.params or {}) do
        if (params or {})[name] == nil then
            return name
        end
    end
    return nil
end


--[[ Runs one transformation over a tree and gives back the tree it produced.

THE ONE DOOR. Everything that runs a transformation comes through here: the right-click menu, the
F6 preview, the tests. A caller names the transformation by id and passes its parameters as a plain
table of ast ids, so nothing outside this file holds a reference to a plugin, and a transformation
can be swapped out by deleting one require line without any caller noticing.

THE SOURCE TREE IS LEFT ALONE. A plugin rebuilds the path from the root down to what it changed and
shares every untouched subtree, so the result lives in the SAME namespace and untouched nodes keep
their ids. That is what lets "did this subtree change?" be answered by identity, and it is what
makes the mexpr repair afterwards small.

Params:
    id      a registered transformation's id
    ns      the namespace `root` lives in; new nodes are minted into it
    root    the tree to transform - the whole row, not the node the gesture named
    params  {name = ast id, ...}, as an option's `params` carries them

Returns the new root; or nil and a reason when the id is unknown, switched off, a declared parameter
is missing, or the plugin refused. RAISED rather than returned: a crash inside a plugin, and an `ns`
or `root` that is not one - a wrong argument is not a refusal.
@date 2026-09-12 22:05 ]]
function transforms.apply(id, ns, root, params)
    --[[ `params` is the PLUGIN's table, and it is checked where the plugin reads it rather than
    here: the names are that plugin's own declaration, so distribute seals what its offer() builds
    and checks it on the way back in. All this file owes is that every declared name arrived, which
    missing_param answers below. ]]
    ast.check_ns(ns)
    ast.check_node(root, "root")
    local spec = REGISTRY[id]
    if not spec then
        return nil, "no such transformation: " .. tostring(id)
    end
    --[[ Checked BEFORE the parameters, because "that transformation is switched off" is the more
    useful answer when both are true, and because an option built while the plugin was still on may
    still be sitting in an open menu. ]]
    if not spec.active then
        return nil, "'" .. id .. "' is not enabled"
    end
    local missing = missing_param(spec, params)
    if missing then
        return nil, "'" .. id .. "' needs a `" .. missing .. "`"
    end
    --[[ `params or {}` here and NOT inside make_ctx: apply has always handed its plugin a table,
    and that stays true. An offer gets nil instead, which is what CTX_FIELDS says - parameters are
    what an offer produces, not something it is given. ]]
    local ok, res = guarded(spec.apply, make_ctx(ns, root, params or {}))
    if not ok then
        return nil, res
    end
    return res
end

--[[ Everything that can be done at one ast node.

ASKED ON EVERY RIGHT-CLICK, so it must be cheap and must never throw at the user: a plugin that
refuses inside its own offer() simply contributes nothing, which is the same answer as not being
applicable. Only a real crash gets through, and that is deliberate - see `guarded`.

An option is {id, label, params}: ids and plain values, never a closure over the tree. That is what
lets one sit in a menu across frames, be logged, and be handed to `apply` later without keeping a
whole namespace alive.

Params: `node` is the ast node the pointer resolved to, NOT the root - aim is the gesture. `root` is
still needed because most offers have to look at the node's surroundings to answer.

Returns a list, empty when nothing applies. Empty is the common answer and is not a failure.
@date 2026-09-12 01:25 ]]
function transforms.offers(ns, root, node)
    ast.check_ns(ns)
    ast.check_node(root, "root")
    local out = {}
    --[[ A NIL `node` IS A REAL ANSWER and the only one of the three that is: ast_gestures.node_at
    returns nil for a right-click on empty space, for a glyph carrying no ast_id, and for an id
    that misses in this namespace - its own comment says so - and ast_gestures.options hands that
    result straight here. So an empty list stays the answer, and anything that IS there has to be a
    node.

    `ns` and `root` used to share this guard, which turned a missing namespace into "nothing
    applies" - the same empty list a plain `a+b` gives, and indistinguishable from it. They cannot
    legitimately be nil: options() returns early when ast_for produced no tree, so by the time this
    is reached both exist or the caller has a bug. ]]
    if node == nil then
        return out
    end
    ast.check_node(node, "node")
    for _, spec in ipairs(ORDER) do
        if spec.active and spec.offer then
            local ok, res = guarded(spec.offer, make_ctx(ns, root, nil, node))
            if ok and res then
                --[[ One option or several, so the common case - exactly one - does not have to be
                written as a single-element list by every plugin. ]]
                --[[ WHAT A PLUGIN HANDED BACK IS CHECKED HERE, at the boundary with code this
                file did not write and cannot see. A plugin building its option by hand instead of
                through transforms.option would otherwise produce something that draws in the menu
                and refuses when run. `is` rather than `check` for the one/many test, because "is
                this a single option" is a question; being neither an option nor a list of them is
                the error. ]]
                if OPTION_SHAPE.is(res) then
                    out[#out + 1] = res
                else
                    for _, opt in ipairs(res) do
                        out[#out + 1] = OPTION_SHAPE.check(opt, "an option from " .. spec.id)
                    end
                end
            end
        end
    end
    return out
end

--[[ Which transformations are NOT in their default state, as text.

Core: configuration, not document - the same standing as keymap.save and glyphmap.save, and written
to its own file for the same reason. Someone else's copy of this project should not inherit which
plugins you happen to have ticked.

Core: ONLY DIVERGENCES ARE WRITTEN, exactly as keymap.serialize does it. A plugin sitting at its own
`default_active` produces no line, so the file stays short, and a plugin whose default CHANGES later
is not held to the old value by a stale entry nobody remembers writing.

Detail: one `id<TAB>on|off` per line. Unknown ids are not this function's problem - `load` below
ignores them, which is what makes a savefile survive a plugin being deleted.

Returns the text, possibly empty - which is the correct content for "everything is as it shipped".
@date 2026-09-12 02:30 ]]
function transforms.serialize()
    local lines = {}
    for _, spec in ipairs(ORDER) do
        if spec.active ~= (spec.default_active == true) then
            lines[#lines + 1] = spec.id .. "\t" .. (spec.active and "on" or "off")
        end
    end
    return table.concat(lines, "\n")
end

--[[ Applies a saved activation state over the plugins that loaded.

Core: LOADING IS NOT REGISTRATION. The plugins are already there, put there by the scan at the
bottom of this file; this only flips flags on them. So a savefile can never bring a transformation
into existence, and a hand-edited one cannot make the editor run something that is not in the
folder.

Detail: a line naming an id nothing answers to is SKIPPED, not an error. That is the ordinary case
after a plugin file is deleted or renamed, and refusing the whole file over it would lose every
other setting in it. The count of skipped lines comes back so a caller can say so if it wants to.

Params: `text` as serialize() produced it; nil or empty is valid and means "leave every default
alone". Returns applied, skipped.
@date 2026-09-12 02:30 ]]
function transforms.load(text)
    local applied, skipped = 0, 0
    for line in tostring(text or ""):gmatch("[^\n]+") do
        local id, state = line:match("^(%S+)%s+(%S+)%s*$")
        if id then
            if transforms.set_active(id, state == "on") then
                applied = applied + 1
            else
                skipped = skipped + 1
            end
        end
    end
    --[[ What was just read IS what is on disk, so reading it is not a change to write back. ]]
    dirty = false
    return applied, skipped
end

--[[ THE PLUGIN FOLDER, scanned at load.

Core: EVERY FILE IN scripts/transforms IS A TRANSFORMATION, and there is no list to keep in step
with it. Dropping a file in makes it appear in the F2 panel; deleting one removes it from the
application entirely. What a scan cannot decide is whether it should RUN - that is `active`, and it
is off unless the plugin says otherwise.

Core: the directory is read through vc.path_list_dir, which resolves against the EXECUTABLE's own
directory rather than the working directory, so the app finds its plugins wherever it is launched
from. The test harness lives elsewhere, which is why tests/run_tests.py mirrors scripts/ next to the
harness binary before every run.

Detail: kept at the BOTTOM because each plugin requires this file back - the cycle package.loaded
breaks at the top. Names are required as `transforms.<base>`, which package.path resolves to
scripts/transforms/<base>.lua; the same module_name-with-a-dot route require already uses, so a
plugin is loaded exactly like any other module.

Note: an empty folder and a MISSING BINDING look the same from here - no plugins either way - so the
second is recorded in `transforms.load_error` rather than passing silently. It means path_composer
was not registered, which is a wiring fault and not an empty folder.
@date 2026-09-12 02:30 ]]
local PLUGIN_DIR = "scripts/transforms"

if not vc.path_list_dir then
    transforms.load_error = "vc.path_list_dir is missing - path_composer is not registered"
else
    for _, file in ipairs(vc.path_list_dir(PLUGIN_DIR)) do
        local base = file:match("^(.+)%.lua$")
        if base then
            require("transforms." .. base)
        end
    end
end

return transforms

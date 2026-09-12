--[[
test_api_manifest.lua - every public function of a migrated script is named in that file's manifest.

THE ASSUMPTION THIS GUARDS. Each scripts/*.lua opens with a "WHAT THIS FILE OFFERS" block listing
what a caller may reach, so the interface can be read without reading the file. That block is prose,
maintained by hand, and nothing makes it true. The failure is silent and one-directional: a function
added later just does not appear, the block still reads as complete, and a reader who trusts it
concludes the function does not exist.

That is worse than having no block at all - the skill this repo writes comments by says a comment
describing three of five behaviours stops the reader looking any further. So the block needs an
alarm, and this is it.

STATIC, LIKE test_no_use_before_define. It reads the sources as text and never loads them, so it
does not care which code paths run and cannot be fooled by a module that fails to require.

WHAT IT DOES NOT CHECK, deliberately: whether an entry is ACCURATE. A manifest line that describes
the wrong thing passes here. Only presence is mechanical; truth is a reading, and a test asserting
it would be asserting one session's reading of the prose.

TWO LISTS, and the split is the rollout. MIGRATED files must have a complete manifest and fail if
they do not. PENDING files are the ones the convention has not reached yet - counted and printed, so
the remaining work is visible, but not failed. Moving a name from one list to the other is the last
step of migrating a file.
@date 2026-09-12 01:25
]]

package.path = package.path .. ";./scripts/?.lua"

local checks_run, checks_failed = 0, 0
local function check(name, cond, got)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name .. (got ~= nil and ("  (got: " .. tostring(got) .. ")") or ""))
    end
end

--[[ Files whose manifest is written and must stay complete. @date 2026-09-12 01:25 ]]
local MIGRATED = {"editor", "transforms", "transforms_old", "transforms/distribute",
                  "ast_gestures", "ast", "ast_mexpr", "editor_formula", "input_recorder",
                  "editor_definition", "mformula_latex", "panel_help", "panel_keymap", "main",
                  "prof", "glyphmap", "content", "keymap", "mexpr_ast", "char", "mexpru", "editor_text", "sealed",
                  "mformula_new"}

--[[ Files the convention has not reached yet. Counted, not failed. Move a name up as it is done.
@date 2026-09-12 01:25 ]]
local PENDING = {}

--[[ Blanks long comments, keeping newlines so nothing shifts. Needed because the manifest block
itself is a comment full of function names - without this, every file would appear to define
everything it documents. @date 2026-09-12 01:25 ]]
local function strip_long_comments(src)
    local out, i, n = {}, 1, #src
    while i <= n do
        local eq = src:match("^%-%-%[(=*)%[", i)
        if eq then
            local close = src:find("%]" .. eq .. "%]", i, false)
            local chunk = src:sub(i, close and (close + #eq + 1) or n)
            out[#out + 1] = (chunk:gsub("[^\n]", " "))
            i = i + #chunk
        else
            out[#out + 1] = src:sub(i, i)
            i = i + 1
        end
    end
    return table.concat(out)
end

local function read(name)
    local f = io.open("scripts/" .. name .. ".lua", "r")
    if not f then
        return nil
    end
    local src = f:read("*a")
    f:close()
    return src
end

--[[ The manifest block's text, or nil when the file has none.

Matched on the banner rather than on "the first comment", because every one of these files already
opened with a prose header before the manifest existed and the two are separate blocks on purpose:
the header says what the module IS, the manifest says what you may call.
@date 2026-09-12 01:25 ]]
local function manifest_of(src)
    return src:match("(WHAT THIS FILE OFFERS.-%]%])")
end

--[[ The module table's name, taken from the file's own `return`, and every public name hung on it.

READ FROM THE RETURN rather than assumed to be the filename, because it is the return that decides
what a caller actually gets. A file returning something other than a table - transform_distribute
returns a marker - has no public surface at all, and that is a real answer, not a failure to parse.

BOTH SPELLINGS COUNT. `function M.foo()` is the common one, and `M.foo = foo` is how a file exposes
an internal it also uses locally (mformula_new.select_all, editor_text.push_undo). A manifest that
listed only the first kind would be exactly the silent omission this test exists for.
@date 2026-09-12 01:25 ]]
local NOT_A_MODULE = {["true"] = true, ["false"] = true, ["nil"] = true}

local function public_names(src)
    local mod = src:match("\nreturn%s+([%w_]+)%s*$") or src:match("\nreturn%s+([%w_]+)%s*\n%s*$")
    --[[ `return true` is a plugin's marker, not a module table, and a bare number would be one too.
    Both mean the same thing here: nothing is reachable through the return, so there is no public
    surface to check. Caught by this test's own "no public functions at all" check on the first run
    against transform_distribute.lua. ]]
    if not mod or NOT_A_MODULE[mod] or tonumber(mod) then
        return nil, {}
    end
    local names, seen = {}, {}
    local function add(n)
        if n and not seen[n] then
            seen[n] = true
            names[#names + 1] = n
        end
    end
    for line in src:gmatch("[^\n]+") do
        add(line:match("^function%s+" .. mod .. "%.([%w_]+)"))
        add(line:match("^" .. mod .. "%.([%w_]+)%s*="))
    end
    return mod, names
end

--[[ The functions a plugin publishes through transforms.register, by the name they are defined
under in the file.

A SECOND WAY TO BE PUBLIC, and the reason this exists: a transform plugin has no module table, so
public_names above finds nothing in it, and by that reading the file would have no interface to
check. It does have one - `offer` and `apply` are handed to transforms.lua, which is the only caller
either of them ever gets. Being `local` there is how a plugin is delivered, not a claim that nobody
outside calls them. Corrected by the author, 2026-09-12, after the first manifest filed both as
internal.

Braces are counted rather than matched with a pattern, because the spec table has a nested one
(`params = {"add"}`) and a non-greedy `.-}` stops inside it.
@date 2026-09-12 01:50 ]]
local function registered_names(src)
    local at = src:find("transforms%.register")
    if not at then
        return {}
    end
    local open = src:find("{", at, true)
    if not open then
        return {}
    end
    local depth, i, n = 0, open, #src
    local close
    while i <= n do
        local c = src:sub(i, i)
        if c == "{" then
            depth = depth + 1
        elseif c == "}" then
            depth = depth - 1
            if depth == 0 then
                close = i
                break
            end
        end
        i = i + 1
    end
    if not close then
        return {}
    end

    local names = {}
    for line in src:sub(open, close):gmatch("[^\n]+") do
        --[[ `offer = offer,` - a bare identifier on the right. `id = "distribute"` and
        `params = {"add"}` are values, not functions, and do not match. ]]
        local value = line:match("^%s*[%w_]+%s*=%s*([%w_]+)%s*,?%s*$")
        if value and src:find("local function " .. value .. "%s*%(") then
            names[#names + 1] = value
        end
    end
    return names
end

--[[ Files exempt from the header check below, and why.

`transforms_old` is FROZEN. Its `find` has carried no comment since it was written, and giving it
one would be editing exploratory work the author has said not to touch - the repo rule that made the
file exist in the first place. Its manifest already says, in one line, that nothing in it runs.
@date 2026-09-12 02:05 ]]
local NO_HEADER_CHECK = {transforms_old = true}

--[[ Does a documented comment block sit directly above `fname`'s definition?

THE OTHER HALF OF THE CONVENTION, and the half the manifest depends on. Author, 2026-09-12: the
manifest stays small, and "the functions that where named will now have large descriptions where you
find them". A manifest entry is a pointer - it says a function exists and what it promises in two
lines - and it is only useful if scrolling to the function finds the contract spelled out. An
exported function with a thin header, or none, makes the manifest a promise the file does not keep.

Checked mechanically: the line above the definition ends a block comment, and that block carries an
`@date`. Presence, not quality - the skill's shape is a reading and cannot be asserted. It does
catch the two real failures, which are a function documented nowhere and a comment left undated.
@date 2026-09-12 02:05 ]]
local function has_header(lines, fname)
    --[[ THE MODULE-QUALIFIED FORM WINS, and is looked for across the whole file before the local
    one is considered. A file may hold both - glyphmap has `local function key_label` doing the work
    and `function glyphmap.key_label` exporting it - and it is the EXPORTED one whose header this
    convention is about. Taking whichever came first in the file reported glyphmap.key_label as
    undocumented while its header sat two lines above the export. ]]
    local forms = {"^function%s+[%w_]+%.(" .. fname .. ")%s*%(",
                   "^local function%s+(" .. fname .. ")%s*%(",
                   "^" .. fname .. "%s*=%s*function"}
    local at
    for _, form in ipairs(forms) do
        for i, line in ipairs(lines) do
            if line:match(form) then
                at = i
                break
            end
        end
        if at then
            break
        end
    end

    for i, line in ipairs(lines) do
        if i == at then
            local above = lines[i - 1]
            if not (above and above:match("%]%]%s*$")) then
                return false
            end
            for j = i - 1, 1, -1 do
                if lines[j]:match("^%s*%-%-%[%[") then
                    return table.concat(lines, "\n", j, i - 1):find("@date", 1, true) ~= nil
                end
            end
            return false
        end
    end
    --[[ Named in a manifest but not defined in the file: a different failure, and one the presence
    check above would report as "no header". Reported honestly as what it is. ]]
    return nil
end

--[[ The parameter list a manifest entry advertises, per function.

WHY THIS IS CHECKED AT ALL. A manifest entry is read INSTEAD of the function, so a parameter list
that has drifted is worse than none - it is a wrong answer given confidently. Three were wrong when
this check was first written, `ast.ns_insert_object(ns, node)` against a real `(ns, id, obj)` among
them, and nothing had noticed.

TYPES ARE STRIPPED before comparing. An entry reads `draw(container: mformula.container, sz: size)`
and the code has only names, so the annotation is the manifest's to carry and cannot be verified
here - what CAN be verified is that the names and their order match, which is what a caller uses.

TWO ENTRIES MAY SHARE A LINE - `dirty() / clear_dirty()` - because a pair that differs only in
direction reads better together. Both are picked up.

A SIGNATURE MAY WRAP, so parentheses are counted rather than matched with a pattern.
@date 2026-09-12 07:05 ]]
local function manifest_params(manifest)
    local sigs = {}
    local lines = {}
    for line in (manifest .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = line
    end
    local i = 1
    while i <= #lines do
        local ln = lines[i]
        if ln:match("^[a-z_][%w_]*%(") then
            local joined, depth = ln, 0
            for c in ln:gmatch("[()]") do
                depth = depth + (c == "(" and 1 or -1)
            end
            while depth > 0 and i < #lines do
                i = i + 1
                joined = joined .. " " .. lines[i]:gsub("^%s+", "")
                for c in lines[i]:gmatch("[()]") do
                    depth = depth + (c == "(" and 1 or -1)
                end
            end
            local head = joined:match("^(.-)%s*%->") or joined
            for part in (head .. " / "):gmatch("(.-)%s*/%s*") do
                local fn, args = part:match("^([a-z_][%w_]*)%((.*)%)%s*$")
                if fn then
                    sigs[fn] = args
                end
            end
        end
        i = i + 1
    end
    return sigs
end

--[[ `a: {x, y}, b` -> {"a", "b"} - the parameter NAMES an entry advertises.

BRACE-AWARE, because a type may contain a comma: `pos: {x, y}` is one parameter, and splitting the
string on every comma made it two. That was this check's own first twelve failures, all of them its
fault rather than the manifests'.

The type is whatever follows the first colon at depth zero, and is dropped - it is the manifest's to
carry and there is nothing in the source to verify it against.
@date 2026-09-12 07:10 ]]
local function param_names(args)
    local pieces, buf, depth = {}, "", 0
    for k = 1, #args do
        local c = args:sub(k, k)
        if c == "{" or c == "(" then
            depth = depth + 1
        elseif c == "}" or c == ")" then
            depth = depth - 1
        end
        if c == "," and depth == 0 then
            pieces[#pieces + 1] = buf
            buf = ""
        else
            buf = buf .. c
        end
    end
    pieces[#pieces + 1] = buf

    local names = {}
    for _, piece in ipairs(pieces) do
        piece = piece:gsub("%s*:.*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
        if piece ~= "" then
            names[#names + 1] = piece
        end
    end
    return names
end

--[[ The real parameter list of every function a file publishes, by either route.

BOTH ROUTES, because a plugin has neither a module table nor a `mod` to match against: its `offer`
and `apply` are `local function`s handed to transforms.register, and checking only `M.name` left
the one file whose contract is read from outside this project entirely unchecked. Author,
2026-09-12: "the ctx type is not documented in the manifest and not checked".

`mod` may be nil, which is exactly the plugin case.
@date 2026-09-12 07:40 ]]
local function real_params(src, mod)
    local out = {}
    for line in src:gmatch("[^\n]+") do
        if mod then
            local fn, args = line:match("^function%s+" .. mod .. "%.([%w_]+)%s*%(([^)]*)%)")
            if fn and out[fn] == nil then
                out[fn] = args
            end
        end
        local lfn, largs = line:match("^local function%s+([%w_]+)%s*%(([^)]*)%)")
        if lfn and out[lfn] == nil then
            out[lfn] = largs
        end
    end
    return out
end

--[[ Is this public name a FUNCTION, as opposed to a constant or a data table?

Decided from the SOURCE rather than from the manifest, because it decides what the manifest is
required to say: a function owes a signature, a table of glyphs does not. char.lua publishes
fourteen data tables and mexpru four constants, and demanding `chars(...)` of them would be asking
for a lie.
@date 2026-09-12 09:00 ]]
local function is_function(src, mod, fn)
    if mod and src:find("function " .. mod .. "." .. fn .. "(", 1, true) then
        return true
    end
    return src:find("local function " .. fn .. "(", 1, true) ~= nil
end

--[[ Is `fn` listed as an ENTRY in the manifest, as opposed to merely mentioned in its prose?

AN ENTRY STARTS AT COLUMN ZERO and prose is indented - that is the format every manifest here
follows, and it is the only thing separating "this is part of the interface" from "this sentence
happens to name it". The distinction is not pedantic: `new_sum` appears in ast.lua's prose
explaining that generated functions have no definition line, and a plain substring search was
satisfied by that sentence alone. The check passed while the family was undocumented, which is the
same false comfort a bare mention gave the static pass before it was tightened.

Whole-word, so `new_sup` does not answer for `new_sum`.
@date 2026-09-12 11:00 ]]
local function listed_as_entry(manifest, fn)
    for line in (manifest .. "\n"):gmatch("([^\n]*)\n") do
        if line:match("^%S") then
            for token in line:gmatch("[%w_]+") do
                if token == fn then
                    return true
                end
            end
        end
    end
    return false
end

--[[ Public names that exist only at RUNTIME, found by asking the module rather than reading it.

WHY A SECOND PASS AT ALL. Everything above is static, deliberately - it cannot be fooled by a module
that fails to require, and it reports on files rather than on what happened to load. But a function
BUILT IN A LOOP has no definition line to read: ast.lua writes
`ast["new_" .. name:lower()] = function(...)` for every row of GROUP_BIGOP_SYMBOL, so thirteen public
constructors - new_sum, new_prod, new_lim and the rest - were invisible to the text scan and
therefore to every check built on it. They were not in the manifest, and nothing said so.

WHAT THIS PASS COSTS is the property the static one was protecting: it requires the module, so a
module that fails to load fails here. That is acceptable because it fails loudly and because every
other test in this suite requires these modules anyway - but it is the reason this is a separate,
clearly-marked pass rather than a change to the scan above.

Returns only names the static pass did NOT find, so the two do not report the same thing twice.
@date 2026-09-12 10:45 ]]
local function runtime_only_names(name, static_names)
    local ok, mod = pcall(require, name)
    if not ok or type(mod) ~= "table" then
        return {}
    end
    local seen = {}
    for _, n in ipairs(static_names) do
        seen[n] = true
    end
    local out = {}
    for key, value in pairs(mod) do
        if type(value) == "function" and type(key) == "string" and not seen[key] then
            out[#out + 1] = key
        end
    end
    table.sort(out)
    return out
end

function run_test()
    for _, name in ipairs(MIGRATED) do
        local raw = read(name)
        check(name .. ".lua exists", raw ~= nil)
        if raw then
            local manifest = manifest_of(raw)
            check(name .. ".lua has a manifest block", manifest ~= nil)
            if manifest then
                local code = strip_long_comments(raw)
                local mod, names = public_names(code)
                --[[ A plugin's interface reaches transforms.lua through the spec table rather than
                through a module table, and is just as external for it. ]]
                for _, fn in ipairs(registered_names(code)) do
                    names[#names + 1] = fn
                end
                for _, fn in ipairs(names) do
                    --[[ A SIGNATURE, not a mention. `fn` followed by `(` - because a name listed
                    bare in a group ("new_in  new_ni  new_subset") satisfied the old substring test
                    while carrying no parameters at all, so the parameter check below silently
                    skipped it. Sixty-six names were hiding that way, among them every relation
                    constructor in ast.lua. Author, 2026-09-12: "all those dont get properly
                    declared in the manifest and don't check lhs, rhs".

                    A DATA TABLE is exempt: it is not callable, so it has no signature to give.
                    `is_function` decides that from the source, not from the manifest.

                    A plugin has no module table, so its entry is named bare rather than as
                    `nil.offer`. ]]
                    local shown = mod and (mod .. "." .. fn) or fn
                    local wants_sig = is_function(code, mod, fn)
                    check(string.format("%s.lua: `%s` is %s", name, shown,
                            wants_sig and "not declared with a signature in the manifest"
                                    or "not named in the manifest"),
                            manifest:find(wants_sig and (fn .. "(") or fn, 1, true) ~= nil)

                    if not NO_HEADER_CHECK[name] then
                        local lines = {}
                        for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
                            lines[#lines + 1] = line
                        end
                        local found = has_header(lines, fn)
                        --[[ A NAME WITH NO FUNCTION DEFINITION IS A CONSTANT or a re-export, not an
                        undocumented function: mexpru publishes MAX_SIZE_INDEX = 18 and rebinds
                        `same` through prof.wrap after defining it. Both belong in the manifest - a
                        caller reaches them - but the comment skill is explicit that a trailing note
                        on a constant is not a documented target, and a re-export's header sits on
                        the definition it re-exports. So they are required to be NAMED and exempt
                        from the header check. ]]
                        if found ~= nil then
                            check(string.format(
                                    "%s.lua: `%s` is exported but has no dated comment header",
                                    name, shown), found)
                        end
                    end
                end
                --[[ A file with a module table and no public names is almost certainly a parse
                miss on this test's side rather than a real empty interface. ]]
                if mod then
                    check(name .. ".lua: found no public functions at all - parser problem?",
                            #names > 0, mod)
                end

                --[[ GENERATED functions, which the text scan cannot see. They are required to be
                NAMED in the manifest; a signature and a per-function header are not, because there
                is no definition line for either to sit on - the loop that builds them carries one
                comment for the whole family. ]]
                for _, fn in ipairs(runtime_only_names(name, names)) do
                    check(string.format("%s.lua: `%s.%s` is generated at runtime and is not named "
                            .. "in the manifest", name, mod or name, fn),
                            listed_as_entry(manifest, fn))
                end

                --[[ The advertised parameter list against the real one, for a module's functions
                and a plugin's alike. Names and order only; the types an entry carries are the
                manifest's own, and there is nothing in the source to check them against. ]]
                local advertised = manifest_params(manifest)
                local actual = real_params(code, mod)
                for _, fn in ipairs(names) do
                    if advertised[fn] and actual[fn] then
                        local want = table.concat(param_names(actual[fn]), ", ")
                        local got = table.concat(param_names(advertised[fn]), ", ")
                        check(string.format("%s.lua: `%s` is documented as (%s) but takes (%s)",
                                name, fn, got, want), got == want)
                    end
                end
            end
        end
    end

    local pending = 0
    for _, name in ipairs(PENDING) do
        if read(name) then
            pending = pending + 1
        end
    end
    print("manifests: " .. #MIGRATED .. " migrated, " .. pending .. " still to write")

    print("checks: " .. checks_run .. ", failed: " .. checks_failed)
    if checks_failed > 0 then
        return false
    end
    print("PASS: every migrated file's manifest names its whole public surface")
    return true
end

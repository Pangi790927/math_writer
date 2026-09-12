--[[ ==================================== WHAT THIS FILE OFFERS ====================================

run_test()                              -> ok
    The suite's entry point. This file is a test, not a module.
@date 2026-09-12 04:45
================================================================================================= ]]

--[[
test_container_fields.lua - every field used on a SEALED container is one that container declares.

THREE SEALED CONTAINERS, each created by exactly one function and read across files:

    u      mexpru.new_u()            a node's own table
    state  content.new_shell()       the whole document
    ctx    transforms.make_ctx()     what a transform plugin is handed

THE ASSUMPTION THIS GUARDS. Each is sealed: an undeclared name is refused on read and
on write, which turns a typo from a silently-created field into an error. That seal is a RUNTIME
one, and it only fires on a line that actually runs.

WHICH IS THE GAP. The draw path is not exercised by this suite at all - the harness is headless and
nothing here renders - and that is precisely where most `u` access lives. A field used only while
drawing would pass every test and then throw on screen, which is the same shape of hole
test_no_use_before_define.lua exists for. So this check is STATIC: it reads the sources as text and
asks the question for every access, run or not.

WHAT IT CANNOT SEE, deliberately. An access through a name this scan does not recognise as a `u`
table - a field reached off a local several assignments away, or a sub-table like `u.bracket.type` -
is not checked. Sub-tables are a separate question: `u.bracket` is declared as a field, what is
INSIDE it is not sealed, and pretending otherwise here would report a coverage this does not have.

A FAILURE IS NOT "STOP USING THAT FIELD". It means U_FIELDS in mexpru.lua is out of date, or the
access is a typo. Both are fixed by looking at the two, never by routing around the seal.
@date 2026-09-12 04:45
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

--[[ The files that touch a `u` table. Listed rather than scanned because Lua cannot enumerate a
directory (see test_no_use_before_define's own note); a file missing from here is simply unchecked,
which is why the count is printed. @date 2026-09-12 04:45 ]]
local FILES = {"mexpru", "mformula_new", "mformula_latex", "mexpr_ast", "ast_mexpr",
               "ast_gestures", "editor_definition", "content", "editor_text"}

--[[ Blanks comments so prose naming a field is not mistaken for an access. Long comments here are
full of `u(_).bracket` and similar. @date 2026-09-12 04:45 ]]
local function strip(src)
    local out, i, n = {}, 1, #src
    while i <= n do
        local eq = src:match("^%-%-%[(=*)%[", i)
        if eq then
            local close = src:find("%]" .. eq .. "%]", i, false)
            local chunk = src:sub(i, close and (close + #eq + 1) or n)
            out[#out + 1] = (chunk:gsub("[^\n]", " "))
            i = i + #chunk
        elseif src:sub(i, i + 1) == "--" then
            local nl = src:find("\n", i) or (n + 1)
            out[#out + 1] = string.rep(" ", nl - i)
            i = nl
        else
            out[#out + 1] = src:sub(i, i)
            i = i + 1
        end
    end
    return table.concat(out)
end

--[[ Every field name reached off a `u` table in `src`.

THE DIRECT FORM ONLY - `mexpru.u(node).field`. Following a local bound to one first was tried and
withdrawn the same day, because a text scan cannot tell which local is which:

  - `local br = mexpru.u(node).bracket` binds a SUB-TABLE, and `br.is_open` is not a `u` field at
    all. The scan reported four of those before the form was narrowed.
  - mexpr_ast calls its PARSER UNIT table `u` as well - a different container entirely, carrying
    `atom`, `node`, `call`, `quoted` - and a file-wide scan cannot separate the two scopes.

Narrow and sound beats wide and wrong here: a false alarm trains the reader to ignore this test,
while what the direct form misses is still caught at runtime by the seal itself. What is lost is
only the unrun-path coverage for accesses through a local, which is why this is a second line of
defence and not the first.
@date 2026-09-12 04:50 ]]
local function accesses(src)
    local found = {}
    --[[ One level of nested parens is allowed inside the call - `u(slot_atom(node))` is the common
    shape - which is as far as a Lua pattern reaches without a real parser. ]]
    for field in src:gmatch("mexpru%.u%([^()]*%)%.([%w_]+)") do
        found[field] = true
    end
    for field in src:gmatch("mexpru%.u%([^()]*%([^()]*%)[^()]*%)%.([%w_]+)") do
        found[field] = true
    end
    return found
end

--[[ Field names reached off `name.` in `src`, for a container bound to a plain local or parameter.

Sound only because the three names checked - `state`, `ctx` - are used for one thing each in the
files scanned. `u` gets the stricter call-form treatment above, since mexpr_ast uses that name for a
second container of its own. @date 2026-09-12 05:25 ]]
local function plain_accesses(src, name)
    local found = {}
    for field in src:gmatch("%f[%w_]" .. name .. "%.([%w_]+)") do
        found[field] = true
    end
    return found
end

local function read(path)
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local src = f:read("*a")
    f:close()
    return strip(src)
end

--[[ Which sealed container each variable name refers to, and where to scan for it.

The name IS the key, which is the point of renaming them: until 2026-09-12 four containers were all
called `state`, and a scan could not tell which declaration to check a field against. Each is now
named for what it is, at every call site, so this table is a list rather than a judgement.
@date 2026-09-12 06:30 ]]
local PLAIN = {
    {name = "state_doc",        file = "content"},
    {name = "state_text",       file = "editor_text"},
    {name = "state_definition", file = "editor_definition"},
    {name = "state_formula",    file = "editor_formula"},
    {name = "state_help",       file = "panel_help"},
    {name = "state_keymap",     file = "panel_keymap"},
}

function run_test()
    --[[ Requiring them is what puts their shapes in sealed.all() - a declaration is registered when
    its file loads, so a module nobody required is simply not listed. ]]
    for _, entry in ipairs(PLAIN) do
        require(entry.file)
    end
    require("mexpru")
    require("transforms")

    local shapes = {}
    for _, shape in ipairs(require("sealed").all()) do
        shapes[shape.name] = shape.fields
    end
    check("sealed.lua registered some shapes", next(shapes) ~= nil)

    -- ------------------------------------------------------------------ u, across every user
    check("`u` is declared", shapes.u ~= nil)
    local scanned = 0
    for _, name in ipairs(FILES) do
        local src = read("scripts/" .. name .. ".lua")
        if src and shapes.u then
            scanned = scanned + 1
            for field in pairs(accesses(src)) do
                check(string.format("%s.lua: `u.%s` is not declared", name, field),
                        shapes.u[field] ~= nil)
            end
        end
    end
    print("u: scanned " .. scanned .. " of " .. #FILES .. " files")

    -- ------------------------------------------------------------------ every named state
    for _, entry in ipairs(PLAIN) do
        local fields = shapes[entry.name]
        check("`" .. entry.name .. "` is declared", fields ~= nil)
        local src = read("scripts/" .. entry.file .. ".lua")
        if src and fields then
            for field in pairs(plain_accesses(src, entry.name)) do
                check(entry.file .. ".lua: `" .. entry.name .. "." .. field
                        .. "` is not declared", fields[field] ~= nil)
            end
        end
    end
    print("states: " .. #PLAIN .. " containers")

    -- ------------------------------------------------------------------ every plugin's ctx
    check("`ctx` is declared", shapes.ctx ~= nil)
    local plugins = 0
    for _, spec in ipairs(require("transforms").list()) do
        local src = read("scripts/transforms/" .. spec.id .. ".lua")
        if src and shapes.ctx then
            plugins = plugins + 1
            for field in pairs(plain_accesses(src, "ctx")) do
                check("transforms/" .. spec.id .. ".lua: `ctx." .. field .. "` is not declared",
                        shapes.ctx[field] ~= nil)
            end
        end
    end
    print("ctx: scanned " .. plugins .. " plugin(s)")

    print("checks: " .. checks_run .. ", failed: " .. checks_failed)
    if checks_failed > 0 then
        return false
    end
    print("PASS: every field used on a sealed container is declared")
    return true
end

--[[
test_no_use_before_define.lua - no script calls a local function declared later in its own file.

In Lua a local is not in scope before its declaration, so a call written ABOVE `local function f`
does not reach that local at all - it silently resolves to a GLOBAL of the same name, which is nil,
and throws only when that line actually runs.

This exists because it happened, 2026-09-06: innermost_unclosed_open() was added at line 1548 and
called from the cursor-drawing code at line 683. Every frame threw. The whole suite still passed,
because this harness is headless and never runs the draw path - so nothing caught it, and it
surfaced only as the running app visibly pulsing.

That is the gap: a nil-call anywhere in drawing is invisible to every other test here. This one is
static instead - it reads the sources as text, so it does not care which paths run.

A forward declaration (`local f` on its own, before the use) is the correct fix and is accepted.
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

--[[ Blanks out comments and string literals, keeping line structure intact so line numbers still
line up. Necessary because this codebase's comments are dense with prose like "see foo()" - without
stripping them the check is pure noise. ]]
local function strip(src)
    local out, i, n = {}, 1, #src
    local function emit(s) out[#out + 1] = s end
    while i <= n do
        local c = src:sub(i, i)
        local two = src:sub(i, i + 1)
        if two == "--" then
            local long = src:match("^%-%-%[(=*)%[", i)
            if long then
                -- a block comment: blank it, but keep every newline it spans
                local close = src:find("%]" .. long .. "%]", i)
                local chunk = src:sub(i, close and close + #long + 1 or n)
                emit((chunk:gsub("[^\n]", " ")))
                i = i + #chunk
            else
                local nl = src:find("\n", i) or (n + 1)
                emit(string.rep(" ", nl - i))
                i = nl
            end
        elseif c == '"' or c == "'" then
            local j, q = i + 1, c
            while j <= n do
                local d = src:sub(j, j)
                if d == "\\" then j = j + 2
                elseif d == q or d == "\n" then break
                else j = j + 1 end
            end
            emit(string.rep(" ", math.min(j, n) - i + 1))
            i = j + 1
        else
            emit(c)
            i = i + 1
        end
    end
    return table.concat(out)
end

local FILES = {"char", "mexpru", "mexpr", "mformula_new", "mformula_latex", "editor",
               "content", "transforms", "ast", "prof", "input_recorder"}

function run_test()
    for _, name in ipairs(FILES) do
        local f = io.open("scripts/" .. name .. ".lua", "r")
        if f then
            local src = strip(f:read("*a"))
            f:close()

            -- line number of every `local function NAME`, and of every bare `local NAME`
            local defined, forward, line = {}, {}, 0
            for text in src:gmatch("[^\n]*") do
                line = line + 1
                local fn = text:match("^%s*local%s+function%s+([%w_]+)")
                if fn and not defined[fn] then
                    defined[fn] = line
                end
                local fwd = text:match("^%s*local%s+([%w_]+)%s*$")
                if fwd and not forward[fwd] then
                    forward[fwd] = line
                end
            end

            -- ...then every call site, and whether it can actually see that local
            line = 0
            for text in src:gmatch("[^\n]*") do
                line = line + 1
                for callee in text:gmatch("([%w_]+)%s*%(") do
                    local def = defined[callee]
                    if def and line < def then
                        local fwd = forward[callee]
                        check(string.format(
                                "%s.lua:%d calls %s() but its local is declared at line %d"
                                .. " (needs a forward declaration)",
                                name, line, callee, def),
                                fwd ~= nil and fwd < line)
                    end
                end
            end
        end
    end

    print("checks: " .. checks_run .. ", failed: " .. checks_failed)
    if checks_failed > 0 then
        return false
    end
    print("PASS: no local function is called before it is in scope")
    return true
end

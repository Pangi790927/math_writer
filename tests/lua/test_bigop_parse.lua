--[[
test_bigop_parse.lua - building a big operator from a TYPED ROW: which names it spawns as variables,
in which order, and what it leaves free.

WHY THIS FILE EXISTS SEPARATELY FROM test_bigop_nodes.lua. That one builds nodes directly and hands
`vars` in by hand - `ast.new_sum(ns, {"i","j"}, ...)` - so it asserts that the CONSTRUCTOR keeps the
order it was given. Nothing there exercises the code that DECIDES that order, and a real ordering bug
lived in that gap: `read_constraints` drained a set with `pairs`, Lua randomises its string-hash seed
per process, and `\sum_{i=j}(i+j)` built vars `i,j` in one run and `j,i` in the next. One formula,
two trees, on a project whose identity scheme is exact structural equality - and 70 green tests
throughout, because none of them came in through the parser.

SO THE ASSERTIONS HERE ALL START FROM LATEX and read what came out, never from a hand-built node.

THE COUNTS MOVED ON 2026-09-11, and this file fired because of it - "SUM 1 var/1 sub/1 sup" is now
"SUM 1 var/1 sup/1 sub". The operator's shape gained no slots and lost none: the SUP side simply
comes first, in the node and therefore in everything that prints it, because the sup is drawn ABOVE
the operator and a listing that put the sub first read upside down. Requested live: "put sub under
sup in f5, that is really strange", then "like, flip the serialization maybe?".

WHAT DID NOT CHANGE, and it is worth saying because this file is entirely about it: which side
SPAWNS the variables. That is still the sub, minus whatever the sup also mentions - "sub minus sup"
below is unaffected, and reads the same way it always did. Which side is written first and which
side declares are two different questions, and only the first one moved.

A NOTE ON THE FIRST CASE, so nobody "fixes" it later: if the ordering bug comes back, that check
fails on roughly half of runs rather than all of them, because the hash seed changes per process. A
tripwire that fires intermittently is doing its job here - the intermittency IS the symptom. Loosen
it and the alarm is gone.
]]

package.path = package.path .. ";./scripts/?.lua"

local char = require("char")
local mexpru = require("mexpru")
local mformula_latex = require("mformula_latex")
local mexpr_ast = require("mexpr_ast")

local checks_run, checks_failed = 0, 0
local function check(name, cond, got)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name .. (got ~= nil and ("  (got: " .. tostring(got) .. ")") or ""))
    end
end

-- The parse as one flat string, the way test_ast_view.lua reads a tree.
local function view(fs, latex)
    local c = mformula_latex.from_latex(fs, mexpru.DEFAULT_SIZE, latex)
    if not c then
        return "<from_latex failed>"
    end
    local parts = {}
    for _, l in ipairs(mexpr_ast.describe(fs, c, {})) do
        parts[#parts + 1] = l.depth .. ":" .. l.text
    end
    return table.concat(parts, " / ")
end

local function build(fs, latex)
    local c = mformula_latex.from_latex(fs, mexpru.DEFAULT_SIZE, latex)
    return mexpr_ast.build(fs, c, {})
end

function run_test()
    local fs = char.load_font_set()

    -- ------------------------------------------------- the order variables are spawned in
    do
        --[[ TWO NAMES OUT OF ONE CONSTRAINT, which is the only way to see the order at all: `i=j`
        is a symmetric relation, so both sides are eligible and both are free. They become the
        operator's variables in slots 4 and 5, so their order IS the tree's shape - ast.to_string
        writes it and structural equality reads it.

        FIRST-SEEN, meaning the order they were written in. Not sorted: sorting would be a second
        rule to remember, and would make `\sum_{j=i}` and `\sum_{i=j}` the same tree when they are
        not the same formula. ]]
        local v = view(fs, "\\sum_{i=j}(i+j)")
        check("two names from one constraint spawn in written order",
                v == [[0:SUM 2 var/0 sup/1 sub / 1:VAR i / 1:VAR j / 1:EQ / 2:REF "i" / 2:REF "j"]]
                        .. [[ / 1:CELL / 2:ADD / 3:REF "i" / 3:REF "j"]], v)

        --[[ The mirror image, to catch a walk that happens to be stable but sorted: if `j,i` came
        back as `i,j` here, the order is not the row's. ]]
        v = view(fs, "\\sum_{j=i}(i+j)")
        check("...and the mirrored row spawns them mirrored",
                v:find("1:VAR j / 1:VAR i", 1, true) ~= nil, v)
    end

    -- ------------------------------------------------- inline limits and display limits
    do
        --[[ TWO NODE SHAPES, ONE TREE. `\sum_{i=1}` builds a SUPSUB (limits beside the sign) and
        `\sum\limits_{i=1}` builds a BIGOP (limits over and under). Only how they DRAW differs, so
        the parser must not be able to tell them apart - and until 2026-09-10 it told them apart on
        purpose, with a `bigop_of` reading the second shape off the atom directly, because
        `slot_atom` unwrapped a supsub and not a bigop.

        Widening `slot_atom` deleted that branch rather than fixing it: `unit()` now hands back the
        glyph and the limits the same way for both, so there is one shape to read. This case exists
        because the display path had NO test at all - the whole `bigop_of` branch could have been
        deleted outright without a single failure. ]]
        local inline = view(fs, "\\sum_{i=1}(i)")
        local display = view(fs, "\\sum\\limits_{i=1}(i)")
        check("display limits parse at all", display:find("SUM", 1, true) ~= nil, display)
        check("and build the identical tree to inline limits", inline == display,
                inline .. "  vs  " .. display)

        local both = view(fs, "\\sum\\limits_{i=1}^{n}(i)")
        check("a display bigop keeps both of its limits",
                both:find("SUM 1 var/1 sup/1 sub", 1, true) ~= nil, both)
    end

    -- ------------------------------------------------- sub minus sup
    do
        --[[ A NAME FREE ON BOTH SIDES CANCELS. `N` is exactly as undeclared as `i` when the sub
        constraint is read, so anything that registered names as it went would capture it; only
        computing the sup's own free set and subtracting afterwards leaves it free.

        The pair is what makes it an assertion rather than a coincidence - the same row without the
        sup spawns `N` too, so the sup is demonstrably what removed it. ]]
        local v = view(fs, "\\sum_{i=N}(i)")
        check("with no sup, both free names spawn",
                v:find("SUM 2 var/0 sup/1 sub", 1, true) ~= nil, v)

        v = view(fs, "\\sum_{i=N}^{N}(i)")
        check("a name the sup also mentions is left free",
                v:find("SUM 1 var/1 sup/1 sub", 1, true) ~= nil, v)
        check("...and it is still a reference in the tree", v:find([[1:REF "N"]], 1, true) ~= nil, v)
    end

    -- ------------------------------------------------- membership has an element side
    do
        --[[ `i \in S` is not symmetric: only the element side is eligible to be spawned. Found by
        live testing - it used to spawn `S` alongside `i`, since `S` is exactly as free and there is
        no sup to subtract it against. ]]
        local v = view(fs, "\\sum_{i \\in S}(i)")
        check("membership spawns the element, not the set",
                v:find("SUM 1 var/0 sup/1 sub / 1:VAR i", 1, true) ~= nil, v)
        check("...and the set stays a free reference", v:find([[2:REF "S"]], 1, true) ~= nil, v)
    end

    -- ------------------------------------------------- shadowing, through the parser
    do
        --[[ THE INNER OPERATOR OWNS ITS OWN `i`. Checked by ID rather than by the rendered name,
        because the viewer prints a reference by the name it points at - so two different variables
        both called `i` render identically and a name-based assertion would pass either way. ]]
        local node = build(fs, "\\sum_{i=1}(\\sum_{i=2}(i))")
        check("the nested row builds", node ~= nil, node)

        local outer_var = node[4]
        local inner = node[#node][1]          -- body is a CELL; the inner sum is inside it
        local inner_var = inner[4]
        local inner_body = inner[#inner]

        check("the two operators made different variables", outer_var.id ~= inner_var.id,
                outer_var.id)
        check("and the inner body is bound to the inner one",
                inner_body.type ~= nil and inner_body[1] == inner_var.id, inner_body[1])
    end

    if checks_failed == 0 then
        print("PASS: bigop spawning, order and scope, from a typed row ("
                .. checks_run .. " checks)")
    end
    return checks_failed == 0
end

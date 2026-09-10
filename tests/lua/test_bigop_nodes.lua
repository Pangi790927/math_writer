--[[
test_bigop_nodes.lua - SUM, PROD, UNION, INTERSECT and INT: the first ast.lua nodes that DECLARE a
name.

THE ASSUMPTION THIS FILE ORIGINALLY ASSERTED, until 2026-09-10: one shape, (op, var, from, to,
body), for all three operators that existed then. That died the same day it was written - see
"Bigop scoping" (docs/phase2_design.md) - because a single `var` turned out to be one relation (`=`)
on one side and a bare bound on the other, not general enough for `i<n`, `i \in S`, or more than one
variable at once. SUM/PROD (and the new UNION/INTERSECT) moved to a GROUP shape: N variables and a
constraint LIST per side, each constraint an ordinary relation node built the same way any other
relation is. INT alone keeps the original shape below - its variable is written as `dx` after the
body, never a relation, so nothing about it needed generalizing.

WHAT THIS FILE IS STILL NOT. It builds nodes directly, the way `mexpr_ast` will once it exists for
these operators - which sub/sup constraints get built from a typed row, how far a body reaches
without explicit brackets, and where a bigop's spawned variables come from (sub's free names minus
the sup's) are `mexpr_ast`'s job, not this file's. These assertions are about the NODES.

Author, 2026-09-10, on why they declare rather than consume (unchanged by the shape split): "int
declares a variable name, it offers the insides a new reference, itself, the idea is that we will
have our free variables that buble up outside of the root, while some vars get catched by bigops";
and on the constructor: "bigop ops need to create a var, probably reuse new_var, the idea is that in
this way we will achieve our binding".
]]

package.path = package.path .. ";./scripts/?.lua"

local ast = require("ast")

local checks_run, checks_failed = 0, 0
local function check(name, cond, got)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name .. (got ~= nil and ("  (got: " .. tostring(got) .. ")") or ""))
    end
end

-- A mention of `name` as the builder of a body would write it: a variable, and a reference to it.
local function free_ref(ns, name)
    return ast.new_vref(ns, ast.new_var(ns, name))
end

function run_test()
    -- ------------------------------------------------- the GROUP shape, and the catch
    do
        local ns = ast.new_ns()
        --[[ `\sum_{i=1}^{n}(i)` - a sub constraint built as a real relation node (`i=1`, ordinary
        `ast.new_eq`), a sup with none, and a body mentioning `i` before anything has said who binds
        it - exactly the order a parser reads a row in. ]]
        local sub1 = ast.new_eq(ns, free_ref(ns, "i"), ast.new_num(ns, 1))
        local body = free_ref(ns, "i")
        local node = ast.new_sum(ns, {"i"}, {sub1}, {}, body)

        check("a sum is a SUM", node.type == ast.SUM, node.type)
        check("slot 1 is the variable count", node[1] == 1, node[1])
        check("slot 2 is the sub-constraint count", node[2] == 1, node[2])
        check("slot 3 is the sup-constraint count", node[3] == 0, node[3])
        check("slot 4 is a variable it made itself",
                node[4].type == ast.VAR and node[4][1] == "i", node[4] and node[4][1])
        check("slot 5 is the sub constraint, unchanged as a node", node[5] == sub1)
        check("the sub constraint's own free `i` was caught too",
                sub1[1].type == ast.VREF and sub1[1][1] == node[4].id, sub1[1] and sub1[1][1])

        --[[ THE BINDING, and the only structural evidence of it: the body's reference now carries
        the spawned variable's id, though it was built pointing somewhere else entirely. ]]
        check("the body's free mention was caught",
                node[6].type == ast.VREF and node[6][1] == node[4].id, node[6] and node[6][1])
    end

    -- ------------------------------------------------- more than one variable at once
    do
        local ns = ast.new_ns()
        --[[ `\sum_{i=0,j=N}` - TWO variables spawned from one sub side, tied by nothing but both
        being free where the sub constraints were built. "Bigop scoping"'s own worked example. ]]
        local sub1 = ast.new_eq(ns, free_ref(ns, "i"), ast.new_num(ns, 0))
        local sub2 = ast.new_eq(ns, free_ref(ns, "j"), free_ref(ns, "N"))
        local body = ast.new_add(ns, free_ref(ns, "i"), free_ref(ns, "j"))
        local node = ast.new_sum(ns, {"i", "j"}, {sub1, sub2}, {}, body)

        check("two variables spawned", node[1] == 2, node[1])
        check("first var is i", node[4][1] == "i", node[4][1])
        check("second var is j", node[5][1] == "j", node[5][1])
        check("body's i caught by the first var", body[1][1] == node[4].id, body[1][1])
        check("body's j caught by the second var", body[2][1] == node[5].id, body[2][1])
        --[[ sub2's OWN right side, `N`, is deliberately NOT one of the spawned variables here -
        this test builds `vars` by hand and only ever asked for {"i","j"}, so `N`'s free mention
        is simply left alone. Whether `mexpr_ast` would have offered `N` as a candidate at all is
        exactly the sub-minus-sup question "Bigop scoping" answers, and is out of scope for this
        file - see the note at the top. ]]
    end

    -- ------------------------------------------------- what is NOT caught
    do
        local ns = ast.new_ns()
        --[[ A DIFFERENT NAME BUBBLES PAST. A body mentioning `k` leaves it free for whatever
        encloses the sum, which is the half of the design that makes free variables reach the root
        at all. ]]
        local k = free_ref(ns, "k")
        local k_target = k[1]
        local sub1 = ast.new_eq(ns, free_ref(ns, "i"), ast.new_num(ns, 1))
        local node = ast.new_sum(ns, {"i"}, {sub1}, {}, k)
        check("a mention of another name is left alone", node[6][1] == k_target, node[6][1])
        check("and is not the operator's variable", node[6][1] ~= node[4].id)
    end

    do
        local ns = ast.new_ns()
        --[[ A NEARER BINDER SHADOWS. The inner sum declares `i` too, so the outer must not reach
        into ANY of its trees - unlike the old single-var shape, a GROUP bigop's subs, sups and body
        are all one scope with each other, so shadowing skips the whole inner group at once rather
        than splitting "bounds ours, body not". Getting this wrong is silent: the tree stays well
        formed and means something else. ]]
        local inner_sub = ast.new_eq(ns, free_ref(ns, "i"), ast.new_num(ns, 1))
        local inner_body = free_ref(ns, "i")
        local inner = ast.new_sum(ns, {"i"}, {inner_sub}, {}, inner_body)

        local outer_sub = ast.new_eq(ns, free_ref(ns, "i"), ast.new_num(ns, 1))
        local outer = ast.new_sum(ns, {"i"}, {outer_sub}, {}, inner)

        check("the outer's own sub is bound by the outer",
                outer_sub[1][1] == outer[4].id, outer_sub[1][1])
        check("the inner sub stays bound to the inner operator",
                inner_sub[1][1] == inner[4].id, inner_sub[1][1])
        check("the inner body stays bound to the inner operator",
                inner_body[1] == inner[4].id, inner_body[1])
    end

    -- ------------------------------------------------- one GROUP shape, four operators
    do
        local ns = ast.new_ns()
        local function one(ctor)
            local sub1 = ast.new_eq(ns, free_ref(ns, "x"), ast.new_num(ns, 0))
            return ctor(ns, {"x"}, {sub1}, {}, free_ref(ns, "x"))
        end
        local made = {one(ast.new_sum), one(ast.new_prod), one(ast.new_union), one(ast.new_intersect)}
        for _, n in ipairs(made) do
            check("every group bigop has six slots (3 counts, 1 var, 1 sub, 1 body)",
                    #n == 6, #n)
            check("and binds its own body", n[6][1] == n[4].id, n[6][1])
        end
        for i = 1, #made do
            for j = i + 1, #made do
                check("made[" .. i .. "] and made[" .. j .. "] are distinct types",
                        made[i].type ~= made[j].type)
            end
        end
    end

    -- ------------------------------------------------- the integral keeps its own shape
    do
        local ns = ast.new_ns()
        --[[ The integral is still the reason a shape exists where the body comes first: `dx` is
        written after it. Untouched by the group-shape split - see the file header. ]]
        local node = ast.new_int(ns, "x", ast.new_num(ns, 0), ast.new_num(ns, 1), free_ref(ns, "x"))
        check("an integral is an INT", node.type == ast.INT, node.type)
        check("still four slots", #node == 4, #node)
        check("slot 1 is a variable it made itself",
                node[1].type == ast.VAR and node[1][1] == "x", node[1] and node[1][1])
        check("and binds its own body", node[4][1] == node[1].id, node[4][1])
    end

    -- ------------------------------------------------- membership and inclusion, the whole family
    do
        --[[ Added the same day as the group shape ("Bigop scoping") - general purpose relations,
        not bigop-only, same shape as EQ. A bigop's own constraints are built through this exact
        door (`n \in \N`, `S \subseteq T`), but nothing here is bigop-specific.

        SIX GLYPHS, SIX TYPES. `\ni` and the `\sup*` pair are each the exact mirror of an existing
        one (`a \ni b` means `b \in a`) but keep their own constructor and operand order rather than
        reusing another node with operands swapped - same precedent `<`/`>` already set. So this
        checks all six are distinct types with operands in the WRITTEN order, not just that each one
        individually builds. ]]
        local ns = ast.new_ns()
        local n, N = free_ref(ns, "n"), free_ref(ns, "N")
        local mem = ast.new_in(ns, n, N)
        check("membership is IN", mem.type == ast.IN, mem.type)
        check("operands stay in written order", mem[1] == n and mem[2] == N)

        local S, T = free_ref(ns, "S"), free_ref(ns, "T")
        local rev_mem = ast.new_ni(ns, S, T)
        check("backward membership is NI, not IN", rev_mem.type == ast.NI, rev_mem.type)
        check("operands stay in written order, not swapped to look like IN",
                rev_mem[1] == S and rev_mem[2] == T)

        local strict_sub = ast.new_subset(ns, S, T)
        check("proper subset is SUBSET, not SUBSETEQ", strict_sub.type == ast.SUBSET,
                strict_sub.type)

        local eq_sub = ast.new_subseteq(ns, S, T)
        check("subset-or-equal is SUBSETEQ", eq_sub.type == ast.SUBSETEQ, eq_sub.type)

        local strict_sup = ast.new_supset(ns, S, T)
        check("proper superset is SUPSET, distinct from SUBSET",
                strict_sup.type == ast.SUPSET and strict_sup.type ~= ast.SUBSET, strict_sup.type)

        local eq_sup = ast.new_supseteq(ns, S, T)
        check("superset-or-equal is SUPSETEQ, distinct from SUBSETEQ",
                eq_sup.type == ast.SUPSETEQ and eq_sup.type ~= ast.SUBSETEQ, eq_sup.type)

        local kinds = {mem.type, rev_mem.type, strict_sub.type, eq_sub.type, strict_sup.type,
                eq_sup.type}
        for i = 1, #kinds do
            for j = i + 1, #kinds do
                check("relation " .. i .. " and " .. j .. " are distinct types", kinds[i] ~= kinds[j])
            end
        end
    end

    -- ------------------------------------------------- serialization, both directions
    do
        --[[ A NEW NODE TYPE THAT CANNOT BE WRITTEN OUT IS A TRAP: it would serialize as "?" and
        deserialize as an error, and the loss would only surface when a document that happened to
        contain one was reopened. Both tables in ast.lua have to know about a type, so this is a
        real round-trip rather than either direction alone. Covers the group shape's own counts
        (plain numbers, not nodes - the same idiom MAT's m/n already round-trip through), and IN. ]]
        local ns = ast.new_ns()
        local sub1 = ast.new_eq(ns, free_ref(ns, "i"), ast.new_num(ns, 1))
        local node = ast.new_sum(ns, {"i"}, {sub1}, {}, free_ref(ns, "i"))
        local text = ast.to_string(ns, node)
        check("a sum serializes with its own symbol", text:sub(1, 2) == "(S", text)

        local back_ns = ast.new_ns()
        local back = ast.from_string(back_ns, text)
        check("and reads back as a SUM", back.type == ast.SUM, back and back.type)
        check("with its six slots intact", #back == 6, #back)
        check("its counts survived as plain numbers", back[1] == 1 and back[2] == 1 and back[3] == 0,
                back[1] and (back[1] .. "/" .. back[2] .. "/" .. back[3]))
        check("its binding preserved across the round trip",
                back[6].type == ast.VREF and back[6][1] == back[4].id, back[6] and back[6][1])
        check("and writes out to what it was read from",
                ast.to_string(back_ns, back) == text, ast.to_string(back_ns, back))

        local mem_text = ast.to_string(ns, ast.new_in(ns, free_ref(ns, "n"), free_ref(ns, "N")))
        local mem_back = ast.from_string(ast.new_ns(), mem_text)
        check("membership round-trips as IN", mem_back.type == ast.IN, mem_back and mem_back.type)
    end

    if checks_failed == 0 then
        print("PASS: big operators declare variables and catch them across subs/sups/body ("
                .. checks_run .. " checks)")
    end
    return checks_failed == 0
end

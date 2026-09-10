--[[
test_bigop_nodes.lua - SUM, PROD and INT: the first ast.lua nodes that DECLARE a name.

THE ASSUMPTION: a big operator is (op, var, from, to, body), the same four slots for all three, it
creates its own variable from a NAME, and it binds the body by repointing the body's free mentions
of that name at that variable. After construction the binding is ordinary structure - a VREF whose
id is slot 1's - so nothing walking the body needs to know it is inside a binder to read it.

WHY THE BODY IS BUILT FIRST AND CAUGHT AFTERWARDS, rather than the operator handing its variable
down: `\int_0^1 x dx` names its variable AFTER the body. Any design needing the name before the body
cannot read an integral at all. Catching afterwards serves all three and asks the caller for
nothing, which is why the shadowing case below is worth guarding - it is the only part of catching
that can be got wrong quietly.

WHY ONE SHAPE FOR ALL THREE, the integral included: where the name is WRITTEN is the input method's
problem; what it MEANS - this operator binds this name over this body between these bounds - is
identical, and a separate arrangement for the integral would make every consumer handle it twice.

WHAT THIS FILE IS NOT. Nothing builds these from a typed formula yet: `mexpr_ast` has no bigop case,
because how far a big operator's body reaches along a row is a notation question the grammar cannot
settle. These assertions are about the NODES, which is what that parser will be written against.

Author, 2026-09-10, on why they declare rather than consume: "int declares a variable name, it
offers the insides a new reference, itself, the idea is that we will have our free variables that
buble up outside of the root, while some vars get catched by bigops"; and on the constructor:
"bigop ops need to create a var, probably reuse new_var, the idea is that in this way we will
achieve our binding".
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
    -- ------------------------------------------------- the shape, and the catch
    do
        local ns = ast.new_ns()
        --[[ `\sum_{i=1}^{n} i` - a body mentioning `i` before anything has said who binds it, which
        is exactly the order a parser reads a row in. ]]
        local body = free_ref(ns, "i")
        local node = ast.new_sum(ns, "i", ast.new_num(ns, 1), ast.new_var(ns, "n"), body)

        check("a sum is a SUM", node.type == ast.SUM, node.type)
        check("slot 1 is a variable it made itself",
                node[1].type == ast.VAR and node[1][1] == "i", node[1] and node[1][1])
        check("slot 2 is the lower bound", node[2].type == ast.NUM)
        check("slot 3 is the upper bound", node[3].type == ast.VAR)

        --[[ THE BINDING, and the only structural evidence of it: the body's reference now carries
        slot 1's id, though it was built pointing somewhere else entirely. Anything computing free
        variables subtracts slot 1's id from what slot 4 returned; nothing else is needed, and
        nothing else exists. ]]
        check("the body's free mention was caught",
                node[4].type == ast.VREF and node[4][1] == node[1].id, node[4][1])
    end

    -- ------------------------------------------------- what is NOT caught
    do
        local ns = ast.new_ns()
        --[[ A DIFFERENT NAME BUBBLES PAST. `\sum_{i=..} k` leaves `k` free for whatever encloses
        the sum, which is the half of the design that makes free variables reach the root at all. ]]
        local k = free_ref(ns, "k")
        local k_target = k[1]
        local node = ast.new_sum(ns, "i", ast.new_num(ns, 1), ast.new_num(ns, 2), k)
        check("a mention of another name is left alone", node[4][1] == k_target, node[4][1])
        check("and is not the operator's variable", node[4][1] ~= node[1].id)
    end

    do
        local ns = ast.new_ns()
        --[[ A NEARER BINDER SHADOWS. The inner sum declares `i` too, so the outer must not reach
        into its body - but the inner's BOUNDS are written outside the inner's own scope, so a
        mention of `i` there belongs to the outer. Getting this wrong is silent: the tree stays
        well formed and means something else. ]]
        local inner_body = free_ref(ns, "i")
        local inner_bound = free_ref(ns, "i")
        local inner = ast.new_sum(ns, "i", ast.new_num(ns, 1), inner_bound, inner_body)
        local outer = ast.new_sum(ns, "i", ast.new_num(ns, 1), ast.new_num(ns, 9), inner)

        check("the inner body stays bound to the inner operator",
                inner_body[1] == inner[1].id, inner_body[1])
        check("the inner bound is bound by the outer one",
                inner_bound[1] == outer[1].id, inner_bound[1])
    end

    -- ------------------------------------------------- one shape, three operators
    do
        local ns = ast.new_ns()
        local made = {
            ast.new_sum(ns, "x", ast.new_num(ns, 0), ast.new_num(ns, 1), free_ref(ns, "x")),
            ast.new_prod(ns, "x", ast.new_num(ns, 0), ast.new_num(ns, 1), free_ref(ns, "x")),
            --[[ The integral is the reason the body comes first: `dx` is written after it. Built
            here in the order it is READ, which nothing about the call has to accommodate. ]]
            ast.new_int(ns, "x", ast.new_num(ns, 0), ast.new_num(ns, 1), free_ref(ns, "x")),
        }
        for _, n in ipairs(made) do
            check("every big operator has four slots", #n == 4, #n)
            check("and binds its own body", n[4][1] == n[1].id, n[4][1])
        end
        check("and they are three distinct types",
                made[1].type ~= made[2].type and made[2].type ~= made[3].type
                        and made[1].type ~= made[3].type)
    end

    -- ------------------------------------------------- serialization, both directions
    do
        --[[ A NEW NODE TYPE THAT CANNOT BE WRITTEN OUT IS A TRAP: it would serialize as "?" and
        deserialize as an error, and the loss would only surface when a document that happened to
        contain one was reopened. Both tables in ast.lua have to know about a type, so this is a
        real round-trip rather than either direction alone.

        THAT THIS WORKS AT ALL IS NEW. `ast.from_string` could not read any tree of more than one
        node until 2026-09-10: ast.new() allocated and registered an id before the serialized one
        was applied, so reading id `n` pushed last_id to `n+1`, the next node allocated `n+1`, and
        applying ITS id found `n+1` taken. `ast.new` takes the id as a parameter now. So this case
        is also the round-trip guard that ast.lua never had. ]]
        local ns = ast.new_ns()
        local node = ast.new_sum(ns, "i", ast.new_num(ns, 1), ast.new_var(ns, "n"),
                free_ref(ns, "i"))
        local text = ast.to_string(ns, node)
        check("a sum serializes with its own symbol", text:sub(1, 2) == "(S", text)

        local back_ns = ast.new_ns()
        local back = ast.from_string(back_ns, text)
        check("and reads back as a SUM", back.type == ast.SUM, back and back.type)
        check("with its four slots intact", #back == 4, #back)
        check("its binding preserved across the round trip",
                back[4].type == ast.VREF and back[4][1] == back[1].id, back[4] and back[4][1])
        check("and writes out to what it was read from",
                ast.to_string(back_ns, back) == text, ast.to_string(back_ns, back))
    end

    if checks_failed == 0 then
        print("PASS: big operators declare a variable and catch it in their body ("
                .. checks_run .. " checks)")
    end
    return checks_failed == 0
end

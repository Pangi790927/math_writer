--[[
test_ast_mexpr.lua - a tree written back into glyphs says the same thing it said.

THE ASSUMPTION, and it is one assertion doing nearly all the work: for every tree this writer accepts,
PARSING WHAT IT DREW RETURNS THAT TREE. Both directions live in this repo, so the round trip is the
cheapest honest check there is, and it fails on exactly the things a writer gets wrong - a bracket
that was needed and not written, a sign that turned into a factor, an implicit product that re-read
as one name. All three produce a formula that looks entirely reasonable and means something else,
which is why eyeballing a screenshot is not a substitute.

WHAT THE ROUND TRIP CANNOT SEE, and so is checked separately below: anything that is TRUE of the
drawing rather than of its meaning. `a + -1 \cdot b` round-trips perfectly and is not how a person
writes `a - b`. So the sign case asserts the LaTeX, not the shape.

WHY SHAPES AND NOT ast.to_string: the rebuilt formula is parsed into a fresh namespace, so no id can
match by construction (ast.shape's own comment). Names match, which is what identity means here.

REFUSALS ARE ASSERTED TOO. This writer covers what `distribute` produces and nothing else; a
fraction, a call or a big operator must come back as nil plus a reason rather than as an
approximation. A drawing that is nearly right is the one outcome worse than no drawing.
]]

package.path = package.path .. ";./scripts/?.lua"

local vc = require("virt_composer")
local char = require("char")
local mexpru = require("mexpru")
local mformula_latex = require("mformula_latex")
local mexpr_ast = require("mexpr_ast")
local ast_mexpr = require("ast_mexpr")
local transforms = require("transforms")
local ast = require("ast")

local SZ = mexpru.DEFAULT_SIZE

local checks_run, checks_failed = 0, 0
local function check(name, cond, got)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name .. (got ~= nil and ("  (got: " .. tostring(got) .. ")") or ""))
    end
end

function run_test()
    local fs = char.load_font_set()

    -- Source formula -> its tree, the way the whole app gets one.
    local function parse(src)
        local c = mformula_latex.from_latex(fs, SZ, src)
        local node, err, ns = mexpr_ast.build(fs, c, {})
        return c, node, ns, err
    end

    --[[ Write `node` back and report both what it says and what it looks like.

    BUILT THROUGH mexpru.new_container SINCE 2026-09-12, not as a bare `{root = ..., version = 0}`.
    The container became a SEALED type with one creator, and ast_mexpr.verify checks it was handed
    one - so the old table, which happened to carry the two fields anything looked at, is no longer
    a container. That is the change working rather than a test to paper over: "a table with a root
    in it" was never the contract, it was just what nothing had checked. ]]
    local function write_back(source, ns, node)
        local root, err = ast_mexpr.build(fs, source.root, ns, node, SZ)
        if not root then
            return nil, err
        end
        local rebuilt = mexpru.new_container(root, mexpru.u(root).children[1] or root)
        local ok, want, got = ast_mexpr.verify(fs, rebuilt, {}, ns, node)
        return {latex = mformula_latex.to_latex(rebuilt), ok = ok, want = want, got = got}
    end

    -- ------------------------------------------------------------------ it says the same thing
    do
        local src, node, ns = parse("a(b+c)")
        check("setup: the source parses", node ~= nil)

        --[[ NOT TRANSFORMED, on purpose. Writing a tree back UNCHANGED is the case that isolates the
        writer: anything that differs is the writer's doing and not the transformation's. It is also
        the case that needs a bracket, since the sum is a factor of the product. ]]
        local out, err = write_back(src, ns, node)
        check("a(b+c) can be written back", out ~= nil, err)
        if out then
            check("...and parses back to the same tree", out.ok,
                    tostring(out.want) .. "  vs  " .. tostring(out.got))
            --[[ The bracket is not incidental: without it the drawing is `a*b+c`, which parses
            cleanly into a DIFFERENT tree. Asserted directly as well as through the round trip,
            because this is the failure the whole precedence table exists to prevent. ]]
            check("...keeping the bracket the meaning needs",
                    out.latex:find("%(") ~= nil and out.latex:find("%)") ~= nil, out.latex)
        end
    end

    -- ------------------------------------------------------------------ after a transformation
    do
        local src, node, ns = parse("a(b+c)")
        local add
        for _, candidate in pairs(ns.by_id) do
            if type(candidate) == "table" and candidate.type == ast.ADD then
                add = candidate
            end
        end
        check("setup: there is a sum to distribute", add ~= nil)

        --[[ THE PARAMS COME FROM THE OFFER as of 2026-09-12, not from a `{add = add.id}` written here.
        distribute seals what its offer() builds and checks it on retrieval, so a hand-made table with
        the right key is refused - the metatable is the type. That is not an assertion that stopped
        holding either: it is the same assertion, made through the same door the right-click menu uses,
        and it now also pins that offer and apply AGREE about the parameter, which two hand-written
        tables could never have caught. ]]
        local option = transforms.offers(ns, node, add[2][1])[1]
        check("setup: distribute offers itself at the sum", option ~= nil)
        if not option then
            return false
        end
        local result, err = transforms.apply(option.id, ns, node, option.params)
        check("distribute produces a tree", result ~= nil, err)
        if result then
            local out, werr = write_back(src, ns, result)
            check("the RESULT can be written back", out ~= nil, werr)
            if out then
                check("...and parses back to what distribute produced", out.ok,
                        tostring(out.want) .. "  vs  " .. tostring(out.got))
                --[[ THE DUPLICATED FACTOR. `a` appears twice in the result and only once in the
                source, so the second one is a node nothing was ever drawn for - it is written by
                copying another reference to the same VARIABLE. If that lookup ever stops working
                this is where it shows, because the write refuses rather than drawing a blank. ]]
                local _, count = out.latex:gsub("a", "")
                check("...with the duplicated name drawn twice", count >= 2, out.latex)
            end
        end
    end

    -- ------------------------------------------------------------------ signs are operators
    do
        --[[ A term's sign lives on its leading NUM (`a-b` is ADD(a, MUL(NUM(-1), b))), so a writer
        that just put `+` between terms would draw `a + -1 \cdot b`. That ROUND TRIPS - it is the
        same tree - which is exactly why the assertion here is about the drawing. ]]
        local src, node, ns = parse("a(b-c)")
        check("setup: the difference parses", node ~= nil)
        local out, err = write_back(src, ns, node)
        check("a(b-c) can be written back", out ~= nil, err)
        if out then
            check("...and still means the same", out.ok,
                    tostring(out.want) .. "  vs  " .. tostring(out.got))
            check("...written with a minus, not a negative factor",
                    out.latex:find("-") ~= nil and out.latex:find("1") == nil, out.latex)
        end
    end

    -- ------------------------------------------------------------------ powers ride on the slot
    do
        local src, node, ns = parse("a^{2}b")
        check("setup: the power parses", node ~= nil)
        local out, err = write_back(src, ns, node)
        check("a^{2}b can be written back", out ~= nil, err)
        if out then
            check("...and parses back to the same tree", out.ok,
                    tostring(out.want) .. "  vs  " .. tostring(out.got))
        end
    end

    -- ------------------------------------------------------------------ and a power over a sum
    do
        --[[ THE EXPONENT RIDES ON THE CLOSING BRACKET - the editor's own model, established while
        typing long before anything wrote a tree back. A base that is a run of several slots becomes
        one slot by being bracketed, and the supsub then hangs off that bracket. If that ever stops
        holding, this round trip breaks rather than the drawing quietly losing its exponent. ]]
        local src, node, ns = parse("(a+b)^{2}")
        check("setup: the power over a sum parses", node ~= nil)
        local out, err = write_back(src, ns, node)
        check("(a+b)^{2} can be written back", out ~= nil, err)
        if out then
            check("...and parses back to the same tree", out.ok,
                    tostring(out.want) .. "  vs  " .. tostring(out.got))
        end
    end

    -- ------------------------------------------------------------------ and over the user's pair
    do
        --[[ A BASE IN THE USER'S OWN BRACKETS keeps them. The parse reads a base's outermost pair
        as the power's, so `((a+b))^{2}` is EXP(CELL(ADD)) and both pairs have to be written; with
        the CELL's pair alone it read back as EXP(ADD), one pair lost on every transform of a
        formula holding it (found 18-10-2026). @date 18-10-2026-21:50 ]]
        for _, s in ipairs({"((a+b))^{2}c", "((ab))^{2}"}) do
            local src, node, ns = parse(s)
            check("setup: " .. s .. " parses", node ~= nil)
            local out, err = write_back(src, ns, node)
            check(s .. " can be written back", out ~= nil, err)
            if out then
                check("...and parses back to the same tree", out.ok,
                        tostring(out.want) .. "  vs  " .. tostring(out.got))
            end
        end
    end

    -- ------------------------------------------------------------------ digits against digits
    do
        --[[ DIGITS WRITTEN AGAINST DIGITS READ AS ONE NUMERAL, a power's base included: a reorder
        of `x+y+5\cdot 10^{2}` committed the box `y+x+510^{2}`, 510 squared, and one of
        `x+2\cdot 3` committed `23+x` (found 19-10-2026). Each case reads back as the tree it was
        written from, written unchanged and after the transformation that made the wrong box. A
        power of a numeral after anything but digits keeps its plain juxtaposition, which already
        read back right. @date 19-10-2026-22:27 ]]
        local function round_trips(label, src, ns, tree)
            local out, err = write_back(src, ns, tree)
            check(label .. " can be written back", out ~= nil, err)
            if out then
                check(label .. " parses back to the same tree", out.ok,
                        tostring(out.latex) .. ": " .. tostring(out.want) .. "  vs  "
                        .. tostring(out.got))
            end
            return out
        end
        for _, s in ipairs({"5\\cdot 10^{2}", "2\\cdot 10^{3}+x+y", "2\\cdot 3+a+b",
                "x+(2)(3)^{2}", "2\\cdot 3^{2}", "x+5\\cdot 2y"}) do
            local src, node, ns = parse(s)
            check("setup: " .. s .. " parses", node ~= nil)
            if node then
                round_trips(s, src, ns, node)
            end
        end
        for _, s in ipairs({"x10^{2}", "3^{2}10^{3}"}) do
            local src, node, ns = parse(s)
            local out = node and round_trips(s, src, ns, node)
            check(s .. " is written without a dot", out ~= nil and out.latex:find("cdot") == nil,
                    out and out.latex)
        end

        check("setup: the reorder plugin is registered", transforms.get("reorder") ~= nil)
        -- Each case is {source, the term that moves, the term it lands in front of}.
        -- @date 19-10-2026-22:37
        for _, case in ipairs({{"x+2\\cdot 3", 2, 1}, {"x+y+5\\cdot 10^{2}", 2, 1},
                {"2\\cdot 10^{3}+x+y", 3, 2}, {"2\\cdot 3+a+b", 3, 2},
                {"x+(2)(3)^{2}", 2, 1}, {"x+5\\cdot 2y", 2, 1}}) do
            local s, t, b = case[1], case[2], case[3]
            local src, node, ns = parse(s)
            local result, err
            if node and transforms.get("reorder") then
                result, err = transforms.apply("reorder", ns, node,
                        {term = node[t].id, before = node[b].id})
            end
            check("the reorder of " .. s .. " produces a tree", result ~= nil, err)
            if result then
                round_trips(s .. " reordered", src, ns, result)
            end
        end

        local src, node, ns = parse("2(3+x)")
        local add = node and node[2]
        local option = add and add.type == ast.ADD and transforms.offers(ns, node, add[2][1])[1]
        check("setup: distribute offers itself in 2(3+x)", option ~= nil and option ~= false)
        if option then
            local result, err = transforms.apply(option.id, ns, node, option.params)
            check("distribute of 2(3+x) produces a tree", result ~= nil, err)
            if result then
                round_trips("2(3+x) distributed", src, ns, result)
            end
        end
    end

    -- ------------------------------------------------------------------ as a container
    do
        --[[ WHAT THE NEXT STAGE WILL HOLD. A written tree has to arrive as something an editor can
        take - a root, a cursor and a version - and the cursor has to name a node that is really in
        the tree, or every arrow key afterwards dies in u(nil). Checked here rather than when the
        cell is built, because "the cursor is somewhere real" is a property of the writing. ]]
        local src, node, ns = parse("a(b+c)")
        local c, err = ast_mexpr.container(fs, src.root, ns, node, SZ)
        check("a written tree comes back as a container", c ~= nil, err)
        if c then
            local at = c.cursor_pos and c.cursor_pos:get_obj()
            check("...with a cursor on a node of its own tree", at ~= nil)
            check("...and a version to key caches on", c.version == 0)
        end
    end

    -- ------------------------------------------------------------------ what it refuses
    do
        --[[ A fraction is a real node this writer cannot draw yet. The answer is a refusal with a
        reason, never an approximation - see this file's own header. ]]
        local src, node, ns = parse("\\frac{a}{b}+c")
        check("setup: the fraction parses", node ~= nil)
        if node then
            local root, err = ast_mexpr.build(fs, src.root, ns, node, SZ)
            check("a fraction is refused rather than approximated", root == nil)
            check("...with a reason naming what is missing",
                    type(err) == "string" and err:find("yet") ~= nil, err)
        end
    end

    if checks_failed == 0 then
        print("PASS: trees survive the round trip (" .. checks_run .. " checks)")
    end
    return checks_failed == 0
end

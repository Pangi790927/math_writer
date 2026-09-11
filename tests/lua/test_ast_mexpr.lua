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

    --[[ Write `node` back and report both what it says and what it looks like. The container is the
    minimum a parse needs, which is a root - the same shape mformula_latex.from_latex hands back. ]]
    local function write_back(source, ns, node)
        local root, err = ast_mexpr.build(fs, source.root, ns, node, SZ)
        if not root then
            return nil, err
        end
        local rebuilt = {root = root, version = 0}
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

        local result, err = transforms.distribute(ns, node, add.id)
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

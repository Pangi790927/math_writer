--[[
test_reorder.lua - moving a term of a sum among its terms, the step a term selector's drag runs.

THE ASSUMPTIONS, from the user's request of 19-10-2026 and the engine contract written for it:

  - THE DRAG IS THE ONLY WAY IN. reorder has no offer, so the right-click menu and F6 offer what
    they offered before it existed. The UI builds the option itself, as
    transforms.option("reorder", label, {term = <ast id>, before = <ast id>}), with plain ids.
  - A TERM MOVES AMONG ITS OWN SUM'S TERMS ONLY. `before` is a sibling of the term, or the sum
    itself to land last. Anything else is refused, and so is a drop that leaves the order as it
    was - a step that changes nothing.
  - EVERY TERM KEEPS ITS SIGN. The term that lands first carries no +1, the old first term gains
    its +1, and a -1 stays with its term wherever it lands (DESIGN.md, "A sign is always its own
    coefficient").
  - A TERM KEEPS ITS FACTORS. Landing first costs a term its +1, never a factor: a typed 1 behind
    the sign stays, so the move dragged back gives the source again.
  - UNTOUCHED TERMS ARE SHARED. A term that stays first, or stays later, is the same node, and
    the source tree is never changed.
  - THE RESULT IS ITS OWN PARSE. Every case is written back and reparsed (ast_mexpr.verify), the
    brackets included. Where the parse's normal form forces a change the result follows the
    parse: a redundant bracket around a leaf that moves into first place is dropped, `x+(a)`
    becoming `a+x`, because the parse reads `(a)+x` as `a+x`.

@date 19-10-2026-22:23
]]

package.path = package.path .. ";./scripts/?.lua"

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

--[[ Lists every ADD under `node` in pre-order, the order the sums are read left to right.
@date 19-10-2026-20:56 ]]
local function sums(node, out)
    if type(node) == "table" and node.type then
        if node.type == ast.ADD then
            out[#out + 1] = node
        end
        for i = 1, #node do
            sums(node[i], out)
        end
    end
    return out
end

--[[ Lists every node under `node` in pre-order. @date 19-10-2026-20:56 ]]
local function nodes(node, out)
    if type(node) == "table" and node.type then
        out[#out + 1] = node
        for i = 1, #node do
            nodes(node[i], out)
        end
    end
    return out
end

--[[ Declares `f(x)` the way a definition box hands a declaration over, so that `f(a+b)` reads as
a call rather than as a product. @date 19-10-2026-20:56 ]]
local function f_decls(fs)
    local c = mformula_latex.from_latex(fs, SZ, "f(x)")
    local pat = mexpr_ast.parse_name(fs, c)
    return {mexpr_ast.new_decl{text = pat.text, name = pat.name, arity = pat.arity,
            tokens = pat.tokens, groups = pat.groups}}
end

--[[ Builds the option a drop builds: two plain ids and the label a menu would show.
@date 19-10-2026-20:56 ]]
local function drop(term, before)
    return transforms.option("reorder", "Reorder terms", {term = term.id, before = before.id})
end

function run_test()
    local fs = char.load_font_set()

    --[[ Parses `src`, moves term `t` of its `which`-th sum in front of term `b` - or to the end
    when `b` is "end" - writes the result back and reparses it. Returns the result tree, its LaTeX
    and the source root, or nil and why; a source tree that changed is a why.
    @date 19-10-2026-20:56 ]]
    local function reorder(src, which, t, b, decls)
        decls = decls or {}
        local c = mformula_latex.from_latex(fs, SZ, src)
        local root, err, ns = mexpr_ast.build(fs, c, decls)
        if not root then
            return nil, "parse: " .. tostring(err)
        end
        local add = sums(root, {})[which]
        if not add then
            return nil, "no sum #" .. which
        end
        local term, before = add[t], (b == "end") and add or add[b]
        if not (term and before) then
            return nil, "no such term"
        end
        local source_shape = ast.shape(ns, root)
        local option = drop(term, before)
        local result, terr = transforms.apply(option.id, ns, root, option.params)
        if not result then
            return nil, "refused: " .. tostring(terr)
        end
        if ast.shape(ns, root) ~= source_shape then
            return nil, "the source tree changed"
        end
        local w, werr = ast_mexpr.build(fs, c.root, ns, result, SZ)
        if not w then
            return nil, "write: " .. tostring(werr)
        end
        local rebuilt = mexpru.new_container(w, mexpru.last_slot(w))
        local ok, want, got = ast_mexpr.verify(fs, rebuilt, decls, ns, result)
        if not ok then
            return nil, "verify: want " .. tostring(want) .. " got " .. tostring(got)
        end
        return result, mformula_latex.to_latex(rebuilt), root
    end

    --[[ THE CASES, as {source, which sum, which term, in front of which term or "end", what it
    writes}, in groups:

      - the user's sketch, moved the three ways a term moves: into first place, out of it to
        the end, and inside the bracketed sum;
      - middle moves, where no term changes first place and so no sign changes - a typed leading
        + stays while its term stays first;
      - negative terms, whose -1 goes with them into and out of first place;
      - numbers, where a value numeral is never taken for a sign;
      - typed 1s, which stay with their term into and out of first place, so each move undoes;
      - brackets into and out of first place, where the parse decides which pairs survive: a
        leaf's pair is dropped once the leaf leads its term, and kept behind a -1;
      - nested sums, each moved on its own level, and the two sides of an equation;
      - a big operator's body, and a big operator as a term.

    @date 19-10-2026-22:23 ]]
    local SKETCH = "(abc+ab^{2})d+ac+2\\pi"
    local CASES = {
        {SKETCH, 1, 3, 1, "2\\pi +\\left(abc+ab^{2}\\right)d+ac"},
        {SKETCH, 1, 1, "end", "ac+2\\pi +\\left(abc+ab^{2}\\right)d"},
        {SKETCH, 2, 2, 1, "\\left(ab^{2}+abc\\right)d+ac+2\\pi "},

        {"a+b+c+d", 1, 3, 2, "a+c+b+d"},
        {"a+b+c+d", 1, 2, "end", "a+c+d+b"},
        {"a+b+c+d", 1, 4, 2, "a+d+b+c"},
        {"a+b", 1, 2, 1, "b+a"},
        {"a+b", 1, 1, "end", "b+a"},
        {"+a+b+c", 1, 3, 2, "+a+c+b"},

        {"a-b+c", 1, 2, 1, "-b+a+c"},
        {"a-b+c", 1, 1, "end", "-b+c+a"},
        {"a-b+c", 1, 2, "end", "a+c-b"},
        {"-a+b", 1, 2, 1, "b-a"},
        {"y-2x", 1, 2, 1, "-2x+y"},
        {"x-1", 1, 2, 1, "-1+x"},

        {"x+1", 1, 2, 1, "1+x"},
        {"3+x", 1, 2, 1, "x+3"},
        {"2x+y", 1, 2, 1, "y+2x"},

        {"a+x\\cdot 1", 1, 2, 1, "x\\cdot 1+a"},
        {"x\\cdot 1+a", 1, 2, 1, "a+x\\cdot 1"},
        {"a-x\\cdot 1", 1, 2, 1, "-x\\cdot 1+a"},
        {"a+2\\cdot 1", 1, 2, 1, "2\\cdot 1+a"},
        {"x\\cdot 1\\cdot y+a", 1, 2, 1, "a+x\\cdot 1y"},
        {"a+x\\cdot 1\\cdot y", 1, 2, 1, "x\\cdot 1y+a"},

        {"(a+b)+c", 1, 2, 1, "c+(a+b)"},
        {"c+(a+b)", 1, 2, 1, "(a+b)+c"},
        {"x-(a+b)", 1, 2, 1, "-(a+b)+x"},
        {"x+(a+b)d", 1, 2, 1, "(a+b)d+x"},
        {"x+((a+b))", 1, 2, 1, "((a+b))+x"},
        {"x+(ab)", 1, 2, 1, "(ab)+x"},
        {"x+(a)", 1, 2, 1, "a+x"},
        {"x+(a)b", 1, 2, 1, "ab+x"},
        {"x+(2)y", 1, 2, 1, "2y+x"},
        {"x-(a)", 1, 2, 1, "-(a)+x"},

        {"x(a+b)+y", 1, 2, 1, "y+x(a+b)"},
        {"x(a+b)+y", 2, 2, 1, "x(b+a)+y"},
        {"a+b=c+d", 1, 2, 1, "b+a=c+d"},
        {"a+b=c+d", 2, 2, 1, "a+b=d+c"},

        {"\\sum_{i=0}^{n}(i+a)", 1, 2, 1, "\\sum \\limits^{n}_{i=0}(a+i)"},
        {"\\sum_{i}i+a", 1, 2, 1, "a+\\sum \\limits_{i}i"},
    }
    for _, case in ipairs(CASES) do
        local src, which, t, b, want = case[1], case[2], case[3], case[4], case[5]
        local name = string.format("%s, sum #%d, term %d before %s", src, which, t, tostring(b))
        local result, latex = reorder(src, which, t, b)
        check(name .. " moves and round-trips", result ~= nil, latex)
        if result then
            check(name .. " writes " .. want, latex == want, latex)
        end
    end

    do
        --[[ A CALL'S ARGUMENT is in the main row, between the call's own brackets, and its sum
        moves like any other; the call stays a call. @date 19-10-2026-20:56 ]]
        local decls = f_decls(fs)
        local result, latex = reorder("f(a+b)+c", 2, 2, 1, decls)
        check("a sum in a declared call's argument moves and round-trips", result ~= nil, latex)
        if result then
            check("...and writes f(b+a)+c", latex == "f(b+a)+c", latex)
            check("...with the call intact", result[1].type == ast.CALL,
                    ast.type_name(result[1].type))
        end
    end

    do
        --[[ THE SKETCH, node by node. The moved term lands first without its +1, built from its
        own factor nodes; the old first term gains a fresh +1 in front of its own factors; the
        term that stayed later is the very node it was. @date 19-10-2026-20:56 ]]
        local result, _, root = reorder(SKETCH, 1, 3, 1)
        if result then
            local moved, old_first, ac = root[3], root[1], root[2]
            local lead = result[1]
            check("2pi lands first with no +1", lead.type == ast.MUL and #lead == 2
                    and rawequal(lead[1], moved[2]) and rawequal(lead[2], moved[3]))
            local gained = result[2]
            check("the old first term gains a +1", gained.type == ast.MUL and #gained == 3
                    and gained[1].type == ast.NUM and gained[1][1] == 1 and gained[1][3] == 1
                    and rawequal(gained[2], old_first[1]) and rawequal(gained[3], old_first[2]))
            check("the term that stays later is shared", rawequal(result[3], ac))
        end

        --[[ A NEGATIVE TERM keeps its -1 into first place; moved anywhere later it does not
        change at all. @date 19-10-2026-20:56 ]]
        result, _, root = reorder("a-b+c", 1, 2, 1)
        if result then
            check("-b lands first keeping its -1", result[1].type == ast.MUL
                    and result[1][1].type == ast.NUM and result[1][1][3] == -1
                    and rawequal(result[1][2], root[2][2]))
            check("...a gains a +1 and c is shared", result[2][1][3] == 1
                    and rawequal(result[2][2], root[1]) and rawequal(result[3], root[3]))
        end
        result, _, root = reorder("a-b+c", 1, 2, "end")
        check("-b moved last is the very node it was", result ~= nil
                and rawequal(result[3], root[2]) and rawequal(result[1], root[1]))

        --[[ A TYPED 1 lands first with its term: only the +1 goes, and what follows is the term's
        own factor nodes, the 1 among them. @date 19-10-2026-22:23 ]]
        result, _, root = reorder("a+x\\cdot 1", 1, 2, 1)
        check("x\\cdot 1 lands first with its own x and 1", result ~= nil
                and result[1].type == ast.MUL and #result[1] == 2
                and rawequal(result[1][1], root[2][2]) and rawequal(result[1][2], root[2][3]))

        --[[ A MIDDLE MOVE rebuilds the sum and nothing in it. @date 19-10-2026-20:56 ]]
        result, _, root = reorder("a+b+c+d", 1, 3, 2)
        check("a middle move shares every term", result ~= nil and not rawequal(result, root)
                and rawequal(result[1], root[1]) and rawequal(result[2], root[3])
                and rawequal(result[3], root[2]) and rawequal(result[4], root[4]))

        --[[ ONE LEVEL AT A TIME: the sum in the bracket is rebuilt, and the path above it; the
        outer sum's other terms are the nodes they were. The same holds across an `=`.
        @date 19-10-2026-20:56 ]]
        result, _, root = reorder(SKETCH, 2, 2, 1)
        check("an inner move shares the outer terms", result ~= nil
                and rawequal(result[2], root[2]) and rawequal(result[3], root[3])
                and rawequal(result[1][2], root[1][2]))
        result, _, root = reorder("a+b=c+d", 2, 2, 1)
        check("a move on one side shares the other side", result ~= nil
                and rawequal(result[1], root[1]))
    end

    do
        --[[ EVERY DROP THAT DOES NOT FIT IS AN ANSWER, not an error: the UI logs the reason and
        makes no box. Each is asked against one parse, which must come out of it unchanged.
        @date 19-10-2026-20:56 ]]
        local c = mformula_latex.from_latex(fs, SZ, "x(a+b)+y")
        local root, _, ns = mexpr_ast.build(fs, c, {})
        local shape = ast.shape(ns, root)
        local inner = root[1][2]
        local x = root[1][1]
        local nowhere = ns.last_id + 1000
        local function refused(name, params)
            local result, reason = transforms.apply("reorder", ns, root, params)
            check(name .. " is refused", result == nil, result and ast.shape(ns, result))
            check(name .. " says why", type(reason) == "string" and #reason > 0, reason)
            check(name .. " leaves the tree alone", ast.shape(ns, root) == shape)
        end
        refused("the whole sum as the term", {term = root.id, before = root[2].id})
        refused("a factor as the term", {term = x.id, before = root[2].id})
        refused("a term id that names nothing", {term = nowhere, before = root[2].id})
        refused("a term of another sum as the place", {term = inner[2].id, before = root[2].id})
        refused("another sum as the place", {term = inner[2].id, before = root.id})
        refused("a factor as the place", {term = root[2].id, before = x.id})
        refused("a place id that names nothing", {term = root[2].id, before = nowhere})
        refused("a term in front of itself", {term = root[1].id, before = root[1].id})
        refused("a term in front of the term after it", {term = root[1].id, before = root[2].id})
        refused("the last term to the end", {term = root[2].id, before = root.id})
        refused("a drop with no place", {term = root[2].id})
    end

    do
        --[[ REGISTERED, ON, AND NEVER OFFERED: not one node offers it, in formulas holding every
        shape a drag can reach, while the signs that offer distribute still offer exactly that.
        @date 19-10-2026-20:56 ]]
        local spec = transforms.get("reorder")
        check("reorder is registered", spec ~= nil)
        if spec then
            check("...as Reorder terms", spec.label == "Reorder terms", spec.label)
            check("...taking a term and a place", #spec.params == 2
                    and spec.params[1] == "term" and spec.params[2] == "before")
            check("...on by default", spec.default_active == true
                    and transforms.is_active("reorder"))
            check("...with no offer", spec.offer == nil)
        end

        local offered, distribute_seen = {}, false
        for _, src in ipairs{SKETCH, "a(b+c)", "a-b+c", "x+(a)", "x-(2)", "a+b=c+d",
                "\\sum_{i=0}^{n}(i+a)"} do
            local c = mformula_latex.from_latex(fs, SZ, src)
            local root, _, ns = mexpr_ast.build(fs, c, {})
            for _, n in ipairs(root and nodes(root, {}) or {}) do
                for _, o in ipairs(transforms.offers(ns, root, n)) do
                    if o.id == "reorder" then
                        offered[#offered + 1] = src
                    end
                    distribute_seen = distribute_seen or o.id == "distribute"
                end
            end
        end
        check("no node offers reorder", #offered == 0, table.concat(offered, " | "))
        check("...while distribute is still offered", distribute_seen)

        local c = mformula_latex.from_latex(fs, SZ, "a(b+c)")
        local root, _, ns = mexpr_ast.build(fs, c, {})
        local opts = transforms.offers(ns, root, root[2][2][1])
        check("the + of a(b+c) offers exactly distribute", #opts == 1
                and opts[1].id == "distribute", #opts)
    end

    if checks_failed == 0 then
        print("PASS: reorder moves a term among its siblings (" .. checks_run .. " checks)")
    end
    return checks_failed == 0
end

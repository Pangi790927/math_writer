--[[
test_ast_gestures.lua - turning a click on a glyph into "what can be done here".

THE ASSUMPTION: a gesture reaches a transformation through the tag the PARSE left behind, never by
re-reading the row.

The correspondence between a glyph and the ast node it produced is recorded once, at the moment the
node is built (mexpr_ast's `tag_ast`), because that is the only place both are in hand. Anything
that worked it out afterwards would be a second traversal free to drift from the real one - the
exact bug mexpr_ast.describe's own comment records having had. A drifting VIEWER shows the wrong
tree; a drifting BINDING hands a transformation the wrong nodes, silently, and the result is a
formula that says something else.

WHAT AN OPTION IS: a description, not a closure - `{id, label, params}` with ast IDS. The AST is
scratch and gets rebuilt whenever the box moves, so an option must be inspectable and cheap rather
than holding a tree alive. It survives exactly as long as the interaction that produced it, which
ends when the transform makes a new cell and focus moves there.

WHY EMPTY IS THE INTERESTING ANSWER. Most right-clicks offer nothing, and that has to be a real
answer rather than a failure - `a+b` has no product to distribute into. The checks below spend as
much effort on what is NOT offered as on what is, because an option offered where it does not apply
is how a transformation ends up running on the wrong nodes.
]]

package.path = package.path .. ";./scripts/?.lua"

local vc = require("virt_composer")
local char = require("char")
local mexpru = require("mexpru")
local mformula_latex = require("mformula_latex")
local mexpr_ast = require("mexpr_ast")
local ast_gestures = require("ast_gestures")
local ast = require("ast")

local B = string.char(92)
local SZ = mexpru.DEFAULT_SIZE

local checks_run, checks_failed = 0, 0
local function check(name, cond, got)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name .. (got ~= nil and ("  (got: " .. tostring(got) .. ")") or ""))
    end
end

-- The n-th top-level glyph whose desc is `want`, as the thing a click would land on.
local function glyph(c, want, nth)
    local seen = 0
    for _, ch in ipairs(mexpru.u(c.root).children) do
        local a = mexpru.slot_atom(ch)
        if a.type == vc.MEXPR_TYPE_SYMBOL then
            local e = char.find_by_ncod(a.symb.code)
            if e and e.desc == want then
                seen = seen + 1
                if seen == (nth or 1) then
                    return ch
                end
            end
        end
    end
    return nil
end

local function ids(options)
    local out = {}
    for _, o in ipairs(options) do
        out[#out + 1] = o.id
    end
    return table.concat(out, ",")
end

function run_test()
    local fs = char.load_font_set()
    local function row(src)
        return mformula_latex.from_latex(fs, SZ, src)
    end

    -- ------------------------------------------------------------------ the click resolves
    do
        local c = row("a(b+c)")
        local node, ns = ast_gestures.ast_for(fs, c, {})
        check("the row parses", node ~= nil)

        local plus = glyph(c, "+")
        check("setup: the + is findable", plus ~= nil)
        local at = ast_gestures.node_at(ns, plus)
        check("a click on + lands on the ADD", at ~= nil and at.type == ast.ADD,
                at and at.type)

        --[[ A GLYPH MAY BELONG TO NOTHING, and that is a real answer rather than a lookup failure.
        The parentheses here were implied by precedence, so no CELL was built and the brackets name
        no node - see maybe_cell. ]]
        local open = glyph(c, "(")
        check("a bracket that became no node resolves to nothing",
                ast_gestures.node_at(ns, open) == nil)
    end

    -- ------------------------------------------------------------------ what is offered
    do
        local c = row("a(b+c)")
        local opts = ast_gestures.options(fs, c, {}, glyph(c, "+"))
        check("the + offers distribute", ids(opts) == "distribute", ids(opts))

        --[[ BOUND TO THE SUM, not to whatever was clicked: the parameter is the ADD's id, so the
        transform needs no knowledge of how the gesture arrived. ]]
        local node, ns = ast_gestures.ast_for(fs, c, {})
        local target = opts[1] and ns.by_id[opts[1].params.add]
        check("...with the ADD as its parameter",
                target ~= nil and target.type == ast.ADD, target and target.type)

        --[[ AIM MATTERS - AND THIS CHECK USED TO ASSERT THE OPPOSITE.

        It read "clicking a term offers it too", because options() climbed from whatever was clicked
        to the nearest sum above it. That climb was never asked for; it was invented here on the
        reasoning that a forgiving gesture is a kinder one, and it was reported as a bug the first
        time it was used in anger, 2026-09-11: "Something is wrong I can wright click the d in a(b+d)
        and apply distribute".

        Why the old assumption fell: a term is one operand of one sum, but "the sum above" is not
        unique once sums nest - `a(b+c(d+e))` has two, and a click on `d` had to pick one silently.
        Aim is the only thing that can say which was meant, so the gesture reads the glyph the parse
        tagged and nothing above it.

        Kept as the inverse rather than deleted: the climb is easy to reintroduce by accident the
        next time "the click landed near a sum" feels like it should be enough. ]]
        local from_b = ast_gestures.options(fs, c, {}, glyph(c, "b"))
        check("clicking a TERM offers nothing - the operator is what names the sum",
                #from_b == 0, ids(from_b))
    end

    -- ------------------------------------------------------------------ and what is not
    do
        --[[ Nothing to distribute INTO - the sum is the whole row. This is the common case, and an
        empty list is the honest answer. ]]
        local bare = row("a+b")
        check("a bare sum offers nothing",
                #ast_gestures.options(fs, bare, {}, glyph(bare, "+")) == 0)

        --[[ A product with no sum in it. The click resolves fine; there is simply no ADD above. ]]
        local prod = row("ab")
        check("a product offers nothing",
                #ast_gestures.options(fs, prod, {}, glyph(prod, "a")) == 0)

        --[[ An unparseable row. A row being typed is invalid most of the time, so this must be
        quiet rather than an error. ]]
        local broken = row("a+")
        check("an unparseable row offers nothing",
                #ast_gestures.options(fs, broken, {}, glyph(broken, "a")) == 0)
    end

    -- ------------------------------------------------------------------ the minus climbs
    do
        --[[ THE CASE THE TAGGING WAS SHAPED AROUND. A `-` does not name the ADD - it names the NUM
        that carries the sign, because `a-b` is ADD(a, MUL(NUM(1,1,-1), b)). So resolving a click on
        it lands two levels below the sum and has to climb. If the minus were tagged to the ADD
        instead this check would still pass, which is why the node_at assertion is separate. ]]
        local c = row("a(b-c)")
        local ns = select(2, ast_gestures.ast_for(fs, c, {}))
        local minus = glyph(c, "-")
        local at = ast_gestures.node_at(ns, minus)
        check("a click on - lands on the NUM that holds the sign",
                at ~= nil and at.type == ast.NUM, at and at.type)
        check("...and still offers distribute",
                ids(ast_gestures.options(fs, c, {}, minus)) == "distribute")
    end

    -- ------------------------------------------------------------------ signs are operators too
    do
        --[[ THE TWO SHAPES A SIGN TAKES. `a(b-c)` puts the minus on a NUM inside the term's MUL;
        `a(b-3)` puts it on the term itself, with no MUL at all. Both are the same glyph doing the
        same job, and both must reach the sum - otherwise "aim at the operator" would mean "aim at
        the operator, unless it is a minus, and then it depends what follows it". ]]
        local with_factor = row("a(b-c)")
        check("a minus in front of a product reaches the sum",
                ids(ast_gestures.options(fs, with_factor, {}, glyph(with_factor, "-")))
                        == "distribute")

        local bare_number = row("a(b-3)")
        check("a minus in front of a bare number reaches it too",
                ids(ast_gestures.options(fs, bare_number, {}, glyph(bare_number, "-")))
                        == "distribute")
    end

    -- ------------------------------------------------------------------ the cache
    do
        --[[ REBUILT ONLY WHEN THE BOX MOVED. Keyed on the container's own `version`, which every
        real edit bumps - the same arrangement editor_definition uses for a name. The point is that
        nothing has to remember to invalidate: a cache cannot go stale without the version moving.
        ]]
        local c = row("a(b+c)")
        local first = select(1, ast_gestures.ast_for(fs, c, {}))
        local again = select(1, ast_gestures.ast_for(fs, c, {}))
        check("the ast is cached between calls", rawequal(first, again))

        c.version = (c.version or 0) + 1
        local after = select(1, ast_gestures.ast_for(fs, c, {}))
        check("...and rebuilt once the box moves", not rawequal(first, after))
    end

    -- ------------------------------------------------------------------ running an option
    do
        --[[ A TRANSFORMATION MINTS NODES, and it mints them into the container's own cached
        namespace. So "run it again" is not free the way re-reading a parse is: every call adds
        nodes that nobody will ever look at, and a caller that runs one per frame - which is what a
        preview panel is - grows the namespace without bound while the screen does not change. Seen
        live 2026-09-11, an idle preview walked its ids from 368 to 5513 between two screenshots.

        Hence the same version-keyed cache the parse uses, and hence this check: the SAME table
        back, not merely an equal tree. An equal-looking result would pass a structural comparison
        while still leaking, which is the whole failure. ]]
        local c = row("a(b+c)")
        local opts = ast_gestures.options(fs, c, {}, glyph(c, "+"))
        local first = ast_gestures.preview(fs, c, {}, opts[1])
        check("an option produces a tree", first ~= nil and first.type == ast.ADD,
                first and first.type)
        check("...and running it again is the same tree, not a second one",
                rawequal(first, (ast_gestures.preview(fs, c, {}, opts[1]))))

        --[[ THE RESULT IS THE SUM OF THE PRODUCTS: a(b+c) becomes ab + ac. Checked here rather than
        only in the transform's own test because this is the path a click actually takes - option to
        parameters to result - and an option bound to the wrong node would still produce a valid
        tree, just the wrong one. ]]
        check("...shaped ADD(MUL, MUL)",
                #first == 2 and first[1].type == ast.MUL and first[2].type == ast.MUL,
                #first .. " " .. tostring(first[1] and first[1].type))

        --[[ AND IT EXPIRES WITH THE BOX. The ids in an option name nodes in the tree as it was
        parsed then; an edit reparses into different ones, so a cached result must not outlive the
        version it was computed for. ]]
        c.version = (c.version or 0) + 1
        local opts2 = ast_gestures.options(fs, c, {}, glyph(c, "+"))
        check("a moved box recomputes the result",
                not rawequal(first, (ast_gestures.preview(fs, c, {}, opts2[1]))))
    end

    if checks_failed == 0 then
        print("PASS: gestures resolve to transformations (" .. checks_run .. " checks)")
    end
    return checks_failed == 0
end

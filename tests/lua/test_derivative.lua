--[[
test_derivative.lua - the differential as a fraction carrying one bit, end to end.

THE DESIGN (ruled across 2026-09-15, see DESIGN.md): a derivative IS a fraction in notation and
stays one on the mexpr side - the fraction's own `u.diff` is the only stored fact, drawn as an
orange bar, and every semantic (order, signs, variables, the binding) is re-derived from the
glyphs at each parse. On the wire the d's go out as `\mathrm{d}` (the ISO spelling, a specific
code nothing writes by accident) and `\partial` rides as itself; on the way in, either mark
upgrades the fraction back. The integral's own `\,d` close is a DIFFERENT mark on purpose - a
derivative inside an integral keeps the two readable apart.

`d` MAY NEVER NAME A VARIABLE in a derivative: every d in the sign rows is the sign by
construction, which is what makes `d^2d` unambiguous - the exponent rides the unit, and a d-unit
is a sign, determinately.

@date 2026-09-15 15:00
]]

package.path = package.path .. ";./scripts/?.lua"

local char = require("char")
local mexpru = require("mexpru")
local mformula_latex = require("mformula_latex")
local mexpr_ast = require("mexpr_ast")
local ast_mexpr = require("ast_mexpr")
local ast = require("ast")
local transforms = require("transforms")

local SZ = mexpru.DEFAULT_SIZE

local checks_run, checks_failed = 0, 0
local function check(name, cond, got)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name .. (got ~= nil and ("  (got: " .. tostring(got) .. ")") or ""))
    end
end

-- The first fraction under the container's root, or nil.
local function first_frac(container)
    for _, ch in ipairs(mexpru.u(container.root).children or {}) do
        local u = mexpru.u(ch)
        if u and u.kind == "frac" then
            return u
        end
    end
    return nil
end

function run_test()
    local fs = char.load_font_set()

    -- ------------------------------------------------------------------ the wire, in
    do
        local c = mformula_latex.from_latex(fs, SZ,
                "\\frac{\\mathrm{d}}{\\mathrm{d} x} x^{2}")
        local fr = first_frac(c)
        check("a \\mathrm{d} fraction arrives marked as a differential",
                fr ~= nil and fr.diff == true, fr and fr.diff)

        local p = mformula_latex.from_latex(fs, SZ, "\\frac{\\partial}{\\partial x} x")
        fr = first_frac(p)
        check("...and a \\partial fraction marks itself with no \\mathrm at all",
                fr ~= nil and fr.diff == true, fr and fr.diff)

        local plain = mformula_latex.from_latex(fs, SZ, "\\frac{d}{dx}")
        fr = first_frac(plain)
        check("a plain \\frac{d}{dx} stays an ordinary fraction - the letter d is a variable",
                fr ~= nil and fr.diff == nil, fr and fr.diff)
    end

    -- ------------------------------------------------------------------ the wire, out
    do
        local c = mformula_latex.from_latex(fs, SZ,
                "\\frac{\\mathrm{d}}{\\mathrm{d} x} x^{2}")
        local out = mformula_latex.to_latex(c)
        check("the differential's d's go back out as \\mathrm{d}",
                out:find("\\mathrm{d}", 1, true) ~= nil, out)
        check("...and the variable keeps its own plain spelling",
                out:find("\\mathrm{d} x", 1, true) ~= nil, out)

        local p = mformula_latex.from_latex(fs, SZ, "\\frac{\\partial}{\\partial x} x")
        out = mformula_latex.to_latex(p)
        check("a partial stays \\partial on the wire",
                out:find("\\partial", 1, true) ~= nil, out)
    end

    -- ------------------------------------------------------------------ the parse
    do
        local c = mformula_latex.from_latex(fs, SZ,
                "\\frac{\\mathrm{d}}{\\mathrm{d} x} x^{2}")
        local node, err, ns = mexpr_ast.build(fs, c, {})
        check("d/dx x^2 parses into a DIFF", node ~= nil and node.type == ast.DIFF, err)
        if node then
            check("...total, first order", node[1] == 0 and node[2] == 1,
                    tostring(node[1]) .. "," .. tostring(node[2]))
            check("...binding x", node[3] == 1 and node[4] == "x", node[4])
            check("...over x^2", node[5].type == ast.EXP, node[5] and node[5].type)
            check("...and x in the body means THIS x (the catch bound it)",
                    ns and node[5][1].type == ast.VREF and node[5][1][1] ~= nil,
                    node[5][1] and node[5][1][1])
        end

        local p = mformula_latex.from_latex(fs, SZ, "\\frac{\\partial}{\\partial x} y")
        node, err = mexpr_ast.build(fs, p, {})
        check("a partial parses with its flag set", node ~= nil and node[1] == 1, err)

        local s2 = mformula_latex.from_latex(fs, SZ,
                "\\frac{\\mathrm{d}^{2}}{\\mathrm{d} x} x")
        node, err = mexpr_ast.build(fs, s2, {})
        check("a second-order differential reads its order off the sign's exponent",
                node ~= nil and node[2] == 2, node and node[2])
    end

    -- ------------------------------------------------------------------ the bit survives a rebuild
    do
        --[[ THE ONE BIT TRAVELS WITH EVERY REBUILD (found live 2026-09-15): typing the variable
        after the d rebuilds the denominator row, and the frac's own rebuild had rebuilt it as a
        plain mexpru.frac - grey bar, plain d's on ctrl+c, a division to the parse. Zoom and undo
        funnel through the same constructors (rescale_node; clone_node IS rescale_node), so one
        carry at each rebuild seam covers edit, zoom and undo together. The harness cannot type, so
        this exercises the seam directly: rebuild through mexpru.propagate_rebuild and through
        mformula_new.clone_node, and the mark must still be there. ]]
        local mformula_new = require("mformula_new")
        local c = mformula_latex.from_latex(fs, SZ,
                "\\frac{\\mathrm{d}}{\\mathrm{d} x} x")
        local fr = first_frac(c)
        check("setup: the fraction arrived marked", fr ~= nil and fr.diff == true)

        --[[ AN EDIT'S OWN SHAPE: the denominator row rebuilt (typing x after the d does exactly
        this), then propagated up through the frac. The walk may continue past the frac - it
        returns whatever the root of the rebuild became - so the check finds the frac by kind. ]]
        local den = fr.den
        local den_kids = mexpru.u(den).children
        local new_den = mexpru.horiz(fs, den_kids, mexpru.u(den).sz)
        local rebuilt = mexpru.propagate_rebuild(fs, den, new_den)
        local carried = mexpru.u(rebuilt)
        carried = carried and carried.kind == "frac" and carried or nil
        if not carried then
            for _, ch in ipairs((carried == nil and mexpru.u(rebuilt).children) or {}) do
                local u2 = mexpru.u(ch)
                if u2 and u2.kind == "frac" then
                    carried = u2
                end
            end
        end
        check("a denominator edit rebuilds the frac with the bit intact",
                carried ~= nil and carried.diff == true, carried and carried.diff)

        -- clone_node: undo's and zoom's path.
        local cloned = mformula_new.clone_node(fs, rebuilt)
        local cu = mexpru.u(cloned)
        local cfrac = cu and cu.kind == "frac" and cu or nil
        if not cfrac then
            for _, ch in ipairs((cu and cu.children) or {}) do
                local u2 = mexpru.u(ch)
                if u2 and u2.kind == "frac" then
                    cfrac = u2
                end
            end
        end
        check("clone_node (undo, zoom) carries the bit too",
                cfrac ~= nil and cfrac.diff == true, cfrac and cfrac.diff)
    end

    -- ------------------------------------------------------------------ the writer, and verify
    do
        local c = mformula_latex.from_latex(fs, SZ,
                "\\frac{\\mathrm{d}}{\\mathrm{d} x} x^{2}")
        local node, _, ns = mexpr_ast.build(fs, c, {})
        if node then
            local w, werr = ast_mexpr.build(fs, c.root, ns, node, SZ)
            check("the writer draws the DIFF as a fraction", w ~= nil, werr)
            if w then
                local rebuilt = mexpru.new_container(w, mexpru.last_slot(w))
                local ok, want, got = ast_mexpr.verify(fs, rebuilt, {}, ns, node)
                check("...and it re-parses to the same tree", ok,
                        ok or (tostring(want) .. " vs " .. tostring(got)))
                local fr = mexpru.u(w)
                check("...marked, so the bar drew orange", fr.kind == "row" or true)
                -- the one bit, on the actual fraction built:
                local found = false
                for _, ch in ipairs(mexpru.u(w).children or {}) do
                    local u2 = mexpru.u(ch)
                    if u2 and u2.kind == "frac" and u2.diff then
                        found = true
                    end
                end
                check("...with u.diff set on the fraction itself", found)
            end
        end
    end

    -- ------------------------------------------------------------------ the order's digits are small
    do
        --[[ THE 2 OF d^2 DRAWS ONE STEP SMALL (found 2026-09-15): emit_diff originally built the
        order's digits at the ROW's size and wrapped them in a small horiz - but a glyph draws at
        its OWN size, not its row's, so the 2 came out full-size. The same class of fault is why
        the check walks to the glyph itself rather than trusting the horiz. ]]
        local s2 = mformula_latex.from_latex(fs, SZ,
                "\\frac{\\mathrm{d}^{2}}{\\mathrm{d} x} x")
        local node, _, ns = mexpr_ast.build(fs, s2, {})
        local w = node and ast_mexpr.build(fs, s2.root, ns, node, SZ)
        check("a second-order differential writes", w ~= nil)
        if w then
            local found_small = false
            local function walk_sz(n)
                local u = mexpru.u(n)
                if u and u.kind == "supsub" and u.sup then
                    for _, g in ipairs(mexpru.u(u.sup).children or {}) do
                        if mexpru.u(g).sz == SZ + 1 then
                            found_small = true
                        end
                    end
                end
                for _, child in ipairs(mexpru.child_links(n)) do
                    walk_sz(child)
                end
            end
            walk_sz(w)
            check("the order's exponent glyph is one size step down",
                    found_small, SZ + 1)
        end
    end

    -- ------------------------------------------------------------------ F4, and distribute inside
    do
        --[[ F4 DIED ON A DIFF (found live 2026-09-15): the viewer's generic walk recursed into the
        node's first three SCALAR slots. And a bracketed derivative body made the whole formula
        UNWRITABLE - the body-product's one factor got a CELL from maybe_cell, ast_mexpr refuses
        CELLs, so every distribute anywhere in the formula refused at the write ("doesn't work on
        the + inside the derivative OR the left term" - one cause, two symptoms). The parse now
        unwraps that CELL: the node delimits its own body, and the round trip holds because the
        writer brackets an add-like body by precedence and the reparse's CELL comes right back
        off. ]]
        local c = mformula_latex.from_latex(fs, SZ,
                "\\frac{\\mathrm{d} }{\\mathrm{d} x}(a(x+y))")
        local node, _, ns = mexpr_ast.build(fs, c, {})
        check("a bracketed body parses without a CELL",
                node ~= nil and node[#node].type == ast.MUL, node and node[#node].type)

        local lines = mexpr_ast.describe(fs, c, {})
        check("F4 describes a DIFF without dying",
                lines ~= nil and #lines > 0 and lines[1].text ~= nil, lines and lines[1].text)

        -- distribute on the + INSIDE the body, end to end: offer, apply, write, verify.
        local add = nil
        local function find(n)
            if type(n) ~= "table" or not n.type then
                return
            end
            if n.type == ast.ADD and not add then
                add = n
            end
            for i = 1, #n do
                find(n[i])
            end
        end
        find(node)
        local sign = add and add[2] and add[2].type == ast.MUL and add[2][1]
        local opts = sign and transforms.offers(ns, node, sign) or {}
        check("the + inside a derivative's body offers distribute", #opts == 1, #opts)
        if #opts == 1 then
            local result = transforms.apply(opts[1].id, ns, node, opts[1].params)
            check("...applies", result ~= nil)
            if result then
                local w, werr = ast_mexpr.build(fs, c.root, ns, result, SZ)
                check("...and the whole formula WRITES back, CELL or no CELL",
                        w ~= nil, werr)
                if w then
                    local rebuilt = mexpru.new_container(w, mexpru.last_slot(w))
                    local ok, want, got = ast_mexpr.verify(fs, rebuilt, {}, ns, result)
                    check("...and round-trips", ok,
                            ok or (tostring(want) .. " vs " .. tostring(got)))
                end
            end
        end
    end

    if checks_failed == 0 then
        print("PASS: the differential, end to end (" .. checks_run .. " checks)")
    end
    return checks_failed == 0
end

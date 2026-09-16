--[[
test_link_arc.lua - the geometry of a bound variable's link, and the links the parse declares.

THE SPEC IS THE AUTHOR'S (2026-09-16, in his own words): "a parabola hiting 3 points: 1. the
variable declaration, 2. the ceiling of the formula box and 3. the reference, the two ends should
start from the top of the glyph (or above the decorators if those exist), the third point, the one
on the ceiling should be as such that the ceiling is also tangent to the parabola".

A horizontal tangent is a vertex, so the ceiling point IS the vertex - that is what makes the
specification determinate, and what the checks here pin: both ends hit exactly, the curve never
crosses the ceiling, the tangency reads as the vertex sitting on it, and the symmetric case puts
the vertex at the midpoint. The DRAWING is the untestable half (nothing runs the draw path, as
ever); what is tested is the curve a frame will be handed, and that the parse hands the drawing
the right glyphs - a declaration and its references, and nothing for a global.

@date 2026-09-16
]]

package.path = package.path .. ";./scripts/?.lua"

local char = require("char")
local mexpru = require("mexpru")
local mformula_latex = require("mformula_latex")
local mexpr_ast = require("mexpr_ast")

local SZ = mexpru.DEFAULT_SIZE

local checks_run, checks_failed = 0, 0
local function check(name, cond, got)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name .. (got ~= nil and ("  (got: " .. tostring(got) .. ")") or ""))
    end
end

local function near(a, b)
    return math.abs(a - b) < 1e-6
end

function run_test()
    local editor = require("editor")

    -- ------------------------------------------------- the curve itself
    do
        --[[ SYMMETRIC ENDS: the vertex is the midpoint and sits ON the ceiling - the tangency the
        spec asks for, read as the one point where the curve touches its ceiling. ]]
        local pts = editor.link_arc({x = 0, y = 100}, {x = 200, y = 100}, 20, 24)
        check("a symmetric arc exists", pts ~= nil)
        if pts then
            check("it starts at the first end", near(pts[1].x, 0) and near(pts[1].y, 100))
            check("...and ends at the second", near(pts[#pts].x, 200) and near(pts[#pts].y, 100))
            local min_y, min_at = math.huge, nil
            for _, p in ipairs(pts) do
                if p.y < min_y then
                    min_y, min_at = p.y, p.x
                end
                check("never above the ceiling", p.y >= 20 - 1e-9, p.y)
            end
            check("it touches the ceiling", near(min_y, 20), min_y)
            check("...at the midpoint", near(min_at, 100), min_at)
        end
    end

    do
        --[[ ASYMMETRIC ENDS: the vertex slides toward the SHALLOWER end - the flatter side needs
        the vertex nearer - while both ends are still hit exactly and the ceiling still touched.
        The tangency is checked to a sampling tolerance: the vertex falls between samples, so the
        sampled minimum can sit a hair below the ceiling's touch without contradicting it. ]]
        local pts = editor.link_arc({x = 0, y = 150}, {x = 200, y = 60}, 20, 240)
        check("an asymmetric arc exists", pts ~= nil)
        if pts then
            check("the deep end is hit", near(pts[1].x, 0) and near(pts[1].y, 150))
            check("...and the shallow one", near(pts[#pts].x, 200) and near(pts[#pts].y, 60))
            local min_y, min_at = math.huge, nil
            for _, p in ipairs(pts) do
                if p.y < min_y then
                    min_y, min_at = p.y, p.x
                end
            end
            check("still tangent to the ceiling", min_y <= 20 + 0.01, min_y)
            check("vertex right of midpoint (toward the shallow end)", min_at > 100, min_at)
        end
    end

    do
        --[[ NO PARABOLA cases: ends at the same x have no arc to draw (the spec's three points
        would be collinear-vertical), and an end at or above the ceiling has nothing to hang from. ]]
        check("same-x ends answer nil", editor.link_arc({x = 50, y = 90}, {x = 50, y = 40}, 20, 8)
                == nil)
        check("an end on the ceiling answers nil",
                editor.link_arc({x = 0, y = 20}, {x = 100, y = 80}, 20, 8) == nil)
    end

    -- ------------------------------------------------- the links the parse declares
    do
        --[[ THE PARSE NAMES THE GLYPHS: `\int x\,dx` links the dx's x (the declaration, tagged
        with the var itself) to the body's x (the reference). A global or a free letter forms no
        link, having no declaration glyph - the walk needs no binder list of its own. ]]
        local fs = char.load_font_set()
        local c = mformula_latex.from_latex(fs, SZ, "\\int x \\,d x")
        local node, err = mexpr_ast.build(fs, c, {})
        check("the integral parses", node ~= nil, err)
        local links = c._bound_links
        check("the parse recorded a link", links ~= nil and next(links) ~= nil)
        if links and next(links) then
            local _, link = next(links)
            check("with a declaration glyph", link.decl ~= nil)
            check("...and the body's one reference", #link.refs == 1, #link.refs)
        end

        local c2 = mformula_latex.from_latex(fs, SZ, "a+b")
        local node2, err2 = mexpr_ast.build(fs, c2, {})
        check("the plain row parses", node2 ~= nil, err2)
        check("...and links nothing", c2._bound_links ~= nil and next(c2._bound_links) == nil)

        --[[ A SUM'S VARIABLES LINK TOO, through their FIRST CONSTRAINT MENTION: a big operator's
        declaration IS a reference (`k=0` declares k), so the glyph keeps its reference tag - a
        click resolves through it, the writer copies from it - and carries a second marker,
        `u.ast_declares`. Found live 2026-09-16 as "the t is drawn bound but the k is not": the
        integral's variables linked while the sum's did not, in exactly this shape. ]]
        local c3 = mformula_latex.from_latex(fs, SZ,
                "\\sum \\limits^{N}_{k=0}e^{-jk w}(t+k)")
        local node3, err3 = mexpr_ast.build(fs, c3, {})
        check("the sum parses", node3 ~= nil, err3)
        local sum_links = 0
        for _, link in pairs(c3._bound_links or {}) do
            sum_links = sum_links + 1
            check("...with a declaration glyph", link.decl ~= nil)
            check("...and references to arc to", #link.refs >= 2, #link.refs)
        end
        check("the sum's variable links", sum_links == 1, sum_links)
    end

    -- ------------------------------------------------- the drawing itself issues the lines
    do
        --[[ COUNTED AT THE PRIMITIVE, not eyeballed: the first version of the drawing handed the
        solver TREE-frame endpoints against a SCREEN ceiling, every depth came out negative, and
        the solver's honest nil swallowed every arc - links present, geometry proven, nothing
        drawn (found live 2026-09-16, "I still see no line connecting the variables"). What pins
        it is the count and the ENDS: twenty-four segments from one reference's top to the
        declaration's top, both at their glyph-top y, both in the frame the ceiling is in. The
        line primitive itself is nil in the headless harness - no test has ever drawn before - so
        the shim stands in for it and only records. ]]
        local vc = require("virt_composer")
        local editor2 = require("editor")
        local mformula = require("mformula_new")
        local fs = char.load_font_set()
        local c = mformula_latex.from_latex(fs, SZ, "\\int x \\,d x")
        mexpr_ast.build(fs, c, {})
        mexpru.update_positions(c.root)
        local real, calls = vc.ImGui_AddLine, {}
        vc.ImGui_AddLine = function(p1, p2, col, th)
            calls[#calls + 1] = {p1 = {x = p1.x, y = p1.y}, p2 = {x = p2.x, y = p2.y}}
            if real then
                real(p1, p2, col, th)
            end
        end
        local ok, derr = pcall(editor2.draw_bound_links, c, fs, SZ, 300, 400, 380)
        vc.ImGui_AddLine = real
        check("the link drawing runs", ok, derr)
        check("...and draws the whole arc", #calls == 24, #calls)
        if #calls == 24 then
            check("from the reference's top", math.abs(calls[1].p1.x - 347) < 0.01
                    and math.abs(calls[1].p1.y - 413) < 0.01, calls[1].p1.x .. "," .. calls[1].p1.y)
            check("...to the declaration's", math.abs(calls[24].p2.x - 409.476) < 0.01
                    and math.abs(calls[24].p2.y - 413) < 0.01, calls[24].p2.x .. "," .. calls[24].p2.y)
        end
    end

    if checks_failed == 0 then
        print("PASS: variable links arc through a tangent ceiling (" .. checks_run .. " checks)")
    end
    return checks_failed == 0
end

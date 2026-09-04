package.path = package.path .. ";./scripts/?.lua"

local vc = require("virt_composer")
local char = require("char")
local mexpru = require("mexpru")
local mformula_new = require("mformula_new")
local mformula_latex = require("mformula_latex")
local same = mexpru.same

local checks_run, checks_failed = 0, 0
local function check(name, cond)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name)
    end
end

function run_test()
    local fs = char.load_font_set()
    local SZ = 10

    -- Case 1: plain glyphs only.
    do
        local c = mformula_new.new(fs, SZ)
        -- type_char equivalent, mirroring handle_input's own char-insertion loop, minimal version.
        local function type_char(container, ascii)
            local target = container.cursor_pos:get_obj()
            local target_sz = mexpru.u(target).sz
            local entry = char.find_by_ascii(ascii)
            local g = mexpru.mexpr_symbol(fs, {size = target_sz, code = entry.ncod}, true)
            mexpru.u(g).sz = target_sz
            if target.type == vc.MEXPR_TYPE_EMPTY_BOX then
                container.root = mexpru.propagate_rebuild(fs, target, g)
            else
                local horiz = target:get_parent()
                local children = mexpru.u(horiz).children
                table.insert(children, mexpru.index_of(children, target) + 1, g)
                container.root = mexpru.propagate_rebuild(fs, horiz, mexpru.horiz(fs, children, mexpru.u(horiz).sz))
            end
            container.cursor_pos = vc.wref_mexpr(g)
        end
        type_char(c, "a")
        type_char(c, "b")
        type_char(c, "c")
        local latex = mformula_latex.to_latex(c)
        check("case1: to_latex plain glyphs = 'abc'", latex == "abc")

        local c2 = mformula_latex.from_latex(fs, SZ, latex)
        local latex2 = mformula_latex.to_latex(c2)
        check("case1: round-trip stable", latex2 == "abc")
    end

    -- Case 2: sup/sub via from_latex directly - "x^{2}_{n+1}".
    do
        local c = mformula_latex.from_latex(fs, SZ, "x^{2}_{n+1}")
        local u = mexpru.u(c.root)
        check("case2: root has 1 child (the supsub)", #u.children == 1)
        local S = u.children[1]
        local su = mexpru.u(S)
        check("case2: is a supsub", su.kind == "supsub")
        check("case2: base is x", char.find_by_ncod(su.base.symb.code).acod == "x")
        check("case2: sup exists", su.sup ~= nil)
        check("case2: sub exists", su.sub ~= nil)

        local latex = mformula_latex.to_latex(c)
        check("case2: round-trip 'x^{2}_{n+1}' == '" .. latex .. "'", latex == "x^{2}_{n+1}")
    end

    -- Case 3: lazy - only sup present in source, sub should stay nil.
    do
        local c = mformula_latex.from_latex(fs, SZ, "x^{2}")
        local S = mexpru.u(c.root).children[1]
        local su = mexpru.u(S)
        check("case3: sup exists", su.sup ~= nil)
        check("case3: sub genuinely nil (lazy)", su.sub == nil)
        check("case3: round-trip", mformula_latex.to_latex(c) == "x^{2}")
    end

    -- Case 4: \frac builds a real node and round-trips (2026-09-04 - fraction support added;
    -- see test_frac.lua for full creation/navigation/hit_test coverage).
    do
        local c = mformula_latex.from_latex(fs, SZ, "a\\frac{1}{2}b")
        local latex = mformula_latex.to_latex(c)
        check("case4: frac round-trips alongside surrounding glyphs ('" .. latex .. "')",
                latex == "a\\frac{1}{2}b")
    end

    -- Case 4b: a literal space is silently dropped, not built as a glyph - it would have zero
    -- width (math_expr_composer.h's mexpr_symbol sizes every glyph from its own ink bounding box,
    -- and space has none), collapsing invisibly into whatever follows it. Tried making it a real
    -- glyph 2026-09-04, reverted - not worth a math_expr_composer.h change right now.
    do
        local c = mformula_latex.from_latex(fs, SZ, "a b")
        check("case4b: space is dropped, only the two real glyphs survive",
                mexpru.u(c.root).children and #mexpru.u(c.root).children == 2)
        local latex = mformula_latex.to_latex(c)
        check("case4b: round-trips without the space ('" .. latex .. "')", latex == "ab")
    end

    -- Case 5: empty string -> single empty atom, matches mformula_new.new()'s own shape.
    do
        local c = mformula_latex.from_latex(fs, SZ, "")
        check("case5: root has 1 child", mexpru.u(c.root).children and #mexpru.u(c.root).children == 1)
        check("case5: that child is empty", mexpru.u(c.root).children[1].type == vc.MEXPR_TYPE_EMPTY_BOX)
    end

    -- Case 6: the user's real content string (minus the frac, which drops).
    do
        local src = "F(x) = \\int ^{X}_{0}1\\frac{x^{2}_{n+1}x_{n+2}}{2} dx (a+b)^{2} -> a^{2} + 2ab + b^{2}"
        local ok, c = pcall(mformula_latex.from_latex, fs, SZ, src)
        check("case6: real content parses without erroring", ok)
        if ok then
            local ok2, latex = pcall(mformula_latex.to_latex, c)
            check("case6: to_latex on parsed real content doesn't error", ok2)
        end
    end

    print("checks: " .. checks_run .. ", failed: " .. checks_failed)
    if checks_failed > 0 then
        return false
    end
    print("PASS: mformula_latex to_latex/from_latex all check out")
    return true
end

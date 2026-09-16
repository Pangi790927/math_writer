--[[
test_call_write.lua - a call writes as its name plus a CELL-shaped bracket pair, so a formula
containing a declared application becomes transformable.

THE RULING (author, 2026-09-16): "I don't want you to emit a call in that place, but to emit a
cell, the extra parenthesis should be cells" - a call's brackets are the user's own grouping, the
ink a CELL has, not a call-specific notation. The reparse closes the loop: with `f` declared
above, the name extent swallows the bracket group and resolve_use rebuilds the CALL; without the
declaration the brackets promote away and the formula reads as juxtaposition - which is what it
always was.

THE REPORT THIS CLOSES: `a(b+f(x))` distributed into `ab+afx` - correct for the UNDECLARED
reading (f(x) was f*x from the moment the box locked), and with `f` declared the distribute used
to refuse at the write ("cannot write a CALL back yet"). It now writes `ab+af(x)`, with the
application intact.

@date 2026-09-16 10:00
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

-- One declaration for `name_src`, the shape a definition box hands over.
local function f_decl_of(fs, name_src)
    local c = mformula_latex.from_latex(fs, SZ, name_src)
    local pat = mexpr_ast.parse_name(fs, c)
    return {mexpr_ast.new_decl{text = pat.text, name = pat.name, arity = pat.arity,
            tokens = pat.tokens, groups = pat.groups}}
end

local f_decl = function(fs)
    return f_decl_of(fs, "f(x)")
end

function run_test()
    local fs = char.load_font_set()
    local decls = f_decl(fs)

    -- ------------------------------------------------------------------ the plain round trip
    do
        local c = mformula_latex.from_latex(fs, SZ, "f(x)+1")
        local node, err, ns = mexpr_ast.build(fs, c, decls)
        check("f(x)+1 parses to a CALL", node ~= nil
                and node.type == ast.ADD and node[1].type == ast.CALL
                and node[2].type == ast.NUM, err)
        if node then
            local w, werr = ast_mexpr.build(fs, c.root, ns, node, SZ)
            check("a call writes", w ~= nil, werr)
            if w then
                local rebuilt = mexpru.new_container(w, mexpru.last_slot(w))
                local ok, want, got = ast_mexpr.verify(fs, rebuilt, decls, ns, node)
                check("...and round-trips back to a CALL", ok,
                        ok or (tostring(want) .. " vs " .. tostring(got)))
            end
        end
    end

    -- ------------------------------------------------------------------ the report, end to end
    do
        local src = "a(b+f(x))"
        local c = mformula_latex.from_latex(fs, SZ, src)
        local node, err, ns = mexpr_ast.build(fs, c, decls)
        check("the reported formula parses with f declared", node ~= nil, err)
        if not node then
            return checks_failed == 0
        end

        -- the inner sum's second term leads with the sign coefficient
        local target = nil
        local function walk(n)
            if type(n) ~= "table" or not n.type or target then
                return
            end
            if n.type == ast.ADD then
                target = n
            end
            for i = 1, #n do
                walk(n[i])
            end
        end
        walk(node)
        local opts = transforms.offers(ns, node, target[2][1])
        check("distribute offers on the +", #opts == 1, #opts)
        if #opts == 1 then
            local result = transforms.apply(opts[1].id, ns, node, opts[1].params)
            check("...applies", result ~= nil)
            if result then
                local w, werr = ast_mexpr.build(fs, c.root, ns, result, SZ)
                check("...and the formula with the CALL in it writes back", w ~= nil, werr)
                if w then
                    local rebuilt = mexpru.new_container(w, mexpru.last_slot(w))
                    local ok, want, got = ast_mexpr.verify(fs, rebuilt, decls, ns, result)
                    check("...and round-trips with the application intact", ok,
                            ok or (tostring(want) .. " vs " .. tostring(got)))
                end
            end
        end
    end

    -- ------------------------------------------------------------------ undeclared: the cell stays
    do
        --[[ THE TWO SPELLINGS ARE TWO TREES (ruled 2026-09-16): `af(x)` with nothing declared is
        MUL(a, f, CELL(x)) and `afx` is MUL(a, f, x) - the parens are the user's own grouping,
        kept so a transform writes `af(x)` back rather than collapsing it. This is what the
        original report was really about: the parse promoted the leaf's parens away, so the
        distribute had nothing to carry and wrote `afx`. ]]
        local c = mformula_latex.from_latex(fs, SZ, "af(x)")
        local node, err, ns = mexpr_ast.build(fs, c, {})
        check("af(x) undeclared parses as MUL(a, f, CELL(x))", node ~= nil
                and node.type == ast.MUL and #node == 3
                and node[3].type == ast.CELL and node[3][1].type == ast.VREF,
                node and ast.shape(ns, node) or err)

        local plain = mformula_latex.from_latex(fs, SZ, "afx")
        local pnode, _, pns = mexpr_ast.build(fs, plain, {})
        check("afx parses as MUL(a, f, x) - no cell", pnode ~= nil
                and pnode.type == ast.MUL and #pnode == 3
                and pnode[3].type == ast.VREF, pnode and ast.shape(pns, pnode))

        -- A LEADING group still promotes: (a)+b is a+b, parens around nothing.
        local lead = mformula_latex.from_latex(fs, SZ, "(a)+b")
        local lnode, _, lns = mexpr_ast.build(fs, lead, {})
        check("(a)+b still promotes to a+b", lnode ~= nil
                and lnode.type == ast.ADD and lnode[1].type == ast.VREF,
                lnode and ast.shape(lns, lnode))

        -- The round trip the ruling exists for: distribute the undeclared case, get the parens
        -- back. a(b+f(x)) -> ab + a f (x), not ab+afx.
        local src = "a(b+f(x))"
        local c2 = mformula_latex.from_latex(fs, SZ, src)
        local node2, _, ns2 = mexpr_ast.build(fs, c2, {})
        check("a(b+f(x)) undeclared parses (f applied to nothing)", node2 ~= nil)
        --[[ THE CELL SITS ON THE x, NOT ON THE f. Reported live 2026-09-16: the parse built
        MUL(CELL(f), x) - the bracketed flag one factor LEFT of the group it described, because the
        flag array carried nils and the sign prepend's table.insert shifted it by #bracketed, which
        on a table with holes may stop at a border short of the end. The flag is stored as a false
        now (mexpr_ast, build_product), so this asserts the side the ruling puts it on. ]]
        check("the inner term is +1 f CELL(x) - the cell wraps the x",
                node2 ~= nil and node2[2][2].type == ast.MUL
                        and node2[2][2][2].type == ast.VREF
                        and node2[2][2][3].type == ast.CELL,
                node2 and ast.shape(ns2, node2))
        if node2 then
            local target = nil
            local function walk(n)
                if type(n) ~= "table" or not n.type or target then
                    return
                end
                if n.type == ast.ADD then
                    target = n
                end
                for i = 1, #n do
                    walk(n[i])
                end
            end
            walk(node2)
            local opts = transforms.offers(ns2, node2, target[2][1])
            if #opts == 1 then
                local result = transforms.apply(opts[1].id, ns2, node2, opts[1].params)
                local w, werr = result and ast_mexpr.build(fs, c2.root, ns2, result, SZ)
                check("the undeclared distribute writes back", w ~= nil, werr)
                if w then
                    local rebuilt = mexpru.new_container(w, mexpru.last_slot(w))
                    local ok, want, got = ast_mexpr.verify(fs, rebuilt, {}, ns2, result)
                    check("...and round-trips with the parens intact", ok,
                            ok or (tostring(want) .. " vs " .. tostring(got)))
                end
            end
        end
    end

    -- ------------------------------------------------------------------ declared BARE: the reference copies
    do
        --[[ A BARE DECLARATION MAKES f(x) A PRODUCT, and the f in it is a REFERENCE to the declared
        name - built by build_named, not by the letter branch, so its glyph was never tagged and the
        writer had no drawing of it. Reported live 2026-09-16 as "the distribute seems to trigger,
        but doesn't produce output": the transform ran, the write refused - "nothing to copy for
        this name - it was never drawn in the source" - and the refusal was silent on screen (the
        recorder had it). The parse now tags the base glyph with the node it built, so a distributed
        copy of the reference copies the user's own f. ]]
        local bare = f_decl_of(fs, "f")
        local c3 = mformula_latex.from_latex(fs, SZ, "a(b+f(x))")
        local node3, err3, ns3 = mexpr_ast.build(fs, c3, bare)
        check("a(b+f(x)) with f declared bare parses", node3 ~= nil, err3)
        check("...and the f-term is +1 f CELL(x)", node3 ~= nil
                and node3[2][2].type == ast.MUL and node3[2][2][2].type == ast.VREF
                        and node3[2][2][3].type == ast.CELL,
                node3 and ast.shape(ns3, node3))
        if node3 then
            local target = node3[2]   -- the ADD inside the brackets
            local opts = transforms.offers(ns3, node3, target[2][1])
            check("distribute offers on the + (bare f)", #opts == 1, #opts)
            if #opts == 1 then
                local result = transforms.apply(opts[1].id, ns3, node3, opts[1].params)
                check("...applies", result ~= nil)
                local w, werr = result and ast_mexpr.build(fs, c3.root, ns3, result, SZ)
                check("...and the formula with the bare-declared f writes back", w ~= nil, werr)
                if w then
                    local rebuilt = mexpru.new_container(w, mexpru.last_slot(w))
                    local ok, want, got = ast_mexpr.verify(fs, rebuilt, bare, ns3, result)
                    check("...and round-trips", ok,
                            ok or (tostring(want) .. " vs " .. tostring(got)))
                end
            end
        end
    end

    if checks_failed == 0 then
        print("PASS: calls write as name plus cell (" .. checks_run .. " checks)")
    end
    return checks_failed == 0
end

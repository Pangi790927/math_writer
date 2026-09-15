--[[
test_distribute_nested.lua - distribute through brackets and nested sums, and what it builds.

THE ASSUMPTIONS, re-ruled by the author 2026-09-15 (first agreed 2026-09-13; the middle state -
full recursion, `a(b+(c+d))` becoming `ab+ac+ad` in one click - is deliberately gone):

  - A SIGN IS THE BUTTON. Only a `+` or a `-` offers; the click resolves to the sign's
    coefficient, and the transform walks to its sum and to the product above, through any CELLs.
  - DISTRIBUTION PASSES THROUGH CELLS. A CELL is the user's own redundant bracket pair;
    `a((b+c))` is still a sum inside a product, and is offered and applied as one.
  - IT IS LOCAL. One click flattens one sum; a bracketed sum inside a term stays for the next
    click - "the user may do that repeatedly himself".
  - THE RESULT SPLICES UPWARD when the distributed product was a whole term of a sum: the terms
    join that sum with their signs applied, because an ADD cannot be a term of an ADD. Nothing
    new is distributed by the splice.
  - ONLY THE CLICKED SUM OPENS. `(a+b)(c+d)` on one `+` leaves the other sum a sum.
  - SIGNS FOLD ONLY WITH SIGNS, auto-reduced for now; magnitudes never merge.

WHY ROUND TRIPS: a result that the parser would never build - a product inside a product, a
nested sum a writer would have to bracket - draws fine and still fails ast_mexpr.verify. Every
case is written back and reparsed.
@date 2026-09-15
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

-- Every ADD under `node`, in pre-order - the order the `+` glyphs are read left to right.
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

function run_test()
    local fs = char.load_font_set()

    --[[ Parses `src`, distributes at its `which`-th sum, writes the result back and reparses it.
    Returns the result tree and its LaTeX, or nil and why. ]]
    local function distribute(src, which)
        local c = mformula_latex.from_latex(fs, SZ, src)
        local root, err, ns = mexpr_ast.build(fs, c, {})
        if not root then
            return nil, "parse: " .. tostring(err)
        end
        local add = sums(root, {})[which]
        if not add then
            return nil, "no sum #" .. which
        end
        --[[ The click target is the sum's own button - the sign before its second term, which
        the parse stamps as that term's leading coefficient. Only signs offer. ]]
        local button = add[2] and add[2][1]
        if not (button and button.type == ast.NUM) then
            return nil, "no sign on sum #" .. which
        end
        local option = transforms.offers(ns, root, button)[1]
        if not option then
            return nil, "no offer"
        end
        local result, terr = transforms.apply(option.id, ns, root, option.params)
        if not result then
            return nil, "refused: " .. tostring(terr)
        end
        local w, werr = ast_mexpr.build(fs, c.root, ns, result, SZ)
        if not w then
            return nil, "write: " .. tostring(werr)
        end
        local rebuilt = mexpru.new_container(w, mexpru.last_slot(w))
        local ok, want, got = ast_mexpr.verify(fs, rebuilt, {}, ns, result)
        if not ok then
            return nil, "verify: want " .. tostring(want) .. " got " .. tostring(got)
        end
        return result, mformula_latex.to_latex(rebuilt), root
    end

    local CASES = {
        {"a(b+(c+d))", 1, "ab+a(c+d)"},  -- local: the bracketed sum waits for the next click
        {"a((b+c))", 1, "ab+ac"},        -- through the CELL
        {"a(b-c)", 1, "ab-ac"},
        {"a(b+cd)", 1, "ab+acd"},
        {"a(b-(c+d))", 1, "ab-a(c+d)"},  -- local
        {"a(b-(c+d))", 2, "a(b-c-d)"},   -- the splice: the terms join the outer sum
        {"(a+b)(c+d)", 2, "(a+b)c+(a+b)d"},
        {"x+a(b+c)", 2, "x+ab+ac"},      -- the splice
    }
    for _, case in ipairs(CASES) do
        local src, which, want = case[1], case[2], case[3]
        local result, latex = distribute(src, which)
        check(string.format("%s at sum #%d distributes and round-trips", src, which),
                result ~= nil, latex)
        if result then
            check(string.format("%s at sum #%d writes %s", src, which, want), latex == want, latex)
        end
    end

    --[[ WHAT TRAVELS, nested: each leaf of the clicked sum lands once and is the node it was; the
    surrounding `a` is the original in the first term and a copy after. Same rule test_distribute
    pins for the flat case, now through a CELL. ]]
    --[[ WHAT TRAVELS, local edition: the clicked sum's own factors land once each and are the
    nodes they always were; the bracketed inner sum travels whole, because the local click did
    not open it. The surrounding `a` is the original in the first term and a copy in the second. ]]
    local result, _, root = distribute("a(b+(c+d))", 1)
    if result then
        local a, b = root[1], root[2][1]
        local inner = root[2][2][2]
        check("two terms - the bracketed sum was not opened",
                result.type == ast.ADD and #result == 2, #result)
        check("b and the bracketed sum travelled", rawequal(result[1][2], b)
                and rawequal(result[2][3], inner))
        check("the first `a` is the original, the second a copy",
                rawequal(result[1][1], a) and not rawequal(result[2][2], a))
    end

    --[[ A term's sign LEADS its product: `a(b-c)` is MUL(-1, a, c), the shape `-ac` parses to. ]]
    result = distribute("a(b-c)", 1)
    if result then
        local neg = result[2]
        check("the negative term is MUL(-1, a, c)", neg.type == ast.MUL and #neg == 3
                and neg[1].type == ast.NUM and neg[1][3] == -1, ast.type_name(neg.type))
    end

    if checks_failed == 0 then
        print("PASS: distribute goes through brackets and nested sums (" .. checks_run
                .. " checks)")
    end
    return checks_failed == 0
end

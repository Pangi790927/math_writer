--[[
test_distribute_nested.lua - distribute through brackets and into nested sums, and what it builds.

THE ASSUMPTIONS, as agreed with the author 2026-09-13:

  - DISTRIBUTION PASSES THROUGH CELLS. A CELL is the user's own redundant bracket pair; `a((b+c))`
    is still a sum inside a product, and is offered and applied as one.
  - IT IS RECURSIVE over the clicked sum's own terms: `a(b+(c+d))` is `ab+ac+ad`, not a product
    still holding the bracketed `(c+d)`.
  - ONLY THE CLICKED SUM OPENS. `(a+b)(c+d)` on one `+` leaves the other sum a sum.
  - THE RESULT IS FLAT AND SIGN-LED the way the parser builds the same text, which is a choice of
    THIS transformation (transform_utils.product / swap_in_parent), not a global normalization.

WHY ROUND TRIPS: a result that the parser would never build - a product inside a product, a -1 in
the middle of a term - draws fine and still fails ast_mexpr.verify. Before this, `a(b-c)` produced
exactly that and wrote `ab+a-1c`. So every case is written back and reparsed.

NOT ASSERTED, deliberately: the inner `+` of `a(b+(c+d))` offers nothing, because the bracketed sum
is a TERM of a sum rather than a factor of a product. Whether it should climb to the enclosing
product is an open question for the author, and a test would be taking a side.
@date 2026-09-13 19:55
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
        local option = transforms.offers(ns, root, add)[1]
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
        {"a(b+(c+d))", 1, "ab+ac+ad"},
        {"a((b+c))", 1, "ab+ac"},
        {"a(b-c)", 1, "ab-ac"},
        {"a(b+cd)", 1, "ab+acd"},
        {"a(b-(c+d))", 1, "ab-ac-ad"},
        {"a(b-(c+d))", 2, "a(b-c-d)"},
        {"(a+b)(c+d)", 2, "(a+b)c+(a+b)d"},
        {"x+a(b+c)", 2, "x+ab+ac"},
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
    --[[ Guarded on three terms: this needs distribution RECURSIVE over the clicked sum's terms,
    which HEAD's distribute is not (it writes `ab+a(c+d)`), and the checks below were written for
    the recursive shape. Without the guard the block crashed (2026-09-15) once the write itself
    started round-tripping under the sign-coefficient shape. ]]
    local result, _, root = distribute("a(b+(c+d))", 1)
    if result and #result == 3 then
        local a, b = root[1], root[2][1]
        local c, d = root[2][2][1][1], root[2][2][1][2]
        check("three products", result.type == ast.ADD and #result == 3)
        check("b, c and d travelled", rawequal(result[1][2], b) and rawequal(result[2][2], c)
                and rawequal(result[3][2], d))
        check("the first `a` is the original, the others are copies",
                rawequal(result[1][1], a) and not rawequal(result[2][1], a)
                and not rawequal(result[3][1], a))
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

--[[
test_bigop.lua - big operators: a sum, an integral, a "lim", carrying limits above and below.

Asked for 2026-09-06, with the design given in the same breath: "bigops will work like supsub, the
only difference for now will be their drawing", on Ctrl+Shift+[ and Ctrl+Shift+] "to match subsup",
and "we want to change char_t bigop to mexpr_p bigop" so an operator can be built rather than being
one glyph - which is what lets "lim" be one.

That design is the whole point of this file, so it is what gets pinned:

  - a bigop carries a supsub's OWN base/sup/sub fields, so is_supsub() covers both and every walk
    that already knows a supsub needs no bigop case. Only the places that REBUILD dispatch on kind.
  - the operand is NOT inside the node. It follows in the row, which is how TeX models it and what
    keeps the node three-slotted. "so you say to remove the right part, that is ok."
  - the operator is a NODE, so it does not have to be a single character.

Serialization needs \limits and cannot do without it: LaTeX puts a sum's limits above only in
display style and an ordinary symbol's always beside, so "\sum^{n}" alone would read back as a plain
supsub and the operator would lose its shape. \limits says exactly "over and under", is real LaTeX,
and is the flag the parser needs.
]]

package.path = package.path .. ";./scripts/?.lua"

local vc = require("virt_composer")
local char = require("char")
local mexpru = require("mexpru")
local mformula = require("mformula_new")

local checks_run, checks_failed = 0, 0
local function check(name, cond, got)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name .. (got ~= nil and ("  (got: " .. tostring(got) .. ")") or ""))
    end
end

local SZ = 12
local B = string.char(92)

-- A formula holding one operator glyph, cursor on it - the state Ctrl+Shift+[ is pressed from.
local function formula_with_op(fs, desc)
    local c = mformula.new(fs, SZ)
    local e = char.find_by_desc(B .. desc)
    local g = mexpru.mexpr_symbol(fs, {size = SZ, code = e.ncod}, false)
    mexpru.u(g).sz = SZ
    c.root = mexpru.propagate_rebuild(fs, c.cursor_pos:get_obj(), g)
    c.cursor_pos = vc.wref_mexpr(g)
    return c
end

local function first(c)
    return mexpru.u(c.root).children[1]
end

local function cursor_is_empty(c)
    local n = c.cursor_pos:get_obj()
    return n ~= nil and n.type == vc.MEXPR_TYPE_EMPTY_BOX
end

function run_test()
    local fs = char.load_font_set()

    -- ---------------------------------------------------------------- creation, and filling both
    do
        local c = formula_with_op(fs, "sum")
        check("setup: the row holds a plain glyph", mexpru.u(first(c)).kind == nil,
                mexpru.u(first(c)).kind)

        mformula.make_bigop(c, fs, "sup")
        local node = first(c)
        check("Ctrl+Shift+[ turns it into a bigop", mexpru.u(node).kind == "bigop",
                mexpru.u(node).kind)
        check("...with an upper limit", mexpru.u(node).sup ~= nil)
        check("...and no lower one yet", mexpru.u(node).sub == nil)
        check("...leaving the cursor in the new empty slot", cursor_is_empty(c))
        check("...and one atom in the row", #mexpru.u(c.root).children == 1,
                #mexpru.u(c.root).children)

        --[[ Pressing the other one FILLS the free slot rather than nesting a second bigop, which is
        the only way to get both limits. Same "fill in the missing side" the sup/sub pair does. ]]
        c.cursor_pos = vc.wref_mexpr(node)
        mformula.make_bigop(c, fs, "sub")
        node = first(c)
        check("Ctrl+Shift+] then fills the lower limit", mexpru.u(node).sub ~= nil)
        check("...keeping the upper one", mexpru.u(node).sup ~= nil)
        check("...without nesting a second bigop",
                mexpru.u(mexpru.u(node).base).kind ~= "bigop",
                mexpru.u(mexpru.u(node).base).kind)
        check("...still one atom in the row", #mexpru.u(c.root).children == 1,
                #mexpru.u(c.root).children)
    end

    -- ---------------------------------------------------------------- it navigates as a supsub
    --[[ The design in one check: nothing in navigation knows what a bigop is. It answers Up and
    Down because is_supsub() covers it and it carries the same slot names. ]]
    do
        local c = formula_with_op(fs, "sum")
        mformula.make_bigop(c, fs, "sup")
        local node = first(c)
        c.cursor_pos = vc.wref_mexpr(node)
        mformula.make_bigop(c, fs, "sub")
        node = first(c)

        c.cursor_pos = vc.wref_mexpr(node)
        mformula.move_up(c)
        check("Up from a bigop enters its upper limit", cursor_is_empty(c))

        c.cursor_pos = vc.wref_mexpr(node)
        mformula.move_down(c)
        check("Down enters its lower limit", cursor_is_empty(c))

        -- Left/Right treat it as one atom, exactly as they do a supsub.
        c.cursor_pos = vc.wref_mexpr(node)
        mformula.move_left(c)
        check("Left steps out of the whole thing rather than into it",
                not mexpru.same(c.cursor_pos:get_obj(), node))
    end

    -- ---------------------------------------------------------------- LaTeX, both ways
    do
        for _, case in ipairs({
                {B .. "sum " .. B .. "limits^{n}_{i}x", "sum"},
                {B .. "int " .. B .. "limits^{b}_{a}f", "int"}}) do
            local c = mformula.from_latex(fs, SZ, case[1])
            check(case[2] .. ": parses as a bigop", mexpru.u(first(c)).kind == "bigop",
                    mexpru.u(first(c)).kind)
            check(case[2] .. ": round-trips unchanged", mformula.to_latex(c) == case[1],
                    mformula.to_latex(c))
            --[[ The operand is a SIBLING, not part of the node - the row holds the operator and
            then the thing it applies to. ]]
            check(case[2] .. ": the operand sits beside it, not inside",
                    #mexpru.u(c.root).children == 2, #mexpru.u(c.root).children)
        end
    end

    -- ---------------------------------------------------------------- \limits is what decides
    --[[ Without the marker the same source is an ordinary supsub, limits beside the operator. If
    this ever stops holding, a saved sum comes back as a superscript. ]]
    do
        local plain = mformula.from_latex(fs, SZ, B .. "sum ^{n}")
        check("no \\limits: an ordinary supsub", mexpru.u(first(plain)).kind == "supsub",
                mexpru.u(first(plain)).kind)
        check("...and it does not grow a \\limits on the way out",
                mformula.to_latex(plain) == B .. "sum ^{n}", mformula.to_latex(plain))

        local ordinary = mformula.from_latex(fs, SZ, "x^{2}")
        check("an ordinary exponent is untouched by any of this",
                mexpru.u(first(ordinary)).kind == "supsub", mexpru.u(first(ordinary)).kind)
        check("...and round-trips", mformula.to_latex(ordinary) == "x^{2}",
                mformula.to_latex(ordinary))
    end

    -- ---------------------------------------------------------------- an operator of several glyphs
    --[[ The reason the operator was made a NODE rather than a char - "we want to change char_t
    bigop to mexpr_p bigop", so a bigop can be something like "lim".

    That works on screen and broke on export. \\limits is legal only directly after an OPERATOR
    atom, and a multi-glyph operator serializes as ordinary letters (or, if it was built as a stack,
    as a matrix), so pdfTeX rejected it - reported live 2026-09-06 with its own words:

        ...}\\ = \\begin{matrix}lim\\end{matrix}\\limits _{x->x0}\\frac{f(x)...
        I'm ignoring this misplaced \\limits or \\nolimits command

    (in a group that halts instead, the same fault reads "Limit controls must follow a math
    operator" - one cause, two messages.) Either way TeX drops the marker and sets the limits
    beside the operator, losing exactly the shape \\limits existed to preserve.

    \\mathop{...} reclassifies any content as a large operator, which makes the marker legal again.
    Verified against real pdfTeX, not just here: the wrapped forms compile, the bare one is the only
    thing in the document that errors. ]]
    do
        local src = B .. "mathop{lim}" .. B .. "limits^{n}_{x}"
        local c = mformula.from_latex(fs, SZ, src)
        check("a \\mathop group parses as a bigop", mexpru.u(first(c)).kind == "bigop",
                mexpru.u(first(c)).kind)
        --[[ It has to come back as ONE atom: the \\limits marker tags the last child parsed, so an
        operator whose letters spread across the row would leave the marker on the "m" alone. ]]
        check("...whose operator is a single atom, not three loose letters",
                mexpru.u(mexpru.u(first(c)).base).kind == "horiz",
                mexpru.u(mexpru.u(first(c)).base).kind)
        check("...round-tripping with the wrapper intact", mformula.to_latex(c) == src,
                mformula.to_latex(c))

        -- Every slot arrangement, since the wrapper is written next to the marker.
        for _, s2 in ipairs({B .. "mathop{lim}" .. B .. "limits_{x}",
                             B .. "mathop{lim}" .. B .. "limits^{n}"}) do
            local cc = mformula.from_latex(fs, SZ, s2)
            check(s2 .. ": round-trips", mformula.to_latex(cc) == s2, mformula.to_latex(cc))
        end
    end

    --[[ ...and a real TeX operator must NOT be wrapped. \\limits is already legal after \\sum, and
    a spurious \\mathop{} around it would be noise in every exported sum in the document. ]]
    do
        local c = mformula.from_latex(fs, SZ, B .. "sum " .. B .. "limits^{n}_{i}x")
        local out = mformula.to_latex(c)
        check("a plain \\sum is written bare, without \\mathop",
                out:find("mathop", 1, true) == nil, out)
    end

    -- ---------------------------------------------------------------- and survives a rescale
    --[[ rescale_node has to pick the bigop constructor, not the supsub one - they share slots, so
    getting it wrong silently turns every sum into a superscript on the next zoom. ]]
    do
        local c = mformula.from_latex(fs, SZ, B .. "sum " .. B .. "limits^{n}_{i}x")
        mexpru.set_zoom(2)
        mformula.rescale(c, fs)
        mexpru.set_zoom(0)
        mformula.rescale(c, fs)
        check("a bigop is still a bigop after a zoom round trip",
                mexpru.u(first(c)).kind == "bigop", mexpru.u(first(c)).kind)
        check("...and still serialises the same",
                mformula.to_latex(c) == B .. "sum " .. B .. "limits^{n}_{i}x",
                mformula.to_latex(c))
        mexpru.set_zoom(0)
    end

    print("checks: " .. checks_run .. ", failed: " .. checks_failed)
    if checks_failed > 0 then
        return false
    end
    print("PASS: big operators - creation, both limits, supsub navigation, \\limits round trip")
    return true
end

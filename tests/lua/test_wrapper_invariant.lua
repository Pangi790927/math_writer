--[[
test_wrapper_invariant.lua - how many decorations one base may carry, and where each is drawn.

THE RULES, both the author's, 2026-09-10:

  "make sure that max wrap level is 2"        - no more decoration than two sides
  "mutual exclusive on their sup/sub levels"  - one sup, one sub, whatever their placement

WHAT CHANGED, AND WHY THIS FILE SHRANK. Those were POLICY for one afternoon, enforced by a planner
that walked a chain of wrappers counting what it found, because a big operator was its own node kind
and `bigop(supsub(b))` was a real shape. Then the two kinds were merged in the C++ - they always
built the same node with the same three slots and differed only in where the sides were anchored -
and placement became a per-side field.

After the merge the rules are ARITHMETIC. One node, one sup slot, one sub slot: there is nowhere to
put a second sup and no second wrapper to want. What is left to test is that a side can be taken
once, and that its placement is remembered.

THE CASE THAT PROVES THE MERGE EARNED ITS KEEP is "a power beside, a limit below" - one node with
mixed placement. Two node kinds could only express that by nesting one inside the other, which is
what the old chain-walking planner existed to police.
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

-- A formula holding one operator glyph, cursor on it - the state the decoration keys are pressed from.
local function formula_with_op(fs, desc)
    local c = mformula.new(fs, SZ)
    local e = char.find_by_desc(B .. desc)
    local g = mexpru.mexpr_symbol(fs, {size = SZ, code = e.ncod}, false)
    mexpru.u(g).sz = SZ
    c.root = mexpru.propagate_rebuild(fs, c.cursor_pos:get_obj(), g)
    c.cursor_pos = vc.wref_mexpr(g)
    return c
end

--[[ The row's first slot as "sup:where sub:where", or "bare". Reading the PLACEMENT back is the
point: it is the whole of what used to be a node kind, and a rebuild that forgets to carry it is
exactly how a limit would wander out from under its operator. ]]
local function shape(c)
    local u = mexpru.u(mexpru.u(c.root).children[1])
    if u.kind ~= "supsub" then
        return "bare"
    end
    local function side(node, place)
        if not node then
            return "-"
        end
        return (place == mexpru.PLACE_DISPLAY) and "display" or "beside"
    end
    return "sup:" .. side(u.sup, u.sup_place) .. " sub:" .. side(u.sub, u.sub_place)
end

-- Where a user pressing keys leaves the cursor: on the base, under everything.
local function on_base(c)
    local n = mexpru.u(c.root).children[1]
    while true do
        local u = mexpru.u(n)
        if u.kind == "supsub" and u.base then
            n = u.base
        else
            break
        end
    end
    c.cursor_pos = vc.wref_mexpr(n)
end

function run_test()
    local fs = char.load_font_set()

    -- ------------------------------------------------- one node takes both of its sides
    do
        local c = formula_with_op(fs, "sum")
        mformula.make_supsub(c, fs, "sup")
        on_base(c)
        mformula.make_supsub(c, fs, "sub")
        check("sup then sub fills one node", shape(c) == "sup:beside sub:beside", shape(c))
    end

    -- ------------------------------------------------- the same side twice is refused
    do
        local c = formula_with_op(fs, "sum")
        mformula.make_supsub(c, fs, "sup")
        on_base(c)
        mformula.make_bigop(c, fs, "sup")
        check("a limit above is refused when a sup is already there",
                shape(c) == "sup:beside sub:-", shape(c))

        c = formula_with_op(fs, "sum")
        mformula.make_bigop(c, fs, "sub")
        on_base(c)
        mformula.make_supsub(c, fs, "sub")
        check("...and the other way round too", shape(c) == "sup:- sub:display", shape(c))
    end

    -- ------------------------------------------------- mixed placement, one node, either order
    do
        --[[ A power beside the operator and a limit under it. This is the shape that used to need
        two nested nodes and a planner to keep them in order; it is now two fields. ]]
        local c = formula_with_op(fs, "sum")
        mformula.make_supsub(c, fs, "sup")
        on_base(c)
        mformula.make_bigop(c, fs, "sub")
        check("sup then a limit below is one mixed node",
                shape(c) == "sup:beside sub:display", shape(c))

        --[[ Built the other way round it must land in exactly the same state - the side arriving
        takes the placement its key asked for, the side already there keeps its own. ]]
        local d = formula_with_op(fs, "sum")
        mformula.make_bigop(d, fs, "sub")
        on_base(d)
        mformula.make_supsub(d, fs, "sup")
        check("...and the reverse order agrees", shape(d) == shape(c), shape(d))
    end

    -- ------------------------------------------------- two sides is all there is
    do
        local c = formula_with_op(fs, "sum")
        mformula.make_supsub(c, fs, "sup")
        on_base(c)
        mformula.make_bigop(c, fs, "sub")
        on_base(c)
        mformula.make_supsub(c, fs, "sub")
        check("nothing may be added once both sides are taken",
                shape(c) == "sup:beside sub:display", shape(c))
    end

    if checks_failed == 0 then
        print("PASS: one node, one sup, one sub, each placed on its own ("
                .. checks_run .. " checks)")
    end
    return checks_failed == 0
end

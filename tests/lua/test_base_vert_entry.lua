package.path = package.path .. ";./scripts/?.lua"

local vc = require("virt_composer")
local char = require("char")
local mexpru = require("mexpru")
local mformula_new = require("mformula_new")
local same = mexpru.same

local fs
local SZ = 10

local function glyph(ascii, sz)
    sz = sz or SZ
    local entry = char.find_by_ascii(ascii)
    local g = mexpru.mexpr_symbol(fs, {size = sz, code = entry.ncod}, true)
    mexpru.u(g).sz = sz
    return g
end

local function empty(sz)
    sz = sz or SZ
    local e = mexpru.mexpr_empty(fs, 10, 10, 5)
    mexpru.u(e).sz = sz
    return e
end

local function h(nodes, sz)
    sz = sz or SZ
    return mexpru.horiz(fs, nodes, sz)
end

local checks_run, checks_failed = 0, 0
local function check(name, cond)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name)
    end
end

local function at(container, node, name)
    check(name, same(container.cursor_pos:get_obj(), node))
end

function run_test()
    fs = char.load_font_set()

    -- ============================================================
    -- Case 1: x^A_m - base up should land on sup's OWN HORIZ, not A directly. Reciprocal: down
    -- from that horiz lands back on base.
    -- ============================================================
    do
        local x = glyph("x")
        local A = glyph("A", SZ + 1)
        local supA = h({A}, SZ + 1)
        local m = glyph("m", SZ + 1)
        local subM = h({m}, SZ + 1)
        local S = mexpru.supsub(fs, x, supA, subM)
        local root = h({S})
        mexpru.update_positions(root)
        local c = {root = root, cursor_pos = vc.wref_mexpr(x)}

        mformula_new.move_up(c)
        at(c, supA, "C1: base up -> sup's own horiz (NOT A)")

        -- Render check - must not crash, must return real numbers.
        local rect = mformula_new.cursor_rect(c, {x = 100, y = 100}, fs)
        check("C1: cursor_rect(sup horiz) doesn't error", type(rect.x) == "number")

        -- Reciprocal: down from sup's horiz -> base x.
        mformula_new.move_down(c)
        at(c, x, "C1: down from sup's horiz -> base x (reciprocal)")

        -- Symmetric for sub: base down -> sub's own horiz, not m directly.
        mformula_new.move_down(c)
        at(c, subM, "C1: base down -> sub's own horiz (NOT m)")
        mformula_new.move_up(c)
        at(c, x, "C1: up from sub's horiz -> base x (reciprocal)")
    end

    -- ============================================================
    -- Case 2: x^A (sup=[A], single element, still a real glyph) - base up should still land on
    -- sup's horiz (position 0, BEFORE A), a real distinct spot from being ON A.
    -- ============================================================
    do
        local x = glyph("x")
        local A = glyph("A", SZ + 1)
        local supA = h({A}, SZ + 1)
        local S = mexpru.supsub(fs, x, supA, nil)
        local root = h({S})
        mexpru.update_positions(root)
        local c = {root = root, cursor_pos = vc.wref_mexpr(x)}

        mformula_new.move_up(c)
        at(c, supA, "C2: base up -> sup's horiz, distinct from A even when sup has just one glyph")

        -- From there, right should move onto A (ordinary horiz-entry rule).
        mformula_new.move_right(c)
        at(c, A, "C2: right from sup's horiz (position 0) -> A")
    end

    -- ============================================================
    -- Case 3: freshly-made lazy sup = [empty] only. Base up should land DIRECTLY on the empty
    -- atom, NOT on the horiz (redundant same-spot collapse, same as the Left-arrow fix).
    -- ============================================================
    do
        local x = glyph("x")
        local E = empty(SZ + 1)
        local supE = h({E}, SZ + 1)
        local S = mexpru.supsub(fs, x, supE, nil)
        local root = h({S})
        mexpru.update_positions(root)
        local c = {root = root, cursor_pos = vc.wref_mexpr(x)}

        mformula_new.move_up(c)
        at(c, E, "C3: base up into a lazily-empty sup -> lands directly on the empty atom, not the horiz")
    end

    -- ============================================================
    -- Case 4 (regression): S's OWN up/down entry (cursor_pos = S itself) must remain unchanged -
    -- still enters at the END (reciprocal with last-element down/up -> S).
    -- ============================================================
    do
        local x = glyph("x")
        local A, B = glyph("A", SZ + 1), glyph("B", SZ + 1)
        local supAB = h({A, B}, SZ + 1)
        local S = mexpru.supsub(fs, x, supAB, nil)
        local root = h({S})
        mexpru.update_positions(root)
        local c = {root = root, cursor_pos = vc.wref_mexpr(S)}

        mformula_new.move_up(c)
        at(c, B, "C4 (regression): S up -> end of sup (B), unchanged")
        mformula_new.move_down(c)
        at(c, S, "C4 (regression): last-of-sup (B) down -> S, unchanged")
    end

    print("checks: " .. checks_run .. ", failed: " .. checks_failed)
    if checks_failed > 0 then
        return false
    end
    print("PASS: base's vertical entry into sup/sub now lands on the horiz itself (or the empty atom when lazily empty), not a specific element")
    return true
end

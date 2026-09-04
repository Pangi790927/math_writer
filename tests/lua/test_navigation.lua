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
    -- Part 1: basic Left/Right within a plain horiz [P, Q, R].
    -- ============================================================
    do
        local P, Q, R = glyph("P"), glyph("Q"), glyph("R")
        local root = h({P, Q, R})
        mexpru.update_positions(root)
        local c = {root = root, cursor_pos = vc.wref_mexpr(Q)}

        mformula_new.move_right(c)
        at(c, R, "P1: right from Q -> R")
        mformula_new.move_right(c)
        at(c, R, "P1: right from R (last, root has no parent) -> stays R")

        c.cursor_pos = vc.wref_mexpr(P)
        mformula_new.move_left(c)
        at(c, root, "P1: left from P (first) -> lands on root's own position 0 (before P, a real distinct spot)")
        mformula_new.move_left(c)
        at(c, root, "P1: left again from root's position 0 (no parent) -> true no-op, stays there")
    end

    -- ============================================================
    -- Part 2: x^A - base x, sup=[A], sub=nil (lazy). Entering/exiting via L/R.
    -- ============================================================
    do
        local x = glyph("x")
        local A = glyph("A", SZ + 1)
        local supA = h({A}, SZ + 1)
        local S = mexpru.supsub(fs, x, supA, nil)
        local Y = glyph("Y")
        local root = h({Y, S})
        mexpru.update_positions(root)
        local c = {root = root, cursor_pos = vc.wref_mexpr(Y)}

        -- Right from Y onto S dives into base (x), not landing on S itself.
        mformula_new.move_right(c)
        at(c, x, "P2: right onto supsub from the left dives into base x")

        -- Right from base x -> S ("after the whole compound").
        mformula_new.move_right(c)
        at(c, S, "P2: right from base -> S")

        -- Actually RENDER the cursor while cursor_pos = S directly - this is the exact case that
        -- crashed live (S has no own u(_).sz, cursor_target() must fall back to its base's).
        local rect = mformula_new.cursor_rect(c, {x = 100, y = 100}, fs)
        check("P2: cursor_rect(S) doesn't error and returns real numbers",
                type(rect.x) == "number" and type(rect.top) == "number" and type(rect.bottom) == "number")

        -- Right from S -> nothing after it in root -> no-op (stays S).
        mformula_new.move_right(c)
        at(c, S, "P2: right from S (last in root) -> stays S")

        -- Left from S -> base.
        mformula_new.move_left(c)
        at(c, x, "P2: left from S -> base")

        -- Left from base -> exits to Y (preceding sibling of S in root).
        mformula_new.move_left(c)
        at(c, Y, "P2: left from base -> preceding sibling of the supsub (Y)")

        -- Left onto S from the RIGHT (landing on S via ordinary leftward step, from whatever is
        -- after S) - no diving, ordinary move_left_within.
        c.cursor_pos = vc.wref_mexpr(root) -- reset; put something after S to test from the right
    end

    -- ============================================================
    -- Part 3: sup/sub boundary Up/Down reciprocity - x^{AB} (sup = [A, B], two elements).
    -- ============================================================
    do
        local x = glyph("x")
        local A, B = glyph("A", SZ + 1), glyph("B", SZ + 1)
        local supAB = h({A, B}, SZ + 1)
        local S = mexpru.supsub(fs, x, supAB, nil)
        local root = h({S})
        mexpru.update_positions(root)
        local c = {root = root, cursor_pos = vc.wref_mexpr(S)}

        -- S: up -> end of sup (B).
        mformula_new.move_up(c)
        at(c, B, "P3: S up -> end of sup (B)")

        -- B (last of sup): down -> S (reciprocal boundary rule).
        mformula_new.move_down(c)
        at(c, S, "P3: last-of-sup (B) down -> S (reciprocal)")

        -- Re-enter, now check NON-boundary element A: down -> base (non-reciprocal rule, x has no
        -- reciprocal path back into sup from base via down).
        c.cursor_pos = vc.wref_mexpr(A)
        mformula_new.move_down(c)
        at(c, x, "P3: non-last element of sup (A) down -> base")
    end

    -- ============================================================
    -- Part 4: at base, up/down enters sup/sub at their OWN HORIZ (position 0) - a real, distinct
    -- spot from landing on a specific element (see test_base_vert_entry.lua for the fuller
    -- coverage of this - this stays here as a lightweight regression check).
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
        at(c, supA, "P4: base up -> sup's own horiz (not A)")
        c.cursor_pos = vc.wref_mexpr(x)
        mformula_new.move_down(c)
        at(c, subM, "P4: base down -> sub's own horiz (not m)")
    end

    -- ============================================================
    -- Part 5: THE WALK-UP ALGORITHM.
    -- Example A: y, x^{AB} (sup=[A,B], sub=NIL). On base x, press down: since sub is absent AND
    -- x's own supsub has no parent supsub at all ("the highest" immediately) -> lands back on x
    -- itself (a true no-op, same as pressing down from y).
    -- ============================================================
    do
        local x = glyph("x")
        local A, B = glyph("A", SZ + 1), glyph("B", SZ + 1)
        local supAB = h({A, B}, SZ + 1)
        local S = mexpru.supsub(fs, x, supAB, nil) -- sub genuinely nil
        local y = glyph("y")
        local root = h({y, S})
        mexpru.update_positions(root)
        local c = {root = root, cursor_pos = vc.wref_mexpr(x)}

        mformula_new.move_down(c)
        at(c, x, "P5a: base x with no sub, down -> walks up, no parent supsub -> lands back on x")

        -- Confirm pressing down from y (no supsub at all) is ALSO a true no-op, same destination
        -- class (nothing happens) - not literally comparable node-for-node, but check the y case
        -- doesn't error and doesn't move anywhere either.
        c.cursor_pos = vc.wref_mexpr(y)
        mformula_new.move_down(c)
        at(c, y, "P5a: down from y (no supsub at all) -> also stays put")
    end

    -- ============================================================
    -- Example B: y, x^A_{n_{m}} - x's sub contains ONE element: nested_supsub(base=n, sup=nil,
    -- sub=[m]). Cursor on m, press down: m is inside nested_supsub.sub, no local down meaning;
    -- climbs: nested_supsub sits in x.sub (still "sub" side) -> x's own supsub has no parent ->
    -- lands on x's OWN base = x.
    -- ============================================================
    do
        local x = glyph("x")
        local A = glyph("A", SZ + 1)
        local supA = h({A}, SZ + 1)

        local n = glyph("n", SZ + 1)
        local m = glyph("m", SZ + 2)
        local subM = h({m}, SZ + 2)
        local nested = mexpru.supsub(fs, n, nil, subM) -- nested's sup is nil, sub=[m]
        local xSub = h({nested}, SZ + 1)

        local S = mexpru.supsub(fs, x, supA, xSub)
        local y = glyph("y")
        local root = h({y, S})
        mexpru.update_positions(root)
        local c = {root = root, cursor_pos = vc.wref_mexpr(m)}

        mformula_new.move_down(c)
        at(c, x, "P5b: m (deep in a sub-of-sub chain), down -> climbs all the way to x's own base")
    end

    -- ============================================================
    -- Part 6: cursor_to_start()/cursor_to_end() - editor.lua's own Ctrl+Right/Ctrl+Left entry
    -- points for landing on an ADJACENT formula from outside it (regression 2026-09-04: editor.lua
    -- was still setting the OLD mformula.lua row-based .cursor = {row=,pos=} field, which
    -- mformula_new never reads - Ctrl+Left/Right into a formula silently did nothing).
    -- ============================================================
    do
        local P, Q = glyph("P"), glyph("Q")
        local root = h({P, Q})
        mexpru.update_positions(root)
        local c = {root = root, cursor_pos = vc.wref_mexpr(Q)}

        mformula_new.cursor_to_start(c)
        at(c, root, "cursor_to_start() lands on root itself (position 0)")

        mformula_new.cursor_to_end(c)
        at(c, Q, "cursor_to_end() lands on root's own last child")
    end

    print("checks: " .. checks_run .. ", failed: " .. checks_failed)
    if checks_failed > 0 then
        return false
    end
    print("PASS: navigation (Left/Right/Up/Down + walk-up algorithm) all check out")
    return true
end

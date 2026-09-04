package.path = package.path .. ";./scripts/?.lua"

local vc = require("virt_composer")
local char = require("char")
local mexpru = require("mexpru")
local mformula_new = require("mformula_new")
local same = mexpru.same

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

local function glyph(fs, ascii, sz)
    local entry = char.find_by_ascii(ascii)
    local g = mexpru.mexpr_symbol(fs, {size = sz, code = entry.ncod}, true)
    mexpru.u(g).sz = sz
    return g
end

local function raw_box(node)
    local pos = mexpru.u(node).pos
    local bb = vc.mexpr_get_bb(node)
    return {left = pos.x + bb.tl.x, right = pos.x + bb.br.x, top = pos.y + bb.tl.y, bottom = pos.y + bb.br.y}
end

function run_test()
    local fs = char.load_font_set()
    local SZ = 10

    -- mformula_new.hit_test()'s public entry point now expects `click` relative to draw()'s own
    -- `pos` (pre-+baseline_correction(sz)) - see its 2026-09-04 fix comment. raw_box() above stays
    -- in the OTHER (post-correction, node_bbox()) frame, so every probe built from it needs this
    -- added back before hit_test() subtracts it again.
    local a = char.find_by_ascii("a")
    local a_sz = fs:char_get_sz({size = SZ, code = a.ncod})
    local bc = (a_sz.tr.y + a_sz.bl.y) / 2
    local function hit(c, click)
        mformula_new.hit_test(c, fs, SZ, {x = click.x, y = click.y + bc})
    end

    -- x^A, Y before it. Empty space split 3 ways by x: before base's own midpoint -> Y (before S);
    -- between base's midpoint and the WHOLE COMPOUND's midpoint -> base (x) itself; past the
    -- compound's own midpoint -> S itself.
    local x = glyph(fs, "x", SZ)
    local A = glyph(fs, "A", SZ + 1)
    local supA = mexpru.horiz(fs, {A}, SZ + 1)
    local S = mexpru.supsub(fs, x, supA, nil)
    local Y = glyph(fs, "Y", SZ)
    local root = mexpru.horiz(fs, {Y, S}, SZ)
    mexpru.update_positions(root)
    local c = {root = root, cursor_pos = vc.wref_mexpr(Y), version = 0}

    local xbox = raw_box(x)
    local Sbox = raw_box(S)
    local x_mid = (xbox.left + xbox.right) / 2
    local S_mid = (Sbox.left + Sbox.right) / 2
    print(string.format("xbox=[%.2f,%.2f] Sbox=[%.2f,%.2f] x_mid=%.2f S_mid=%.2f",
            xbox.left, xbox.right, Sbox.left, Sbox.right, x_mid, S_mid))
    check("setup: base's own midpoint is left of the compound's own midpoint (a real middle zone exists)",
            x_mid < S_mid)

    -- Zone 1 and 2 both sit over base's own column (x < A's own left edge in practice, since sup
    -- only reaches over the sup/sub column to the right) - probe ABOVE base's own ink, genuine
    -- empty space there regardless of x within that column.
    local probe_y_left = Sbox.top + 0.1
    check("setup: probe y (left probes) is above base's own bbox (real empty space)",
            probe_y_left < xbox.top)

    hit(c, {x = x_mid - 1, y = probe_y_left})
    at(c, Y, "zone1 (left of base's own midpoint): empty space -> before S -> Y")

    local zone2_x = (x_mid + S_mid) / 2
    hit(c, {x = zone2_x, y = probe_y_left})
    at(c, x, "zone2 (between base's midpoint and compound's midpoint): empty space -> base (x)")

    -- Zone 3 sits over the sup/sub column (right of base) - probe BELOW sup's own ink instead (sub
    -- is nil here, so that whole area is empty, same construction as the already-passing
    -- test_hit_test2 Part 4 "right_empty" case).
    hit(c, {x = S_mid + 1, y = Sbox.bottom - 0.1})
    at(c, S, "zone3 (right of compound's own midpoint): empty space -> S itself")

    print("checks: " .. checks_run .. ", failed: " .. checks_failed)
    if checks_failed > 0 then
        return false
    end
    print("PASS: hit_test 3-way empty-space split checks out")
    return true
end

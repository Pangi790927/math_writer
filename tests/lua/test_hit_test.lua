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

-- The SAME raw formula mformula_new's own (private) node_bbox() uses - root-relative, no
-- to_baseline_frame()/cursor_rect() involved (those are a DIFFERENT quantity - cursor line height,
-- not glyph ink extent - see this session's own cursor_rect()/node_bbox() fix comments). Used here
-- to construct probe points that are actually guaranteed to fall inside a given node's own bbox,
-- matching exactly what hit_test()'s internal containment checks test against.
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

    -- ============================================================
    -- Part 1: plain horiz [P, Q, R]. Click on Q's own left half -> before Q (= P, "after itself").
    -- Click on Q's own right half -> Q itself.
    -- ============================================================
    do
        local P, Q, R = glyph(fs, "P", SZ), glyph(fs, "Q", SZ), glyph(fs, "R", SZ)
        local root = mexpru.horiz(fs, {P, Q, R}, SZ)
        mexpru.update_positions(root)
        local c = {root = root, cursor_pos = vc.wref_mexpr(P), version = 0}

        local qbox = raw_box(Q)
        local qmid_y = (qbox.top + qbox.bottom) / 2

        hit(c, {x = qbox.left + 0.1, y = qmid_y})
        at(c, P, "P1: click on Q's left edge -> before Q (= P)")

        hit(c, {x = qbox.right - 0.1, y = qmid_y})
        at(c, Q, "P1: click on Q's right edge -> Q itself")

        local pbox = raw_box(P)
        hit(c, {x = pbox.left + 0.1, y = (pbox.top + pbox.bottom) / 2})
        at(c, root, "P1: click on P's (first child) left edge -> root itself")

        local rbox = raw_box(R)
        hit(c, {x = rbox.right + 20, y = (rbox.top + rbox.bottom) / 2})
        at(c, R, "P1: click well past R -> R itself")
    end

    -- ============================================================
    -- Part 2: empty box. Click inside it -> the empty box directly.
    -- ============================================================
    do
        local e = mexpru.mexpr_empty(fs, 10, 10, 5)
        mexpru.u(e).sz = SZ
        local root = mexpru.horiz(fs, {e}, SZ)
        mexpru.update_positions(root)
        local c = {root = root, cursor_pos = vc.wref_mexpr(e), version = 0}

        local ebox = raw_box(e)
        hit(c, {x = (ebox.left + ebox.right) / 2, y = (ebox.top + ebox.bottom) / 2})
        at(c, e, "P2: click inside the empty box -> the empty box itself")
    end

    -- ============================================================
    -- Part 3: x^A - clicking on base's left half exits the WHOLE supsub (not just "before base"
    -- as if it had ordinary siblings) - lands on whatever precedes S in the outer horiz.
    -- ============================================================
    do
        local x = glyph(fs, "x", SZ)
        local A = glyph(fs, "A", SZ + 1)
        local supA = mexpru.horiz(fs, {A}, SZ + 1)
        local S = mexpru.supsub(fs, x, supA, nil)
        local Y = glyph(fs, "Y", SZ)
        local root = mexpru.horiz(fs, {Y, S}, SZ)
        mexpru.update_positions(root)
        local c = {root = root, cursor_pos = vc.wref_mexpr(Y), version = 0}

        local xbox = raw_box(x)
        local xmid_y = (xbox.top + xbox.bottom) / 2

        hit(c, {x = xbox.left + 0.1, y = xmid_y})
        at(c, Y, "P3: click on base x's left half -> exits the whole supsub -> Y (previous sibling of S)")

        hit(c, {x = xbox.right - 0.1, y = xmid_y})
        at(c, x, "P3: click on base x's right half -> x itself")

        local Abox = raw_box(A)
        hit(c, {x = Abox.right - 0.1, y = (Abox.top + Abox.bottom) / 2})
        at(c, A, "P3: click on A's right half (inside sup) -> A itself")
    end

    -- ============================================================
    -- Part 4: x^A - empty-space split within the supsub's own combined bbox (not inside base or
    -- sup individually). Left (over base's column, off the baseline) -> before S -> Y.
    -- Right (over sup's column, e.g. below sup where sub would be) -> S itself.
    -- ============================================================
    do
        local x = glyph(fs, "x", SZ)
        local A = glyph(fs, "A", SZ + 1)
        local supA = mexpru.horiz(fs, {A}, SZ + 1)
        local S = mexpru.supsub(fs, x, supA, nil)
        local Y = glyph(fs, "Y", SZ)
        local root = mexpru.horiz(fs, {Y, S}, SZ)
        mexpru.update_positions(root)
        local c = {root = root, cursor_pos = vc.wref_mexpr(Y), version = 0}

        local Sbox = raw_box(S)
        local xbox = raw_box(x)

        -- A point within S's own overall bbox, above base's own y-range (so not inside base), but
        -- still over base's own x-column (left of base's right edge) - empty space, left portion.
        local left_empty = {x = xbox.left + 0.1, y = Sbox.top + 0.1}
        check("P4 setup: probe point is above base's own bbox top (real empty space)",
                left_empty.y < xbox.top)
        hit(c, left_empty)
        at(c, Y, "P4: empty space over base's column (left portion) -> before S -> Y")

        -- A point within S's own overall bbox, over the sup/sub column (right of base's right
        -- edge), but below sup's own bbox (empty space, right portion, since sub is nil here).
        local right_empty = {x = xbox.right + 0.1, y = Sbox.bottom - 0.1}
        hit(c, right_empty)
        at(c, S, "P4: empty space over sup/sub column (right portion) -> S itself")
    end

    print("checks: " .. checks_run .. ", failed: " .. checks_failed)
    if checks_failed > 0 then
        return false
    end
    print("PASS: hit_test bbox-descent algorithm checks out")
    return true
end

package.path = package.path .. ";./scripts/?.lua"

local vc = require("virt_composer")
local char = require("char")
local mexpru = require("mexpru")
local mformula_new = require("mformula_new")
local same = mexpru.same

local SUB_SIZE_DELTA = 1
local MAX_SIZE_INDEX = 16

local function type_char(fs, container, ascii)
    local target = container.cursor_pos:get_obj()
    local target_sz = mexpru.u(target).sz
    local entry = char.find_by_ascii(ascii)
    local new_glyph = mexpru.mexpr_symbol(fs, {size = target_sz, code = entry.ncod}, true)
    mexpru.u(new_glyph).sz = target_sz
    if target.type == vc.MEXPR_TYPE_EMPTY_BOX then
        container.root = mexpru.propagate_rebuild(fs, target, new_glyph)
    elseif mexpru.u(target).kind == "horiz" then
        local children = mexpru.u(target).children
        table.insert(children, 1, new_glyph)
        container.root = mexpru.propagate_rebuild(fs, target, mexpru.horiz(fs, children, target_sz))
    else
        local horiz = target:get_parent()
        local children = mexpru.u(horiz).children
        table.insert(children, mexpru.index_of(children, target) + 1, new_glyph)
        container.root = mexpru.propagate_rebuild(fs, horiz, mexpru.horiz(fs, children, mexpru.u(horiz).sz))
    end
    container.cursor_pos = vc.wref_mexpr(new_glyph)
    return new_glyph
end

local function build_side(fs, sz)
    local empty = mexpru.mexpr_empty(fs, 10, 10, 5)
    mexpru.u(empty).sz = sz
    return empty, mexpru.horiz(fs, {empty}, sz)
end

-- Mirrors make_supsub() - LAZY now, only builds the requested slot.
local function make_supsub(fs, container, slot)
    local target = container.cursor_pos:get_obj()
    local base_sz = mexpru.u(target).sz
    local sub_sz = math.min(base_sz + SUB_SIZE_DELTA, MAX_SIZE_INDEX)
    local original_parent = target:get_parent()

    local new_empty, new_horiz = build_side(fs, sub_sz)
    local supsub_node
    if slot == "sup" then
        supsub_node = mexpru.supsub(fs, target, new_horiz, nil)
    else
        supsub_node = mexpru.supsub(fs, target, nil, new_horiz)
    end

    local children = mexpru.u(original_parent).children
    children[mexpru.index_of(children, target)] = supsub_node
    container.root = mexpru.propagate_rebuild(fs, original_parent,
            mexpru.horiz(fs, children, mexpru.u(original_parent).sz))
    container.cursor_pos = vc.wref_mexpr(new_empty)
    return supsub_node
end

-- Mirrors the new "fill missing side" branch of handle_input()'s Ctrl+Shift+=/- handling.
local function fill_side(fs, container, sup_wanted)
    local target = container.cursor_pos:get_obj()
    local target_sz = mexpru.u(target).sz
    local supsub_node = target:get_parent()
    local u = mexpru.u(supsub_node)

    if (sup_wanted and u.sup) or ((not sup_wanted) and u.sub) then
        return nil, "already exists"
    end

    local sub_sz = math.min(target_sz + SUB_SIZE_DELTA, MAX_SIZE_INDEX)
    local new_empty, new_horiz = build_side(fs, sub_sz)
    local rebuilt_supsub
    if sup_wanted then
        rebuilt_supsub = mexpru.supsub(fs, u.base, new_horiz, u.sub)
    else
        rebuilt_supsub = mexpru.supsub(fs, u.base, u.sup, new_horiz)
    end
    container.root = mexpru.propagate_rebuild(fs, supsub_node, rebuilt_supsub)
    container.cursor_pos = vc.wref_mexpr(new_empty)
    return new_empty
end

function run_test()
    local fs = char.load_font_set()
    local container = mformula_new.new(fs, 10)
    local gX = type_char(fs, container, "x")

    -- make_supsub("sup") only - sub must be genuinely NIL, not an empty placeholder.
    local supsub_node = make_supsub(fs, container, "sup")
    local u = mexpru.u(supsub_node)
    if u.sup == nil then
        print("FAIL: sup should have been built")
        return false
    end
    if u.sub ~= nil then
        print("FAIL: sub should be genuinely NIL (lazy), not eagerly created")
        return false
    end

    -- Type "2" into sup.
    type_char(fs, container, "2")

    -- Move cursor back to base (x - unchanged identity, still resolvable).
    container.cursor_pos = vc.wref_mexpr(gX)

    -- Requesting sup AGAIN (already exists) should report "already exists", no tree change.
    local before_len = container.root:anchor_len()
    local result, why = fill_side(fs, container, true)
    if result ~= nil or why ~= "already exists" then
        print("FAIL: requesting an already-existing sup should report 'already exists', not fill anything")
        return false
    end

    -- Requesting sub (genuinely missing) should FILL IT IN.
    local new_sub_empty = fill_side(fs, container, false)
    if new_sub_empty == nil then
        print("FAIL: requesting the missing sub should have filled it in")
        return false
    end
    local supsub2 = container.root:anchor_at(1)[1] -- root's one child, rebuilt again
    local u2 = mexpru.u(supsub2)
    if u2.sub == nil then
        print("FAIL: sub should now exist after filling it in")
        return false
    end
    if not same(u2.sub:anchor_at(1)[1], new_sub_empty) then
        print("FAIL: filled-in sub should contain the new empty atom")
        return false
    end
    if not same(container.cursor_pos:get_obj(), new_sub_empty) then
        print("FAIL: cursor should follow into the newly-filled sub")
        return false
    end
    -- sup must be UNTOUCHED (still has "2" in it, same content as before).
    if u2.sup == nil or u2.sup:anchor_at(1)[1].type ~= vc.MEXPR_TYPE_SYMBOL then
        print("FAIL: sup should be untouched (still containing '2') after filling in sub")
        return false
    end

    -- The supsub's own bounding box must have changed (sub now reserves real layout space) -
    -- confirms this really was treated as a structural edit, not a no-op.
    local bb_with_sub = vc.mexpr_get_bb(supsub2)
    -- Build a version with only sup (no sub) for comparison, same base/sup, sub=nil.
    local supsub_sup_only = mexpru.supsub(fs, u2.base, u2.sup, nil)
    local bb_sup_only = vc.mexpr_get_bb(supsub_sup_only)
    if math.abs(bb_with_sub.br.y - bb_sup_only.br.y) < 0.01 then
        print("FAIL: adding sub should have changed the supsub's own bounding box (extra layout space)")
        return false
    end

    print("PASS: lazy sup/sub creation and fill-in-missing-side both check out")
    return true
end

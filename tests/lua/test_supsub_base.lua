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
    local target_parent = target:get_parent()
    local target_is_horiz = mexpru.u(target).kind == "horiz"
    local target_is_empty = target.type == vc.MEXPR_TYPE_EMPTY_BOX
    local target_is_supsub_base = target_parent ~= nil and mexpru.u(target_parent).kind == "supsub"
            and same(mexpru.u(target_parent).base, target)
    local target_sz = mexpru.u(target).sz

    local entry = char.find_by_ascii(ascii)
    local new_glyph = mexpru.mexpr_symbol(fs, {size = target_sz, code = entry.ncod}, true)
    mexpru.u(new_glyph).sz = target_sz

    if target_is_empty then
        container.root = mexpru.propagate_rebuild(fs, target, new_glyph)
    elseif target_is_horiz then
        local children = mexpru.u(target).children
        table.insert(children, 1, new_glyph)
        container.root = mexpru.propagate_rebuild(fs, target, mexpru.horiz(fs, children, target_sz))
    elseif target_is_supsub_base then
        local supsub_node = target_parent
        local outer_horiz = supsub_node:get_parent()
        local outer_children = mexpru.u(outer_horiz).children
        local u = mexpru.u(supsub_node)
        local rebuilt_supsub = mexpru.supsub(fs, new_glyph, u.sup, u.sub)
        local idx = mexpru.index_of(outer_children, supsub_node)
        outer_children[idx] = rebuilt_supsub
        table.insert(outer_children, idx, target)
        container.root = mexpru.propagate_rebuild(fs, outer_horiz,
                mexpru.horiz(fs, outer_children, mexpru.u(outer_horiz).sz))
    else
        local horiz = target_parent
        local children = mexpru.u(horiz).children
        table.insert(children, mexpru.index_of(children, target) + 1, new_glyph)
        container.root = mexpru.propagate_rebuild(fs, horiz, mexpru.horiz(fs, children, mexpru.u(horiz).sz))
    end

    container.cursor_pos = vc.wref_mexpr(new_glyph)
    return new_glyph
end

local function make_supsub(fs, container, slot)
    local target = container.cursor_pos:get_obj()
    local base_sz = mexpru.u(target).sz
    local sub_sz = math.min(base_sz + SUB_SIZE_DELTA, MAX_SIZE_INDEX)
    local original_parent = target:get_parent()

    local sup_empty = mexpru.mexpr_empty(fs, 10, 10, 5)
    mexpru.u(sup_empty).sz = sub_sz
    local sub_empty = mexpru.mexpr_empty(fs, 10, 10, 5)
    mexpru.u(sub_empty).sz = sub_sz
    local supsub_node = mexpru.supsub(fs, target,
            mexpru.horiz(fs, {sup_empty}, sub_sz), mexpru.horiz(fs, {sub_empty}, sub_sz))

    local children = mexpru.u(original_parent).children
    children[mexpru.index_of(children, target)] = supsub_node
    container.root = mexpru.propagate_rebuild(fs, original_parent,
            mexpru.horiz(fs, children, mexpru.u(original_parent).sz))
    container.cursor_pos = vc.wref_mexpr(slot == "sup" and sup_empty or sub_empty)
    return supsub_node
end

-- Mirrors handle_input()'s own backspace-on-base branch exactly.
local function backspace_base(fs, container)
    local target = container.cursor_pos:get_obj()
    local target_sz = mexpru.u(target).sz
    local supsub_node = target:get_parent()
    local outer_horiz = supsub_node:get_parent()
    local outer_children = mexpru.u(outer_horiz).children
    local supsub_idx = mexpru.index_of(outer_children, supsub_node)

    local new_base
    if supsub_idx > 1 then
        new_base = outer_children[supsub_idx - 1]
        table.remove(outer_children, supsub_idx - 1)
    else
        new_base = mexpru.mexpr_empty(fs, 10, 10, 5)
        mexpru.u(new_base).sz = target_sz
    end

    local u = mexpru.u(supsub_node)
    local rebuilt_supsub = mexpru.supsub(fs, new_base, u.sup, u.sub)
    outer_children[mexpru.index_of(outer_children, supsub_node)] = rebuilt_supsub
    container.root = mexpru.propagate_rebuild(fs, outer_horiz,
            mexpru.horiz(fs, outer_children, mexpru.u(outer_horiz).sz))
    container.cursor_pos = vc.wref_mexpr(new_base)
end

function run_test()
    local fs = char.load_font_set()

    local container = mformula_new.new(fs, 10)
    local gX = type_char(fs, container, "x") -- root = [x]

    -- make_supsub("sup") on x: base should be x DIRECTLY (not wrapped in a horiz).
    local supsub_node = make_supsub(fs, container, "sup")
    local base = mexpru.u(supsub_node).base
    if not same(base, gX) then
        print("FAIL: base should be x itself, unwrapped")
        return false
    end
    if mexpru.u(base).kind == "horiz" then
        print("FAIL: base should NOT be a horiz")
        return false
    end
    if container.root:anchor_len() ~= 1 then
        print("FAIL: root should have exactly 1 child (the supsub), got " .. container.root:anchor_len())
        return false
    end

    -- Type "2" into sup.
    local g2 = type_char(fs, container, "2")

    -- Move cursor onto base (x) directly and verify detection would fire.
    container.cursor_pos = vc.wref_mexpr(gX)
    local target_parent = gX:get_parent()
    local is_base = target_parent ~= nil and mexpru.u(target_parent).kind == "supsub"
            and same(mexpru.u(target_parent).base, gX)
    if not is_base then
        print("FAIL: cursor on x should be detected as a supsub's own base")
        return false
    end

    -- Type "y" while on base x: y becomes the new base, x gets bumped into root BEFORE the supsub.
    local gY = type_char(fs, container, "y")
    if container.root:anchor_len() ~= 2 then
        print("FAIL: after typing y on base, root should have 2 children (x, supsub'), got "
                .. container.root:anchor_len())
        return false
    end
    if not same(container.root:anchor_at(1)[1], gX) then
        print("FAIL: bumped x should sit BEFORE the supsub in root's children")
        return false
    end
    local new_supsub = container.root:anchor_at(2)[1]
    if not same(mexpru.u(new_supsub).base, gY) then
        print("FAIL: supsub's base should now be y")
        return false
    end
    if not same(mexpru.u(new_supsub).sup:anchor_at(1)[1], g2) then
        print("FAIL: sup should still contain 2, untouched by the base edit")
        return false
    end
    if not same(container.cursor_pos:get_obj(), gY) then
        print("FAIL: cursor should follow the new base y")
        return false
    end

    -- Backspace on base y: pulls x back in (reverse of the type above) - root shrinks back to
    -- just [supsub''] with base=x, cursor -> x.
    backspace_base(fs, container)
    if container.root:anchor_len() ~= 1 then
        print("FAIL: after backspacing base y, root should shrink back to 1 child, got "
                .. container.root:anchor_len())
        return false
    end
    local supsub3 = container.root:anchor_at(1)[1]
    if not same(mexpru.u(supsub3).base, gX) then
        print("FAIL: backspacing base y should pull x back in as the new base")
        return false
    end
    if not same(container.cursor_pos:get_obj(), gX) then
        print("FAIL: cursor should follow x back onto base")
        return false
    end

    -- Backspace on base x AGAIN: nothing precedes the supsub in root now (it's the only child) -
    -- falls back to a fresh empty atom, root STILL has exactly 1 child.
    backspace_base(fs, container)
    if container.root:anchor_len() ~= 1 then
        print("FAIL: after backspacing base x (nothing to pull in), root should still have 1 child")
        return false
    end
    local supsub4 = container.root:anchor_at(1)[1]
    local fallback_base = mexpru.u(supsub4).base
    if fallback_base.type ~= vc.MEXPR_TYPE_EMPTY_BOX then
        print("FAIL: fallback base (nothing to pull in) should be a fresh EMPTY_BOX")
        return false
    end
    if not same(container.cursor_pos:get_obj(), fallback_base) then
        print("FAIL: cursor should follow the fallback empty base")
        return false
    end

    print("PASS: supsub base simplification (atomic, no horiz) and its type/backspace rules all check out")
    return true
end

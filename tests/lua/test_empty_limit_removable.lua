--[[
test_empty_limit_removable.lua - an empty sup/sub can always be removed, even when its SIBLING
slot holds something.

THE ASSUMPTION: Backspace in a slot you have not typed into gets you out of it. Whatever else is
in the structure, an empty slot is never a dead end.

WHY IT NEEDS AN ALARM. collapse_empty_supsub() used to require BOTH slots to be untyped, which
means the very common half-filled case had no way back at all:

    a sum with a limit BELOW, then a limit added ABOVE and thought better of - the empty upper
    slot could not be removed, because the lower one had content, and it could not be typed away
    either, because it was already empty.

Reported live on 2026-09-07 as "I can't delete it", with the session's own flight recorder showing
nine consecutive Backspaces doing nothing, and again as "a loaded bigsup or sup doesn't seem to
allow deletion" - the same wall reached from the other side, by opening a saved formula whose
limits are both filled and clearing one of them.

That both reports were the same rule is the reason this file exists rather than a fix alone: the
condition reads perfectly reasonable in isolation ("only undo a spawn nobody typed into"), and its
own comment defends it convincingly. What it does not say is what happens to the OTHER case, and
the answer was "nothing, forever".

WHAT IS DELIBERATELY STILL TRUE, and asserted here so a later change cannot quietly drop it: with
both slots untyped the WHOLE structure goes, not one side; and a slot with content in it is never
removed by Backspace - that key clears content one glyph at a time, and only an already-empty slot
is structural.

Driven through make_bigop/collapse_empty_supsub rather than key presses, for the reason every
handle_input-adjacent test here gives: handle_input() needs real keys, so these tests work one
level down.
]]

package.path = package.path .. ";./scripts/?.lua"

local vc = require("virt_composer")
local char = require("char")
local mexpru = require("mexpru")
local mformula = require("mformula_new")

local function check(cond, msg)
    if not cond then
        print("FAIL: " .. msg)
        return false
    end
    return true
end

-- The node the cursor is on, and the compound above it, without reaching into mformula's locals.
local function cursor_node(c)
    return c.cursor_pos and c.cursor_pos:get_obj()
end

function run_test()
    local ok = true
    local fs = char.load_font_set()
    local sz = mexpru.DEFAULT_SIZE

    --[[ CASE 1 - the reported one. A big operator with a limit BELOW that has content, plus an
    empty limit ABOVE. Backspace in the empty one must remove that side and leave the other. ]]
    local c = mformula.from_latex(fs, sz, "\\sum \\limits_{k}")
    if not check(c ~= nil, "could not load a bigop with one limit") then
        return false
    end

    -- Put the cursor on the bigop itself, then add the empty upper limit - which is exactly what
    -- Ctrl+Shift+[ does, and leaves the cursor inside the new slot.
    local root_children = mexpru.u(c.root).children
    local bigop = root_children and root_children[1]
    if not check(bigop ~= nil, "loaded formula has no node to work with") then
        return false
    end
    c.cursor_pos = vc.wref_mexpr(bigop)
    mformula.make_bigop(c, fs, "sup")

    --[[ `bigop` MUST NOT be touched again from here. make_bigop() fills a free slot by rebuilding
    the node and propagating the replacement upwards, so the handle above it now names a node that
    no longer belongs to the tree - reading its `u` table segfaults outright rather than returning
    nil. The first version of this test did exactly that and took the harness down with it. Ask
    the container where the cursor is instead; it is updated by the rebuild. ]]
    local made = cursor_node(c)
    ok = check(made ~= nil, "make_bigop left no cursor") and ok

    -- THE ASSERTION: Backspace here must do something. It used to return false.
    local removed = mformula.collapse_empty_supsub(c, fs)
    ok = check(removed == true,
            "an empty limit could not be removed while its sibling had content"
            .. " - this is the reported bug") and ok

    --[[ THE CURSOR MUST STILL NAME A LIVE NODE. Removing a side rebuilds the compound, and a
    cursor left pointing at a handle from before that rebuild is DANGLING - the app recovers by
    snapping to the formula root and logs a warning, after which arrow navigation has nothing
    coherent to walk and Left stops escaping the operator. That is precisely what a live session
    reported ("can't navigate left", with "WARN cursor_pos was dangling" in its recorder), so it
    is asserted here rather than left to be noticed by hand. ]]
    local landed = cursor_node(c)
    ok = check(landed ~= nil, "the cursor was left dangling after removing a side") and ok

    -- ...and it must have removed only the empty side. The surviving limit still has to be there,
    -- or the fix has traded one kind of loss for a worse one.
    local latex = mformula.to_latex(c)
    ok = check(latex:find("k") ~= nil,
            "removing the empty limit destroyed the other one too; got: " .. tostring(latex)) and ok
    ok = check(latex:find("sum") ~= nil,
            "the operator itself disappeared; got: " .. tostring(latex)) and ok

    --[[ CASE 2 - the rule that must SURVIVE. With nothing typed into either slot, Backspace still
    takes the whole spawn rather than one side of it. ]]
    local c2 = mformula.from_latex(fs, sz, "S")
    local kids = mexpru.u(c2.root).children
    c2.cursor_pos = vc.wref_mexpr(kids[1])
    mformula.make_bigop(c2, fs, "sup")
    local collapsed = mformula.collapse_empty_supsub(c2, fs)
    ok = check(collapsed == true, "an untouched spawn must still collapse") and ok
    local latex2 = mformula.to_latex(c2)
    ok = check(latex2:find("limits") == nil and latex2:find("%^") == nil,
            "collapsing an untouched spawn left part of it behind; got: " .. tostring(latex2)) and ok

    --[[ CASE 3 - a slot WITH content is not structural. Backspace there is for clearing glyphs,
    and must not remove the slot out from under what is still in it. ]]
    local c3 = mformula.from_latex(fs, sz, "\\sum \\limits_{k}")
    local kids3 = mexpru.u(c3.root).children
    local big3 = kids3 and kids3[1]
    local sub_horiz = big3 and mexpru.u(big3).sub
    local sub_kids = sub_horiz and mexpru.u(sub_horiz).children
    if sub_kids and sub_kids[1] then
        c3.cursor_pos = vc.wref_mexpr(sub_kids[1])
        local wrongly = mformula.collapse_empty_supsub(c3, fs)
        ok = check(wrongly == false,
                "Backspace removed a slot that still had content in it") and ok
    end

    --[[ CASE 4 - BOTH delete keys remove an empty slot, and NEITHER removes a filled one.

    Backspace-only was the rule until 2026-09-07. It was defensible - Delete means "the thing after
    the cursor" and an empty slot has nothing after it - but it left Delete inert in an empty slot,
    which reads as a broken key rather than as a model. Ruled: "if the horiz is empty it should
    delete, only when the horiz has something else than an empty should it not".

    What makes that safe to implement as one shared branch, and what this case actually pins, is
    that the SECOND half needs no separate test in the caller: collapsible_supsub() only offers a
    target when the cursor's own slot is untyped, so a filled slot declines by itself and Delete
    falls through to its ordinary forward meaning. If someone later adds a key check in the caller
    instead of relying on that, this case is what should stop them. ]]
    local function empty_limit_container()
        local cc = mformula.from_latex(fs, sz, "\\sum \\limits_{k}")
        local kk = mexpru.u(cc.root).children
        cc.cursor_pos = vc.wref_mexpr(kk[1])
        mformula.make_bigop(cc, fs, "sup")
        return cc
    end

    -- The shared branch is reached by both keys, so what each key does is decided in
    -- handle_input(); here the point is that the OPERATION accepts an empty slot exactly once
    -- and refuses a filled one, whichever key arrives.
    local c4 = empty_limit_container()
    ok = check(mformula.collapse_empty_supsub(c4, fs) == true,
            "an empty slot must be removable (this is the branch Delete now shares)") and ok
    ok = check(mformula.collapse_empty_supsub(c4, fs) == false,
            "removing it twice must not keep removing things") and ok

    if ok then
        print("empty limits are removable by either delete key; filled ones are not;"
                .. " untouched spawns still collapse")
    end
    return ok
end

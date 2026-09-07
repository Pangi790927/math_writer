--[[
test_bigop_exit_left.lua - Left always gets you OUT of a big operator's limit.

THE ASSUMPTION: every cursor position is escapable. Whatever you have walked into, Left keeps
walking and eventually leaves it. Nothing in the editor is a place you can only get out of with
the mouse.

WHY IT NEEDS AN ALARM, and what it cost. exit_horiz_leftward() branched on the kind of the thing a
horiz sits inside, and knew about supsub, frac and vert - but not bigop. A big operator's limit is
a horiz whose parent is a bigop, so it matched no branch, the function returned having done
nothing, and the cursor stayed exactly where it was. Not a wrong landing - no landing at all,
permanently.

Reported 2026-09-07 as losing "the ability to exit the integral area to the left". The session's
own flight recorder recorded the shape of it better than any description: thirty-one consecutive
LeftArrow presses, and the document unchanged either side of them.

The omission was invisible for a long time because it needs a bigop with a limit you have typed
into AND then walked left from, and because the function's own comment asserted the premise that
made it look complete - "horiz's parent is EITHER a supsub or a frac (the only two things a horiz
can ever sit inside)". That statement was already false when it was written (vert had been added)
and the code was written to match the comment rather than the model.

THE FORMULA BELOW IS THE USER'S OWN, copied verbatim out of the math_writer.save left behind by the
session that reported it. It is kept as-is rather than reduced to a minimal case on purpose: a
reduced case would prove the branch works, while this one also proves the whole walk out of a real
formula - through the integral, its neighbours, a supsub and a second big operator - never stalls.

WHAT MUST STAY TRUE: stopping at the ROOT is correct and is not a failure. There is nothing to the
left of the leftmost position, so the walk below asserts that the cursor reaches the root, not that
it moves forever.
]]

package.path = package.path .. ";./scripts/?.lua"

local vc = require("virt_composer")
local char = require("char")
local mexpru = require("mexpru")
local mformula = require("mformula_new")

-- Verbatim from the reporting session's saved document.
local FORMULA = "\\vec{F}\\ =\\ \\sum \\limits^{N}_{k=1}\\vec{F}_{k}\\ \\int \\limits_{a}^{b}"

function run_test()
    local ok = true
    local fs = char.load_font_set()

    local c = mformula.from_latex(fs, mexpru.DEFAULT_SIZE, FORMULA)
    if not c then
        print("FAIL: the reported formula no longer loads at all")
        return false
    end

    -- Find the integral and put the cursor in its UPPER limit, on the "b" - where the report left
    -- off, having just typed it.
    local kids = mexpru.u(c.root).children
    local integral
    for i = #kids, 1, -1 do
        if mexpru.u(kids[i]).kind == "bigop" then
            integral = kids[i]
            break
        end
    end
    if not integral then
        print("FAIL: no big operator in the loaded formula - the fixture stopped being the fixture")
        return false
    end
    local sup = mexpru.u(integral).sup
    local sup_kids = sup and mexpru.u(sup).children
    if not (sup_kids and sup_kids[#sup_kids]) then
        print("FAIL: the integral loaded without its upper limit")
        return false
    end
    c.cursor_pos = vc.wref_mexpr(sup_kids[#sup_kids])

    --[[ Walk left and watch for a STALL: the same node twice running means the cursor stopped
    responding. Two identical positions is enough to say so - Left either moves or it does not,
    and there is no position in this model that legitimately needs two presses to leave. ]]
    local escaped_limit, reached_root = false, false
    local prev = c.cursor_pos:get_obj()
    for step = 1, 20 do
        mformula.move_left(c)
        local now = c.cursor_pos:get_obj()

        if mexpru.same(now, c.root) then
            reached_root = true
            break
        end
        if mexpru.same(now, prev) then
            print("FAIL: Left stopped moving at step " .. step
                    .. " - the cursor is stuck, which is the reported bug")
            return false
        end
        -- Out of the limit means the cursor is no longer anywhere inside the sup subtree.
        if not escaped_limit then
            local walk, inside = now, false
            while walk do
                if mexpru.same(walk, sup) then inside = true break end
                walk = walk:get_parent()
            end
            escaped_limit = not inside
        end
        prev = now
    end

    if not escaped_limit then
        print("FAIL: never left the integral's limit")
        ok = false
    end
    if not reached_root then
        print("FAIL: walking left never reached the row itself")
        ok = false
    end

    if ok then
        print("Left walks out of a big operator's limit and on to the start of the formula")
    end
    return ok
end

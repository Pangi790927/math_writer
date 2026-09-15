--[[
test_derive_trust.lua - a derivation requires a trusted source, and the child is born trusted.

THE ASSUMPTION: ctrl+d (the identity derivation) is a transform like any other, and the lock is
a trust bit - so deriving from an UNLOCKED box would propagate trust the source does not have.
Reported live, 2026-09-15: "ctrl+d, a transform, allowed me to apply it on an unlocked formula,
trust propagation would break". The check lives inside content.derive_identity, not at the
keybinding, so every caller inherits it.

@date 2026-09-15 14:00
]]

package.path = package.path .. ";./scripts/?.lua"

local content = require("content")
local editor_formula = require("editor_formula")
local char = require("char")

local checks_run, checks_failed = 0, 0
local function check(name, cond, got)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name .. (got ~= nil and ("  (got: " .. tostring(got) .. ")") or ""))
    end
end

function run_test()
    local fontset = char.load_font_set()
    local state = content.new()
    content.insert_box(state, 2, "formula")
    local fml = state.boxes[2].fml
    fml.id = 2
    fml.latex = "a(b+c)"

    --[[ THE GATE: an unlocked box - even one with content - refuses the derivation. Nothing is
    inserted, so the box count is the assertion. ]]
    check("ctrl+d on an UNLOCKED formula is refused",
            content.derive_identity(state, 2) == nil and #state.boxes == 2, #state.boxes)

    -- Locked, it derives: same latex, the parent recorded, and the child BORN LOCKED - it is a
    -- step in a derivation, not a draft, exactly like a transform's child.
    fml.locked = true
    local made = content.derive_identity(state, 2)
    check("ctrl+d on a LOCKED formula derives", made == 3, made)
    local child = state.boxes[3].fml
    check("...with the same content", child.latex == "a(b+c)", child.latex)
    check("...linked to its source", child.parent == 2, child.parent)
    check("...and born locked, like a transform's child", child.locked == true, child.locked)

    --[[ OPENING A MID-CHAIN LOCK, the author's dance (2026-09-15): a trusted copy takes the
    original's chain position (parent UPWARD), the original drops its links and sits directly
    below the copy for writing. Its descendants follow its OLD content, which the copy now holds,
    so they go. ]]
    local grand = content.derive_identity(state, 3)
    check("setup: the chain has a grandchild", grand == 4, grand)
    local back = content.unlock_mid_chain(state, 3)
    local copy = state.boxes[3].fml
    check("the copy holds the original's chain position",
            copy.parent == 2 and copy.locked == true and copy.latex == "a(b+c)", copy.parent)
    check("...and the original answers at its new index", back == 4, back)
    check("the original is free: no parent, no lock",
            child.parent == nil and child.locked == nil, child.parent)
    check("the grandchild followed the original's old content and went",
            #state.boxes == 4, #state.boxes)

    -- A root unlock is the plain toggle: no copy, nothing inserted.
    editor_formula.lock(child, fontset, {})
    check("unlocking a root makes it a root again (no parent to drop)",
            child.parent == nil and #state.boxes == 4, #state.boxes)

    if checks_failed == 0 then
        print("PASS: derivation requires trust (" .. checks_run .. " checks)")
    end
    return checks_failed == 0
end

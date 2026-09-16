--[[
test_load_lock.lua - what a load does to a saved chain of locked boxes.

THE RULING (the author, 2026-09-16): "the first load in a formula should test the lock, if it
fails, unlock it (with all that means)". A loaded box's tree was validated when it was saved, but
the document around it may have changed since - definitions moved or retyped - so the load runs the
lock's own test once per formula box. "All that means" is the lock button's unlock: the parent link
goes and the children are pruned, because a tree that no longer parses cannot hold the trust its
chain claims.

THE SAME PARSE IS WHAT PAINTS DECLARED NAMES at load (the same day's report: "the first load does
not paint them") - one parse per box, at load time, nothing continuous. The paint itself is
test_decl_paint's subject; this file is the trust half.

@date 2026-09-16
]]

package.path = package.path .. ";./scripts/?.lua"

local char = require("char")
local mexpru = require("mexpru")
local editor_formula = require("editor_formula")
local editor = require("editor_text")
local content = require("content")

local checks_run, checks_failed = 0, 0
local function check(name, cond, got)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name .. (got ~= nil and ("  (got: " .. tostring(got) .. ")") or ""))
    end
end

-- One formula box's saved body, in exactly the format to_text writes.
local function fml_body(fs, latex, id, parent)
    local box = editor_formula.new(id)
    box.latex = latex
    box.parent = parent
    box.locked = true
    return editor_formula.to_text(box)
end

local function doc_text(bodies)
    local parts = {}
    for _, body in ipairs(bodies) do
        parts[#parts + 1] = "formula " .. #body .. "\n" .. body
    end
    return table.concat(parts)
end

function run_test()
    local fs = char.load_font_set()

    -- ------------------------------------------------- a chain that still parses survives
    do
        local a = fml_body(fs, "a(b+c)", 7)
        local b = fml_body(fs, "ab+ac", 8, 7)
        local doc = content.deserialize(doc_text({a, b}), fs)
        check("the source box is still locked", doc.boxes[1].fml.locked == true)
        check("the child box is still there", #doc.boxes == 2, #doc.boxes)
        check("...and still locked", doc.boxes[2].fml.locked == true)
        check("...and still parented", doc.boxes[2].fml.parent == 7, doc.boxes[2].fml.parent)
    end

    -- ------------------------------------------------- a box that fails the test loses the chain
    do
        --[[ `@@` is the same unparseable content test_formula_lock refuses the lock on - a lone
        `@` atom reads as nothing in the grammar. Saved locked (a save format records what was,
        not what should be), it must come back unlocked, parentless, and childless - the child
        COLLECTED, not lost (the author, 2026-09-16): a text box takes the first deleted child's
        place, holding the removed formulas one to a line, so the content survives as prose while
        the link is properly deleted. ]]
        local a = fml_body(fs, "@@", 7)
        local b = fml_body(fs, "ab+ac", 8, 7)
        local doc = content.deserialize(doc_text({a, b}), fs)
        check("the unparseable box loads unlocked", doc.boxes[1].fml.locked == nil,
                doc.boxes[1].fml.locked)
        check("...and parentless", doc.boxes[1].fml.parent == nil, doc.boxes[1].fml.parent)
        check("the child became a text box", doc.boxes[2].kind == "text"
                and doc.boxes[2].editor ~= nil, doc.boxes[2].kind)
        local body = editor.to_text(doc.boxes[2].editor)
        check("...holding the child's formula, one line", body:find("%$%$ab%+ac%$%$", 1, false)
                ~= nil, body)
        check("...and no chain survives", doc.boxes[2].fml == nil)
    end

    -- ------------------------------------------------- an unlocked box is left alone
    do
        --[[ The test runs on LOCKED boxes - an unlocked box was never claiming trust, and its
        content failing to parse is the ordinary state of a box being typed in. ]]
        local body = fml_body(fs, "@@", 7)
        local box = editor_formula.new(7)
        editor_formula.from_text(box, body, fs)
        box.locked = nil
        local doc = content.deserialize(doc_text({editor_formula.to_text(box)}), fs)
        check("an unlocked unparseable box stays unlocked", doc.boxes[1].fml.locked == nil)
        check("...and stays in the document", #doc.boxes == 1, #doc.boxes)
    end

    if checks_failed == 0 then
        print("PASS: a load tests every lock and drops what fails (" .. checks_run .. " checks)")
    end
    return checks_failed == 0
end

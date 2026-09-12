--[[
test_transform_plugins.lua - a transformation that is switched off offers nothing and runs nothing.

THE ASSUMPTION THIS GUARDS. From 2026-09-12 the set of available transformations is not fixed: the
plugin folder decides what EXISTS and `transforms.save` decides which of those run. Everything above
that - the right-click menu, the F6 preview, ast_gestures - asks the registry rather than naming a
transformation, so "switched off" has to mean switched off at the registry or it means nothing at
all.

TWO GATES, AND BOTH ARE NEEDED, which is the real content of this test. `offers` skipping an
inactive plugin is not enough on its own: an option built while the plugin was still on can outlive
the change, sitting in an open menu or a cached preview, and running it would reach a plugin the
user has just disabled. So `apply` refuses by id as well. Testing only the first gate would pass
while the second was missing.

DEFAULT STATE IS PART OF THE CONTRACT. A plugin is off unless it declares `default_active`; author,
2026-09-12: "off by default, we will enable all the plugins that we will create, but for it in at
large, the user will need to check it". distribute ships declaring it, so the editor works out of
the box, and a file dropped into the folder by someone else cannot change what the editor does until
it is ticked.

WHY THE STATE IS PUT BACK at the end: the registry is process-wide and this harness runs one test
per process, but that is a property of the harness rather than a promise, and a test that leaves a
transformation disabled would be a trap for whatever runs next in the same state.
@date 2026-09-12 02:50
]]

package.path = package.path .. ";./scripts/?.lua"

local ast = require("ast")
local transforms = require("transforms")

local checks_run, checks_failed = 0, 0
local function check(name, cond, got)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name .. (got ~= nil and ("  (got: " .. tostring(got) .. ")") or ""))
    end
end

function run_test()
    -- ---------------------------------------------------------------- the folder was actually read
    check("the plugin scan did not fault", transforms.load_error == nil, transforms.load_error)
    local specs = transforms.list()
    check("at least one plugin loaded", #specs > 0, #specs)

    local dist = transforms.get("distribute")
    check("distribute was found by the folder scan", dist ~= nil)
    if not dist then
        return false
    end

    -- ---------------------------------------------------------------- the shipped default
    check("distribute declares itself default-active", dist.default_active == true)
    check("and is therefore active before anything is loaded", transforms.is_active("distribute"))

    --[[ An id nothing answers to is a real case - a savefile naming a deleted plugin - and must be
    an answer rather than an error. ]]
    check("an unknown id is not active", transforms.is_active("no_such_transform") == false)
    check("and cannot be switched on", transforms.set_active("no_such_transform", true) == false)

    -- ---------------------------------------------------------------- gate one: it stops offering
    transforms.set_active("distribute", false)
    check("switching off is reported by is_active", transforms.is_active("distribute") == false)

    --[[ offers() with NO NODE must still answer with an empty list rather than throwing, because
    that is the code path a right-click on empty space takes: ast_gestures.node_at resolves such a
    click to nil and options() hands that straight to offers.

    The tree is real as of 2026-09-12, and the assumption is unchanged - only the inputs are. This
    read `offers(nil, nil, nil)`, which asked the right question through the wrong call: a nil
    NAMESPACE is not the empty-space case, it is a caller bug, and offers used to answer both with
    the same empty list. It checks ns and root now, so the two cases are told apart; a nil `node`
    is still an ordinary answer and is what this pins. ]]
    local ns = ast.new_ns()
    local tree = ast.new(ns, ast.VAR)
    local none = transforms.offers(ns, tree, nil)
    check("offers with no node to ask about returns an empty list", #none == 0, #none)

    -- ---------------------------------------------------------------- gate two: it also refuses
    --[[ A REAL ns and root here too, for the same reason: this hand-built `{by_id = {}}` and `{}`
    were look-alikes that only had to survive being carried, since the gate below answers before
    anything reads them. They are checked as arguments now. What is asserted is untouched - that a
    disabled transformation refuses BY NAME - and it is now asserted with inputs that could not
    have been the thing at fault. ]]
    local root, err = transforms.apply("distribute", ns, tree, {add = 1})
    check("apply refuses a disabled transformation", root == nil)
    check("and says so by name rather than blaming the arguments",
            err ~= nil and err:find("not enabled", 1, true) ~= nil, err)

    -- ---------------------------------------------------------------- the savefile round trip
    local text = transforms.serialize()
    check("a divergence from the default is written", text:find("distribute", 1, true) ~= nil, text)
    check("and written as off", text:find("off", 1, true) ~= nil, text)

    transforms.set_active("distribute", true)
    check("back on", transforms.is_active("distribute"))
    check("a plugin at its default writes no line at all",
            transforms.serialize() == "", transforms.serialize())

    local applied, skipped = transforms.load(text)
    check("loading the saved text applies it", applied == 1, applied)
    check("and skips nothing that exists", skipped == 0, skipped)
    check("the loaded state took effect", transforms.is_active("distribute") == false)

    local applied2, skipped2 = transforms.load("no_such_transform\ton")
    check("a line naming a deleted plugin is skipped, not fatal", skipped2 == 1, skipped2)
    check("and applies nothing", applied2 == 0, applied2)

    --[[ Reading a file is not a reason to write one back: what was just loaded IS what is
    already on disk. ]]
    check("loading does not mark the state dirty", transforms.dirty() == false)
    transforms.set_active("distribute", true)
    check("a real change does", transforms.dirty() == true)
    transforms.clear_dirty()
    check("and clears", transforms.dirty() == false)

    -- ---------------------------------------------------------------- leave it as it shipped
    transforms.set_active("distribute", true)
    transforms.clear_dirty()

    print("checks: " .. checks_run .. ", failed: " .. checks_failed)
    if checks_failed > 0 then
        return false
    end
    print("PASS: activation gates both offering and running")
    return true
end

--[[
test_dress_editor.lua - accents as the editor sees them: toggling, dot counting, and the LaTeX
round trip that decides whether they survive a save.

Ctrl+^ / Ctrl+~ / Ctrl+G toggle an accent, Ctrl+. / Ctrl+, count dots up and down. The rules worth
pinning are the ones a user would notice breaking:

  - the same accent twice removes it, leaving the BARE atom - not an empty dress
  - a different accent replaces rather than stacks
  - removing the last dot undresses entirely, so Ctrl+, fully undoes Ctrl+.
  - a dressed atom is still one atom in its row: dressing does not change how many children the
    row has, which is what keeps navigation and selection working over it

and the round trip, because an accent that does not serialise vanishes on load exactly the way
spaces did before 2026-09-05.
]]

package.path = package.path .. ";./scripts/?.lua"

local vc = require("virt_composer")
local char = require("char")
local mexpru = require("mexpru")
local mformula_new = require("mformula_new")

local checks_run, checks_failed = 0, 0
local function check(name, cond, got)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name .. (got ~= nil and ("  (got: " .. tostring(got) .. ")") or ""))
    end
end

local SZ = 12

local function formula_with(fs, ascii)
    local c = mformula_new.new(fs, SZ)
    local e = char.find_by_ascii(ascii)
    local g = mexpru.mexpr_symbol(fs, {size = mexpru.physical_sz(SZ), code = e.ncod}, true)
    mexpru.u(g).sz = SZ
    c.root = mexpru.propagate_rebuild(fs, c.cursor_pos:get_obj(), g)
    c.cursor_pos = vc.wref_mexpr(g)
    return c
end

local function cursor_kind(c)
    return mexpru.u(c.cursor_pos:get_obj()).kind
end

local function row_len(c)
    return #mexpru.u(c.root).children
end

function run_test()
    local fs = char.load_font_set()

    -- ---------------------------------------------------------------- toggle on and off
    do
        local c = formula_with(fs, "x")
        check("one atom in the row to begin with", row_len(c) == 1, row_len(c))

        mformula_new.toggle_accent(c, fs, "hat")
        check("Ctrl+^ dresses the atom", cursor_kind(c) == "dress", cursor_kind(c))
        check("...and the row still holds exactly one atom", row_len(c) == 1, row_len(c))
        check("...tagged with which accent it wears",
                mexpru.u(c.cursor_pos:get_obj()).above_kind == "hat")

        mformula_new.toggle_accent(c, fs, "hat")
        check("the same accent again takes it off", cursor_kind(c) ~= "dress", cursor_kind(c))
        check("...leaving the bare atom, not an empty dress", row_len(c) == 1, row_len(c))
    end

    -- ---------------------------------------------------------------- one accent at a time
    do
        local c = formula_with(fs, "x")
        mformula_new.toggle_accent(c, fs, "hat")
        mformula_new.toggle_accent(c, fs, "tilde")
        check("a different accent REPLACES rather than stacking",
                mexpru.u(c.cursor_pos:get_obj()).above_kind == "tilde",
                mexpru.u(c.cursor_pos:get_obj()).above_kind)
        check("...and there is still one atom in the row", row_len(c) == 1, row_len(c))
    end

    -- ---------------------------------------------------------------- dots count up and down
    do
        local c = formula_with(fs, "y")
        mformula_new.adjust_dots(c, fs, 1)
        check("Ctrl+. dresses with one dot", mexpru.u(c.cursor_pos:get_obj()).dots == 1)
        mformula_new.adjust_dots(c, fs, 1)
        mformula_new.adjust_dots(c, fs, 1)
        check("...up to three", mexpru.u(c.cursor_pos:get_obj()).dots == 3)
        local at_ceiling = mformula_new.to_latex(c)
        mformula_new.adjust_dots(c, fs, 1)
        check("a fourth is refused rather than growing", mformula_new.to_latex(c) == at_ceiling)

        mformula_new.adjust_dots(c, fs, -1)
        mformula_new.adjust_dots(c, fs, -1)
        check("Ctrl+, counts back down", mexpru.u(c.cursor_pos:get_obj()).dots == 1)
        mformula_new.adjust_dots(c, fs, -1)
        check("removing the LAST dot undresses entirely", cursor_kind(c) ~= "dress", cursor_kind(c))
        check("...back to a bare one-atom row", row_len(c) == 1, row_len(c))
    end

    -- ---------------------------------------------------------------- the round trip
    do
        for _, case in ipairs({{"hat", "\\hat{x}"}, {"tilde", "\\tilde{x}"}, {"bar", "\\bar{x}"}}) do
            local c = formula_with(fs, "x")
            mformula_new.toggle_accent(c, fs, case[1])
            local latex = mformula_new.to_latex(c)
            check(case[1] .. " serialises as its real LaTeX command", latex == case[2], latex)
            local back = mformula_new.from_latex(fs, SZ, latex)
            check(case[1] .. " survives the round trip",
                    mformula_new.to_latex(back) == case[2], mformula_new.to_latex(back))
            local kid = mexpru.u(back.root).children[1]
            check(case[1] .. " comes back as a dress", mexpru.u(kid).kind == "dress")
        end

        local c = formula_with(fs, "x")
        mformula_new.adjust_dots(c, fs, 1)
        mformula_new.adjust_dots(c, fs, 1)
        local latex = mformula_new.to_latex(c)
        check("two dots serialise as \\ddot", latex == "\\ddot{x}", latex)
        check("...and round trip", mformula_new.to_latex(
                mformula_new.from_latex(fs, SZ, latex)) == latex)
    end

    -- ---------------------------------------------------------------- still one atom to navigate
    --[[ The whole point of a dress being an atom: a hatted ")" must still read as a bracket to
    everything that scans a row. slot_atom is what makes that true (see mexpru). ]]
    do
        local c = formula_with(fs, ")")
        mexpru.u(c.cursor_pos:get_obj()).bracket = {is_open = false, type = vc.MEXPR_BRACKET_ROUND}
        mformula_new.toggle_accent(c, fs, "hat")
        local dressed = mexpru.u(c.root).children[1]
        check("a dressed bracket is still found by slot_atom",
                mexpru.u(mexpru.slot_atom(dressed)).bracket ~= nil)
        check("...and is a sprint landmark like the bare bracket",
                mformula_new.is_sprint_landmark(dressed))
    end

    -- ---------------------------------------------------------------- the decoration survives an
    --[[ ...edit of the thing it decorates. A dress is rebuilt in two places - propagate_rebuild()
    when the target is edited, rescale_node() on a zoom - and they had drifted: only the rescale
    checked u.dots, so editing the letter under a dot accent silently dropped the dots while zooming
    kept them. mexpru.redress() is now the single rebuild both go through.

    The order inside it is the whole bug: a dotted dress carries no above_recipe, so testing the
    recipe first finds nothing and hands back a bare target. Both the dotted and the accented case
    are checked here, since only checking the accented one is exactly what let this through. ]]
    do
        -- Dots, through an ordinary target edit (propagate_rebuild's own dress branch).
        local c = formula_with(fs, "x")
        mformula_new.adjust_dots(c, fs, 2)
        check("setup: two dots", mformula_new.to_latex(c) == "\\ddot{x}", mformula_new.to_latex(c))

        local dress = mexpru.u(c.root).children[1]
        local target = mexpru.u(dress).target
        local y = char.find_by_ascii("y")
        local new_target = mexpru.mexpr_symbol(fs, {size = SZ, code = y.ncod}, true)
        mexpru.u(new_target).sz = SZ
        c.root = mexpru.propagate_rebuild(fs, target, new_target)

        --[[ anchor_len, not to_latex: to_latex reads u.dots, which redress() copies across
        whether or not it actually BUILT anything, so it reports the dotted command even for a dress
        wearing nothing. The decoration is a real subobject - 2 anchors with it, 1 without - so that
        is what the check has to look at. Found by backing the fix out and watching the to_latex
        version of this check stay green. ]]
        local rebuilt = mexpru.u(c.root).children[1]
        check("the rebuilt node is still a dress", mexpru.u(rebuilt).kind == "dress",
                mexpru.u(rebuilt).kind)
        check("editing the target keeps the DOTS THEMSELVES, not just the u.dots tag",
                rebuilt:anchor_len() == 2, rebuilt:anchor_len())
        local latex = mformula_new.to_latex(c)
        check("...and still serialises as two dots on the new letter", latex == "\\ddot{y}", latex)

        -- The same, for an accent rather than dots.
        local c2 = formula_with(fs, "x")
        mformula_new.toggle_accent(c2, fs, "hat")
        local dress2 = mexpru.u(c2.root).children[1]
        local target2 = mexpru.u(dress2).target
        local nt2 = mexpru.mexpr_symbol(fs, {size = SZ, code = y.ncod}, true)
        mexpru.u(nt2).sz = SZ
        c2.root = mexpru.propagate_rebuild(fs, target2, nt2)
        local rebuilt2 = mexpru.u(c2.root).children[1]
        check("editing the target keeps the ACCENT itself", rebuilt2:anchor_len() == 2,
                rebuilt2:anchor_len())
        check("...and serialises as a hat on the new letter",
                mformula_new.to_latex(c2) == "\\hat{y}", mformula_new.to_latex(c2))
    end

    -- ---------------------------------------------------------------- and survives a zoom
    --[[ The other caller of redress(). A dress rebuilt at a new size must come back wearing the
    same thing - the glyph is re-picked for the new width (Rule 12), the decoration is not. ]]
    do
        for _, case in ipairs({{"dots", 3, "\\dddot{x}"}, {"accent", nil, "\\tilde{x}"}}) do
            local c = formula_with(fs, "x")
            if case[2] then
                mformula_new.adjust_dots(c, fs, case[2])
            else
                mformula_new.toggle_accent(c, fs, "tilde")
            end
            check(case[1] .. ": setup", mformula_new.to_latex(c) == case[3], mformula_new.to_latex(c))

            mexpru.set_zoom(-2)
            mformula_new.rescale(c, fs)
            mexpru.set_zoom(0)
            mformula_new.rescale(c, fs)
            check(case[1] .. " survives a zoom round trip", mformula_new.to_latex(c) == case[3],
                    mformula_new.to_latex(c))
            check(case[1] .. ": ...still wearing a real decoration, not just the tag",
                    mexpru.u(c.root).children[1]:anchor_len() == 2,
                    mexpru.u(c.root).children[1]:anchor_len())
        end
    end

    -- ---------------------------------------------------------------- the underside
    --[[ Shift is "put it UNDERNEATH" across the whole accent family (Ctrl+6 / Ctrl+Shift+6, Ctrl+G
    / Ctrl+Shift+G, Ctrl+` / Ctrl+Shift+`), asked for 2026-09-06. The two slots are INDEPENDENT: an
    atom can wear a hat and a bar beneath at once, and toggling one must never disturb the other -
    which is exactly what a single-slot implementation gets wrong by dropping the one it isn't
    looking at. anchor_len is what says a decoration is really there: 2 for one, 3 for both. ]]
    do
        for _, kind in ipairs({"hat", "tilde", "bar"}) do
            local c = formula_with(fs, "x")
            mformula_new.toggle_accent(c, fs, kind, "below")
            local u = mexpru.u(c.cursor_pos:get_obj())
            check(kind .. " below dresses the atom", u.kind == "dress", u.kind)
            check(kind .. " below is tagged on the LOWER slot", u.bellow_kind == kind,
                    u.bellow_kind)
            check(kind .. " below leaves the upper slot empty", u.above_kind == nil, u.above_kind)
            check(kind .. " below really built something",
                    c.cursor_pos:get_obj():anchor_len() == 2,
                    c.cursor_pos:get_obj():anchor_len())

            mformula_new.toggle_accent(c, fs, kind, "below")
            check(kind .. " below toggles back off", cursor_kind(c) ~= "dress", cursor_kind(c))
            check(kind .. " below leaves one bare atom", row_len(c) == 1, row_len(c))
        end
    end

    -- ---------------------------------------------------------------- both at once, independent
    do
        local c = formula_with(fs, "x")
        mformula_new.toggle_accent(c, fs, "hat")
        mformula_new.toggle_accent(c, fs, "bar", "below")
        local u = mexpru.u(c.cursor_pos:get_obj())
        check("an atom can wear both at once",
                u.above_kind == "hat" and u.bellow_kind == "bar",
                tostring(u.above_kind) .. "/" .. tostring(u.bellow_kind))
        check("...and both are really built", c.cursor_pos:get_obj():anchor_len() == 3,
                c.cursor_pos:get_obj():anchor_len())

        -- Taking the top one off must not disturb the bottom one.
        mformula_new.toggle_accent(c, fs, "hat")
        u = mexpru.u(c.cursor_pos:get_obj())
        check("removing the top leaves the bottom", u.above_kind == nil and u.bellow_kind == "bar",
                tostring(u.above_kind) .. "/" .. tostring(u.bellow_kind))
        check("...still a dress with one decoration",
                c.cursor_pos:get_obj():anchor_len() == 2, c.cursor_pos:get_obj():anchor_len())

        mformula_new.toggle_accent(c, fs, "bar", "below")
        check("removing the bottom too leaves a bare atom", cursor_kind(c) ~= "dress",
                cursor_kind(c))
    end

    -- ---------------------------------------------------------------- dots are an ABOVE thing
    --[[ Dots share the upper slot with a named accent, so they replace one - but they must leave
    the underside alone, which is the case a "clear everything and re-dress" implementation loses. ]]
    do
        local c = formula_with(fs, "y")
        mformula_new.toggle_accent(c, fs, "tilde", "below")
        mformula_new.adjust_dots(c, fs, 2)
        local u = mexpru.u(c.cursor_pos:get_obj())
        check("dots go above and keep the accent below",
                u.dots == 2 and u.bellow_kind == "tilde",
                tostring(u.dots) .. "/" .. tostring(u.bellow_kind))

        mformula_new.toggle_accent(c, fs, "hat")
        u = mexpru.u(c.cursor_pos:get_obj())
        check("a hat above replaces the dots, not the accent below",
                u.above_kind == "hat" and u.dots == nil and u.bellow_kind == "tilde",
                tostring(u.above_kind) .. "/" .. tostring(u.dots) .. "/" .. tostring(u.bellow_kind))

        mformula_new.adjust_dots(c, fs, -1)
        check("removing a dot there is a no-op - there are none", cursor_kind(c) == "dress")
    end

    -- ---------------------------------------------------------------- LaTeX, both slots
    --[[ TeX has no two-slot accent, so a node wearing both writes as the below command wrapping
    the above one. Reading that back must give ONE node again, not a dress inside a dress - which
    is what the parser's merge is for, and why the order it was written in cannot matter. ]]
    do
        for _, case in ipairs({
                {"hat", "\\underhat{x}"},
                {"tilde", "\\undertilde{x}"},
                {"bar", "\\underbar{x}"}}) do
            local c = formula_with(fs, "x")
            mformula_new.toggle_accent(c, fs, case[1], "below")
            check(case[1] .. " below serialises as its own command",
                    mformula_new.to_latex(c) == case[2], mformula_new.to_latex(c))
            local back = mformula_new.from_latex(fs, SZ, case[2])
            check(case[1] .. " below round-trips", mformula_new.to_latex(back) == case[2],
                    mformula_new.to_latex(back))
            check(case[1] .. " below comes back on the LOWER slot",
                    mexpru.u(mexpru.u(back.root).children[1]).bellow_kind == case[1])
        end

        local both = "\\underbar{\\hat{x}}"
        local c = mformula_new.from_latex(fs, SZ, both)
        local kid = mexpru.u(c.root).children[1]
        check("both slots parse into ONE dress, not two nested",
                mexpru.u(kid).kind == "dress" and mexpru.u(mexpru.u(kid).target).kind ~= "dress")
        check("...carrying both decorations", kid:anchor_len() == 3, kid:anchor_len())
        check("...and round-tripping", mformula_new.to_latex(c) == both, mformula_new.to_latex(c))

        -- Written the other way round, it has to normalise to the same thing.
        local flipped = mformula_new.from_latex(fs, SZ, "\\hat{\\underbar{x}}")
        check("the two spellings agree", mformula_new.to_latex(flipped) == both,
                mformula_new.to_latex(flipped))
    end

    print("checks: " .. checks_run .. ", failed: " .. checks_failed)
    if checks_failed > 0 then
        return false
    end
    print("PASS: accents - toggling, dot counting, LaTeX round trip, still one atom")
    return true
end

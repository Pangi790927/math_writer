--[[
test_bracket_grows_under_exponent.lua - a bracket pair still grows when the closing half carries a
superscript or subscript.

Reported live 2026-09-06 by pasting "$$(\frac{a}{b})$$ $$(\frac{a}{b})^{2}$$": identical content,
and the first drew tall parentheses around the fraction while the second drew letter-height ones.
Nothing errored - it only looked wrong, which is why it survived so long.

Cause: "(a)^{2}" is [ "(", a, supsub(base=")") ]. The closing bracket is a supsub BASE, not a child
of the row, and resolve_bracket_pairs() searched for it with

    while ... and mexpru.u(children[close_idx]) ~= br.peer do

reading the slot directly. That finds the supsub, whose u never equals br.peer, so the close was
never located and the pair never resized. mexpru.slot_atom() exists precisely for this blind spot -
its own comment records four earlier live bugs from it - and this was the one call site still
reading around it. Writing back needs the mirror (replace_slot_atom), or the exponent would be
thrown away along with the bracket it rides on.

This became urgent when \sqrt started expanding to "(x)^{1/2}" (test_sqrt_as_power.lua), since that
makes EVERY square root of anything tall hit it - but the bug is older and independent, which is
what the first cases here pin.
]]

package.path = package.path .. ";./scripts/?.lua"

local vc = require("virt_composer")
local char = require("char")
local mexpru = require("mexpru")
local mformula_latex = require("mformula_latex")

local B = string.char(92)
local SZ = 12

local checks_run, checks_failed = 0, 0
local function check(name, cond, got)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name .. (got ~= nil and ("  (got: " .. tostring(got) .. ")") or ""))
    end
end

local function walk(node, fn)
    fn(node)
    local u = mexpru.u(node)
    if u.children then for _, c in ipairs(u.children) do walk(c, fn) end end
    for _, k in ipairs({"base", "sup", "sub", "num", "den", "target"}) do
        if u[k] then walk(u[k], fn) end
    end
    if u.slots then for _, c in ipairs(u.slots) do walk(c, fn) end end
end

-- Height of the first OPENING bracket anywhere in the tree - the thing that visibly grows.
local function open_bracket_h(root)
    local h
    walk(root, function(n)
        local u = mexpru.u(n)
        if not h and u.bracket and u.bracket.is_open then
            local bb = vc.mexpr_get_bb(n)
            h = bb.br.y - bb.tl.y
        end
    end)
    return h or -1
end

local function height_of(fs, src)
    return open_bracket_h(mformula_latex.from_latex(fs, SZ, src).root)
end

function run_test()
    local fs = char.load_font_set()
    local FRAC = B .. "frac{a}{b}"

    -- ---------------------------------------------------------------- the reported case
    do
        local bare = height_of(fs, "(" .. FRAC .. ")")
        local sup  = height_of(fs, "(" .. FRAC .. ")^{2}")
        local sub  = height_of(fs, "(" .. FRAC .. ")_{2}")
        local both = height_of(fs, "(" .. FRAC .. ")^{2}_{3}")

        check("sanity: parentheses round a fraction grow at all", bare > 40, bare)

        --[[ Compared against the SAME pair without an exponent rather than an absolute number:
        what was wrong is that adding "^{2}" changed the bracket, and that is exactly what must
        stop being true. It also keeps this honest if the font or size table ever moves. ]]
        check("a superscript on the closing half does not shrink the pair", sup == bare,
                string.format("%.1f vs %.1f", sup, bare))
        check("...nor does a subscript", sub == bare, string.format("%.1f vs %.1f", sub, bare))
        check("...nor both at once", both == bare, string.format("%.1f vs %.1f", both, bare))
    end

    -- ---------------------------------------------------------------- the exponent is not content
    --[[ `inner` is what sits strictly BETWEEN the brackets, so the exponent riding on the closing
    one must not be counted when sizing. If it were, "(x)^{2}" would start growing brackets around
    a single letter just because it has a power - and TeX sizes it the same way this does. ]]
    do
        local plain = height_of(fs, "(x)")
        check("short content keeps plain glyphs", plain > 0, plain)
        check("...and still does with an exponent", height_of(fs, "(x)^{2}") == plain,
                string.format("%.1f vs %.1f", height_of(fs, "(x)^{2}"), plain))
        check("...and with a tall exponent, which is outside the bracket",
                height_of(fs, "(x)^{" .. FRAC .. "}") == plain,
                string.format("%.1f vs %.1f", height_of(fs, "(x)^{" .. FRAC .. "}"), plain))
    end

    -- ---------------------------------------------------------------- nothing is lost in the swap
    --[[ Growing the pair REBUILDS the supsub around the new bracket glyph. Get that wrong and the
    exponent disappears with the atom it rode on - a silent edit to the user's formula, and the
    reason replace_slot_atom() mirrors slot_atom() rather than assigning over the slot. ]]
    do
        local src = "(" .. FRAC .. ")^{2}"
        local c = mformula_latex.from_latex(fs, SZ, src)
        local out = mformula_latex.to_latex(c)
        check("the exponent survives the bracket being replaced",
                out:find("^{2}", 1, true) ~= nil, out)
        --[[ A grown pair is written \left...\right, so the output doubles as proof the growth
        happened - and it must still round-trip. ]]
        check("a grown pair serializes as " .. B .. "left/" .. B .. "right",
                out:find("left(", 1, true) ~= nil, out)
        local twice = mformula_latex.to_latex(mformula_latex.from_latex(fs, SZ, out))
        check("...and re-reads as itself", twice == out, twice)
    end

    -- ---------------------------------------------------------------- the pair is still a pair
    --[[ Peers must survive the rebuild in BOTH directions. A pair linked on only one side is the
    exact shape transfer_bracket_peers() exists to prevent, and it renders identically - so nothing
    but a check like this would catch it. ]]
    do
        local c = mformula_latex.from_latex(fs, SZ, "(" .. FRAC .. ")^{2}")
        local children = mexpru.u(c.root).children
        local open = mexpru.u(mexpru.slot_atom(children[1]))
        local close = mexpru.u(mexpru.slot_atom(children[#children]))
        check("open half still carries a bracket", open.bracket ~= nil and open.bracket.is_open)
        check("close half still carries one, inside the supsub",
                close.bracket ~= nil and close.bracket.is_open == false)
        check("and they point at each other",
                open.bracket.peer == close and close.bracket.peer == open)
    end

    -- ---------------------------------------------------------------- nesting still resolves
    do
        local inner_src = "((" .. FRAC .. ")^{2})^{3}"
        local c = mformula_latex.from_latex(fs, SZ, inner_src)
        local n = 0
        walk(c.root, function(node)
            local u = mexpru.u(node)
            if u.bracket and u.bracket.is_open then n = n + 1 end
        end)
        check("both nested pairs are present and resolved", n == 2, n)
        local out = mformula_latex.to_latex(c)
        check("nested case round-trips",
                mformula_latex.to_latex(mformula_latex.from_latex(fs, SZ, out)) == out, out)
    end

    print("checks: " .. checks_run .. ", failed: " .. checks_failed)
    if checks_failed > 0 then
        return false
    end
    print("PASS: bracket pairs grow through a supsub base")
    return true
end

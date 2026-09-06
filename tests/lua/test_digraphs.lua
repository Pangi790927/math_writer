--[[
test_digraphs.lua - ASCII shorthands that become one glyph while typing, and the catalog rows and
aliases that back them.

Asked for 2026-09-06: ">= should turn into greater than or equal ... and -> should turn into an
arrow, same with their reverses", then the three-character extensions and the common set of symbols
that used to vanish silently on paste.

The part worth pinning is the CHAINING. There is no lookahead and no timer: "<" then "=" has already
become the less-or-equal glyph by the time ">" arrives, so the ">" rule is keyed on THAT glyph, not
on the two characters that produced it. Every step is a complete substitution on its own. Get that
wrong and either the two-character forms stop working or the three-character ones never can.
]]

package.path = package.path .. ";./scripts/?.lua"

local vc = require("virt_composer")
local char = require("char")
local mexpru = require("mexpru")
local mformula = require("mformula_new")
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

--[[ Drives try_digraph the way the keyboard does: `prefix` is parsed to leave the cursor on its
last glyph (from_latex's own convention), then each character of `chars` is offered in turn. Chaining
falls out of that - the second character sees whatever glyph the first one produced.

Returns whether every character was consumed as a shorthand, plus the LaTeX the result serializes
to. A wrong glyph shows up as a wrong name; a shorthand that failed to fire shows up as `false`. ]]
local function digraphs(fs, prefix, chars)
    local c = mformula_latex.from_latex(fs, SZ, prefix)
    local all = true
    for i = 1, #chars do
        local target = c.cursor_pos:get_obj()
        if not mformula.try_digraph(c, fs, target, false, chars:sub(i, i)) then
            all = false
        end
    end
    return all, mformula_latex.to_latex(c)
end

function run_test()
    local fs = char.load_font_set()

    -- ---------------------------------------------------------------- the four that were asked for
    for _, case in ipairs({
            {"a>", "=", "ge"},
            {"a<", "=", "le"},
            {"a-", ">", "rightarrow"},
            {"a<", "-", "leftarrow"},
    }) do
        local fired, out = digraphs(fs, case[1], case[2])
        local want = "a" .. B .. case[3] .. " "
        check(case[1] .. case[2] .. " gives " .. B .. case[3], fired and out == want, out)
    end

    -- ---------------------------------------------------------------- and the three-character ones
    --[[ These work ONLY because the rule for ">" is keyed on the GLYPH the previous pair produced,
    not on the raw characters. If that keying ever changes, these are what break first. ]]
    for _, case in ipairs({
            {"a=", ">",  "Rightarrow"},
            {"a<", "=>", "Leftrightarrow"},
            {"a<", "->", "leftrightarrow"},
    }) do
        local fired, out = digraphs(fs, case[1], case[2])
        local want = "a" .. B .. case[3] .. " "
        check(case[1] .. case[2] .. " gives " .. B .. case[3], fired and out == want, out)
    end

    -- ---------------------------------------------------------------- similar / approx / equiv
    --[[ Asked for 2026-09-06: "~ is similar and ~= can be aproximative ... equivalent is ==".

    "~" is not a digraph - it is a one-character substitution at insertion time (CHAR_REMAP), since
    a literal tilde has no meaning inside a formula. What makes it worth checking here is that it
    then feeds the digraph table like any other glyph: once the tilde IS \sim, "=" upgrades it. ]]
    do
        local c = mformula_latex.from_latex(fs, SZ, B .. "sim")
        check("setup: the similar glyph exists", char.find_by_desc(B .. "sim") ~= nil)

        local fired, out = digraphs(fs, "a" .. B .. "sim", "=")
        check("similar then = gives approx", fired and out == "a" .. B .. "approx ", out)

        local f2, o2 = digraphs(fs, "a=", "=")
        check("== gives equivalent", f2 and o2 == "a" .. B .. "equiv ", o2)

        -- => still works from the same left-hand key; adding == must not have displaced it.
        local f3, o3 = digraphs(fs, "a=", ">")
        check("=> still gives the double arrow", f3 and o3 == "a" .. B .. "Rightarrow ", o3)

        -- and the chain stops: approx has no rule for a further "="
        local f4, o4 = digraphs(fs, "a" .. B .. "sim", "==")
        check("a second = leaves approx alone", not f4)
        check("...with approx intact", o4 == "a" .. B .. "approx ", o4)
    end

    -- ---------------------------------------------------------------- the doubled dot
    --[[ Asked for 2026-09-06: ".. gives cdot, keep the period as is". Only the DOUBLED form is a
    shorthand - a lone period has to stay a period, or decimal points and full stops break. ]]
    do
        local fired, out = digraphs(fs, "a.", ".")
        check(".. gives the centred dot", fired and out == "a" .. B .. "cdot ", out)

        local f2, o2 = digraphs(fs, "a", ".")
        check("a single . is not a shorthand", not f2)
        check("...and is left as a period", o2 == "a", o2)

        -- the common real case: a decimal number must survive untouched
        local f3, o3 = digraphs(fs, "3", ".")
        check("3. does not become a centred dot", not f3)
        check("...leaving the number alone", o3 == "3", o3)
    end

    -- ---------------------------------------------------------------- perpendicular / parallel
    --[[ Asked for 2026-09-06: "_| should give perpendicular and || paralel". Both are shapes drawn
    with the keys themselves. Single "|" and single "_" have to stay themselves - the tall bar
    bracket lives on Ctrl+Shift+backslash precisely so this key is free. ]]
    do
        --[[ The prefix is written "\_", not "_": in LaTeX SOURCE a bare underscore opens a
        subscript, so "a_" would parse as an a with an empty sub rather than the two glyphs the
        keyboard actually produces. Typing goes through find_by_ascii and has no such ambiguity. ]]
        local fired, out = digraphs(fs, "a" .. B .. "_", "|")
        check("_| gives perpendicular", fired and out == "a" .. B .. "perp ", out)

        local f2, o2 = digraphs(fs, "a|", "|")
        check("|| gives parallel", f2 and o2 == "a" .. B .. "parallel ", o2)

        local f3, o3 = digraphs(fs, "a", "|")
        check("a single | is not a shorthand", not f3)
        check("...and stays a plain bar", o3 == "a", o3)

        local f4 = digraphs(fs, "a", "_")
        check("a single _ is not a shorthand", not f4)

        --[[ \perp is its OWN entry, not an alias of ot. Same glyph, different LaTeX class -
        \perp is a relation and gets relation spacing, ot is ordinary - so which one was meant
        has to survive the round trip. If these ever collapse into one entry, a perpendicularity
        statement starts exporting with the wrong spacing and nothing here would say so. ]]
        local perp, bot = char.find_by_desc(B .. "perp"), char.find_by_desc(B .. "bot")
        check("perp and bot both resolve", perp ~= nil and bot ~= nil)
        check("...to the same glyph in the font", perp.fcod == bot.fcod and perp.fnum == bot.fnum)
        check("...but are distinct entries", perp.ncod ~= bot.ncod)
        for _, name in ipairs({"perp", "bot", "parallel"}) do
            local src = "a" .. B .. name .. " b"
            local out2 = mformula_latex.to_latex(mformula_latex.from_latex(fs, SZ, src))
            check(src .. " round-trips to its own name", out2 == src, out2)
        end
    end

    -- ---------------------------------------------------------------- or-equal as a composite
    --[[ Asked for 2026-09-06: "that is the inclusion sign and included or equal should be a
    composite, so made with equal after". Alt+< / Alt+> put the PROPER inclusion in; "=" upgrades it.

    Keyed on the GLYPH, not on how it got there - so it works identically whether the inclusion came
    from the Alt key, from pasted LaTeX or from a loaded file. Both routes are checked here, because
    a rule keyed on keystrokes instead would pass the first and fail the second. ]]
    for _, case in ipairs({{"subset", "subseteq"}, {"supset", "supseteq"}}) do
        local fired, out = digraphs(fs, "a" .. B .. case[1], "=")
        check(B .. case[1] .. " then = gives " .. B .. case[2],
                fired and out == "a" .. B .. case[2] .. " ", out)
    end

    do
        -- ...and it stops there: a second "=" has no rule and must leave the glyph alone.
        local fired, out = digraphs(fs, "a" .. B .. "subset", "==")
        check("a second = does not mangle the or-equal form further", not fired)
        check("...leaving subseteq intact", out == "a" .. B .. "subseteq ", out)
    end

    -- ---------------------------------------------------------------- what must NOT be swallowed
    --[[ A shorthand fires only when the two characters are ADJACENT. Anything between them and both
    stay as typed - that is the only escape hatch for writing them literally, so it has to keep
    working. An unlisted pair must also fall straight through to ordinary insertion. ]]
    do
        for _, case in ipairs({
                {"ax", "=", "a letter then = is not a shorthand"},
                {"a<x", "=", "= after something else does not reach back to the <"},
                {"a-", "-", "-- is not a shorthand"},
                {"a<", "<", "<< is not a shorthand"},
                {"a>", ">", ">> is not a shorthand"},
        }) do
            local fired, out = digraphs(fs, case[1], case[2])
            check(case[3], not fired, out)
            check("...and " .. case[1] .. " is left exactly as it was",
                    out == case[1], out)
        end

        --[[ The chain must not run away either: once "<=" is the less-or-equal glyph, a SECOND "="
        has no rule and has to leave it alone rather than mangling it further. ]]
        local fired, out = digraphs(fs, "a<", "==")
        check("<== stops after the first substitution", not fired)
        check("...leaving the less-or-equal glyph intact", out == "a" .. B .. "le ", out)
    end

    -- ---------------------------------------------------------------- the two operator letters
    --[[ q carries no Greek lowercase (no lowercase koppa in these fonts), so it is the one letter
    slot free for something else. It holds the two differentials: Alt+Q the partial, Alt+Shift+Q the
    integral. Asked for 2026-09-06 - "alt+q is the last slot and will be the differential sign (the
    other than d)".

    Checked here rather than assumed because the tables are keyed by letter and a typo is silent -
    the key would simply insert a plain "q" through the fallback and nobody would see an error. ]]
    do
        check("Alt+Q is the partial differential", char.greek_alt.q == B .. "partial",
                char.greek_alt.q)
        check("Alt+Shift+Q is the integral", char.greek_alt_shift.q == B .. "int",
                char.greek_alt_shift.q)
        for _, d in ipairs({char.greek_alt.q, char.greek_alt_shift.q}) do
            check(d .. " resolves to a glyph", char.find_by_desc(d) ~= nil)
        end
        --[[ And the partial is the cmmi glyph, not the cmsy prime it was mistaken for until
        2026-09-06 - the whole point of the fix that made this key worth binding. ]]
        check("...and the partial is the cmmi one, not a prime",
                char.find_by_desc(B .. "partial").fnum == char.FONT_MATH,
                char.find_by_desc(B .. "partial").fnum)
        check("no other letter was displaced - d is still delta",
                char.greek_alt.d == B .. "delta", char.greek_alt.d)
    end

    -- ---------------------------------------------------------------- the logic layer
    --[[ Added 2026-09-06, once it became clear the logic layer is not deferrable: a typing rule is
    itself a formula (docs/phase2_design.md 6b), so quantifiers and connectives are needed to state
    the very first one.

    Nearly all of it already existed as glyphs and only needed keys. Implication and the
    biconditional needed neither - "=>" and "<=>" were already bound as arrows, and in mathematics
    those ARE implication and iff. ]]
    do
        check("Alt+Shift+A is for-all", char.greek_alt_shift.a == B .. "forall",
                char.greek_alt_shift.a)
        check("Alt+Shift+E is exists", char.greek_alt_shift.e == B .. "exists",
                char.greek_alt_shift.e)
        --[[ Those two slots were free because Greek capital Alpha and Epsilon are drawn identically
        to Latin A and E, so nothing was ever placed there - unlike Sigma and Pi, which really were
        displaced. Alt+A and Alt+E must still be the lowercase Greek. ]]
        check("...and Alt+A is still alpha", char.greek_alt.a == B .. "alpha", char.greek_alt.a)
        check("...and Alt+E is still epsilon", char.greek_alt.e == B .. "epsilon",
                char.greek_alt.e)

        local by_label = {}
        for _, sym in ipairs(char.alt_symbols) do
            by_label[sym.label] = sym
        end
        --[[ Shift lifts the bracket pair from SETS to LOGIC - union to or, intersection to and,
        which is the exact correspondence, so the key keeps meaning the shape. ]]
        check("Alt+Shift+[ is or", by_label["["] and by_label["["].shift == B .. "vee")
        check("Alt+Shift+] is and", by_label["]"] and by_label["]"].shift == B .. "wedge")
        check("...and unshifted is still cup / cap",
                by_label["["].plain == B .. "cup" and by_label["]"].plain == B .. "cap")
        -- "!" is what that key carries in a programming layout, so that is where "not" goes.
        check("Alt+1 is negation", by_label["1"] and by_label["1"].plain == B .. "neg")

        for _, d in ipairs({"forall", "exists", "vee", "wedge", "neg", "Rightarrow",
                            "Leftrightarrow"}) do
            check(B .. d .. " resolves", char.find_by_desc(B .. d) ~= nil)
        end
    end

    -- ---------------------------------------------------------------- the number sets
    --[[ Blackboard bold, from AMS msbm - the first non-Computer-Modern face in the app. msbm holds
    the double-struck capitals at the ordinary ASCII letter positions, so unlike cmsy and cmex there
    is no encoding translation: the fcod IS the letter's code. Verified by rendering.

    They are types (docs/phase2_design.md 6b: types are sets), so these are not decoration - they
    are the vocabulary the typing relation is written in. ]]
    do
        for _, pair in ipairs({{"N", 0x4E}, {"Z", 0x5A}, {"Q", 0x51}, {"R", 0x52},
                               {"C", 0x43}, {"H", 0x48}, {"I", 0x49}, {"L", 0x4C}}) do
            local e = char.find_by_desc(B .. pair[1])
            check(B .. pair[1] .. " is in the catalog", e ~= nil)
            if e then
                check("..." .. B .. pair[1] .. " comes from the blackboard face",
                        e.fnum == char.FONT_BBOLD, e.fnum)
                check("..." .. B .. pair[1] .. " sits at the plain letter position",
                        e.fcod == pair[2], e.fcod)
            end
        end

        --[[ Typed as a DOUBLED capital - "double struck" is what blackboard bold means, so the
        gesture is the notation. Chosen over Alt+Shift+letter, which had room for only five of the
        eight (Q, L and H collide with the integral, Lambda and Theta). ]]
        for _, letter in ipairs({"N", "Z", "Q", "R", "C", "H", "I", "L"}) do
            local fired, out = digraphs(fs, "x" .. letter, letter)
            check(letter .. letter .. " gives " .. B .. letter,
                    fired and out == "x" .. B .. letter .. " ", out)

            -- a single capital stays a plain letter, or ordinary algebra breaks
            local f2, o2 = digraphs(fs, "x", letter)
            check("a lone " .. letter .. " is not a shorthand", not f2)
            check("...and is left as the letter", o2 == "x", o2)

            -- and the chain stops: a third capital must not mangle the set
            local f3, o3 = digraphs(fs, "x" .. letter, letter .. letter)
            check("a third " .. letter .. " leaves the set alone", not f3)
            check("..." .. B .. letter .. " intact", o3 == "x" .. B .. letter .. " ", o3)
        end

        --[[ They must sit ON THE LINE. msbm's baseline does not agree with Computer Modern's - its
        capitals bottomed out 10px high at the default level, so a blackboard R floated a third of
        its own height above the letters beside it. Reported 2026-09-06 as "constructs a character
        in a strange location, not on the same line"; fixed by char.y_offset_by_font, a FACE-level
        correction rather than eight identical per-glyph ones.

        Compared against the plain capital of the same letter, so this stays honest if the font or
        the size table ever moves. The tolerance is 1px of ink rounding - round letters overshoot
        the baseline slightly in one face and not the other. ]]
        for _, letter in ipairs({"N", "Z", "R", "C", "H", "I", "L", "Q"}) do
            local plain = vc.mexpr_get_bb(
                    mexpru.u(mformula_latex.from_latex(fs, SZ, letter).root).children[1]).br.y
            local bbold = vc.mexpr_get_bb(
                    mexpru.u(mformula_latex.from_latex(fs, SZ, B .. letter).root).children[1]).br.y
            check(string.format("%s%s sits on the same baseline as %s (%.1f vs %.1f)",
                            B, letter, letter, bbold, plain),
                    math.abs(bbold - plain) <= 1.0, bbold - plain)
        end

        --[[ And they round-trip, which is what makes them usable in a saved type statement. The
        comparison is one pass against the next, not against the input: these are control WORDS, so
        the writer appends the separator space that a control word needs, and the input written
        without it is simply a different spelling of the same thing. ]]
        local one = mformula_latex.to_latex(mformula_latex.from_latex(fs, SZ, "x" .. B .. "in " .. B .. "R"))
        local two = mformula_latex.to_latex(mformula_latex.from_latex(fs, SZ, one))
        check("a type statement round-trips (" .. one .. ")", one == two, two)
        check("...and names the blackboard set", one:find(B .. "R", 1, true) ~= nil, one)
    end

    -- ---------------------------------------------------------------- typing only, never rescan
    --[[ Shorthands fire while TYPING and at no other moment. Nothing re-scans for them afterwards.

    That is what makes the escape hatch work, and the escape is the only way to write the literal
    characters at all: type them with anything between, then delete the separator (Left, Delete,
    Right). The pair ends up adjacent and untouched.

    It has to survive save/load too, or a carefully escaped ".." would collapse into a centred dot
    the next time the document is opened - silently, and with no way to get it back. So this pins
    that loading applies no shorthands, which is the property the trick actually depends on.

    Do not "fix" this by re-checking adjacency after an edit. ]]
    do
        for _, src in ipairs({"x..y", "xNNy", "x||y", "x==y", "a!=b", "x<=y", "x->y"}) do
            local c = mformula_latex.from_latex(fs, SZ, src)
            check("loading '" .. src .. "' applies no shorthand",
                    mformula_latex.to_latex(c) == src, mformula_latex.to_latex(c))
            check("...and it stays separate atoms",
                    #mexpru.u(c.root).children == #src, #mexpru.u(c.root).children)
        end
    end

    -- ---------------------------------------------------------------- the new catalog rows
    --[[ Every one of these used to parse to NOTHING - an unknown macro was skipped silently, so
    "a \leq b" loaded as "ab". These are the ones reported as worth having. ]]
    do
        for _, name in ipairs({"cdot", "sim", "approx", "subset", "supset", "equiv", "partial"}) do
            local e = char.find_by_desc(B .. name)
            check(B .. name .. " is in the catalog", e ~= nil)
        end

        --[[ Aliases resolve on the way IN but never on the way out: they are a lookup table, not
        extra rows, because a second row sharing an ncod would make to_latex's choice of name depend
        on table order. So each of these loads as its primary spelling. ]]
        for _, pair in ipairs({{"leq", "le"}, {"geq", "ge"}, {"land", "wedge"}, {"lor", "vee"},
                              {"to", "rightarrow"}, {"cong", "equiv"}}) do
            local alias = char.find_by_desc(B .. pair[1])
            local primary = char.find_by_desc(B .. pair[2])
            check(B .. pair[1] .. " resolves to the same glyph as " .. B .. pair[2],
                    alias ~= nil and primary ~= nil and alias.ncod == primary.ncod)
            local out = mformula_latex.to_latex(
                    mformula_latex.from_latex(fs, SZ, "a" .. B .. pair[1] .. " b"))
            check(B .. pair[1] .. " is written back as " .. B .. pair[2],
                    out == "a" .. B .. pair[2] .. " b", out)
        end

        -- \setminus is the backslash glyph itself (TeX 0x6E), so it writes back as an escaped one.
        check(B .. "setminus resolves", char.find_by_desc(B .. "setminus") ~= nil)
    end

    -- ---------------------------------------------------------------- round trips
    do
        for _, name in ipairs({"cdot", "sim", "approx", "subset", "supset", "equiv", "partial"}) do
            local src = "a" .. B .. name .. " b"
            local out = mformula_latex.to_latex(mformula_latex.from_latex(fs, SZ, src))
            check(src .. " round-trips", out == src, out)
        end
    end

    -- ---------------------------------------------------------------- the dot runs
    --[[ No font here has a run of dots as one glyph (docs/texbook.pdf Appendix F), so these expand
    into the characters they actually are - three atoms the cursor can walk and delete one by one.
    One-way, like \sqrt: what comes back out is the expansion, which is valid LaTeX too. ]]
    do
        local ldots = mformula_latex.to_latex(
                mformula_latex.from_latex(fs, SZ, "a" .. B .. "ldots b"))
        check("\\ldots expands to three periods", ldots == "a...b", ldots)

        local cdots = mformula_latex.to_latex(
                mformula_latex.from_latex(fs, SZ, "a" .. B .. "cdots b"))
        check("\\cdots expands to three centred dots",
                cdots == "a" .. B .. "cdot " .. B .. "cdot " .. B .. "cdot b", cdots)

        check("...and both are stable on a second read",
                mformula_latex.to_latex(mformula_latex.from_latex(fs, SZ, cdots)) == cdots, cdots)
    end

    -- ---------------------------------------------------------------- overprinted relations
    --[[ TeX has no single not-equal glyph. It gives 
ot a width of exactly ZERO and prints the
    next character on top of it - that is what 
e, 
otin and \mapsto literally are
    (docs/texbook.pdf Appendix F). This TTF lost that zero width, so the slash used to land BESIDE
    the sign; char.lua's adv_by_desc restores it.

    Two things had to be true, and only the second is visible: the font must report zero advance,
    AND the node must occupy no horizontal space. Layout here is ink-based - mexpr_merge_h steps by
    br.x and only consults the advance for glyphs with no ink at all - so the advance override on
    its own changed nothing, and the fix had to collapse the BOX in mexpr_symbol. Both are checked,
    because either one silently reverting puts the slash back beside the sign. ]]
    do
        local not_e = char.find_by_desc(B .. "not")
        check(B .. "not is in the catalog under its own name", not_e ~= nil)
        if not_e then
            local m = fs:char_get_sz({size = mexpru.physical_sz(SZ), code = not_e.ncod})
            check("...with zero advance", m.adv == 0, m.adv)
        end

        -- the box, which is what layout actually reads
        local c = mformula_latex.from_latex(fs, SZ, B .. "not")
        local n = mexpru.u(c.root).children[1]
        local bb = vc.mexpr_get_bb(n)
        check(B .. "not occupies no horizontal space", bb.br.x - bb.tl.x == 0,
                bb.br.x - bb.tl.x)
        check("...while keeping its height, so the row still fits the slash",
                bb.br.y - bb.tl.y > 0, bb.br.y - bb.tl.y)

        --[[ The pair therefore takes exactly the room of the "=" alone. This is the check that
        would fail if either half of the fix were undone. ]]
        local ne = mformula_latex.from_latex(fs, SZ, B .. "ne")
        local eq = mformula_latex.from_latex(fs, SZ, "=")
        local ne_bb, eq_bb = vc.mexpr_get_bb(ne.root), vc.mexpr_get_bb(eq.root)
        local ne_w, eq_w = ne_bb.br.x - ne_bb.tl.x, eq_bb.br.x - eq_bb.tl.x
        --[[ Not exactly equal: the zero-width slash still contributes its origin to the row's
        union, which sits a couple of units left of where the "=" ink starts. What matters is that
        it is nowhere near SIDE BY SIDE - the slash alone is another ~18 units, so an unfixed
        build lands past 40 here. ]]
        check("a not-equal is about as wide as the = it crosses, not the two side by side",
                ne_w < eq_w * 1.3, string.format("%.1f vs = at %.1f", ne_w, eq_w))
    end

    -- ---------------------------------------------------------------- and how they are spelled
    do
        for _, case in ipairs({
                {B .. "ne",     B .. "not ="},
                {B .. "neq",    B .. "not ="},
                {B .. "notin",  B .. "not " .. B .. "in "},
                {B .. "mapsto", B .. "mapstochar " .. B .. "rightarrow "},
        }) do
            local out = mformula_latex.to_latex(
                    mformula_latex.from_latex(fs, SZ, "a" .. case[1] .. " b"))
            check(case[1] .. " expands to " .. case[2], out == "a" .. case[2] .. "b", out)
            check("...and is stable on a second read",
                    mformula_latex.to_latex(mformula_latex.from_latex(fs, SZ, out)) == out, out)
        end

        --[[ The frontier match: a name must never fire as the PREFIX of a longer one. Without it
        
e would match inside 
eq and leave a stray "q" - and pairs() gives no order to lean on
        instead. ]]
        local neq = mformula_latex.to_latex(mformula_latex.from_latex(fs, SZ, "a" .. B .. "neq b"))
        check(B .. "neq does not leave a stray q", neq:find("q", 1, true) == nil, neq)
    end

    -- ---------------------------------------------------------------- != types as the pair
    do
        local fired, out = digraphs(fs, "a!", "=")
        check("typing != gives the composed not-equal", fired and out == "a" .. B .. "not =", out)
        local c = mformula_latex.from_latex(fs, SZ, "a!")
        mformula.try_digraph(c, fs, c.cursor_pos:get_obj(), false, "=")
        --[[ Two atoms in the MODEL - the slash and the sign are separate glyphs, which is how the
        overprint works at all - but one symbol to the user. See the deletion checks below. ]]
        check("...as two atoms in the row", #mexpru.u(c.root).children == 3,
                #mexpru.u(c.root).children)
        check("...with the cursor on the last of them",
                mexpru.same(c.cursor_pos:get_obj(), mexpru.u(c.root).children[3]))
    end

    -- ---------------------------------------------------------------- and it deletes as ONE
    --[[ Reported live 2026-09-06: "you can write != to get negation, but deleting it leaves the /
    behind." Backspace removed only the "=", stranding a slash that means nothing on its own - a
    lone 
ot is not a symbol anyone writes.

    An earlier version of THIS file asserted that behaviour as if it were a feature ("two atoms, so
    each can be deleted on its own"). It was not. Two atoms is how the overprint is built; one
    symbol is what it is. ]]
    do
        local function backspace_on_last(src)
            local c = mformula_latex.from_latex(fs, SZ, src)
            local children = mexpru.u(c.root).children
            local target = children[#children]
            local ok = mformula.delete_overprint_unit(c, fs, target, c.root, true)
            return ok, mformula_latex.to_latex(c), #mexpru.u(c.root).children
        end

        local ok, out, n = backspace_on_last("a" .. B .. "ne")
        check("backspacing a not-equal removes the slash too", ok and out == "a", out)
        check("...leaving one atom, not a stranded slash", n == 1, n)

        for _, src in ipairs({"a" .. B .. "notin", "a" .. B .. "mapsto"}) do
            local ok2, out2 = backspace_on_last(src)
            check("backspacing " .. src .. " removes both halves", ok2 and out2 == "a", out2)
        end

        --[[ Forward delete from the other side: the cursor sits before the slash, so Delete takes
        the slash AND what it negates. Removing only the slash would silently un-negate the
        relation, which is a different formula. ]]
        do
            local c = mformula_latex.from_latex(fs, SZ, "a" .. B .. "ne b")
            local children = mexpru.u(c.root).children
            check("setup: a, not, =, b", #children == 4, #children)
            local ok3 = mformula.delete_overprint_unit(c, fs, children[1], c.root, false)
            check("forward delete over a not-equal takes both halves", ok3)
            check("...leaving a and b", mformula_latex.to_latex(c) == "ab",
                    mformula_latex.to_latex(c))
        end

        --[[ It must NOT fire on ordinary atoms - this runs ahead of the whole bracket-cascade path,
        so a false positive there would bypass the cascade entirely. ]]
        do
            local c = mformula_latex.from_latex(fs, SZ, "abc")
            local children = mexpru.u(c.root).children
            check("ordinary text is left to the ordinary delete path",
                    not mformula.delete_overprint_unit(c, fs, children[#children], c.root, true))
            local c2 = mformula_latex.from_latex(fs, SZ, "(a)")
            local ch2 = mexpru.u(c2.root).children
            check("a bracket is left to the cascade path",
                    not mformula.delete_overprint_unit(c2, fs, ch2[#ch2], c2.root, true))
        end

        -- Deleting the whole row's contents still leaves a usable row behind.
        do
            local c = mformula_latex.from_latex(fs, SZ, B .. "ne")
            local children = mexpru.u(c.root).children
            check("setup: just the pair", #children == 2, #children)
            check("deleting the only symbol works",
                    mformula.delete_overprint_unit(c, fs, children[2], c.root, true))
            check("...and the row is left with one empty atom, never zero",
                    #mexpru.u(c.root).children == 1, #mexpru.u(c.root).children)
        end
    end

    print("checks: " .. checks_run .. ", failed: " .. checks_failed)
    if checks_failed > 0 then
        return false
    end
    print("PASS: digraphs chain correctly; new catalog rows and aliases resolve")
    return true
end

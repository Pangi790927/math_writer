--[[
test_command_entry.lua - the two ways a symbol gets in that are not a key of its own.

Between them they are the ONLY route to most of char.lua. Alt+letter is entirely spoken for by
Greek and ordinary keys cover ASCII, so before these existed every big operator, relation, arrow and
set symbol in the catalog was unreachable from the keyboard - present in the font, present in the
table, and impossible to type.

1. Typing "\name" then Space.
   Deliberately not a modal command line: the backslash and the letters go in as ORDINARY glyphs,
   so a half-typed command is visible, editable and backspaceable like any other text, and
   abandoning it is just moving away. Space then walks back from the cursor over the letters to the
   backslash and swaps the run for one glyph. What is checked here is that it consumes exactly that
   run and nothing before it, and that an unknown name is left alone rather than eaten.

2. Alt+punctuation for the set symbols.
   The key handler cannot be pressed from the harness, but the thing that actually breaks can be:
   char.alt_symbols is ONE table, read by both the handler and F2's legend. That panel's whole
   claim is that it "can never drift from what the keys actually do", which holds only while there
   is a single table. So its shape is pinned, and every name in it is checked to resolve - a typo
   there is a key that silently does nothing AND a blank row in the legend.
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

local function children(c)
    return mexpru.u(c.root).children
end

local function height(n)
    local bb = vc.mexpr_get_bb(n)
    return bb.br.y - bb.tl.y
end

--[[ Builds the state the user is actually in when they press Space: the command typed out as plain
glyphs, cursor on its last letter. A doubled backslash in LaTeX source is a literal backslash GLYPH,
which is exactly what the key produces - so this goes through the same run the real path sees. ]]
local function typed(fs, text)
    local c = mformula_latex.from_latex(fs, SZ, B .. B .. text)
    local ch = children(c)
    c.cursor_pos = vc.wref_mexpr(ch[#ch])
    return c, ch
end

function run_test()
    local fs = char.load_font_set()

    -- ---------------------------------------------------------------- the run becomes one glyph
    do
        local c, before = typed(fs, "sum")
        check("setup: typed as 4 separate glyphs", #before == 4, #before)

        check("Space resolves it", mformula.try_resolve_command(c, fs) == true)
        local after = children(c)
        check("...collapsing the run to a single glyph", #after == 1, #after)
        check("...which is the summation sign",
                after[1].symb and after[1].symb.code == char.find_by_desc(B .. "sum").ncod,
                after[1].symb and after[1].symb.code)
        check("...with the cursor left on it", mexpru.same(c.cursor_pos:get_obj(), after[1]))
        check("...serializing as the command that was typed",
                mformula_latex.to_latex(c) == B .. "sum ", mformula_latex.to_latex(c))

        --[[ size_delta_by_desc is applied on the way in, which is the point of routing through the
        catalog at all - a sum has to arrive at display size, not as the raw cmex glyph that is
        smaller than a capital letter at text size (see test_bigop_size.lua). ]]
        local cap = children(mformula_latex.from_latex(fs, SZ, "A"))[1]
        check("...at its proper display size, not raw text size",
                height(after[1]) > height(cap) * 1.5,
                string.format("%.0f vs cap %.0f", height(after[1]), height(cap)))
        check("...while u(_).sz stays the surrounding logical level",
                mexpru.u(after[1]).sz == SZ, mexpru.u(after[1]).sz)
    end

    -- ---------------------------------------------------------------- it eats the run and no more
    do
        --[[ "x\infty": only the command goes, the x stays put. Getting this wrong swallows whatever
        preceded the backslash, which is silent data loss. ]]
        local c = mformula_latex.from_latex(fs, SZ, "x" .. B .. B .. "infty")
        local ch = children(c)
        c.cursor_pos = vc.wref_mexpr(ch[#ch])
        check("Space resolves a command that follows other text",
                mformula.try_resolve_command(c, fs) == true)
        local after = children(c)
        check("...leaving exactly the x and the new glyph", #after == 2, #after)
        check("...with the x untouched",
                after[1].symb and after[1].symb.code == char.find_by_ascii("x").ncod)
        check("...round-tripping as both", mformula_latex.to_latex(c) == "x" .. B .. "infty ",
                mformula_latex.to_latex(c))
    end

    -- ---------------------------------------------------------------- an unknown name is left alone
    do
        --[[ The text stays exactly as typed and Space falls through to inserting a real space. If
        this ever consumed the run anyway, a mistyped command would delete itself. ]]
        local c, before = typed(fs, "notacommand")
        local n = #before
        check("an unknown name does not resolve", mformula.try_resolve_command(c, fs) == false)
        check("...and the typed text is untouched", #children(c) == n, #children(c))
    end

    do
        -- No backslash at all: ordinary text, so Space must stay an ordinary space.
        local c = mformula_latex.from_latex(fs, SZ, "abc")
        local ch = children(c)
        c.cursor_pos = vc.wref_mexpr(ch[#ch])
        check("plain letters are not mistaken for a command",
                mformula.try_resolve_command(c, fs) == false)
        check("...and are left as they were", #children(c) == 3, #children(c))
    end

    -- ---------------------------------------------------------------- Alt+punctuation, one table
    do
        check("char.alt_symbols exists and is non-empty",
                type(char.alt_symbols) == "table" and #char.alt_symbols > 0)

        for _, sym in ipairs(char.alt_symbols) do
            local tag = "alt_symbols[" .. tostring(sym.label) .. "]"
            check(tag .. ": has the label F2 prints", type(sym.label) == "string")

            check(tag .. ": names an ImGuiKey", tostring(sym.key):match("^ImGuiKey_") ~= nil,
                    sym.key)

            --[[ Resolved to an integer at load, for the same reason greek_key_ids is: a name that
            does not resolve stays a string, which still works through the slow path but costs a
            lookup per key per frame.

            Only checkable where the constants exist. This harness is headless and registers no
            ImGuiKey bindings at all - vc.ImGuiKey_A is nil there too, so all 26 Greek entries are
            equally unresolved and the assertion would say nothing about the app. Gated on the same
            table rather than skipped outright, so it starts enforcing the moment a harness does
            bind them. ]]
            if type(next(char.greek_key_ids)) == "number" then
                check(tag .. ": its key resolved to a real ImGuiKey id",
                        type(sym.key_id) == "number", sym.key_id)
            end

            check(tag .. ": '" .. sym.plain .. "' is a real glyph",
                    char.find_by_desc(sym.plain) ~= nil)
            if sym.shift then
                check(tag .. ": its Shift form '" .. sym.shift .. "' is a real glyph",
                        char.find_by_desc(sym.shift) ~= nil)
            end
        end

        -- The pairing that was asked for, by name - left/right keys to left/right symbols.
        local by_label = {}
        for _, sym in ipairs(char.alt_symbols) do
            by_label[sym.label] = sym
        end
        check("Alt+[ is union", by_label["["] and by_label["["].plain == B .. "cup")
        check("Alt+] is intersection", by_label["]"] and by_label["]"].plain == B .. "cap")
        --[[ Shifted gives the PROPER inclusion, not the or-equal form. On a US layout those keys
        are "<" and ">", so the shape of the key is the shape of the sign. The or-equal versions are
        deliberately not bound: typing "=" after upgrades the glyph in place (test_digraphs.lua).
        Asked for 2026-09-06 - "included or equal should be a composite, so made with equal after". ]]
        check("Alt+, is 'in', Alt+< the proper inclusion",
                by_label[","] and by_label[","].plain == B .. "in"
                        and by_label[","].shift == B .. "subset")
        check("Alt+. is 'contains', Alt+> the proper inclusion",
                by_label["."] and by_label["."].plain == B .. "ni"
                        and by_label["."].shift == B .. "supset")

        --[[ These are the cmsy10 relations, NOT the cmex big operators of the same name - \cup is
        an inline union, \bigcup the display one. Mixing them up puts a display-height glyph inline,
        which is why none of these should carry a size boost. ]]
        for _, sym in ipairs(char.alt_symbols) do
            check(sym.plain .. " is the inline relation, not its display-operator namesake",
                    char.size_delta_by_desc[sym.plain] == nil, sym.plain)
        end
    end

    print("checks: " .. checks_run .. ", failed: " .. checks_failed)
    if checks_failed > 0 then
        return false
    end
    print("PASS: command entry resolves exactly its own run; Alt+symbol table is sound")
    return true
end

--[[
test_declarations_scope.lua - what a box is allowed to refer to: the definitions ABOVE it, and
nothing else.

THE ASSUMPTION. Author, 2026-09-10: "the definition module should know to provide all the
definitions for the boxes above an i'th box, the idea is that later definitions will be unknown".
A document therefore reads top to bottom the way a proof does, and `content.declarations_before()`
is the one place that decides it.

WHY IT NEEDS AN ALARM. Scope errors are the quietest class of bug there is: getting the bound wrong
by one does not crash, it makes a name resolve that should not have, and the expression built on it
is wrong in a way that looks perfectly reasonable on screen. Nothing else in this repo would catch
it - the expression parser that will consume this does not exist yet, so until it does, this file
is the only thing standing between the rule and a plausible-looking off-by-one.

The three things worth pinning are the bound (strictly above), the identity (the pattern TEXT, not
the display name, because that string is what a use site rebuilds for itself), and the shape handed
out - a caller must not receive the parser's own result table, or every reader ends up coupled to
the name parser's internals.

WHAT IS DELIBERATELY NOT ASSERTED: that resolution WORKS. There is no expression parser and no use
site yet; this checks only what the document offers, which is the half that exists.
]]

package.path = package.path .. ";./scripts/?.lua"

local char = require("char")
local mexpru = require("mexpru")
local mformula_latex = require("mformula_latex")
local mexpr_ast = require("mexpr_ast")
local editor_definition = require("editor_definition")
local content = require("content")

local checks_run, checks_failed = 0, 0
local function check(name, cond, got)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name .. (got ~= nil and ("  (got: " .. tostring(got) .. ")") or ""))
    end
end

--[[ A definition box whose name slot holds `latex`, built the way the box itself would end up
after a parse: the pattern is what mexpr_ast produced. Going through the real parser rather than
hand-writing a pattern is the point - a hand-written one could not drift, and drift is what this
file is watching for. ]]
local function def_box(fs, latex)
    local c = mformula_latex.from_latex(fs, mexpru.DEFAULT_SIZE, latex)
    local pat = c and mexpr_ast.parse_name(fs, c)
    local st = editor_definition.new()
    st.pattern = pat
    return {kind = "definition", def = st}, pat
end

function run_test()
    local fs = char.load_font_set()

    local f_box, f_pat = def_box(fs, "f(x)")
    local g_box, g_pat = def_box(fs, "g(x,y)")
    local a_box = def_box(fs, "a_{n}")
    check("setup: f(x) parsed", f_pat ~= nil and f_pat.text == "f(),(1)",
            f_pat and f_pat.text)
    check("setup: g(x,y) parsed", g_pat ~= nil and g_pat.arity == 2, g_pat and g_pat.arity)

    -- boxes 1..4, with a text box in the middle to prove it is skipped rather than counted
    local state = {boxes = {f_box, {kind = "text"}, g_box, a_box}}

    -- ------------------------------------------------------------------ the bound
    do
        --[[ STRICTLY above. Box 1 is the first thing in the document, so it sees nothing - and box
        3 must NOT see itself. A box that could see its own declaration would make recursion fall
        out of an off-by-one instead of being asked for. ]]
        check("the first box sees nothing", #content.declarations_before(state, 1).order == 0)
        check("box 2 sees the one above it", #content.declarations_before(state, 2).order == 1)
        check("box 3 still sees one - the text box declares nothing",
                #content.declarations_before(state, 3).order == 1)
        check("box 4 sees both definitions above it",
                #content.declarations_before(state, 4).order == 2)

        local at3 = content.declarations_before(state, 3)
        check("box 3 does NOT see its own declaration", at3.by_text["g(),(1),(2)"] == nil)
        local at4 = content.declarations_before(state, 4)
        check("...but box 4 does see it", at4.by_text["g(),(1),(2)"] ~= nil)
    end

    -- ------------------------------------------------------------------ the identity
    do
        --[[ Keyed by the PATTERN TEXT, because that is the string a use site rebuilds for itself.
        Keying by the display name instead would collapse `f(x)` and `f(x,y)` into one entry - two
        different variables that merely share a base. ]]
        local at = content.declarations_before(state, 4)
        check("keyed by pattern text", at.by_text["f(),(1)"] ~= nil)
        check("...not by the bare name", at.by_text["f"] == nil)
        check("arity rides along", at.by_text["f(),(1)"].arity == 1,
                at.by_text["f(),(1)"] and at.by_text["f(),(1)"].arity)
        check("and the box it came from", at.by_text["f(),(1)"].box_index == 1)
    end

    -- ------------------------------------------------------------------ the shape handed out
    do
        --[[ A caller gets a small stable record, never the parser's own result - so `marks`, which
        is presentation, must not leak.

        `tokens` DID leak, and deliberately, on 2026-09-10. This block asserted its absence until
        resolution needed it: matching a use against a declaration walks the two token lists
        position by position, because the pattern TEXT is a string and not a structure. Splitting
        that string back apart at the far end would be a second definition of what a token is, free
        to drift from the first. So the token list is part of the contract now rather than an
        internal - which is a real widening of it, and the reason is recorded here so the next
        person to add a field has to make the same argument. ]]
        local decl = editor_definition.declaration(f_box.def)
        check("declaration has text/name/arity", decl.text and decl.name and decl.arity ~= nil)
        check("...and the token list resolution walks", type(decl.tokens) == "table")
        check("...but NOT the parser's marks", decl.marks == nil)
        check("an unparsed box declares nothing",
                editor_definition.declaration(editor_definition.new()) == nil)
    end

    -- ------------------------------------------------------------------ degenerate input
    do
        --[[ An index past the end asks for "everything", which is what a resolver at the bottom of
        the document wants; nil means the same. Neither may run off the array. ]]
        check("past the end sees all of them", #content.declarations_before(state, 99).order == 3)
        check("nil index sees all of them", #content.declarations_before(state, nil).order == 3)
        check("an empty document is empty", #content.declarations_before({boxes = {}}, 1).order == 0)
    end

    if checks_failed == 0 then
        print("PASS: a box sees the declarations above it and no others ("
                .. checks_run .. " checks)")
    end
    return checks_failed == 0
end

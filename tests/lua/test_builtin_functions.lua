--[[
test_builtin_functions.lua - `sin`, `log`, `det` resolve without anybody declaring them.

THE ASSUMPTION: a built-in is an INJECTED DECLARATION, not a special case in the parser.

That was the intention from the beginning - read_pattern's own comment says "a built-in is an
INJECTED DEFINITION - it reaches resolution through the same declaration set as everything written
by hand, so this reads the name and resolution answers, once" - but nothing produced them, so
`\sin (x)` serialized correctly to LaTeX and then failed to build with "not parsed yet".

WHY THAT SHAPE MATTERS RATHER THAN JUST WORKING. If `sin` were recognised by a branch in the reader
instead, it would be a second grammar: it would not honour the trie's specificity ranking, it would
not sit in the same refusal machinery that now guards the name, and `sin(2x+1)` would need its own
argument parser. As a declaration it gets all of that for nothing, which is what these checks are
really watching - the CALL node, the expression inside the argument, and the refusal - rather than
the list of words.

THE ARITY IS A DECISION, not a fact: one argument for everything except `gcd`, which takes two. So
`\gcd (a)` does NOT resolve, and that is asserted deliberately - it is the visible edge of the
choice, and whoever widens it should have to change a test that says so out loud.

THE SET ITSELF IS A DECISION TOO, and a smaller one than LaTeX's list of macros: every name here is
immutable, so it is spent. See the last block for which words were deliberately left out and why.

BUILT BY PARSING `\sin (x)`, not by writing `sin(),(1)` out by hand, so a built-in keys identically
to a use of it because the same parser produced both. The first check is the one that would catch a
"simplification" back to hand-written tuples: it compares against what the name parser makes of the
same source.
]]

package.path = package.path .. ";./scripts/?.lua"

local char = require("char")
local mexpru = require("mexpru")
local mformula_latex = require("mformula_latex")
local mexpr_ast = require("mexpr_ast")
local ast = require("ast")

local B = string.char(92)
local SZ = mexpru.DEFAULT_SIZE

local checks_run, checks_failed = 0, 0
local function check(name, cond, got)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name .. (got ~= nil and ("  (got: " .. tostring(got) .. ")") or ""))
    end
end

local function build(fs, src, decls)
    local c = mformula_latex.from_latex(fs, SZ, src)
    if not c then
        return nil, "from_latex failed"
    end
    local node, err, ns = mexpr_ast.build(fs, c, decls or {})
    return (node and ast.to_string(ns, node) or nil), err
end

function run_test()
    local fs = char.load_font_set()

    -- ------------------------------------------------------------------ they key like real names
    do
        local decls = mexpr_ast.builtin_declarations(fs)
        check("there are built-ins at all", #decls > 0, #decls)

        local by_text = {}
        for _, d in ipairs(decls) do
            by_text[d.text] = d
        end
        check("sin is declared of one argument", by_text["sin(),(1)"] ~= nil)
        check("gcd is declared of two", by_text["gcd(),(1),(2)"] ~= nil)

        --[[ THE SAME TOKEN WALK the name parser produces for the same source. If someone ever
        replaces the parse with a hand-written tuple, this is what notices. ]]
        local c = mformula_latex.from_latex(fs, SZ, B .. "sin (y)")
        local pat = c and mexpr_ast.parse_name(fs, c)
        check("a built-in keys exactly as a parse of the same name does",
                pat ~= nil and pat.text == "sin(),(1)", pat and pat.text)

        --[[ ORDER IS DETERMINISTIC. It is built by walking a table with `pairs`, which Lua
        randomises per process, and declaration order is the tie-break between two equally specific
        candidates - so the list is sorted. Comparing two calls in one process cannot catch a
        missing sort; comparing against SORTED order can. ]]
        local sorted = true
        for i = 2, #decls do
            if decls[i - 1].text > decls[i].text then
                sorted = false
            end
        end
        check("the list is in a fixed order", sorted)
    end

    -- ------------------------------------------------------------------ a use resolves to a CALL
    do
        local out, err = build(fs, B .. "sin (x)")
        check("sin(x) builds with no declarations in the document", out ~= nil, err)
        check("...as a CALL, not a multiplication",
                out ~= nil and out:sub(1, 3) == "(@,", out)

        --[[ The argument goes through the ordinary expression cascade, which is the part that
        would have needed writing twice if `sin` were a branch instead of a declaration. ]]
        out, err = build(fs, B .. "sin (2x+1)")
        check("its argument is a full expression", out ~= nil, err)
        check("...an addition inside the call",
                out ~= nil and out:find("(+, ", 1, true) ~= nil, out)

        out, err = build(fs, B .. "gcd (a,b)")
        check("a two-argument built-in builds", out ~= nil, err)
        check("...carrying both", out ~= nil and out:find("gcd(),(1),(2)", 1, true) ~= nil, out)

        out = build(fs, B .. "log (x)+" .. B .. "cos (y)")
        check("two different built-ins in one row", out ~= nil and out:sub(1, 3) == "(+,", out)
    end

    -- ------------------------------------------------------------------ the edges of the decision
    do
        --[[ ARITY IS PART OF THE NAME. `gcd` is declared of two, so a use of one does not match it
        - see the header on why this is asserted rather than quietly allowed. ]]
        local out = build(fs, B .. "gcd (a)")
        check("a built-in used at the wrong arity does not resolve", out == nil, out)

        -- A function name with nothing applied to it is not a value.
        out = build(fs, B .. "sin ")
        check("a bare built-in name is not an expression", out == nil, out)
    end

    -- ------------------------------------------------------------------ the built-in wins
    do
        --[[ THE CONSECRATED NAMES ARE IMMUTABLE. `sin` means sine, in every document, always.

        THIS ASSERTION USED TO SAY THE OPPOSITE - that a user's own `sin` replaced the built-in -
        and it was written that way deliberately, on the reasoning that silently losing your own
        definition is worse than shadowing a default. That reasoning was overruled 2026-09-11:
        "builtins should only be those we decided... The consacrated ones are special cases, this
        is imutable". The argument that won: these are not defaults, they are notation. A reader
        who meets `sin(x)` is entitled to read sine without checking what the document did to it,
        and the price is that the word is spent.

        REFUSED, NOT SILENTLY DROPPED. check_declarations says why, so the editor can show it,
        rather than the definition simply never taking effect. ]]
        local mine = {text = "sin(),(1)", name = "sin", arity = 1,
                      tokens = {"sin()", "(1)"}, groups = {}}

        local res = mexpr_ast.check_declarations({mine})
        check("redefining a built-in is refused", #res.refused == 1, #res.refused)
        check("...saying which name and why",
                res.refused[1] and res.refused[1].why
                        and res.refused[1].why:find("built-in", 1, true) ~= nil,
                res.refused[1] and res.refused[1].why)

        --[[ BY WORD, NOT BY KEY: a different arity is still the same word, and a document that
        could mean something else by `sin` at two arguments is exactly as confusing. ]]
        check("a different arity is refused too", mexpr_ast.is_builtin_word("sin"))
        check("an ordinary name is not", not mexpr_ast.is_builtin_word("foo"))

        --[[ And if one reaches the parser anyway, the built-in is the one that answers. Both
        declarations share a key, so the tree alone cannot tell them apart - what is being checked
        is that the row still BUILDS rather than reporting "two readings of this factor", which is
        what two live declarations of one key would produce. ]]
        local out, err = build(fs, B .. "sin (x)", {mine})
        check("a use still builds with a shadowing declaration present", out ~= nil, err)
        check("...without becoming ambiguous",
                err == nil or err:find("two readings", 1, true) == nil, err)
    end

    -- ------------------------------------------------------------------ the set is deliberate
    do
        --[[ SHORTER THAN THE LIST OF MACROS LATEX KNOWS, on purpose: every name here is spent, so
        a word somebody might reasonably use as a variable must not be on it. `dim`, `ker`, `deg`,
        `arg`, `hom`, `lg` and `Pr` were dropped for that reason - "I want to minimize the crossing
        with normal vectors".

        THEY STILL ROUND-TRIP: char.operator_words is the separate, longer list of what LaTeX
        names, so `\dim` still reads, writes and draws - it simply carries no meaning, and a
        document may define one. The two lists are meant to differ, and this pair of checks is what
        says so out loud. ]]
        for _, w in ipairs({"dim", "ker", "deg", "arg", "hom", "lg", "Pr"}) do
            check(w .. " is NOT a reserved built-in", not mexpr_ast.is_builtin_word(w))
            check(w .. " is still a LaTeX macro this app writes", char.operator_words[w] ~= nil)
        end
        for _, w in ipairs({"sin", "cos", "tan", "log", "ln", "exp", "det", "gcd"}) do
            check(w .. " is reserved", mexpr_ast.is_builtin_word(w))
        end
    end

    if checks_failed == 0 then
        print("PASS: built-in functions resolve as declarations (" .. checks_run .. " checks)")
    end
    return checks_failed == 0
end

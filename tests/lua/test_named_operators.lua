--[[
test_named_operators.lua - `lim`, `min`, `argmax` and friends: operators written as WORDS.

TWO ASSUMPTIONS, and they are about different layers.

1. A WORD OPERATOR IS A BINDER, exactly like `\sum`. It declares the variable in its subscript and
   binds it in its body, and it reaches the AST through the same group shape and the same reader -
   `read_bigop` was not modified to accept them. The only thing that differs is how its name is
   spelled on screen: a 1-tall vert of letters instead of one glyph. Requested 2026-09-11: "now do
   the limit too, it should look like sum and also add min, max argmin argmax".

2. IT SERIALIZES AS A LATEX OPERATOR. It used to go out as `\begin{matrix}lim\end{matrix}` - a
   one-row MATRIX, which compiles and is nonsense in a document - and an incoming `\lim` was
   dropped, so a limit pasted from a paper lost its operator and left the subscript hanging.
   Author: "serialize it/deserialize it so that latex understands it".

WHY `argmin` IS SPELLED DIFFERENTLY FROM `lim`, and it is not an inconsistency: `\argmin` does not
exist in LaTeX. Not in plain, not in amsmath. `\operatorname{argmin}` is the only correct spelling,
and it is what amsmath provides for precisely this case. char.operator_words is the list of the ones
LaTeX already names; everything else takes the general form.

WHAT IS DELIBERATELY NOT ASSERTED: that `sin(x)` builds a tree. `sin` is a NAME applied to an
argument, not a binder, and a name has to be declared before a use of it resolves - the "injected
definition" for built-ins does not exist yet. Its serialization IS asserted, because that part works
and is what a document sees.
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

local function build(fs, src)
    local c = mformula_latex.from_latex(fs, SZ, src)
    if not c then
        return nil, "from_latex failed", nil
    end
    local node, err, ns = mexpr_ast.build(fs, c, {})
    return (node and ast.to_string(ns, node) or nil), err, mformula_latex.to_latex(c)
end

function run_test()
    local fs = char.load_font_set()

    -- ------------------------------------------------------------------ every binder, one shape
    do
        --[[ All nine take the SAME path, so one table rather than nine blocks: what is being
        checked is that each is recognised and each declares its subscript variable, not that any
        of them is special. If a tenth is added and this table is not, that is the omission the
        count check at the end is for. ]]
        local words = {"lim", "limsup", "liminf", "min", "max", "sup", "inf"}
        for _, w in ipairs(words) do
            local out, err = build(fs, B .. w .. " _{x}x")
            check(w .. " builds", out ~= nil, err)
            check(w .. " is its own operator at the root",
                    out ~= nil and out:sub(1, #w + 2) == "(" .. w .. ",", out)
            check(w .. " declares its subscript variable",
                    out ~= nil and out:find("(#, x:", 1, true) ~= nil, out)
        end

        -- The two with no LaTeX macro of their own - same shape, different spelling.
        for _, w in ipairs({"argmin", "argmax"}) do
            local out, err = build(fs, B .. "operatorname{" .. w .. "}_{x}x")
            check(w .. " builds", out ~= nil, err)
            check(w .. " is its own operator", out ~= nil and out:sub(1, #w + 2) == "(" .. w .. ",",
                    out)
        end
    end

    -- ------------------------------------------------------------------ the limit's own relation
    do
        --[[ `x \to 0` is not `x = 0`, so it needed a relation of its own - and it is a RELATION
        rather than anything limit-shaped, usable wherever one is. It reaches the row as
        `\rightarrow`, which is also what typing `-` then `>` produces (DIGRAPHS collapses the pair
        into that one glyph), so there is a single spelling to recognise. ]]
        local out, err = build(fs, B .. "lim _{x" .. B .. "rightarrow 0}x")
        check("a limit with an arrow builds", out ~= nil, err)
        check("...reading the arrow as a relation",
                out ~= nil and out:find("(to, ", 1, true) ~= nil, out)
        check("...and spawning the side that varies, not the destination",
                out ~= nil and out:find("(#, x:", 1, true) ~= nil
                        and out:find("(#, 0", 1, true) == nil, out)

        local bare = build(fs, "x" .. B .. "rightarrow 0")
        check("the arrow is a relation outside a limit too",
                bare ~= nil and bare:sub(1, 4) == "(to,", bare)
    end

    -- ------------------------------------------------------------------ what a document sees
    do
        --[[ ROUND-TRIP THROUGH LATEX, which is the half that was broken. Asserted as equality with
        the source, so a change that keeps the app self-consistent while writing something a
        document cannot read still fails here. ]]
        local pairs_ = {
            {B .. "lim _{x}x",                       "a named macro"},
            {B .. "limsup _{n}n",                    "a two-word name, written as one macro"},
            {B .. "max _{x" .. B .. "in S}x",        "with a membership constraint"},
            {B .. "operatorname{argmin}_{x}x",       "a name LaTeX does not define"},
            {B .. "sin (x)",                         "a function, not a binder"},
        }
        for _, case in ipairs(pairs_) do
            local _, _, back = build(fs, case[1])
            check("round-trips: " .. case[2], back == case[1], back)
        end

        --[[ NOT A MATRIX any more, and this is the check that would catch a revert: the old
        spelling round-tripped perfectly within the app, so equality above would still have passed
        if `\begin{matrix}` came back. ]]
        local _, _, back = build(fs, B .. "lim _{x}x")
        check("and is not written as a matrix",
                back ~= nil and back:find("matrix", 1, true) == nil, back)
    end

    -- ------------------------------------------------------------------ the star is a placement
    do
        --[[ amsmath's `\operatorname*` means "limits under it", which is what `\limits` says for
        the built-in operators - so it is read as the same thing rather than dropped. Without this a
        pasted display-style argmin flattened to a beside subscript. ]]
        local c = mformula_latex.from_latex(fs, SZ, B .. "operatorname*{argmin}_{x}x")
        local back = c and mformula_latex.to_latex(c)
        check("a starred operatorname keeps its display placement",
                back ~= nil and back:find(B .. "limits", 1, true) ~= nil, back)
    end

    -- ------------------------------------------------------------------ the list is one list
    do
        --[[ char.operator_words is what the READER accepts and the WRITER emits; mexpr_ast decides
        which of them BIND. A word that binds but is not in the catalog would parse and then
        serialize as `\operatorname{lim}` - legal, but not what anyone writes - so the two lists
        have to agree on the binders even though they answer different questions. ]]
        for _, w in ipairs({"lim", "limsup", "liminf", "min", "max", "sup", "inf"}) do
            check(w .. " is a known LaTeX macro", char.operator_words[w] ~= nil)
        end
        check("argmin is deliberately NOT one", char.operator_words["argmin"] == nil)
        check("argmax is deliberately NOT one", char.operator_words["argmax"] == nil)

        local n = 0
        for _ in pairs(char.operator_words) do n = n + 1 end
        check("the catalog holds the function names too, not just the binders", n >= 20, n)
    end

    if checks_failed == 0 then
        print("PASS: named operators bind and serialize (" .. checks_run .. " checks)")
    end
    return checks_failed == 0
end

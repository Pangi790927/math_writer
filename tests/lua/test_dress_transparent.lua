--[[
test_dress_transparent.lua - a decoration is something done TO a thing, so the thing underneath is
what counts.

THE ASSUMPTION: `\vec{F}_{n}` and `\vec{F_{n}}` are the same name.

They are two spellings of one thing, and the only difference between them is how WIDE the accent is
drawn - a narrow \vec over the letter, a stretchy \overrightarrow over the letter and its index. The
width of an accent is a typesetting choice, not a different accent.

WHAT IT WAS BEFORE, and why it was worth fixing rather than writing off as an odd spelling: the
second built dress(supsub(F, n)), and every reader stopped at the dress. So the subscript was not an
argument, was not part of the identity, and was not an error either - it was simply discarded.
`\vec{F_{n}}` and `\vec{F_{m}}` therefore keyed identically, and a document defining both was told
"`F\vec` is already defined", which reads as a bug in the editor rather than a statement about
notation. Author's diagnosis, 2026-09-11: "this is considered like a glyph, the solution is that
dresses divert the things that is done to them to the underlying object".

TWO PLACES NEEDED IT, which is why mexpru.undressed exists rather than a branch in one of them:
`unit()` reads a row's limits, and the definition editor's signature line drops a name's arguments.
Both stopped at the dress; both now go through the same helper. A third (dress_suffix) already
walked both kinds and was correct.

WHAT IS DELIBERATELY NOT ASSERTED: that the two spellings SERIALIZE identically. They do not, and
should not - `\vec{F}_{n}` and `\overrightarrow{F_{n}}` are different LaTeX and draw differently.
This is about what the parser READS, not about what the writer emits.
]]

package.path = package.path .. ";./scripts/?.lua"

local char = require("char")
local mexpru = require("mexpru")
local mformula_latex = require("mformula_latex")
local mexpr_ast = require("mexpr_ast")
local editor_definition = require("editor_definition")

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

local function pattern(fs, src)
    local c = mformula_latex.from_latex(fs, SZ, src)
    local pat = c and mexpr_ast.parse_name(fs, c)
    return pat, c
end

function run_test()
    local fs = char.load_font_set()

    -- ------------------------------------------------------------------ one name, two spellings
    do
        local inside = pattern(fs, B .. "vec{F_{n}}")     -- accent OVER the limits
        local outside = pattern(fs, B .. "vec{F}_{n}")    -- accent UNDER them

        check("the accent-over-limits spelling parses", inside ~= nil)
        check("the accent-under-limits spelling parses", outside ~= nil)
        check("they key identically",
                inside and outside and inside.text == outside.text,
                inside and outside and (inside.text .. " vs " .. outside.text))
        --[[ ARITY IS THE PART THAT WAS ACTUALLY LOST. The subscript holds the ARGUMENT, so a name
        that reports arity 0 here has silently thrown it away - which is exactly what happened. ]]
        check("...both of arity one", inside and outside
                and inside.arity == 1 and outside.arity == 1,
                inside and (tostring(inside.arity) .. " vs " .. tostring(outside.arity)))

        --[[ And the accent is still IDENTITY, not decoration to be dropped: an undecorated `F_{n}`
        is a different name. If the fix had gone too far - looking through the dress and forgetting
        it - this is what would catch it. ]]
        local plain = pattern(fs, "F_{n}")
        check("a plain F_{n} is a DIFFERENT name",
                inside and plain and inside.text ~= plain.text,
                inside and plain and (inside.text .. " vs " .. plain.text))
    end

    -- ------------------------------------------------------------------ no more false collision
    do
        --[[ The symptom a person actually met. Two definitions that differ only in the name of
        their parameter are the same PATTERN - `f(x)` and `f(z)` always were - so the trie accepts
        one and refuses the second as a duplicate, which is correct and says so. The bug was that
        they were the same pattern for the WRONG reason: the subscript was gone entirely. ]]
        local a = pattern(fs, B .. "vec{F_{n}}")
        local b = pattern(fs, B .. "vec{F_{m}}")
        check("two parameter spellings of one name agree",
                a and b and a.text == b.text and a.arity == 1, a and a.text)
    end

    -- ------------------------------------------------------------------ other accents too
    do
        local hat = pattern(fs, B .. "hat{a_{n}}")
        check("a hat over a subscripted letter reads its subscript",
                hat ~= nil and hat.arity == 1, hat and hat.arity)
        check("...keeping the accent in the key",
                hat ~= nil and hat.text:find("hat", 1, true) ~= nil, hat and hat.text)
    end

    -- ------------------------------------------------------------------ the signature line
    do
        --[[ THE SECOND PLACE THAT STOPPED AT THE DRESS. A definition's signature shows the name
        ALONE - `F : N -> R`, never `F(x) : ...` - so the arguments have to come off. That worked
        by swapping the node for its own base, which a dress hides, so the accent-over spelling put
        the argument back into the signature. ]]
        local pat, c = pattern(fs, B .. "vec{F_{n}}")
        local base = pat and select(1, editor_definition.name_drawings(pat, c))
        check("the signature drops the argument",
                base ~= nil and base:find("_", 1, true) == nil, base)
        check("...and keeps the accent",
                base ~= nil and base:find("{F}", 1, true) ~= nil, base)

        local pat2, c2 = pattern(fs, B .. "vec{F}_{n}")
        local base2 = pat2 and select(1, editor_definition.name_drawings(pat2, c2))
        check("the other spelling drops it too",
                base2 ~= nil and base2:find("_", 1, true) == nil, base2)
    end

    -- ------------------------------------------------------------------ the helper itself
    do
        --[[ mexpru.undressed stops at what the dress WRAPS; slot_atom keeps going to the bare
        glyph. Two different questions, and conflating them is what would break this again - a
        supsub reached by undressing has to still BE the supsub, or its limits are lost. ]]
        local c = mformula_latex.from_latex(fs, SZ, B .. "vec{F_{n}}")
        local top = mexpru.u(c.root).children[1]
        local inner = mexpru.undressed(top)
        check("undressed() reaches the supsub", mexpru.u(inner).kind == "supsub",
                mexpru.u(inner).kind)
        check("slot_atom keeps going to the letter",
                mexpru.u(mexpru.slot_atom(top)).kind ~= "supsub")
        check("undressed() leaves an undressed node alone",
                mexpru.same(mexpru.undressed(inner), inner))
    end

    if checks_failed == 0 then
        print("PASS: dresses are transparent to what they wrap (" .. checks_run .. " checks)")
    end
    return checks_failed == 0
end

--[[
test_definition_name_row.lua - the two DERIVED rows of a definition box are drawn from the user's
own boxes, never from the parser's internal name.

THE ASSUMPTION THIS GUARDS, and it is the one that was broken rather than an output shape:

    `pattern.name` and `pattern.text` are a TOKEN WALK, not LaTeX.

They look like LaTeX - "F\\vec", "F\\vec,sub,(1),end" - and for an undecorated name they even render
correctly, which is exactly why it went unnoticed. The moment a name carries an accent the two part
company: the parser folds a decoration into the base token as a SUFFIX (dress_suffix, so that `a`
cannot be a prefix of `a,\\hat` in the trie), while LaTeX spells an accent as a command WRAPPING its
letter. Feed the token spelling to from_latex and the arrow is drawn after the F instead of above
it. Reported live, 2026-09-11: "in vec(F_n) definition the vector is not drawn above the F, but
right of it", and, on both derived rows at once, "the vec(F) above that field is also broken, only
the original place is not broken".

So the fix was to stop re-rendering a string and draw the mexpr that is already there - author's own
words, "just draw the mexpr already present at the base?" - and these checks watch that it stays
that way. They are written as "the drawing differs from the token spelling", not as "the drawing
equals this exact string", because the failure mode is a silent fall back to the token spelling: an
equality test against a literal would also pass if someone changed how accents serialise, and would
NOT fail if someone quietly restored `pattern.name` as the source.

WHY A PARAMETER IS A DOT. A name's parameters have no spelling (`f(x)` and `f(z)` are one name), so
the row shows the position and not a letter. Requested 2026-09-11: "take the definition and where
you see a var replace it with that dot".

WHAT IS NOT ASSERTED HERE: the colour. `color_parameter_dots` walks the built row and paints every
centred dot, and its own safety argument - that a parsed name can never contain one - is a property
of the NAME PARSER, not of this row. If someone ever makes `\\cdot` legal inside a name, that
argument dies quietly and this file will not notice. The check to write then is in the name parser.
]]

package.path = package.path .. ";./scripts/?.lua"

local char = require("char")
local mexpru = require("mexpru")
local mformula_latex = require("mformula_latex")
local mexpr_ast = require("mexpr_ast")
local editor_definition = require("editor_definition")

local checks_run, checks_failed = 0, 0
local function check(name, cond, got)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name .. (got ~= nil and ("  (got: " .. tostring(got) .. ")") or ""))
    end
end

-- A name slot holding `latex`, parsed exactly as the definition box parses its own.
local function name(fs, latex)
    local c = mformula_latex.from_latex(fs, mexpru.DEFAULT_SIZE, latex)
    if not c then
        return nil, nil, nil
    end
    local pat = mexpr_ast.parse_name(fs, c)
    if not pat then
        return c, nil, nil
    end
    local base_tex, row_tex = editor_definition.name_drawings(pat, c)
    return c, pat, {base = base_tex, row = row_tex}
end

function run_test()
    local fs = char.load_font_set()
    local B = string.char(92)

    -- ------------------------------------------------------- an accent survives into both rows
    do
        local _, pat, tex = name(fs, B .. "vec{F}_{n}")
        check("setup: an accented name with one parameter parses", pat ~= nil and pat.arity == 1,
                pat and pat.arity)

        --[[ THE BUG ITSELF. The token spelling puts the accent after the letter; the drawing must
        not. Comparing the two rather than matching a literal is deliberate - see the header. ]]
        check("the base drawing is not the token spelling",
                tex and tex.base ~= nil and tex.base ~= pat.name, tex and tex.base)
        check("the base drawing spells the accent as a command wrapping the letter",
                tex and tex.base:find("{F}", 1, true) ~= nil, tex and tex.base)
        check("the token spelling still puts it after - i.e. the two really do differ",
                pat.name:find(B .. "vec") ~= nil and pat.name:sub(1, 1) == "F", pat.name)

        -- The parameter shows as a position, not as the letter that happens to sit in it.
        check("the row draws the parameter as a dot",
                tex and tex.row:find(B .. "cdot", 1, true) ~= nil, tex and tex.row)
        check("and does not draw the letter written there", tex and tex.row:find("n") == nil,
                tex and tex.row)
        check("the row keeps the accent too", tex and tex.row:find("{F}", 1, true) ~= nil,
                tex and tex.row)
    end

    -- ------------------------------------------------------- the base is the name WITHOUT its args
    do
        --[[ `a_{n}` is `a` of one parameter, so the signature line shows `a`. The subscript holds
        the ARGUMENT, and an argument is never part of the name - which is why base_nodes takes the
        supsub off (base_under_limits) rather than drawing the node whole. ]]
        local _, pat, tex = name(fs, "a_{n}")
        check("setup: a_{n} parses as arity 1", pat ~= nil and pat.arity == 1, pat and pat.arity)
        check("the base drawing drops the argument", tex and tex.base == "a", tex and tex.base)
        check("the row keeps it, as a dot",
                tex and tex.row:find(B .. "cdot", 1, true) ~= nil, tex and tex.row)
    end

    -- ------------------------------------------------------- an undecorated name is unchanged
    do
        --[[ WHY THIS CASE IS HERE: `f(x)` renders identically either way, which is precisely how
        the bug survived. Keeping it asserts that the fix did not go the other way and start
        mangling the names that always worked. ]]
        local _, pat, tex = name(fs, "f(x)")
        check("setup: f(x) parses", pat ~= nil and pat.arity == 1, pat and pat.arity)
        check("a plain base still draws as itself", tex and tex.base == "f", tex and tex.base)
        check("its argument is a dot", tex and tex.row:find(B .. "cdot", 1, true) ~= nil,
                tex and tex.row)
        check("and the brackets it was written with survive",
                tex and tex.row:find("(", 1, true) ~= nil, tex and tex.row)
    end

    -- ------------------------------------------------------- the substitution hook itself
    do
        --[[ node_to_latex's `subst` is keyed by the node's `u` TABLE, not by the node: two handles
        onto one mexpr_t are two Lua values and hashing does not go through __eq. That is the whole
        reason `Parser.marks` is a list, so it is worth one check that the key really works - if it
        ever stops, every substitution silently misses and the rows quietly go back to being wrong
        WITHOUT any of the checks above failing, since they compare against the token spelling. ]]
        local c = mformula_latex.from_latex(fs, mexpru.DEFAULT_SIZE, "x+y")
        local plain = mformula_latex.to_latex(c)
        local first = mexpru.u(c.root).children[1]
        local swapped = mformula_latex.to_latex(c, {[mexpru.u(first)] = "Q"})
        check("setup: the row serialises", plain ~= nil and #plain > 0, plain)
        check("a subst keyed by u() replaces that node", swapped ~= plain and swapped:find("Q"),
                swapped)
        check("and leaves the rest alone", swapped == "Q" .. plain:sub(2), swapped)
    end

    if checks_failed == 0 then
        print("PASS: definition name rows are drawn from the boxes (" .. checks_run .. " checks)")
    end
    return checks_failed == 0
end

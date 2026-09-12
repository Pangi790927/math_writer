--[[
test_ast_view.lua - mexpr_ast.build() and the F4 viewer that renders it.

THE ASSUMPTION: the parser's output is a REAL ast.lua tree, and the viewer shows that tree and
nothing else. Every node here comes from a genuine constructor - ast.new_eq, ast.new_call,
ast.new_num, ast.new_vref - so anything that walks an AST can walk this one.

WHY THE VIEWER READS THE TREE RATHER THAN THE ROW. An earlier version described the row a second
time, in its own walk, which is a parallel traversal free to drift from the real one. For a tool
whose entire job is to say what the parser did, that is the one bug it must not have: it would show
a shape nobody built, and be believed. Now it has nothing to read but the tree.

DECLARATIONS DECIDE THE SHAPE, NOT WHETHER THERE IS ONE. A CALL's callee is the declaration's key,
so nothing can become a CALL without one - but since 2026-09-10 an unresolved row is read as free
variables and products rather than refused, so `F(0)` builds either `CALL("F(),(1)", NUM(0))` or
`MUL(REF(F), CELL(NUM(0)))` depending only on what is declared above it. Every case below declares
what it means to use, which is also how the app calls it; the pair at the end asserts the fork
itself.

FAILURE IS SHOWN AS FAILURE, and the list of what fails keeps shrinking. This file used to assert
that `a_{n+1}` produced no tree because addition had no parser; on 2026-09-10 it acquired one, along
with multiplication and brackets, and that assertion was replaced rather than deleted - see "CASES 2
AND 3" below for what it was guarding and why the guard moved.
]]

package.path = package.path .. ";./scripts/?.lua"

local char = require("char")
local mexpru = require("mexpru")
local mformula_latex = require("mformula_latex")
local mexpr_ast = require("mexpr_ast")

local checks_run, checks_failed = 0, 0
local function check(name, cond, got)
    checks_run = checks_run + 1
    if not cond then
        checks_failed = checks_failed + 1
        print("FAIL: " .. name .. (got ~= nil and ("  (got: " .. tostring(got) .. ")") or ""))
    end
end

--[[ A declaration, as content.declarations_before() hands them out - a LIST, since resolution
walks candidates rather than looking up a key the use site cannot build. ]]
local function decl(fs, latex)
    local c = mformula_latex.from_latex(fs, mexpru.DEFAULT_SIZE, latex)
    local pat = c and mexpr_ast.parse_name(fs, c)
    if not pat then
        error("test needs '" .. latex .. "' to declare")
    end
    --[[ Through mexpr_ast.new_decl since 2026-09-12: a declaration is a sealed type now, and
    resolve_use checks each element of the list it walks. A bare table carrying the same four
    fields is no longer one - which is the point, since what the parser walks has to BE what the
    document produced. ]]
    return mexpr_ast.new_decl{text = pat.text, name = pat.name, arity = pat.arity,
            tokens = pat.tokens}
end

--[[ The view as one flat string, "depth:text" per line joined by " / " - so an expectation reads
like the cascade it describes, and a failure prints the whole tree rather than one line of it. ]]
local function view(fs, latex, decls)
    local c = mformula_latex.from_latex(fs, mexpru.DEFAULT_SIZE, latex)
    if not c then
        return "<from_latex failed>"
    end
    local parts = {}
    for _, l in ipairs(mexpr_ast.describe(fs, c, decls)) do
        parts[#parts + 1] = l.depth .. ":" .. l.text
    end
    return table.concat(parts, " / ")
end

function run_test()
    local fs = char.load_font_set()
    local F  = decl(fs, "F(n)")
    local f  = decl(fs, "f(y)")
    local a  = decl(fs, "a_{m}")

    -- ------------------------------------------------- the case that was asked for
    do
        local v = view(fs, "F(0)", {F})
        check([[F(0) is CALL "F(),(1)" with NUM 0]],
                v == [[0:CALL "F(),(1)" / 1:NUM 0]], v)
    end

    -- ------------------------------------------------- arguments become real nodes
    do
        --[[ A variable argument is a VREF to a VAR, never the variable itself - which is what
        `x f(x)` needs, two occurrences of one variable. ast.new_vref takes an id, so the AST
        enforces that shape rather than trusting the builder to keep it. ]]
        local v = view(fs, "f(x)", {f})
        check("a variable argument is a REF", v == [[0:CALL "f(),(1)" / 1:REF "x"]], v)

        v = view(fs, "a_{n}", {a})
        check("a subscripted name is a CALL too", v == [[0:CALL "a,sub,(1),end" / 1:REF "n"]], v)
    end

    -- ------------------------------------------------- CASE 4: the relation splits the row
    do
        --[[ The only splitter. Both sides are parsed as expressions in their own right, so the
        tree is a relation with two operands rather than a flat row. ]]
        local v = view(fs, "F(0)=F(1)", {F})
        check("= splits into EQ with both sides built",
                v == [[0:EQ / 1:CALL "F(),(1)" / 2:NUM 0 / 1:CALL "F(),(1)" / 2:NUM 1]], v)

        v = view(fs, "F(0)<F(1)", {F})
        check("< builds LESS", v:match("^0:LESS") ~= nil, v)

        --[[ TOP LEVEL ONLY: an `=` inside brackets belongs to the argument, not to the row. It has
        no parser either way, but it must not SPLIT - a relation inside brackets that tore the row
        in half would build a tree of a formula nobody wrote. ]]
        v = view(fs, "f(a=b)", {f})
        check("a relation inside brackets does not split", v:match("^0:EQ") == nil, v)

        --[[ A chain needs a shape nobody has chosen - ast.new_eq takes two operands - so it is
        refused rather than silently associating left or right. ]]
        v = view(fs, "F(0)=F(1)=F(2)", {F})
        check("a chained relation is refused, not guessed",
                v:find("chains are not handled", 1, true) ~= nil, v)

        v = view(fs, "=F(0)", {F})
        check("a relation needs both sides", v:find("both sides", 1, true) ~= nil, v)

        --[[ THE `\ne` PSEUDO-GLYPH. No font here draws one - TeX has none either, and builds the
        symbol by overprinting the zero-width negation slash with `=`, which is how mformula_latex
        expands the macro. So the row holds TWO atoms, and the danger is specific: `\not` read on
        its own leaves `=` behind as an ordinary equals, so `a \ne b` would build `a = b` and assert
        the opposite of what was written. This asserts the pair is one relation.

        Only `=` is paired, per the author: "if I remember corectly only = has that stupid
        problem". A negated anything else is refused, because ast.lua has INEQ_NEQ and no other
        negated node to put in the tree. ]]
        v = view(fs, "F(0) \\ne F(1)", {F})
        check("\\ne is one relation, not \\not next to =",
                v == [[0:NEQ / 1:CALL "F(),(1)" / 2:NUM 0 / 1:CALL "F(),(1)" / 2:NUM 1]], v)

        v = view(fs, "F(0) \\notin F(1)", {F})
        check("a negated relation with no AST node is refused",
                v:find("has no node in the AST", 1, true) ~= nil, v)

        --[[ AN OPERAND NEED NOT BE A NAME. `a_{1}=1` was reported as broken: the right side is a
        plain value, and the builder only ever offered a side to the NAME parser, so a lone number
        died as "a name must begin with a letter". A relation is the first place two different
        kinds of operand meet, which is why it surfaced here and not in an argument, where numbers
        had worked all along.

        The order the fallback runs in is the assumption worth guarding: a name is tried FIRST.
        Reversed, `a_{1}` would read as the letter `a` and lose its subscript without a word. ]]
        v = view(fs, "a_{1}=1", {decl(fs, "a_{1}")})
        check("a value is a valid side of a relation",
                v == [[0:EQ / 1:REF "a,sub,1,end" / 1:NUM 1]], v)
    end

    -- ------------------------------------------------- a power wraps what it applies to
    do
        local v = view(fs, "f^{2}(x)", {f})
        check("f^2(x) is POW above the CALL",
                v == [[0:POW / 1:CALL "f(),(1)" / 2:REF "x" / 1:NUM 2]], v)
    end

    -- ------------------------------------------------- CASES 2 AND 3: sums, products, brackets
    do
        --[[ THIS TEST FIRED on 2026-09-10 and the assumption behind it is what changed, not the
        code under it. It asserted `addition in an argument stops the build`, which was true while
        an argument had its own miniature parser knowing only "number" and "single letter". The
        cascade replaced that with one expression parser used by the row, the argument and the
        superscript alike, so an argument understands exactly what a row understands.

        What the old assertion was really guarding is still guarded, one line down: that nothing is
        approximated. It was never about addition - it was about the viewer showing a tree for
        something the parser had not understood. So the case moved from "addition fails" to
        "addition builds ADD, and the things that still have no parser still fail". ]]
        local v = view(fs, "a_{n+1}", {a})
        check("addition in an argument builds ADD",
                v == [[0:CALL "a,sub,(1),end" / 1:ADD / 2:REF "n" / 2:NUM 1]], v)

        --[[ JUXTAPOSITION IS MULTIPLICATION, and it can be because a multi-character name has two
        other spellings - quoted, or a 1-tall vert for `sin`. Without those `bb` would be a genuine
        ambiguity and this layer would be guessing. ]]
        v = view(fs, "f(bb)", {f})
        check("two letters side by side are a product",
                v == [[0:CALL "f(),(1)" / 1:MUL / 2:REF "b" / 2:REF "b"]], v)

        --[[ THE SIGN IS A PROPERTY OF THE PRODUCT. Author, 2026-09-10: "so -x transforms into
        (MUL, NUM(-1), REF(x))... +/- is a property of the next NUM or NUM in MUL" - so a negative
        term folds into a leading numeral when there is one, and grows a NUM(-1) factor when there
        is not. Two spellings of one rule, which is why both are here. ]]
        v = view(fs, "f(-x)", {f})
        check("a negated variable is MUL(-1, x)",
                v == [[0:CALL "f(),(1)" / 1:MUL / 2:NUM -1 / 2:REF "x"]], v)

        v = view(fs, "f(-2x)", {f})
        check("a negated product folds the sign into its numeral",
                v == [[0:CALL "f(),(1)" / 1:MUL / 2:NUM -2 / 2:REF "x"]], v)

        --[[ THIS TEST ASSERTED A BUG AS A FEATURE for one day, which is the failure mode
        CLAUDE.md names as the reason tests are tripwires and not proof. It claimed every bracket
        group becomes a CELL, reasoning that `(a+b)c` and `a+bc` differ and the brackets are the
        only thing saying so. The second half is false: the TREE says so - `MUL(ADD(a,b), c)` is
        already a different tree from `ADD(a, MUL(b,c))` - and the rule for this was written on
        2026-09-06, before this parser existed:

            A CELL is emitted exactly when the parentheses are NOT implied by precedence.

        Required parentheses are absorbed into the shape; redundant ones are kept, because they are
        the only carrier of the user's own grouping, which is what transforms.lua drags around.
        Author, restating it 2026-09-10: "the cell should be implied here, it is a jump from mul to
        add, it doesn't need a cell".

        Both halves of the rule are asserted, because either alone would let the other rot. ]]
        v = view(fs, "f((a+b)c)", {f})
        check("brackets required by precedence leave no CELL",
                v == [[0:CALL "f(),(1)" / 1:MUL / 2:ADD / 3:REF "a" / 3:REF "b" / 2:REF "c"]], v)

        v = view(fs, "f((a+b)+c)", {f})
        check("redundant brackets are kept as a CELL",
                v == [[0:CALL "f(),(1)" / 1:ADD / 2:CELL / 3:ADD / 4:REF "a" / 4:REF "b" / 2:REF "c"]],
                v)

        --[[ A GROUP AROUND A LEAF IS NOT GROUPING, and promotes. The 2026-09-06 note calls this
        "lossy in the letter, not in the spirit" - there is nothing inside to arrange, so the
        parentheses carry no arrangement to preserve. ]]
        v = view(fs, "f((a)+b)", {f})
        check("brackets around a leaf promote", v == [[0:CALL "f(),(1)" / 1:ADD / 2:REF "a" / 2:REF "b"]], v)

        --[[ A POWER REQUIRES THEM, whatever is inside: `(a+b)^2` and `a+b^2` are different, so the
        brackets are load-bearing and never become a CELL. ]]
        v = view(fs, "f((a+b)^{2})", {f})
        check("a power keeps its brackets in the shape",
                v == [[0:CALL "f(),(1)" / 1:POW / 2:ADD / 3:REF "a" / 3:REF "b" / 2:NUM 2]], v)

        --[[ A DECORATED DIGIT ENDS THE NUMERAL. `2^{n}3` is a product of a power and a 3; reading
        it as the numeral 23 with a power would be a tree for a formula nobody wrote. ]]
        v = view(fs, "f(2^{n}3)", {f})
        check("a power interrupts a run of digits",
                v == [[0:CALL "f(),(1)" / 1:MUL / 2:POW / 3:NUM 2 / 3:REF "n" / 2:NUM 3]], v)
    end

    -- ------------------------------------------------- still honest about what has no parser
    do
        --[[ THIS TEST FIRED the same day it was written, and it is the clearest example in this
        file of what "green means what I asserted still holds, never it works" is for. It asserted
        that `g(x)` with `g` undeclared is an ERROR, on the grounds that reading it as a product
        would turn a missing declaration into a silently different formula. That was a decision,
        not a consequence, and it was the author's to make - he made it the other way, 2026-09-10:
        "a free letter in front of a bracket should mean multiplication after the resolution
        failed, so say a was not found or found to be an independent variable then a( is a.( a
        multiplication begining".

        The reasoning that survives the reversal, and is what the assertion below now guards: this
        is only reached AFTER resolution has failed on every extent, so a declared `g(x)` is still
        a CALL. And an undeclared letter is an independent variable, which is not applicable to
        anything - so the product is the reading that says something true. ]]
        local v = view(fs, "f(g(x))", {f})
        check("an unresolved letter before a bracket is a product",
                v == [[0:CALL "f(),(1)" / 1:MUL / 2:REF "g" / 2:REF "x"]], v)

        --[[ A SUBSCRIPT ONLY MEANS SOMETHING ON A DECLARED NAME, where it is part of the identity.
        On anything else nobody has decided what it means, and dropping it silently would build a
        tree missing a piece of what was written. ]]
        v = view(fs, "f(a_{1})", {f})
        check("a subscript on an undeclared name stops the build",
                v:find("not parsed yet", 1, true) ~= nil, v)

        --[[ THIS TEST FIRED the day after it was written, and the assumption it carried lasted
        one day. It asserted that a free variable is ordinary in an argument and an ERROR at the top
        of a row, on the reasoning that `f(x)` says nothing about `x` while a row consisting of `x`
        names something that does not exist. Author, 2026-09-10: "yes, allow free variables at the
        top of a row too".

        WHAT THE OLD RULE WAS REALLY STANDING IN FOR is the binders - `sum`, `integral`, `product`,
        `lim` all declare a variable that binds inside their body, and none of them is built. It
        refused a bound variable and a mistyped one alike, because it could not tell them apart;
        allowing both is the better half of that trade until the scope stack exists. ]]
        v = view(fs, "x", {f})
        check("an undeclared letter is a free variable", v == [[0:REF "x"]], v)
    end

    -- ------------------------------------------------- resolution, which is what F4 is for
    do
        --[[ THIS FIRED with the same change, and it is the one to look at hardest. It asserted
        that `F(0)` with nothing declared produced no tree. It now produces a PRODUCT - `F` is a
        free variable, `(0)` a cell beside it - because a letter before a bracket is multiplication
        once resolution has failed, and resolution now fails softly.

        THAT IS THE COST OF THE TWO RULES TOGETHER, and it is worth stating plainly rather than
        leaving to be discovered: a call to a function nobody declared is no longer an error. It
        reads as a product, which is a well-formed tree of something the author probably did not
        mean. Nothing downstream can tell the difference; only the declarations can, which is what
        the pair below asserts.

        Both halves are the author's own calls, made a day apart, and each is right on its own -
        this is what they cost jointly. ]]
        --[[ NOTE THE SHAPE: not `MUL(REF(F), CELL(NUM(0)))` but a flat product, because a group
        around a leaf carries no grouping - so undeclared, `F(0)` and `F 0` are the SAME tree.
        Accepted by the author, 2026-09-10: "I agree with the implication that F becomes
        multiplication, it is what it is, maybe we should deny such a syntax, but not for now". ]]
        local v = view(fs, "F(0)", {})
        check("undeclared, `F(0)` is a product",
                v == [[0:MUL / 1:REF "F" / 1:NUM 0]], v)

        v = view(fs, "F(0)", {F})
        check("declared, the same row is a CALL",
                v == [[0:CALL "F(),(1)" / 1:NUM 0]], v)

        --[[ A literal the declaration wrote into its own name is part of the NAME, so it is not an
        argument: one child, not two. Two would be the miscount that made a use key run to (7). ]]
        v = view(fs, "F_{1,x}", {decl(fs, "F_{1,m}")})
        check("a declared literal is part of the name, not an argument",
                v == [[0:CALL "F,sub,1,(1),end" / 1:REF "x"]], v)

        v = view(fs, "f(a)", {decl(fs, "f(x)"), decl(fs, "f(z)")})
        check("two candidates are reported, not picked", v:find("matches 2", 1, true) ~= nil, v)
    end

    -- ------------------------------------------------- HOW FAR A NAME REACHES ALONG A ROW
    do
        --[[ THE EXTENT IS A PAIR, NOT A SEARCH, and that is the assumption this block exists to
        guard. read_pattern reads a base, then AT MOST ONE bracketed group, then nothing - and a
        subscript rides on the base's own unit, consuming no units of the row. So a name ends either
        where its base does or after the one bracket group that may follow it. There is no third
        place, which is why read_factor asks for exactly two readings.

        Until 2026-09-10 it searched instead: every end position from the whole row down to a single
        unit, re-parsing the same prefix each time. Everything between the two real answers failed
        for reasons that were never interesting - trailing content, or a bracket cut in half.

        If a name ever gains a second call, or a decoration that costs a row unit, this stops being
        true and these cases are where it will show. ]]
        local f_call, f_bare = decl(fs, "f(y)"), decl(fs, "f")

        --[[ THE SAME ROW, TWO DECLARATIONS, TWO READINGS. Nothing about `f(x)` says which it is;
        the declaration is the only thing that does. ]]
        local v = view(fs, "f(x)", {f_call})
        check("declared with a call, the bracket group is the argument",
                v == [[0:CALL "f(),(1)" / 1:REF "x"]], v)

        v = view(fs, "f(x)", {f_bare})
        check("declared bare, the same brackets are a product",
                v == [[0:MUL / 1:REF "f" / 1:REF "x"]], v)

        --[[ AND BOTH DECLARED IS AN AMBIGUITY, not a preference. Two readings of one factor differ
        in EXTENT, so specificity has nothing to compare - ranking cannot help here and does not
        try. ]]
        v = view(fs, "a_{1}(x)", {decl(fs, "a_{1}"), decl(fs, "a_{1}(m)")})
        check("both declared is two readings of the factor",
                v:find("two readings", 1, true) ~= nil, v)

        --[[ The name stops where it stops; the rest of the row is other factors. `f(x)(y)` in
        particular is NOT a second call - read_pattern takes one and no more. ]]
        v = view(fs, "f(x)y", {f_call})
        check("a name is followed by the rest of the row",
                v == [[0:MUL / 1:CALL "f(),(1)" / 2:REF "x" / 1:REF "y"]], v)

        v = view(fs, "f(x)(y)", {f_call})
        check("a second bracket group is a separate factor",
                v == [[0:MUL / 1:CALL "f(),(1)" / 2:REF "x" / 1:REF "y"]], v)
    end

    if checks_failed == 0 then
        print("PASS: the viewer renders the tree the parser built (" .. checks_run .. " checks)")
    end
    return checks_failed == 0
end

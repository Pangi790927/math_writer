--[[
mexpr_ast.lua - the bridge from the EDITED tree (mexpr) to MEANING.

Named to sit beside mexpr.lua (ast -> mexpr) so the pair is visible; see docs/phase2_design.md
section 3. This is its first piece: parsing a NAME PATTERN, which is what a definition box's first
slot holds.

WHAT A NAME PATTERN IS. Not an expression - a *declaration* of one name, written in the notation it
will be applied with, from which the parameters are read off. `f(x)`, `a_n`, `F_{m,n}`, `v_'max'`.
Everything that is not the name itself or a literal is a FREE VARIABLE, and the count of those is
the arity `n` the definition needs (docs/phase2_design.md section 10, and editor_definition.lua's
own header on the n+2 slots).

THE RULES, from the 2026-09-07 spec, with the examples that fix each one:

  ACCEPTED                          REJECTED
  a_b        letter, subscript      2(whatever)   must not start with a number applied to anything
  a_'maxlim' quoted literal index   ab            two atoms at the same level is multiplication,
  'abc'      quoted name                          not a name
  a(x)       call notation          F_{mn}        same, one level down: juxtaposition inside an
  1_u        decorated number                     argument is multiplication
  F_{m,n}    two arguments          a^{'abcd'}x   nothing may follow the base
  a^'abcd'   quoted literal power   (a)           must not start with a bracket

A bare `1` or `a` with nothing else IS a name (the simplest one). What `2(whatever)` violates is
not "starts with a digit" - `1_u` starts with a digit and is fine - it is that a number cannot be
APPLIED. Quotes are what separate a multi-letter NAME from a product: `'abc'` is one name, `abc`
is three variables multiplied. That also answers what section 6 left open as question (b) - how a
multi-letter subscript is written - `v_'max'` is a literal, `v_{max}` is v applied to m*a*x.

LITERALS ARE NOT PARAMETERS. A quoted string and a number are constants, so `a_'maxlim'` has arity
ZERO - it is a plain named variable that happens to be drawn with a subscript. `a_n` has arity one.

THE OUTPUT is a flattened pattern: the base name, then each notation step and the arguments it
takes, with free variables numbered in traversal order.

    a_{n_{m}}   ->  a,sub,(1),sub,(2)
    f(x,y,z)    ->  f(),(1),(2),(3)

TRAVERSAL ORDER IS sup, then same-line, then sub - so `a^p_q(x)` reads its power first, then its
call arguments, then its index. Stated by the user; the same order has to be used by whatever
compares two patterns later, or two spellings of one declaration will not match.
]]

local vc = require("virt_composer")
local char = require("char")
local mexpru = require("mexpru")

local mexpr_ast = {}

local QUOTE = "'"
-- The membership sign's catalog desc (char.lua ncod 155), as a parameter cell must contain one.
local IN_DESC = "\\in"

-- ################################################################################################
-- Reading the tree
-- ################################################################################################

--[[ The glyph an atom carries, as its catalog `desc` ("a", "1", "'", "\\times"), or nil if the node
is not a symbol atom at all (an empty placeholder, or a composite). ]]
local function atom_desc(node)
    if not node or node.type ~= vc.MEXPR_TYPE_SYMBOL then
        return nil
    end
    local entry = char.find_by_ncod(node.symb.code)
    return entry and entry.desc
end

local function is_letter(d)
    return d ~= nil and #d == 1 and d:match("%a") ~= nil
end

local function is_digit(d)
    return d ~= nil and #d == 1 and d:match("%d") ~= nil
end

--[[ One slot of a row, split into the atom that carries its identity and the decorations hung on
it. A supsub is ONE child of the row, so `a_b` is a single slot whose atom is `a` and whose sub is
`b` - and mexpru.slot_atom() is what looks through it (and through a dress) to find that atom.
Every walk over a row has to go through slot_atom or it reads the wrong thing; that blind spot has
produced seven live bugs so far (docs/phase2_design.md section 8). ]]
local function unit(child)
    local u = mexpru.u(child)
    local kind = u and u.kind
    if kind == "supsub" or kind == "bigop" then
        return {atom = mexpru.slot_atom(child), sup = u.sup, sub = u.sub, node = child}
    end
    return {atom = mexpru.slot_atom(child), node = child}
end

local function row_children(node)
    local u = node and mexpru.u(node)
    if u and u.kind == "horiz" then
        return u.children or {}
    end
    -- A slot that is a bare node rather than a row still reads as a one-item row.
    return node and {node} or {}
end

-- ################################################################################################
-- Numbers
-- ################################################################################################

--[[ A written decimal, as the exact rational ast.new_num() wants: {m, n, sign} meaning
sign * m / n.

    "12"     -> 12/1        "3.14"  -> 314/100        "-0.5" -> -5/10

NOT REDUCED. 3.14 stays 314/100 rather than becoming 157/50, matching what
docs/phase2_design.md section 4.2 fixes as the representation. Reducing is a normalisation, and
normalisations belong to the equality machinery (section 9), not to reading a literal - the two
spellings must be able to differ until something decides they do not.

Returns nil for anything that is not a well-formed literal, so `1.2.3` and a bare `.` are refused
rather than silently becoming something.

WHAT THIS IS NOT. It reads LITERALS only, and a literal is not the same thing as a number.
Verbatim, 2026-09-07: "remember sqrt(2) is also a number". `sqrt(2)` reaches the bridge as
`(2)^{1/2}` (section 6c - the radical is rewritten on input and never exists as a node), which is
an EXPRESSION that happens to have a constant value. So "is this a number" is a question about
whether an expression has any free variables, answerable only once expressions can be parsed and
their linked variables computed (section 6b's triple). This function answers the much smaller
question "is this run of glyphs a written numeral", which is what a lexer can know. Do not extend
it to try to recognise constant expressions - that check belongs where variables are resolved. ]]
function mexpr_ast.parse_number(text)
    local sign, body = 1, text
    if body:sub(1, 1) == "-" then
        sign, body = -1, body:sub(2)
    end
    if body == "" then
        return nil
    end

    local int_part, frac_part = body:match("^(%d*)%.(%d*)$")
    if not int_part then
        if not body:match("^%d+$") then
            return nil
        end
        return {m = tonumber(body), n = 1, sign = sign}
    end
    if int_part == "" and frac_part == "" then
        return nil                      -- a lone "."
    end

    -- Integer arithmetic throughout: 10^#frac in Lua 5.4 is a FLOAT, and a denominator that is not
    -- an integer would poison every rational built from it.
    local den = 1
    for _ = 1, #frac_part do
        den = den * 10
    end
    return {m = tonumber(int_part .. frac_part), n = den, sign = sign}
end

-- ################################################################################################
-- Parsing
-- ################################################################################################

local Parser = {}
Parser.__index = Parser

local function new_parser()
    return setmetatable({vars = {}, tokens = {}, marks = {}}, Parser)
end

--[[ Records what the parser made of one atom, for the editor to paint behind it:

    "ok"    read and accepted
    "work"  inside something that is not finished yet - an unclosed bracket, an unterminated
            quote. Not wrong, just incomplete, which is what most of typing looks like.
    "bad"   this is the thing that breaks the rule

Anything the parser never reached is simply absent, and stays unpainted. A LIST rather than a table
keyed by node, because a Lua table cannot be keyed by an mexpr_p - node identity has to go through
mexpru.same(), so there is no usable key. ]]
function Parser:mark(node, status)
    if node then
        self.marks[#self.marks + 1] = {node = node, status = status}
    end
end

--[[ Everything from unit `i` onward, as "work": an unfinished construct swallows the rest of what
was typed, and none of it is wrong yet. ]]
function Parser:mark_rest(units, i)
    for j = i, #units do
        self:mark(units[j].node, "work")
    end
end

function Parser:fail(msg, node)
    self.err, self.err_node = msg, node
    self:mark(node, "bad")
    return nil
end

function Parser:emit(tok)
    self.tokens[#self.tokens + 1] = tok
end

--[[ Records a free variable and emits its numbered slot. Every occurrence gets its own number:
`F_{m,m}` is two parameters that happen to be spelled the same, which is a thing the user can write
and which the definition has no reason to collapse. ]]
function Parser:free_var(name)
    self.vars[#self.vars + 1] = name
    self:emit("(" .. #self.vars .. ")")
end

--[[ Reads a quoted literal starting at `i` in `units`: the opening quote, the run of atoms, the
closing quote. Returns the text and the index of the CLOSING quote's unit, or nil.

The closing quote's unit is returned rather than the one after it because that unit may carry the
decorations - typing Ctrl+_ after `'abc'` wraps the closing quote, so `'abc'_n` is
[', a, b, c, supsub(base=', sub=n)]. Handing the caller the quote's own unit is what lets it find
those. ]]
function Parser:read_quoted(units, i)
    local text = {}
    local j = i + 1
    while j <= #units do
        local d = atom_desc(units[j].atom)
        if d == QUOTE then
            if #text == 0 then
                return self:fail("empty quoted name", units[j].node)
            end
            self:mark(units[i].node, "ok")
            self:mark(units[j].node, "ok")
            for k = i + 1, j - 1 do
                self:mark(units[k].node, "ok")
            end
            return table.concat(text), j
        end
        if not (is_letter(d) or is_digit(d)) then
            return self:fail("a quoted name may only contain letters and digits", units[j].node)
        end
        text[#text + 1] = d
        j = j + 1
    end
    -- Ran off the end with the quote still open: incomplete, not wrong.
    self:mark_rest(units, i)
    self.err, self.err_node = "unterminated quoted name - no closing '", units[i].node
    return nil
end

--[[ Is this unit a bracket, and which way round? Bracket atoms carry u(_).bracket - nothing else
does (mexpru's own bracket model comment). ]]
local function bracket_of(u)
    local uu = u.atom and mexpru.u(u.atom)
    return uu and uu.bracket
end

--[[ Splits a row's units into comma-separated groups. Commas are the ONLY separator inside an
argument list; two atoms side by side with no comma is multiplication, which a name may not
contain (`F_{m,n}` yes, `F_{mn}` no). ]]
local function split_commas(units, p)
    local groups, cur = {}, {}
    for _, u in ipairs(units) do
        if atom_desc(u.atom) == "," then
            if p then
                p:mark(u.node, "ok")
            end
            groups[#groups + 1] = cur
            cur = {}
        else
            cur[#cur + 1] = u
        end
    end
    groups[#groups + 1] = cur
    return groups
end

--[[ One argument: a single unit, which is either a literal (quoted string or number - NOT a
parameter) or a free variable, and which may itself carry decorations that recurse. ]]
function Parser:parse_argument(units)
    if #units == 0 then
        return self:fail("empty argument", nil)
    end

    local first = units[1]
    local d = atom_desc(first.atom)
    local last_i = 1

    if d == QUOTE then
        local text, close_i = self:read_quoted(units, 1)
        if not text then
            return nil
        end
        self:emit("'" .. text .. "'")
        last_i = close_i
    elseif is_digit(d) then
        --[[ A number, read as a run of digits and dots: a literal, not a parameter. Numbers ARE
        strings for this purpose - "constants if you will". ]]
        local num = {}
        local first_i = last_i
        while last_i <= #units do
            local dd = atom_desc(units[last_i].atom)
            if is_digit(dd) or dd == "." then
                num[#num + 1] = dd
                last_i = last_i + 1
            else
                break
            end
        end
        last_i = last_i - 1
        local text = table.concat(num)
        --[[ Checked rather than accepted as typed: `1.2.3` is a run of digits and dots and is not
        a number, and letting it through would put something unreadable into the pattern. ]]
        local value = mexpr_ast.parse_number(text)
        if not value then
            return self:fail("`" .. text .. "` is not a number", units[first_i].node)
        end
        for i = first_i, last_i do
            self:mark(units[i].node, "ok")
        end
        self:emit(text)
    elseif is_letter(d) then
        self:free_var(d)
        self:mark(first.node, "ok")
    else
        return self:fail("an argument must be a name, a quoted literal or a number", first.node)
    end

    --[[ Anything after the argument's own atom (and its decorations) is juxtaposition, i.e.
    multiplication, which is what separates `F_{m,n}` from `F_{mn}`. ]]
    if last_i < #units then
        return self:fail("juxtaposition inside a name - use a comma to separate arguments, "
                .. "or quotes to make one name", units[last_i + 1].node)
    end

    return self:decorations(units[last_i])
end

--[[ An argument list: comma-separated, each group one argument. Takes a plain ARRAY of nodes,
not a row node - a sup/sub slot is unwrapped by the caller with row_children(), and a call's
contents were collected as an array while scanning to the matching bracket. One shape here means
neither path needs a special case. ]]
function Parser:parse_arg_list(nodes)
    local units = {}
    for _, ch in ipairs(nodes or {}) do
        units[#units + 1] = unit(ch)
    end
    -- An untouched slot holds a single empty placeholder; that is "no arguments yet", not an error
    -- worth stopping the whole parse for - the caller sees arity 0 for it.
    if #units == 1 and units[1].atom and units[1].atom.type == vc.MEXPR_TYPE_EMPTY_BOX then
        return true
    end
    for _, group in ipairs(split_commas(units, self)) do
        if not self:parse_argument(group) then
            return nil
        end
    end
    return true
end

--[[ The decorations hanging off one unit, in the fixed order sup -> same-line -> sub. `u.call` is
set by the caller when a bracketed group followed the base on the same line. ]]
function Parser:decorations(u)
    if not u then
        return true
    end
    if u.sup then
        self:emit("sup")
        if not self:parse_arg_list(row_children(u.sup)) then
            return nil
        end
    end
    if u.call then
        --[[ No step marker of its own: the "()" is already stuck to the NAME token, because that is
        how the user wrote the expected output - `f(x,y,z)` is `f(),(1),(2),(3)`, not
        `f,(),(1),(2),(3)`. A call has no step name because the brackets ARE the notation, and they
        are written against the name itself.

        UNSPECIFIED EDGE: a name carrying both a power and a call (`a^2(x)`) puts the "()" on the
        name but its arguments here, in the same-line position, AFTER the power's. That follows the
        stated sup -> same-line -> sub order, but the user's examples only cover one decoration at a
        time, so it is a reading rather than a rule. ]]
        if not self:parse_arg_list(u.call) then
            return nil
        end
    end
    if u.sub then
        self:emit("sub")
        if not self:parse_arg_list(row_children(u.sub)) then
            return nil
        end
    end
    return true
end

--[[ Parses the name pattern in `container`.

Returns a table on success:
    {name = <string>, vars = {<string>, ...}, arity = <n>, tokens = {...}, text = "a,sub,(1)"}
or nil, <message>, <offending mexpr node> on failure. The node is what lets the editor highlight
the problem rather than only describing it (docs/phase2_design.md section 3).

A FOURTH value comes back either way: `marks`, a list of {node, status} saying what the parser made
of each atom it reached - "ok", "work" or "bad" (Parser:mark's own comment). On success it is also
on the pattern as `.marks`. That is what the definition box paints per character, so the user can
see how far a name got rather than only whether it arrived. ]]
--[[ The units of a row, in order. Split out so the same reading serves a whole slot and the
left-hand side of a domain restriction. ]]
local function row_units(node)
    local units = {}
    for _, ch in ipairs(row_children(node)) do
        units[#units + 1] = unit(ch)
    end
    return units
end

local function is_untouched(units)
    return #units == 0 or (#units == 1 and units[1].atom
            and units[1].atom.type == vc.MEXPR_TYPE_EMPTY_BOX)
end

--[[ Reads a name pattern out of `units`, using parser `p`. Everything in `units` must belong to the
name: this is the routine both a name slot (the whole row) and a domain restriction's left-hand
side (the part before the membership sign) go through, so the rules cannot drift between them. ]]
local function read_pattern(p, units)
    if is_untouched(units) then
        -- Nothing typed yet: not an error to paint, just nothing to say.
        return nil, "empty name", nil, p.marks
    end

    -- ---- the base ------------------------------------------------------------------------
    local first = units[1]
    local d = atom_desc(first.atom)
    local base_unit, next_i

    if bracket_of(first) then
        p:mark(first.node, "bad")
        return nil, "a name may not start with a bracket", first.node, p.marks
    elseif d == QUOTE then
        local text, close_i = p:read_quoted(units, 1)
        if not text then
            return nil, p.err, p.err_node, p.marks
        end
        p.name = text
        base_unit, next_i = units[close_i], close_i + 1
    elseif is_letter(d) or is_digit(d) then
        --[[ A digit is allowed as a base - `1_u` is a name, if a strange one. What a number may
        NOT do is be applied, which is caught below when a bracket follows it. ]]
        p.name = d
        p:mark(first.node, "ok")
        base_unit, next_i = first, 2
    else
        p:mark(first.node, "bad")
        return nil, "a name must begin with a letter, a digit or a quoted name", first.node,
                p.marks
    end

    -- ---- an optional call: ONE bracketed group, immediately after the base -----------------
    local call_row = nil
    if next_i <= #units and bracket_of(units[next_i]) then
        local open = bracket_of(units[next_i])
        if not open.is_open then
            p:mark(units[next_i].node, "bad")
            return nil, "closing bracket with nothing open", units[next_i].node, p.marks
        end
        if is_digit(d) then
            p:mark(units[next_i].node, "bad")
            return nil, "a number cannot be applied - `2(x)` is multiplication, not a name",
                    units[next_i].node, p.marks
        end
        --[[ Collect to the matching close. The contents become the call's argument row; the
        brackets themselves are punctuation and do not survive into the pattern. ]]
        local depth, j, inner = 1, next_i + 1, {}
        while j <= #units and depth > 0 do
            local b = bracket_of(units[j])
            if b then
                depth = depth + (b.is_open and 1 or -1)
            end
            if depth > 0 then
                inner[#inner + 1] = units[j].node
            end
            j = j + 1
        end
        if depth ~= 0 then
            --[[ Opened and never closed: everything from the bracket on is "in work" rather than
            wrong. This is what most of typing `f(x,y)` looks like on the way there, and painting it
            red would mean the box was shouting at the user for three keystrokes out of four. ]]
            p:mark_rest(units, next_i)
            return nil, "unclosed bracket in name", units[next_i].node, p.marks
        end
        -- Both brackets read fine; they are punctuation and do not survive into the pattern.
        p:mark(units[next_i].node, "ok")
        p:mark(units[j - 1].node, "ok")
        call_row = inner
        next_i = j
    end

    -- ---- nothing may follow ---------------------------------------------------------------
    if next_i <= #units then
        p:mark(units[next_i].node, "bad")
        return nil, "a name may not be followed by anything else - `a^{'x'}y` is a product, "
                .. "not a name", units[next_i].node, p.marks
    end

    -- ---- emit -----------------------------------------------------------------------------
    -- (still inside read_pattern)
    --[[ The call marker rides on the name token (`f()`), not as a step of its own - see
    decorations() for why. ]]
    p:emit(p.name .. (call_row and "()" or ""))
    base_unit.call = call_row
    if not p:decorations(base_unit) then
        return nil, p.err, p.err_node, p.marks
    end

    return {
        name = p.name,
        vars = p.vars,
        arity = #p.vars,
        tokens = p.tokens,
        text = table.concat(p.tokens, ","),
        marks = p.marks,
    }
end

function mexpr_ast.parse_name(fontset, container)
    local p = new_parser()
    return read_pattern(p, row_units(container.root))
end

--[[ Parses a PARAMETER cell, which must be a membership and nothing else:

        <name> \in <set>          n \in \N ,  v_{max} \in \R ^{2}

Requested 2026-09-07: "the param boxes should reject anything else than apartenance of named to
set". A parameter cell is a domain restriction, so it names the variable and the set it is drawn
from; an expression that is not a membership does not restrict anything and is refused rather than
half-understood.

A SECOND form was floated and then WITHDRAWN the same day: a cell could also have been
`a = <string or constant>`, binding the parameter to a constant instead of restricting it to a set.
Verbatim on dropping it: "yeah we get rid if that". Membership is the only accepted form - do not
re-add the equality case without asking, it was considered and declined.

Returns {var = <name pattern>, set = {<mexpr nodes>}, marks = ...} or nil, message, node, marks.

WHAT IS NOT CHECKED: the SET side. It is handed back as the raw nodes after the membership sign,
because validating it means parsing a general expression (`\R ^{2}` is a power) and that parser
does not exist yet - see docs/phase2_design.md section 3, layer 2. Marking those nodes "ok" rather
than leaving them blank is deliberate: they were read, they are simply not yet understood, and
painting them as unreached would be a lie about how far the parse got. ]]
function mexpr_ast.parse_domain(fontset, container)
    local p = new_parser()
    local units = row_units(container.root)

    if is_untouched(units) then
        return nil, "empty", nil, p.marks
    end

    -- The membership sign, at the top level of this row.
    local in_i
    for i, u in ipairs(units) do
        if atom_desc(u.atom) == IN_DESC then
            in_i = i
            break
        end
    end
    if not in_i then
        --[[ No membership at all. Everything typed is "in work" rather than wrong: a cell on its
        way to `n \in \N` spends every keystroke before the sign in this state, and painting it red
        would have the box shouting through most of normal typing. ]]
        p:mark_rest(units, 1)
        return nil, "a parameter must be a membership: <name> " .. IN_DESC .. " <set>",
                units[1].node, p.marks
    end

    local left, right = {}, {}
    for i = 1, in_i - 1 do
        left[#left + 1] = units[i]
    end
    for i = in_i + 1, #units do
        right[#right + 1] = units[i]
    end

    if #left == 0 then
        p:mark(units[in_i].node, "bad")
        return nil, "nothing before the membership sign", units[in_i].node, p.marks
    end

    local pat, err, node = read_pattern(p, left)
    if not pat then
        return nil, err, node, p.marks
    end

    p:mark(units[in_i].node, "ok")

    if #right == 0 or is_untouched(right) then
        -- The set has not been typed yet: unfinished, not wrong.
        return nil, "nothing after the membership sign", units[in_i].node, p.marks
    end

    local set_nodes = {}
    for _, u in ipairs(right) do
        set_nodes[#set_nodes + 1] = u.node
        p:mark(u.node, "ok")
    end

    return {var = pat, set = set_nodes, marks = p.marks}
end

return mexpr_ast

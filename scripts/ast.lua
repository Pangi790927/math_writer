--[[
ast.lua - THE MEANING TREE: what a formula IS, as opposed to how it is drawn or typed.

Every mathematical element in the program has a node shape here, and this is the base that
serialization, deserialization and the transforms are all written against. The editors do not build
these yet - phase 1 keeps a formula as mexpr plus LaTeX - so this is the model phase 2 grows into
(docs/phase2_design.md), and transforms.lua is the first thing written against it.

A node is a TUPLE: an operator, then its operands, each node carrying an id of its own so anything
else can refer to it. The catalogue of tuple shapes is written out below.

WHAT IS NOT HERE, since docs/phase2_design.md still describes it: an ast -> LaTeX writer sat at the
bottom of this file until 2026-09-09. Nothing outside its own recursion had ever called it, and
mexpr.lua - the only consumer of anything in this file besides main.lua's dead demo - was deleted
the same day. The LaTeX the app really reads and writes is mformula_latex.lua's, and it works on
the mexpr tree, not on these nodes.

@date 2026-09-09 21:20
]]
--[[ OBS: function names can't have spaces ]]

-- tuples:
-- _ID:(...)                    -- tuple with it's id, each tupple will have such an ID 
-- (=, a1, a2)                  -- equality
-- (<, a1, a2)                  -- inequality (and all others <, <=. >=, >, !=)
-- (+, a1, a2, a3, ...)         -- sum of elements
-- (*, a1, a2, a3, ...)         -- product of elements
-- (/, a1, a2)                  -- division
-- (^, a1, a2)                  -- exponentiation
-- (N, m, n, sign)              -- rational/natural number m/n
-- (@, f, a1, a2, a3, ...)      -- function call
-- (#, name)                    -- named variable
-- (&, id)                      -- variable reference
-- (V, a1, a2, a3, ...)         -- vector
-- (M, m, n, a1, ... a[m+n])    -- matrix
-- (_, a1)                      -- paranthesis
-- (S, var, from, to, body)     -- sum       \sum_{var=from}^{to} body
-- (P, var, from, to, body)     -- product   \prod_{var=from}^{to} body
-- (I, var, from, to, body)     -- integral  \int_{from}^{to} body d(var)
-- ...                          -- other custom ones to be thought about later?

--[[ reminder: name option: mathew - math expression writter @date 2026-09-08 08:55 ]]

local ast = {
    INVALID = 1,
    EQ = 2,
    INEQ_LESS = 3,
    INEQ_LEQ = 4,
    INEQ_NEQ = 5,
    INEQ_GREATER = 6,
    INEQ_GEQ = 7,
    ADD = 8,
    MUL = 9,
    DIV = 10,
    EXP = 11,
    NUM = 12,
    CALL = 13,
    VAR = 14,
    VEC = 15,   --[[VEC and MAT are here for later, so I don't forget about them]]
    MAT = 16,
    CELL = 17,  --[[ paranthesis - not sure why I would care about this? ]]
    VREF = 18,
    --[[ The BIG OPERATORS, added 2026-09-10. One shape, three operators - see new_bigop below for
    what makes them different in kind from everything above: they DECLARE a variable. ]]
    SUM = 19,
    PROD = 20,
    INT = 21,
}

--[[ A fresh NAMESPACE: the id -> node table every ast node in one tree is registered in, plus the
next id to hand out. Ids are what a reference names, so a node only means anything inside the
namespace it was made in. @date 2026-09-08 09:10 ]]
function ast.new_ns()
    return { by_id = {}, last_id = 1 }
end

--[[ Registers `obj` under `id`, keeping the namespace's next id past it - so an id read back from
a file cannot later be handed out a second time. @date 2026-09-08 09:10 ]]
function ast.ns_insert_object(ns, id, obj)
    ns.by_id[id] = obj
    if ns.last_id <= id then
        ns.last_id = id + 1
    end
end

--[[ A new node of `type`, already registered in `ns`. Every constructor below goes through here,
which is what makes "has an id" true of every node rather than of most of them.

`id` IS OPTIONAL AND IS THE DESERIALIZER'S DOOR. Without it the namespace hands out the next free
id. With it the node takes the id it is given - which a reader needs, because the ids in a saved
tree are what its references point at, and a node that gets a fresh one has lost every reference to
it.

WHY IT IS A PARAMETER RATHER THAN A CORRECTION AFTERWARDS, which is what from_string used to do:
allocating an id, registering it, then overwriting it left the node in `by_id` TWICE, under a
phantom id nobody would ever look up - and made the collision check fire on the node's own
registration. That broke every tree of more than one node, since reading id `n` pushed `last_id` to
`n+1`, the next node allocated `n+1`, and applying ITS id found `n+1` taken. Nothing can go wrong
here that did not go wrong there, because the id is decided before anything is registered.
@date 2026-09-10 07:40 ]]
function ast.new(ns, type, id)
    local ret = { type = type }
    if id then
        if ns.by_id[id] then
            error("ID " .. tostring(id) .. " is already taken in namespace")
        end
        ret.id = id
    else
        ret.id = ns.last_id
    end
    ast.ns_insert_object(ns, ret.id, ret)
    return ret
end

--[[ Create a copy of an ast, populating a namespace with the right references
(namespace presumed empty at the root of the copy call)

* ns - the old namespace
* node - the node to duplicate
* new_ns - the new namespace in which to create the new tree
* keep_vars - this dictates if the vars inside the expression reference the
             same vars as before
@date 2026-09-08 08:55 ]]
function ast.copy(ns, node, new_ns, keep_vars)
    local ret = { type = node.type }
    ast.ns_insert_object(new_ns, node.id, ret)
    for i = 1, #node do
        if type(node[i]) == "table" and node[i].id then
            if node[i].type == ast.VREF then
                if keep_vars then
                    ast.ns_insert_object(new_ns, node[i][1], ns.by_id[node[i][1]])
                else
                    error("TODO: I didn't need it until now, but I must find a way to " ..
                            "create the new vars inside the new namespace, or figure out a " ..
                            "different solution like to specify what are the new vars " ..
                            "in the new namespace")
                end
            end
            ret[i] = ast.copy(ns, node[i], new_ns, keep_vars)
        else
            ret[i] = node[i]
        end
    end
    return ret
end

--[[ TODO: figure out if this makes sens, if this is not copy with extra rules, etc. @date 2026-09-08 08:55 ]]
function ast.ns_import_ast(dst_ns, src_ns, node)

end

--[[ The RELATION constructors - equality, then the five inequalities. Each takes two expressions
already in `ns` and returns the node joining them; they differ only in the type tag, which is what
tells them apart downstream. @date 2026-09-08 09:10 ]]
function ast.new_eq(ns, expr1, expr2)
    local ret = ast.new(ns, ast.EQ)
    ret[1] = expr1
    ret[2] = expr2
    return ret
end

-- Inequality operators
function ast.new_ineq_less(ns, expr1, expr2)
    local ret = ast.new(ns, ast.INEQ_LESS)
    ret[1] = expr1
    ret[2] = expr2
    return ret
end

function ast.new_ineq_leq(ns, expr1, expr2)
    local ret = ast.new(ns, ast.INEQ_LEQ)
    ret[1] = expr1
    ret[2] = expr2
    return ret
end

function ast.new_ineq_neq(ns, expr1, expr2)
    local ret = ast.new(ns, ast.INEQ_NEQ)
    ret[1] = expr1
    ret[2] = expr2
    return ret
end

function ast.new_ineq_greater(ns, expr1, expr2)
    local ret = ast.new(ns, ast.INEQ_GREATER)
    ret[1] = expr1
    ret[2] = expr2
    return ret
end

function ast.new_ineq_geq(ns, expr1, expr2)
    local ret = ast.new(ns, ast.INEQ_GEQ)
    ret[1] = expr1
    ret[2] = expr2
    return ret
end

-- Arithmetic operators
function ast.new_add(ns, ...)
    local ret = ast.new(ns, ast.ADD)
    for i, expr in ipairs({...}) do
        ret[i] = expr
    end
    return ret
end

function ast.new_mul(ns, ...)
    local ret = ast.new(ns, ast.MUL)
    for i, expr in ipairs({...}) do
        ret[i] = expr
    end
    return ret
end

function ast.new_div(ns, expr1, expr2)
    local ret = ast.new(ns, ast.DIV)
    ret[1] = expr1
    ret[2] = expr2
    return ret
end

--[[ A BIG OPERATOR - a sum, a product or an integral - as (op, var, from, to, body).

THESE ARE THE FIRST NODES THAT DECLARE A NAME. Every other node in this file consumes references;
a big operator makes one. `var` is an ast.new_var that belongs to this node, and the body refers to
it through an ordinary ast.new_vref, exactly as it would to any other variable - so nothing walking
the body needs to know it is inside a binder to read it correctly.

WHAT THAT BUYS is scope without a second mechanism. Author, 2026-09-10: "int declares a variable
name, it offers the insides a new reference, itself, the idea is that we will have our free
variables that buble up outside of the root, while some vars get catched by bigops". So a name in
the body resolves to the innermost binder that declares it, and a name no binder claims keeps
travelling outward past the root, where it is a free variable of the whole formula. Collecting the
free variables of an expression is then one walk that subtracts each binder's `var` from what its
body returned.

ALL THREE HAVE ONE SHAPE deliberately, including the integral, whose `var` is written as `dx` at
the end rather than under the sign. Where the name is WRITTEN is the input method's problem; what
it MEANS - this operator binds this name over this body between these bounds - is the same for all
three, and a separate tuple for the integral would only make every consumer handle it twice.
@date 2026-09-10 07:05 ]]
local BIGOPS = {[ast.SUM] = true, [ast.PROD] = true, [ast.INT] = true}

--[[ Rebinds every free reference to `name` inside `sub` so it points at `var` instead.

THIS IS THE CATCH, and it is the whole of the binding. A body is built with no knowledge of what
encloses it, so a mention of `x` in it is an ordinary reference to whatever `x` the builder had.
Wrapping that body in an operator that declares `x` is what makes those mentions MEAN the operator's
variable - so the constructor walks the body once and repoints them.

FREE means not already claimed by a nearer binder. A nested operator declaring the same name
shadows this one, so its body is skipped - but not its BOUNDS, which are written outside its own
scope: in `\sum_{i=1}^{n}` the `1` and the `n` are not in `i`'s scope, and a `\sum_{x=1}^{x}`
inside an integral over `x` binds its body and nothing else.

Only VREFs move. The VAR they used to point at is left alone in the namespace, because something
outside the body may still be referring to it - `x + \int_0^1 x dx` has two mentions of `x` that
mean different things, and only the inner one is caught.
@date 2026-09-10 07:40 ]]
local function catch_free(ns, sub, name, var)
    if type(sub) ~= "table" or not sub.type then
        return
    end
    if sub.type == ast.VREF then
        local target = ns.by_id[sub[1]]
        if target and target.type == ast.VAR and target[1] == name then
            sub[1] = var.id
        end
        return
    end
    if BIGOPS[sub.type] and sub[1] and sub[1][1] == name then
        -- Shadowed: its body is that operator's, but its bounds are still ours.
        catch_free(ns, sub[2], name, var)
        catch_free(ns, sub[3], name, var)
        return
    end
    for i = 1, #sub do
        catch_free(ns, sub[i], name, var)
    end
end

--[[ A big operator over `name`, whose variable it DECLARES and whose body it then binds.

    ast.new_sum(ns, "i", one, n, body)      -- body's free `i` now means this sum's `i`

THE NAME COMES IN, NOT THE VARIABLE. Author, 2026-09-10: "bigop ops need to create a var, probably
reuse new_var, the idea is that in this way we will achieve our binding". So the operator owns the
variable it binds, and there is no way to build one whose slot 1 belongs to somebody else.

THE BODY IS BUILT FIRST, WHICH THE INTEGRAL REQUIRES. `\int_0^1 x dx` names its variable AFTER the
body - the `dx` at the end is where `x` is declared - so anything that needed the variable before
the body could not read an integral at all. Catching afterwards works for all three and asks the
caller for nothing: build the body with `x` free, then say who binds it.
@date 2026-09-10 07:40 ]]
local function new_bigop(ns, node_type, name, from, to, body)
    local ret = ast.new(ns, node_type)
    ret[1] = ast.new_var(ns, name)
    ret[2] = from
    ret[3] = to
    ret[4] = body
    catch_free(ns, body, name, ret[1])
    return ret
end

function ast.new_sum(ns, name, from, to, body)
    return new_bigop(ns, ast.SUM, name, from, to, body)
end

function ast.new_prod(ns, name, from, to, body)
    return new_bigop(ns, ast.PROD, name, from, to, body)
end

function ast.new_int(ns, name, from, to, body)
    return new_bigop(ns, ast.INT, name, from, to, body)
end

function ast.new_exp(ns, base, exponent)
    local ret = ast.new(ns, ast.EXP)
    ret[1] = base
    ret[2] = exponent
    return ret
end

-- Number: (N, m, n, sign) - rational/natural number m/n
function ast.new_num(ns, m, n, sign)
    n = n or 1
    sign = sign or 1
    assert(type(m) == "number" and m == math.floor(m), "m must be an integer")
    assert(type(n) == "number" and n == math.floor(n), "n must be an integer")
    assert(sign == 1 or sign == -1, "sign must be 1 or -1")
    
    -- Ensure m and n are positive, with sign capturing the overall sign
    if m < 0 and n < 0 then
        -- Both negative: flip both to positive (signs cancel out)
        m = -m
        n = -n
    elseif m < 0 then
        -- Only m is negative: flip m to positive and flip sign
        m = -m
        sign = -sign
    elseif n < 0 then
        -- Only n is negative: flip n to positive and flip sign
        n = -n
        sign = -sign
    end
    
    local ret = ast.new(ns, ast.NUM)
    ret[1] = m
    ret[2] = n
    ret[3] = sign
    return ret
end

-- Function call: (@, f, a1, a2, a3, ...)
function ast.new_call(ns, fn, ...)
    local ret = ast.new(ns, ast.CALL)
    ret[1] = fn
    for i, arg in ipairs({...}) do
        ret[i+1] = arg
    end
    return ret
end

-- Named variable: (#, name)
function ast.new_var(ns, name)
    local ret = ast.new(ns, ast.VAR)
    ret[1] = name
    return ret
end

-- Vector: (V, a1, a2, ...)
function ast.new_vec(ns, ...)
    local ret = ast.new(ns, ast.VEC)
    for i, expr in ipairs({...}) do
        ret[i] = expr
    end
    return ret
end

-- Matrix: (M, m, n, a1, ... a[m+n])
function ast.new_mat(ns, rows, cols, ...)
    local elements = {...}
    local expected_max = rows * cols
    assert(#elements <= expected_max, 
        string.format("matrix has %d elements but rows*cols=%d allows max %d", 
            #elements, rows, cols, expected_max))
    local ret = ast.new(ns, ast.MAT)
    ret[1] = rows
    ret[2] = cols
    for i, expr in ipairs(elements) do
        ret[i+2] = expr
    end
    return ret
end

-- Parentheses: (_, a1)
function ast.new_cell(ns, expr)
    local ret = ast.new(ns, ast.CELL)
    ret[1] = expr
    return ret
end

-- Variable reference: (&, ref_id)
-- ref can be either a number (id) or an AST node (whose id will be extracted)
function ast.new_vref(ns, ref)
    local ref_id
    if type(ref) == "number" then
        ref_id = ref
    elseif type(ref) == "table" and ref.id then
        ref_id = ref.id
    else
        error("ref must be a number (id) or an AST node with an id")
    end
    local ret = ast.new(ns, ast.VREF)
    ret[1] = ref_id
    return ret
end

-- #################################################################################################
-- Serialization/Deserialization
-- #################################################################################################

-- Serialization: AST node -> string
local type_to_symbol = {
    [ast.EQ] = "=",
    [ast.INEQ_LESS] = "<",
    [ast.INEQ_LEQ] = "<=",
    [ast.INEQ_NEQ] = "!=",
    [ast.INEQ_GREATER] = ">",
    [ast.INEQ_GEQ] = ">=",
    [ast.ADD] = "+",
    [ast.MUL] = "*",
    [ast.DIV] = "/",
    [ast.EXP] = "^",
    [ast.NUM] = "N",
    [ast.CALL] = "@",
    [ast.VAR] = "#",
    [ast.VEC] = "V",
    [ast.MAT] = "M",
    [ast.CELL] = "_",
    [ast.VREF] = "&",
    [ast.SUM] = "S",
    [ast.PROD] = "P",
    [ast.INT] = "I",
}

function ast.to_string(ns, node)
    if type(node) == "number" then
        return tostring(node)
    elseif type(node) == "string" then
        return node
    elseif type(node) == "table" and node.type then
        local symbol = type_to_symbol[node.type] or "?"
        local parts = {"(" .. symbol}
        for i = 1, #node do
            table.insert(parts, ", " .. ast.to_string(ns, node[i]))
        end
        return table.concat(parts) .. ":" .. tostring(node.id) .. ")"
    else
        error("Cannot serialize: " .. type(node))
    end
end


-- Deserialization: string -> AST node
local symbol_to_type = {
    ["="] = ast.EQ,
    ["<"] = ast.INEQ_LESS,
    ["<="] = ast.INEQ_LEQ,
    ["!="] = ast.INEQ_NEQ,
    [">"] = ast.INEQ_GREATER,
    [">="] = ast.INEQ_GEQ,
    ["+"] = ast.ADD,
    ["*"] = ast.MUL,
    ["/"] = ast.DIV,
    ["^"] = ast.EXP,
    ["N"] = ast.NUM,
    ["@"] = ast.CALL,
    ["#"] = ast.VAR,
    ["V"] = ast.VEC,
    ["M"] = ast.MAT,
    ["_"] = ast.CELL,
    ["&"] = ast.VREF,
    ["S"] = ast.SUM,
    ["P"] = ast.PROD,
    ["I"] = ast.INT,
}

-- Helper: parse a token that's either a number or a string
local function parse_atom(s)
    local num = tonumber(s)
    if num then
        return num
    end
    return s
end

-- Helper: split tuple arguments respecting nested parentheses
local function split_args(s)
    local args = {}
    local depth = 0
    local start = 1
    for i = 1, #s do
        local c = s:sub(i, i)
        if c == "(" then
            depth = depth + 1
        elseif c == ")" then
            depth = depth - 1
        elseif c == "," and depth == 0 then
            table.insert(args, s:sub(start, i - 1))
            start = i + 1
        end
    end
    -- Add last argument
    if start <= #s then
        table.insert(args, s:sub(start))
    end
    return args
end

function ast.from_string(ns, s)
    -- Remove all whitespace for simpler parsing
    s = s:gsub("%s+", "")
    
    -- Empty string
    if s == "" then
        return nil
    end
    
    -- Bare number
    local num = tonumber(s)
    if num then
        return num
    end
    
    -- Bare string/identifier (not a tuple)
    if s:sub(1, 1) ~= "(" then
        return s
    end
    
    -- Parse tuple: (type, arg1, arg2, ...:id)
    assert(s:sub(1, 1) == "(", "Expected '(' at start of tuple: " .. s)
    assert(s:sub(-1) == ")", "Expected ')' at end of tuple: " .. s)
    
    -- Extract content between parentheses
    local inner = s:sub(2, -2)
    
    -- Check for id suffix: ...:id
    local node_id = nil
    local colon_pos = inner:find(":%d+$")
    if colon_pos then
        -- Extract the id part
        local id_str = inner:sub(colon_pos + 1)
        node_id = tonumber(id_str)
        inner = inner:sub(1, colon_pos - 1)
    end
    
    -- Find the type symbol (everything before first comma)
    local first_comma = inner:find(",")
    if not first_comma then
        error("Missing comma in tuple: " .. s)
    end
    
    local type_str = inner:sub(1, first_comma - 1)
    local args_str = inner:sub(first_comma + 1)
    
    -- Look up the type
    local node_type = symbol_to_type[type_str]
    if not node_type then
        error("Unknown type symbol: '" .. type_str .. "' in: " .. s)
    end
    
    -- Split arguments
    local arg_strs = split_args(args_str)
    local args = {}
    for _, arg_str in ipairs(arg_strs) do
        if arg_str ~= "" then  -- Skip empty
            table.insert(args, ast.from_string(ns, arg_str))
        end
    end
    
    --[[ The serialized id goes IN, rather than being corrected on afterwards - see ast.new.
    The old shape registered the node under a freshly allocated id first, which made every tree
    of more than one node unreadable and left a phantom entry behind when it did not. ]]
    local ret = ast.new(ns, node_type, node_id)
    for i, arg in ipairs(args) do
        ret[i] = arg
    end

    return ret
end

return ast

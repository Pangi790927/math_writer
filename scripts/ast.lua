--[[ 
  This file contains the ast node representation of all math elements inside the program
  This is the base that will be used later for serialization, deserialization and drawing
  diverse mathematical expressions.
  
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
-- ...                          -- other custom ones to be thought about later?

--[[ reminder: name option: mathew - math expression writter ]]

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
}

function ast.new_ns()
    return { by_id = {}, last_id = 1 }
end

function ast.ns_insert_object(ns, id, obj)
    ns.by_id[id] = obj
    if ns.last_id <= id then
        ns.last_id = id + 1
    end
end

function ast.new(ns, type)
    local ret = { type = type }
    ret.id = ns.last_id
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
]]
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

--[[ TODO: figure out if this makes sens, if this is not copy with extra rules, etc. ]]
function ast.ns_import_ast(dst_ns, src_ns, node)

end

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
    
    -- Create the node
    local ret = ast.new(ns, node_type)
    for i, arg in ipairs(args) do
        ret[i] = arg
    end
    
    -- Override id if provided in serialization
    if node_id then
        -- Check if id is already taken
        if ns.by_id[node_id] then
            error("ID " .. tostring(node_id) .. " is already taken in namespace")
        end
        ret.id = node_id
        ns.by_id[ret.id] = ret
        -- Update last_id if this id is beyond current
        if node_id >= ns.last_id then
            ns.last_id = node_id + 1
        end
    end
    
    return ret
end

-- #################################################################################################
-- LaTeX generation
-- #################################################################################################

-- Precedence levels for operators (higher number = higher precedence)
ast.precedence = {
    [ast.NUM] = 100,
    [ast.VAR] = 100,
    [ast.VREF] = 100,
    [ast.CALL] = 100,
    [ast.VEC] = 100,
    [ast.MAT] = 100,
    [ast.CELL] = 100,
    [ast.EXP] = 90,
    [ast.MUL] = 80,
    [ast.DIV] = 80,
    [ast.ADD] = 60,
    [ast.EQ] = 10,
    [ast.INEQ_LESS] = 10,
    [ast.INEQ_LEQ] = 10,
    [ast.INEQ_NEQ] = 10,
    [ast.INEQ_GREATER] = 10,
    [ast.INEQ_GEQ] = 10,
}
local precedence = ast.precedence

-- Helper: wrap LaTeX string in parentheses if needed based on precedence
local function maybe_wrap(ns, node, latex_str, parent_type)
    if parent_type == nil then
        return latex_str
    end
    -- If parent is CELL, it already provides parentheses, so don't wrap
    if parent_type == ast.CELL then
        return latex_str
    end
    local child_prec = precedence[node.type] or 0
    local parent_prec = precedence[parent_type] or 0
    -- Wrap if child has lower precedence than parent
    if child_prec < parent_prec then
        return "(" .. latex_str .. ")"
    end
    return latex_str
end

-- Helper: join child nodes with a delimiter for LaTeX output
local function join_latex(ns, children, delimiter, wrap_start, wrap_end, parent_type)
    wrap_start = wrap_start or ""
    wrap_end = wrap_end or ""
    local parts = {}
    for i, child in ipairs(children) do
        table.insert(parts, ast.to_latex(ns, child, parent_type))
    end
    return wrap_start .. table.concat(parts, delimiter) .. wrap_end
end

-- Map type to LaTeX symbol
local latex_symbols = {
    [ast.EQ] = "=",
    [ast.INEQ_LESS] = "<",
    [ast.INEQ_LEQ] = "\\leq",
    [ast.INEQ_NEQ] = "\\neq",
    [ast.INEQ_GREATER] = ">",
    [ast.INEQ_GEQ] = "\\geq",
    [ast.ADD] = "+",
    [ast.MUL] = "",  -- implicit multiplication in LaTeX
    [ast.DIV] = "/",
    [ast.EXP] = "^",
}

-- Main LaTeX generation function
function ast.to_latex(ns, node, parent_type)
    if type(node) == "number" then
        return tostring(node)
    elseif type(node) == "string" then
        return node
    elseif type(node) == "table" and node.type then
        local symbol = latex_symbols[node.type]
        local result
        
        if node.type == ast.EQ then
            -- (=, a1, a2) -> a1 = a2
            result = ast.to_latex(ns, node[1], node.type) .. " = " ..
                     ast.to_latex(ns, node[2], node.type)
            
        elseif node.type == ast.INEQ_LESS then
            -- (<, a1, a2) -> a1 < a2
            result = ast.to_latex(ns, node[1], node.type) .. " < " ..
                     ast.to_latex(ns, node[2], node.type)
            
        elseif node.type == ast.INEQ_LEQ then
            -- (<=, a1, a2) -> a1 \leq a2
            result = ast.to_latex(ns, node[1], node.type) .. " \\leq " ..
                     ast.to_latex(ns, node[2], node.type)
            
        elseif node.type == ast.INEQ_NEQ then
            -- (!=, a1, a2) -> a1 \neq a2
            result = ast.to_latex(ns, node[1], node.type) .. " \\neq " ..
                     ast.to_latex(ns, node[2], node.type)
            
        elseif node.type == ast.INEQ_GREATER then
            -- (> , a1, a2) -> a1 > a2
            result = ast.to_latex(ns, node[1], node.type) .. " > " ..
                     ast.to_latex(ns, node[2], node.type)
            
        elseif node.type == ast.INEQ_GEQ then
            -- (>=, a1, a2) -> a1 \geq a2
            result = ast.to_latex(ns, node[1], node.type) .. " \\geq " ..
                     ast.to_latex(ns, node[2], node.type)
            
        elseif node.type == ast.NUM then
            -- (N, m, n, sign) -> rational number m/n with sign
            local m = node[1]
            local n = node[2]
            local sign = node[3]
            local abs_result
            if n == 1 then
                abs_result = tostring(m)
            else
                abs_result = "\\frac{" .. tostring(m) .. "}{" .. tostring(n) .. "}"
            end
            if sign == -1 then
                result = "-" .. abs_result
            else
                result = abs_result
            end
            
        elseif node.type == ast.VAR then
            -- (#, name) -> variable name
            result = node[1]
            
        elseif node.type == ast.VREF then
            -- (&, ref_id) -> follow reference and render the referenced node
            local ref_node = ns.by_id[node[1]]
            if ref_node then
                result = ast.to_latex(ns, ref_node, parent_type)
            else
                result = "[ref:" .. tostring(node[1]) .. "]"
            end
            
        elseif node.type == ast.CALL then
            -- (@, fn, a1, a2, ...) -> function call
            local fn = node[1]
            local args = {}
            for i = 2, #node do
                table.insert(args, ast.to_latex(ns, node[i], node.type))
            end
            result = fn .. "(" .. table.concat(args, ", ") .. ")"
            
        elseif node.type == ast.VEC then
            -- (V, a1, a2, ...) -> row vector
            result = "\\begin{pmatrix}" ..
                     join_latex(ns, node, "& ", nil, nil, node.type) ..
                     "\\end{pmatrix"
            
        elseif node.type == ast.MAT then
            -- (M, rows, cols, a1, a2, ...) -> matrix
            local rows = node[1]
            local cols = node[2]
            local elements = {}
            for i = 3, #node do
                table.insert(elements, ast.to_latex(ns, node[i], node.type))
            end
            -- Build matrix with proper row breaks
            local matrix_parts = {}
            for i = 1, rows do
                local row_elements = {}
                for j = 1, cols do
                    local idx = (i-1)*cols + j
                    if elements[idx] then
                        table.insert(row_elements, elements[idx])
                    else
                        table.insert(row_elements, "0")
                    end
                end
                table.insert(matrix_parts, table.concat(row_elements, "& "))
            end
            result = "\\begin{pmatrix}" ..
                     table.concat(matrix_parts, "\\\\") ..
                     "\\end{pmatrix}"
            
        elseif node.type == ast.CELL then
            -- (_, a1) -> parentheses
            result = "(" .. ast.to_latex(ns, node[1], node.type) .. ")"
            
        elseif node.type == ast.DIV then
            -- (/, a1, a2) -> fraction
            result = "\\frac{" .. ast.to_latex(ns, node[1], node.type) ..
                     "}{" .. ast.to_latex(ns, node[2], node.type) .. "}"
            
        elseif node.type == ast.EXP then
            -- (^, base, exponent) -> base^exponent
            result = ast.to_latex(ns, node[1], node.type) ..
                     "^{ " .. ast.to_latex(ns, node[2], node.type) .. " }"
            
        elseif node.type == ast.ADD then
            -- (+, a1, a2, ...) -> a1 + a2 + ...
            result = join_latex(ns, node, " + ", nil, nil, node.type)
            
        elseif node.type == ast.MUL then
            -- (*, a1, a2, ...) -> a1 a2 ... (implicit multiplication)
            result = join_latex(ns, node, " ", nil, nil, node.type)
        else
            -- Default: (symbol, arg1, arg2, ...)
            local op = symbol or type_to_symbol[node.type] or "?"
            local parts = {}
            for i = 1, #node do
                table.insert(parts, ast.to_latex(ns, node[i], node.type))
            end
            result = "(" .. op .. " " .. table.concat(parts, ", ") .. ")"
        end
        
        -- Apply precedence-based wrapping
        if parent_type then
            result = maybe_wrap(ns, node, result, parent_type)
        end
        return result
    else
        error("Cannot generate LaTeX: " .. type(node))
    end
end


return ast

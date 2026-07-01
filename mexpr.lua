-- mexpr.lua - Converts AST nodes to mexpr trees for rendering
-- This module provides functions to convert AST expressions to mexpr format

local vc = require("virt_composer")
local char = require("char")
local ast = require("ast")

-- Create the mexpr module table
local mexpr = {}

-- Helper function to determine if a node needs parentheses based on parent context
-- Returns true if the child node needs wrapping in parentheses when it's a child of parent_type
local function needs_parentheses(child_type, parent_type, precedence)
    if parent_type == nil then
        return false
    end
    -- If parent is CELL, it already provides parentheses, so don't wrap
    if parent_type == ast.CELL then
        return false
    end
    
    local child_prec = precedence[child_type] or 0
    local parent_prec = precedence[parent_type] or 0
    
    -- Wrap if child has lower precedence than parent
    return child_prec < parent_prec
end

-- Helper function to wrap a mexpr in parentheses if needed based on precedence
local function wrap_mexpr_if_needed(fontset, mexpr_node, node_type, parent_type,
        sz, precedence, char_module)
    if needs_parentheses(node_type, parent_type, precedence) then
        return vc.mexpr_bracket(fontset, mexpr_node, char_module.round_bracket(sz))
    else
        return mexpr_node
    end
end

-- Helper: create a symbol mexpr from a character
local function create_symbol_mexpr(fontset, char_spec)
    -- Ensure char_spec is a table with size and code
    if type(char_spec) ~= "table" then
        char_spec = {size=10, code=61}  -- default to 'a'
    end
    if type(char_spec.size) ~= "number" then
        char_spec.size = 10
    end
    if type(char_spec.code) ~= "number" then
        char_spec.code = 61
    end
    return vc.mexpr_symbol(fontset, char_spec, 1)
end

-- Helper function to find character info by ASCII code or description
local function find_char_info(target, sz, char_module)
    for _, c in ipairs(char_module.chars or {}) do
        if c.acod == target and c.ncod then
            return {size=sz, code=c.ncod}
        end
        if c.desc == target and c.ncod then
            return {size=sz, code=c.ncod}
        end
    end
    -- Default to a placeholder if not found
    return {size=sz, code=61}
end

-- Helper function to find character info by description pattern
local function find_char_by_desc(pattern, sz, char_module)
    for _, c in ipairs(char_module.chars or {}) do
        if c.desc and c.desc:match(pattern) and c.ncod then
            return {size=sz, code=c.ncod}
        end
    end
    return {size=sz, code=61} -- default to 'a'
end

-- Default size for characters
local DEFAULT_SIZE = 10

-- Helper function to create a mexpr from a number string
local function create_number_mexpr(fontset, number_str, size, char_module)
    if #number_str == 0 then
        return vc.mexpr_empty(fontset, 10, 10, 0)
    end
    
    local digits = {}
    for i = 1, #number_str do
        local digit_char = number_str:sub(i, i)
        if digit_char == "-" then
            -- Minus sign - create symbol for minus
            table.insert(digits,
                create_symbol_mexpr(fontset, char_module.minus(size)))
        else
            -- Digit
            local char_code = tonumber(digit_char) + 15
            table.insert(digits,
                create_symbol_mexpr(fontset, {size=size, code=char_code}))
        end
    end
    
    -- Merge all digit symbols horizontally
    if #digits == 1 then
        return digits[1]
    else
        local result = digits[1]
        for i = 2, #digits do
            result = vc.mexpr_merge_h(fontset, result, digits[i])
        end
        return result
    end
end

-- Main to_mexpr function: converts AST node to mexpr tree
-- Parameters:
--   fontset - the fontset for creating mexpr symbols
--   ns - the namespace containing the AST nodes
--   node - the AST node to convert
--   parent_type - the type of the parent node (for determining if parentheses are needed)
--   sz - the base font size to use
function mexpr.to_mexpr(fontset, ns, node, parent_type, sz)
    local precedence = ast.precedence
    sz = sz or DEFAULT_SIZE
    
    if type(node) == "number" then
        -- Create a symbol mexpr for the number
        return create_number_mexpr(fontset, tostring(node), sz, char)
    elseif type(node) == "string" then
        -- For string variables, create symbols for each character and merge them
        if #node == 0 then
            return vc.mexpr_empty(fontset, 10, 10, 0)
        elseif #node == 1 then
            -- Single character - find its character code
            local char_info = find_char_info(node, sz, char)
            return create_symbol_mexpr(fontset, char_info)
        else
            -- Multi-character string - merge each character horizontally
            local symbols = {}
            for i = 1, #node do
                local char_str = node:sub(i, i)
                local char_info = find_char_info(char_str, sz, char)
                table.insert(symbols, create_symbol_mexpr(fontset, char_info))
            end
            
            -- Merge all symbols horizontally
            local result = symbols[1]
            for i = 2, #symbols do
                result = vc.mexpr_merge_h(fontset, result, symbols[i])
            end
            return result
        end
    elseif type(node) == "table" and node.type then
        local node_type = node.type
        
        if node_type == ast.NUM then
            -- (N, m, n, sign) - rational number
            local m = node[1]
            local n = node[2]
            local sign = node[3]
            
            -- For simplicity, we'll handle integers and simple fractions
            if n == 1 then
                -- Integer
                local num_str = tostring(m)
                if sign == -1 then
                    num_str = "-" .. num_str
                end
                return create_number_mexpr(fontset, num_str, sz, char)
            else
                -- Fraction - use mexpr_frac
                local numerator_str = tostring(m)
                if sign == -1 then
                    numerator_str = "-" .. numerator_str
                end
                local denominator_str = tostring(n)
                local numerator_mexpr = create_number_mexpr(fontset, numerator_str, sz, char)
                local denominator_mexpr = create_number_mexpr(fontset, denominator_str, sz, char)
                return vc.mexpr_frac(fontset, numerator_mexpr, denominator_mexpr, char.hline_basic(sz))
            end
            
        elseif node_type == ast.VAR then
            -- (#, name) - named variable
            local var_name = node[1]
            -- Create a symbol for the variable name
            local char_info = find_char_info(var_name, sz, char)
            return create_symbol_mexpr(fontset, char_info)
            
        elseif node_type == ast.VREF then
            -- (&, ref_id) - variable reference
            local ref_node = ns.by_id[node[1]]
            if ref_node then
                return wrap_mexpr_if_needed(fontset,
                        mexpr.to_mexpr(fontset, ns, ref_node, parent_type, sz),
                        ref_node.type, parent_type, sz, precedence, char)
            else
                -- Reference not found, return empty mexpr
                return vc.mexpr_empty(fontset, 10, 10, 0)
            end
            
        elseif node_type == ast.CELL then
            -- (_, a1) - parentheses
            local child = node[1]
            local child_mexpr = mexpr.to_mexpr(fontset, ns, child, node_type, sz)
            -- Wrap in brackets (parentheses)
            return vc.mexpr_bracket(fontset, child_mexpr, char.round_bracket(sz))
            
        elseif node_type == ast.EQ then
            -- (=, a1, a2) - equality
            local left = wrap_mexpr_if_needed(fontset,
                    mexpr.to_mexpr(fontset, ns, node[1], node_type, sz),
                    node[1].type, node_type, sz, precedence, char)
            local right = wrap_mexpr_if_needed(fontset,
                    mexpr.to_mexpr(fontset, ns, node[2], node_type, sz),
                    node[2].type, node_type, sz, precedence, char)
            return vc.mexpr_binexpr(fontset, left, char.equal(sz), right)
            
        elseif node_type == ast.INEQ_LESS then
            -- (<, a1, a2) - less than
            local left = wrap_mexpr_if_needed(fontset,
                    mexpr.to_mexpr(fontset, ns, node[1], node_type, sz),
                    node[1].type, node_type, sz, precedence, char)
            local right = wrap_mexpr_if_needed(fontset,
                    mexpr.to_mexpr(fontset, ns, node[2], node_type, sz),
                    node[2].type, node_type, sz, precedence, char)
            return vc.mexpr_binexpr(fontset, left, char.less(sz), right)
            
        elseif node_type == ast.INEQ_LEQ then
            -- (<=, a1, a2) - less than or equal
            local left = wrap_mexpr_if_needed(fontset,
                    mexpr.to_mexpr(fontset, ns, node[1], node_type, sz),
                    node[1].type, node_type, sz, precedence, char)
            local right = wrap_mexpr_if_needed(fontset,
                    mexpr.to_mexpr(fontset, ns, node[2], node_type, sz),
                    node[2].type, node_type, sz, precedence, char)
            return vc.mexpr_binexpr(fontset, left, char.leq(sz), right)
            
        elseif node_type == ast.INEQ_GREATER then
            -- (> , a1, a2) - greater than
            local left = wrap_mexpr_if_needed(fontset,
                    mexpr.to_mexpr(fontset, ns, node[1], node_type, sz),
                    node[1].type, node_type, sz, precedence, char)
            local right = wrap_mexpr_if_needed(fontset,
                    mexpr.to_mexpr(fontset, ns, node[2], node_type, sz),
                    node[2].type, node_type, sz, precedence, char)
            return vc.mexpr_binexpr(fontset, left, char.greater(sz), right)
            
        elseif node_type == ast.INEQ_GEQ then
            -- (>=, a1, a2) - greater than or equal
            local left = wrap_mexpr_if_needed(fontset,
                    mexpr.to_mexpr(fontset, ns, node[1], node_type, sz),
                    node[1].type, node_type, sz, precedence, char)
            local right = wrap_mexpr_if_needed(fontset,
                    mexpr.to_mexpr(fontset, ns, node[2], node_type, sz),
                    node[2].type, node_type, sz, precedence, char)
            return vc.mexpr_binexpr(fontset, left, char.geq(sz), right)
            
        elseif node_type == ast.INEQ_NEQ then
            -- (!=, a1, a2) - not equal
            local left = wrap_mexpr_if_needed(fontset,
                    mexpr.to_mexpr(fontset, ns, node[1], node_type, sz),
                    node[1].type, node_type, sz, precedence, char)
            local right = wrap_mexpr_if_needed(fontset,
                    mexpr.to_mexpr(fontset, ns, node[2], node_type, sz),
                    node[2].type, node_type, sz, precedence, char)
            return vc.mexpr_binexpr(fontset, left, char.neq(sz), right)
            
        elseif node_type == ast.ADD then
            -- (+, a1, a2, ...) - addition
            if #node < 2 then
                return vc.mexpr_empty(fontset, 10, 10, 0)
            end
            -- For multiple operands, we chain them with binexpr
            local result = wrap_mexpr_if_needed(fontset,
                    mexpr.to_mexpr(fontset, ns, node[1], node_type, sz),
                    node[1].type, node_type, sz, precedence, char)
            for i = 2, #node do
                local next_operand = wrap_mexpr_if_needed(fontset,
                        mexpr.to_mexpr(fontset, ns, node[i], node_type, sz),
                        node[i].type, node_type, sz, precedence, char)
                result = vc.mexpr_binexpr(fontset, result, char.plus(sz), next_operand)
            end
            return result
            
        elseif node_type == ast.MUL then
            -- (*, a1, a2, ...) - multiplication
            if #node < 2 then
                return vc.mexpr_empty(fontset, 10, 10, 0)
            end
            local result = wrap_mexpr_if_needed(fontset,
                    mexpr.to_mexpr(fontset, ns, node[1], node_type, sz),
                    node[1].type, node_type, sz, precedence, char)
            for i = 2, #node do
                local next_operand = wrap_mexpr_if_needed(fontset,
                        mexpr.to_mexpr(fontset, ns, node[i], node_type, sz),
                        node[i].type, node_type, sz, precedence, char)
                result = vc.mexpr_binexpr(fontset, result, char.times(sz), next_operand)
            end
            return result
            
        elseif node_type == ast.DIV then
            -- (/, a1, a2) - division (as fraction)
            local numerator = wrap_mexpr_if_needed(fontset,
                    mexpr.to_mexpr(fontset, ns, node[1], node_type, sz),
                    node[1].type, node_type, sz, precedence, char)
            local denominator = wrap_mexpr_if_needed(fontset,
                    mexpr.to_mexpr(fontset, ns, node[2], node_type, sz),
                    node[2].type, node_type, sz, precedence, char)
            return vc.mexpr_frac(fontset, numerator, denominator, char.hline_basic(sz))
            
        elseif node_type == ast.EXP then
            -- (^, base, exponent) - exponentiation
            local base = wrap_mexpr_if_needed(fontset,
                    mexpr.to_mexpr(fontset, ns, node[1], node_type, sz),
                    node[1].type, node_type, sz, precedence, char)
            local exponent = wrap_mexpr_if_needed(fontset,
                    mexpr.to_mexpr(fontset, ns, node[2], node_type, sz - 2),
                    node[2].type, node_type, sz - 2, precedence, char)
            return vc.mexpr_supsub(fontset, base, exponent, nil)
            
        elseif node_type == ast.CALL then
            -- (@, f, a1, a2, ...) - function call
            -- For now, we'll handle this as a simple concatenation
            -- TODO: improve to handle special functions like sum, integral, etc.
            local fn_name = node[1]
            local fn_symbol = nil
            
            -- Check if this is a special function that should use bigop
            if fn_name == "sum" or fn_name == "\\sum" then
                -- Summation - need to handle bounds and expression
                if #node >= 3 then
                    -- Assume format: sum(variable, start, end, expression)
                    local var = wrap_mexpr_if_needed(fontset,
                            mexpr.to_mexpr(fontset, ns, node[2], node_type, sz - 5),
                            node[2].type, node_type, sz - 5, precedence, char)
                    local start = wrap_mexpr_if_needed(fontset,
                            mexpr.to_mexpr(fontset, ns, node[3], node_type, sz - 5),
                            node[3].type, node_type, sz - 5, precedence, char)
                    local stop = wrap_mexpr_if_needed(fontset,
                            mexpr.to_mexpr(fontset, ns, node[4], node_type, sz - 5),
                            node[4].type, node_type, sz - 5, precedence, char)
                    local expr = #node > 4 and
                            wrap_mexpr_if_needed(fontset,
                                    mexpr.to_mexpr(fontset, ns, node[5], node_type, sz),
                                    node[5].type, node_type, sz, precedence, char)
                            or
                            wrap_mexpr_if_needed(fontset,
                                    mexpr.to_mexpr(fontset, ns, node[2], node_type, sz),
                                    node[2].type, node_type, sz, precedence, char)
                    return vc.mexpr_bigop(fontset, expr, var, stop,
                        char.bigsum(math.max(sz-5, 1)))
                else
                    -- Simple sum without bounds
                    local expr = wrap_mexpr_if_needed(fontset,
                            mexpr.to_mexpr(fontset, ns, node[2], node_type, sz),
                            node[2].type, node_type, sz, precedence, char)
                    return vc.mexpr_bigop(fontset, expr, nil, nil, char.bigsum(math.max(sz-5, 1)))
                end
            elseif fn_name == "int" or fn_name == "\\int" then
                -- Integral
                if #node >= 3 then
                    local var = wrap_mexpr_if_needed(fontset,
                            mexpr.to_mexpr(fontset, ns, node[2], node_type, sz - 5),
                            node[2].type, node_type, sz - 5, precedence, char)
                    local start = wrap_mexpr_if_needed(fontset,
                            mexpr.to_mexpr(fontset, ns, node[3], node_type, sz - 5),
                            node[3].type, node_type, sz - 5, precedence, char)
                    local stop = wrap_mexpr_if_needed(fontset,
                            mexpr.to_mexpr(fontset, ns, node[4], node_type, sz - 5),
                            node[4].type, node_type, sz - 5, precedence, char)
                    local expr = #node > 4 and
                            wrap_mexpr_if_needed(fontset,
                                    mexpr.to_mexpr(fontset, ns, node[5], node_type, sz),
                                    node[5].type, node_type, sz, precedence, char)
                            or
                            wrap_mexpr_if_needed(fontset,
                                    mexpr.to_mexpr(fontset, ns, node[2], node_type, sz),
                                    node[2].type, node_type, sz, precedence, char)
                    return vc.mexpr_bigop(fontset, expr, var, stop, char.integral(math.max(sz-5, 1)))
                else
                    -- Simple integral without bounds
                    local expr = wrap_mexpr_if_needed(fontset,
                            mexpr.to_mexpr(fontset, ns, node[2], node_type, sz),
                            node[2].type, node_type, sz, precedence, char)
                    return vc.mexpr_bigop(fontset, expr, nil, nil, char.integral(math.max(sz-5, 1)))
                end
            else
                -- Regular function call - concatenate function name with arguments
                local parts = {}
                -- Find function name character
                local fn_char = find_char_info(fn_name, sz, char)
                -- If not found by acod, try by description
                if fn_char.code == 61 then
                    fn_char = find_char_by_desc(fn_name, sz, char)
                end
                
                table.insert(parts, create_symbol_mexpr(fontset, fn_char))
                
                -- Add arguments
                for i = 2, #node do
                    table.insert(parts,
                        wrap_mexpr_if_needed(fontset,
                            mexpr.to_mexpr(fontset, ns, node[i], node_type, sz),
                            node[i].type, node_type, sz, precedence, char))
                end
                
                -- Merge all parts horizontally
                if #parts == 0 then
                    return vc.mexpr_empty(fontset, 10, 10, 0)
                elseif #parts == 1 then
                    return parts[1]
                else
                    local result = parts[1]
                    for i = 2, #parts do
                        result = vc.mexpr_merge_h(fontset, result, parts[i])
                    end
                    return result
                end
            end
            
        elseif node_type == ast.VEC then
            -- (V, a1, a2, ...) - vector
            -- Create a vertical arrangement of elements
            local elements = {}
            for i = 1, #node do
                table.insert(elements, wrap_mexpr_if_needed(fontset,
                        mexpr.to_mexpr(fontset, ns, node[i], node_type, sz),
                        node[i].type, node_type, sz, precedence, char))
            end
            
            if #elements == 0 then
                return vc.mexpr_empty(fontset, 10, 10, 0)
            elseif #elements == 1 then
                return elements[1]
            else
                local result = elements[1]
                for i = 2, #elements do
                    result = vc.mexpr_merge_v(fontset, result, elements[i])
                end
                -- Wrap in parentheses
                return vc.mexpr_bracket(fontset, result, char.round_bracket(sz))
            end
            
        elseif node_type == ast.MAT then
            -- (M, rows, cols, a1, a2, ...) - matrix
            -- For simplicity, flatten to a vertical arrangement for now
            local rows = node[1]
            local cols = node[2]
            local elements = {}
            for i = 3, #node do
                table.insert(elements, wrap_mexpr_if_needed(fontset,
                        mexpr.to_mexpr(fontset, ns, node[i], node_type, sz),
                        node[i].type, node_type, sz, precedence, char))
            end
            
            if #elements == 0 then
                return vc.mexpr_empty(fontset, 10, 10, 0)
            elseif #elements == 1 then
                return elements[1]
            else
                -- Create rows
                local matrix_rows = {}
                for i = 1, rows do
                    local row_elements = {}
                    for j = 1, cols do
                        local idx = (i-1)*cols + j
                        if elements[idx] then
                            table.insert(row_elements, elements[idx])
                        end
                    end
                    if #row_elements > 0 then
                        local row = row_elements[1]
                        for j = 2, #row_elements do
                            row = vc.mexpr_merge_h(fontset, row, row_elements[j])
                        end
                        table.insert(matrix_rows, row)
                    end
                end
                
                -- Merge rows vertically
                if #matrix_rows == 0 then
                    return vc.mexpr_empty(fontset, 10, 10, 0)
                elseif #matrix_rows == 1 then
                    return matrix_rows[1]
                else
                    local result = matrix_rows[1]
                    for i = 2, #matrix_rows do
                        result = vc.mexpr_merge_v(fontset, result,
                            matrix_rows[i])
                    end
                    -- Wrap in brackets
                    return vc.mexpr_bracket(fontset, result,
                        char.round_bracket(sz))
                end
            end
        else
            -- Unknown node type, return empty mexpr
            return vc.mexpr_empty(fontset, 10, 10, 0)
        end
    else
        error("Cannot generate mexpr: " .. type(node))
    end
end

return mexpr

local vc = require("virt_composer")
local char = require("char")
local ast = require("ast")

local fontset = nil

function test_init()
    fontset = char.load_font_set(42)
end

--[[ TODO: Add imports into code ]]
--[[ TODO: Add the ast into this and make functions that will let us draw the ast ]]
--[[ TODO: Figure out where this drawing will stay in conjunction with the drawing spaces ]]

local increment = 1
local i = 0
function test_draw()
    local ns = ast.new_ns()
    local a = ast.new_var(ns, "a")
    local node = ast.new_eq(ns,
        ast.new_vref(ns, a),
        ast.new_add(ns,
            ast.new_num(ns, 10, 1, 1),
            ast.new_num(ns, -10, 1, 1)
        )
    )
    print(ast.to_string(ns, node), ast.to_latex(ns, node))
    local b = ast.new_var(ns, "b")
    local c = ast.new_var(ns, "c")
    local bc = ast.new_mul(ns, ast.new_vref(ns, b), ast.new_vref(ns, c))
    local aIab_ac_bcI = ast.new_mul(ns,
        ast.new_vref(ns, a),
        ast.new_add(ns,
            ast.new_mul(ns, ast.new_vref(ns, a), ast.new_vref(ns, b)),
            ast.new_mul(ns, ast.new_vref(ns, a), ast.new_vref(ns, c)),
            bc
        )
    )
    print(ast.to_string(ns, aIab_ac_bcI), ast.to_latex(ns, aIab_ac_bcI))

    -- transforms.initial_traverse(aIab_ac_bcI)
    -- local found_bc = transforms.find(aIab_ac_bcI, bc.id)
    -- if found_bc ~= bc then
    --     error("HUH?")
    -- end

    if i == 10 then
        increment = increment + 1
        if increment > 248 then
            increment = 1
        end
        i = 0
    end
    i = i + 1

    local c = char.chars[increment]
    -- print(c.desc)
    char.draw_char(fontset, c, 0, 0)
end

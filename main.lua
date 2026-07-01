local vc = require("virt_composer")
local char = require("char")
local ast = require("ast")
local mexpr = require("mexpr")

local fontset = nil

function test_init()
    fontset = char.load_font_set()
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
    -- print(ast.to_latex(ns, node))

    
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

    local mexpr_root = mexpr.to_mexpr(fontset, ns, aIab_ac_bcI, nil, 10)
    if mexpr_root then
        vc.mexpr_draw(fontset, {x=100, y=500}, mexpr_root, 0)
    else
        print("FAIL")
    end
    -- print(ast.to_latex(ns, aIab_ac_bcI))
    -- print(ast.to_string(ns, aIab_ac_bcI), ast.to_latex(ns, aIab_ac_bcI))

    -- transforms.initial_traverse(aIab_ac_bcI)
    -- local found_bc = transforms.find(aIab_ac_bcI, bc.id)
    -- if found_bc ~= bc then
    --     error("HUH?")
    -- end

    local sz = 10
    local a = vc.mexpr_symbol(fontset, {size=sz, code=61}, 1)
    local b = vc.mexpr_symbol(fontset, {size=sz, code=62}, 1)
    local c = vc.mexpr_symbol(fontset, {size=sz, code=63}, 1)
    local d = vc.mexpr_symbol(fontset, {size=sz, code=64}, 1)
    local _a = vc.mexpr_symbol(fontset, {size=sz+1, code=61}, 1)
    local _b = vc.mexpr_symbol(fontset, {size=sz+1, code=62}, 1)
    local _c = vc.mexpr_symbol(fontset, {size=sz+1, code=63}, 1)
    local _d = vc.mexpr_symbol(fontset, {size=sz+1, code=64}, 1)
    local sub = vc.mexpr_supsub(fontset, a, nil, _a)
    local sup = vc.mexpr_supsub(fontset, b, _b, nil)
    local subp = vc.mexpr_supsub(fontset, c, _a, _b)
    local a_b = vc.mexpr_binexpr(fontset, a, char.plus(sz), sub)
    local a_b_c = vc.mexpr_binexpr(fontset, a_b, char.minus(sz), sup)
    local a_b_c_d = vc.mexpr_binexpr(fontset, a_b_c, char.plus(sz), subp)
    -- TODO: fix fractions
    -- local frac = vc.mexpr_frac(fontset, a_b_c_d, a_b_c, char.hline_basic(sz))
    local int = vc.mexpr_bigop(fontset, a_b_c_d, a, b, char.integral(math.max(sz-5, 1)))
    local sum = vc.mexpr_bigop(fontset, a_b_c_d, a, b, char.bigsum(math.max(sz-5, 1)))
    local brack1 = vc.mexpr_bracket(fontset, int, char.round_bracket(sz))
    local brack2 = vc.mexpr_bracket(fontset, sum, char.round_bracket(sz))
    local sum_brack = vc.mexpr_binexpr(fontset, brack1, char.plus(sz), brack2)
    local brack3 = vc.mexpr_bracket(fontset, sum_brack, char.square_bracket(sz))
    -- vc.mexpr_draw(fontset, {x=100, y=100}, brack3, 0)

    --[[ OBS: bigops need to be around 4-5 fonts bigger ]]
    --[[ OBS: brackets need to be around 2 fonts bigger ]]

    local sz = 10
    local box = vc.mexpr_empty(fontset, 50, 100, 20);
    local a = vc.mexpr_symbol(fontset, {size=sz, code=61}, 1)
    local b = vc.mexpr_symbol(fontset, {size=sz, code=62}, 1)
    local _a = vc.mexpr_symbol(fontset, {size=sz+1, code=61}, 1)
    local _b = vc.mexpr_symbol(fontset, {size=sz+1, code=62}, 1)
    local g = vc.mexpr_symbol(fontset, {size=sz, code=67}, 1)
    -- local intsym = vc.mexpr_symbol(fontset, char.integral(sz), 0)
    local sum = vc.mexpr_bigop(fontset, a, b, g, char.bigsum(sz-5))
    local int = vc.mexpr_bigop(fontset, a, b, g, char.integral(sz-5))
    local exp = vc.mexpr_supsub(fontset, a, _a, _b)
    local exp2 = vc.mexpr_supsub(fontset, a, _b, nil)
    local unar_op = vc.mexpr_unarexpr(fontset, char.minus(sz), exp)
    local binexpr = vc.mexpr_binexpr(fontset, unar_op, char.plus(sz), int)
    local frac = vc.mexpr_frac(fontset, sum, binexpr, char.hline_basic(sz))
    local frac2 = vc.mexpr_frac(fontset, exp2, frac, char.hline_basic(sz))
    local bin2 = vc.mexpr_binexpr(fontset, frac2, char.plus(sz), int)
    local hmerge = vc.mexpr_merge_h(fontset, a, b)
    local vmerge = vc.mexpr_merge_v(fontset, a, sum)
    local _char = vc.mexpr_symbol(fontset, char.minus(sz), 1)
    local brack1 = vc.mexpr_bracket(fontset, _char, char.square_bracket(sz-2))
    local brack2 = vc.mexpr_bracket(fontset, a, char.square_bracket(sz-2))
    local brack3 = vc.mexpr_bracket(fontset, exp2, char.square_bracket(sz-2))
    local brack4 = vc.mexpr_bracket(fontset, exp, char.square_bracket(sz-2))
    local brack5 = vc.mexpr_bracket(fontset, bin2, char.square_bracket(sz-2))
    local brack6 = vc.mexpr_bracket(fontset, _char, char.round_bracket(sz-2))
    local brack7 = vc.mexpr_bracket(fontset, a, char.round_bracket(sz-2))
    local brack8 = vc.mexpr_bracket(fontset, exp2, char.round_bracket(sz-2))
    local brack9 = vc.mexpr_bracket(fontset, exp, char.round_bracket(sz-2))
    local brack10 = vc.mexpr_bracket(fontset, bin2, char.round_bracket(sz-2))
    local brack11 = vc.mexpr_bracket(fontset, _char, char.curly_bracket(sz-2))
    local brack12 = vc.mexpr_bracket(fontset, a, char.curly_bracket(sz-2))
    local brack13 = vc.mexpr_bracket(fontset, exp2, char.curly_bracket(sz-2))
    local brack14 = vc.mexpr_bracket(fontset, exp, char.curly_bracket(sz-2))
    local brack15 = vc.mexpr_bracket(fontset, bin2, char.curly_bracket(sz-2))
    local bin3 = vc.mexpr_binexpr(fontset, brack5, char.plus(sz), sum)
    local bin4 = vc.mexpr_binexpr(fontset, brack10, char.plus(sz), sum)
    local bin5 = vc.mexpr_binexpr(fontset, brack15, char.plus(sz), sum)
    local bin6 = vc.mexpr_binexpr(fontset, bin3, char.plus(sz), bin4)
    local bin7 = vc.mexpr_binexpr(fontset, bin6, char.plus(sz), bin5)
    local bin8 = vc.mexpr_binexpr(fontset, bin7, char.plus(sz), bin7)
    -- vc.mexpr_draw(fontset, {x=100, y=300}, bin8, 0)


    -- fontset:char_draw(char.square_bracket(sz-2).left[1], {x=100, y=100},
    --     0xffffffff, 1, 0xffff00ff)
end

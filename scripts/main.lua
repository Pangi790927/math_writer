package.path = package.path .. ";./scripts/?.lua"

local vc = require("virt_composer")
local char = require("char")
local ast = require("ast")
local mexpr = require("mexpr")
local editor = require("editor")
local content = require("content")
local input_recorder = require("input_recorder")
local prof = require("prof")

local fontset = nil
local content_state = nil

local SAVE_PATH = "math_writer.save"

--[[ Whole-file read via Lua's own io library (enabled per-project in the makefiles -
VIRT_COMPOSER_ENABLE_LUA_IO - rather than a custom C++ binding, since io.* already does exactly
this). Returns nil, not an error, when the file doesn't exist yet - the very first run, or one
after the save was deleted. ]]
local function read_file(path)
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local text = f:read("*a")
    f:close()
    return text
end

local function write_file(path, text)
    local f = io.open(path, "wb")
    if not f then
        return
    end
    f:write(text)
    f:close()
end

--[[ Generational GC rather than Lua's default incremental collector.

Measured 2026-09-05, same scenario three times (type into a formula, then eight Ctrl+Shift+Right
selections, then idle), counting frames whose WORK exceeded 25ms:

    incremental (default)   63 spikes
    collectgarbage("stop")   3
    generational             3

The 63 were a ~50ms stall arriving every ~20 frames like clockwork, landing in a different scope
each time and continuing long after input had stopped and the app was idle - the signature of a
collector pause, not of any function. Stopping the GC confirmed it and generational mode fixes it
without the leak, by doing many small collections of young objects instead of occasionally walking
everything. This app allocates a short-lived table for practically every drawing call ({x=,y=} per
AddText/AddRect/AddLine) and per mexpru.u() access, which is precisely the churn generational mode
is designed for: almost all of it dies within the frame that made it.

The 3 that survive in every mode are real work, not GC - structural edits, where mformula.clone()
snapshots the tree for undo (~19-33ms). Those are the next thing to look at, and they are visible
now only because this noise is gone. ]]
collectgarbage("generational")

function test_init()
    fontset = char.load_font_set()
    local saved = read_file(SAVE_PATH)
    -- content.new()'s own single-empty-box default is exactly the right fallback when there's
    -- nothing to load yet - not a special case.
    content_state = saved and content.deserialize(saved, fontset) or content.new()
    input_recorder.init()
end

--[[ input_recorder.poll() runs UNCONDITIONALLY, first, before the real per-frame logic - so
whatever the user just did is already flushed to disk even if it goes on to error out below in this
SAME frame (input_recorder.lua's own top comment). The real logic is wrapped in its own pcall so a
Lua exception here gets logged (frame number + every recent action already on disk, plus the error
message itself) instead of just vanishing into virt_composer's own C++-side DBG log - see that
file's own comment on why this doesn't (and can't) prevent whatever the process does about the error
itself, only makes it inspectable afterward. ]]
function test_draw()
    prof.begin("lua.input_recorder.poll")
    input_recorder.poll()
    prof.stop("lua.input_recorder.poll")
    local ok, err = pcall(function()
        prof.begin("lua.handle_input")
        content.handle_input(content_state, fontset, {x=20, y=30})
        prof.stop("lua.handle_input")
        prof.begin("lua.draw")
        content.draw(content_state, fontset, {x=20, y=30})
        prof.stop("lua.draw")
    end)
    if not ok then
        input_recorder.log_error(err)
    end
end

--[[ Called once, after the main loop exits but before the window actually closes (see main.cpp) -
writes every box's content back out in the same $$LaTeX$$ format Ctrl+C already uses, so the file
this produces is exactly what "select all, copy" across every box would have given you. ]]
function test_shutdown()
    write_file(SAVE_PATH, content.serialize(content_state))
    -- Flush and close the flight recorder explicitly rather than leaving it to the Lua state's own
    -- teardown to finalize the file handle (input_recorder.close()'s own comment).
    input_recorder.close()
end

--[[ TODO: Add the ast into this and make functions that will let us draw the ast ]]
--[[ TODO: Figure out where this drawing will stay in conjunction with the drawing spaces ]]

-- Kept as a reference for the mexpr_* API, not called by default anymore - see editor.lua for
-- the live, typeable canvas.
--
-- TODO (2026-09-04): vc.mexpr_bracket() is GONE - math_expr_composer.h split it into
-- vc.mexpr_bracket_left(fs, expr, opts)/vc.mexpr_bracket_right(fs, expr, opts), each just its own
-- glyph-like leaf sized to fit `expr` (no more single call gluing brackets+expr into one container -
-- see the header's own comment on why: entangled-bracket editing in mformula_new.lua needs the two
-- sides as independent, separately-placeable siblings). Every brack1..brack15 call below (and the
-- vc.mexpr_bracket calls in mexpr.lua's to_mexpr()) still uses the OLD signature and will fail if
-- this function - or anything reaching mexpr.lua's bracket-touching branches - is ever actually
-- called again; left as-is for now (dead code, not on any currently-reachable path - confirmed
-- 2026-09-04) rather than patched, since the real work right now is mformula_new.lua's own
-- entangled-bracket support, not this reference demo. Fix this (or just delete it, if by then
-- nothing still wants it as an mexpr_* API reference) whenever this file's own bracket calls
-- actually need to run again.
local increment = 1
local i = 0
local function demo_draw()
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
        vc.mexpr_draw(fontset, {x=100, y=500}, mexpr_root, false, math.huge)
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
    local a = vc.mexpr_symbol(fontset, {size=sz, code=61}, true)
    local b = vc.mexpr_symbol(fontset, {size=sz, code=62}, true)
    local c = vc.mexpr_symbol(fontset, {size=sz, code=63}, true)
    local d = vc.mexpr_symbol(fontset, {size=sz, code=64}, true)
    local _a = vc.mexpr_symbol(fontset, {size=sz+1, code=61}, true)
    local _b = vc.mexpr_symbol(fontset, {size=sz+1, code=62}, true)
    local _c = vc.mexpr_symbol(fontset, {size=sz+1, code=63}, true)
    local _d = vc.mexpr_symbol(fontset, {size=sz+1, code=64}, true)
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
    -- vc.mexpr_draw(fontset, {x=100, y=100}, brack3, false)

    --[[ OBS: bigops need to be around 4-5 fonts bigger ]]
    --[[ OBS: brackets need to be around 2 fonts bigger ]]

    local sz = 10
    local box = vc.mexpr_empty(fontset, 50, 100, 20);
    local a = vc.mexpr_symbol(fontset, {size=sz, code=61}, true)
    local b = vc.mexpr_symbol(fontset, {size=sz, code=62}, true)
    local _a = vc.mexpr_symbol(fontset, {size=sz+1, code=61}, true)
    local _b = vc.mexpr_symbol(fontset, {size=sz+1, code=62}, true)
    local g = vc.mexpr_symbol(fontset, {size=sz, code=67}, true)
    -- local intsym = vc.mexpr_symbol(fontset, char.integral(sz), false)
    local sum = vc.mexpr_bigop(fontset, a, b, g, char.bigsum(sz-5))
    local int = vc.mexpr_bigop(fontset, a, b, g, char.integral(sz-5))
    local exp = vc.mexpr_supsub(fontset, a, _a, _b)
    local exp2 = vc.mexpr_supsub(fontset, a, _b, nil)
    local unar_op = vc.mexpr_unarexpr(fontset, char.minus(sz), exp)
    local binexpr = vc.mexpr_binexpr(fontset, unar_op, char.plus(sz), int)
    local frac = vc.mexpr_frac(fontset, sum, binexpr, char.hline_basic(sz))
    local frac2 = vc.mexpr_frac(fontset, exp2, frac, char.hline_basic(sz))
    local bin2 = vc.mexpr_binexpr(fontset, frac2, char.plus(sz), int)
    local hmerge = vc.mexpr_merge_h(fontset, {a, b})
    local vmerge = vc.mexpr_merge_v(fontset, {a, sum})
    local _char = vc.mexpr_symbol(fontset, char.minus(sz), true)
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
    -- vc.mexpr_draw(fontset, {x=100, y=300}, bin8, false)


    -- fontset:char_draw(char.square_bracket(sz-2).left[1], {x=100, y=100},
    --     0xffffffff, 1, 0xffff00ff)
end

--[[ ==================================== WHAT THIS FILE OFFERS ====================================
NOTHING. This is the application's entry script, not a module: it returns no table and nothing
requires it. virt_composer loads it as `main_script` (see math_writer.yaml) and calls the globals
below, which are the interface - to the C++ side rather than to any Lua caller.

    test_init()     builds the fontset and the content state, and reads the document back along
                    with the three config files. main.cpp:178 calls it.
    test_draw()     one frame: input, then drawing. Called every frame; main.cpp keeps running
                    when it throws, so Ctrl+Q still works while it is erroring.
    test_shutdown() saves the document and the config on the way out. Runs before a Ctrl+R reload
                    too, which is how the reloaded instance opens on what was on screen.

It also owns the SAVE PATHS. math_writer.save, keymap.save, glyphmap.save and transforms.save are
concatenated here from vc.app_data_prefix(), so a --test instance writes them all under test_run/
and cannot touch the presentation instance's files. A module that needs persisting hands main.lua
text through serialize/deserialize rather than opening a file itself.
@date 2026-09-12 03:25
================================================================================================= ]]

package.path = package.path .. ";./scripts/?.lua"

local vc = require("virt_composer")
local char = require("char")
local ast = require("ast")
local content = require("content")
local input_recorder = require("input_recorder")
local keymap = require("keymap")
local glyphmap = require("glyphmap")
local prof = require("prof")
local transforms = require("transforms")

local fontset = nil
local content_state = nil

--[[ Prefixed by app_mode.h: "" in presentation mode, "test_run/" under --test. A testing instance
must never touch the real document - before this existed, a headless run would overwrite
math_writer.save with whatever the test had typed, and nearly every run had to be followed by a
`git checkout --` to rescue it (2026-09-05). Falls back to no prefix if app_mode was not registered,
so a harness that only loads part of the app still works.
@date 2026-09-08 08:45 ]]
local DATA_PREFIX = (vc.app_data_prefix and vc.app_data_prefix()) or ""
local SAVE_PATH = DATA_PREFIX .. "math_writer.save"
--[[ The keymap lives in its own file, NOT inside math_writer.save. It is configuration, not
document: a .save copied to somebody else, or checked in, should not drag one person's keyboard
habits along with it. Same DATA_PREFIX, so a --test instance writes test_run/keymap.save and cannot
touch the real one.
@date 2026-09-08 08:45 ]]
local KEYMAP_PATH = DATA_PREFIX .. "keymap.save"
--[[ The letter map, in its own file beside the keymap for the same reason the keymap is beside the
document: it is configuration, and a keymap and a glyph map are separately useful - someone may
want one and not the other, and merging them would mean a change to either rewriting both.
@date 2026-09-08 08:45 ]]
local GLYPHMAP_PATH = DATA_PREFIX .. "glyphmap.save"
--[[ Which transformations are switched on, in its own file for the same reason the keymap is in
one: it is configuration, not document. Same DATA_PREFIX, so a --test instance writes
test_run/transforms.save and can never touch the presentation instance's plugin list.

It holds only DIVERGENCES from each plugin's declared default, so the file is usually absent or
short, and it can never bring a transformation into existence - the folder scan decides what exists,
this only decides which of those run.
@date 2026-09-12 02:40 ]]
local TRANSFORMS_PATH = DATA_PREFIX .. "transforms.save"

--[[ Whole-file read via Lua's own io library (enabled per-project in the makefiles -
VIRT_COMPOSER_ENABLE_LUA_IO - rather than a custom C++ binding, since io.* already does exactly
this). Returns nil, not an error, when the file doesn't exist yet - the very first run, or one
after the save was deleted.
@date 2026-09-08 08:45 ]]
local function read_file(path)
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local text = f:read("*a")
    f:close()
    return text
end

--[[ Whole-file write, and silently a no-op if the path cannot be opened: a save that fails must
not take the app down with it, and the flight recorder next to every call site is what makes the
failure visible afterwards. @date 2026-09-08 08:45 ]]
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

--[[ Lets mformula_new report a recovered dangling cursor into the flight recorder without
requiring input_recorder itself (that would be a require cycle through char/prof). ]]
if mformula_new_warn_sink == nil then
    local ok, mf = pcall(require, "mformula_new")
    if ok and mf.set_warn_sink then
        mf.set_warn_sink(function(msg) input_recorder.log_event("WARN " .. msg) end)
    end
    mformula_new_warn_sink = true
end

--[[ Called ONCE by main.cpp before the first frame: builds the fonts, loads the document, and
loads the two configuration files beside it.

Every load is optional. A missing or unreadable file is a normal first run - the document falls
back to content.new()'s single empty box, and the keymap and glyph map to their factory tables -
so nothing here is a special case that has to be spelled out at each site. Both configurations are
marked clean afterwards, because loading is not an edit and must not make the app write them back.
@date 2026-09-08 08:45 ]]
function test_init()
    fontset = char.load_font_set()
    local saved = read_file(SAVE_PATH)
    -- content.new()'s own single-empty-box default is exactly the right fallback when there's
    -- nothing to load yet - not a special case.
    content_state = saved and content.deserialize(saved, fontset) or content.new()
    --[[ Before content.new() would matter either way, but read here rather than at require() time
    so a missing or unreadable file is a normal empty start rather than something that happens
    while keymap.lua is still loading. deserialize() begins from a fresh set of defaults, so an
    action the file no longer mentions goes back to factory rather than keeping a stale value. ]]
    local km = read_file(KEYMAP_PATH)
    if km then
        keymap.deserialize(km, function(msg) input_recorder.log_event(msg) end)
    end
    keymap.clear_dirty()
    local gm = read_file(GLYPHMAP_PATH)
    if gm then
        glyphmap.deserialize(gm, function(msg) input_recorder.log_event(msg) end)
    end
    --[[ After the plugins have been found - requiring transforms.lua ran the folder scan - because
    this only flips flags on what that scan registered. A line naming a plugin that is no longer in
    the folder is skipped rather than failing the file. ]]
    local tr = read_file(TRANSFORMS_PATH)
    if tr then
        local applied, skipped = transforms.load(tr)
        input_recorder.log_event("transforms: " .. applied .. " set, " .. skipped .. " unknown")
    end
    glyphmap.clear_dirty()
    input_recorder.init()
end

--[[ Writes the whole document to SAVE_PATH. The ONE place that does - Ctrl+S below and
test_shutdown() both come through here, so an explicit save and an exit-save can never write
different things or drift apart as the format changes.
@date 2026-09-08 08:45 ]]
local function save_document()
    write_file(SAVE_PATH, content.serialize(content_state))
    -- Goes in the flight recorder too: a save is a real user action, and when reading a session
    -- log back it matters whether a save happened before whatever came next.
    input_recorder.log_event("saved " .. SAVE_PATH)
end

--[[ ONE FRAME, called by main.cpp: poll the recorder, then run the app inside a pcall.

input_recorder.poll() runs UNCONDITIONALLY and FIRST, so whatever was just typed is already on disk
even if this same frame goes on to throw. The rest is wrapped in its own pcall, so a Lua error is
logged - frame number, the recent actions already written, and the message - instead of vanishing
into virt_composer's C++-side log. That does not, and cannot, decide what the process does about
the error; it only makes it inspectable afterwards.
@date 2026-09-08 08:45 ]]
function test_draw()
    prof.begin("lua.input_recorder.poll")
    input_recorder.poll()
    prof.stop("lua.input_recorder.poll")

    --[[ Must run before the first keymap.pressed() of the frame: keymap caches the Ctrl/Shift/Alt
    state for one frame (it is asked dozens of times per frame and each answer is a C++ round trip)
    and this is what tells it the frame turned over. Here rather than inside keymap itself because
    only this file knows where a frame begins. ]]
    keymap.begin_frame()

    --[[ doc.save (Ctrl+S) - handled HERE rather than in content.lua because this is where SAVE_PATH,
    write_file() and content_state all live, and where the exit-save already happens; routing it
    through content.lua would mean handing that file a save callback for one keybinding.

    Before content.handle_input(), but NOT consuming the key: nothing downstream binds Ctrl+S (the
    editor's Ctrl set is A/C/X/V/Z/M//,= and the plain-typing path filters codepoints below 32, so
    Ctrl+S never reaches it as text), and Alt+S is sigma, which is a different modifier entirely.

    Goes through keymap now rather than polling ImGui directly, so the binding is customisable
    (keymap.lua's own header). keymap resolves the key id once at load for the same reason the old
    code used an integer constant here - see char.lua's greek_key_ids comment (180us vs 0.22us). ]]
    if keymap.pressed("doc.save") then
        save_document()
    end

    --[[ Write the keymap when it has changed AND the customiser is closed - ruled 2026-09-07,
    "on any change the settings should be saved when the f2 pannel closes". Watching the two
    conditions here rather than taking a callback from content.lua keeps every file path in this
    one file, the same reason Ctrl+S is handled here.

    Checked BEFORE the pcall below, so a keymap edit is safely on disk even if the very next frame
    of editing throws. keymap.dirty() is cleared by the write, so this costs one comparison per
    frame in the normal case. ]]
    if not content.customiser_open(content_state) then
        if keymap.dirty() then
            write_file(KEYMAP_PATH, keymap.serialize())
            keymap.clear_dirty()
            input_recorder.log_event("saved " .. KEYMAP_PATH)
        end
        -- Same rule, same moment, separate file: written only once the customiser is closed, so a
        -- half-typed glyph name never reaches disk.
        if glyphmap.dirty() then
            write_file(GLYPHMAP_PATH, glyphmap.serialize())
            glyphmap.clear_dirty()
            input_recorder.log_event("saved " .. GLYPHMAP_PATH)
        end
        -- Third file, same rule and same moment: the plugin list is edited in the same panel.
        if transforms.dirty() then
            write_file(TRANSFORMS_PATH, transforms.serialize())
            transforms.clear_dirty()
            input_recorder.log_event("saved " .. TRANSFORMS_PATH)
        end
    end

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
this produces is exactly what "select all, copy" across every box would have given you.
@date 2026-09-08 08:45 ]]
function test_shutdown()
    save_document()
    -- Flush and close the flight recorder explicitly rather than leaving it to the Lua state's own
    -- teardown to finalize the file handle (input_recorder.close()'s own comment).
    input_recorder.close()
end

--[[ TODO: Add the ast into this and make functions that will let us draw the ast ]]
--[[ TODO: Figure out where this drawing will stay in conjunction with the drawing spaces ]]

--[[ WORKED EXAMPLES, KEPT AS TEXT. Nothing calls this and nothing can: it is here to show how an
ast is built with ast.new_* and what the raw vc.mexpr_* calls look like beside each other. The live,
typeable canvas is editor.lua and the editors above it.

IT NO LONGER COMPILES AS BEHAVIOUR, on purpose, and the reader has to expect that:

  - vc.mexpr_bracket() is GONE (2026-09-04). math_expr_composer.h split it into
    vc.mexpr_bracket_left(fs, expr, opts)/vc.mexpr_bracket_right(fs, expr, opts), each its own
    glyph-like leaf sized to fit `expr`, because entangled-bracket editing in mformula_new.lua
    needs the two sides as independent, separately-placeable siblings. Every brack1..brack15 call
    below still passes the old shape.
  - char.plus/minus/bigsum/integral were deleted 2026-09-09 as unused; this was their last caller.
  - mexpr.lua (ast -> mexpr) was deleted the same day, so the drawing step this used to end with
    is gone too - what survives builds the ast and stops there.

Read it for the SHAPE of the calls, never as something to run. Anyone reviving it is writing new
code against today's API, not repairing this.
@date 2026-09-09 21:20 ]]
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

    -- print(ast.to_string(ns, aIab_ac_bcI))

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
    -- The operand is no longer part of the node - it follows the operator in a row.
    local int_c = char.integral(math.max(sz-5, 1))
    local sum_c = char.bigsum(math.max(sz-5, 1))
    local int = vc.mexpr_merge_h(fontset, {
            vc.mexpr_supsub(fontset, vc.mexpr_symbol(fontset, int_c, false), a, b, int_c, 1, 1), a_b_c_d})
    local sum = vc.mexpr_merge_h(fontset, {
            vc.mexpr_supsub(fontset, vc.mexpr_symbol(fontset, sum_c, false), a, b, sum_c, 1, 1), a_b_c_d})
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
    local sum_c2, int_c2 = char.bigsum(sz-5), char.integral(sz-5)
    local sum = vc.mexpr_merge_h(fontset, {
            vc.mexpr_supsub(fontset, vc.mexpr_symbol(fontset, sum_c2, false), b, g, sum_c2, 1, 1), a})
    local int = vc.mexpr_merge_h(fontset, {
            vc.mexpr_supsub(fontset, vc.mexpr_symbol(fontset, int_c2, false), b, g, int_c2, 1, 1), a})
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

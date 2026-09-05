--[[
mformula_latex.lua - LaTeX-subset serialization for mformula_new's mexpr_t-based tree: to_latex()
(mexpr_t -> string) and from_latex() (string -> a fresh mformula_new-shaped container). Split out
of mformula_new.lua into its own file (2026-09-04) so that file stays focused on the live editor
itself; this one only ever needs the same handful of mexpru builders and read-only tree walking,
not any of mformula_new's own editing/navigation state.

Deliberately self-sufficient - no require("mformula_new") here (that would make a require() cycle,
since mformula_new.lua requires THIS file to re-export to_latex/from_latex - see the bottom of that
file). A couple of small things (SUB_SIZE_DELTA/MAX_SIZE_INDEX, is_horiz()/is_supsub(),
build_empty_atom() and its own min_extent()/baseline_correction() dependencies) are therefore
duplicated here rather than imported - the same small-duplication-over-cross-module-coupling
tradeoff mformula.lua (the OLD editor) and mformula_new.lua already independently make for their
own copies of SUB_SIZE_DELTA/MAX_SIZE_INDEX.

Mirrors mformula.lua's own row_to_latex()/parse_latex_row(), adapted to walk mexpr_t/mexpru "kind"
tags directly (horiz/supsub/frac/atom - see mformula_new.lua's own top comment) instead of an items
table. \frac{num}{den} is a real, round-tripping node kind here (2026-09-04) - see mexpru.frac()'s
own comment for the model (num/den always both present, rendered at the surrounding text's own
size, no shrinking the way sup/sub's do).
]]

local vc = require("virt_composer")
local char = require("char")
local mexpru = require("mexpru")

local mformula_latex = {}

local SUB_SIZE_DELTA = 1
-- Defers to mexpru's own canonical copy (2026-09-04's Ctrl+MouseWheel zoom levels).
local MAX_SIZE_INDEX = mexpru.MAX_SIZE_INDEX

-- "(" / "[" and ")" / "]" - mirrors mformula_new.lua's own OPEN_BRACKETS/CLOSE_BRACKETS (2026-09-05,
-- own small copy here rather than a require() - this file's own top comment on staying self-
-- sufficient). Curly braces are deliberately NOT here - "{"/"}" are ALWAYS structural in this
-- parser (group delimiters for ^{...}/_{...}/\frac{...}{...} - parse_latex_children() itself stops
-- at a bare "}"), never a literal glyph, so a curly MATH bracket can't round-trip through this
-- LaTeX subset at all - a pre-existing, separate gap from the one this fixes.
local OPEN_BRACKETS = { ["("] = vc.MEXPR_BRACKET_ROUND, ["["] = vc.MEXPR_BRACKET_SQUARE }
local CLOSE_BRACKETS = { [")"] = vc.MEXPR_BRACKET_ROUND, ["]"] = vc.MEXPR_BRACKET_SQUARE }

-- The reverse direction, for node_to_latex() below - curly included here (unlike the two tables
-- above, which drive PARSING, where "{"/"}" are always structural group delimiters in this subset
-- and so can never be read back as content): a curly bracket atom that already exists in a tree
-- still has to serialize as SOMETHING, and latex_escape_char() turns it into "\{" / "\}", which
-- the parser does read back as a literal typed brace (just an unpaired plain glyph, same as it
-- already treats any brace).
local OPEN_BRACKET_ASCII = {
    [vc.MEXPR_BRACKET_ROUND] = "(", [vc.MEXPR_BRACKET_SQUARE] = "[", [vc.MEXPR_BRACKET_CURLY] = "{",
}
local CLOSE_BRACKET_ASCII = {
    [vc.MEXPR_BRACKET_ROUND] = ")", [vc.MEXPR_BRACKET_SQUARE] = "]", [vc.MEXPR_BRACKET_CURLY] = "}",
}

local function is_horiz(node)
    return mexpru.u(node).kind == "horiz"
end

local function is_supsub(node)
    return mexpru.u(node).kind == "supsub"
end

local function is_frac(node)
    return mexpru.u(node).kind == "frac"
end

local baseline_correction_cache = {}
local function baseline_correction(fs, sz)
    local c = baseline_correction_cache[sz]
    if c then
        return c
    end
    local a = char.find_by_ascii("a")
    local a_sz = fs:char_get_sz({size = sz, code = a.ncod})
    c = (a_sz.tr.y + a_sz.bl.y) / 2
    baseline_correction_cache[sz] = c
    return c
end

local function cursor_metrics(fs, sz)
    local G, g = char.find_by_ascii("G"), char.find_by_ascii("g")
    local G_sz = fs:char_get_sz({size = sz, code = G.ncod})
    local g_sz = fs:char_get_sz({size = sz, code = g.ncod})
    return {line_height = g_sz.bl.y - G_sz.tr.y, baseline_shift = G_sz.tr.y}
end

local function min_extent(fs, sz)
    local cm = cursor_metrics(fs, sz)
    local H = char.find_by_ascii("H")
    local width = fs:char_get_sz({size = sz, code = H.ncod}).adv
    return {width = width, top = cm.baseline_shift, bottom = cm.baseline_shift + cm.line_height}
end

--[[ Builds one fresh empty atom (mexpr_empty) at font size sz - see mformula_new.lua's own
build_empty_atom() comment for what the three mexpr_empty() args mean; identical here, LOGICAL vs.
PHYSICAL split (mexpru.physical_sz()'s own comment) included. ]]
local function build_empty_atom(fontset, sz)
    local phys = mexpru.physical_sz(sz)
    local ext = min_extent(fontset, phys)
    local bc = baseline_correction(fontset, phys)
    local ret = mexpru.mexpr_empty(fontset, ext.width, ext.bottom - ext.top, bc - ext.top)
    mexpru.u(ret).sz = sz
    return ret
end

-- Characters that mean something special in our LaTeX subset (group/sup/sub syntax, or the
-- backslash-escape itself) - a literal occurrence of one of these as TYPED content gets
-- backslash-escaped on the way out, so from_latex() can always tell "a typed \ or $ or { etc.
-- character" apart from real syntax on the way back in.
local LATEX_ESCAPE_CHARS = {["$"] = true, ["\\"] = true, ["{"] = true, ["}"] = true, ["^"] = true, ["_"] = true}

local function latex_escape_char(c)
    if LATEX_ESCAPE_CHARS[c] then
        return "\\" .. c
    end
    return c
end

--[[ True when `horiz`'s only content is the lazy "nothing typed yet" placeholder (a single empty
atom) - see mformula_new.lua's own build_side() comment. Such a slot carries nothing worth
round-tripping, same as a sup/sub that was never built at all (see node_to_latex()'s own use of
this). ]]
local function horiz_is_untyped(horiz)
    local children = mexpru.u(horiz).children
    return #children == 1 and children[1].type == vc.MEXPR_TYPE_EMPTY_BOX
end

local function node_to_latex(node)
    if is_horiz(node) then
        local parts = {}
        for _, child in ipairs(mexpru.u(node).children) do
            parts[#parts + 1] = node_to_latex(child)
        end
        return table.concat(parts)
    elseif is_supsub(node) then
        local u = mexpru.u(node)
        local parts = {node_to_latex(u.base)}
        -- An absent (nil - lazy, never requested) OR present-but-never-typed-into slot carries
        -- nothing worth round-tripping - omitted entirely (not even as "^{}"), same as
        -- mformula.lua's own row_to_latex() did for its own eager-but-still-empty slots.
        if u.sup and not horiz_is_untyped(u.sup) then
            parts[#parts + 1] = "^{" .. node_to_latex(u.sup) .. "}"
        end
        if u.sub and not horiz_is_untyped(u.sub) then
            parts[#parts + 1] = "_{" .. node_to_latex(u.sub) .. "}"
        end
        return table.concat(parts)
    elseif is_frac(node) then
        -- Unlike sup/sub, num/den are never omitted even when still untyped - a fraction's two
        -- slots are never "not there at all" the way an unvisited sup/sub is (mexpr_frac itself
        -- requires both - mexpru.frac()'s own comment), so an empty one round-trips as "\frac{}{}"
        -- rather than being dropped.
        local u = mexpru.u(node)
        return "\\frac{" .. node_to_latex(u.num) .. "}{" .. node_to_latex(u.den) .. "}"
    elseif mexpru.u(node).kind == "vert" then
        --[[ "\stack{a}{b}{c}" - one brace group per slot, however many there are. A custom macro
        rather than a real LaTeX environment because this parser has none (no \begin/\end at all),
        and because a bare vertical stack has no established LaTeX spelling to borrow - it isn't a
        matrix and it isn't a cases block. Named \stack rather than \vert because \vert already
        means a vertical BAR in real LaTeX, and text leaving this editor shouldn't claim to be
        something it isn't. ]]
        local parts = {"\\stack"}
        for _, slot in ipairs(mexpru.u(node).slots) do
            parts[#parts + 1] = "{" .. node_to_latex(slot) .. "}"
        end
        return table.concat(parts)
    elseif node.type == vc.MEXPR_TYPE_EMPTY_BOX then
        return ""
    end

    --[[ A bracket atom serializes from its OWN semantic tag (u(_).bracket's is_open/type - set by
    open_bracket()/try_close_bracket()/resolve_bracket_pairs(), mformula_new.lua and mexpru.lua),
    NEVER by reverse-mapping its glyph below.

    Reported live 2026-09-05 ("reached an invalid state and reproduced it in a separate box"):
    resolve_bracket_pairs() only keeps the plain typed "(" glyph while the pair's content is short
    enough for one (its own 2026-09-05 pixel-identical sizing rule) - the moment that content grows
    taller (a superscript, a fraction, a nested pair), it swaps BOTH atoms for the TIERED glyphs
    mexpr_bracket_left()/_right() build (math_expr_composer.h's mexpr_bracket_side - a FONT_MATH_EX
    symbol at whichever tier fits, or a LINE_STRIP composite at the largest). Those carry no
    meaningful node.symb.code, so the MEXPR_TYPE_SYMBOL branch below read it back as 0 - which is
    char.lua's very FIRST table entry, "!" - and every tall bracket silently serialized as "!"
    instead of "(" / ")". Purely a serialization bug (the on-screen tree was always correct), but
    to_latex() is what math_writer.save and Ctrl+C are both built on, so it corrupted on SAVE:
    "((a))" with a superscript typed into it came back as "!(a^{i}!)".

    The tag is authoritative for both representations at once, which is exactly why this reads it
    instead of the glyph - a resolved pair's two atoms are only ever "the same bracket" by that
    tag, never by what they currently happen to be drawn as. ]]
    local br = mexpru.u(node).bracket
    if br then
        local ascii = br.is_open and OPEN_BRACKET_ASCII[br.type] or CLOSE_BRACKET_ASCII[br.type]
        if ascii then
            return latex_escape_char(ascii)
        end
    end

    do -- MEXPR_TYPE_SYMBOL - node.symb.code is exactly the ncod mexpr_symbol() was built with.
        local entry = char.find_by_ncod(node.symb.code)
        if not entry then
            return ""
        end
        if entry.acod ~= '\0' then
            return latex_escape_char(entry.acod)
        end
        -- No plain-ASCII form (greek/symbols) - char.lua's own `desc` for these IS their LaTeX
        -- macro name (e.g. "\\alpha"); the trailing space keeps it from running into whatever
        -- glyph comes right after, same as editor.lua's own plain-text selection_to_text() does.
        return entry.desc .. " "
    end
end

--[[ Renders `container`'s tree (an mformula_new container - {root=<horiz mexpr_p>, ...}) as a
LaTeX-subset string - NOT wrapped in $$ (editor.lua's own selection_to_text() does that, the same
place it decides a formula embed needs $$ at all). Only covers what mformula_new itself can
produce: plain glyphs, the greek/symbol shortcuts in char.lua (by their own `desc`), ^{...}/_{...}
for sup/sub, \frac{...}{...} - nothing fancier (big-op layout tweaks) since nothing in that editor
builds those yet either. ]]
function mformula_latex.to_latex(container)
    return node_to_latex(container.root)
end

--[[ The same rendering for a RUN of sibling nodes rather than a whole tree - what copying a
selection inside a formula needs (mformula_new's own selection is always a contiguous slice of one
horiz's children, so this is exactly the shape it has to serialise). Concatenated with no separator,
identically to how node_to_latex() already walks a horiz's own children. ]]
function mformula_latex.nodes_to_latex(nodes)
    local parts = {}
    for _, node in ipairs(nodes) do
        parts[#parts + 1] = node_to_latex(node)
    end
    return table.concat(parts)
end

--[[ Parses LaTeX-subset content starting at 1-based `pos` into a flat array of sibling mexpr_t
nodes (leaves or supsub nodes - never a horiz itself, the caller wraps that) - mirrors
mformula.lua's own parse_latex_row(), building real mexpr_t via mexpru's own constructors instead
of an intermediate {items=...} row. `sz` is the level to build plain content at; sup/sub content
recurses at SUB_SIZE_DELTA smaller (capped at MAX_SIZE_INDEX), same convention as mformula_new.lua's
own make_supsub(). Stops at a matching "}" (left for the caller to consume) or end of string.
Returns children, next_pos.

Deliberately lenient, not a general LaTeX parser (same spirit as mformula.lua's own parser, and
editor.lua's insert_text() for plain-text paste): an unrecognized "\\foo" macro is silently
dropped. "\\frac{...}{...}" builds a real mexpru.frac() node (both brace groups fully parsed via
this same function, recursively, so braces/sup/sub *inside* them are handled exactly like anywhere
else - an empty group, same as "^{}", still gets a fresh empty atom rather than an empty horiz with
nothing in it). ]]
local function parse_latex_children(fontset, s, pos, sz)
    local children = {}
    -- Bracket re-pairing (2026-09-05, reported live: "loading and saving the brackets is simply
    -- saving their glyph, at load those should be re-paired") - to_latex()/node_to_latex() only
    -- ever emits a resolved bracket pair's own PLAIN "("/")" characters (the MEXPR_TYPE_SYMBOL
    -- branch, same as any other glyph - it has no idea two of them were ever a real pair), so
    -- loading them back with NO pairing at all would silently drop the structure: no cascade-
    -- delete, no synchronized resize, nothing - just two ordinary, unrelated glyphs. A real stack
    -- (not mformula_new.lua's own single pending_bracket slot - that's fine for interactive typing,
    -- where only one bracket is ever mid-edit at a time, but loaded text can contain multiple,
    -- nested, or sequential ALREADY-COMPLETE pairs, e.g. "(a+b)*(c+d)" or "((a+b))") - local to
    -- THIS call, same as pending_bracket can't span into a sup/sub's own separate content, brackets
    -- typed across a "^{...}"/"_{...}"/"\\frac{...}{...}" boundary can't pair across it either.
    local bracket_stack = {}

    while pos <= #s do
        local c = s:sub(pos, pos)
        if c == "}" then
            break
        elseif c == "^" or c == "_" then
            local slot = (c == "^") and "sup" or "sub"
            pos = pos + 1

            -- What this slot attaches to: reuse the last child if it's ALREADY a supsub (x^{2}_{3}
            -- - both markers apply to the SAME node, see mformula.lua's own parse_latex_row()
            -- comment on this exact case); otherwise pop the last plain atom as the new base (or
            -- build a fresh empty one if there's nothing preceding - matches editor.lua's own
            -- Ctrl+Shift+=/- "no preceding character... base is just left empty"). Bases are never
            -- pulled from an EARLIER supsub (mformula_new's own base-must-be-atomic invariant),
            -- only is_supsub() ever reuses instead of popping.
            local reuse = children[#children]
            local base
            if reuse and is_supsub(reuse) then
                -- base already exists on `reuse`, nothing to pop.
            elseif reuse then
                children[#children] = nil
                base = reuse
            else
                base = build_empty_atom(fontset, sz)
            end
            -- Deliberately `sz` (this call's own nominal level), NOT the base's own u(_).sz: for
            -- an ordinary glyph the two are always equal anyway, but a glyph with its own
            -- size_delta_by_desc adjustment (currently just "\\int" - see below) renders at a
            -- DIFFERENT actual size than the surrounding text's nominal level, and sup/sub sizing
            -- must stay relative to that nominal level, not compound on top of the adjustment
            -- (an "^{X}" right after "\\int" would otherwise inherit \\int's own bigger size as
            -- ITS base, coming out even bigger than \\int itself instead of a normal-sized sup).
            local sub_sz = math.min(sz + SUB_SIZE_DELTA, MAX_SIZE_INDEX)

            local slot_children
            if s:sub(pos, pos) == "{" then
                slot_children, pos = parse_latex_children(fontset, s, pos + 1, sub_sz)
                if s:sub(pos, pos) == "}" then
                    pos = pos + 1
                end
            else
                -- Bare single-token shorthand (x^2, no braces) - accepted for compatibility with
                -- hand-written LaTeX, even though to_latex() never emits it.
                slot_children = {}
                local one = s:sub(pos, pos)
                local entry = one ~= "" and char.find_by_ascii(one)
                if entry then
                    -- sub_sz is LOGICAL - mapped to PHYSICAL only for the real construction call
                    -- (mexpru.physical_sz()'s own comment).
                    local g = mexpru.mexpr_symbol(fontset, {size = mexpru.physical_sz(sub_sz), code = entry.ncod}, true)
                    mexpru.u(g).sz = sub_sz
                    slot_children[1] = g
                    pos = pos + 1
                end
            end
            if #slot_children == 0 then
                -- "^{}" written explicitly - the marker's presence means the slot exists (matches
                -- build_side()'s own "reserves real layout space" placeholder), unlike an absent
                -- marker, which stays genuinely nil.
                slot_children[1] = build_empty_atom(fontset, sub_sz)
            end
            local slot_horiz = mexpru.horiz(fontset, slot_children, sub_sz)

            if reuse and is_supsub(reuse) then
                local u = mexpru.u(reuse)
                local rebuilt = mexpru.supsub(fontset, u.base,
                        slot == "sup" and slot_horiz or u.sup,
                        slot == "sub" and slot_horiz or u.sub)
                children[#children] = rebuilt
            else
                local node = mexpru.supsub(fontset, base,
                        slot == "sup" and slot_horiz or nil,
                        slot == "sub" and slot_horiz or nil)
                children[#children + 1] = node
            end
        elseif c == "\\" then
            pos = pos + 1
            local nc = s:sub(pos, pos)
            if nc:match("%a") then
                local start = pos
                while s:sub(pos, pos):match("%a") do
                    pos = pos + 1
                end
                local name = s:sub(start, pos - 1)
                if name == "frac" then
                    -- num/den render at the SAME sz as the surrounding text (mexpru.frac()'s own
                    -- comment - standard typesetting doesn't shrink a fraction's contents the way
                    -- an exponent shrinks), unlike sup/sub's sub_sz above.
                    local function parse_brace_group()
                        local grp_children = {}
                        if s:sub(pos, pos) == "{" then
                            grp_children, pos = parse_latex_children(fontset, s, pos + 1, sz)
                            if s:sub(pos, pos) == "}" then
                                pos = pos + 1
                            end
                        end
                        if #grp_children == 0 then
                            grp_children = {build_empty_atom(fontset, sz)}
                        end
                        return mexpru.horiz(fontset, grp_children, sz)
                    end
                    local num_horiz = parse_brace_group()
                    local den_horiz = parse_brace_group()
                    children[#children + 1] = mexpru.frac(fontset, num_horiz, den_horiz, sz)
                elseif name == "stack" then
                    --[[ "\stack{a}{b}{c}" - a vert, one brace group per slot (node_to_latex()'s own
                    comment on the spelling). Reads groups until the braces run out, since a stack
                    has no fixed arity the way \frac does; always ends up with at least one, so a
                    malformed "\stack" with no groups still parses into the one-slot stack the
                    editor's own Ctrl+= would have made rather than throwing. ]]
                    local slots = {}
                    while s:sub(pos, pos) == "{" do
                        local grp_children
                        grp_children, pos = parse_latex_children(fontset, s, pos + 1, sz)
                        if s:sub(pos, pos) == "}" then
                            pos = pos + 1
                        end
                        if #grp_children == 0 then
                            grp_children = {build_empty_atom(fontset, sz)}
                        end
                        slots[#slots + 1] = mexpru.horiz(fontset, grp_children, sz)
                    end
                    if #slots == 0 then
                        slots[1] = mexpru.horiz(fontset, {build_empty_atom(fontset, sz)}, sz)
                    end
                    children[#children + 1] = mexpru.vert(fontset, slots, sz)
                else
                    local entry = char.find_by_desc("\\" .. name)
                    if entry then
                        -- char.lua's own size_delta_by_desc (currently just "\\int") - a big
                        -- operator built at plain text size reads as a thin, undersized squiggle
                        -- instead of the display-style glyph it's supposed to be (see that
                        -- table's own comment; main.lua's demo draws \\int the same bigger way via
                        -- char.integral(sz-5)). Clamped into the valid [1, MAX_SIZE_INDEX] table
                        -- range the same way every other size computation in this codebase is -
                        -- size_delta_by_desc's deltas are small relative to the table (-5 vs 18
                        -- entries) so this only ever matters for glyphs already near an edge.
                        --
                        -- glyph_sz is ONLY for mexpr_symbol()'s own construction call - it bakes
                        -- the bigger visual size directly into the glyph's real geometry (tl/br),
                        -- permanently, independent of anything tagged afterward. u(g).sz is tagged
                        -- with the surrounding NOMINAL `sz` instead, deliberately NOT glyph_sz -
                        -- u(_).sz is a LOGICAL "what level does this belong to" reading (cursor
                        -- height via cursor_metrics()'s own G/g measurement, and the base size any
                        -- later supsub built off this glyph sizes its own sup/sub relative to),
                        -- not a visual one - \\int's own display-style boost is real ink, not a
                        -- change of context level, and a cursor parked on \\int rendering at 4x a
                        -- normal glyph's height (matching \\int's own boosted line-height) reads as
                        -- broken, not as "you're now inside bigger text".
                        local delta = char.size_delta_by_desc[entry.desc]
                        -- glyph_sz is LOGICAL too (same table, just a boosted level) - mapped to
                        -- PHYSICAL only for the real construction call (mexpru.physical_sz()'s own
                        -- comment), same as every other glyph this file builds.
                        local glyph_sz = delta and math.max(1, math.min(sz + delta, MAX_SIZE_INDEX)) or sz
                        local g = mexpru.mexpr_symbol(fontset, {size = mexpru.physical_sz(glyph_sz), code = entry.ncod}, true)
                        mexpru.u(g).sz = sz
                        children[#children + 1] = g
                    end
                    -- to_latex() always emits one trailing space after a macro name - consume it
                    -- so round-tripping our own output doesn't leave a stray space glyph behind.
                    if s:sub(pos, pos) == " " then
                        pos = pos + 1
                    end
                end
            else
                -- Escaped literal (\$, \\, \{, \}, \^, \_).
                local entry = nc ~= "" and char.find_by_ascii(nc)
                if entry then
                    -- sz is LOGICAL - mapped to PHYSICAL only for the real construction call.
                    local g = mexpru.mexpr_symbol(fontset, {size = mexpru.physical_sz(sz), code = entry.ncod}, true)
                    mexpru.u(g).sz = sz
                    children[#children + 1] = g
                end
                pos = pos + 1
            end
        else
            -- Same cp > 32 and cp < 256 range mformula_new.lua's own typing loop already restricts
            -- to (see its own comment) - a literal space or control character in the source is
            -- silently skipped rather than becoming a glyph that editor could never have typed.
            -- (A space glyph would have zero width - math_expr_composer.h's mexpr_symbol sizes
            -- every glyph from its own ink bounding box, and space has none - so mexpr_merge_h's
            -- own "x += n->br.x" advance treats it as taking up no room at all. Reverted 2026-09-04,
            -- not worth a math_expr_composer.h change right now.)
            local cp = c:byte()
            local entry = (cp and cp > 32 and cp < 256) and char.find_by_ascii(c) or nil
            if entry then
                -- sz is LOGICAL - mapped to PHYSICAL only for the real construction call.
                local g = mexpru.mexpr_symbol(fontset, {size = mexpru.physical_sz(sz), code = entry.ncod}, true)
                mexpru.u(g).sz = sz
                if OPEN_BRACKETS[c] then
                    -- Always tagged, paired or not - a literal unmatched "(" in the source (a
                    -- malformed/incomplete formula) round-trips as a genuinely still-PENDING
                    -- bracket, same as open_bracket()'s own live convention.
                    mexpru.u(g).bracket = {is_open = true, type = OPEN_BRACKETS[c]}
                    children[#children + 1] = g
                    table.insert(bracket_stack, {atom = g, idx = #children})
                elseif CLOSE_BRACKETS[c] then
                    local top = bracket_stack[#bracket_stack]
                    if top and mexpru.u(top.atom).bracket.type == CLOSE_BRACKETS[c] then
                        table.remove(bracket_stack)
                        -- Nothing was added since the open went in (an empty "()" in the source -
                        -- to_latex()'s own node_to_latex() emits exactly this for a live-typed
                        -- empty pair, its EMPTY_BOX filler rendering as "") - keep the span
                        -- non-empty the same way, or resolve_bracket_pairs() (mexpru.lua) errors
                        -- on it (mformula_new.lua's own handle_input() fix, 2026-09-05, same
                        -- reasoning: mirrors try_close_bracket()'s own "closed immediately" filler).
                        if #children == top.idx then
                            children[#children + 1] = build_empty_atom(fontset, sz)
                        end
                        mexpru.u(g).bracket = {is_open = false, type = CLOSE_BRACKETS[c], peer = mexpru.u(top.atom)}
                        mexpru.u(top.atom).bracket.peer = mexpru.u(g)
                    end
                    -- Mismatched or unmatched close (no open on the stack, or a type mismatch like
                    -- "(a]") - left as a PLAIN, untagged glyph rather than guessing a pairing that
                    -- isn't really there; same leniency this parser already has everywhere else.
                    children[#children + 1] = g
                else
                    children[#children + 1] = g
                end
            end
            pos = pos + 1
        end
    end

    return children, pos
end

--[[ Inverse of to_latex(): parses a LaTeX-subset string (again, NOT expecting the surrounding $$ -
editor.lua strips those before calling this) into a fresh container, same shape as
mformula_new.new(). Never errors - unparseable/unsupported bits are just dropped, matching
editor.lua's insert_text()'s own leniency for plain-text paste. Cursor ends up on the LAST
top-level node parsed (itself, if that's a supsub - "after the whole compound", same resting spot
mformula_new's own move_right() would leave it at), or on a fresh empty atom for an empty/fully-
unparseable string - same shape mformula_new.new() itself would produce. ]]
function mformula_latex.from_latex(fontset, sz, s)
    local children = parse_latex_children(fontset, s, 1, sz)
    if #children == 0 then
        children = {build_empty_atom(fontset, sz)}
    end
    local root = mexpru.horiz(fontset, children, sz)
    mexpru.update_positions(root)
    return {
        root = root,
        cursor_pos = vc.wref_mexpr(children[#children]),
        version = 0,
    }
end

return mformula_latex

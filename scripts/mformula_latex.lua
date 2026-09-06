--[[
mformula_latex.lua - LaTeX-subset serialization for mformula_new's mexpr_t-based tree: to_latex()
(mexpr_t -> string) and from_latex() (string -> a fresh mformula_new-shaped container). Split out
of mformula_new.lua into its own file so that file stays focused on the live editor
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
table. \frac{num}{den} is a real, round-tripping node kind here - see mexpru.frac()'s
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

-- "(" / "[" and ")" / "]" - mirrors mformula_new.lua's own OPEN_BRACKETS/CLOSE_BRACKETS (
-- own small copy here rather than a require() - this file's own top comment on staying self-
-- sufficient). Curly braces are deliberately NOT here - "{"/"}" are ALWAYS structural in this
-- parser (group delimiters for ^{...}/_{...}/\frac{...}{...} - parse_latex_children() itself stops
-- at a bare "}"), never a literal glyph, so a curly MATH bracket can't round-trip through this
-- LaTeX subset at all - a pre-existing, separate gap from the one this fixes.
local OPEN_BRACKETS = { ["("] = vc.MEXPR_BRACKET_ROUND, ["["] = vc.MEXPR_BRACKET_SQUARE }
local CLOSE_BRACKETS = { [")"] = vc.MEXPR_BRACKET_ROUND, ["]"] = vc.MEXPR_BRACKET_SQUARE }
--[[ Delimiters with no unambiguous CHARACTER of their own, written as commands instead.

The bar is the case: "|" stays an ordinary typeable literal (its shortcut is Ctrl+Shift+\ - see
mformula_new.lua's BAR_BRACKET), so a bar pair written as "|" would be indistinguishable from two
typed bars on reload, and a saved document would come back with the wrong one. \lvert/\rvert are
what LaTeX itself uses for exactly this, and being commands they can never collide with content.

Both halves are emitted with a trailing space, the separator this parser already relies on after a
command name (a bare space is skipped, a literal one is written "\ " - see latex_escape_char) -
without it "\lverta" would read back as a command named "lverta". ]]
local BRACKET_COMMAND = {}
local BRACKET_BY_COMMAND = {}
if vc.MEXPR_BRACKET_BAR then
    BRACKET_COMMAND[vc.MEXPR_BRACKET_BAR] = {open = "\\lvert ", close = "\\rvert "}
    BRACKET_BY_COMMAND["lvert"] = {type = vc.MEXPR_BRACKET_BAR, is_open = true}
    BRACKET_BY_COMMAND["rvert"] = {type = vc.MEXPR_BRACKET_BAR, is_open = false}
end

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

--[[ The characters LaTeX actually lets you escape - the ones where "\\x" means a literal x.
Anything else after a backslash is a COMMAND, not an escape, and must not be read as its own
character. That confusion is what turned "\\,"  (a thin space) into a comma: the escaped-literal
branch asked only "is the next character a letter?" and took everything else at face value, so
"\\int f(x)\\,dx" loaded with a comma in it and nothing said so.

" " is here too: "\\ " is LaTeX's control space, and what to_latex writes for a space glyph. ]]
local TEX_ESCAPABLE = {
    ["$"] = true, ["%"] = true, ["#"] = true, ["&"] = true, ["_"] = true,
    ["{"] = true, ["}"] = true, ["\\"] = true, ["^"] = true, [" "] = true,
}

local function is_horiz(node)
    return mexpru.u(node).kind == "horiz"
end

--[[ The atoms TeX itself classes as large operators, i.e. the ones \\limits is legal after.

This is a fact about LaTeX, not about our fonts, which is why it is spelled out here rather than
read from char.size_delta_by_desc - that table happens to hold the same six today because they are
the cmex display glyphs, but it exists to fix their SIZE and would be the wrong thing to consult if
either list ever moved. ]]
local TEX_BIG_OPERATORS = {
    ["\\sum"]    = true, ["\\prod"]   = true,
    ["\\int"]    = true, ["\\oint"]   = true,
    ["\\bigcup"] = true, ["\\bigcap"] = true,
}

local function base_is_tex_operator(node)
    if node.type ~= vc.MEXPR_TYPE_SYMBOL then
        return false                -- anything built out of several glyphs, e.g. "lim"
    end
    local entry = char.find_by_ncod(node.symb.code)
    return entry ~= nil and TEX_BIG_OPERATORS[entry.desc] == true
end

--[[ A bigop counts: it carries the same base/sup/sub and serializes the same way, differing only
by the \\limits that says its limits sit over and under rather than beside. Without this it matched
no branch at all and fell through to the SYMBOL one, which read symb.code off an internal node and
wrote char.lua's first entry - every big operator saved as "!", the same failure tall brackets had. ]]
local function is_supsub(node)
    local kind = mexpru.u(node).kind
    return kind == "supsub" or kind == "bigop"
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
--[[ "%", "#" and "&" joined this list 2026-09-06. Each is special to LaTeX and a bare one
breaks the document rather than printing: "%" starts a COMMENT, so it swallows the rest of the
line including the closing "$" (pdfTeX answers "! Missing $ inserted"); "#" is a parameter
character and "&" an alignment tab. "$" was already escaped here - these three were simply
missed. ]]
local LATEX_ESCAPE_CHARS = {["$"] = true, ["\\"] = true, ["{"] = true, ["}"] = true, ["^"] = true, ["_"] = true,
        ["%"] = true, ["#"] = true, ["&"] = true}

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

--[[ The LaTeX accent commands from_latex understands, and what each builds. Kept beside the
writer above so the two cannot drift: every `cmd` node_to_latex can emit appears here as a key. ]]
--[[ `below` marks the ones that dress the UNDERSIDE. LaTeX has no standard spelling for those -
\\underbar exists but means an underline, and there is nothing at all for a hat or a tilde beneath -
so they are this app's own \\under-prefixed names. The above-accents deliberately stay the real
commands (\\hat, \\tilde, \\bar, \\dot, \\ddot), so a copied formula still pastes into a document and
renders; only the half TeX cannot express leaves the standard. ]]
local ACCENT_COMMANDS = {
    hat   = {kind = "hat",   recipe = char.hat_accent},
    tilde = {kind = "tilde", recipe = char.tilde_accent},
    bar   = {kind = "bar",   recipe = char.bar_accent},
    dot   = {dots = 1},
    ddot  = {dots = 2},
    dddot = {dots = 3},
    vec           = {kind = "vec",     recipe = char.vec_accent},
    -- The stretchy spellings (see WIDE_ACCENT_COMMAND) read back to the same accents: which one a
    -- source used says how wide it was set, not what it was.
    widehat        = {kind = "hat",     recipe = char.hat_accent, wide = true},
    widetilde      = {kind = "tilde",   recipe = char.tilde_accent, wide = true},
    overline       = {kind = "bar",     recipe = char.bar_accent, wide = true},
    overrightarrow = {kind = "vec",     recipe = char.vec_accent, wide = true},
    overleftarrow = {kind = "vecleft", recipe = char.vec_left_accent},
    underhat   = {kind = "hat",   recipe = char.hat_accent,   below = true},
    undertilde = {kind = "tilde", recipe = char.tilde_accent, below = true},
    underbar   = {kind = "bar",   recipe = char.bar_accent,   below = true},
}

--[[ The STRETCHY spelling of each accent, for a target that is more than one glyph.

LaTeX splits these in two and the difference is not cosmetic: \\hat is \\mathaccent, a single-character
accent, so "\\hat{...}" over a four-row matrix sets a tiny hat over a big box. \\widehat is the one
that grows. Reported after a real pdflatex run: "the hats don't match".

\\overline rather than \\widebar for the bar, and \\overrightarrow rather than a wide \\vec, because
those are the names LaTeX actually has. The left arrow has no narrow form at all, so it is
\\overleftarrow either way.

Dots are absent on purpose - \\dot/\\ddot/\\dddot have no stretchy counterpart, and a dot does not
want one. ]]
local WIDE_ACCENT_COMMAND = {
    hat = "widehat", tilde = "widetilde", bar = "overline",
    vec = "overrightarrow", vecleft = "overleftarrow",
}

--[[ Is this the kind of target LaTeX's single-character accents are for? A lone glyph (or the empty
placeholder) takes \\hat; anything with structure - a row of atoms, a stack, a fraction - takes the
stretchy form, which is the same split the renderer makes when it picks a wider accent glyph by
measuring the target. ]]
local function target_is_one_glyph(target)
    return target.type == vc.MEXPR_TYPE_SYMBOL or target.type == vc.MEXPR_TYPE_EMPTY_BOX
end

-- kind -> the command that writes it, per slot.
local ACCENT_COMMAND_BY_KIND = {above = {}, below = {}}
--[[ Only the NARROW spellings, skipping spec.wide. Both "hat" and "widehat" carry kind "hat", so
without this the winner depended on pairs() hash order - and it picked "widehat", which is how
"\hat{x}" started coming out stretchy over a single letter. The wide name is chosen deliberately at
write time from the target, never by whichever entry happened to be visited last. ]]
for name, spec in pairs(ACCENT_COMMANDS) do
    if spec.kind and not spec.wide then
        ACCENT_COMMAND_BY_KIND[spec.below and "below" or "above"][spec.kind] = name
    end
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
        --[[ \\limits is what makes a big operator round-trip as one. LaTeX places a sum's limits
        above and below by default in display style and beside it inline, and an ordinary symbol's
        always beside - so without an explicit marker "\\sum^{n}_{i}" reads back as a plain supsub
        and the operator loses its shape. \\limits says exactly "put them over and under", which is
        both correct LaTeX and the flag the parser needs. ]]
        if u.kind == "bigop" then
            --[[ \\limits is only legal directly after an OPERATOR atom. A bigop whose operator is a
            node rather than one symbol - "lim", the case that motivated making it a node at all -
            serializes as ordinary letters or as a matrix, and pdfTeX answers exactly that with

                I'm ignoring this misplaced \\limits or \\nolimits command

            and then sets the limits beside it, losing the shape the marker existed to preserve.
            \\mathop{...} is the kernel primitive that reclassifies any content as a large operator,
            which makes \\limits legal again and costs nothing when it is not needed.

            Deliberately NOT \\operatorname*{lim}, which would be the idiomatic spelling for a named
            operator: that sets its content UPRIGHT, and this app draws "lim" in the same italic
            math letters everything else uses. \\mathop keeps the output looking like the formula on
            screen, which is the standing rule for this writer. ]]
            if not base_is_tex_operator(u.base) then
                parts[1] = "\\mathop{" .. parts[1] .. "}"
            end
            parts[#parts + 1] = "\\limits"
        end
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
    elseif mexpru.u(node).kind == "dress" then
        --[[ Accents map onto the real LaTeX commands - \\hat{x}, \\tilde{x}, \\bar{x}, \\dot{x},
        \\ddot{x} - rather than a custom macro, so a copied formula pastes into a document and
        renders. Three dots have no standard spelling and become \\dddot, which plain TeX does not
        define; that is the one place this leaves the standard, and it round-trips here regardless
        since from_latex reads its own output. ]]
        --[[ A dress has two slots and one node, but LaTeX has no two-slot accent - so a node
        wearing both writes as the below command WRAPPING the above one, "\\underbar{\\hat{x}}".
        Reading that back would ordinarily build two nested dresses where typing builds one, so the
        parser merges instead: an \\under* command whose target is already a dress with a free
        underside fills that slot rather than wrapping it. Order therefore does not matter, and one
        node goes out and one node comes back. ]]
        local u = mexpru.u(node)
        local above
        if u.dots == 1 then above = "dot"
        elseif u.dots == 2 then above = "ddot"
        elseif u.dots == 3 then above = "dddot"
        else above = ACCENT_COMMAND_BY_KIND.above[u.above_kind] end
        local below = ACCENT_COMMAND_BY_KIND.below[u.bellow_kind]

        -- Stretchy spelling for anything wider than a single glyph - see WIDE_ACCENT_COMMAND.
        if not target_is_one_glyph(u.target) then
            if u.above_kind and WIDE_ACCENT_COMMAND[u.above_kind] and not u.dots then
                above = WIDE_ACCENT_COMMAND[u.above_kind]
            end
            if u.bellow_kind and WIDE_ACCENT_COMMAND[u.bellow_kind] then
                below = WIDE_ACCENT_COMMAND[u.bellow_kind]
            end
        end

        local out = node_to_latex(u.target)
        if not above and not below then
            return out                       -- dressed with nothing; write the bare atom
        end
        if above then
            out = "\\" .. above .. "{" .. out .. "}"
        end
        if below then
            out = "\\" .. below .. "{" .. out .. "}"
        end
        return out
    elseif is_frac(node) then
        -- Unlike sup/sub, num/den are never omitted even when still untyped - a fraction's two
        -- slots are never "not there at all" the way an unvisited sup/sub is (mexpr_frac itself
        -- requires both - mexpru.frac()'s own comment), so an empty one round-trips as "\frac{}{}"
        -- rather than being dropped.
        local u = mexpru.u(node)
        return "\\frac{" .. node_to_latex(u.num) .. "}{" .. node_to_latex(u.den) .. "}"
    elseif mexpru.u(node).kind == "vert" then
        --[[ "\\begin{matrix} a \\\\ b \\end{matrix}" - real amsmath, so a saved formula pastes into a
        document and renders. It used to be "\\stack{a}{b}", this file's own invented macro, which
        round-tripped perfectly here and was an undefined control sequence anywhere else.

        The BARE matrix, deliberately, not pmatrix/bmatrix: a vert carries no delimiters of its own
        in this model - the brackets around one are separate bracket atoms that grow to fit it - so
        anything that brings its own parentheses would add a second pair on the way out. ]]
        local rows = {}
        for _, slot in ipairs(mexpru.u(node).slots) do
            rows[#rows + 1] = node_to_latex(slot)
        end
        return "\\begin{matrix}" .. table.concat(rows, "\\\\") .. "\\end{matrix}"
    elseif false then
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

    Reported live ("reached an invalid state and reproduced it in a separate box"):
    resolve_bracket_pairs() only keeps the plain typed "(" glyph while the pair's content is short
    enough for one (its own pixel-identical sizing rule) - the moment that content grows
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
        --[[ A PAIRED bracket goes out as \\left.../\\right..., because that is what it does here:
        a resolved pair grows to fit whatever sits between it, and \\left/\\right is LaTeX's name
        for exactly that. Written as a plain "[" instead, a stack four rows tall came back flanked
        by two normal-height brackets in a PDF - the document no longer looking like the thing that
        produced it, which is the whole point of the export.

        Only when it has a PEER. \\left and \\right must balance within a math group, and an
        unpaired bracket is a legitimate mid-edit state here (a typed "(" with no ")" yet), so one
        of those goes out as the plain character it is - correct LaTeX, and it cannot make the
        document fail to compile. ]]
        local cmd = BRACKET_COMMAND[br.type]
        local body = cmd and (br.is_open and cmd.open or cmd.close)
                or (br.is_open and OPEN_BRACKET_ASCII[br.type] or CLOSE_BRACKET_ASCII[br.type])
        if body then
            local plain = cmd and body or latex_escape_char(body)
            --[[ ...and only when it is actually GROWN. resolve_bracket_pairs keeps the plain typed
            glyph while the content is short enough for one, and swaps in the tiered composite only
            when it is not - so a short pair is a MEXPR_TYPE_SYMBOL and a grown one is not. Mirroring
            that here keeps "(a)" as "(a)" instead of the noisier \left(a
ight), and reserves the
            growing form for the pairs that really do grow on screen. ]]
            if br.peer and node.type ~= vc.MEXPR_TYPE_SYMBOL then
                return (br.is_open and "\\left" or "\\right") .. plain
            end
            return plain
        end
    end

    do -- MEXPR_TYPE_SYMBOL - node.symb.code is exactly the ncod mexpr_symbol() was built with.
        local entry = char.find_by_ncod(node.symb.code)
        if not entry then
            return ""
        end
        --[[ A SPACE is written as "\\ " (a LaTeX control space), never as a bare " ". A literal
        space in LaTeX source is not content - it separates tokens and terminates macro names -
        so the parser skips it, and a space glyph written plainly simply vanished on the next
        load. Reported: "save does not save spaces".

        "\\ " is real LaTeX for exactly this, and it needs nothing new on the read side: the
        parser's escaped-literal branch already resolves backslash-plus-non-letter through
        find_by_ascii(), and the space glyph's own acod IS ' '. ]]
        if entry.acod == ' ' then
            return "\\ "
        end
        --[[ A typed backslash goes out as "\\backslash ", not as the escaped "\\\\" it used to be.

        Two reasons, and the second is the load-bearing one. \\backslash is real LaTeX for a literal
        backslash in math mode, where "\\\\" is not - it is a line break. And inside a matrix "\\\\" IS
        the row separator, so as long as a typed backslash also spelled itself that way the two were
        genuinely ambiguous and neither could be read back reliably.

        Old saves still load: the parser keeps reading a bare "\\\\" as a literal backslash everywhere
        except inside a matrix environment, which no old save can contain. ]]
        if entry.acod == "\\" then
            return "\\backslash "
        end
        if entry.acod ~= '\0' then
            return latex_escape_char(entry.acod)
        end
        --[[ No plain-ASCII form (greek/symbols) - char.lua's own `desc` for these IS their LaTeX
        macro name (e.g. "\\alpha").

        A control WORD gets a trailing space, which keeps its name from running into whatever glyph
        follows ("\\alpha b", not "\\alphab"). A control SYMBOL - a backslash and one non-letter,
        like "\\," or "\\;" or "\\|" - must NOT, because its name cannot run on: the very next
        character already ends it, and LaTeX needs no separator there.

        Writing one anyway was a slow leak. Now that a literal space is kept as a glyph, the space
        after "\\," was read back as CONTENT, so every save/load cycle added another one:
        "a\\,b" -> "a\\, b" -> "a\\, \\ b" -> "a\\, \\ \\ b". Found 2026-09-06 by round-tripping
        three times instead of once - twice would have looked fine on the first comparison. ]]
        if entry.desc:match("^\\%A$") then
            return entry.desc
        end
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
--[[ `row_mode` is set while parsing one row of a matrix environment: the loop then also stops at
the row separator "\\\\" and at "\\end", WITHOUT consuming either, leaving the caller to decide
whether another row follows. Outside a matrix both are ordinary content and nothing changes. ]]
local function parse_latex_children(fontset, s, pos, sz, row_mode)
    local children = {}
    -- Bracket re-pairing (reported live: "loading and saving the brackets is simply
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
        elseif c == "{" then
            --[[ A plain LaTeX group. It has no visual effect - braces only delimit - so its
            contents are spliced straight into this row and the braces themselves vanish.

            Without this branch the two braces were ASYMMETRIC: every "}" closed a row (the break
            just above, written for a caller that had already consumed the matching "{"), while "{"
            was handled nowhere and fell through to the ordinary-character path as a literal glyph.
            So a bare group did not open anything, and its closing brace ended the row early -
            SILENTLY TRUNCATING everything after it:

                a{b}c                            ->  a{b          (the c simply gone)
                \frac{a}{b}+\text{q}+\frac{c}{d} ->  \frac{a}{b}+{q

            Measured 2026-09-06 while chasing what looked like an unknown-macro bug. It is not one:
            \text is only the way most people MEET this, because an unrecognised macro is dropped
            and leaves its group behind bare. An unknown macro with no group loses nothing but
            itself ("1+\foo+2" -> "1++2"). The brace is the bug.

            A literal brace glyph is "\{" and still works - that is the escaped-literal branch
            further down, and what to_latex() writes. ]]
            local grp
            grp, pos = parse_latex_children(fontset, s, pos + 1, sz)
            if s:sub(pos, pos) == "}" then
                pos = pos + 1
            end
            for _, g in ipairs(grp) do
                children[#children + 1] = g
            end
        elseif row_mode and c == "\\"
                and (s:sub(pos + 1, pos + 1) == "\\" or s:sub(pos + 1, pos + 4) == "end{") then
            break       -- row separator or the environment's end; the caller consumes it
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

            --[[ A base marked by \limits builds a BIGOP - limits over and under - instead of a
            supsub. The flag is carried on the node the marker followed, and read here rather than
            where it was set because "\sum\limits" alone is still just a sum until a limit
            actually arrives. Once the node exists its own kind carries the distinction, so the
            reuse path below asks it rather than the flag. ]]
            local wants_limits = (reuse and is_supsub(reuse) and mexpru.u(reuse).kind == "bigop")
                    or (base and mexpru.u(base).wants_limits)

            if reuse and is_supsub(reuse) then
                local u = mexpru.u(reuse)
                local new_sup = slot == "sup" and slot_horiz or u.sup
                local new_sub = slot == "sub" and slot_horiz or u.sub
                local rebuilt
                if wants_limits then
                    rebuilt = mexpru.bigop(fontset, u.base, new_sup, new_sub, u.sz or sz)
                else
                    rebuilt = mexpru.supsub(fontset, u.base, new_sup, new_sub)
                end
                children[#children] = rebuilt
            else
                local new_sup = slot == "sup" and slot_horiz or nil
                local new_sub = slot == "sub" and slot_horiz or nil
                local node
                if wants_limits then
                    node = mexpru.bigop(fontset, base, new_sup, new_sub,
                            mexpru.u(base).sz or sz)
                else
                    node = mexpru.supsub(fontset, base, new_sup, new_sub)
                end
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
                if ACCENT_COMMANDS[name] then
                    --[[ One brace group, dressed. The accent is re-derived from the parsed
                    target's own width rather than stored, exactly as every other path does - see
                    mexpr_accent's successor search. ]]
                    local grp_children
                    if s:sub(pos, pos) == "{" then
                        grp_children, pos = parse_latex_children(fontset, s, pos + 1, sz)
                        if s:sub(pos, pos) == "}" then
                            pos = pos + 1
                        end
                    end
                    local inner = grp_children or {}
                    local target = (#inner == 1) and inner[1]
                            or mexpru.horiz(fontset,
                                    (#inner > 0) and inner or {build_empty_atom(fontset, sz)}, sz)
                    local spec = ACCENT_COMMANDS[name]
                    --[[ Merge rather than nest when the target is already a dress with the slot
                    this command wants free - "\\underbar{\\hat{x}}" is ONE atom wearing two
                    decorations, the same node typing it produces, not a dress inside a dress.
                    Built through mexpru.redress() either way, so the accent glyph is re-picked
                    against the real target's width (Rule 12) exactly as everywhere else. ]]
                    local slot_free = mexpru.u(target).kind == "dress"
                            and ((spec.below and not mexpru.u(target).bellow_kind)
                                or (not spec.below and not mexpru.u(target).above_kind
                                        and not mexpru.u(target).dots))
                    local dress_spec, real_target
                    if slot_free then
                        local tu = mexpru.u(target)
                        real_target = tu.target
                        dress_spec = {
                            above_kind = tu.above_kind, above_recipe = tu.above_recipe,
                            bellow_kind = tu.bellow_kind, bellow_recipe = tu.bellow_recipe,
                            dots = tu.dots,
                        }
                    else
                        real_target = target
                        dress_spec = {}
                    end
                    if spec.below then
                        dress_spec.bellow_kind = spec.kind
                        dress_spec.bellow_recipe = spec.recipe
                    else
                        dress_spec.above_kind = spec.kind
                        dress_spec.above_recipe = spec.recipe
                        dress_spec.dots = spec.dots
                    end
                    children[#children + 1] =
                            mexpru.redress(fontset, real_target, dress_spec, sz)
                --[[ A command-written delimiter (BRACKET_COMMAND): tagged and stacked exactly
                like a character-written one, so everything downstream - the counter rule, the
                cascade, resolve_bracket_pairs() - sees an ordinary bracket pair and needs to know
                nothing about how it was spelled.

                An unmatched close is left as a PLAIN untagged glyph, the same leniency this parser
                already gives "(a]" - guessing a pairing that isn't in the source is how a document
                comes back subtly rewired. ]]
                elseif BRACKET_BY_COMMAND[name] then
                    local spec = BRACKET_BY_COMMAND[name]
                    local entry = char.find_by_ascii("|")
                    local g = mexpru.mexpr_symbol(fontset,
                            {size = mexpru.physical_sz(sz), code = entry.ncod}, true)
                    mexpru.u(g).sz = sz
                    if spec.is_open then
                        mexpru.u(g).bracket = {is_open = true, type = spec.type}
                        children[#children + 1] = g
                        table.insert(bracket_stack, {atom = g, idx = #children})
                    else
                        local top = bracket_stack[#bracket_stack]
                        if top and mexpru.u(top.atom).bracket.type == spec.type then
                            table.remove(bracket_stack)
                            -- Keep the span non-empty: resolve_bracket_pairs() errors on an empty
                            -- one, same as every other close path here already guards.
                            if #children == top.idx then
                                children[#children + 1] = build_empty_atom(fontset, sz)
                            end
                            mexpru.u(g).bracket = {is_open = false, type = spec.type,
                                    peer = mexpru.u(top.atom)}
                            mexpru.u(top.atom).bracket.peer = mexpru.u(g)
                        end
                        children[#children + 1] = g
                    end
                elseif name == "frac" then
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
                elseif name == "begin" then
                    --[[ "\\begin{matrix} a \\\\ b \\end{matrix}" - what node_to_latex() now writes a
                    vert as, and real amsmath rather than this file's old invented "\\stack".

                    Only the BARE matrix is read, matching what is written. pmatrix and friends
                    carry their own delimiters, which this model keeps as separate bracket atoms
                    beside the vert - accepting one would have to synthesise that pair to avoid
                    losing it, and guessing at delimiters nobody asked for is worse than declining
                    the environment. ]]
                    local env
                    if s:sub(pos, pos) == "{" then
                        local close = s:find("}", pos + 1, true)
                        if close then
                            env = s:sub(pos + 1, close - 1)
                            pos = close + 1
                        end
                    end
                    if env == "matrix" then
                        local slots = {}
                        while true do
                            local row
                            row, pos = parse_latex_children(fontset, s, pos, sz, true)
                            if #row == 0 then
                                row = {build_empty_atom(fontset, sz)}
                            end
                            slots[#slots + 1] = mexpru.horiz(fontset, row, sz)
                            if s:sub(pos, pos + 1) == "\\\\" then
                                pos = pos + 2       -- another row follows
                            else
                                break
                            end
                        end
                        -- Consume "\\end{matrix}" if it is really there; a truncated source just
                        -- ends the stack early rather than throwing, same leniency as everywhere.
                        if s:sub(pos, pos + 4) == "\\end{" then
                            local close = s:find("}", pos + 5, true)
                            pos = close and (close + 1) or pos
                        end
                        if #slots == 0 then
                            slots[1] = mexpru.horiz(fontset, {build_empty_atom(fontset, sz)}, sz)
                        end
                        children[#children + 1] = mexpru.vert(fontset, slots, sz)
                    end
                elseif name == "left" or name == "right" then
                    --[[ Skipped, not represented: the delimiter that FOLLOWS carries all the
                    meaning, and it is parsed by the ordinary bracket paths on the next iteration -
                    as a character for "(" "[" "{", or as a command for \\lvert/\\rvert. Pairing is
                    then the bracket stack's job exactly as for a typed pair, so a \\left...\\right
                    document loads with the same structure a hand-typed one gets.

                    That also means \\left. and \\right. (the invisible delimiters) are read as a literal
                    ".", which is wrong but harmless, and nothing this app writes ever emits them. ]]
                elseif name == "mathop" then
                    --[[ Reads what the writer emits for a multi-glyph operator. The group becomes
                    ONE atom in the row, which is what lets the \\limits that follows attach to it -
                    the marker below tags children[#children], so the operator has to arrive as a
                    single child rather than as its letters spread across the row. ]]
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
                    children[#children + 1] = mexpru.horiz(fontset, grp_children, sz)
                elseif name == "limits" then
                    --[[ Marks the atom just parsed as wanting its sup/sub ABOVE and BELOW, so the
                    "^"/"_" handler builds a bigop rather than a supsub. A marker rather than a node
                    of its own: that is what it is in LaTeX too. ]]
                    local last = children[#children]
                    if last then
                        mexpru.u(last).wants_limits = true
                    end
                elseif name == "backslash" then
                    -- A typed backslash, written as real LaTeX - see node_to_latex()'s own comment.
                    local e = char.find_by_ascii("\\")
                    if e then
                        local g = mexpru.mexpr_symbol(fontset,
                                {size = mexpru.physical_sz(sz), code = e.ncod}, true)
                        mexpru.u(g).sz = sz
                        children[#children + 1] = g
                    end
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
                end
                --[[ The ONE separator space that follows a control word, consumed here so it
                applies to EVERY branch above rather than only the plain-glyph one.

                It only started mattering when a literal space became a real glyph: until then an
                unconsumed separator was skipped anyway, so the branches that never consumed theirs
                - the bracket commands like \lvert among them - looked fine. The moment spaces were
                kept, "\lvert a\rvert " read back with a space glyph wedged after each. Caught by
                test_bar_bracket.lua. Consuming one optional space after a control word is exactly
                what LaTeX itself does. ]]
                if s:sub(pos, pos) == " " then
                    pos = pos + 1
                end
            else
                --[[ A backslash followed by something that is not a letter. Three things it can be,
                tried in this order - and NOTHING is discarded, which is the point:

                  1. a real LaTeX escape (TEX_ESCAPABLE) - "\$" and friends, a literal character.
                  2. a named punctuation command the catalog knows - the spacing commands \, \: \;
                     \! and the likes of \| . Looked up by desc, so each keeps its own identity and
                     writes back out as itself.
                  3. anything else: the character itself, which is what this branch always did.

                Order matters twice over. Before this, EVERY non-letter took route 3, so "\," became
                a comma and "\;" a semicolon - valid formulas, silently different from what was
                pasted. And the escape has to be tried FIRST: the catalog also holds a desc "\{" for
                cmsy's BIG brace, so a desc-first order quietly turned every escaped "\{" into a
                bracket-sized one. Caught by test_latex_groups.lua. ]]
                local entry = (TEX_ESCAPABLE[nc] and char.find_by_ascii(nc))
                        or (nc ~= "" and char.find_by_desc("\\" .. nc))
                        or (nc ~= "" and char.find_by_ascii(nc))
                if entry then
                    -- sz is LOGICAL - mapped to PHYSICAL only for the real construction call.
                    local g = mexpru.mexpr_symbol(fontset, {size = mexpru.physical_sz(sz), code = entry.ncod}, true)
                    mexpru.u(g).sz = sz
                    children[#children + 1] = g
                end
                pos = pos + 1
            end
        else
            --[[ A literal space in the source becomes a real space GLYPH, deliberately - this
            app is not LaTeX and keeps what was typed. Asked for 2026-09-06: "especialy spaces,
            since I like them, I know latex kinda doesn't care about them, but my app will, even if
            loosing them when exporting."

            Safe for our own output because the ONE place a space really is just a separator - the
            single space to_latex writes after every macro name - is consumed by the macro branch
            itself, before this is ever reached. So "\\sum x" still loads as two atoms, while a
            pasted "a + b" now keeps its gaps instead of closing up.

            The reason previously recorded here - that a space glyph would be zero-width, since
            mexpr_symbol sizes every glyph from its ink box and a space has none - stopped being
            true on, when mexpr_symbol gained a fallback to the font advance for an
            inkless glyph. Spaces occupy real width now, which is what made saving them worth
            fixing. Control characters below 32 stay skipped: nothing can type them. ]]
            local cp = c:byte()
            local entry = (cp and cp >= 32 and cp < 256) and char.find_by_ascii(c) or nil
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
                        -- on it (mformula_new.lua's own handle_input() fix, same
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
--[[ Finds the "}" that closes the "{" at open_pos, counting nesting, so an argument containing
groups of its own is taken whole. A backslash escapes whatever follows it, which is what stops a
literal "\\\\{" inside the argument from being mistaken for a delimiter. Returns nil if nothing
closes it - a malformed source is left for the ordinary parse path to deal with, not repaired. ]]
local function match_brace(s, open_pos)
    local depth, i = 0, open_pos
    while i <= #s do
        local c = s:sub(i, i)
        if c == "\\" then
            i = i + 1
        elseif c == "{" then
            depth = depth + 1
        elseif c == "}" then
            depth = depth - 1
            if depth == 0 then
                return i
            end
        end
        i = i + 1
    end
    return nil
end

--[[ Rewrites \\sqrt into the power it already means:

    \\sqrt{x}      ->  (x)^{\\frac{1}{2}}
    \\sqrt[3]{x}   ->  (x)^{\\frac{1}{3}}

Asked for directly 2026-09-06 - "in the specific case of sqrt I want to transform it into ()^(1/2)".

A rewrite of the SOURCE rather than a branch in the parser, deliberately. There is no radical node
in this model, so a root has to come out as nodes that already exist; going through the text means
the brackets are built by the same path a typed "(" takes, so they arrive as a real resolved PAIR -
cascade-delete, synchronized growth, all of it - instead of two loose glyphs that merely look like
parentheses. Nothing new to keep in step, and every existing test of bracket behaviour covers this
for free.

The parentheses are kept even around a single letter. They are not redundant in general -
\\sqrt{a+b} without them is a different expression - and deciding when they can be dropped is a
judgement about precedence this does not need to make.

ONE-WAY on purpose: what comes back out is the power form, because that is now genuinely what the
formula IS. It re-reads as itself, so it is stable; it just never turns back into a \\sqrt.

Recursive on both parts, so nested roots and a root in the index both expand. ]]
--[[ Macros that are SEVERAL glyphs, not one, and so expand into what they actually are.

Two kinds, both from docs/texbook.pdf Appendix F:

  - dot runs. No font here has a row of dots as a single glyph; TeX sets three separate characters,
    low periods for \ldots and centred dots for \cdots (cmsy10 has one centred dot at TeX 0x01 and
    no run of any length).
  - negated and composite relations. TeX builds these by OVERPRINTING: \not has zero width, so the
    glyph after it prints on top. \ne is literally \not followed by "=", \notin is \not followed
    by \in, and \mapsto is the zero-width \mapstochar followed by an arrow. That only works
    because char.lua's adv_by_desc restores the zero advance this font lost - without it these come
    out side by side rather than overlaid.

Expanding in the SOURCE, rather than inventing composite nodes, means each piece is an ordinary atom
the cursor can walk through and delete on its own, built by the ordinary path. Same reasoning as
\sqrt below.

ONE-WAY, like \sqrt: what comes back out is the expansion. That is still correct LaTeX - "\not ="
and "\cdot \cdot \cdot" both typeset exactly as the macro would - so a document round-trips to
one spelling rather than flipping between two. ]]
local MACRO_EXPANSIONS = {
    ["\\ldots"] = "...",
    ["\\dots"]  = "...",
    ["\\cdots"] = "\\cdot \\cdot \\cdot ",

    ["\\ne"]     = "\\not =",
    ["\\neq"]    = "\\not =",
    ["\\notin"]  = "\\not \\in ",
    ["\\mapsto"] = "\\mapstochar \\rightarrow ",
}

local function expand_macros(s)
    for name, run in pairs(MACRO_EXPANSIONS) do
        -- The trailing space to_latex() writes after every macro name is consumed with it, so
        -- "a \ne b" does not come back with a stray gap where the macro was.
        --[[ %f[%A] is a frontier: it matches only where a letter is followed by a non-letter, so
        a name never matches as the PREFIX of a longer one. Without it \ne would fire
        inside \neq and leave a stray q behind - and pairs() gives no order to rely on instead. ]]
        s = s:gsub(name:gsub("%p", "%%%1") .. "%f[%A] ?", (run:gsub("%%", "%%%%")))
    end
    return s
end

local function expand_sqrt(s)
    local out, i = {}, 1
    while true do
        local a, b = s:find("\\sqrt", i, true)
        if not a then
            out[#out + 1] = s:sub(i)
            break
        end
        if s:sub(b + 1, b + 1):match("%a") then
            -- "\sqrtsign" is a macro called sqrtsign, not \sqrt applied to anything.
            out[#out + 1] = s:sub(i, b)
            i = b + 1
        else
            out[#out + 1] = s:sub(i, a - 1)

            -- Optional index: "[3]" in \sqrt[3]{x}. Absent means a square root.
            local p, index = b + 1, "2"
            if s:sub(p, p) == "[" then
                local close = s:find("]", p, true)
                if close then
                    index = s:sub(p + 1, close - 1)
                    p = close + 1
                end
            end

            local open = (s:sub(p, p) == "{") and p or nil
            local close = open and match_brace(s, open)
            if close then
                out[#out + 1] = "(" .. expand_sqrt(s:sub(open + 1, close - 1))
                        .. ")^{\\frac{1}{" .. expand_sqrt(index) .. "}}"
                i = close + 1
            else
                out[#out + 1] = s:sub(a, b)      -- no argument; leave it to the ordinary path
                i = b + 1
            end
        end
    end
    return table.concat(out)
end

function mformula_latex.from_latex(fontset, sz, s)
    -- \sqrt is rewritten into a power before anything else looks at the text - see expand_sqrt().
    local children = parse_latex_children(fontset, expand_sqrt(expand_macros(s)), 1, sz)
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

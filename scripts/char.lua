local vc = require("virt_composer")

local capi = {
	FONT_NORMAL = 1,
	FONT_BOLD = 2,
	FONT_ITALIC = 3,
	FONT_MONO = 4,
	FONT_MATH = 5,
	FONT_SYMBOLS = 6,
	FONT_MATH_EX = 7,
}

function capi.load_font_set()
    local base_sz = 42

    local paths = {}
    -- Roman
    --      * Has some math operators/Symbols
    --      * Usefull for description parts of the app
    paths[capi.FONT_NORMAL] = "fonts/cmr10.ttf"

    -- Bold Extended
    --      * Has some math operators/Symbols
    --      * Usefull for description parts of the app
    paths[capi.FONT_BOLD] = "fonts/cmbx10.ttf"

    -- Text Italic
    --      * Has some math operators/Symbols
    --      * Usefull for description parts of the app
    paths[capi.FONT_ITALIC] = "fonts/cmti10.ttf"

    -- Typewriter Type
    --      * Has some math operators/Symbols
    --      * Usefull for description parts of the app
    --      * Has constant spacing, can be used for code writing
    paths[capi.FONT_MONO] = "fonts/cmtt10.ttf"

    -- Math Italic
    --      * Used for formulas (the variable names)
    --      * Has more/all greek
    --      * has some operators
    paths[capi.FONT_MATH] = "fonts/cmmi10.ttf"

    -- Math Symbols
    --      * Used for formulas
    --      * A lot of signs
    paths[capi.FONT_SYMBOLS] = "fonts/cmsy10.ttf"

    -- Math Extension
    --      * Used for formulas
    --      * big operators
    --      * brackets
    paths[capi.FONT_MATH_EX] = "fonts/cmex10.ttf"

    local ret = vc.create_object(nil, {
        m_type = "charc::fontset_t",
        m_a_code = 61,
        -- 60.0/50.0 (9, 10) added, between the pre-existing 72 and 42, for content.lua's
        -- Ctrl+MouseWheel zoom (make_supsub()'s own SUB_SIZE_DELTA=1/MAX_SIZE_INDEX walk relies on
        -- consecutive indices being consecutive steps, so a smoothing level has to be INSERTED in
        -- sorted position, not appended past 8 - the old table jumped 72->42, a ~1.7x step, way out
        -- of line with every other step's ~1.2-1.3x, right where content.lua's own default (36, now
        -- index 12) sits closest to). mformula_new.lua/mformula.lua/mformula_latex.lua's own
        -- MAX_SIZE_INDEX=18 (was 16) has to track this table's actual length - checked,
        -- all three still say so.
        m_font_sizes = {
            360.0,  288.0,  216.0,  180.0,  --[[  1,  2,  3,  4]]
            144.0,  120.0,  96.0,   72.0,   --[[  5,  6,  7,  8]]
            60.0,   50.0,   42.0,   36.0,   --[[  9, 10, 11, 12]] --[[ 12 shall be the default one]]
            24.0,   18.0,   14.0,   12.0,   --[[ 13, 14, 15, 16]]
            10.0,   8.0                     --[[ 17, 18]]
        },
        m_font_paths = paths
    })

    --[[ The trailing arguments are the two per-glyph metric corrections this font needs: a
    vertical shift (capi.y_offset_by_desc / font_loc_t::y_off_em) and an advance-width override
    (capi.adv_by_desc / font_loc_t::adv_em). Both have "no correction" defaults, so a glyph in
    neither table registers exactly as it always did. ]]
    for i in ipairs(capi.chars) do
        local c = capi.chars[i]
        ret:register_code(c.ncod, c.fnum, c.fcod,
                capi.y_offset_by_desc[c.desc] or 0.0,
                capi.adv_by_desc[c.desc] or -1.0)
    end

    return ret
end

--[[ Some character definitions ]]
function capi.hash(fontsz)        return {size=fontsz, code=2} end
function capi.comma(fontsz)       return {size=fontsz, code=11} end
function capi.plus(fontsz)        return {size=fontsz, code=10} end
function capi.minus(fontsz)       return {size=fontsz, code=181} end
function capi.equal(fontsz)       return {size=fontsz, code=27} end
function capi.integral(fontsz)    return {size=fontsz, code=191} end
function capi.bigsum(fontsz)      return {size=fontsz, code=192} end
function capi.hline_basic(fontsz) return {size=fontsz, code=221} end
function capi.hline_long(fontsz)  return {size=fontsz, code=222} end
function capi.hline_above(fontsz) return {size=fontsz, code=223} end
function capi.less(fontsz)        return {size=fontsz, code=245} end  -- <
function capi.greater(fontsz)     return {size=fontsz, code=246} end  -- >
function capi.leq(fontsz)         return {size=fontsz, code=186} end  -- \le
function capi.geq(fontsz)         return {size=fontsz, code=187} end  -- \ge
function capi.neq(fontsz)         return {size=fontsz, code=27} end   -- = (fallback for !=)
function capi.times(fontsz)       return {size=fontsz, code=182} end  -- \times
function capi.divide(fontsz)      return {size=fontsz, code=183} end  -- \div

function capi.round_bracket(fontsz)
    return {
        type = vc.MEXPR_BRACKET_ROUND,
        tl   = { size=fontsz, code=231 },
        bl   = { size=fontsz, code=233 },
        tr   = { size=fontsz, code=232 },
        br   = { size=fontsz, code=234 },
        cl   = { size=fontsz, code=228 },
        cr   = { size=fontsz, code=229 },
        conl = { size=fontsz, code=228 },
        conr = { size=fontsz, code=229 },
        left = {
            { size=fontsz, code=197 },
            { size=fontsz, code=198 },
            { size=fontsz, code=199 },
            { size=fontsz, code=200 },
        },
        right = {
            { size=fontsz, code=201 },
            { size=fontsz, code=202 },
            { size=fontsz, code=203 },
            { size=fontsz, code=204 },
        }
    }
end

function capi.square_bracket(fontsz)
    return {
        type = vc.MEXPR_BRACKET_SQUARE,
        tl   = { size=fontsz, code=235 },
        bl   = { size=fontsz, code=237 },
        tr   = { size=fontsz, code=236 },
        br   = { size=fontsz, code=238 },
        cl   = { size=fontsz, code=226 },
        cr   = { size=fontsz, code=227 },
        conl = { size=fontsz, code=226 },
        conr = { size=fontsz, code=227 },
        left = {
            { size=fontsz, code=205 },
            { size=fontsz, code=206 },
            { size=fontsz, code=207 },
            { size=fontsz, code=208 },
        },
        right = {
            { size=fontsz, code=209 },
            { size=fontsz, code=210 },
            { size=fontsz, code=211 },
            { size=fontsz, code=212 },
        }
    }
end

function capi.curly_bracket(fontsz)
    return {
        type = vc.MEXPR_BRACKET_CURLY,
        tl   = { size=fontsz, code=239 },
        bl   = { size=fontsz, code=241 },
        tr   = { size=fontsz, code=240 },
        br   = { size=fontsz, code=242 },
        cl   = { size=fontsz, code=243 },
        cr   = { size=fontsz, code=244 },
        conl = { size=fontsz, code=224 },
        conr = { size=fontsz, code=224 },
        left = {
            { size=fontsz, code=213 },
            { size=fontsz, code=214 },
            { size=fontsz, code=215 },
            { size=fontsz, code=216 },
        },
        right = {
            { size=fontsz, code=217 },
            { size=fontsz, code=218 },
            { size=fontsz, code=219 },
            { size=fontsz, code=220 },
        }
    }
end

--[[ Dispatches to round_bracket()/square_bracket()/curly_bracket() above by the vc.MEXPR_BRACKET_*
`bracket_type` a bracket atom's own u(_).bracket.type carries (mexpru.lua's resolve_bracket_pairs()) -
lets that generic code build the right mexpr_bracket_t for whichever type a given entangled pair
actually is, without itself needing a three-way if/elseif of its own. ]]
--[[ "|" - absolute value / norm bars. Both delimiters of a bar pair are the SAME shape, so
unlike every other bracket here there is no mirrored partner to describe: left and right are equal.

tl/bl/tr/br are the SPACE glyph, deliberately. mexpr_bracket_side sums their heights into the
extensible's base height before deciding how many connectors to stack, and a bar has no corner
pieces to account for - an inkless glyph measures exactly 0 tall (mexpr_symbol's own inkless
branch), which is the contribution wanted. Only cl/conl carry real metrics: their HEIGHT is the
quantisation step and their WIDTH is the stroke the drawn rule is given.

The tiers are all the plain "|" (ncod 88 - 38 units tall at size 12, against a letter's 17), so
anything that fits inside one resolves to the typed glyph itself and only genuinely tall content
reaches the extensible path at all. There is nothing finer to put in them: cmex10 ships no
\\big|/\\Big| tiers, TeX builds those from these same extension pieces.

_vline_4/_vline_5 (w=2.0) are the widest registered extensions, against the plain bar's own 2.5 -
half a unit thinner at size 12, which is the closest match available without adding a glyph. ]]
function capi.bar_bracket(fontsz)
    local space = capi.find_by_ascii(" ")
    local blank = { size=fontsz, code=space and space.ncod or 247 }
    local bar   = { size=fontsz, code=88 }
    return {
        type = vc.MEXPR_BRACKET_BAR,
        tl   = blank,
        bl   = blank,
        tr   = blank,
        br   = blank,
        cl   = { size=fontsz, code=228 },
        cr   = { size=fontsz, code=229 },
        conl = { size=fontsz, code=228 },
        conr = { size=fontsz, code=229 },
        left  = { bar, bar, bar, bar },
        right = { bar, bar, bar, bar },
    }
end

function capi.bracket_opts(bracket_type, fontsz)
    if bracket_type == vc.MEXPR_BRACKET_SQUARE then
        return capi.square_bracket(fontsz)
    elseif bracket_type == vc.MEXPR_BRACKET_CURLY then
        return capi.curly_bracket(fontsz)
    -- Guarded on the constant rather than assumed: the bar needs MEXPR_BRACKET_BAR registered from
    -- C++ (math_expr_composer.h), and until that lands vc.MEXPR_BRACKET_BAR is nil - in which case
    -- nothing ever tags a bracket with it and this branch is unreachable anyway.
    elseif vc.MEXPR_BRACKET_BAR and bracket_type == vc.MEXPR_BRACKET_BAR then
        return capi.bar_bracket(fontsz)
    else
        return capi.round_bracket(fontsz)
    end
end

capi.chars = {
    {acod='!',  fcod=0x21, fnum=capi.FONT_NORMAL , ncod=  0, desc="!" },               -- exclamation mark
    {acod='"',  fcod=0x22, fnum=capi.FONT_NORMAL , ncod=  1, desc="\""},               -- double quote
    {acod='#',  fcod=0x23, fnum=capi.FONT_NORMAL , ncod=  2, desc="#" },               -- hash
    {acod='$',  fcod=0x24, fnum=capi.FONT_NORMAL , ncod=  3, desc="$" },               -- dollar sign
    {acod='%',  fcod=0x25, fnum=capi.FONT_NORMAL , ncod=  4, desc="%" },               -- percent sign
    {acod='&',  fcod=0x26, fnum=capi.FONT_NORMAL , ncod=  5, desc="&" },               -- ampersand
    {acod='\'', fcod=0x27, fnum=capi.FONT_NORMAL , ncod=  6, desc="'" },               -- single quote
    {acod='(',  fcod=0x28, fnum=capi.FONT_NORMAL , ncod=  7, desc="(" },               -- left parenthesis
    {acod=')',  fcod=0x29, fnum=capi.FONT_NORMAL , ncod=  8, desc=")" },               -- right parenthesis
    {acod='*',  fcod=0x2A, fnum=capi.FONT_NORMAL , ncod=  9, desc="*" },               -- asterisk
    {acod='+',  fcod=0x2B, fnum=capi.FONT_NORMAL , ncod= 10, desc="+" },               -- plus sign
    {acod=',',  fcod=0x2C, fnum=capi.FONT_NORMAL , ncod= 11, desc="," },               -- comma
    {acod='-',  fcod=0x2D, fnum=capi.FONT_NORMAL , ncod= 12, desc="-" },               -- hyphen-minus
    {acod='.',  fcod=0x2E, fnum=capi.FONT_NORMAL , ncod= 13, desc="." },               -- period
    {acod='/',  fcod=0x2F, fnum=capi.FONT_NORMAL , ncod= 14, desc="/" },               -- slash
    {acod='0',  fcod=0x30, fnum=capi.FONT_NORMAL , ncod= 15, desc="0" },               -- digit zero
    {acod='1',  fcod=0x31, fnum=capi.FONT_NORMAL , ncod= 16, desc="1" },               -- digit one
    {acod='2',  fcod=0x32, fnum=capi.FONT_NORMAL , ncod= 17, desc="2" },               -- digit two
    {acod='3',  fcod=0x33, fnum=capi.FONT_NORMAL , ncod= 18, desc="3" },               -- digit three
    {acod='4',  fcod=0x34, fnum=capi.FONT_NORMAL , ncod= 19, desc="4" },               -- digit four
    {acod='5',  fcod=0x35, fnum=capi.FONT_NORMAL , ncod= 20, desc="5" },               -- digit five
    {acod='6',  fcod=0x36, fnum=capi.FONT_NORMAL , ncod= 21, desc="6" },               -- digit six
    {acod='7',  fcod=0x37, fnum=capi.FONT_NORMAL , ncod= 22, desc="7" },               -- digit seven
    {acod='8',  fcod=0x38, fnum=capi.FONT_NORMAL , ncod= 23, desc="8" },               -- digit eight
    {acod='9',  fcod=0x39, fnum=capi.FONT_NORMAL , ncod= 24, desc="9" },               -- digit nine
    {acod=':',  fcod=0x3A, fnum=capi.FONT_NORMAL , ncod= 25, desc=":" },               -- colon
    {acod=';',  fcod=0x3B, fnum=capi.FONT_NORMAL , ncod= 26, desc=";" },               -- semicolon
    {acod='=',  fcod=0x3D, fnum=capi.FONT_NORMAL , ncod= 27, desc="=" },               -- equals sign
    {acod='?',  fcod=0x3F, fnum=capi.FONT_NORMAL , ncod= 28, desc="?" },               -- question mark
    {acod='@',  fcod=0x40, fnum=capi.FONT_NORMAL , ncod= 29, desc="@" },               -- at symbol
    {acod='A',  fcod=0x41, fnum=capi.FONT_MATH   , ncod= 30, desc="A" },               -- uppercase A
    {acod='B',  fcod=0x42, fnum=capi.FONT_MATH   , ncod= 31, desc="B" },               -- uppercase B
    {acod='C',  fcod=0x43, fnum=capi.FONT_MATH   , ncod= 32, desc="C" },               -- uppercase C
    {acod='D',  fcod=0x44, fnum=capi.FONT_MATH   , ncod= 33, desc="D" },               -- uppercase D
    {acod='E',  fcod=0x45, fnum=capi.FONT_MATH   , ncod= 34, desc="E" },               -- uppercase E
    {acod='F',  fcod=0x46, fnum=capi.FONT_MATH   , ncod= 35, desc="F" },               -- uppercase F
    {acod='G',  fcod=0x47, fnum=capi.FONT_MATH   , ncod= 36, desc="G" },               -- uppercase G
    {acod='H',  fcod=0x48, fnum=capi.FONT_MATH   , ncod= 37, desc="H" },               -- uppercase H
    {acod='I',  fcod=0x49, fnum=capi.FONT_MATH   , ncod= 38, desc="I" },               -- uppercase I
    {acod='J',  fcod=0x4A, fnum=capi.FONT_MATH   , ncod= 39, desc="J" },               -- uppercase J
    {acod='K',  fcod=0x4B, fnum=capi.FONT_MATH   , ncod= 40, desc="K" },               -- uppercase K
    {acod='L',  fcod=0x4C, fnum=capi.FONT_MATH   , ncod= 41, desc="L" },               -- uppercase L
    {acod='M',  fcod=0x4D, fnum=capi.FONT_MATH   , ncod= 42, desc="M" },               -- uppercase M
    {acod='N',  fcod=0x4E, fnum=capi.FONT_MATH   , ncod= 43, desc="N" },               -- uppercase N
    {acod='O',  fcod=0x4F, fnum=capi.FONT_MATH   , ncod= 44, desc="O" },               -- uppercase O
    {acod='P',  fcod=0x50, fnum=capi.FONT_MATH   , ncod= 45, desc="P" },               -- uppercase P
    {acod='Q',  fcod=0x51, fnum=capi.FONT_MATH   , ncod= 46, desc="Q" },               -- uppercase Q
    {acod='R',  fcod=0x52, fnum=capi.FONT_MATH   , ncod= 47, desc="R" },               -- uppercase R
    {acod='S',  fcod=0x53, fnum=capi.FONT_MATH   , ncod= 48, desc="S" },               -- uppercase S
    {acod='T',  fcod=0x54, fnum=capi.FONT_MATH   , ncod= 49, desc="T" },               -- uppercase T
    {acod='U',  fcod=0x55, fnum=capi.FONT_MATH   , ncod= 50, desc="U" },               -- uppercase U
    {acod='V',  fcod=0x56, fnum=capi.FONT_MATH   , ncod= 51, desc="V" },               -- uppercase V
    {acod='W',  fcod=0x57, fnum=capi.FONT_MATH   , ncod= 52, desc="W" },               -- uppercase W
    {acod='X',  fcod=0x58, fnum=capi.FONT_MATH   , ncod= 53, desc="X" },               -- uppercase X
    {acod='Y',  fcod=0x59, fnum=capi.FONT_MATH   , ncod= 54, desc="Y" },               -- uppercase Y
    {acod='Z',  fcod=0x5A, fnum=capi.FONT_MATH   , ncod= 55, desc="Z" },               -- uppercase Z
    {acod='[',  fcod=0x5B, fnum=capi.FONT_NORMAL , ncod= 56, desc="[" },               -- left square bracket
    {acod=']',  fcod=0x5D, fnum=capi.FONT_NORMAL , ncod= 57, desc="]" },               -- right square bracket
    {acod='^',  fcod=0x5E, fnum=capi.FONT_NORMAL , ncod= 58, desc="^" },               -- circumflex accent
    {acod='_',  fcod=0x5F, fnum=capi.FONT_MONO   , ncod= 59, desc="_" },               -- underscore
    {acod='`',  fcod=0xB5, fnum=capi.FONT_NORMAL , ncod= 60, desc="`" },               -- grave accent
    {acod='a',  fcod=0x61, fnum=capi.FONT_MATH   , ncod= 61, desc="a" },               -- lowercase a
    {acod='b',  fcod=0x62, fnum=capi.FONT_MATH   , ncod= 62, desc="b" },               -- lowercase b
    {acod='c',  fcod=0x63, fnum=capi.FONT_MATH   , ncod= 63, desc="c" },               -- lowercase c
    {acod='d',  fcod=0x64, fnum=capi.FONT_MATH   , ncod= 64, desc="d" },               -- lowercase d
    {acod='e',  fcod=0x65, fnum=capi.FONT_MATH   , ncod= 65, desc="e" },               -- lowercase e
    {acod='f',  fcod=0x66, fnum=capi.FONT_MATH   , ncod= 66, desc="f" },               -- lowercase f
    {acod='g',  fcod=0x67, fnum=capi.FONT_MATH   , ncod= 67, desc="g" },               -- lowercase g
    {acod='h',  fcod=0x68, fnum=capi.FONT_MATH   , ncod= 68, desc="h" },               -- lowercase h
    {acod='i',  fcod=0x69, fnum=capi.FONT_MATH   , ncod= 69, desc="i" },               -- lowercase i
    {acod='j',  fcod=0x6A, fnum=capi.FONT_MATH   , ncod= 70, desc="j" },               -- lowercase j
    {acod='k',  fcod=0x6B, fnum=capi.FONT_MATH   , ncod= 71, desc="k" },               -- lowercase k
    {acod='l',  fcod=0x6C, fnum=capi.FONT_MATH   , ncod= 72, desc="l" },               -- lowercase l
    {acod='m',  fcod=0x6D, fnum=capi.FONT_MATH   , ncod= 73, desc="m" },               -- lowercase m
    {acod='n',  fcod=0x6E, fnum=capi.FONT_MATH   , ncod= 74, desc="n" },               -- lowercase n
    {acod='o',  fcod=0x6F, fnum=capi.FONT_MATH   , ncod= 75, desc="o" },               -- lowercase o
    {acod='p',  fcod=0x70, fnum=capi.FONT_MATH   , ncod= 76, desc="p" },               -- lowercase p
    {acod='q',  fcod=0x71, fnum=capi.FONT_MATH   , ncod= 77, desc="q" },               -- lowercase q
    {acod='r',  fcod=0x72, fnum=capi.FONT_MATH   , ncod= 78, desc="r" },               -- lowercase r
    {acod='s',  fcod=0x73, fnum=capi.FONT_MATH   , ncod= 79, desc="s" },               -- lowercase s
    {acod='t',  fcod=0x74, fnum=capi.FONT_MATH   , ncod= 80, desc="t" },               -- lowercase t
    {acod='u',  fcod=0x75, fnum=capi.FONT_MATH   , ncod= 81, desc="u" },               -- lowercase u
    {acod='v',  fcod=0x76, fnum=capi.FONT_MATH   , ncod= 82, desc="v" },               -- lowercase v
    {acod='w',  fcod=0x77, fnum=capi.FONT_MATH   , ncod= 83, desc="w" },               -- lowercase w
    {acod='x',  fcod=0x78, fnum=capi.FONT_MATH   , ncod= 84, desc="x" },               -- lowercase x
    {acod='y',  fcod=0x79, fnum=capi.FONT_MATH   , ncod= 85, desc="y" },               -- lowercase y
    {acod='z',  fcod=0x7A, fnum=capi.FONT_MATH   , ncod= 86, desc="z" },               -- lowercase z
    {acod='{',  fcod=0x66, fnum=capi.FONT_SYMBOLS, ncod= 87, desc="{" },               -- left curly brace
    {acod='|',  fcod=0x6A, fnum=capi.FONT_SYMBOLS, ncod= 88, desc="|" },               -- vertical bar
    {acod='}',  fcod=0x67, fnum=capi.FONT_SYMBOLS, ncod= 89, desc="}" },               -- right curly brace
    {acod='~',  fcod=0x7E, fnum=capi.FONT_NORMAL , ncod= 90, desc="~" },               -- tilde
    {acod='\\', fcod=0x6E, fnum=capi.FONT_SYMBOLS, ncod= 91, desc="\\"},               -- backslash
    {acod='\0', fcod=0xA1, fnum=capi.FONT_NORMAL , ncod= 92, desc="\\Gamma" },         -- Greek uppercase Gamma
    {acod='\0', fcod=0xA2, fnum=capi.FONT_NORMAL , ncod= 93, desc="\\Delta" },         -- Greek uppercase Delta
    {acod='\0', fcod=0xA3, fnum=capi.FONT_NORMAL , ncod= 94, desc="\\Theta" },         -- Greek uppercase Theta
    {acod='\0', fcod=0xA4, fnum=capi.FONT_NORMAL , ncod= 95, desc="\\Lambda" },        -- Greek uppercase Lambda
    {acod='\0', fcod=0xA5, fnum=capi.FONT_NORMAL , ncod= 96, desc="\\Xi" },            -- Greek uppercase Xi
    {acod='\0', fcod=0xA6, fnum=capi.FONT_NORMAL , ncod= 97, desc="\\Pi" },            -- Greek uppercase Pi
    {acod='\0', fcod=0xA7, fnum=capi.FONT_NORMAL , ncod= 98, desc="\\Sigma" },         -- Greek uppercase Sigma
    {acod='\0', fcod=0xA8, fnum=capi.FONT_NORMAL , ncod= 99, desc="\\Upsilon" },       -- Greek uppercase Upsilon
    {acod='\0', fcod=0xA9, fnum=capi.FONT_NORMAL , ncod=100, desc="\\Phi" },           -- Greek uppercase Phi
    {acod='\0', fcod=0xAA, fnum=capi.FONT_NORMAL , ncod=101, desc="\\Psi" },           -- Greek uppercase Psi
    {acod='\0', fcod=0xAB, fnum=capi.FONT_NORMAL , ncod=102, desc="\\Omega" },         -- Greek uppercase Omega
    {acod='\0', fcod=0xAE, fnum=capi.FONT_MATH   , ncod=103, desc="\\alpha" },         -- Greek lowercase alpha
    {acod='\0', fcod=0xAF, fnum=capi.FONT_MATH   , ncod=104, desc="\\beta" },          -- Greek lowercase beta
    {acod='\0', fcod=0xB0, fnum=capi.FONT_MATH   , ncod=105, desc="\\gamma" },         -- Greek lowercase gamma
    {acod='\0', fcod=0xB1, fnum=capi.FONT_MATH   , ncod=106, desc="\\delta" },         -- Greek lowercase delta
    {acod='\0', fcod=0xB2, fnum=capi.FONT_MATH   , ncod=107, desc="\\epsilon" },       -- Greek lowercase epsilon
    {acod='\0', fcod=0xB3, fnum=capi.FONT_MATH   , ncod=108, desc="\\zeta" },          -- Greek lowercase zeta
    {acod='\0', fcod=0xB4, fnum=capi.FONT_MATH   , ncod=109, desc="\\eta" },           -- Greek lowercase eta
    {acod='\0', fcod=0xB5, fnum=capi.FONT_MATH   , ncod=110, desc="\\theta" },         -- Greek lowercase theta
    {acod='\0', fcod=0xB6, fnum=capi.FONT_MATH   , ncod=111, desc="\\iota" },          -- Greek lowercase iota
    {acod='\0', fcod=0xB7, fnum=capi.FONT_MATH   , ncod=112, desc="\\kappa" },         -- Greek lowercase kappa
    {acod='\0', fcod=0xB8, fnum=capi.FONT_MATH   , ncod=113, desc="\\lambda" },        -- Greek lowercase lambda
    {acod='\0', fcod=0xB9, fnum=capi.FONT_MATH   , ncod=114, desc="\\mu" },            -- Greek lowercase mu
    {acod='\0', fcod=0xBA, fnum=capi.FONT_MATH   , ncod=115, desc="\\nu" },            -- Greek lowercase nu
    {acod='\0', fcod=0xBB, fnum=capi.FONT_MATH   , ncod=116, desc="\\xi" },            -- Greek lowercase xi
    {acod='\0', fcod=0xBC, fnum=capi.FONT_MATH   , ncod=117, desc="\\pi" },            -- Greek lowercase pi
    {acod='\0', fcod=0xBD, fnum=capi.FONT_MATH   , ncod=118, desc="\\rho" },           -- Greek lowercase rho
    {acod='\0', fcod=0xBE, fnum=capi.FONT_MATH   , ncod=119, desc="\\sigma" },         -- Greek lowercase sigma
    {acod='\0', fcod=0xBF, fnum=capi.FONT_MATH   , ncod=120, desc="\\tau" },           -- Greek lowercase tau
    {acod='\0', fcod=0xC0, fnum=capi.FONT_MATH   , ncod=121, desc="\\upsilon" },       -- Greek lowercase upsilon
    {acod='\0', fcod=0xC1, fnum=capi.FONT_MATH   , ncod=122, desc="\\phi" },           -- Greek lowercase phi
    {acod='\0', fcod=0xC2, fnum=capi.FONT_MATH   , ncod=123, desc="\\chi" },           -- Greek lowercase chi
    {acod='\0', fcod=0xC3, fnum=capi.FONT_MATH   , ncod=124, desc="\\psi" },           -- Greek lowercase psi
    {acod='\0', fcod=0x21, fnum=capi.FONT_MATH   , ncod=125, desc="\\omega" },         -- Greek lowercase omega
    {acod='\0', fcod=0xA1, fnum=capi.FONT_MATH   , ncod=126, desc="\\Gamma" },         -- Greek uppercase Gamma
    {acod='\0', fcod=0xA2, fnum=capi.FONT_MATH   , ncod=127, desc="\\Delta" },         -- Greek uppercase Delta
    {acod='\0', fcod=0xA3, fnum=capi.FONT_MATH   , ncod=128, desc="\\Theta" },         -- Greek uppercase Theta
    {acod='\0', fcod=0xA4, fnum=capi.FONT_MATH   , ncod=129, desc="\\Lambda" },        -- Greek uppercase Lambda
    {acod='\0', fcod=0xA5, fnum=capi.FONT_MATH   , ncod=130, desc="\\Xi" },            -- Greek uppercase Xi
    {acod='\0', fcod=0xA6, fnum=capi.FONT_MATH   , ncod=131, desc="\\Pi" },            -- Greek uppercase Pi
    {acod='\0', fcod=0xA7, fnum=capi.FONT_MATH   , ncod=132, desc="\\Sigma" },         -- Greek uppercase Sigma
    {acod='\0', fcod=0xA8, fnum=capi.FONT_MATH   , ncod=133, desc="\\Upsilon" },       -- Greek uppercase Upsilon
    {acod='\0', fcod=0xA9, fnum=capi.FONT_MATH   , ncod=134, desc="\\Phi" },           -- Greek uppercase Phi
    {acod='\0', fcod=0xAA, fnum=capi.FONT_MATH   , ncod=135, desc="\\Psi" },           -- Greek uppercase Psi
    {acod='\0', fcod=0xAB, fnum=capi.FONT_MATH   , ncod=136, desc="\\Omega" },         -- Greek uppercase Omega
    {acod='\0', fcod=0xC3, fnum=capi.FONT_SYMBOLS, ncod=137, desc="\\leftarrow" },     -- left arrow
    {acod='\0', fcod=0x21, fnum=capi.FONT_SYMBOLS, ncod=138, desc="\\rightarrow" },    -- right arrow
    {acod='\0', fcod=0x22, fnum=capi.FONT_SYMBOLS, ncod=139, desc="\\uparrow" },       -- up arrow
    {acod='\0', fcod=0x23, fnum=capi.FONT_SYMBOLS, ncod=140, desc="\\downarrow" },     -- down arrow
    {acod='\0', fcod=0x24, fnum=capi.FONT_SYMBOLS, ncod=141, desc="\\leftrightarrow" },-- left-right arrow
    {acod='\0', fcod=0x25, fnum=capi.FONT_SYMBOLS, ncod=142, desc="\\nearrow" },       -- north-east arrow
    {acod='\0', fcod=0x26, fnum=capi.FONT_SYMBOLS, ncod=143, desc="\\searrow" },       -- south-east arrow
    {acod='\0', fcod=0x27, fnum=capi.FONT_SYMBOLS, ncod=144, desc="\\simeq" },         -- approximately equal
    {acod='\0', fcod=0x28, fnum=capi.FONT_SYMBOLS, ncod=145, desc="\\Leftarrow" },     -- left double arrow
    {acod='\0', fcod=0x29, fnum=capi.FONT_SYMBOLS, ncod=146, desc="\\Rightarrow" },    -- right double arrow
    {acod='\0', fcod=0x2A, fnum=capi.FONT_SYMBOLS, ncod=147, desc="\\Uparrow" },       -- up double arrow
    {acod='\0', fcod=0x2B, fnum=capi.FONT_SYMBOLS, ncod=148, desc="\\Downarrow" },     -- down double arrow
    {acod='\0', fcod=0x2C, fnum=capi.FONT_SYMBOLS, ncod=149, desc="\\Leftrightarrow" },-- left-right double arrow
    {acod='\0', fcod=0x2D, fnum=capi.FONT_SYMBOLS, ncod=150, desc="\\nwarrow" },       -- north-west arrow
    {acod='\0', fcod=0x2E, fnum=capi.FONT_SYMBOLS, ncod=151, desc="\\swarrow" },       -- south-west arrow
    {acod='\0', fcod=0x2F, fnum=capi.FONT_SYMBOLS, ncod=152, desc="\\propto" },        -- proportional to
    -- TeX 0x30, which Figure 5 shows as PRIME, not partial - this row claimed "\partial" until
    -- 2026-09-06, so every derivative drawn in this app was actually a prime mark. The real partial
    -- is cmmi 0x40 (Figure 4), registered further down.
    {acod='\0', fcod=0x30, fnum=capi.FONT_SYMBOLS, ncod=153, desc="\\prime" },         -- prime mark
    {acod='\0', fcod=0x31, fnum=capi.FONT_SYMBOLS, ncod=154, desc="\\infty" },         -- infinity
    {acod='\0', fcod=0x32, fnum=capi.FONT_SYMBOLS, ncod=155, desc="\\in" },            -- element of
    {acod='\0', fcod=0x33, fnum=capi.FONT_SYMBOLS, ncod=156, desc="\\ni" },            -- element of backwards
    {acod='\0', fcod=0x35, fnum=capi.FONT_SYMBOLS, ncod=157, desc="\\nabla" },         -- nabla
    -- TeX 0x36. Figure 5 shows the NEGATION slash - the thing \ne and \notin are built from, not
    -- an ordinary "/" (which is FONT_NORMAL 0x2F, above). It was spelled "/" here, which made it
    -- unreachable: by_ascii and by_desc both resolve "/" to that earlier row. Zero advance, so it
    -- overprints whatever follows - see capi.adv_by_desc.
    {acod='\0', fcod=0x36, fnum=capi.FONT_SYMBOLS, ncod=158, desc="\\not" },            -- negation slash
    -- TeX 0x37, the stem of \mapsto. Also zero width: TeX draws it and then an arrow on top.
    {acod='\0', fcod=0x37, fnum=capi.FONT_SYMBOLS, ncod=262, desc="\\mapstochar" },     -- \mapsto stem
    {acod='\0', fcod=0x38, fnum=capi.FONT_SYMBOLS, ncod=159, desc="\\forall" },        -- for all
    {acod='\0', fcod=0x39, fnum=capi.FONT_SYMBOLS, ncod=160, desc="\\exists" },        -- exists
    {acod='\0', fcod=0x3A, fnum=capi.FONT_SYMBOLS, ncod=161, desc="\\neg" },           -- negation
    {acod='\0', fcod=0x3B, fnum=capi.FONT_SYMBOLS, ncod=162, desc="\\emptyset" },      -- empty set
    {acod='\0', fcod=0x3C, fnum=capi.FONT_SYMBOLS, ncod=163, desc="\\Re" },            -- real part
    {acod='\0', fcod=0x3D, fnum=capi.FONT_SYMBOLS, ncod=164, desc="\\Im" },            -- imaginary part
    {acod='\0', fcod=0x3E, fnum=capi.FONT_SYMBOLS, ncod=165, desc="\\top" },           -- top
    {acod='\0', fcod=0x3F, fnum=capi.FONT_SYMBOLS, ncod=166, desc="\\bot" },           -- bottom
    {acod='\0', fcod=0x40, fnum=capi.FONT_SYMBOLS, ncod=167, desc="\\aleph" },         -- aleph
    {acod='\0', fcod=0x5B, fnum=capi.FONT_SYMBOLS, ncod=168, desc="\\cup" },           -- union
    {acod='\0', fcod=0x5C, fnum=capi.FONT_SYMBOLS, ncod=169, desc="\\cap" },           -- intersection
    {acod='\0', fcod=0x5D, fnum=capi.FONT_SYMBOLS, ncod=170, desc="\\uplus" },         -- multiset union
    {acod='\0', fcod=0x5E, fnum=capi.FONT_SYMBOLS, ncod=171, desc="\\wedge" },         -- logical and
    {acod='\0', fcod=0x5F, fnum=capi.FONT_SYMBOLS, ncod=172, desc="\\vee" },           -- logical or
    {acod='\0', fcod=0x66, fnum=capi.FONT_SYMBOLS, ncod=173, desc="\\{" },             -- DUPLICATE - left brace
    {acod='\0', fcod=0x67, fnum=capi.FONT_SYMBOLS, ncod=174, desc="\\}" },             -- DUPLICATE - right brace
    {acod='\0', fcod=0x6A, fnum=capi.FONT_SYMBOLS, ncod=175, desc="\\|" },             -- vertical bar
    {acod='\0', fcod=0x6B, fnum=capi.FONT_SYMBOLS, ncod=176, desc="\\parallel" },      -- parallel
    {acod='\0', fcod=0xBF, fnum=capi.FONT_SYMBOLS, ncod=177, desc="\\ll" },            -- much less than
    {acod='\0', fcod=0xC0, fnum=capi.FONT_SYMBOLS, ncod=178, desc="\\gg" },            -- much greater than
    {acod='\0', fcod=0xB1, fnum=capi.FONT_SYMBOLS, ncod=179, desc="\\circ" },          -- circle
    {acod='\0', fcod=0xB2, fnum=capi.FONT_SYMBOLS, ncod=180, desc="\\bullet" },        -- bullet
    {acod='-' , fcod=0xA1, fnum=capi.FONT_SYMBOLS, ncod=181, desc="-" },               -- minus sign
    {acod='\0', fcod=0xA3, fnum=capi.FONT_SYMBOLS, ncod=182, desc="\\times" },         -- multiplication sign
    {acod='\0', fcod=0xA5, fnum=capi.FONT_SYMBOLS, ncod=183, desc="\\div" },           -- division sign
    {acod='\0', fcod=0xA7, fnum=capi.FONT_SYMBOLS, ncod=184, desc="\\pm" },            -- plus-minus sign
    {acod='\0', fcod=0xA8, fnum=capi.FONT_SYMBOLS, ncod=185, desc="\\mp" },            -- minus-plus sign
    {acod='\0', fcod=0xB7, fnum=capi.FONT_SYMBOLS, ncod=186, desc="\\le" },            -- less than or equal
    {acod='\0', fcod=0xB8, fnum=capi.FONT_SYMBOLS, ncod=187, desc="\\ge" },            -- greater than or equal
    -- TeX 0x11. Figure 5 shows the three-bar identity sign here; cmsy10 has no congruence glyph
    -- at all (it is built by stacking). Was labelled "\cong" until 2026-09-06 - kept reachable as
    -- an alias below so documents written with the old name still load.
    {acod='\0', fcod=0xB4, fnum=capi.FONT_SYMBOLS, ncod=188, desc="\\equiv" },         -- identical to
    {acod='\0', fcod=0xB6, fnum=capi.FONT_SYMBOLS, ncod=189, desc="\\supseteq" },      -- superset equal
    {acod='\0', fcod=0xB5, fnum=capi.FONT_SYMBOLS, ncod=190, desc="\\subseteq" },      -- subset equal
    {acod='\0', fcod=0x5A, fnum=capi.FONT_MATH_EX, ncod=191, desc="\\int" },           -- integration sign
    {acod='\0', fcod=0x58, fnum=capi.FONT_MATH_EX, ncod=192, desc="\\sum" },           -- summation sign
    {acod='\0', fcod=0x59, fnum=capi.FONT_MATH_EX, ncod=193, desc="\\prod" },          -- product sign
    {acod='\0', fcod=0x5B, fnum=capi.FONT_MATH_EX, ncod=194, desc="\\bigcup" },        -- large union
    {acod='\0', fcod=0x5C, fnum=capi.FONT_MATH_EX, ncod=195, desc="\\bigcap" },        -- large intersection
    {acod='\0', fcod=0x49, fnum=capi.FONT_MATH_EX, ncod=196, desc="\\oint" },          -- circle integral
    {acod='\0', fcod=0xC3, fnum=capi.FONT_MATH_EX, ncod=197, desc="\\Biggl(" },        -- paranthesis '(' level 4
    --[[ Added 2026-09-06. The authority for every fcod in this file is docs/texbook.pdf, Appendix F
    "Font Tables" (page 431, Figure 5 for cmsy10; page 430, Figure 4 for cmmi10) - read it before
    adding a row, do not work from memory of the encoding.

    TeX positions have to be TRANSLATED for these TTFs, which do not carry the low range at its own
    codes: cmsy10's TeX 0x00-0x1F lands at 0xA1+ here, with output slots 0xAC/0xAD skipped - so TeX
    0x00-0x0A are 0xA1-0xAB, and TeX 0x0B-0x1F are 0xAE-0xC2. TeX 0x20-0x7F map straight through.
    Checked against nine rows already in this table (0xB1 circ, 0xB2 bullet, 0xB5/0xB6
    subseteq/supseteq, 0xB7/0xB8 le/ge, 0xBF/0xC0 ll/gg, 0xC3 leftarrow). The two-slot gap makes a
    plain offset wrong above 0xAB, so translate, never extrapolate.

    ncod runs past 255 from here; char_t::code is uint32_t, and nothing stores it narrower. ]]
    {acod='\0', fcod=0xA2, fnum=capi.FONT_SYMBOLS, ncod=256, desc="\\cdot" },         -- centred dot
    {acod='\0', fcod=0xBB, fnum=capi.FONT_SYMBOLS, ncod=257, desc="\\sim" },          -- similar to
    {acod='\0', fcod=0xBC, fnum=capi.FONT_SYMBOLS, ncod=258, desc="\\approx" },       -- approximately
    {acod='\0', fcod=0xBD, fnum=capi.FONT_SYMBOLS, ncod=259, desc="\\subset" },       -- proper subset
    {acod='\0', fcod=0xBE, fnum=capi.FONT_SYMBOLS, ncod=260, desc="\\supset" },       -- proper superset
    {acod='\0', fcod=0x40, fnum=capi.FONT_MATH   , ncod=261, desc="\\partial" },      -- cmmi 0x40, Figure 4
    --[[ Same GLYPH as \bot (TeX 0x3F), deliberately a separate entry rather than an alias. In
    LaTeX they are different classes: \perp is a relation and gets relation spacing, \bot is
    ordinary - "a \perp b" and "a \bot b" set differently. Which one a glyph came from is the only
    record of which was meant, so the two round-trip to their own names. ]]
    {acod='\0', fcod=0x3F, fnum=capi.FONT_SYMBOLS, ncod=263, desc="\\perp" },          -- perpendicular
    {acod='\0', fcod=0xB5, fnum=capi.FONT_MATH_EX, ncod=198, desc="\\biggl(" },        -- paranthesis '(' level 3
    {acod='\0', fcod=0xB3, fnum=capi.FONT_MATH_EX, ncod=199, desc="\\Bigl(" },         -- paranthesis '(' level 2
    {acod='\0', fcod=0xA1, fnum=capi.FONT_MATH_EX, ncod=200, desc="\\bigl(" },         -- paranthesis '(' level 1
    {acod='\0', fcod=0x21, fnum=capi.FONT_MATH_EX, ncod=201, desc="\\Biggl)" },        -- paranthesis ')' level 4
    {acod='\0', fcod=0xB6, fnum=capi.FONT_MATH_EX, ncod=202, desc="\\biggl)" },        -- paranthesis ')' level 3
    {acod='\0', fcod=0xB4, fnum=capi.FONT_MATH_EX, ncod=203, desc="\\Bigl)" },         -- paranthesis ')' level 2
    {acod='\0', fcod=0xA2, fnum=capi.FONT_MATH_EX, ncod=204, desc="\\bigl)" },         -- paranthesis ')' level 1
    {acod='\0', fcod=0x22, fnum=capi.FONT_MATH_EX, ncod=205, desc="\\Biggl[" },        -- paranthesis '[' level 4
    {acod='\0', fcod=0xB7, fnum=capi.FONT_MATH_EX, ncod=206, desc="\\biggl[" },        -- paranthesis '[' level 3
    {acod='\0', fcod=0x68, fnum=capi.FONT_MATH_EX, ncod=207, desc="\\Bigl[" },         -- paranthesis '[' level 2
    {acod='\0', fcod=0xA3, fnum=capi.FONT_MATH_EX, ncod=208, desc="\\bigl[" },         -- paranthesis '[' level 1
    {acod='\0', fcod=0x23, fnum=capi.FONT_MATH_EX, ncod=209, desc="\\Biggl]" },        -- paranthesis ']' level 4
    {acod='\0', fcod=0xB8, fnum=capi.FONT_MATH_EX, ncod=210, desc="\\biggl]" },        -- paranthesis ']' level 3
    {acod='\0', fcod=0x69, fnum=capi.FONT_MATH_EX, ncod=211, desc="\\Bigl]" },         -- paranthesis ']' level 2
    {acod='\0', fcod=0xA4, fnum=capi.FONT_MATH_EX, ncod=212, desc="\\bigl]" },         -- paranthesis ']' level 1
    {acod='\0', fcod=0x28, fnum=capi.FONT_MATH_EX, ncod=213, desc="\\Biggl{" },        -- paranthesis '{' level 4
    {acod='\0', fcod=0xBD, fnum=capi.FONT_MATH_EX, ncod=214, desc="\\biggl{" },        -- paranthesis '{' level 3
    {acod='\0', fcod=0x6E, fnum=capi.FONT_MATH_EX, ncod=215, desc="\\Bigl{" },         -- paranthesis '{' level 2
    {acod='\0', fcod=0xA9, fnum=capi.FONT_MATH_EX, ncod=216, desc="\\bigl{" },         -- paranthesis '{' level 1
    {acod='\0', fcod=0x29, fnum=capi.FONT_MATH_EX, ncod=217, desc="\\Biggl}" },        -- paranthesis '}' level 4
    {acod='\0', fcod=0xBE, fnum=capi.FONT_MATH_EX, ncod=218, desc="\\biggl}" },        -- paranthesis '}' level 3
    {acod='\0', fcod=0x6F, fnum=capi.FONT_MATH_EX, ncod=219, desc="\\Bigl}" },         -- paranthesis '}' level 2
    {acod='\0', fcod=0xAA, fnum=capi.FONT_MATH_EX, ncod=220, desc="\\bigl}" },         -- paranthesis '}' level 1
    {acod='\0', fcod=0x7B, fnum=capi.FONT_NORMAL , ncod=221, desc="\\_hline"},         -- horizontal line for building stuff
    {acod='\0', fcod=0x7C, fnum=capi.FONT_NORMAL , ncod=222, desc="\\_hline_long"},    -- longer line?
    {acod='\0', fcod=0xB9, fnum=capi.FONT_NORMAL , ncod=223, desc="\\_hline_above"},   -- same but displaced above?
    {acod='\0', fcod=0x3E, fnum=capi.FONT_MATH_EX, ncod=224, desc="\\_vline_small"},   -- those are all vertical lines
    {acod='\0', fcod=0x3F, fnum=capi.FONT_MATH_EX, ncod=225, desc="\\_vline_1"},
    {acod='\0', fcod=0x36, fnum=capi.FONT_MATH_EX, ncod=226, desc="\\_vline_2"},
    {acod='\0', fcod=0x37, fnum=capi.FONT_MATH_EX, ncod=227, desc="\\_vline_3"},
    {acod='\0', fcod=0x42, fnum=capi.FONT_MATH_EX, ncod=228, desc="\\_vline_4"},
    {acod='\0', fcod=0x43, fnum=capi.FONT_MATH_EX, ncod=229, desc="\\_vline_5"},
    {acod='\0', fcod=0x75, fnum=capi.FONT_MATH_EX, ncod=230, desc="\\_vline_6"},       -- this is a bit different
    {acod='\0', fcod=0x30, fnum=capi.FONT_MATH_EX, ncod=231, desc="\\_brack_lt_round" },
    {acod='\0', fcod=0x31, fnum=capi.FONT_MATH_EX, ncod=232, desc="\\_brack_rt_round" },
    {acod='\0', fcod=0x40, fnum=capi.FONT_MATH_EX, ncod=233, desc="\\_brack_lb_round" },
    {acod='\0', fcod=0x41, fnum=capi.FONT_MATH_EX, ncod=234, desc="\\_brack_rb_round" },
    {acod='\0', fcod=0x32, fnum=capi.FONT_MATH_EX, ncod=235, desc="\\_brack_lt_square" },
    {acod='\0', fcod=0x33, fnum=capi.FONT_MATH_EX, ncod=236, desc="\\_brack_rt_square" },
    {acod='\0', fcod=0x34, fnum=capi.FONT_MATH_EX, ncod=237, desc="\\_brack_lb_square" },
    {acod='\0', fcod=0x35, fnum=capi.FONT_MATH_EX, ncod=238, desc="\\_brack_rb_square" },
    {acod='\0', fcod=0x38, fnum=capi.FONT_MATH_EX, ncod=239, desc="\\_brack_lt_curly" },
    {acod='\0', fcod=0x39, fnum=capi.FONT_MATH_EX, ncod=240, desc="\\_brack_rt_curly" },
    {acod='\0', fcod=0x3A, fnum=capi.FONT_MATH_EX, ncod=241, desc="\\_brack_lb_curly" },
    {acod='\0', fcod=0x3B, fnum=capi.FONT_MATH_EX, ncod=242, desc="\\_brack_rb_curly" },
    {acod='\0', fcod=0x3C, fnum=capi.FONT_MATH_EX, ncod=243, desc="\\_brack_lc_curly" },
    {acod='\0', fcod=0x3D, fnum=capi.FONT_MATH_EX, ncod=244, desc="\\_brack_rc_curly" },
    {acod='<',  fcod=0x3C, fnum=capi.FONT_MATH   , ncod=245, desc="<" },
    {acod='>',  fcod=0x3E, fnum=capi.FONT_MATH   , ncod=246, desc=">" },
    {acod=' ',  fcod=0x20, fnum=capi.FONT_NORMAL , ncod=247, desc=" " },
    --[[ TeX's spacing commands, added 2026-09-06. Each is the SPACE glyph - no ink at all -
    with its own width, set in capi.adv_by_desc below (TeX's own fractions of an em: 3/18, 4/18,
    5/18, 1 and 2). mexpr_symbol sizes an inkless glyph from its advance, so the width IS the atom.

    Separate entries rather than one shared space so each keeps its own name and writes back out as
    itself - "\\,"  in, "\\,"  out - instead of every gap flattening to one width.

    \\! is a NEGATIVE thin space in TeX. Zero here, because adv_em treats a negative value as "no
    override": it survives as a real, deletable atom that round-trips, it just does not pull the
    next glyph back. ]]
    {acod='\0', fcod=0x20, fnum=capi.FONT_NORMAL , ncod=264, desc="\\," },            -- thin space
    {acod='\0', fcod=0x20, fnum=capi.FONT_NORMAL , ncod=265, desc="\\:" },            -- medium space
    {acod='\0', fcod=0x20, fnum=capi.FONT_NORMAL , ncod=266, desc="\\;" },            -- thick space
    {acod='\0', fcod=0x20, fnum=capi.FONT_NORMAL , ncod=267, desc="\\!" },            -- negative thin
    {acod='\0', fcod=0x20, fnum=capi.FONT_NORMAL , ncod=268, desc="\\quad" },        -- 1 em
    {acod='\0', fcod=0x20, fnum=capi.FONT_NORMAL , ncod=269, desc="\\qquad" },       -- 2 em

    --[[ ACCENT glyphs, for mexpr_dress()/mexpr_accent() (math_expr_composer.h).

    The hat and tilde a formula can already contain ARE the accent shapes: cmr10 is encoded OT1,
    where 0x5E is the circumflex ACCENT and 0x7E the tilde ACCENT - which is why ncod 58 and 90
    above sit high rather than on the baseline. So only the dot needs adding: OT1 puts it at 0x5F,
    but the '_' entry above deliberately takes that slot from FONT_MONO, where it really is an
    underscore.

    The wide variants come from cmex10, and are what TEXbook Appendix G Rule 12's successor search
    walks: "if the accent character has a successor in its font whose width is <= u, change it to
    the successor and repeat". Listed narrowest-first in the accent tables at the bottom of this
    file, the same order and for the same purpose as the bracket tables' left[]/right[]. There is
    no bar/macron glyph in any of these fonts (OT1 0x16 is absent from the .ttf cmaps) - a bar is
    drawn instead.
    ]]
    {acod='\0', fcod=0x5F, fnum=capi.FONT_NORMAL , ncod=249, desc="\\dot" },
    {acod='\0', fcod=0x7E, fnum=capi.FONT_MATH   , ncod=248, desc="\\vec" },              -- cmmi vector accent
    {acod='\0', fcod=0x62, fnum=capi.FONT_MATH_EX, ncod=250, desc="\\widehat1" },
    {acod='\0', fcod=0x63, fnum=capi.FONT_MATH_EX, ncod=251, desc="\\widehat2" },
    {acod='\0', fcod=0x64, fnum=capi.FONT_MATH_EX, ncod=252, desc="\\widehat3" },
    {acod='\0', fcod=0x65, fnum=capi.FONT_MATH_EX, ncod=253, desc="\\widetilde1" },
    {acod='\0', fcod=0x66, fnum=capi.FONT_MATH_EX, ncod=254, desc="\\widetilde2" },
    {acod='\0', fcod=0x67, fnum=capi.FONT_MATH_EX, ncod=255, desc="\\widetilde3" },
}

-- #################################################################################################
-- Indexed lookups (built once here instead of the linear scans mexpr.lua used to do per glyph
-- per frame)
-- #################################################################################################

local by_ascii = {}
local by_desc = {}
local by_ncod = {}
for _, c in ipairs(capi.chars) do
    if c.acod ~= '\0' and by_ascii[c.acod] == nil then
        by_ascii[c.acod] = c
    end
    if c.desc and by_desc[c.desc] == nil then
        by_desc[c.desc] = c
    end
    by_ncod[c.ncod] = c
end

--[[ Returns the capi.chars entry for an ascii character (a 1-length string), or nil.
When a character appears more than once in capi.chars (a few do), the first entry in the table
wins - same as the old linear-scan behavior this replaces. ]]
function capi.find_by_ascii(ascii_char)
    return by_ascii[ascii_char]
end

--[[ Spellings that mean an EXISTING glyph rather than a new one.

A table, not extra rows in capi.chars, and that distinction matters: by_ncod maps one code to one
entry, so a second row sharing an ncod would make to_latex()'s choice of name depend on table order.
Aliases resolve on the way IN only. What comes back out is always the primary desc, so a document
round-trips to one canonical spelling.

  - leq/geq/land/lor are just LaTeX's other names for glyphs already here.
  - to is by far the commonest way to write a rightarrow, and what "->" produces.
  - setminus IS the backslash glyph (TeX 0x6E - see Figure 5), already registered as "\\\\".
  - cong is BACK-COMPATIBILITY: that name used to be attached to the identity sign by mistake, so
    documents saved before 2026-09-06 still contain it. They load as the glyph they always drew. ]]
capi.desc_aliases = {
    ["\\leq"]      = "\\le",
    ["\\geq"]      = "\\ge",
    ["\\land"]     = "\\wedge",
    ["\\lor"]      = "\\vee",
    ["\\to"]       = "\\rightarrow",
    ["\\setminus"] = "\\",
    ["\\cong"]     = "\\equiv",
}

--[[ Returns the capi.chars entry whose `desc` matches exactly (e.g. "\\alpha"), or nil.
Falls back to capi.desc_aliases, so an alternate spelling finds the same glyph. ]]
function capi.find_by_desc(desc)
    local hit = by_desc[desc]
    if hit then
        return hit
    end
    local aliased = capi.desc_aliases[desc]
    return aliased and by_desc[aliased] or nil
end

--[[ Returns the capi.chars entry for a given ncod (glyph catalog code), or nil. ]]
function capi.find_by_ncod(ncod)
    return by_ncod[ncod]
end

-- #################################################################################################
-- Alt-key Greek input: Alt+letter -> lowercase greek, Alt+Shift+letter -> uppercase greek where
-- it exists as a distinct glyph (else the caller falls back to the plain/uppercase Latin letter,
-- matching old/comments.h's own fallback behavior).
-- #################################################################################################

--[[ The common "greek keyboard" mnemonic mapping (not old/comments.h's own table, which was
fairly arbitrary - e.g. it mapped alt+n to eta). 'o', 'q', 'v' are intentionally unmapped: no
natural greek association (omicron is visually identical to 'o' and isn't in the glyph catalog). ]]
capi.greek_alt = {
    a="\\alpha",   b="\\beta", g="\\gamma",  d="\\delta", e="\\epsilon", z="\\zeta",
    h="\\eta",     j="\\theta", i="\\iota",  k="\\kappa", l="\\lambda",  m="\\mu",
    n="\\nu",      x="\\xi",   p="\\pi",     r="\\rho",   s="\\sigma",   t="\\tau",
    u="\\upsilon", f="\\phi",  c="\\chi",    y="\\psi",   w="\\omega",

    --[[ q has no Greek lowercase (there is no lowercase koppa in these fonts), so it was the one
    letter slot left. It holds the PARTIAL differential - "the other than d", asked for 2026-09-06 -
    which pairs with Alt+Shift+Q holding the integral for exactly the same "this key is free"
    reason. Both are operators on a letter key, and both are listed in greek_alt_shift's own note. ]]
    q="\\partial",
}

--[[ Only these have a distinct capital glyph in capi.chars - the rest look identical to their
Latin counterpart and were never catalogued separately. 'q' isn't a capital Greek letter at all -
'q' has no Greek association (see greek_alt's own comment), so Alt+Shift+Q was otherwise wasted
falling back to plain 'Q' - the integral sign lives here instead, freeing that keystroke up. ]]
--[[ Three entries here are OPERATORS, not letters, and that is deliberate.

`q` never had a Greek capital to hold (uppercase Koppa is not in the fonts), so the key was free and
took the integral.

`s` and `p` are real trades, made 2026-09-06 after "I do alt+shift+s and it's the same as F, that's
not good" and then "and also do product, large pi". They were Greek capital Sigma and Pi, which are
LETTERS and therefore correctly the same size as a capital F - but each is the same letterform as
the operator it shadows, so the key looked broken every time it produced the letter. Nobody reaching
for Alt+Shift+S in a formula wants a variable named Sigma; they want the operator - a different
glyph in a different font (cmex10 ncod 192, not FONT_NORMAL ncod 98) carrying size_delta_by_desc's
display-size correction. Same for Pi and \prod.

So the rule for this table is "Greek uppercase where that is what the key is FOR", not "Greek
uppercase wherever one exists". \Sigma and \Pi themselves are still reachable by typing the name and
Space, the same route every other unmapped symbol uses.

The letters left alone are the ones genuinely used AS variables - \Delta, \Omega, \Gamma, \Phi,
\Theta, \Lambda, \Xi, \Upsilon, \Psi. None of those shadows an operator. ]]
capi.greek_alt_shift = {
    g="\\Gamma", d="\\Delta", h="\\Theta", l="\\Lambda", x="\\Xi",
    u="\\Upsilon", f="\\Phi", y="\\Psi",   w="\\Omega",
    q="\\int",  s="\\sum",  p="\\prod",
}

--[[ How many size-table steps BIGGER (negative - the table runs biggest-to-smallest, see
mformula.lua's own SUB_SIZE_DELTA comment) a glyph should render at than whatever size it's typed
into, keyed by desc. Only "\\int" uses this so far - a big operator inserted at plain text size
reads as a thin, undersized squiggle instead of the display-style integral sign it's supposed to
be (compare main.lua's demo, which draws it via char.integral(sz-5) for exactly this reason) -
not a general per-glyph size feature, just this one shortcut's own fix.

-7, not -5: recalibrated after inserting two new levels (60/50, between the old 72/42)
into m_font_sizes above for Ctrl+MouseWheel zoom - those two extra rungs sit exactly inside this
delta's own path from the default (12), so the old "-5" (which used to land on 144pt, 4x the 36pt
default) only reached 96pt (2.67x) once the table grew under it - visibly "too small" again,
reported live. -7 from 12 lands back on index 5 (144pt), the same PHYSICAL target -5 always meant
against the pre-2026-09-04 table - not a new/different visual size, just re-pointed at the same one. ]]
capi.size_delta_by_desc = {
    --[[ Every one of these is -7, and that is not a coincidence: it is ONE correction, applied to
    the whole cmex10 display-operator family, because they all share the same defect.

    Measured at the default level (index 12, 36pt), against a capital 'A' at 26px:

        int/oint   22px        sum/prod/bigcup/bigcap   14px

    A display integral in real TeX stands about 3x the cap height and a display sum about 2x, so
    these arrive roughly 4x too small - fonts/cmex10.ttf carries a far larger em box than the
    metrics it was converted from, so a nominal 36pt buys about 9pt of actual ink. -7 walks 12 ->
    5 in m_font_sizes above, i.e. 36pt -> 144pt, which is exactly that factor back. It lands int at
    86px (3.3x cap) and sum at 54px (2.1x) - the TeX proportions, and the two stay in proportion to
    EACH OTHER because they were only ever off by the same constant.

    "\sum" spent a while at -4 (a literal reading of "make it twice as big"), which doubles 14 to
    27 - dead level with a capital A, which is why it came back reported as "sigma is the same
    size". Twice as big was the right instinct and the wrong arithmetic: the glyph needed to be
    un-shrunk first, not doubled from a broken baseline.

    This is a per-glyph FIX, not a general size feature. It is baked into construction (real ink)
    and deliberately never reaches u(_).sz, which stays LOGICAL - see the callers, and
    test_int_size.lua, which pins that separation. ]]
    ["\\int"]    = -7,
    ["\\oint"]   = -7,
    ["\\sum"]    = -7,
    ["\\prod"]   = -7,
    ["\\bigcup"] = -7,
    ["\\bigcap"] = -7,
}

--[[ The OTHER half of the same lossy font conversion: where size_delta_by_desc fixes how BIG these
glyphs are, this fixes WHERE they sit. Passed to register_code() as font_loc_t::y_off_em - a
fraction of the font size, positive = down, y growing downward as everywhere else.

TeX centres a big operator on the math axis (a quarter em above the baseline), so it straddles the
line rather than resting on it. fonts/cmex10.ttf reports no depth at all - every glyph in it comes
back with the same flattened ascent - so they arrive sitting entirely above the baseline instead.
Measured at the default level (36pt, baseline at 7.5, axis at -1.5):

    glyph                       ink spans     centre    axis    needs
    sum/prod/bigcup/bigcap    -55.0 .. -1.0    -28.0    -1.5    +26.5px = +0.184em
    int/oint                  -55.0 .. +31.0   -12.0    -1.5    +10.5px = +0.073em

The sum family does not touch the baseline anywhere - its lowest ink ended 8.5 units ABOVE the line
it was supposed to straddle, which is what "it is the right size, not the right placement" was
describing. The integrals do straddle, being drawn with real descent, but still hang about 10 too
high.

Two values rather than six because the family splits exactly by whether the glyph was converted with
descent or without - the same split their raw heights show (22px vs 14px, see above). Nothing here
is tuned by eye: each is (axis - centre) at the size the glyph is actually drawn at.

Kept as an em fraction so it scales with the size table and with Ctrl+MouseWheel zoom by itself. A
pixel count would be correct at exactly one size and wrong at the other seventeen - the same reason
size_delta_by_desc is a table INDEX delta rather than a point size. ]]
--[[ Advance widths this font got wrong, as a fraction of the font size. REPLACES the font's own
(font_loc_t::adv_em), unlike y_offset_by_desc which adds to it - because what these express is not a
nudge but a width TeX defines as exactly zero.

A zero-width glyph is drawn and then NOT stepped over, so the next character prints on top of it.
That is how TeX builds every negated relation: \ne is \not followed by =, \notin is \not followed
by \in. This TTF gave \not an ordinary full-width advance (measured 27.97 at the default level,
the same as the "=" it is meant to cross), so the slash landed beside the sign instead of through
it, and \ne could not be expressed at all.

Only glyphs DESIGNED to overprint belong here. Zeroing anything else makes it collide with its
neighbour. ]]
capi.adv_by_desc = {
    ["\\not"]        = 0.0,
    ["\\mapstochar"] = 0.0,

    -- TeX's own spacing widths, as fractions of an em (see the entries above).
    ["\\,"]     = 3.0 / 18.0,
    ["\\:"]     = 4.0 / 18.0,
    ["\\;"]     = 5.0 / 18.0,
    ["\\!"]     = 0.0,
    ["\\quad"]  = 1.0,
    ["\\qquad"] = 2.0,
}

capi.y_offset_by_desc = {
    ["\\sum"]    = 0.184,
    ["\\prod"]   = 0.184,
    ["\\bigcup"] = 0.184,
    ["\\bigcap"] = 0.184,
    ["\\int"]    = 0.073,
    ["\\oint"]   = 0.073,
}

--[[ Alt+PUNCTUATION: the set-theory symbols. Alt+letter is entirely spoken for by Greek, so
these live on the keys either side of it, paired by their left/right position, with Shift giving the
"bigger" relation of each pair.

The shifted pair gives the PROPER inclusions. On a US layout those keys are "<" and ">", so
Alt+Shift+, is Alt+< - the shape of the key is the shape of the sign. The or-equal forms are not
bound to anything: type "=" straight after and the shorthand upgrades the glyph in place, exactly
as "<" then "=" does (DIGRAPHS in mformula_new.lua). Asked for 2026-09-06 - "that is the inclusion
sign and included or equal should be a composite, so made with equal after".

Here rather than beside the key handler because F2's panel draws from it too - that panel's whole
claim is that it "can never drift from what the keys actually do", which only holds while both read
the same table. Adding a row here adds it to the legend.

`key` is resolved to an integer id once, below, for the same reason greek_key_ids exists: the
string form of an ImGuiKey costs a yaml node per poll. ]]
capi.alt_symbols = {
    {key = "ImGuiKey_LeftBracket",  label = "[", plain = "\\cup"},
    {key = "ImGuiKey_RightBracket", label = "]", plain = "\\cap"},
    {key = "ImGuiKey_Comma",        label = ",", plain = "\\in",  shift = "\\subset"},
    {key = "ImGuiKey_Period",       label = ".", plain = "\\ni",  shift = "\\supset"},
}

for _, sym in ipairs(capi.alt_symbols) do
    sym.key_id = vc[sym.key] or sym.key
end

--[[ ImGuiKey name -> lowercase letter, used to poll Alt+letter Greek shortcuts directly (Alt
combinations don't reliably produce char events, so this can't go through
vc.ImGui_input_queue_chars() the way plain typing does). Shared by editor.lua (plain text) and
mformula.lua (inside a formula) so both read Alt+letter the same way. ]]
capi.greek_keys = {
    ImGuiKey_A="a", ImGuiKey_B="b", ImGuiKey_C="c", ImGuiKey_D="d", ImGuiKey_E="e",
    ImGuiKey_F="f", ImGuiKey_G="g", ImGuiKey_H="h", ImGuiKey_I="i", ImGuiKey_J="j",
    ImGuiKey_K="k", ImGuiKey_L="l", ImGuiKey_M="m", ImGuiKey_N="n", ImGuiKey_O="o",
    ImGuiKey_P="p", ImGuiKey_Q="q", ImGuiKey_R="r", ImGuiKey_S="s", ImGuiKey_T="t",
    ImGuiKey_U="u", ImGuiKey_V="v", ImGuiKey_W="w", ImGuiKey_X="x", ImGuiKey_Y="y",
    ImGuiKey_Z="z",
}

--[[ greek_keys above, resolved once to the INTEGER ImGuiKey values, keyed by id instead of name.

The two Alt+letter loops that walk this (editor.lua and mformula_new.lua) call ImGui_IsKeyPressed
for all 26 entries on every frame Alt is held. Passing the NAME makes virt_composer's bm_t<ImGuiKey>
build an fkyaml::node per call to look the enum up - measured at 180.83us against 0.22us for the
integer form (20000 calls each), so 26 names cost ~4.7ms of a 16.7ms frame for as long
as Alt is down. The integers are already on the vc table (add_lua_flag_mapping), so this is just
taking the fast path that was always there.

Built here rather than in either caller so the two cannot drift, and keyed by id -> letter because
that is exactly what those loops iterate. A name that somehow does not resolve stays a string, which
still works through the slow path rather than silently never matching. ]]
capi.greek_key_ids = {}
for name, letter in pairs(capi.greek_keys) do
    capi.greek_key_ids[vc[name] or name] = letter
end

--[[ Accent recipes for mexpr_accent(). Same shape as capi.round_bracket() above - a size in, a
table out, tiers narrowest-first. `stroke` is passed only for its HEIGHT, which becomes the pen
width when the accent has to be DRAWN rather than set from a glyph (mexpr_frac's divline idiom).

hat and tilde run out of glyphs after their third cmex10 variant; past that mexpr_accent draws the
shape itself, continuing at the last tier's own height so there is no step at the boundary. A bar
has no glyph at all in these fonts, so it is always drawn - hence no tiers. ]]
function capi.hat_accent(fontsz)
    return {
        kind = "MEXPR_ACCENT_HAT",
        stroke = capi.hline_basic(fontsz),
        tiers = {
            {size = fontsz, code = 58},    -- "^" - the OT1 circumflex accent
            {size = fontsz, code = 250},
            {size = fontsz, code = 251},
            {size = fontsz, code = 252},
        },
    }
end

--[[ Vector arrows. The RIGHT one has a real accent glyph - cmmi 0x7E, what LaTeX's own \\vec
uses - at 17x8 against a letter's ~17 wide, so an ordinary single-letter vector resolves to it.
There is no left-pointing counterpart in Computer Modern at any size, and no wider right one either,
so everything else is drawn (MEXPR_ACCENT_ARROW_R/_L, math_expr_composer.h). That matters here
rather than being a corner case: a vector over a STACK is exactly what this is for, and no glyph
is anywhere near that wide.

The left one therefore lists no tiers at all - the drawn shape is its only form. ]]
function capi.vec_accent(fontsz)
    return {
        kind = "MEXPR_ACCENT_ARROW_R",
        stroke = capi.hline_basic(fontsz),
        -- No tiers on purpose - see mexpr_accent's arrow branch. cmmi's own \\vec glyph (ncod 248)
        -- is 8 tall against the drawn head's 4.25, so letting short targets use it would make
        -- the head change size with the target, which is exactly what it must not do.
        tiers = {},
    }
end

function capi.vec_left_accent(fontsz)
    return {
        kind = "MEXPR_ACCENT_ARROW_L",
        stroke = capi.hline_basic(fontsz),
        tiers = {},
    }
end

function capi.tilde_accent(fontsz)
    return {
        kind = "MEXPR_ACCENT_TILDE",
        stroke = capi.hline_basic(fontsz),
        tiers = {
            {size = fontsz, code = 90},    -- "~" - the OT1 tilde accent
            {size = fontsz, code = 253},
            {size = fontsz, code = 254},
            {size = fontsz, code = 255},
        },
    }
end

function capi.bar_accent(fontsz)
    return { kind = "MEXPR_ACCENT_RULE", stroke = capi.hline_basic(fontsz), tiers = {} }
end

-- One dot. Several are made by merging this with itself, not by a wider glyph - there is no ddot
-- in these fonts either.
function capi.dot_accent_char(fontsz) return {size = fontsz, code = 249} end


return capi

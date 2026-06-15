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

function capi.load_font_set(fontsz)
	return {
		fontsz = fontsz,
		-- Roman
        -- 		* Has some math operators/Symbols
        -- 		* Usefull for description parts of the app
		[capi.FONT_NORMAL]  = vc.create_object(nil, { m_path = "fonts/cmr10.ttf", m_font_size = fontsz, m_type = "drawc_font_t" }),

		-- Bold Extended
        -- 		* Has some math operators/Symbols
        -- 		* Usefull for description parts of the app
		[capi.FONT_BOLD]    = vc.create_object(nil, { m_path = "fonts/cmbx10.ttf", m_font_size = fontsz, m_type = "drawc_font_t" }),

		-- Text Italic
        -- 		* Has some math operators/Symbols
        -- 		* Usefull for description parts of the app
		[capi.FONT_ITALIC]  = vc.create_object(nil, { m_path = "fonts/cmti10.ttf", m_font_size = fontsz, m_type = "drawc_font_t" }),

		-- Typewriter Type
        -- 		* Has some math operators/Symbols
        -- 		* Usefull for description parts of the app
        -- 		* Has constant spacing, can be used for code writing
		[capi.FONT_MONO]    = vc.create_object(nil, { m_path = "fonts/cmtt10.ttf", m_font_size = fontsz, m_type = "drawc_font_t" }),
		
		-- Math Italic
		-- 		* Used for formulas (the variable names)
		-- 		* Has more/all greek
		-- 		* has some operators
		[capi.FONT_MATH]    = vc.create_object(nil, { m_path = "fonts/cmmi10.ttf", m_font_size = fontsz, m_type = "drawc_font_t" }),

		-- Math Symbols
		-- 		* Used for formulas
		-- 		* A lot of signs
		[capi.FONT_SYMBOLS] = vc.create_object(nil, { m_path = "fonts/cmsy10.ttf", m_font_size = fontsz, m_type = "drawc_font_t" }),

		-- Math Extension
		--		* Used for formulas
        --		* big operators
        --		* brackets
		[capi.FONT_MATH_EX] = vc.create_object(nil, { m_path = "fonts/cmex10.ttf", m_font_size = fontsz, m_type = "drawc_font_t" }),
	}
end

function capi.draw_char(fontset, c, px, py, color, do_box, box_color)
	color = color or 0xffffffff
	do_box = do_box or 0
	box_color = box_color or 0xff00ff00
	fontset[c.fnum]:char_draw(c.fcod, px, py, color, do_box, box_color)
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
    {acod='0',  fcod=0x30, fnum=capi.FONT_MATH   , ncod= 15, desc="0" },               -- digit zero
    {acod='1',  fcod=0x31, fnum=capi.FONT_MATH   , ncod= 16, desc="1" },               -- digit one
    {acod='2',  fcod=0x32, fnum=capi.FONT_MATH   , ncod= 17, desc="2" },               -- digit two
    {acod='3',  fcod=0x33, fnum=capi.FONT_MATH   , ncod= 18, desc="3" },               -- digit three
    {acod='4',  fcod=0x34, fnum=capi.FONT_MATH   , ncod= 19, desc="4" },               -- digit four
    {acod='5',  fcod=0x35, fnum=capi.FONT_MATH   , ncod= 20, desc="5" },               -- digit five
    {acod='6',  fcod=0x36, fnum=capi.FONT_MATH   , ncod= 21, desc="6" },               -- digit six
    {acod='7',  fcod=0x37, fnum=capi.FONT_MATH   , ncod= 22, desc="7" },               -- digit seven
    {acod='8',  fcod=0x38, fnum=capi.FONT_MATH   , ncod= 23, desc="8" },               -- digit eight
    {acod='9',  fcod=0x39, fnum=capi.FONT_MATH   , ncod= 24, desc="9" },               -- digit nine
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
    {acod='\0', fcod=0x30, fnum=capi.FONT_SYMBOLS, ncod=153, desc="\\partial" },       -- partial derivative
    {acod='\0', fcod=0x31, fnum=capi.FONT_SYMBOLS, ncod=154, desc="\\infty" },         -- infinity
    {acod='\0', fcod=0x32, fnum=capi.FONT_SYMBOLS, ncod=155, desc="\\in" },            -- element of
    {acod='\0', fcod=0x33, fnum=capi.FONT_SYMBOLS, ncod=156, desc="\\ni" },            -- element of backwards
    {acod='\0', fcod=0x35, fnum=capi.FONT_SYMBOLS, ncod=157, desc="\\nabla" },         -- nabla
    {acod='/',  fcod=0x36, fnum=capi.FONT_SYMBOLS, ncod=158, desc="/" },               -- forward slash
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
    {acod='\0', fcod=0xB4, fnum=capi.FONT_SYMBOLS, ncod=188, desc="\\cong" },          -- congruent
    {acod='\0', fcod=0xB6, fnum=capi.FONT_SYMBOLS, ncod=189, desc="\\supseteq" },      -- superset equal
    {acod='\0', fcod=0xB5, fnum=capi.FONT_SYMBOLS, ncod=190, desc="\\subseteq" },      -- subset equal
    {acod='\0', fcod=0x5A, fnum=capi.FONT_MATH_EX, ncod=191, desc="\\int" },           -- integration sign
    {acod='\0', fcod=0x58, fnum=capi.FONT_MATH_EX, ncod=192, desc="\\sum" },           -- summation sign
    {acod='\0', fcod=0x59, fnum=capi.FONT_MATH_EX, ncod=193, desc="\\prod" },          -- product sign
    {acod='\0', fcod=0x5B, fnum=capi.FONT_MATH_EX, ncod=194, desc="\\bigcup" },        -- large union
    {acod='\0', fcod=0x5C, fnum=capi.FONT_MATH_EX, ncod=195, desc="\\bigcap" },        -- large intersection
    {acod='\0', fcod=0x49, fnum=capi.FONT_MATH_EX, ncod=196, desc="\\oint" },          -- circle integral
    {acod='\0', fcod=0xC3, fnum=capi.FONT_MATH_EX, ncod=197, desc="\\Biggl(" },        -- paranthesis '(' level 4
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
}

return capi

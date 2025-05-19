#ifndef CHAR_H
#define CHAR_H

#include "fonts.h"

struct char_t {
    union {
        struct {
            uint32_t ccod : 8; /* ascii code, if it happens to be ascii */
            uint32_t fcod : 8; /* the code inside the font */
            uint32_t fnum : 3; /* the font number */
            uint32_t size : 3; /* the size of the char */
            uint32_t bold : 1; /* bold T/F */
            uint32_t ital : 1; /* italiic T/F */
            uint32_t resv : 8; /* reserved for later use */
        };
        uint32_t code = 0;
    };
};

struct char_desc_t {
    char_t ch;
    char desc[32];
};

char_desc_t chars[] = {
/*   0*/{.ch = {.ccod='!', .fcod=0x21, .fnum=FONT_NORMAL }, .desc="!" },               /* exclamation mark */
/*   1*/{.ch = {.ccod='"', .fcod=0x22, .fnum=FONT_NORMAL }, .desc="\""},               /* double quote */
/*   2*/{.ch = {.ccod='#', .fcod=0x23, .fnum=FONT_NORMAL }, .desc="#" },               /* hash */
/*   3*/{.ch = {.ccod='$', .fcod=0x24, .fnum=FONT_NORMAL }, .desc="$" },               /* dollar sign */
/*   4*/{.ch = {.ccod='%', .fcod=0x25, .fnum=FONT_NORMAL }, .desc="%" },               /* percent sign */
/*   5*/{.ch = {.ccod='&', .fcod=0x26, .fnum=FONT_NORMAL }, .desc="&" },               /* ampersand */
/*   6*/{.ch = {.ccod='\\',.fcod=0x27, .fnum=FONT_NORMAL }, .desc="'" },               /* single quote */
/*   7*/{.ch = {.ccod='(', .fcod=0x28, .fnum=FONT_NORMAL }, .desc="(" },               /* left parenthesis */
/*   8*/{.ch = {.ccod=')', .fcod=0x29, .fnum=FONT_NORMAL }, .desc=")" },               /* right parenthesis */
/*   9*/{.ch = {.ccod='*', .fcod=0x2A, .fnum=FONT_NORMAL }, .desc="*" },               /* asterisk */
/*  10*/{.ch = {.ccod='+', .fcod=0x2B, .fnum=FONT_NORMAL }, .desc="+" },               /* plus sign */
/*  11*/{.ch = {.ccod=',', .fcod=0x2C, .fnum=FONT_NORMAL }, .desc="," },               /* comma */
/*  12*/{.ch = {.ccod='-', .fcod=0x2D, .fnum=FONT_NORMAL }, .desc="-" },               /* hyphen-minus */
/*  13*/{.ch = {.ccod='.', .fcod=0x2E, .fnum=FONT_NORMAL }, .desc="." },               /* period */
/*  14*/{.ch = {.ccod='/', .fcod=0x2F, .fnum=FONT_NORMAL }, .desc="/" },               /* slash */
/*  15*/{.ch = {.ccod='0', .fcod=0x30, .fnum=FONT_MATH   }, .desc="0" },               /* digit zero */
/*  16*/{.ch = {.ccod='1', .fcod=0x31, .fnum=FONT_MATH   }, .desc="1" },               /* digit one */
/*  17*/{.ch = {.ccod='2', .fcod=0x32, .fnum=FONT_MATH   }, .desc="2" },               /* digit two */
/*  18*/{.ch = {.ccod='3', .fcod=0x33, .fnum=FONT_MATH   }, .desc="3" },               /* digit three */
/*  19*/{.ch = {.ccod='4', .fcod=0x34, .fnum=FONT_MATH   }, .desc="4" },               /* digit four */
/*  20*/{.ch = {.ccod='5', .fcod=0x35, .fnum=FONT_MATH   }, .desc="5" },               /* digit five */
/*  21*/{.ch = {.ccod='6', .fcod=0x36, .fnum=FONT_MATH   }, .desc="6" },               /* digit six */
/*  22*/{.ch = {.ccod='7', .fcod=0x37, .fnum=FONT_MATH   }, .desc="7" },               /* digit seven */
/*  23*/{.ch = {.ccod='8', .fcod=0x38, .fnum=FONT_MATH   }, .desc="8" },               /* digit eight */
/*  24*/{.ch = {.ccod='9', .fcod=0x39, .fnum=FONT_MATH   }, .desc="9" },               /* digit nine */
/*  25*/{.ch = {.ccod=':', .fcod=0x3A, .fnum=FONT_NORMAL }, .desc=":" },               /* colon */
/*  26*/{.ch = {.ccod=';', .fcod=0x3B, .fnum=FONT_NORMAL }, .desc=";" },               /* semicolon */
/*  27*/{.ch = {.ccod='=', .fcod=0x3D, .fnum=FONT_NORMAL }, .desc="=" },               /* equals sign */
/*  28*/{.ch = {.ccod='?', .fcod=0x3F, .fnum=FONT_NORMAL }, .desc="?" },               /* question mark */
/*  29*/{.ch = {.ccod='@', .fcod=0x40, .fnum=FONT_NORMAL }, .desc="@" },               /* at symbol */
/*  30*/{.ch = {.ccod='A', .fcod=0x41, .fnum=FONT_MATH   }, .desc="A" },               /* uppercase A */
/*  31*/{.ch = {.ccod='B', .fcod=0x42, .fnum=FONT_MATH   }, .desc="B" },               /* uppercase B */
/*  32*/{.ch = {.ccod='C', .fcod=0x43, .fnum=FONT_MATH   }, .desc="C" },               /* uppercase C */
/*  33*/{.ch = {.ccod='D', .fcod=0x44, .fnum=FONT_MATH   }, .desc="D" },               /* uppercase D */
/*  34*/{.ch = {.ccod='E', .fcod=0x45, .fnum=FONT_MATH   }, .desc="E" },               /* uppercase E */
/*  35*/{.ch = {.ccod='F', .fcod=0x46, .fnum=FONT_MATH   }, .desc="F" },               /* uppercase F */
/*  36*/{.ch = {.ccod='G', .fcod=0x47, .fnum=FONT_MATH   }, .desc="G" },               /* uppercase G */
/*  37*/{.ch = {.ccod='H', .fcod=0x48, .fnum=FONT_MATH   }, .desc="H" },               /* uppercase H */
/*  38*/{.ch = {.ccod='I', .fcod=0x49, .fnum=FONT_MATH   }, .desc="I" },               /* uppercase I */
/*  39*/{.ch = {.ccod='J', .fcod=0x4A, .fnum=FONT_MATH   }, .desc="J" },               /* uppercase J */
/*  40*/{.ch = {.ccod='K', .fcod=0x4B, .fnum=FONT_MATH   }, .desc="K" },               /* uppercase K */
/*  41*/{.ch = {.ccod='L', .fcod=0x4C, .fnum=FONT_MATH   }, .desc="L" },               /* uppercase L */
/*  42*/{.ch = {.ccod='M', .fcod=0x4D, .fnum=FONT_MATH   }, .desc="M" },               /* uppercase M */
/*  43*/{.ch = {.ccod='N', .fcod=0x4E, .fnum=FONT_MATH   }, .desc="N" },               /* uppercase N */
/*  44*/{.ch = {.ccod='O', .fcod=0x4F, .fnum=FONT_MATH   }, .desc="O" },               /* uppercase O */
/*  45*/{.ch = {.ccod='P', .fcod=0x50, .fnum=FONT_MATH   }, .desc="P" },               /* uppercase P */
/*  46*/{.ch = {.ccod='Q', .fcod=0x51, .fnum=FONT_MATH   }, .desc="Q" },               /* uppercase Q */
/*  47*/{.ch = {.ccod='R', .fcod=0x52, .fnum=FONT_MATH   }, .desc="R" },               /* uppercase R */
/*  48*/{.ch = {.ccod='S', .fcod=0x53, .fnum=FONT_MATH   }, .desc="S" },               /* uppercase S */
/*  49*/{.ch = {.ccod='T', .fcod=0x54, .fnum=FONT_MATH   }, .desc="T" },               /* uppercase T */
/*  50*/{.ch = {.ccod='U', .fcod=0x55, .fnum=FONT_MATH   }, .desc="U" },               /* uppercase U */
/*  51*/{.ch = {.ccod='V', .fcod=0x56, .fnum=FONT_MATH   }, .desc="V" },               /* uppercase V */
/*  52*/{.ch = {.ccod='W', .fcod=0x57, .fnum=FONT_MATH   }, .desc="W" },               /* uppercase W */
/*  53*/{.ch = {.ccod='X', .fcod=0x58, .fnum=FONT_MATH   }, .desc="X" },               /* uppercase X */
/*  54*/{.ch = {.ccod='Y', .fcod=0x59, .fnum=FONT_MATH   }, .desc="Y" },               /* uppercase Y */
/*  55*/{.ch = {.ccod='Z', .fcod=0x5A, .fnum=FONT_MATH   }, .desc="Z" },               /* uppercase Z */
/*  56*/{.ch = {.ccod='[', .fcod=0x5B, .fnum=FONT_NORMAL }, .desc="[" },               /* left square bracket */
/*  57*/{.ch = {.ccod=']', .fcod=0x5D, .fnum=FONT_NORMAL }, .desc="]" },               /* right square bracket */
/*  58*/{.ch = {.ccod='^', .fcod=0x5E, .fnum=FONT_NORMAL }, .desc="^" },               /* circumflex accent */
/*  59*/{.ch = {.ccod='_', .fcod=0x5F, .fnum=FONT_MONO   }, .desc="_" },               /* underscore */
/*  60*/{.ch = {.ccod='`', .fcod=0xB5, .fnum=FONT_NORMAL }, .desc="`" },               /* grave accent */
/*  61*/{.ch = {.ccod='a', .fcod=0x61, .fnum=FONT_MATH   }, .desc="a" },               /* lowercase a */
/*  62*/{.ch = {.ccod='b', .fcod=0x62, .fnum=FONT_MATH   }, .desc="b" },               /* lowercase b */
/*  63*/{.ch = {.ccod='c', .fcod=0x63, .fnum=FONT_MATH   }, .desc="c" },               /* lowercase c */
/*  64*/{.ch = {.ccod='d', .fcod=0x64, .fnum=FONT_MATH   }, .desc="d" },               /* lowercase d */
/*  65*/{.ch = {.ccod='e', .fcod=0x65, .fnum=FONT_MATH   }, .desc="e" },               /* lowercase e */
/*  66*/{.ch = {.ccod='f', .fcod=0x66, .fnum=FONT_MATH   }, .desc="f" },               /* lowercase f */
/*  67*/{.ch = {.ccod='g', .fcod=0x67, .fnum=FONT_MATH   }, .desc="g" },               /* lowercase g */
/*  68*/{.ch = {.ccod='h', .fcod=0x68, .fnum=FONT_MATH   }, .desc="h" },               /* lowercase h */
/*  69*/{.ch = {.ccod='i', .fcod=0x69, .fnum=FONT_MATH   }, .desc="i" },               /* lowercase i */
/*  70*/{.ch = {.ccod='j', .fcod=0x6A, .fnum=FONT_MATH   }, .desc="j" },               /* lowercase j */
/*  71*/{.ch = {.ccod='k', .fcod=0x6B, .fnum=FONT_MATH   }, .desc="k" },               /* lowercase k */
/*  72*/{.ch = {.ccod='l', .fcod=0x6C, .fnum=FONT_MATH   }, .desc="l" },               /* lowercase l */
/*  73*/{.ch = {.ccod='m', .fcod=0x6D, .fnum=FONT_MATH   }, .desc="m" },               /* lowercase m */
/*  74*/{.ch = {.ccod='n', .fcod=0x6E, .fnum=FONT_MATH   }, .desc="n" },               /* lowercase n */
/*  75*/{.ch = {.ccod='o', .fcod=0x6F, .fnum=FONT_MATH   }, .desc="o" },               /* lowercase o */
/*  76*/{.ch = {.ccod='p', .fcod=0x70, .fnum=FONT_MATH   }, .desc="p" },               /* lowercase p */
/*  77*/{.ch = {.ccod='q', .fcod=0x71, .fnum=FONT_MATH   }, .desc="q" },               /* lowercase q */
/*  78*/{.ch = {.ccod='r', .fcod=0x72, .fnum=FONT_MATH   }, .desc="r" },               /* lowercase r */
/*  79*/{.ch = {.ccod='s', .fcod=0x73, .fnum=FONT_MATH   }, .desc="s" },               /* lowercase s */
/*  80*/{.ch = {.ccod='t', .fcod=0x74, .fnum=FONT_MATH   }, .desc="t" },               /* lowercase t */
/*  81*/{.ch = {.ccod='u', .fcod=0x75, .fnum=FONT_MATH   }, .desc="u" },               /* lowercase u */
/*  82*/{.ch = {.ccod='v', .fcod=0x76, .fnum=FONT_MATH   }, .desc="v" },               /* lowercase v */
/*  83*/{.ch = {.ccod='w', .fcod=0x77, .fnum=FONT_MATH   }, .desc="w" },               /* lowercase w */
/*  84*/{.ch = {.ccod='x', .fcod=0x78, .fnum=FONT_MATH   }, .desc="x" },               /* lowercase x */
/*  85*/{.ch = {.ccod='y', .fcod=0x79, .fnum=FONT_MATH   }, .desc="y" },               /* lowercase y */
/*  86*/{.ch = {.ccod='z', .fcod=0x7A, .fnum=FONT_MATH   }, .desc="z" },               /* lowercase z */
/*  87*/{.ch = {.ccod='{', .fcod=0x66, .fnum=FONT_SYMBOLS}, .desc="{" },               /* left curly brace */
/*  88*/{.ch = {.ccod='|', .fcod=0x6A, .fnum=FONT_SYMBOLS}, .desc="|" },               /* vertical bar */
/*  89*/{.ch = {.ccod='}', .fcod=0x67, .fnum=FONT_SYMBOLS}, .desc="}" },               /* right curly brace */
/*  90*/{.ch = {.ccod='~', .fcod=0x7E, .fnum=FONT_NORMAL }, .desc="~" },               /* tilde */
/*  91*/{.ch = {.ccod='\\',.fcod=0x6E, .fnum=FONT_SYMBOLS}, .desc="\\"},               /* backslash */
/*  92*/{.ch = {.ccod='\0',.fcod=0xA1, .fnum=FONT_NORMAL }, .desc="\\Gamma" },         /* Greek uppercase Gamma */
/*  93*/{.ch = {.ccod='\0',.fcod=0xA2, .fnum=FONT_NORMAL }, .desc="\\Delta" },         /* Greek uppercase Delta */
/*  94*/{.ch = {.ccod='\0',.fcod=0xA3, .fnum=FONT_NORMAL }, .desc="\\Theta" },         /* Greek uppercase Theta */
/*  95*/{.ch = {.ccod='\0',.fcod=0xA4, .fnum=FONT_NORMAL }, .desc="\\Lambda" },        /* Greek uppercase Lambda */
/*  96*/{.ch = {.ccod='\0',.fcod=0xA5, .fnum=FONT_NORMAL }, .desc="\\Xi" },            /* Greek uppercase Xi */
/*  97*/{.ch = {.ccod='\0',.fcod=0xA6, .fnum=FONT_NORMAL }, .desc="\\Pi" },            /* Greek uppercase Pi */
/*  98*/{.ch = {.ccod='\0',.fcod=0xA7, .fnum=FONT_NORMAL }, .desc="\\Sigma" },         /* Greek uppercase Sigma */
/*  99*/{.ch = {.ccod='\0',.fcod=0xA8, .fnum=FONT_NORMAL }, .desc="\\Upsilon" },       /* Greek uppercase Upsilon */
/* 100*/{.ch = {.ccod='\0',.fcod=0xA9, .fnum=FONT_NORMAL }, .desc="\\Phi" },           /* Greek uppercase Phi */
/* 101*/{.ch = {.ccod='\0',.fcod=0xAA, .fnum=FONT_NORMAL }, .desc="\\Psi" },           /* Greek uppercase Psi */
/* 102*/{.ch = {.ccod='\0',.fcod=0xAB, .fnum=FONT_NORMAL }, .desc="\\Omega" },         /* Greek uppercase Omega */
/* 103*/{.ch = {.ccod='\0',.fcod=0xAE, .fnum=FONT_MATH   }, .desc="\\alpha" },         /* Greek lowercase alpha */
/* 104*/{.ch = {.ccod='\0',.fcod=0xAF, .fnum=FONT_MATH   }, .desc="\\beta" },          /* Greek lowercase beta */
/* 105*/{.ch = {.ccod='\0',.fcod=0xB0, .fnum=FONT_MATH   }, .desc="\\gamma" },         /* Greek lowercase gamma */
/* 106*/{.ch = {.ccod='\0',.fcod=0xB1, .fnum=FONT_MATH   }, .desc="\\delta" },         /* Greek lowercase delta */
/* 107*/{.ch = {.ccod='\0',.fcod=0xB2, .fnum=FONT_MATH   }, .desc="\\epsilon" },       /* Greek lowercase epsilon */
/* 108*/{.ch = {.ccod='\0',.fcod=0xB3, .fnum=FONT_MATH   }, .desc="\\zeta" },          /* Greek lowercase zeta */
/* 109*/{.ch = {.ccod='\0',.fcod=0xB4, .fnum=FONT_MATH   }, .desc="\\eta" },           /* Greek lowercase eta */
/* 110*/{.ch = {.ccod='\0',.fcod=0xB5, .fnum=FONT_MATH   }, .desc="\\theta" },         /* Greek lowercase theta */
/* 111*/{.ch = {.ccod='\0',.fcod=0xB6, .fnum=FONT_MATH   }, .desc="\\iota" },          /* Greek lowercase iota */
/* 112*/{.ch = {.ccod='\0',.fcod=0xB7, .fnum=FONT_MATH   }, .desc="\\kappa" },         /* Greek lowercase kappa */
/* 113*/{.ch = {.ccod='\0',.fcod=0xB8, .fnum=FONT_MATH   }, .desc="\\lambda" },        /* Greek lowercase lambda */
/* 114*/{.ch = {.ccod='\0',.fcod=0xB9, .fnum=FONT_MATH   }, .desc="\\mu" },            /* Greek lowercase mu */
/* 115*/{.ch = {.ccod='\0',.fcod=0xBA, .fnum=FONT_MATH   }, .desc="\\nu" },            /* Greek lowercase nu */
/* 116*/{.ch = {.ccod='\0',.fcod=0xBB, .fnum=FONT_MATH   }, .desc="\\xi" },            /* Greek lowercase xi */
/* 117*/{.ch = {.ccod='\0',.fcod=0xBC, .fnum=FONT_MATH   }, .desc="\\pi" },            /* Greek lowercase omicron */
/* 118*/{.ch = {.ccod='\0',.fcod=0xBD, .fnum=FONT_MATH   }, .desc="\\rho" },           /* Greek lowercase pi */
/* 119*/{.ch = {.ccod='\0',.fcod=0xBE, .fnum=FONT_MATH   }, .desc="\\sigma" },         /* Greek lowercase rho */
/* 120*/{.ch = {.ccod='\0',.fcod=0xBF, .fnum=FONT_MATH   }, .desc="\\tau" },           /* Greek lowercase sigma */
/* 121*/{.ch = {.ccod='\0',.fcod=0xC0, .fnum=FONT_MATH   }, .desc="\\upsilon" },       /* Greek lowercase tau */
/* 122*/{.ch = {.ccod='\0',.fcod=0xC1, .fnum=FONT_MATH   }, .desc="\\phi" },           /* Greek lowercase upsilon */
/* 123*/{.ch = {.ccod='\0',.fcod=0xC2, .fnum=FONT_MATH   }, .desc="\\chi" },           /* Greek lowercase phi */
/* 124*/{.ch = {.ccod='\0',.fcod=0xC3, .fnum=FONT_MATH   }, .desc="\\psi" },           /* Greek lowercase chi */
/* 125*/{.ch = {.ccod='\0',.fcod=0x21, .fnum=FONT_MATH   }, .desc="\\omega" },         /* Greek lowercase psi */
/* 126*/{.ch = {.ccod='\0',.fcod=0xA1, .fnum=FONT_MATH   }, .desc="\\Gamma" },         /* Greek uppercase Gamma */
/* 127*/{.ch = {.ccod='\0',.fcod=0xA2, .fnum=FONT_MATH   }, .desc="\\Delta" },         /* Greek uppercase Delta */
/* 128*/{.ch = {.ccod='\0',.fcod=0xA3, .fnum=FONT_MATH   }, .desc="\\Theta" },         /* Greek uppercase Theta */
/* 129*/{.ch = {.ccod='\0',.fcod=0xA4, .fnum=FONT_MATH   }, .desc="\\Lambda" },        /* Greek uppercase Lambda */
/* 130*/{.ch = {.ccod='\0',.fcod=0xA5, .fnum=FONT_MATH   }, .desc="\\Xi" },            /* Greek uppercase Xi */
/* 131*/{.ch = {.ccod='\0',.fcod=0xA6, .fnum=FONT_MATH   }, .desc="\\Pi" },            /* Greek uppercase Pi */
/* 132*/{.ch = {.ccod='\0',.fcod=0xA7, .fnum=FONT_MATH   }, .desc="\\Sigma" },         /* Greek uppercase Sigma */
/* 133*/{.ch = {.ccod='\0',.fcod=0xA8, .fnum=FONT_MATH   }, .desc="\\Upsilon" },       /* Greek uppercase Upsilon */
/* 134*/{.ch = {.ccod='\0',.fcod=0xA9, .fnum=FONT_MATH   }, .desc="\\Phi" },           /* Greek uppercase Phi */
/* 135*/{.ch = {.ccod='\0',.fcod=0xAA, .fnum=FONT_MATH   }, .desc="\\Psi" },           /* Greek uppercase Psi */
/* 136*/{.ch = {.ccod='\0',.fcod=0xAB, .fnum=FONT_MATH   }, .desc="\\Omega" },         /* Greek uppercase Omega */
/* 137*/{.ch = {.ccod='\0',.fcod=0xC3, .fnum=FONT_SYMBOLS}, .desc="\\leftarrow" },     /* left arrow */
/* 138*/{.ch = {.ccod='\0',.fcod=0x21, .fnum=FONT_SYMBOLS}, .desc="\\rightarrow" },    /* right arrow */
/* 139*/{.ch = {.ccod='\0',.fcod=0x22, .fnum=FONT_SYMBOLS}, .desc="\\uparrow" },       /* up arrow */
/* 140*/{.ch = {.ccod='\0',.fcod=0x23, .fnum=FONT_SYMBOLS}, .desc="\\downarrow" },     /* down arrow */
/* 141*/{.ch = {.ccod='\0',.fcod=0x24, .fnum=FONT_SYMBOLS}, .desc="\\leftrightarrow" },/* left-right arrow */
/* 142*/{.ch = {.ccod='\0',.fcod=0x25, .fnum=FONT_SYMBOLS}, .desc="\\nearrow" },       /* north-east arrow */
/* 143*/{.ch = {.ccod='\0',.fcod=0x26, .fnum=FONT_SYMBOLS}, .desc="\\searrow" },       /* south-east arrow */
/* 144*/{.ch = {.ccod='\0',.fcod=0x27, .fnum=FONT_SYMBOLS}, .desc="\\simeq" },         /* approximately equal */
/* 145*/{.ch = {.ccod='\0',.fcod=0x28, .fnum=FONT_SYMBOLS}, .desc="\\Leftarrow" },     /* left double arrow */
/* 146*/{.ch = {.ccod='\0',.fcod=0x29, .fnum=FONT_SYMBOLS}, .desc="\\Rightarrow" },    /* right double arrow */
/* 147*/{.ch = {.ccod='\0',.fcod=0x2A, .fnum=FONT_SYMBOLS}, .desc="\\Uparrow" },       /* up double arrow */
/* 148*/{.ch = {.ccod='\0',.fcod=0x2B, .fnum=FONT_SYMBOLS}, .desc="\\Downarrow" },     /* down double arrow */
/* 149*/{.ch = {.ccod='\0',.fcod=0x2C, .fnum=FONT_SYMBOLS}, .desc="\\Leftrightarrow" },/* left-right double arrow */
/* 150*/{.ch = {.ccod='\0',.fcod=0x2D, .fnum=FONT_SYMBOLS}, .desc="\\nwarrow" },       /* north-west arrow */
/* 151*/{.ch = {.ccod='\0',.fcod=0x2E, .fnum=FONT_SYMBOLS}, .desc="\\swarrow" },       /* south-west arrow */
/* 152*/{.ch = {.ccod='\0',.fcod=0x2F, .fnum=FONT_SYMBOLS}, .desc="\\propto" },        /* proportional to */
/* 153*/{.ch = {.ccod='\0',.fcod=0x30, .fnum=FONT_SYMBOLS}, .desc="\\partial" },       /* partial derivative */
/* 154*/{.ch = {.ccod='\0',.fcod=0x31, .fnum=FONT_SYMBOLS}, .desc="\\infty" },         /* infinity */
/* 155*/{.ch = {.ccod='\0',.fcod=0x32, .fnum=FONT_SYMBOLS}, .desc="\\in" },            /* element of */
/* 156*/{.ch = {.ccod='\0',.fcod=0x33, .fnum=FONT_SYMBOLS}, .desc="\\ni" },            /* element of backwards */
/* 157*/{.ch = {.ccod='\0',.fcod=0x35, .fnum=FONT_SYMBOLS}, .desc="\\nabla" },         /* nabla */
/* 158*/{.ch = {.ccod='/', .fcod=0x36, .fnum=FONT_SYMBOLS}, .desc="/" },               /* forward slash */
/* 159*/{.ch = {.ccod='\0',.fcod=0x38, .fnum=FONT_SYMBOLS}, .desc="\\forall" },        /* for all */
/* 160*/{.ch = {.ccod='\0',.fcod=0x39, .fnum=FONT_SYMBOLS}, .desc="\\exists" },        /* exists */
/* 161*/{.ch = {.ccod='\0',.fcod=0x3A, .fnum=FONT_SYMBOLS}, .desc="\\neg" },           /* negation */
/* 162*/{.ch = {.ccod='\0',.fcod=0x3B, .fnum=FONT_SYMBOLS}, .desc="\\emptyset" },      /* empty set */
/* 163*/{.ch = {.ccod='\0',.fcod=0x3C, .fnum=FONT_SYMBOLS}, .desc="\\Re" },            /* real part */
/* 164*/{.ch = {.ccod='\0',.fcod=0x3D, .fnum=FONT_SYMBOLS}, .desc="\\Im" },            /* imaginary part */
/* 165*/{.ch = {.ccod='\0',.fcod=0x3E, .fnum=FONT_SYMBOLS}, .desc="\\top" },           /* top */
/* 166*/{.ch = {.ccod='\0',.fcod=0x3F, .fnum=FONT_SYMBOLS}, .desc="\\bot" },           /* bottom */
/* 167*/{.ch = {.ccod='\0',.fcod=0x40, .fnum=FONT_SYMBOLS}, .desc="\\aleph" },         /* aleph */
/* 168*/{.ch = {.ccod='\0',.fcod=0x5B, .fnum=FONT_SYMBOLS}, .desc="\\cup" },           /* union */
/* 169*/{.ch = {.ccod='\0',.fcod=0x5C, .fnum=FONT_SYMBOLS}, .desc="\\cap" },           /* intersection */
/* 170*/{.ch = {.ccod='\0',.fcod=0x5D, .fnum=FONT_SYMBOLS}, .desc="\\uplus" },         /* multiset union */
/* 171*/{.ch = {.ccod='\0',.fcod=0x5E, .fnum=FONT_SYMBOLS}, .desc="\\wedge" },         /* logical and */
/* 172*/{.ch = {.ccod='\0',.fcod=0x5F, .fnum=FONT_SYMBOLS}, .desc="\\vee" },           /* logical or */
/* 173*/{.ch = {.ccod='\0',.fcod=0x66, .fnum=FONT_SYMBOLS}, .desc="\\{" },             /* DUPLICATE - left brace */
/* 174*/{.ch = {.ccod='\0',.fcod=0x67, .fnum=FONT_SYMBOLS}, .desc="\\}" },             /* DUPLICATE - right brace */
/* 175*/{.ch = {.ccod='\0',.fcod=0x6A, .fnum=FONT_SYMBOLS}, .desc="\\|" },             /* vertical bar */
/* 176*/{.ch = {.ccod='\0',.fcod=0x6B, .fnum=FONT_SYMBOLS}, .desc="\\parallel" },      /* parallel */
/* 177*/{.ch = {.ccod='\0',.fcod=0xBF, .fnum=FONT_SYMBOLS}, .desc="\\ll" },            /* much less than */
/* 178*/{.ch = {.ccod='\0',.fcod=0xC0, .fnum=FONT_SYMBOLS}, .desc="\\gg" },            /* much greater than */
/* 179*/{.ch = {.ccod='\0',.fcod=0xB1, .fnum=FONT_SYMBOLS}, .desc="\\circ" },          /* circle */
/* 180*/{.ch = {.ccod='\0',.fcod=0xB2, .fnum=FONT_SYMBOLS}, .desc="\\bullet" },        /* bullet */
/* 181*/{.ch = {.ccod='-' ,.fcod=0xA1, .fnum=FONT_SYMBOLS}, .desc="-" },               /* minus sign */
/* 182*/{.ch = {.ccod='\0',.fcod=0xA3, .fnum=FONT_SYMBOLS}, .desc="\\times" },         /* multiplication sign */
/* 183*/{.ch = {.ccod='\0',.fcod=0xA5, .fnum=FONT_SYMBOLS}, .desc="\\div" },           /* division sign */
/* 184*/{.ch = {.ccod='\0',.fcod=0xA7, .fnum=FONT_SYMBOLS}, .desc="\\pm" },            /* plus-minus sign */
/* 185*/{.ch = {.ccod='\0',.fcod=0xA8, .fnum=FONT_SYMBOLS}, .desc="\\mp" },            /* minus-plus sign */
/* 186*/{.ch = {.ccod='\0',.fcod=0xB7, .fnum=FONT_SYMBOLS}, .desc="\\le" },            /* less than or equal */
/* 187*/{.ch = {.ccod='\0',.fcod=0xB8, .fnum=FONT_SYMBOLS}, .desc="\\ge" },            /* greater than or equal */
/* 188*/{.ch = {.ccod='\0',.fcod=0xB4, .fnum=FONT_SYMBOLS}, .desc="\\cong" },          /* congruent */
/* 189*/{.ch = {.ccod='\0',.fcod=0xB6, .fnum=FONT_SYMBOLS}, .desc="\\supseteq" },      /* superset equal */
/* 190*/{.ch = {.ccod='\0',.fcod=0xB5, .fnum=FONT_SYMBOLS}, .desc="\\subseteq" },      /* subset equal */
/* 191*/{.ch = {.ccod='\0',.fcod=0x5A, .fnum=FONT_MATH_EX}, .desc="\\int" },           /* integration sign */
/* 192*/{.ch = {.ccod='\0',.fcod=0x58, .fnum=FONT_MATH_EX}, .desc="\\sum" },           /* summation sign */
/* 193*/{.ch = {.ccod='\0',.fcod=0x59, .fnum=FONT_MATH_EX}, .desc="\\prod" },          /* product sign */
/* 194*/{.ch = {.ccod='\0',.fcod=0x5B, .fnum=FONT_MATH_EX}, .desc="\\bigcup" },        /* large union */
/* 195*/{.ch = {.ccod='\0',.fcod=0x5C, .fnum=FONT_MATH_EX}, .desc="\\bigcap" },        /* large intersection */
/* 196*/{.ch = {.ccod='\0',.fcod=0x49, .fnum=FONT_MATH_EX}, .desc="\\oint" },          /* circle integral */
/* 197*/{.ch = {.ccod='\0',.fcod=0xC3, .fnum=FONT_MATH_EX}, .desc="\\Biggl(" },        /* paranthesis '(' level 4 */
/* 198*/{.ch = {.ccod='\0',.fcod=0xB5, .fnum=FONT_MATH_EX}, .desc="\\biggl(" },        /* paranthesis '(' level 3 */
/* 199*/{.ch = {.ccod='\0',.fcod=0xB3, .fnum=FONT_MATH_EX}, .desc="\\Bigl(" },         /* paranthesis '(' level 2 */
/* 200*/{.ch = {.ccod='\0',.fcod=0xA1, .fnum=FONT_MATH_EX}, .desc="\\bigl(" },         /* paranthesis '(' level 1 */
/* 201*/{.ch = {.ccod='\0',.fcod=0x21, .fnum=FONT_MATH_EX}, .desc="\\Biggl)" },        /* paranthesis ')' level 4 */
/* 202*/{.ch = {.ccod='\0',.fcod=0xB6, .fnum=FONT_MATH_EX}, .desc="\\biggl)" },        /* paranthesis ')' level 3 */
/* 203*/{.ch = {.ccod='\0',.fcod=0xB4, .fnum=FONT_MATH_EX}, .desc="\\Bigl)" },         /* paranthesis ')' level 2 */
/* 204*/{.ch = {.ccod='\0',.fcod=0xA2, .fnum=FONT_MATH_EX}, .desc="\\bigl)" },         /* paranthesis ')' level 1 */
/* 205*/{.ch = {.ccod='\0',.fcod=0x22, .fnum=FONT_MATH_EX}, .desc="\\Biggl[" },        /* paranthesis '[' level 4 */
/* 206*/{.ch = {.ccod='\0',.fcod=0xB7, .fnum=FONT_MATH_EX}, .desc="\\biggl[" },        /* paranthesis '[' level 3 */
/* 207*/{.ch = {.ccod='\0',.fcod=0x68, .fnum=FONT_MATH_EX}, .desc="\\Bigl[" },         /* paranthesis '[' level 2 */
/* 208*/{.ch = {.ccod='\0',.fcod=0xA3, .fnum=FONT_MATH_EX}, .desc="\\bigl[" },         /* paranthesis '[' level 1 */
/* 209*/{.ch = {.ccod='\0',.fcod=0x23, .fnum=FONT_MATH_EX}, .desc="\\Biggl]" },        /* paranthesis ']' level 4 */
/* 210*/{.ch = {.ccod='\0',.fcod=0xB8, .fnum=FONT_MATH_EX}, .desc="\\biggl]" },        /* paranthesis ']' level 3 */
/* 211*/{.ch = {.ccod='\0',.fcod=0x69, .fnum=FONT_MATH_EX}, .desc="\\Bigl]" },         /* paranthesis ']' level 2 */
/* 212*/{.ch = {.ccod='\0',.fcod=0xA4, .fnum=FONT_MATH_EX}, .desc="\\bigl]" },         /* paranthesis ']' level 1 */
/* 213*/{.ch = {.ccod='\0',.fcod=0x28, .fnum=FONT_MATH_EX}, .desc="\\Biggl{" },        /* paranthesis '{' level 4 */
/* 214*/{.ch = {.ccod='\0',.fcod=0xBD, .fnum=FONT_MATH_EX}, .desc="\\biggl{" },        /* paranthesis '{' level 3 */
/* 215*/{.ch = {.ccod='\0',.fcod=0x6E, .fnum=FONT_MATH_EX}, .desc="\\Bigl{" },         /* paranthesis '{' level 2 */
/* 216*/{.ch = {.ccod='\0',.fcod=0xA9, .fnum=FONT_MATH_EX}, .desc="\\bigl{" },         /* paranthesis '{' level 1 */
/* 217*/{.ch = {.ccod='\0',.fcod=0x29, .fnum=FONT_MATH_EX}, .desc="\\Biggl}" },        /* paranthesis '}' level 4 */
/* 218*/{.ch = {.ccod='\0',.fcod=0xBE, .fnum=FONT_MATH_EX}, .desc="\\biggl}" },        /* paranthesis '}' level 3 */
/* 219*/{.ch = {.ccod='\0',.fcod=0x6F, .fnum=FONT_MATH_EX}, .desc="\\Bigl}" },         /* paranthesis '}' level 2 */
/* 220*/{.ch = {.ccod='\0',.fcod=0xAA, .fnum=FONT_MATH_EX}, .desc="\\bigl}" },         /* paranthesis '}' level 1 */
/* 221*/{.ch = {.ccod='\0',.fcod=0x7B, .fnum=FONT_NORMAL }, .desc="\\_hline"},         /* horizontal line for building stuff */
/* 222*/{.ch = {.ccod='\0',.fcod=0x7C, .fnum=FONT_NORMAL }, .desc="\\_hline_long"},    /* longer line? */
/* 223*/{.ch = {.ccod='\0',.fcod=0xB9, .fnum=FONT_NORMAL }, .desc="\\_hline_above"},   /* same but displaced above? */
/* 224*/{.ch = {.ccod='\0',.fcod=0x3E, .fnum=FONT_MATH_EX}, .desc="\\_vline_small"},   /* those are all vertical lines */
/* 225*/{.ch = {.ccod='\0',.fcod=0x3F, .fnum=FONT_MATH_EX}, .desc="\\_vline_1"},
/* 226*/{.ch = {.ccod='\0',.fcod=0x36, .fnum=FONT_MATH_EX}, .desc="\\_vline_2"},
/* 227*/{.ch = {.ccod='\0',.fcod=0x37, .fnum=FONT_MATH_EX}, .desc="\\_vline_3"},
/* 228*/{.ch = {.ccod='\0',.fcod=0x42, .fnum=FONT_MATH_EX}, .desc="\\_vline_4"},
/* 229*/{.ch = {.ccod='\0',.fcod=0x43, .fnum=FONT_MATH_EX}, .desc="\\_vline_5"},
/* 230*/{.ch = {.ccod='\0',.fcod=0x75, .fnum=FONT_MATH_EX}, .desc="\\_vline_6"},       /* this is a bit different */
/* 231*/{.ch = {.ccod='\0',.fcod=0x30, .fnum=FONT_MATH_EX}, .desc="\\_brack_lt_round" },
/* 232*/{.ch = {.ccod='\0',.fcod=0x31, .fnum=FONT_MATH_EX}, .desc="\\_brack_rt_round" },
/* 233*/{.ch = {.ccod='\0',.fcod=0x40, .fnum=FONT_MATH_EX}, .desc="\\_brack_lb_round" },
/* 234*/{.ch = {.ccod='\0',.fcod=0x41, .fnum=FONT_MATH_EX}, .desc="\\_brack_rb_round" },
/* 235*/{.ch = {.ccod='\0',.fcod=0x32, .fnum=FONT_MATH_EX}, .desc="\\_brack_lt_square" },
/* 236*/{.ch = {.ccod='\0',.fcod=0x33, .fnum=FONT_MATH_EX}, .desc="\\_brack_rt_square" },
/* 237*/{.ch = {.ccod='\0',.fcod=0x34, .fnum=FONT_MATH_EX}, .desc="\\_brack_lb_square" },
/* 238*/{.ch = {.ccod='\0',.fcod=0x35, .fnum=FONT_MATH_EX}, .desc="\\_brack_rb_square" },
/* 239*/{.ch = {.ccod='\0',.fcod=0x38, .fnum=FONT_MATH_EX}, .desc="\\_brack_lt_curly" },
/* 240*/{.ch = {.ccod='\0',.fcod=0x39, .fnum=FONT_MATH_EX}, .desc="\\_brack_rt_curly" },
/* 241*/{.ch = {.ccod='\0',.fcod=0x3A, .fnum=FONT_MATH_EX}, .desc="\\_brack_lb_curly" },
/* 242*/{.ch = {.ccod='\0',.fcod=0x3B, .fnum=FONT_MATH_EX}, .desc="\\_brack_rb_curly" },
/* 243*/{.ch = {.ccod='\0',.fcod=0x3C, .fnum=FONT_MATH_EX}, .desc="\\_brack_lc_curly" },
/* 244*/{.ch = {.ccod='\0',.fcod=0x3D, .fnum=FONT_MATH_EX}, .desc="\\_brack_rc_curly" },
/* 245*/{.ch = {.ccod='<', .fcod=0x3C, .fnum=FONT_MATH   }, .desc="<" },
/* 246*/{.ch = {.ccod='>', .fcod=0x3E, .fnum=FONT_MATH   }, .desc=">" },
};

#endif

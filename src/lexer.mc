// lexer.mc — TypeScript tokenizer.
//
// Pull scanner: lexer_next lexes with context-free defaults (`/` is
// division, `}` is a plain brace, `>`-family is maximal munch). The
// parser calls lexer_rescan_regex / lexer_rescan_template where
// grammar context says otherwise, and rewinds with lexer_seek for
// speculation. Spans are byte offsets into the UTF-8 source.
// See doc/PLAN_M2_lexer.md.

import vec;
import map;
import diag;
import numparse;
import "regex_uniprops_data.mc";   // general-category runs, for Unicode identifiers

enum TokKind {
    TOK_EOF,
    TOK_ERROR,

    TOK_IDENT,
    TOK_PRIVATE_NAME,
    TOK_NUMBER,
    TOK_BIGINT,
    TOK_STRING,
    TOK_TEMPLATE_FULL,
    TOK_TEMPLATE_HEAD,
    TOK_TEMPLATE_MIDDLE,
    TOK_TEMPLATE_TAIL,
    TOK_REGEX,

    TOK_LBRACE, TOK_RBRACE, TOK_LPAREN, TOK_RPAREN, TOK_LBRACK, TOK_RBRACK,
    TOK_SEMI, TOK_COMMA, TOK_DOT, TOK_DOTDOTDOT, TOK_COLON, TOK_QUESTION,
    TOK_QUESTION_DOT, TOK_QUESTION_QUESTION, TOK_QUESTION_QUESTION_EQ,
    TOK_ARROW, TOK_AT,
    TOK_LT, TOK_GT, TOK_LE, TOK_GE,
    TOK_EQEQ, TOK_NEQ, TOK_EQEQEQ, TOK_NEQEQEQ,
    TOK_PLUS, TOK_MINUS, TOK_STAR, TOK_STARSTAR, TOK_SLASH, TOK_PERCENT,
    TOK_PLUSPLUS, TOK_MINUSMINUS,
    TOK_LSHIFT, TOK_RSHIFT, TOK_URSHIFT,
    TOK_AMP, TOK_PIPE, TOK_CARET, TOK_BANG, TOK_TILDE,
    TOK_AMPAMP, TOK_PIPEPIPE,
    TOK_EQ, TOK_PLUS_EQ, TOK_MINUS_EQ, TOK_STAR_EQ, TOK_STARSTAR_EQ,
    TOK_SLASH_EQ, TOK_PERCENT_EQ, TOK_LSHIFT_EQ, TOK_RSHIFT_EQ,
    TOK_URSHIFT_EQ, TOK_AMP_EQ, TOK_PIPE_EQ, TOK_CARET_EQ,
    TOK_AMPAMP_EQ, TOK_PIPEPIPE_EQ,

    // keywords — contiguous block; tok_is_keyword uses the bounds
    TOK_KW_ABSTRACT, TOK_KW_AS, TOK_KW_ASSERTS, TOK_KW_ASYNC,
    TOK_KW_AWAIT, TOK_KW_BREAK, TOK_KW_CASE, TOK_KW_CATCH,
    TOK_KW_CLASS, TOK_KW_CONST, TOK_KW_CONTINUE, TOK_KW_DEBUGGER,
    TOK_KW_DECLARE, TOK_KW_DEFAULT, TOK_KW_DELETE, TOK_KW_DO,
    TOK_KW_ELSE, TOK_KW_ENUM, TOK_KW_EXPORT, TOK_KW_EXTENDS,
    TOK_KW_FALSE, TOK_KW_FINALLY, TOK_KW_FOR, TOK_KW_FROM,
    TOK_KW_FUNCTION, TOK_KW_GET, TOK_KW_GLOBAL, TOK_KW_IF,
    TOK_KW_IMPLEMENTS, TOK_KW_IMPORT, TOK_KW_IN, TOK_KW_INFER,
    TOK_KW_INSTANCEOF, TOK_KW_INTERFACE, TOK_KW_IS, TOK_KW_KEYOF,
    TOK_KW_LET, TOK_KW_MODULE, TOK_KW_NAMESPACE, TOK_KW_NEW,
    TOK_KW_NULL, TOK_KW_OF, TOK_KW_OUT, TOK_KW_OVERRIDE,
    TOK_KW_PRIVATE, TOK_KW_PROTECTED, TOK_KW_PUBLIC, TOK_KW_READONLY,
    TOK_KW_RETURN, TOK_KW_SATISFIES, TOK_KW_SET, TOK_KW_STATIC,
    TOK_KW_SUPER, TOK_KW_SWITCH, TOK_KW_THIS, TOK_KW_THROW,
    TOK_KW_TRUE, TOK_KW_TRY, TOK_KW_TYPE, TOK_KW_TYPEOF,
    TOK_KW_UNIQUE, TOK_KW_VAR, TOK_KW_VOID, TOK_KW_WHILE,
    TOK_KW_WITH, TOK_KW_YIELD
}

bool tok_is_keyword(i32 kind) {
    return kind >= TOK_KW_ABSTRACT && kind <= TOK_KW_YIELD;
}

struct Token {
    i32 kind;
    i32 start;
    i32 end;
    bool newline_before;   // line terminator crossed before this token
    bool escaped;          // an identifier spelled with a Unicode escape
    f64 num;               // TOK_NUMBER value
    str text;              // ident/keyword name, cooked string/template, regex pattern
    str aux;               // regex flags
}

struct Lexer {
    str src;
    i32 pos;
    DiagList* diags;
    Vec<str> owned;        // decoded literal buffers, freed in lexer_destroy
}

// --- low-level helpers ----------------------------------------------

private u8 lx_at(Lexer* lx, i32 i) {
    if i >= lx.src.len { return 0; }
    return *(lx.src.data + i);
}

private u8 lx_cur(Lexer* lx) {
    return lx_at(lx, lx.pos);
}

private str lx_view(Lexer* lx, i32 a, i32 b) {
    str r;
    r.data = lx.src.data + a;
    r.len = b - a;
    return r;
}

private void lex_error(Lexer* lx, i32 a, i32 b, str msg) {
    diag_add(lx.diags, DIAG_ERROR, Span{a, b}, msg);
}

private bool is_digit(u8 c) {
    return c >= '0' && c <= '9';
}

private bool is_hex(u8 c) {
    return is_digit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

private i32 hex_val(u8 c) {
    if is_digit(c) { return c - '0'; }
    if c >= 'a' { return c - 'a' + 10; }
    return c - 'A' + 10;
}

// A byte's classes, for the scans that run per byte: a name's letters, a
// digit, a blank, a line end. Bytes past ASCII have none; the Unicode
// tables decide those. Filled by the first lexer made, the same from
// every thread.
const u8 LXC_ID_START = 1;
const u8 LXC_DIGIT = 2;
const u8 LXC_SPACE = 4;
const u8 LXC_NL = 8;
const u8 LXC_ID_PART = 3;
private u8[256] g_lxc;
private bool g_lxc_ready = false;
// By a word's first and last letter, the lengths of the keywords spelled
// so, a bit per length: most names are turned away by one lookup before
// the keyword compare.
private u16[676] g_kw_lens;

private void lxc_init() {
    for i32 c = 0; c < 256; c++ {
        u8 f = 0;
        if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c == '$' { f |= LXC_ID_START; }
        if c >= '0' && c <= '9' { f |= LXC_DIGIT; }
        if c == ' ' || c == '\t' || c == 11 || c == 12 { f |= LXC_SPACE; }
        if c == '\n' || c == '\r' { f |= LXC_NL; }
        g_lxc[c] = f;
    }
    g_kw_lens[19] |= 256;
    g_kw_lens[18] |= 4;
    g_kw_lens[18] |= 128;
    g_kw_lens[2] |= 32;
    g_kw_lens[19] |= 32;
    g_kw_lens[36] |= 32;
    g_kw_lens[56] |= 16;
    g_kw_lens[59] |= 32;
    g_kw_lens[70] |= 32;
    g_kw_lens[71] |= 32;
    g_kw_lens[56] |= 256;
    g_kw_lens[95] |= 256;
    g_kw_lens[82] |= 128;
    g_kw_lens[97] |= 128;
    g_kw_lens[82] |= 64;
    g_kw_lens[92] |= 4;
    g_kw_lens[108] |= 16;
    g_kw_lens[116] |= 16;
    g_kw_lens[123] |= 64;
    g_kw_lens[122] |= 128;
    g_kw_lens[134] |= 32;
    g_kw_lens[154] |= 128;
    g_kw_lens[147] |= 8;
    g_kw_lens[142] |= 16;
    g_kw_lens[143] |= 256;
    g_kw_lens[175] |= 8;
    g_kw_lens[167] |= 64;
    g_kw_lens[213] |= 4;
    g_kw_lens[226] |= 1024;
    g_kw_lens[227] |= 64;
    g_kw_lens[221] |= 4;
    g_kw_lens[225] |= 32;
    g_kw_lens[213] |= 1024;
    g_kw_lens[212] |= 512;
    g_kw_lens[226] |= 4;
    g_kw_lens[265] |= 32;
    g_kw_lens[305] |= 8;
    g_kw_lens[316] |= 64;
    g_kw_lens[342] |= 512;
    g_kw_lens[360] |= 8;
    g_kw_lens[349] |= 16;
    g_kw_lens[369] |= 4;
    g_kw_lens[383] |= 8;
    g_kw_lens[368] |= 256;
    g_kw_lens[394] |= 128;
    g_kw_lens[393] |= 512;
    g_kw_lens[392] |= 64;
    g_kw_lens[466] |= 256;
    g_kw_lens[455] |= 64;
    g_kw_lens[486] |= 512;
    g_kw_lens[487] |= 8;
    g_kw_lens[470] |= 64;
    g_kw_lens[485] |= 32;
    g_kw_lens[475] |= 64;
    g_kw_lens[512] |= 16;
    g_kw_lens[516] |= 32;
    g_kw_lens[498] |= 16;
    g_kw_lens[518] |= 8;
    g_kw_lens[498] |= 16;
    g_kw_lens[499] |= 64;
    g_kw_lens[524] |= 64;
    g_kw_lens[563] |= 8;
    g_kw_lens[549] |= 16;
    g_kw_lens[576] |= 32;
    g_kw_lens[579] |= 16;
    g_kw_lens[627] |= 32;
    g_lxc_ready = true;
}

// The tables made before a second thread lexes: a lexer makes them on
// its first use, which two threads must not do at once.
void lexer_tables_init() { if !g_lxc_ready { lxc_init(); } }

private bool is_id_start(u8 c) {
    return (g_lxc[c] & LXC_ID_START) != 0;
}

private bool is_id_part(u8 c) {
    return (g_lxc[c] & LXC_ID_PART) != 0;
}

// --- Unicode identifiers ---------------------------------------------
//
// Beyond ASCII an identifier character is decided by its general
// category, read from the same run table the regex \p{...} escapes use.
// ID_Start is L* plus Nl; ID_Continue adds Mn, Mc, Nd and Pc. The small
// Other_ID_Start / Other_ID_Continue sets are listed explicitly.

const u32 UNI_ID_START_CATS = 1 | 2 | 4 | 8 | 16 | 512;              // Lu Ll Lt Lm Lo Nl
const u32 UNI_ID_CONT_CATS = 32 | 64 | 256 | 2048;                  // Mn Mc Nd Pc

// The category bit of `cp`: the runs partition the code space, so the
// last run starting at or below cp holds it.
private u32 uni_gc_bit(u32 cp) {
    i32 lo = 0;
    i32 hi = UNI_GC_RUNS - 1;
    while lo < hi {
        i32 mid = (lo + hi + 1) / 2;
        if UNI_GC_START[mid] <= cp { lo = mid; } else { hi = mid - 1; }
    }
    return cast(u32, 1) << UNI_GC_CAT[lo];
}

private bool uni_is_id_start(u32 cp) {
    // Other_ID_Start
    if cp == 0x1885 || cp == 0x1886 || cp == 0x2118
        || cp == 0x212E || cp == 0x309B || cp == 0x309C { return true; }
    if cp == 0x2E2F { return false; }   // VERTICAL TILDE: Pattern_Syntax
    return (uni_gc_bit(cp) & UNI_ID_START_CATS) != 0;
}

private bool uni_is_id_cont(u32 cp) {
    if cp == 0x200C || cp == 0x200D { return true; }   // ZWNJ, ZWJ
    if cp == 0x2E2F { return false; }                  // VERTICAL TILDE
    // Other_ID_Continue
    if cp == 0xB7 || cp == 0x387 || cp == 0x19DA
        || (cp >= 0x1369 && cp <= 0x1371) { return true; }
    return (uni_gc_bit(cp) & (UNI_ID_START_CATS | UNI_ID_CONT_CATS)) != 0;
}

// Decodes the UTF-8 sequence at `pos`. *len receives its byte length;
// a malformed sequence yields 0 with a length of 1.
private u32 utf8_decode_at(Lexer* lx, i32 pos, i32* len) {
    *len = 1;
    u8 b0 = lx_at(lx, pos);
    if b0 < 0x80 { return cast(u32, b0); }
    i32 n = 0;
    u32 cp = 0;
    if (b0 & 0xE0) == 0xC0 { n = 2; cp = cast(u32, b0 & 0x1F); }
    else if (b0 & 0xF0) == 0xE0 { n = 3; cp = cast(u32, b0 & 0x0F); }
    else if (b0 & 0xF8) == 0xF0 { n = 4; cp = cast(u32, b0 & 0x07); }
    else { return 0; }
    if pos + n > lx.src.len { return 0; }
    for i32 i = 1; i < n; i++ {
        u8 b = lx_at(lx, pos + i);
        if (b & 0xC0) != 0x80 { return 0; }
        cp = (cp << 6) | cast(u32, b & 0x3F);
    }
    *len = n;
    return cp;
}

// Identifier start/continue at `pos`, ASCII or not. *len receives the
// number of bytes the character occupies.
private bool id_start_at(Lexer* lx, i32 pos, i32* len) {
    u8 c = lx_at(lx, pos);
    if c < 0x80 { *len = 1; return is_id_start(c); }
    u32 cp = utf8_decode_at(lx, pos, len);
    return cp != 0 && uni_is_id_start(cp);
}

private bool id_part_at(Lexer* lx, i32 pos, i32* len) {
    u8 c = lx_at(lx, pos);
    if c < 0x80 { *len = 1; return is_id_part(c); }
    u32 cp = utf8_decode_at(lx, pos, len);
    return cp != 0 && uni_is_id_cont(cp);
}

// WTF-8: lone surrogates encode like normal 3-byte sequences; the
// string-model milestone decides their final representation.
private i32 utf8_encode(u8* dst, u32 cp) {
    if cp < 0x80 {
        *dst = cast(u8, cp);
        return 1;
    }
    if cp < 0x800 {
        *dst = cast(u8, 0xC0 | (cp >> 6));
        *(dst + 1) = cast(u8, 0x80 | (cp & 0x3F));
        return 2;
    }
    if cp < 0x10000 {
        *dst = cast(u8, 0xE0 | (cp >> 12));
        *(dst + 1) = cast(u8, 0x80 | ((cp >> 6) & 0x3F));
        *(dst + 2) = cast(u8, 0x80 | (cp & 0x3F));
        return 3;
    }
    *dst = cast(u8, 0xF0 | (cp >> 18));
    *(dst + 1) = cast(u8, 0x80 | ((cp >> 12) & 0x3F));
    *(dst + 2) = cast(u8, 0x80 | ((cp >> 6) & 0x3F));
    *(dst + 3) = cast(u8, 0x80 | (cp & 0x3F));
    return 4;
}

// --- trivia ---------------------------------------------------------

// Skips whitespace and comments. True when a line terminator was
// crossed, including inside a block comment — ASI input.
private bool skip_trivia(Lexer* lx) {
    bool nl = false;
    u8* d = lx.src.data;
    i32 n = lx.src.len;
    while lx.pos < n {
        // the blanks and line ends, the common run, with the position in a local
        i32 pos = lx.pos;
        while pos < n {
            u8 f = g_lxc[*(d + pos)];
            if (f & (LXC_SPACE | LXC_NL)) == 0 { break; }
            if (f & LXC_NL) != 0 { nl = true; }
            pos++;
        }
        lx.pos = pos;
        if pos >= n { break; }
        u8 c = *(d + pos);
        if c < 0x80 && c != '/' { break; }
        // U+2028 / U+2029 are line terminators; U+00A0 and a stray
        // BOM are whitespace.
        if c == 0xE2 && lx_at(lx, lx.pos + 1) == 0x80 {
            u8 c3 = lx_at(lx, lx.pos + 2);
            if c3 == 0xA8 || c3 == 0xA9 {
                nl = true;
                lx.pos += 3;
                continue;
            }
            break;
        }
        if c == 0xC2 && lx_at(lx, lx.pos + 1) == 0xA0 {
            lx.pos += 2;
            continue;
        }
        if c == 0xEF && lx_at(lx, lx.pos + 1) == 0xBB && lx_at(lx, lx.pos + 2) == 0xBF {
            lx.pos += 3;
            continue;
        }
        if c == '/' {
            u8 n = lx_at(lx, lx.pos + 1);
            if n == '/' {
                lx.pos += 2;
                while lx.pos < lx.src.len {
                    u8 d = lx_cur(lx);
                    if d == '\n' || d == '\r' { break; }
                    if d == 0xE2 && lx_at(lx, lx.pos + 1) == 0x80 {
                        u8 d3 = lx_at(lx, lx.pos + 2);
                        if d3 == 0xA8 || d3 == 0xA9 { break; }
                    }
                    lx.pos++;
                }
                continue;
            }
            if n == '*' {
                i32 open = lx.pos;
                lx.pos += 2;
                bool closed = false;
                while lx.pos < lx.src.len {
                    u8 d = lx_cur(lx);
                    if d == '*' && lx_at(lx, lx.pos + 1) == '/' {
                        lx.pos += 2;
                        closed = true;
                        break;
                    }
                    if d == '\n' || d == '\r' { nl = true; }
                    lx.pos++;
                }
                if !closed {
                    lex_error(lx, open, lx.pos, "unterminated block comment");
                }
                continue;
            }
            break;
        }
        break;
    }
    return nl;
}

// --- escape decoding ------------------------------------------------

// Decodes src[a..b) into an owned buffer. Template mode also
// normalizes \r and \r\n to \n. Decoded output never exceeds the raw
// length.
private str decode_text(Lexer* lx, i32 a, i32 b, bool is_template) {
    u8* buf = alloc<u8>(b - a + 1);
    i32 out = 0;
    i32 i = a;
    while i < b {
        u8 c = *(lx.src.data + i);
        if is_template && c == '\r' {
            *(buf + out) = '\n';
            out++;
            i++;
            if i < b && *(lx.src.data + i) == '\n' { i++; }
            continue;
        }
        if c != '\\' {
            *(buf + out) = c;
            out++;
            i++;
            continue;
        }
        i++;
        if i >= b { break; }
        u8 e = *(lx.src.data + i);
        i++;
        if e == 'n' { *(buf + out) = '\n'; out++; continue; }
        if e == 't' { *(buf + out) = '\t'; out++; continue; }
        if e == 'r' { *(buf + out) = '\r'; out++; continue; }
        if e == 'b' { *(buf + out) = 8; out++; continue; }
        if e == 'f' { *(buf + out) = 12; out++; continue; }
        if e == 'v' { *(buf + out) = 11; out++; continue; }
        if e == '0' {
            if i < b && is_digit(*(lx.src.data + i)) {
                lex_error(lx, i - 2, i + 1, "octal escapes are not allowed");
            }
            *(buf + out) = 0;
            out++;
            continue;
        }
        if e >= '1' && e <= '9' {
            lex_error(lx, i - 2, i, "octal and \\8 \\9 escapes are not allowed");
            *(buf + out) = e;
            out++;
            continue;
        }
        if e == 'x' {
            if i + 1 < b && is_hex(*(lx.src.data + i)) && is_hex(*(lx.src.data + i + 1)) {
                u32 cp = hex_val(*(lx.src.data + i)) * 16 + hex_val(*(lx.src.data + i + 1));
                out += utf8_encode(buf + out, cp);
                i += 2;
            } else {
                lex_error(lx, i - 2, i, "invalid \\x escape");
                *(buf + out) = 'x';
                out++;
            }
            continue;
        }
        if e == 'u' {
            if i < b && *(lx.src.data + i) == '{' {
                i32 j = i + 1;
                u32 cp = 0;
                i32 nd = 0;
                bool bad = false;
                while j < b && *(lx.src.data + j) != '}' {
                    u8 h = *(lx.src.data + j);
                    if !is_hex(h) { bad = true; break; }
                    if cp <= 0x10FFFF { cp = cp * 16 + cast(u32, hex_val(h)); }
                    nd++;
                    j++;
                }
                if bad || nd == 0 || j >= b || cp > 0x10FFFF {
                    lex_error(lx, i - 2, j, "invalid Unicode escape");
                    *(buf + out) = 'u';
                    out++;
                } else {
                    out += utf8_encode(buf + out, cp);
                    i = j + 1;
                }
            } else if i + 3 < b && is_hex(*(lx.src.data + i)) && is_hex(*(lx.src.data + i + 1))
                    && is_hex(*(lx.src.data + i + 2)) && is_hex(*(lx.src.data + i + 3)) {
                u32 cp = 0;
                for i32 k = 0; k < 4; k++ {
                    cp = cp * 16 + cast(u32, hex_val(*(lx.src.data + i + k)));
                }
                out += utf8_encode(buf + out, cp);
                i += 4;
            } else {
                lex_error(lx, i - 2, i, "invalid Unicode escape");
                *(buf + out) = 'u';
                out++;
            }
            continue;
        }
        if e == '\n' { continue; }                       // line continuation
        if e == '\r' {
            if i < b && *(lx.src.data + i) == '\n' { i++; }
            continue;
        }
        if e == 0xE2 && i + 1 < b && *(lx.src.data + i) == 0x80 {
            u8 e3 = *(lx.src.data + i + 1);
            if e3 == 0xA8 || e3 == 0xA9 {
                i += 2;                                  // U+2028/29 continuation
                continue;
            }
        }
        *(buf + out) = e;                                // NonEscapeCharacter
        out++;
    }
    str s;
    s.data = buf;
    s.len = out;
    vec_push(&lx.owned, s);
    return s;
}

// --- identifiers and keywords ---------------------------------------

// Validates a \uXXXX or \u{...} escape at lx.pos (on the '\') and
// advances past it, returning the code point; -1 (position restored) if
// it is not a well-formed Unicode escape.
private i32 scan_ident_escape(Lexer* lx) {
    i32 start = lx.pos;
    if lx_at(lx, lx.pos) != '\\' || lx_at(lx, lx.pos + 1) != 'u' { return -1; }
    lx.pos += 2;
    if lx_cur(lx) == '{' {
        lx.pos++;
        i32 v = 0;
        i32 nd = 0;
        while lx.pos < lx.src.len && lx_cur(lx) != '}' {
            u8 h = lx_cur(lx);
            if !is_hex(h) { lx.pos = start; return -1; }
            v = v * 16 + hex_val(h);
            if v > 0x10FFFF { lx.pos = start; return -1; }
            nd++;
            lx.pos++;
        }
        if nd == 0 || lx.pos >= lx.src.len { lx.pos = start; return -1; }
        lx.pos++;                                       // past '}'
        return v;
    }
    i32 v = 0;
    for i32 k = 0; k < 4; k++ {
        u8 h = lx_at(lx, lx.pos + k);
        if !is_hex(h) { lx.pos = start; return -1; }
        v = v * 16 + hex_val(h);
    }
    lx.pos += 4;
    return v;
}

// The words that are never identifiers. An escape may spell one only
// where any IdentifierName is accepted, such as a property name.
bool reserved_word_text(str t) {
    return str_equal(t, "break") || str_equal(t, "case") || str_equal(t, "catch")
        || str_equal(t, "class") || str_equal(t, "const") || str_equal(t, "continue")
        || str_equal(t, "debugger") || str_equal(t, "default") || str_equal(t, "delete")
        || str_equal(t, "do") || str_equal(t, "else") || str_equal(t, "enum")
        || str_equal(t, "export") || str_equal(t, "extends") || str_equal(t, "false")
        || str_equal(t, "finally") || str_equal(t, "for") || str_equal(t, "function")
        || str_equal(t, "if") || str_equal(t, "import") || str_equal(t, "in")
        || str_equal(t, "instanceof") || str_equal(t, "new") || str_equal(t, "null")
        || str_equal(t, "return") || str_equal(t, "super") || str_equal(t, "switch")
        || str_equal(t, "this") || str_equal(t, "throw") || str_equal(t, "true")
        || str_equal(t, "try") || str_equal(t, "typeof") || str_equal(t, "var")
        || str_equal(t, "void") || str_equal(t, "while") || str_equal(t, "with");
}

// Whether an escaped code point may start, or continue, an identifier.
private bool cp_is_id_start(i32 v) {
    if v < 0x80 { return is_id_start(cast(u8, v)); }
    return uni_is_id_start(cast(u32, v));
}

private bool cp_is_id_part(i32 v) {
    if v < 0x80 { return is_id_part(cast(u8, v)); }
    return uni_is_id_cont(cast(u32, v));
}

// Decodes an identifier span containing \u escapes (already validated by
// the scan) into an owned UTF-8 buffer.
private str decode_ident(Lexer* lx, i32 a, i32 b) {
    u8* buf = alloc<u8>(b - a + 1);
    i32 out = 0;
    i32 i = a;
    while i < b {
        u8 c = *(lx.src.data + i);
        if c != '\\' {
            *(buf + out) = c;
            out++;
            i++;
            continue;
        }
        i += 2;                                         // past '\u'
        u32 cp = 0;
        if *(lx.src.data + i) == '{' {
            i++;
            while *(lx.src.data + i) != '}' {
                cp = cp * 16 + cast(u32, hex_val(*(lx.src.data + i)));
                i++;
            }
            i++;                                        // past '}'
        } else {
            for i32 k = 0; k < 4; k++ {
                cp = cp * 16 + cast(u32, hex_val(*(lx.src.data + i)));
                i++;
            }
        }
        out += utf8_encode(buf + out, cp);
    }
    str s;
    s.data = buf;
    s.len = out;
    vec_push(&lx.owned, s);
    return s;
}

// IdentifierName, allowing \uXXXX / \u{...} escapes (ES 12.6). The common
// escape-free case keeps a borrowed source view; an escaped name decodes
// into an owned buffer. Keyword classification runs on the decoded name.
// The keyword a word is, or 0. Every keyword is two to ten lowercase
// letters: its first eight packed into one word compare at once, and
// the length and the first letter leave one or two to try.
private i32 keyword_kind(str w) {
    i32 n = w.len;
    if n < 2 || n > 10 { return 0; }
    u8* d = w.data;
    u8 c0 = *d;
    u8 cl = *(d + n - 1);
    if c0 < 'a' || c0 > 'z' || cl < 'a' || cl > 'z' { return 0; }
    if (g_kw_lens[(c0 - 'a') * 26 + (cl - 'a')] & (1 << n)) == 0 { return 0; }
    u64 a = 0;
    i32 m = n < 8 ? n : 8;
    for i32 i = 0; i < m; i++ { a |= cast(u64, *(d + i)) << cast(u64, 8 * i); }
    switch n {
        case 2: {
            switch c0 {
                case 'a': {
                    if a == 0x7361 { return TOK_KW_AS; }
                }
                case 'd': {
                    if a == 0x6F64 { return TOK_KW_DO; }
                }
                case 'i': {
                    if a == 0x6669 { return TOK_KW_IF; }
                    if a == 0x6E69 { return TOK_KW_IN; }
                    if a == 0x7369 { return TOK_KW_IS; }
                }
                case 'o': {
                    if a == 0x666F { return TOK_KW_OF; }
                }
                default: { }
            }
        }
        case 3: {
            switch c0 {
                case 'f': {
                    if a == 0x726F66 { return TOK_KW_FOR; }
                }
                case 'g': {
                    if a == 0x746567 { return TOK_KW_GET; }
                }
                case 'l': {
                    if a == 0x74656C { return TOK_KW_LET; }
                }
                case 'n': {
                    if a == 0x77656E { return TOK_KW_NEW; }
                }
                case 'o': {
                    if a == 0x74756F { return TOK_KW_OUT; }
                }
                case 's': {
                    if a == 0x746573 { return TOK_KW_SET; }
                }
                case 't': {
                    if a == 0x797274 { return TOK_KW_TRY; }
                }
                case 'v': {
                    if a == 0x726176 { return TOK_KW_VAR; }
                }
                default: { }
            }
        }
        case 4: {
            switch c0 {
                case 'c': {
                    if a == 0x65736163 { return TOK_KW_CASE; }
                }
                case 'e': {
                    if a == 0x65736C65 { return TOK_KW_ELSE; }
                    if a == 0x6D756E65 { return TOK_KW_ENUM; }
                }
                case 'f': {
                    if a == 0x6D6F7266 { return TOK_KW_FROM; }
                }
                case 'n': {
                    if a == 0x6C6C756E { return TOK_KW_NULL; }
                }
                case 't': {
                    if a == 0x73696874 { return TOK_KW_THIS; }
                    if a == 0x65757274 { return TOK_KW_TRUE; }
                    if a == 0x65707974 { return TOK_KW_TYPE; }
                }
                case 'v': {
                    if a == 0x64696F76 { return TOK_KW_VOID; }
                }
                case 'w': {
                    if a == 0x68746977 { return TOK_KW_WITH; }
                }
                default: { }
            }
        }
        case 5: {
            switch c0 {
                case 'a': {
                    if a == 0x636E797361 { return TOK_KW_ASYNC; }
                    if a == 0x7469617761 { return TOK_KW_AWAIT; }
                }
                case 'b': {
                    if a == 0x6B61657262 { return TOK_KW_BREAK; }
                }
                case 'c': {
                    if a == 0x6863746163 { return TOK_KW_CATCH; }
                    if a == 0x7373616C63 { return TOK_KW_CLASS; }
                    if a == 0x74736E6F63 { return TOK_KW_CONST; }
                }
                case 'f': {
                    if a == 0x65736C6166 { return TOK_KW_FALSE; }
                }
                case 'i': {
                    if a == 0x7265666E69 { return TOK_KW_INFER; }
                }
                case 'k': {
                    if a == 0x666F79656B { return TOK_KW_KEYOF; }
                }
                case 's': {
                    if a == 0x7265707573 { return TOK_KW_SUPER; }
                }
                case 't': {
                    if a == 0x776F726874 { return TOK_KW_THROW; }
                }
                case 'w': {
                    if a == 0x656C696877 { return TOK_KW_WHILE; }
                }
                case 'y': {
                    if a == 0x646C656979 { return TOK_KW_YIELD; }
                }
                default: { }
            }
        }
        case 6: {
            switch c0 {
                case 'd': {
                    if a == 0x6574656C6564 { return TOK_KW_DELETE; }
                }
                case 'e': {
                    if a == 0x74726F707865 { return TOK_KW_EXPORT; }
                }
                case 'g': {
                    if a == 0x6C61626F6C67 { return TOK_KW_GLOBAL; }
                }
                case 'i': {
                    if a == 0x74726F706D69 { return TOK_KW_IMPORT; }
                }
                case 'm': {
                    if a == 0x656C75646F6D { return TOK_KW_MODULE; }
                }
                case 'p': {
                    if a == 0x63696C627570 { return TOK_KW_PUBLIC; }
                }
                case 'r': {
                    if a == 0x6E7275746572 { return TOK_KW_RETURN; }
                }
                case 's': {
                    if a == 0x636974617473 { return TOK_KW_STATIC; }
                    if a == 0x686374697773 { return TOK_KW_SWITCH; }
                }
                case 't': {
                    if a == 0x666F65707974 { return TOK_KW_TYPEOF; }
                }
                case 'u': {
                    if a == 0x657571696E75 { return TOK_KW_UNIQUE; }
                }
                default: { }
            }
        }
        case 7: {
            switch c0 {
                case 'a': {
                    if a == 0x73747265737361 { return TOK_KW_ASSERTS; }
                }
                case 'd': {
                    if a == 0x6572616C636564 { return TOK_KW_DECLARE; }
                    if a == 0x746C7561666564 { return TOK_KW_DEFAULT; }
                }
                case 'e': {
                    if a == 0x73646E65747865 { return TOK_KW_EXTENDS; }
                }
                case 'f': {
                    if a == 0x796C6C616E6966 { return TOK_KW_FINALLY; }
                }
                case 'p': {
                    if a == 0x65746176697270 { return TOK_KW_PRIVATE; }
                }
                default: { }
            }
        }
        case 8: {
            switch c0 {
                case 'a': {
                    if a == 0x7463617274736261 { return TOK_KW_ABSTRACT; }
                }
                case 'c': {
                    if a == 0x65756E69746E6F63 { return TOK_KW_CONTINUE; }
                }
                case 'd': {
                    if a == 0x7265676775626564 { return TOK_KW_DEBUGGER; }
                }
                case 'f': {
                    if a == 0x6E6F6974636E7566 { return TOK_KW_FUNCTION; }
                }
                case 'o': {
                    if a == 0x656469727265766F { return TOK_KW_OVERRIDE; }
                }
                case 'r': {
                    if a == 0x796C6E6F64616572 { return TOK_KW_READONLY; }
                }
                default: { }
            }
        }
        case 9: {
            switch c0 {
                case 'i': {
                    if a == 0x6361667265746E69 && *(d + 8) == 'e' { return TOK_KW_INTERFACE; }
                }
                case 'n': {
                    if a == 0x63617073656D616E && *(d + 8) == 'e' { return TOK_KW_NAMESPACE; }
                }
                case 'p': {
                    if a == 0x65746365746F7270 && *(d + 8) == 'd' { return TOK_KW_PROTECTED; }
                }
                case 's': {
                    if a == 0x6569667369746173 && *(d + 8) == 's' { return TOK_KW_SATISFIES; }
                }
                default: { }
            }
        }
        case 10: {
            switch c0 {
                case 'i': {
                    if a == 0x6E656D656C706D69 && *(d + 8) == 't' && *(d + 9) == 's' { return TOK_KW_IMPLEMENTS; }
                    if a == 0x65636E6174736E69 && *(d + 8) == 'o' && *(d + 9) == 'f' { return TOK_KW_INSTANCEOF; }
                }
                default: { }
            }
        }
        default: { }
    }
    return 0;
}

private void scan_ident(Lexer* lx, Token* t) {
    i32 a = lx.pos;
    bool esc = false;
    if lx_cur(lx) == '\\' {
        i32 v = scan_ident_escape(lx);
        if v < 0 {
            lex_error(lx, a, lx.pos + 1, "invalid Unicode escape in identifier");
            t.kind = TOK_ERROR;
            lx.pos++;
            t.text = lx_view(lx, a, lx.pos);
            return;
        }
        if !cp_is_id_start(v) { lex_error(lx, a, lx.pos, "invalid Unicode escape sequence: not an identifier character"); }
        esc = true;
    } else {
        i32 n;
        ignore id_start_at(lx, lx.pos, &n);
        lx.pos += n;
    }
    // the common run: ASCII name characters, no call per character
    u8* d = lx.src.data;
    i32 n = lx.src.len;
    i32 pos = lx.pos;
    while pos < n && (g_lxc[*(d + pos)] & LXC_ID_PART) != 0 { pos++; }
    lx.pos = pos;
    // a name ends at an ASCII byte that is not one of its letters nor an
    // escape; past ASCII or at a backslash the slow walk decides
    if lx.pos < lx.src.len && (lx_cur(lx) >= 0x80 || lx_cur(lx) == '\\') {
    while lx.pos < lx.src.len {
        u8 c = lx_cur(lx);
        if c < 0x80 && c != '\\' {
            if !is_id_part(c) { break; }
            lx.pos++;
            continue;
        }
        if c == '\\' {
            i32 at = lx.pos;
            i32 v = scan_ident_escape(lx);
            if v < 0 { break; }
            if !cp_is_id_part(v) { lex_error(lx, at, lx.pos, "invalid Unicode escape sequence: not an identifier character"); }
            esc = true;
        } else {
            i32 n;
            if !id_part_at(lx, lx.pos, &n) { break; }
            lx.pos += n;
        }
    }
    }
    if esc { t.text = decode_ident(lx, a, lx.pos); }
    else { t.text = lx_view(lx, a, lx.pos); }
    // a keyword spelled with an escape is an identifier, which the parser
    // refuses wherever the word could not have been one. Every keyword is
    // two to ten lowercase letters: a word shaped otherwise is not looked up.
    i32 k = keyword_kind(t.text);
    if k != 0 && !esc {
        t.kind = k;
    } else {
        t.kind = TOK_IDENT;
        t.escaped = esc;
    }
}

private void scan_private_name(Lexer* lx, Token* t) {
    lx.pos++;
    i32 a = lx.pos;
    i32 n;
    bool esc = false;
    // the name after '#' follows identifier rules, Unicode escapes included
    if lx.pos < lx.src.len && lx_cur(lx) == '\\' {
        i32 v = scan_ident_escape(lx);
        if v < 0 {
            lex_error(lx, a - 1, lx.pos + 1, "invalid Unicode escape in identifier");
            t.kind = TOK_ERROR;
            lx.pos++;
            return;
        }
        if !cp_is_id_start(v) { lex_error(lx, a, lx.pos, "invalid Unicode escape sequence: not an identifier character"); }
        esc = true;
    } else if lx.pos >= lx.src.len || !id_start_at(lx, lx.pos, &n) {
        lex_error(lx, a - 1, lx.pos, "expected identifier after '#'");
        t.kind = TOK_ERROR;
        return;
    } else {
        lx.pos += n;
    }
    while lx.pos < lx.src.len {
        if lx_cur(lx) == '\\' {
            i32 at = lx.pos;
            i32 v = scan_ident_escape(lx);
            if v < 0 { break; }
            if !cp_is_id_part(v) { lex_error(lx, at, lx.pos, "invalid Unicode escape sequence: not an identifier character"); }
            esc = true;
        } else if id_part_at(lx, lx.pos, &n) {
            lx.pos += n;
        } else {
            break;
        }
    }
    t.kind = TOK_PRIVATE_NAME;
    if esc { t.text = decode_ident(lx, a, lx.pos); }
    else { t.text = lx_view(lx, a, lx.pos); }
}

// --- numbers --------------------------------------------------------

private void finish_number(Lexer* lx, Token* t, i32 start, f64 v, bool allow_bigint) {
    if lx.pos < lx.src.len && lx_cur(lx) == 'n' {
        if !allow_bigint {
            lex_error(lx, start, lx.pos + 1, "invalid bigint literal");
        }
        lx.pos++;
        t.kind = TOK_BIGINT;
        t.text = lx_view(lx, start, lx.pos);
    } else {
        t.num = v;
    }
    if lx.pos < lx.src.len && is_id_part(lx_cur(lx)) {
        lex_error(lx, start, lx.pos + 1, "identifier characters cannot follow a numeric literal");
    }
}

private void scan_radix(Lexer* lx, Token* t, i32 start, i32 base) {
    lx.pos += 2;
    f64 v = 0.0;
    i32 ndigits = 0;
    bool last_us = false;
    bool sep_err = false;
    while lx.pos < lx.src.len {
        u8 c = lx_cur(lx);
        if c == '_' {
            if ndigits == 0 || last_us { sep_err = true; }
            last_us = true;
            lx.pos++;
            continue;
        }
        i32 d = -1;
        if base == 16 {
            if is_hex(c) { d = hex_val(c); }
        } else if base == 8 {
            if c >= '0' && c <= '7' { d = c - '0'; }
        } else {
            if c == '0' || c == '1' { d = c - '0'; }
        }
        if d < 0 { break; }
        v = v * base + d;
        ndigits++;
        last_us = false;
        lx.pos++;
    }
    if ndigits == 0 {
        lex_error(lx, start, lx.pos, "missing digits in numeric literal");
    }
    if last_us { sep_err = true; }
    if sep_err {
        lex_error(lx, start, lx.pos, "numeric separator must be between digits");
    }
    finish_number(lx, t, start, v, true);
}

private void scan_decimal(Lexer* lx, Token* t, i32 start) {
    bool has_frac = false;
    bool has_exp = false;
    bool sep_err = false;
    bool last_us = false;
    bool prev_digit = false;

    while lx.pos < lx.src.len {
        u8 c = lx_cur(lx);
        if c == '_' {
            if !prev_digit || last_us { sep_err = true; }
            last_us = true;
            lx.pos++;
            continue;
        }
        if !is_digit(c) { break; }
        prev_digit = true;
        last_us = false;
        lx.pos++;
    }
    if last_us { sep_err = true; }

    if lx.pos < lx.src.len && lx_cur(lx) == '.' {
        has_frac = true;
        lx.pos++;
        prev_digit = false;
        last_us = false;
        while lx.pos < lx.src.len {
            u8 c = lx_cur(lx);
            if c == '_' {
                if !prev_digit || last_us { sep_err = true; }
                last_us = true;
                lx.pos++;
                continue;
            }
            if !is_digit(c) { break; }
            prev_digit = true;
            last_us = false;
            lx.pos++;
        }
        if last_us { sep_err = true; }
    }

    if lx.pos < lx.src.len && (lx_cur(lx) == 'e' || lx_cur(lx) == 'E') {
        i32 save = lx.pos;
        lx.pos++;
        bool neg = false;
        if lx.pos < lx.src.len && (lx_cur(lx) == '+' || lx_cur(lx) == '-') {
            neg = lx_cur(lx) == '-';
            lx.pos++;
        }
        if lx.pos >= lx.src.len || !is_digit(lx_cur(lx)) {
            // not an exponent; the trailing-identifier check reports it
            lx.pos = save;
        } else {
            has_exp = true;
            prev_digit = false;
            last_us = false;
            while lx.pos < lx.src.len {
                u8 c = lx_cur(lx);
                if c == '_' {
                    if !prev_digit || last_us { sep_err = true; }
                    last_us = true;
                    lx.pos++;
                    continue;
                }
                if !is_digit(c) { break; }
                prev_digit = true;
                last_us = false;
                lx.pos++;
            }
            if last_us { sep_err = true; }
            ignore neg;
        }
    }

    if sep_err {
        lex_error(lx, start, lx.pos, "numeric separator must be between digits");
    }
    f64 v = dec_to_f64(lx_view(lx, start, lx.pos));
    finish_number(lx, t, start, v, !has_frac && !has_exp);
}

private void scan_number(Lexer* lx, Token* t) {
    i32 start = lx.pos;
    t.kind = TOK_NUMBER;
    if lx_cur(lx) == '0' {
        u8 n = lx_at(lx, lx.pos + 1);
        if n == '_' {
            lex_error(lx, start, lx.pos + 2, "numeric separator cannot follow a leading zero");
        }
        if n == 'x' || n == 'X' { scan_radix(lx, t, start, 16); return; }
        if n == 'o' || n == 'O' { scan_radix(lx, t, start, 8); return; }
        if n == 'b' || n == 'B' { scan_radix(lx, t, start, 2); return; }
        if is_digit(n) {
            lex_error(lx, start, lx.pos + 2, "legacy octal literals are not allowed");
        }
    }
    scan_decimal(lx, t, start);
}

// --- strings and templates ------------------------------------------

private void scan_string(Lexer* lx, Token* t) {
    u8 q = lx_cur(lx);
    i32 tok_start = lx.pos;
    lx.pos++;
    i32 a = lx.pos;
    bool needs = false;
    u8* d = lx.src.data;
    i32 n = lx.src.len;
    i32 pos = lx.pos;
    while true {
        if pos >= n {
            lx.pos = pos;
            lex_error(lx, tok_start, lx.pos, "unterminated string literal");
            t.kind = TOK_ERROR;
            return;
        }
        u8 c = *(d + pos);
        if c == q { break; }
        if c == '\n' || c == '\r' {
            lx.pos = pos;
            lex_error(lx, tok_start, lx.pos, "unterminated string literal");
            t.kind = TOK_ERROR;
            return;
        }
        if c == '\\' {
            needs = true;
            pos++;
            if pos < n {
                if *(d + pos) == '\r' && pos + 1 < n && *(d + pos + 1) == '\n' {
                    pos += 2;
                } else {
                    pos++;
                }
            }
            continue;
        }
        pos++;
    }
    lx.pos = pos;
    i32 b = lx.pos;
    lx.pos++;
    t.kind = TOK_STRING;
    if needs {
        t.text = decode_text(lx, a, b, false);
    } else {
        t.text = lx_view(lx, a, b);
    }
}

// from_sub: resumed at the `}` that closed a `${…}` substitution.
private void scan_template(Lexer* lx, Token* t, bool from_sub) {
    i32 a = lx.pos;
    bool needs = false;
    bool ended_backtick = false;
    while true {
        if lx.pos >= lx.src.len {
            lex_error(lx, t.start, lx.pos, "unterminated template literal");
            t.kind = TOK_ERROR;
            return;
        }
        u8 c = lx_cur(lx);
        if c == '`' {
            ended_backtick = true;
            break;
        }
        if c == '$' && lx_at(lx, lx.pos + 1) == '{' { break; }
        if c == '\\' {
            needs = true;
            lx.pos++;
            if lx.pos < lx.src.len {
                if lx_cur(lx) == '\r' && lx_at(lx, lx.pos + 1) == '\n' {
                    lx.pos += 2;
                } else {
                    lx.pos++;
                }
            }
            continue;
        }
        if c == '\r' { needs = true; }
        lx.pos++;
    }
    i32 b = lx.pos;
    if ended_backtick {
        lx.pos++;
        t.kind = from_sub ? TOK_TEMPLATE_TAIL : TOK_TEMPLATE_FULL;
    } else {
        lx.pos += 2;
        t.kind = from_sub ? TOK_TEMPLATE_MIDDLE : TOK_TEMPLATE_HEAD;
    }
    if needs {
        t.text = decode_text(lx, a, b, true);
    } else {
        t.text = lx_view(lx, a, b);
    }
    t.aux = lx_view(lx, a, b);   // raw source, for a tagged template's .raw
}

// --- punctuators ----------------------------------------------------

private void pk(Lexer* lx, Token* t, i32 kind, i32 n) {
    t.kind = kind;
    lx.pos += n;
}

private void scan_punct(Lexer* lx, Token* t) {
    u8 c = lx_cur(lx);
    switch c {
        case '{': { pk(lx, t, TOK_LBRACE, 1); return; }
        case '}': { pk(lx, t, TOK_RBRACE, 1); return; }
        case '(': { pk(lx, t, TOK_LPAREN, 1); return; }
        case ')': { pk(lx, t, TOK_RPAREN, 1); return; }
        case '[': { pk(lx, t, TOK_LBRACK, 1); return; }
        case ']': { pk(lx, t, TOK_RBRACK, 1); return; }
        case ';': { pk(lx, t, TOK_SEMI, 1); return; }
        case ',': { pk(lx, t, TOK_COMMA, 1); return; }
        case ':': { pk(lx, t, TOK_COLON, 1); return; }
        case '@': { pk(lx, t, TOK_AT, 1); return; }
        case '~': { pk(lx, t, TOK_TILDE, 1); return; }
        default: { }
    }
    u8 c1 = lx_at(lx, lx.pos + 1);
    if c == '.' {
        if c1 == '.' && lx_at(lx, lx.pos + 2) == '.' { pk(lx, t, TOK_DOTDOTDOT, 3); return; }
        pk(lx, t, TOK_DOT, 1);
        return;
    }
    u8 c2 = lx_at(lx, lx.pos + 2);
    u8 c3 = c2 == 0 ? 0 : lx_at(lx, lx.pos + 3);
    if c == '?' {
        if c1 == '?' {
            if c2 == '=' { pk(lx, t, TOK_QUESTION_QUESTION_EQ, 3); return; }
            pk(lx, t, TOK_QUESTION_QUESTION, 2);
            return;
        }
        if c1 == '.' && !is_digit(c2) { pk(lx, t, TOK_QUESTION_DOT, 2); return; }
        pk(lx, t, TOK_QUESTION, 1);
        return;
    }
    if c == '=' {
        if c1 == '=' {
            if c2 == '=' { pk(lx, t, TOK_EQEQEQ, 3); return; }
            pk(lx, t, TOK_EQEQ, 2);
            return;
        }
        if c1 == '>' { pk(lx, t, TOK_ARROW, 2); return; }
        pk(lx, t, TOK_EQ, 1);
        return;
    }
    if c == '!' {
        if c1 == '=' {
            if c2 == '=' { pk(lx, t, TOK_NEQEQEQ, 3); return; }
            pk(lx, t, TOK_NEQ, 2);
            return;
        }
        pk(lx, t, TOK_BANG, 1);
        return;
    }
    if c == '<' {
        if c1 == '<' {
            if c2 == '=' { pk(lx, t, TOK_LSHIFT_EQ, 3); return; }
            pk(lx, t, TOK_LSHIFT, 2);
            return;
        }
        if c1 == '=' { pk(lx, t, TOK_LE, 2); return; }
        pk(lx, t, TOK_LT, 1);
        return;
    }
    if c == '>' {
        if c1 == '>' {
            if c2 == '>' {
                if c3 == '=' { pk(lx, t, TOK_URSHIFT_EQ, 4); return; }
                pk(lx, t, TOK_URSHIFT, 3);
                return;
            }
            if c2 == '=' { pk(lx, t, TOK_RSHIFT_EQ, 3); return; }
            pk(lx, t, TOK_RSHIFT, 2);
            return;
        }
        if c1 == '=' { pk(lx, t, TOK_GE, 2); return; }
        pk(lx, t, TOK_GT, 1);
        return;
    }
    if c == '+' {
        if c1 == '+' { pk(lx, t, TOK_PLUSPLUS, 2); return; }
        if c1 == '=' { pk(lx, t, TOK_PLUS_EQ, 2); return; }
        pk(lx, t, TOK_PLUS, 1);
        return;
    }
    if c == '-' {
        if c1 == '-' { pk(lx, t, TOK_MINUSMINUS, 2); return; }
        if c1 == '=' { pk(lx, t, TOK_MINUS_EQ, 2); return; }
        pk(lx, t, TOK_MINUS, 1);
        return;
    }
    if c == '*' {
        if c1 == '*' {
            if c2 == '=' { pk(lx, t, TOK_STARSTAR_EQ, 3); return; }
            pk(lx, t, TOK_STARSTAR, 2);
            return;
        }
        if c1 == '=' { pk(lx, t, TOK_STAR_EQ, 2); return; }
        pk(lx, t, TOK_STAR, 1);
        return;
    }
    if c == '/' {
        if c1 == '=' { pk(lx, t, TOK_SLASH_EQ, 2); return; }
        pk(lx, t, TOK_SLASH, 1);
        return;
    }
    if c == '%' {
        if c1 == '=' { pk(lx, t, TOK_PERCENT_EQ, 2); return; }
        pk(lx, t, TOK_PERCENT, 1);
        return;
    }
    if c == '&' {
        if c1 == '&' {
            if c2 == '=' { pk(lx, t, TOK_AMPAMP_EQ, 3); return; }
            pk(lx, t, TOK_AMPAMP, 2);
            return;
        }
        if c1 == '=' { pk(lx, t, TOK_AMP_EQ, 2); return; }
        pk(lx, t, TOK_AMP, 1);
        return;
    }
    if c == '|' {
        if c1 == '|' {
            if c2 == '=' { pk(lx, t, TOK_PIPEPIPE_EQ, 3); return; }
            pk(lx, t, TOK_PIPEPIPE, 2);
            return;
        }
        if c1 == '=' { pk(lx, t, TOK_PIPE_EQ, 2); return; }
        pk(lx, t, TOK_PIPE, 1);
        return;
    }
    if c == '^' {
        if c1 == '=' { pk(lx, t, TOK_CARET_EQ, 2); return; }
        pk(lx, t, TOK_CARET, 1);
        return;
    }
    lex_error(lx, lx.pos, lx.pos + 1, "unexpected character");
    t.kind = TOK_ERROR;
    lx.pos++;
}

// --- main entry points ----------------------------------------------

void lexer_next_into(Lexer* lx, Token* t) {
    bool nl = skip_trivia(lx);
    t.newline_before = nl;
    t.escaped = false;
    t.start = lx.pos;
    if lx.pos >= lx.src.len {
        t.kind = TOK_EOF;
        t.end = lx.pos;
        return;
    }
    u8 c = *(lx.src.data + lx.pos);
    u8 f = g_lxc[c];
    i32 idlen;
    if (f & LXC_ID_START) != 0 || (c >= 0x80 && id_start_at(lx, lx.pos, &idlen))
       || (c == '\\' && lx_at(lx, lx.pos + 1) == 'u') {
        scan_ident(lx, t);
    } else if (f & LXC_DIGIT) != 0 {
        scan_number(lx, t);
    } else if c == '.' && is_digit(lx_at(lx, lx.pos + 1)) {
        scan_number(lx, t);
    } else if c == '"' || c == '\'' {
        scan_string(lx, t);
    } else if c == '`' {
        lx.pos++;
        scan_template(lx, t, false);
    } else if c == '#' {
        scan_private_name(lx, t);
    } else {
        scan_punct(lx, t);
    }
    t.end = lx.pos;
    return;
}

Token lexer_next(Lexer* lx) {
    noinit Token t;
    lexer_next_into(lx, &t);
    return t;
}

// U+2028 LINE SEPARATOR or U+2029 PARAGRAPH SEPARATOR at `pos`.
private bool is_line_sep_at(Lexer* lx, i32 pos) {
    return lx_at(lx, pos) == 0xE2 && lx_at(lx, pos + 1) == 0x80
        && (lx_at(lx, pos + 2) == 0xA8 || lx_at(lx, pos + 2) == 0xA9);
}

// Re-lex a '/' or '/=' token as a regex literal. The parser calls
// this where it expects an expression.
Token lexer_rescan_regex(Lexer* lx, Token slash) {
    Token t;
    t.newline_before = slash.newline_before;
    t.start = slash.start;
    lx.pos = slash.start + 1;
    i32 a = lx.pos;
    bool in_class = false;
    while true {
        if lx.pos >= lx.src.len {
            lex_error(lx, t.start, lx.pos, "unterminated regular expression");
            t.kind = TOK_ERROR;
            t.end = lx.pos;
            return t;
        }
        u8 c = lx_cur(lx);
        // a line or paragraph separator ends the line here as well
        if c == '\n' || c == '\r' || is_line_sep_at(lx, lx.pos) {
            lex_error(lx, t.start, lx.pos, "unterminated regular expression");
            t.kind = TOK_ERROR;
            t.end = lx.pos;
            return t;
        }
        if c == '\\' {
            u8 e = lx_at(lx, lx.pos + 1);
            if e == '\n' || e == '\r' || e == 0 || is_line_sep_at(lx, lx.pos + 1) {
                lex_error(lx, t.start, lx.pos, "unterminated regular expression");
                t.kind = TOK_ERROR;
                t.end = lx.pos;
                return t;
            }
            lx.pos += 2;
            continue;
        }
        if c == '[' { in_class = true; }
        if c == ']' { in_class = false; }
        if c == '/' && !in_class { break; }
        lx.pos++;
    }
    i32 b = lx.pos;
    lx.pos++;
    i32 fa = lx.pos;
    while lx.pos < lx.src.len && is_id_part(lx_cur(lx)) { lx.pos++; }
    t.kind = TOK_REGEX;
    t.text = lx_view(lx, a, b);
    t.aux = lx_view(lx, fa, lx.pos);
    t.end = lx.pos;
    return t;
}

// Re-lex a '}' token as a template continuation. The parser calls
// this when the brace closes a `${…}` substitution.
Token lexer_rescan_template(Lexer* lx, Token rbrace) {
    Token t;
    t.newline_before = rbrace.newline_before;
    t.start = rbrace.start;
    lx.pos = rbrace.start + 1;
    scan_template(lx, &t, true);
    t.end = lx.pos;
    return t;
}

// Scan-position save/restore for parser speculation.
i32 lexer_tell(Lexer* lx) {
    return lx.pos;
}

void lexer_seek(Lexer* lx, i32 pos) {
    lx.pos = pos;
}

// --- init / teardown ------------------------------------------------

void lexer_init(Lexer* lx, str src, DiagList* diags) {
    lx.src = src;
    lx.pos = 0;
    lx.diags = diags;
    vec_init<str>(&lx.owned, 8);
    if !g_lxc_ready { lxc_init(); }
    if src.len >= 3 && *(src.data) == 0xEF && *(src.data + 1) == 0xBB && *(src.data + 2) == 0xBF {
        lx.pos = 3;
    }
    if lx_at(lx, lx.pos) == '#' && lx_at(lx, lx.pos + 1) == '!' {
        while lx.pos < src.len && lx_cur(lx) != '\n' { lx.pos++; }
    }
}

void lexer_destroy(Lexer* lx) {
    for i32 i = 0; i < lx.owned.len; i++ {
        str s = vec_get(&lx.owned, i);
        free(s.data);
    }
    vec_free(&lx.owned);
}

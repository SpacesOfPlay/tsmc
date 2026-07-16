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
    f64 num;               // TOK_NUMBER value
    str text;              // ident/keyword name, cooked string/template, regex pattern
    str aux;               // regex flags
}

struct Lexer {
    str src;
    i32 pos;
    DiagList* diags;
    StrMap<i32> keywords;
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

private bool is_id_start(u8 c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c == '$';
}

private bool is_id_part(u8 c) {
    return is_id_start(c) || is_digit(c);
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
    while lx.pos < lx.src.len {
        u8 c = lx_cur(lx);
        if c == ' ' || c == '\t' || c == 11 || c == 12 {   // \v \f
            lx.pos++;
            continue;
        }
        if c == '\n' || c == '\r' {
            nl = true;
            lx.pos++;
            continue;
        }
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
private void scan_ident(Lexer* lx, Token* t) {
    i32 a = lx.pos;
    bool esc = false;
    if lx_cur(lx) == '\\' {
        if scan_ident_escape(lx) < 0 {
            lex_error(lx, a, lx.pos + 1, "invalid Unicode escape in identifier");
            t.kind = TOK_ERROR;
            lx.pos++;
            t.text = lx_view(lx, a, lx.pos);
            return;
        }
        esc = true;
    } else {
        lx.pos++;
    }
    while lx.pos < lx.src.len {
        u8 c = lx_cur(lx);
        if c == '\\' {
            if scan_ident_escape(lx) < 0 { break; }
            esc = true;
        } else if is_id_part(c) {
            lx.pos++;
        } else {
            break;
        }
    }
    if esc { t.text = decode_ident(lx, a, lx.pos); }
    else { t.text = lx_view(lx, a, lx.pos); }
    i32* k = strmap_get<i32>(&lx.keywords, t.text);
    if k != null {
        t.kind = *k;
    } else {
        t.kind = TOK_IDENT;
    }
}

private void scan_private_name(Lexer* lx, Token* t) {
    lx.pos++;
    if lx.pos >= lx.src.len || !is_id_start(lx_cur(lx)) {
        lex_error(lx, lx.pos - 1, lx.pos, "expected identifier after '#'");
        t.kind = TOK_ERROR;
        return;
    }
    i32 a = lx.pos;
    while lx.pos < lx.src.len && is_id_part(lx_cur(lx)) { lx.pos++; }
    t.kind = TOK_PRIVATE_NAME;
    t.text = lx_view(lx, a, lx.pos);
}

// --- numbers --------------------------------------------------------

private f64[23] g_pow10 = {
    1.0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11,
    1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22
};

// mant * 10^e. Correctly rounded when mant < 2^53 and |e| <= 22;
// otherwise stepped multiplies, within ~2 ulp. A correctly-rounded
// parser is a later infrastructure task.
private f64 scale10(u64 mant, i32 e) {
    if mant == 0 { return 0.0; }
    f64 v = cast(f64, mant);
    bool exact = mant < 9007199254740992;
    if exact && e >= 0 && e <= 22 { return v * g_pow10[e]; }
    if exact && e < 0 && e >= -22 { return v / g_pow10[-e]; }
    while e > 22 {
        v = v * g_pow10[22];
        e -= 22;
    }
    if e > 0 {
        v = v * g_pow10[e];
        e = 0;
    }
    while e < -22 {
        v = v / g_pow10[22];
        e += 22;
    }
    if e < 0 { v = v / g_pow10[-e]; }
    return v;
}

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
    u64 mant = 0;
    i32 sig = 0;
    i32 exp_adjust = 0;
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
        if sig < 19 {
            u64 d = c - '0';
            mant = mant * 10 + d;
            if mant != 0 { sig++; }
        } else {
            exp_adjust++;
        }
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
            if sig < 19 {
                u64 d = c - '0';
                mant = mant * 10 + d;
                if mant != 0 { sig++; }
                exp_adjust--;
            }
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
            i32 ev = 0;
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
                i32 d = c - '0';
                if ev < 1000000 { ev = ev * 10 + d; }
                prev_digit = true;
                last_us = false;
                lx.pos++;
            }
            if last_us { sep_err = true; }
            if neg { exp_adjust -= ev; } else { exp_adjust += ev; }
        }
    }

    if sep_err {
        lex_error(lx, start, lx.pos, "numeric separator must be between digits");
    }
    f64 v = scale10(mant, exp_adjust);
    finish_number(lx, t, start, v, !has_frac && !has_exp);
}

private void scan_number(Lexer* lx, Token* t) {
    i32 start = lx.pos;
    t.kind = TOK_NUMBER;
    if lx_cur(lx) == '0' {
        u8 n = lx_at(lx, lx.pos + 1);
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
    while true {
        if lx.pos >= lx.src.len {
            lex_error(lx, tok_start, lx.pos, "unterminated string literal");
            t.kind = TOK_ERROR;
            return;
        }
        u8 c = lx_cur(lx);
        if c == q { break; }
        if c == '\n' || c == '\r' {
            lex_error(lx, tok_start, lx.pos, "unterminated string literal");
            t.kind = TOK_ERROR;
            return;
        }
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
        lx.pos++;
    }
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
    u8 c1 = lx_at(lx, lx.pos + 1);
    u8 c2 = lx_at(lx, lx.pos + 2);
    u8 c3 = lx_at(lx, lx.pos + 3);

    if c == '{' { pk(lx, t, TOK_LBRACE, 1); return; }
    if c == '}' { pk(lx, t, TOK_RBRACE, 1); return; }
    if c == '(' { pk(lx, t, TOK_LPAREN, 1); return; }
    if c == ')' { pk(lx, t, TOK_RPAREN, 1); return; }
    if c == '[' { pk(lx, t, TOK_LBRACK, 1); return; }
    if c == ']' { pk(lx, t, TOK_RBRACK, 1); return; }
    if c == ';' { pk(lx, t, TOK_SEMI, 1); return; }
    if c == ',' { pk(lx, t, TOK_COMMA, 1); return; }
    if c == ':' { pk(lx, t, TOK_COLON, 1); return; }
    if c == '@' { pk(lx, t, TOK_AT, 1); return; }
    if c == '~' { pk(lx, t, TOK_TILDE, 1); return; }
    if c == '.' {
        if c1 == '.' && c2 == '.' { pk(lx, t, TOK_DOTDOTDOT, 3); return; }
        pk(lx, t, TOK_DOT, 1);
        return;
    }
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

Token lexer_next(Lexer* lx) {
    bool nl = skip_trivia(lx);
    Token t;
    t.newline_before = nl;
    t.start = lx.pos;
    if lx.pos >= lx.src.len {
        t.kind = TOK_EOF;
        t.end = lx.pos;
        return t;
    }
    u8 c = lx_cur(lx);
    if is_id_start(c) || (c == '\\' && lx_at(lx, lx.pos + 1) == 'u') {
        scan_ident(lx, &t);
    } else if is_digit(c) {
        scan_number(lx, &t);
    } else if c == '.' && is_digit(lx_at(lx, lx.pos + 1)) {
        scan_number(lx, &t);
    } else if c == '"' || c == '\'' {
        scan_string(lx, &t);
    } else if c == '`' {
        lx.pos++;
        scan_template(lx, &t, false);
    } else if c == '#' {
        scan_private_name(lx, &t);
    } else {
        scan_punct(lx, &t);
    }
    t.end = lx.pos;
    return t;
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
        if c == '\n' || c == '\r' {
            lex_error(lx, t.start, lx.pos, "unterminated regular expression");
            t.kind = TOK_ERROR;
            t.end = lx.pos;
            return t;
        }
        if c == '\\' {
            u8 e = lx_at(lx, lx.pos + 1);
            if e == '\n' || e == '\r' || e == 0 {
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

private void kw(Lexer* lx, str name, i32 kind) {
    strmap_set<i32>(&lx.keywords, name, kind);
}

private void add_keywords(Lexer* lx) {
    kw(lx, "abstract", TOK_KW_ABSTRACT);
    kw(lx, "as", TOK_KW_AS);
    kw(lx, "asserts", TOK_KW_ASSERTS);
    kw(lx, "async", TOK_KW_ASYNC);
    kw(lx, "await", TOK_KW_AWAIT);
    kw(lx, "break", TOK_KW_BREAK);
    kw(lx, "case", TOK_KW_CASE);
    kw(lx, "catch", TOK_KW_CATCH);
    kw(lx, "class", TOK_KW_CLASS);
    kw(lx, "const", TOK_KW_CONST);
    kw(lx, "continue", TOK_KW_CONTINUE);
    kw(lx, "debugger", TOK_KW_DEBUGGER);
    kw(lx, "declare", TOK_KW_DECLARE);
    kw(lx, "default", TOK_KW_DEFAULT);
    kw(lx, "delete", TOK_KW_DELETE);
    kw(lx, "do", TOK_KW_DO);
    kw(lx, "else", TOK_KW_ELSE);
    kw(lx, "enum", TOK_KW_ENUM);
    kw(lx, "export", TOK_KW_EXPORT);
    kw(lx, "extends", TOK_KW_EXTENDS);
    kw(lx, "false", TOK_KW_FALSE);
    kw(lx, "finally", TOK_KW_FINALLY);
    kw(lx, "for", TOK_KW_FOR);
    kw(lx, "from", TOK_KW_FROM);
    kw(lx, "function", TOK_KW_FUNCTION);
    kw(lx, "get", TOK_KW_GET);
    kw(lx, "global", TOK_KW_GLOBAL);
    kw(lx, "if", TOK_KW_IF);
    kw(lx, "implements", TOK_KW_IMPLEMENTS);
    kw(lx, "import", TOK_KW_IMPORT);
    kw(lx, "in", TOK_KW_IN);
    kw(lx, "infer", TOK_KW_INFER);
    kw(lx, "instanceof", TOK_KW_INSTANCEOF);
    kw(lx, "interface", TOK_KW_INTERFACE);
    kw(lx, "is", TOK_KW_IS);
    kw(lx, "keyof", TOK_KW_KEYOF);
    kw(lx, "let", TOK_KW_LET);
    kw(lx, "module", TOK_KW_MODULE);
    kw(lx, "namespace", TOK_KW_NAMESPACE);
    kw(lx, "new", TOK_KW_NEW);
    kw(lx, "null", TOK_KW_NULL);
    kw(lx, "of", TOK_KW_OF);
    kw(lx, "out", TOK_KW_OUT);
    kw(lx, "override", TOK_KW_OVERRIDE);
    kw(lx, "private", TOK_KW_PRIVATE);
    kw(lx, "protected", TOK_KW_PROTECTED);
    kw(lx, "public", TOK_KW_PUBLIC);
    kw(lx, "readonly", TOK_KW_READONLY);
    kw(lx, "return", TOK_KW_RETURN);
    kw(lx, "satisfies", TOK_KW_SATISFIES);
    kw(lx, "set", TOK_KW_SET);
    kw(lx, "static", TOK_KW_STATIC);
    kw(lx, "super", TOK_KW_SUPER);
    kw(lx, "switch", TOK_KW_SWITCH);
    kw(lx, "this", TOK_KW_THIS);
    kw(lx, "throw", TOK_KW_THROW);
    kw(lx, "true", TOK_KW_TRUE);
    kw(lx, "try", TOK_KW_TRY);
    kw(lx, "type", TOK_KW_TYPE);
    kw(lx, "typeof", TOK_KW_TYPEOF);
    kw(lx, "unique", TOK_KW_UNIQUE);
    kw(lx, "var", TOK_KW_VAR);
    kw(lx, "void", TOK_KW_VOID);
    kw(lx, "while", TOK_KW_WHILE);
    kw(lx, "with", TOK_KW_WITH);
    kw(lx, "yield", TOK_KW_YIELD);
}

void lexer_init(Lexer* lx, str src, DiagList* diags) {
    lx.src = src;
    lx.pos = 0;
    lx.diags = diags;
    strmap_init<i32>(&lx.keywords);
    vec_init<str>(&lx.owned, 8);
    add_keywords(lx);
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
    strmap_free<i32>(&lx.keywords);
}

// test_lexer.mc — token kinds, values, spans, rescans, ASI flags.

import str;
import "../helpers/check.mc";
import "../../src/diag.mc";
import "../../src/lexer.mc";

// Lexes src and checks the token kind sequence, then EOF, no errors.
void check_kinds(str src, i32* kinds, i32 n, str what) {
    DiagList d;
    diags_init(&d);
    Lexer lx;
    lexer_init(&lx, src, &d);
    for i32 i = 0; i < n; i++ {
        Token t = lexer_next(&lx);
        check(t.kind == *(kinds + i), what);
    }
    Token e = lexer_next(&lx);
    check(e.kind == TOK_EOF, what);
    check(d.n_errors == 0, what);
    lexer_destroy(&lx);
    diags_free(&d);
}

void check_num(str src, f64 want, str what) {
    DiagList d;
    diags_init(&d);
    Lexer lx;
    lexer_init(&lx, src, &d);
    Token t = lexer_next(&lx);
    check(t.kind == TOK_NUMBER, what);
    check(t.num == want, what);
    check(d.n_errors == 0, what);
    lexer_destroy(&lx);
    diags_free(&d);
}

void check_str_lit(str src, str want, str what) {
    DiagList d;
    diags_init(&d);
    Lexer lx;
    lexer_init(&lx, src, &d);
    Token t = lexer_next(&lx);
    check(t.kind == TOK_STRING, what);
    check(str_equal(t.text, want), what);
    check(d.n_errors == 0, what);
    lexer_destroy(&lx);
    diags_free(&d);
}

// Lexes everything; asserts at least one diagnostic error.
void check_lex_error(str src, str what) {
    DiagList d;
    diags_init(&d);
    Lexer lx;
    lexer_init(&lx, src, &d);
    for i32 i = 0; i < 100; i++ {
        Token t = lexer_next(&lx);
        if t.kind == TOK_EOF { break; }
    }
    check(d.n_errors > 0, what);
    lexer_destroy(&lx);
    diags_free(&d);
}

i32 main() {
    // maximal munch: > family
    i32[7] gt_kinds = {
        TOK_URSHIFT_EQ, TOK_URSHIFT, TOK_RSHIFT, TOK_RSHIFT_EQ,
        TOK_GE, TOK_GT, TOK_LT
    };
    check_kinds(">>>= >>> >> >>= >= > <", &gt_kinds[0], 7, "gt family");

    i32[10] op_kinds = {
        TOK_DOTDOTDOT, TOK_QUESTION_DOT, TOK_QUESTION_QUESTION,
        TOK_QUESTION_QUESTION_EQ, TOK_ARROW, TOK_STARSTAR,
        TOK_STARSTAR_EQ, TOK_EQEQEQ, TOK_NEQEQEQ, TOK_DOT
    };
    check_kinds("... ?. ?? ??= => ** **= === !== .", &op_kinds[0], 10, "ops");

    i32[12] as_kinds = {
        TOK_EQ, TOK_PLUS_EQ, TOK_MINUS_EQ, TOK_STAR_EQ, TOK_SLASH_EQ,
        TOK_PERCENT_EQ, TOK_AMP_EQ, TOK_PIPE_EQ, TOK_CARET_EQ,
        TOK_AMPAMP_EQ, TOK_PIPEPIPE_EQ, TOK_LSHIFT_EQ
    };
    check_kinds("= += -= *= /= %= &= |= ^= &&= ||= <<=", &as_kinds[0], 12, "assign ops");

    i32[14] more_kinds = {
        TOK_PLUSPLUS, TOK_MINUSMINUS, TOK_AMPAMP, TOK_PIPEPIPE,
        TOK_BANG, TOK_TILDE, TOK_AMP, TOK_PIPE, TOK_CARET,
        TOK_LSHIFT, TOK_EQEQ, TOK_NEQ, TOK_LE, TOK_AT
    };
    check_kinds("++ -- && || ! ~ & | ^ << == != <= @", &more_kinds[0], 14, "more ops");

    i32[10] br_kinds = {
        TOK_LPAREN, TOK_RPAREN, TOK_LBRACK, TOK_RBRACK, TOK_LBRACE,
        TOK_RBRACE, TOK_SEMI, TOK_COMMA, TOK_COLON, TOK_QUESTION
    };
    check_kinds("( ) [ ] { } ; , : ?", &br_kinds[0], 10, "brackets");

    // ?. not followed by digit: x?.5:y is ? then .5
    i32[5] qd_kinds = { TOK_IDENT, TOK_QUESTION, TOK_NUMBER, TOK_COLON, TOK_IDENT };
    check_kinds("x?.5:y", &qd_kinds[0], 5, "?.digit");

    // keywords vs identifiers
    i32[8] kw_kinds = {
        TOK_KW_LET, TOK_KW_CONST, TOK_KW_TYPEOF, TOK_KW_INSTANCEOF,
        TOK_KW_OF, TOK_KW_TYPE, TOK_KW_INTERFACE, TOK_IDENT
    };
    check_kinds("let const typeof instanceof of type interface letx", &kw_kinds[0], 8, "keywords");
    check(tok_is_keyword(TOK_KW_LET), "let is keyword");
    check(tok_is_keyword(TOK_KW_YIELD), "yield is keyword");
    check(tok_is_keyword(TOK_KW_ABSTRACT), "abstract is keyword");
    check(!tok_is_keyword(TOK_IDENT), "ident not keyword");
    check(!tok_is_keyword(TOK_STRING), "string not keyword");

    // numbers
    check_num("42", 42.0, "int");
    check_num("0", 0.0, "zero");
    check_num("3.14", 3.14, "decimal");
    check_num(".5", 0.5, "leading dot");
    check_num("5.", 5.0, "trailing dot");
    check_num("1e6", 1000000.0, "exponent");
    check_num("1.5e-3", 0.0015, "negative exponent");
    check_num("2.5E+10", 25000000000.0, "explicit plus exponent");
    check_num("0xFF", 255.0, "hex");
    check_num("0Xff", 255.0, "hex upper");
    check_num("0b1010", 10.0, "binary");
    check_num("0o777", 511.0, "octal");
    check_num("1_000_000", 1000000.0, "separators");
    check_num("0x1_00", 256.0, "hex separators");
    check_num("9007199254740993", 9007199254740992.0, "rounds past 2^53");
    check_num("1e309", 1.0e308 * 10.0, "overflow to inf");
    check_num("0.0001", 0.0001, "small decimal");

    // bigint
    {
        DiagList d;
        diags_init(&d);
        Lexer lx;
        lexer_init(&lx, "123n 1_000n", &d);
        Token t = lexer_next(&lx);
        check(t.kind == TOK_BIGINT, "bigint kind");
        check(str_equal(t.text, "123n"), "bigint text");
        t = lexer_next(&lx);
        check(t.kind == TOK_BIGINT, "bigint with separator");
        check(d.n_errors == 0, "bigint clean");
        lexer_destroy(&lx);
        diags_free(&d);
    }

    // number errors
    check_lex_error("08", "legacy octal");
    check_lex_error("1__2", "double separator");
    check_lex_error("1_", "trailing separator");
    check_lex_error("0x", "missing hex digits");
    check_lex_error("3in x", "ident after number");
    check_lex_error("1.5n", "fractional bigint");

    // strings
    check_str_lit("'hello'", "hello", "single quoted");
    check_str_lit("\"hi\"", "hi", "double quoted");
    check_str_lit("''", "", "empty");
    check_str_lit("\"it's\"", "it's", "quote mix");
    check_str_lit("'a\\nb'", "a\nb", "newline escape");
    check_str_lit("'t\\tv'", "t\tv", "tab escape");
    check_str_lit("'\\x41'", "A", "hex escape");
    check_str_lit("'\\u0041'", "A", "u4 escape");
    check_str_lit("'q\\u{41}z'", "qAz", "braced escape");
    check_str_lit("'\\u{1F389}'", "🎉", "astral escape");
    check_str_lit("'\\q'", "q", "non-escape char");
    check_str_lit("'a\\\nb'", "ab", "line continuation");
    check_str_lit("'a\\0b'", "a\0b", "nul escape");

    // string errors
    check_lex_error("'abc", "unterminated string");
    check_lex_error("'a\nb'", "raw newline in string");
    check_lex_error("'\\x4'", "bad hex escape");
    check_lex_error("'\\u{110000}'", "codepoint too large");
    check_lex_error("'\\1'", "octal escape");

    // templates
    {
        DiagList d;
        diags_init(&d);
        Lexer lx;
        lexer_init(&lx, "`abc`", &d);
        Token t = lexer_next(&lx);
        check(t.kind == TOK_TEMPLATE_FULL, "template full");
        check(str_equal(t.text, "abc"), "template full text");
        lexer_destroy(&lx);

        lexer_init(&lx, "`a${b}c${d}e`", &d);
        t = lexer_next(&lx);
        check(t.kind == TOK_TEMPLATE_HEAD, "template head");
        check(str_equal(t.text, "a"), "head text");
        t = lexer_next(&lx);
        check(t.kind == TOK_IDENT, "sub ident 1");
        t = lexer_next(&lx);
        check(t.kind == TOK_RBRACE, "sub close 1");
        t = lexer_rescan_template(&lx, t);
        check(t.kind == TOK_TEMPLATE_MIDDLE, "template middle");
        check(str_equal(t.text, "c"), "middle text");
        t = lexer_next(&lx);
        check(t.kind == TOK_IDENT, "sub ident 2");
        t = lexer_next(&lx);
        t = lexer_rescan_template(&lx, t);
        check(t.kind == TOK_TEMPLATE_TAIL, "template tail");
        check(str_equal(t.text, "e"), "tail text");
        t = lexer_next(&lx);
        check(t.kind == TOK_EOF, "template chain eof");
        lexer_destroy(&lx);

        lexer_init(&lx, "`a\\n${x}`", &d);
        t = lexer_next(&lx);
        check(t.kind == TOK_TEMPLATE_HEAD && str_equal(t.text, "a\n"), "template escape");
        lexer_destroy(&lx);

        lexer_init(&lx, "`a\nb`", &d);
        t = lexer_next(&lx);
        check(t.kind == TOK_TEMPLATE_FULL && str_equal(t.text, "a\nb"), "raw newline in template");
        lexer_destroy(&lx);

        lexer_init(&lx, "`a\r\nb`", &d);
        t = lexer_next(&lx);
        check(str_equal(t.text, "a\nb"), "crlf normalized");
        lexer_destroy(&lx);

        lexer_init(&lx, "`\\${x}`", &d);
        t = lexer_next(&lx);
        check(t.kind == TOK_TEMPLATE_FULL && str_equal(t.text, "${x}"), "escaped dollar");
        lexer_destroy(&lx);

        check(d.n_errors == 0, "templates clean");
        diags_free(&d);
    }
    check_lex_error("`abc", "unterminated template");

    // regex via rescan
    {
        DiagList d;
        diags_init(&d);
        Lexer lx;
        lexer_init(&lx, "x = /ab+c/gi;", &d);
        Token t = lexer_next(&lx);
        check(t.kind == TOK_IDENT, "regex stmt ident");
        t = lexer_next(&lx);
        check(t.kind == TOK_EQ, "regex stmt eq");
        t = lexer_next(&lx);
        check(t.kind == TOK_SLASH, "slash before rescan");
        t = lexer_rescan_regex(&lx, t);
        check(t.kind == TOK_REGEX, "regex kind");
        check(str_equal(t.text, "ab+c"), "regex pattern");
        check(str_equal(t.aux, "gi"), "regex flags");
        t = lexer_next(&lx);
        check(t.kind == TOK_SEMI, "after regex");
        lexer_destroy(&lx);

        lexer_init(&lx, "/a[/]b/", &d);
        t = lexer_next(&lx);
        t = lexer_rescan_regex(&lx, t);
        check(t.kind == TOK_REGEX && str_equal(t.text, "a[/]b"), "slash in class");
        check(t.aux.len == 0, "no flags");
        lexer_destroy(&lx);

        lexer_init(&lx, "/a\\/b/", &d);
        t = lexer_next(&lx);
        t = lexer_rescan_regex(&lx, t);
        check(t.kind == TOK_REGEX && str_equal(t.text, "a\\/b"), "escaped slash");
        lexer_destroy(&lx);

        // /= token rescans from its first character
        lexer_init(&lx, "/=x/", &d);
        t = lexer_next(&lx);
        check(t.kind == TOK_SLASH_EQ, "slash-eq default");
        t = lexer_rescan_regex(&lx, t);
        check(t.kind == TOK_REGEX && str_equal(t.text, "=x"), "slash-eq rescan");
        lexer_destroy(&lx);

        check(d.n_errors == 0, "regex clean");

        lexer_init(&lx, "/abc", &d);
        t = lexer_next(&lx);
        t = lexer_rescan_regex(&lx, t);
        check(t.kind == TOK_ERROR, "unterminated regex");
        check(d.n_errors > 0, "unterminated regex diag");
        lexer_destroy(&lx);
        diags_free(&d);
    }

    // newline_before
    {
        DiagList d;
        diags_init(&d);
        Lexer lx;
        lexer_init(&lx, "a\nb c", &d);
        Token t = lexer_next(&lx);
        check(!t.newline_before, "first token no newline");
        t = lexer_next(&lx);
        check(t.newline_before, "newline before b");
        t = lexer_next(&lx);
        check(!t.newline_before, "no newline before c");
        lexer_destroy(&lx);

        lexer_init(&lx, "a /* x\ny */ b", &d);
        t = lexer_next(&lx);
        t = lexer_next(&lx);
        check(t.newline_before, "newline inside block comment");
        lexer_destroy(&lx);

        lexer_init(&lx, "a // note\nb", &d);
        t = lexer_next(&lx);
        t = lexer_next(&lx);
        check(t.newline_before, "newline after line comment");
        check(t.kind == TOK_IDENT, "comment skipped");
        lexer_destroy(&lx);
        diags_free(&d);
    }

    // shebang and BOM
    {
        DiagList d;
        diags_init(&d);
        Lexer lx;
        lexer_init(&lx, "#!/usr/bin/env node\nlet x", &d);
        Token t = lexer_next(&lx);
        check(t.kind == TOK_KW_LET, "shebang skipped");
        lexer_destroy(&lx);

        lexer_init(&lx, "\xEF\xBB\xBFlet x", &d);
        t = lexer_next(&lx);
        check(t.kind == TOK_KW_LET, "bom skipped");
        check(d.n_errors == 0, "shebang/bom clean");
        lexer_destroy(&lx);
        diags_free(&d);
    }

    // private names
    {
        DiagList d;
        diags_init(&d);
        Lexer lx;
        lexer_init(&lx, "#field", &d);
        Token t = lexer_next(&lx);
        check(t.kind == TOK_PRIVATE_NAME, "private name kind");
        check(str_equal(t.text, "field"), "private name text");
        check(d.n_errors == 0, "private name clean");
        lexer_destroy(&lx);
        diags_free(&d);
    }
    check_lex_error("#1", "bad private name");

    // spans
    {
        DiagList d;
        diags_init(&d);
        Lexer lx;
        lexer_init(&lx, "let x", &d);
        Token t = lexer_next(&lx);
        check(t.start == 0 && t.end == 3, "kw span");
        t = lexer_next(&lx);
        check(t.start == 4 && t.end == 5, "ident span");
        lexer_destroy(&lx);
        diags_free(&d);
    }

    // tell/seek rewind for speculation
    {
        DiagList d;
        diags_init(&d);
        Lexer lx;
        lexer_init(&lx, "a b", &d);
        Token t1 = lexer_next(&lx);
        i32 p = lexer_tell(&lx);
        Token t2 = lexer_next(&lx);
        lexer_seek(&lx, p);
        Token t3 = lexer_next(&lx);
        check(t2.start == t3.start && t2.kind == t3.kind, "seek rewind");
        check(str_equal(t1.text, "a") && str_equal(t3.text, "b"), "rewind texts");
        lexer_destroy(&lx);
        diags_free(&d);
    }

    // unknown character
    check_lex_error("§", "unexpected character");

    return check_done("test_lexer");
}

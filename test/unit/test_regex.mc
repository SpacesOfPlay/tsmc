// test_regex.mc — regex engine, standalone (no VM).

import str;
import "../helpers/check.mc";
import "../../src/regex.mc";

// Compiles p/flags, execs against subject from 0; checks match and the
// whole-match span text.
void check_match(str pat, str flags, str subject, str want, str what) {
    RegexProg* prog = regex_compile(pat, flags);
    if prog == null {
        eprint("  FAIL: {} (compile failed)\n", what);
        g_checks_failed++;
        g_checks_run++;
        return;
    }
    i32 ncap = 2 * (regex_ngroups(prog) + 1);
    i32* caps = alloc<i32>(ncap);
    bool ok = regex_exec(prog, subject, 0, caps);
    if !ok {
        eprint("  FAIL: {} (no match)\n", what);
        g_checks_failed++;
    } else {
        str got;
        got.data = subject.data + *(caps + 0);
        got.len = *(caps + 1) - *(caps + 0);
        if !str_equal(got, want) {
            eprint("  FAIL: {} (got '{}', want '{}')\n", what, got, want);
            g_checks_failed++;
        }
    }
    g_checks_run++;
    free(caps);
    regex_free(prog);
}

void check_nomatch(str pat, str flags, str subject, str what) {
    RegexProg* prog = regex_compile(pat, flags);
    if prog == null {
        eprint("  FAIL: {} (compile failed)\n", what);
        g_checks_failed++;
        g_checks_run++;
        return;
    }
    i32 ncap = 2 * (regex_ngroups(prog) + 1);
    i32* caps = alloc<i32>(ncap);
    bool ok = regex_exec(prog, subject, 0, caps);
    if ok {
        eprint("  FAIL: {} (matched but shouldn't)\n", what);
        g_checks_failed++;
    }
    g_checks_run++;
    free(caps);
    regex_free(prog);
}

// Checks capture group g's span text.
void check_group(str pat, str flags, str subject, i32 g, str want, str what) {
    RegexProg* prog = regex_compile(pat, flags);
    if prog == null {
        eprint("  FAIL: {} (compile failed)\n", what);
        g_checks_failed++;
        g_checks_run++;
        return;
    }
    i32 ncap = 2 * (regex_ngroups(prog) + 1);
    i32* caps = alloc<i32>(ncap);
    bool ok = regex_exec(prog, subject, 0, caps);
    if !ok {
        eprint("  FAIL: {} (no match)\n", what);
        g_checks_failed++;
    } else {
        i32 gs = *(caps + 2 * g);
        i32 ge = *(caps + 2 * g + 1);
        str got;
        if gs < 0 {
            got = "";
        } else {
            got.data = subject.data + gs;
            got.len = ge - gs;
        }
        if !str_equal(got, want) {
            eprint("  FAIL: {} (group {} got '{}', want '{}')\n", what, g, got, want);
            g_checks_failed++;
        }
    }
    g_checks_run++;
    free(caps);
    regex_free(prog);
}

i32 main() {
    // literals and anchors
    check_match("abc", "", "xxabcxx", "abc", "literal");
    check_match("^abc", "", "abcdef", "abc", "anchor start");
    check_nomatch("^abc", "", "xabc", "anchor start fails");
    check_match("abc$", "", "xxabc", "abc", "anchor end");
    check_nomatch("abc$", "", "abcx", "anchor end fails");

    // . and classes
    check_match("a.c", "", "axc", "axc", "dot");
    check_nomatch("a.c", "", "a\nc", "dot not newline");
    check_match("[abc]+", "", "xxbcabz", "bcab", "class");
    check_match("[^0-9]+", "", "abc123", "abc", "negated class");
    check_match("[a-z]+", "", "ABCdefGHI", "def", "range");
    check_match("\\d+", "", "abc4567xy", "4567", "digit class");
    check_match("\\w+", "", "  foo_bar!", "foo_bar", "word class");
    check_match("a\\s+b", "", "a   b", "a   b", "space class");

    // quantifiers
    check_match("ab*c", "", "ac", "ac", "star zero");
    check_match("ab*c", "", "abbbc", "abbbc", "star many");
    check_match("ab+c", "", "abbc", "abbc", "plus");
    check_nomatch("ab+c", "", "ac", "plus needs one");
    check_match("ab?c", "", "ac", "ac", "quest zero");
    check_match("ab?c", "", "abc", "abc", "quest one");
    check_match("a{2,3}", "", "aaaa", "aaa", "repeat greedy");
    check_match("a{2}", "", "aaaa", "aa", "repeat exact");
    check_match("a{2,}", "", "aaaaa", "aaaaa", "repeat unbounded");
    check_nomatch("a{3}", "", "aa", "repeat min fails");

    // greedy vs lazy
    check_match("<.*>", "", "<a><b>", "<a><b>", "greedy");
    check_match("<.*?>", "", "<a><b>", "<a>", "lazy");
    check_match("a+?", "", "aaa", "a", "lazy plus");

    // alternation
    check_match("cat|dog|bird", "", "I have a dog", "dog", "alternation");
    check_match("(ab|cd)+", "", "abcdab", "abcdab", "grouped alternation");

    // groups and captures
    check_group("(\\d+)-(\\d+)", "", "12-345", 1, "12", "capture 1");
    check_group("(\\d+)-(\\d+)", "", "12-345", 2, "345", "capture 2");
    check_group("(a)(b)?(c)", "", "ac", 2, "", "optional unset capture");
    check_match("(?:ab)+", "", "ababab", "ababab", "non-capturing");
    check_group("(a(b(c)))", "", "abc", 3, "c", "nested capture");

    // backreferences
    check_match("(\\w)\\1", "", "hello", "ll", "backref");
    check_nomatch("(\\w)\\1", "", "abc", "backref no repeat");
    check_group("(['\"]).*?\\1", "", "say 'hi' there", 1, "'", "quote backref");

    // lookahead
    check_match("foo(?=bar)", "", "foobar", "foo", "positive lookahead");
    check_nomatch("foo(?=bar)", "", "foobaz", "positive lookahead fails");
    check_match("foo(?!bar)", "", "foobaz", "foo", "negative lookahead");
    check_nomatch("foo(?!bar)", "", "foobar", "negative lookahead fails");
    check_match("\\d+(?=px)", "", "size:16px", "16", "lookahead width");

    // word boundaries
    check_match("\\bword\\b", "", "a word here", "word", "word boundary");
    check_nomatch("\\bword\\b", "", "wordy", "word boundary fails");
    check_match("\\Bar", "", "bar car", "ar", "non word boundary");

    // flags
    check_match("abc", "i", "XYZABCxy", "ABC", "case insensitive");
    check_match("[a-z]+", "i", "ABC", "ABC", "case insensitive class");
    check_match("^b", "m", "a\nb\nc", "b", "multiline start");
    check_match("a.b", "s", "a\nb", "a\nb", "dotall");

    // escapes
    check_match("a\\.b", "", "a.b", "a.b", "escaped dot");
    check_nomatch("a\\.b", "", "axb", "escaped dot literal");
    check_match("\\$\\d+", "", "cost $42", "$42", "escaped dollar");
    check_match("a\\tb", "", "a\tb", "a\tb", "tab escape");

    // compile errors
    check(regex_compile("(abc", "") == null, "unclosed group errors");
    check(regex_compile("[abc", "") == null, "unclosed class errors");

    // realistic patterns
    check_match("[a-zA-Z_][a-zA-Z0-9_]*", "", "  my_var2 = 3", "my_var2", "identifier");
    check_group("(\\d{4})-(\\d{2})-(\\d{2})", "", "date 2024-01-15!", 2, "01", "date parts");
    check_match("https?://[^\\s]+", "", "go to https://x.io now", "https://x.io", "url");

    return check_done("test_regex");
}

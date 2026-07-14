// check.mc — shared assertions for unit tests.
//
// Tests call check*() and return check_done() from main. Output only
// appears on failure; the harness gates on the exit code.

i32 g_checks_run = 0;
i32 g_checks_failed = 0;

void check(bool cond, str what) {
    g_checks_run++;
    if !cond {
        eprint("  FAIL: {}\n", what);
        g_checks_failed++;
    }
}

void check_eq(i32 got, i32 want, str what) {
    g_checks_run++;
    if got != want {
        eprint("  FAIL: {} (got {}, want {})\n", what, got, want);
        g_checks_failed++;
    }
}

void check_eq_i64(i64 got, i64 want, str what) {
    g_checks_run++;
    if got != want {
        eprint("  FAIL: {} (got {}, want {})\n", what, got, want);
        g_checks_failed++;
    }
}

i32 check_done(str suite) {
    if g_checks_failed > 0 {
        eprint("{}: {}/{} checks failed\n", suite, g_checks_failed, g_checks_run);
        return 1;
    }
    return 0;
}

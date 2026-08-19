// build.mc — build and test tsmc.
//
// Usage, from this folder:
//   minc build      compile build/tsmc
//   minc test       build, then unit + cli + golden + gc-stress
//   minc bench      build, then time bench/*.ts
//   minc clean      remove build/
//
// plugins, diff and t262 have no minc verb. Compile this script once
// and call it directly:
//   minc build.mc -o build/build.exe
//   build/build.exe plugins
//
// Requires the minc compiler: its install dir on PATH, or MINC naming
// that dir (the folder holding the binary and its lib/). A deploy at
// ./minc is preferred over PATH when present, which is how this repo
// is developed; nothing needs it to be there.

import process;
import file;
import str;

when os(windows) { str EXE_SUFFIX = ".exe"; }
when os(linux) || os(macos) { str EXE_SUFFIX = ""; }

str VERSION_LINE = "tsmc 0.1.0-dev";

i32 g_pass = 0;
i32 g_fail = 0;

// Set by assert_toolchain: the install dir, and the binary inside it.
string g_minc_dir;
string g_minc;

void out(str s) {
    write(stdout(), s.data, s.len);
    return;
}

void outln(str s) {
    out(s);
    write(stdout(), "\n", 1);
    return;
}

void out_int(i64 v) {
    u8[24] buf;
    i32 n = 0;
    if v < 0 {
        write(stdout(), "-", 1);
        v = -v;
    }
    if v == 0 {
        buf[0] = 48;
        n = 1;
    }
    while v > 0 {
        buf[n] = cast(u8, 48 + cast(i32, v % 10));
        v = v / 10;
        n = n + 1;
    }
    for i32 i = n - 1; i >= 0; i-- { write(stdout(), &buf[i], 1); }
    return;
}

void step(str msg) {
    out(":: ");
    outln(msg);
    return;
}

void pass(str msg) {
    g_pass = g_pass + 1;
    out("  PASS  ");
    outln(msg);
    return;
}

// Two parts rather than one joined string: every call site would
// otherwise allocate a message it then has to free.
void fail(str name, str detail) {
    g_fail = g_fail + 1;
    out("  FAIL  ");
    out(name);
    outln(detail);
    return;
}

void die(str msg) {
    write(stderr(), msg.data, msg.len);
    write(stderr(), "\n", 1);
    exit(1);
    return;
}

// --- toolchain -------------------------------------------------------

// MINC, then a local ./minc deploy, then the minc on PATH. An install
// is one folder with the binary at its root and lib/ beside it.
string find_minc_dir() {
    string env = env_get("MINC");
    if env.len > 0 { return env; }
    free(env);

    string binname = str_concat("minc", EXE_SUFFIX);
    defer free(binname);
    string local = path_join("minc", str_from(binname.data, binname.len));
    defer free(local);
    if path_exists(str_from(local.data, local.len)) { return str_concat("minc", ""); }

    string onpath = path_which("minc");
    defer free(onpath);
    if onpath.len > 0 {
        return str_concat(path_dirname(str_from(onpath.data, onpath.len)), "");
    }

    string none = { .data = null, .len = 0 };
    return none;
}

void assert_toolchain() {
    g_minc_dir = find_minc_dir();
    if g_minc_dir.len == 0 {
        fail("minc not found", "");
        die("  put the minc install dir on PATH, or set MINC to it (see README.md)");
    }
    str dir = str_from(g_minc_dir.data, g_minc_dir.len);
    if !path_is_dir(dir) {
        fail("no such minc install dir", "");
        die("  MINC names the folder holding the minc binary and lib/");
    }
    string binname = str_concat("minc", EXE_SUFFIX);
    defer free(binname);
    g_minc = path_join(dir, str_from(binname.data, binname.len));
    if !path_exists(str_from(g_minc.data, g_minc.len)) {
        fail("no minc binary in the install dir", "");
        die("  MINC names the folder holding the minc binary and lib/");
    }
    string libprobe = path_join(dir, "lib/str.mc");
    defer free(libprobe);
    if !path_exists(str_from(libprobe.data, libprobe.len)) {
        fail("no lib/ in the minc install dir — bare imports (import str;) cannot resolve", "");
        die("  a minc install has lib/ beside the binary");
    }
    return;
}

str cc() {
    return str_from(g_minc.data, g_minc.len);
}

// --- helpers ----------------------------------------------------------

// stdout with \r stripped and trailing blank space removed, so a
// Windows child compares equal to a LF golden file.
string normalize(str s) {
    u8* buf = alloc<u8>(cast(i64, s.len + 1));
    i32 n = 0;
    for i32 i = 0; i < s.len; i++ {
        u8 c = *(s.data + i);
        if c != 13 {
            *(buf + n) = c;
            n = n + 1;
        }
    }
    while n > 0 && (*(buf + n - 1) == 10 || *(buf + n - 1) == 32) { n = n - 1; }
    *(buf + n) = 0;
    string r = { .data = buf, .len = n };
    return r;
}

bool same_text(str a, str b) {
    string na = normalize(a);
    defer free(na);
    string nb = normalize(b);
    defer free(nb);
    return str_equal(str_from(na.data, na.len), str_from(nb.data, nb.len));
}

// Compile one .mc into `exe`. Returns the compiler's exit code.
i32 compile(str src, str exe, str define) {
    ProcCmd c = { .args = { cc(), src }, .capture = true };
    if define.len > 0 { proc_arg(&c, define); }
    proc_arg(&c, "-o");
    proc_arg(&c, exe);
    ProcResult r = proc_run(&c);
    i32 rc = r.exit_code;
    if rc != 0 { out(str_from(r.out.data, r.out.len)); }
    proc_result_free(&r);
    return rc;
}

// "<dir>/<name><ext>", without leaking the joined name.
string join_named(str dir, str name, str ext) {
    string base = str_concat(name, ext);
    defer free(base);
    return path_join(dir, str_from(base.data, base.len));
}

string out_exe() {
    return join_named("build", "tsmc", EXE_SUFFIX);
}

// --- build ------------------------------------------------------------

void build_tsmc() {
    step("build tsmc");
    assert_toolchain();
    ignore dir_create("build");
    string exe = out_exe();
    defer free(exe);
    if compile("src/main.mc", str_from(exe.data, exe.len), "") != 0 {
        outln("compile failed");
        exit(1);
    }
    pass(str_from(exe.data, exe.len));
    return;
}

// A separate binary: plugins bind the embeddable compiler at load
// time, so this one needs the library beside it to start at all. The
// default build stays a single file with nothing to find.
void build_plugins() {
    step("build tsmc with plugin support");
    assert_toolchain();
    ignore dir_create("build");
    string exe = join_named("build", "tsmc-plugins", EXE_SUFFIX);
    defer free(exe);
    if compile("src/main.mc", str_from(exe.data, exe.len), "-DTSMC_PLUGINS") != 0 {
        outln("compile failed");
        exit(1);
    }
    str dir = str_from(g_minc_dir.data, g_minc_dir.len);
    i32 copied = 0;
    str[3] libs = { "libminc.dll", "libminc.so", "libminc.dylib" };
    for i32 i = 0; i < 3; i++ {
        string src = path_join(dir, libs[i]);
        defer free(src);
        str srcp = str_from(src.data, src.len);
        if path_exists(srcp) {
            FileData d = file_read(srcp);
            if d.len > 0 {
                string dst = path_join("build", libs[i]);
                defer free(dst);
                ignore file_write(str_from(dst.data, dst.len), d);
                copied = copied + 1;
            }
            free(cast(void*, d.data));
        }
    }
    if copied == 0 {
        outln("no libminc in the minc install dir — a plugin build cannot start without it");
        exit(1);
    }
    pass(str_from(exe.data, exe.len));
    return;
}

// --- tests ------------------------------------------------------------

// Each test/unit/*.mc is a standalone program; exit 0 means pass.
void run_unit_tests() {
    step("unit tests");
    ignore dir_create("build/unit");
    DirList tests = dir_list_ext("test/unit", ".mc");
    for i32 i = 0; i < tests.count; i++ {
        str name = tests.items[i];
        string src = path_join("test/unit", name);
        defer free(src);
        str stem = path_stem(name);
        string exe = join_named("build/unit", stem, EXE_SUFFIX);
        defer free(exe);
        if compile(str_from(src.data, src.len), str_from(exe.data, exe.len), "") != 0 {
            fail(stem, " (compile)");
        } else {
            // Capture: check.mc is silent on success and several tests
            // exercise error paths that print to stderr. Show it only
            // when the test actually fails, so a passing run stays clean.
            ProcCmd c = { .args = { str_from(exe.data, exe.len) }, .capture = true };
            ProcResult r = proc_run(&c);
            if r.exit_code != 0 {
                fail(stem, " (nonzero exit)");
                out("      ");
                outln(str_from(r.out.data, r.out.len));
            } else {
                pass(stem);
            }
            proc_result_free(&r);
        }
    }
    dir_list_free(&tests);
    return;
}

// Flag handling and exit codes.
void run_cli_smoke(str exe) {
    step("cli smoke");

    ProcCmd v = { .args = { exe, "--version" }, .capture = true };
    ProcResult rv = proc_run(&v);
    if rv.exit_code == 0 && same_text(str_from(rv.out.data, rv.out.len), VERSION_LINE) {
        pass("--version");
    } else {
        fail("--version", "");
    }
    proc_result_free(&rv);

    ProcCmd n = { .args = { exe }, .capture = true };
    ProcResult rn = proc_run(&n);
    if rn.exit_code == 2 { pass("no args exits 2"); } else { fail("no args", ""); }
    proc_result_free(&rn);

    ProcCmd m = { .args = { exe, "build/no_such_file.ts" }, .capture = true };
    ProcResult rm = proc_run(&m);
    if rm.exit_code == 2 { pass("missing file exits 2"); } else { fail("missing file", ""); }
    proc_result_free(&rm);

    // What a script leaves with: process.exitCode, exit(), and whether
    // an uncaught error or rejection was taken by a listener. These
    // cannot live in test/diff, where every script has to end with 0.
    str[7] modes = { "property", "explicit", "exit-no-arg", "listener",
                     "caught", "uncaught", "rejection-caught" };
    i32[7] want = { 7, 3, 5, 4, 0, 1, 0 };
    i32 bad = 0;
    for i32 i = 0; i < 7; i++ {
        ProcCmd c = { .args = { exe, "test/cli/exitcode.js", modes[i] }, .capture = true };
        ProcResult r = proc_run(&c);
        if r.exit_code != want[i] {
            out("  FAIL  exit code '");
            out(modes[i]);
            out("' (want ");
            out_int(cast(i64, want[i]));
            out(", got ");
            out_int(cast(i64, r.exit_code));
            outln(")");
            bad = bad + 1;
        }
        proc_result_free(&r);
    }
    if bad == 0 { pass("exit codes"); } else { g_fail = g_fail + bad; }
    return;
}

// Run test/run/<name>.ts, diff stdout against <name>.expected.
void run_golden_tests(str exe, DirList* scripts) {
    step("run tests");
    if scripts.count == 0 {
        outln("  (none yet)");
        return;
    }
    for i32 i = 0; i < scripts.count; i++ {
        str name = scripts.items[i];
        str stem = path_stem(name);
        string src = path_join("test/run", name);
        defer free(src);
        string expected_path = path_with_ext(str_from(src.data, src.len), ".expected");
        defer free(expected_path);
        if !path_exists(str_from(expected_path.data, expected_path.len)) {
            fail(stem, " (no .expected)");
        } else {
            ProcCmd c = {
                .args = { exe, str_from(src.data, src.len) },
                .capture = true,
                .split_stderr = true
            };
            ProcResult r = proc_run(&c);
            string want = file_read_str(str_from(expected_path.data, expected_path.len));
            defer free(want);
            if r.exit_code != 0 {
                fail(stem, " (nonzero exit)");
            } else if !same_text(str_from(r.out.data, r.out.len), str_from(want.data, want.len)) {
                fail(stem, " (diff)");
            } else {
                pass(stem);
            }
            proc_result_free(&r);
        }
    }
    return;
}

// Re-run every golden and differential script with collect-on-every-
// allocation, catching use-after-free / missing roots. Only a clean
// exit is asserted, not output — slow but thorough. A script that
// never finishes is reported by name rather than left to hold the
// suite open; GC_STRESS_TIMEOUT overrides the limit (seconds).
void run_gc_stress(str exe, DirList* run_scripts, DirList* diff_scripts) {
    step("gc stress");
    i32 limit = 60;
    string env = env_get("GC_STRESS_TIMEOUT");
    defer free(env);
    if env.len > 0 {
        i32 v = 0;
        bool okv = true;
        for i32 i = 0; i < env.len; i++ {
            u8 ch = *(env.data + i);
            if ch < 48 || ch > 57 { okv = false; }
            else { v = v * 10 + cast(i32, ch) - 48; }
        }
        if okv && v > 0 { limit = v; }
    }

    i32 total = run_scripts.count + diff_scripts.count;
    if total == 0 {
        outln("  (none)");
        return;
    }
    i32 bad = 0;
    for i32 pass_i = 0; pass_i < 2; pass_i++ {
        DirList* list = run_scripts;
        str dir = "test/run";
        if pass_i == 1 {
            list = diff_scripts;
            dir = "test/diff";
        }
        for i32 i = 0; i < list.count; i++ {
            str name = list.items[i];
            string src = path_join(dir, name);
            defer free(src);
            ProcCmd c = {
                .args = { exe, "--gc-stress", str_from(src.data, src.len) },
                .capture = true,
                .timeout_ms = limit * 1000
            };
            ProcResult r = proc_run(&c);
            if r.timed_out {
                fail(path_stem(name), " (--gc-stress did not finish)");
                bad = bad + 1;
            } else if r.exit_code != 0 {
                fail(path_stem(name), " (--gc-stress nonzero exit)");
                bad = bad + 1;
            }
            proc_result_free(&r);
        }
    }
    if bad == 0 {
        out("  PASS  ");
        out_int(cast(i64, total));
        outln(" scripts clean under --gc-stress");
        g_pass = g_pass + 1;
    }
    return;
}

// test/diff holds both .js and .mjs.
DirList list_diff_scripts() {
    // The two extensions are disjoint, so the lists concatenate.
    DirList js = dir_list_ext("test/diff", ".js");
    DirList mjs = dir_list_ext("test/diff", ".mjs");
    DirList all = { .count = js.count + mjs.count };
    all.items = alloc<str>(all.count + 1);
    for i32 i = 0; i < js.count; i++ { all.items[i] = js.items[i]; }
    for i32 i = 0; i < mjs.count; i++ { all.items[js.count + i] = mjs.items[i]; }
    // Names moved into `all`; drop the shells without freeing the names.
    free(cast(void*, js.items));
    free(cast(void*, mjs.items));
    return all;
}

i32 run_tests() {
    build_tsmc();
    string exe = out_exe();
    str e = str_from(exe.data, exe.len);

    run_unit_tests();
    run_cli_smoke(e);

    DirList run_scripts = dir_list_ext("test/run", ".ts");
    DirList diff_scripts = list_diff_scripts();

    run_golden_tests(e, &run_scripts);
    run_gc_stress(e, &run_scripts, &diff_scripts);

    dir_list_free(&run_scripts);
    dir_list_free(&diff_scripts);
    free(exe);

    outln("");
    if g_fail == 0 {
        out("  PASS  all ");
        out_int(cast(i64, g_pass));
        outln(" checks passed");
        return 0;
    }
    out("  FAIL  ");
    out_int(cast(i64, g_fail));
    outln(" check(s) failed");
    return 1;
}

// --- bench ------------------------------------------------------------

i32 run_bench() {
    build_tsmc();
    step("benchmarks");
    string exe = out_exe();
    DirList benches = dir_list_ext("bench", ".ts");
    if benches.count == 0 {
        outln("  (none)");
        dir_list_free(&benches);
        free(exe);
        return 0;
    }
    i64 freq = qpf();
    for i32 i = 0; i < benches.count; i++ {
        string src = path_join("bench", benches.items[i]);
        ProcCmd c = {
            .args = { str_from(exe.data, exe.len), str_from(src.data, src.len) },
            .capture = true
        };
        i64 t0 = qpc();
        ProcResult r = proc_run(&c);
        i64 ms = (qpc() - t0) * 1000 / freq;
        out("  ");
        out_int(ms);
        out(" ms  ");
        out(path_stem(benches.items[i]));
        out("  -> ");
        string clean = normalize(str_from(r.out.data, r.out.len));
        outln(str_from(clean.data, clean.len));
        free(clean);
        proc_result_free(&r);
        free(src);
    }
    dir_list_free(&benches);
    free(exe);
    return 0;
}

// --- differential vs node ---------------------------------------------

i32 run_diff() {
    build_tsmc();
    step("differential (vs node)");
    string node = env_get("NODE");
    if node.len == 0 {
        free(node);
        node = path_which("node");
    }
    if node.len == 0 {
        outln("  skipped - node not found (set NODE)");
        free(node);
        return 0;
    }
    string exe = out_exe();
    DirList scripts = list_diff_scripts();
    i32 bad = 0;
    for i32 i = 0; i < scripts.count; i++ {
        string src = path_join("test/diff", scripts.items[i]);
        str s = str_from(src.data, src.len);

        ProcCmd rc = { .args = { str_from(node.data, node.len), s }, .capture = true };
        ProcResult ref = proc_run(&rc);

        ProcCmd gc = { .args = { str_from(exe.data, exe.len), s }, .capture = true };
        ProcResult got = proc_run(&gc);

        if same_text(str_from(ref.out.data, ref.out.len), str_from(got.out.data, got.out.len)) {
            pass(path_stem(scripts.items[i]));
        } else {
            fail(path_stem(scripts.items[i]), " (differs from node)");
            bad = bad + 1;
        }
        proc_result_free(&ref);
        proc_result_free(&got);
        free(src);
    }
    if scripts.count == 0 { outln("  (none)"); }
    dir_list_free(&scripts);
    free(exe);
    free(node);
    if bad > 0 { return 1; }
    return 0;
}

// --- test262 -----------------------------------------------------------

// The runner is one portable bash script (dir-walk + process spawn).
// On Windows use Git Bash, derived from git's own location so the WSL
// 'bash' launcher in System32 is not picked up.
string find_bash() {
    when os(windows) {
        string git = path_which("git");
        if git.len > 0 {
            str gitdir = path_dirname(str_from(git.data, git.len));
            str root = path_dirname(gitdir);
            free(git);
            str[2] cand = { "bin/bash.exe", "usr/bin/bash.exe" };
            for i32 i = 0; i < 2; i++ {
                string p = path_join(root, cand[i]);
                if path_exists(str_from(p.data, p.len)) { return p; }
                free(p);
            }
        } else {
            free(git);
        }
        string none = { .data = null, .len = 0 };
        return none;
    }
    when os(linux) || os(macos) {
        return path_which("bash");
    }
}

i32 run_t262(i32 argc, i32 first_extra) {
    build_tsmc();
    string bash = find_bash();
    if bash.len == 0 {
        outln("bash not found (install Git for Windows) — needed for the test262 runner");
        exit(1);
    }
    ProcCmd c = { .args = { str_from(bash.data, bash.len), "tools/test262.sh" } };
    for i32 i = first_extra; i < argc; i++ { proc_arg_cstr(&c, get_arg(i)); }
    ProcResult r = proc_run(&c);
    i32 rc = r.exit_code;
    proc_result_free(&r);
    free(bash);
    return rc;
}

// --- entry -------------------------------------------------------------

void usage() {
    outln("usage: minc <build|test|bench|clean>");
    outln("  or:  build/build.exe <plugins|diff|t262>   (no minc verb for these)");
    outln("  build   compile build/tsmc");
    outln("  plugins compile build/tsmc-plugins (loads minc plugins)");
    outln("  test    build, then run unit + cli + golden run tests");
    outln("  bench   build, then time bench/*.ts");
    outln("  diff    build, then diff test/diff/*.js vs node");
    outln("  t262    build, then run test262 (fetched to vendor/ on first use)");
    outln("  clean   remove build/");
    return;
}

i32 main() {
    i32 argc = get_argc();
    str verb = "help";
    if argc > 1 { verb = str_from_cstr(get_arg(1)); }

    if str_equal(verb, "clean") {
        step("clean");
        ignore dir_remove("build");
        pass("removed build/");
        return 0;
    }
    if str_equal(verb, "build") {
        build_tsmc();
        return 0;
    }
    if str_equal(verb, "plugins") {
        build_plugins();
        return 0;
    }
    if str_equal(verb, "test") { return run_tests(); }
    if str_equal(verb, "bench") { return run_bench(); }
    if str_equal(verb, "diff") { return run_diff(); }
    if str_equal(verb, "t262") { return run_t262(argc, 2); }

    usage();
    return 0;
}

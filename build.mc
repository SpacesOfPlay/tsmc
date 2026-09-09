// build.mc — build and test tsmc.
//
// Usage, from this folder:
//   minc build      compile build/tsmc
//   minc test       build, then unit + cli + golden + gc-stress
//   minc bench      build, then time bench/*.ts
//   minc wasm       build tsmc.wasm and the page into build/web, serve it
//   minc clean      remove build/
//
// plugins, diff, t262 and release have no minc verb. Compile this script
// once and call it directly:
//   minc build.mc -o build/build.exe
//   build/build.exe plugins
//   build/build.exe release   the downloadable archives, all platforms
//
// Requires the minc compiler: its install dir on PATH, or MINC naming
// that dir (the folder holding the binary and its lib/). A deploy at
// ./minc is preferred over PATH when present, which is how this repo
// is developed; nothing needs it to be there.

import process;
import file;
import str;
import sha256;
import zip;
import "src/version.mc";

when os(windows) { str EXE_SUFFIX = ".exe"; }
when os(linux) || os(macos) { str EXE_SUFFIX = ""; }

// What `tsmc --version` prints. Owned: free it.
string version_line() {
    return format("tsmc {}", TSMC_VERSION);
}

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
    if env.len > 0 {
        // the folder, or the binary inside it
        if path_is_dir(str_from(env.data, env.len)) { return env; }
        string dir = str_concat(path_dirname(str_from(env.data, env.len)), "");
        free(env);
        return dir;
    }
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
// Cross-compile for one target; an empty target means the host default.
// Release binaries are built with the same flags as every other build,
// bounds checks included.
i32 compile_for(str src, str dst, str target) {
    ProcCmd c = { .args = { cc(), src }, .capture = true };
    if target.len > 0 {
        proc_arg(&c, "--target");
        proc_arg(&c, target);
    }
    proc_arg(&c, "-o");
    proc_arg(&c, dst);
    ProcResult r = proc_run(&c);
    i32 rc = r.exit_code;
    if rc != 0 { out(str_from(r.out.data, r.out.len)); }
    proc_result_free(&r);
    return rc;
}

// Whether `exe` reports the version this tree says it has. A mismatch
// means a stale binary, or a build that did not pick up version.mc.
bool check_version(str exe) {
    ProcCmd c = { .args = { exe, "--version" }, .capture = true };
    ProcResult r = proc_run(&c);
    string want = version_line();
    bool ok = r.exit_code == 0
        && same_text(str_from(r.out.data, r.out.len), str_from(want.data, want.len));
    free(want);
    proc_result_free(&r);
    return ok;
}

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

// NODE names the binary; otherwise the first node on PATH. A candidate
// that does not answer --version counts as absent.
string find_node() {
    string node = env_get("NODE");
    if node.len == 0 {
        free(node);
        // by full name on Windows, so a directory called node on PATH is
        // not taken for the binary
        when os(windows) { node = path_which("node.exe"); }
        else { node = path_which("node"); }
    }
    if node.len == 0 { return node; }
    ProcCmd v = { .args = { str_from(node.data, node.len), "--version" }, .capture = true };
    ProcResult r = proc_run(&v);
    bool ok = r.spawned && r.exit_code == 0;
    proc_result_free(&r);
    if ok { return node; }
    free(node);
    return string("");
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

// --- wasm -------------------------------------------------------------

string out_wasm() {
    return path_join("build", "tsmc.wasm");
}

i32 compile_wasm(str src, str dst) {
    return compile_for(src, dst, "wasm");
}

void build_wasm() {
    step("build tsmc.wasm");
    assert_toolchain();
    ignore dir_create("build");
    string wasm = out_wasm();
    defer free(wasm);
    if compile_wasm("src/main.mc", str_from(wasm.data, wasm.len)) != 0 {
        outln("compile failed");
        exit(1);
    }
    pass(str_from(wasm.data, wasm.len));
    return;
}

void copy_or_die(str src, str dst) {
    if file_copy(src, dst) { return; }
    out("  copy failed: ");
    outln(src);
    exit(1);
}

// build/web: the page from web/ with the module beside it, ready to
// serve locally or to publish as a static site.
void assemble_web() {
    step("assemble build/web");
    ignore dir_create("build/web");
    DirList files = dir_list_ext("web", "");
    for i32 i = 0; i < files.count; i++ {
        string src = path_join("web", files.items[i]);
        string dst = path_join("build/web", files.items[i]);
        copy_or_die(str_from(src.data, src.len), str_from(dst.data, dst.len));
        free(src);
        free(dst);
    }
    dir_list_free(&files);
    string wasm = out_wasm();
    copy_or_die(str_from(wasm.data, wasm.len), "build/web/tsmc.wasm");
    free(wasm);
    pass("build/web");
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

// --- release ----------------------------------------------------------

// One archive per platform: the binary under a plain name, the licence,
// the third-party notices and a short readme, in a directory named after
// the archive. Every target is cross-compiled, so whichever machine runs
// this produces the whole set, and the one built for this host is run to
// confirm it reports the version the tree claims.
//
// macOS on Intel is not here: the compiler's macOS target is ARM64. A zip
// carries no Unix permission bit, so the readme says to set it.

str REL_DIR = "build/release";
str STAGE_DIR = "build/stage";
str SUMS_NAME = "SHA256SUMS";
const i32 SUMS_CAP = 4096;

// The platform name for this host, or empty when the host is not one of
// the platforms below.
private str host_platform() {
    str s = "";
    when os(windows) { s = "windows-x64"; }
    when os(macos) { s = "macos-arm64"; }
    when os(linux) && arch(x64) { s = "linux-x64"; }
    when os(linux) && arch(arm64) { s = "linux-arm64"; }
    return s;
}

// Appends `s` at `n` and returns the new length, stopping at `cap` so an
// overflow shows up as a length the caller can refuse.
private i32 buf_add(u8* buf, i32 n, i32 cap, str s) {
    for i32 i = 0; i < s.len; i++ {
        if n >= cap { return cap; }
        *(buf + n) = *(s.data + i);
        n++;
    }
    return n;
}

// 64 lowercase hex digits for a 32-byte digest. Owned: free it.
private string hex_digest(u8* digest) {
    u8[64] text;
    str digits = "0123456789abcdef";
    for i32 i = 0; i < 32; i++ {
        i32 v = cast(i32, *(digest + i));
        text[i * 2] = *(digits.data + (v >> 4));
        text[i * 2 + 1] = *(digits.data + (v & 15));
    }
    return str_concat(str_from(&text[0], 64), "");
}

// Adds `path` to the archive as "<dir>/<name>".
private void zip_put(ZipWriter* z, str dir, str name, str path) {
    string entry = format("{}/{}", dir, name);
    ignore zip_add_file(z, str_from(entry.data, entry.len), path, true);
    free(entry);
}

// Writes the archive as REL_DIR/<base>.zip, hashes it into `sums` and
// reports it. Returns the new sums length, or -1 if anything failed.
private i32 close_archive(ZipWriter* z, str base, u8* sums, i32 sn) {
    string arc = format("{}.zip", base);
    str av = str_from(arc.data, arc.len);
    string path = path_join(REL_DIR, av);
    str pv = str_from(path.data, path.len);
    i32 out = -1;
    bool written = zip_end(z, pv);
    if !written {
        fail(av, " (archive failed)");
    } else {
        FileData d = file_read(pv);
        if d.data == null {
            fail(av, " (cannot read back)");
        } else {
            u8[32] digest;
            sha256_oneshot(d.data, cast(u64, d.len), &digest[0]);
            string hex = hex_digest(&digest[0]);
            i32 n = buf_add(sums, sn, SUMS_CAP, str_from(hex.data, hex.len));
            n = buf_add(sums, n, SUMS_CAP, "  ");
            n = buf_add(sums, n, SUMS_CAP, av);
            n = buf_add(sums, n, SUMS_CAP, "\n");
            free(hex);
            string shown = format("{}  {} KB", av, d.len / 1024);
            pass(str_from(shown.data, shown.len));
            free(shown);
            free(d.data);
            out = n;
        }
    }
    free(path);
    free(arc);
    return out;
}

i32 run_release() {
    step("release");
    assert_toolchain();
    ignore dir_create("build");
    // start empty, so the directories hold this version and nothing else
    ignore dir_remove(REL_DIR);
    ignore dir_remove(STAGE_DIR);
    ignore dir_create(REL_DIR);
    ignore dir_create(STAGE_DIR);

    // one row per platform: the compiler target, the name in the archive
    // name, and what the binary is called inside it
    str[4] targets = { "windows", "linux", "linux-arm64", "macos" };
    str[4] platforms = { "windows-x64", "linux-x64", "linux-arm64", "macos-arm64" };
    str[4] binaries = { "tsmc.exe", "tsmc", "tsmc", "tsmc" };

    u8[SUMS_CAP] sums;
    i32 sn = 0;
    i32 bad = 0;

    for i32 i = 0; i < 4; i++ {
        string base = format("tsmc-{}-{}", TSMC_VERSION, platforms[i]);
        str bv = str_from(base.data, base.len);
        string staged = path_join(STAGE_DIR, binaries[i]);
        str sv = str_from(staged.data, staged.len);

        if compile_for("src/main.mc", sv, targets[i]) != 0 {
            fail(bv, " (cross-compile failed)");
            bad++;
            free(staged);
            free(base);
            continue;
        }
        // the binary built for this host has to answer with this version
        if str_equal(platforms[i], host_platform()) && !check_version(sv) {
            fail(bv, " (does not report this version)");
            bad++;
        }

        ZipWriter z;
        zip_put(&z, bv, binaries[i], sv);
        zip_put(&z, bv, "README.md", "dist/README.md");
        zip_put(&z, bv, "LICENSE.md", "LICENSE.md");
        zip_put(&z, bv, "NOTICE.md", "NOTICE.md");
        i32 n = close_archive(&z, bv, &sums[0], sn);
        if n < 0 { bad++; } else { sn = n; }

        ignore file_remove(sv);
        free(staged);
        free(base);
    }

    // The wasm module is not an executable: it ships with the host that
    // gives it a file view, a clock, output and randomness, and with the
    // node runner the test suite uses. wasm_run.js reads the host from
    // web/ beside it, so both keep their paths.
    string wbase = format("tsmc-{}-wasm", TSMC_VERSION);
    str wv = str_from(wbase.data, wbase.len);
    string wstage = path_join(STAGE_DIR, "tsmc.wasm");
    str wsv = str_from(wstage.data, wstage.len);
    if compile_for("src/main.mc", wsv, "wasm") != 0 {
        fail(wv, " (cross-compile failed)");
        bad++;
    } else {
        ZipWriter z;
        zip_put(&z, wv, "tsmc.wasm", wsv);
        zip_put(&z, wv, "tools/wasm_run.js", "tools/wasm_run.js");
        zip_put(&z, wv, "web/tsmc_host.js", "web/tsmc_host.js");
        zip_put(&z, wv, "web/cdn_fs.js", "web/cdn_fs.js");
        zip_put(&z, wv, "README.md", "dist/README.md");
        zip_put(&z, wv, "LICENSE.md", "LICENSE.md");
        zip_put(&z, wv, "NOTICE.md", "NOTICE.md");
        i32 n = close_archive(&z, wv, &sums[0], sn);
        if n < 0 { bad++; } else { sn = n; }
        ignore file_remove(wsv);
    }
    free(wstage);
    free(wbase);
    ignore dir_remove(STAGE_DIR);

    string sums_path = path_join(REL_DIR, SUMS_NAME);
    if sn >= SUMS_CAP {
        fail(SUMS_NAME, " (too long for its buffer)");
        bad++;
    } else if !file_write_str(str_from(sums_path.data, sums_path.len), str_from(&sums[0], sn)) {
        fail(SUMS_NAME, " (write failed)");
        bad++;
    } else {
        pass(SUMS_NAME);
    }
    free(sums_path);

    if bad != 0 {
        outln("release failed");
        return 1;
    }
    out("  ready in ");
    outln(REL_DIR);
    return 0;
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

    if check_version(exe) { pass("--version"); } else { fail("--version", ""); }

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
// Runs c and compares its stdout with the .expected file beside src.
void golden_check(str stem, str src, ProcCmd* c) {
    string expected_path = path_with_ext(src, ".expected");
    defer free(expected_path);
    if !path_exists(str_from(expected_path.data, expected_path.len)) {
        fail(stem, " (no .expected)");
        return;
    }
    ProcResult r = proc_run(c);
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
    return;
}

// True when `needle` occurs in `hay`.
private bool text_contains(str hay, str needle) {
    if needle.len == 0 { return true; }
    for i32 i = 0; i + needle.len <= hay.len; i++ {
        bool same = true;
        for i32 j = 0; j < needle.len; j++ {
            if *(hay.data + i + j) != *(needle.data + j) { same = false; break; }
        }
        if same { return true; }
    }
    return false;
}

// The fragment after "// expect:" on a test's first line, else empty.
private str neg_expectation(str text) {
    str none = str_from(text.data, 0);
    str tag = "// expect:";
    if text.len < tag.len { return none; }
    for i32 j = 0; j < tag.len; j++ {
        if *(text.data + j) != *(tag.data + j) { return none; }
    }
    i32 s = tag.len;
    while s < text.len && *(text.data + s) == ' ' { s++; }
    i32 e = s;
    while e < text.len && *(text.data + e) != '\n' && *(text.data + e) != '\r' { e++; }
    return str_from(text.data + s, e - s);
}

// Each test/neg/*.js is a program the compiler must refuse: exit code 2,
// and the message named on its first line, `// expect: <fragment>`.
void run_neg_tests(str exe) {
    step("negative tests");
    DirList tests = dir_list_ext("test/neg", ".js");
    if tests.count == 0 { outln("  (none)"); }
    for i32 i = 0; i < tests.count; i++ {
        str name = tests.items[i];
        str stem = path_stem(name);
        string src = path_join("test/neg", name);
        defer free(src);
        string text = file_read_str(str_from(src.data, src.len));
        defer free(text);
        str want = neg_expectation(str_from(text.data, text.len));
        ProcCmd c = { .args = { exe, str_from(src.data, src.len) }, .capture = true };
        ProcResult r = proc_run(&c);
        if r.exit_code != 2 {
            fail(stem, " (compiled, or failed at run time)");
        } else if !text_contains(str_from(r.out.data, r.out.len), want) {
            fail(stem, " (message)");
            out("      ");
            outln(str_from(r.out.data, r.out.len));
        } else {
            pass(stem);
        }
        proc_result_free(&r);
    }
    dir_list_free(&tests);
    return;
}

void run_golden_tests(str exe, DirList* scripts) {
    step("run tests");
    if scripts.count == 0 {
        outln("  (none yet)");
        return;
    }
    for i32 i = 0; i < scripts.count; i++ {
        str name = scripts.items[i];
        string src = path_join("test/run", name);
        defer free(src);
        ProcCmd c = {
            .args = { exe, str_from(src.data, src.len) },
            .capture = true,
            .split_stderr = true
        };
        golden_check(path_stem(name), str_from(src.data, src.len), &c);
    }
    return;
}

// Two golden tests need what the sandbox does not have: an environment
// (process) and a socket (tls_plaintext_reply).
private bool wasm_skips(str stem) {
    return str_equal(stem, "process") || str_equal(stem, "tls_plaintext_reply");
}

// The module is cross-compiled on every test run, so it cannot rot
// unnoticed. With node present the golden tests run through it too.
void run_wasm_tests(DirList* scripts) {
    build_wasm();
    step("wasm run tests (node)");
    string node = find_node();
    defer free(node);
    if node.len == 0 {
        outln("  skipped - node not found (set NODE)");
        return;
    }
    string wasm = out_wasm();
    defer free(wasm);
    for i32 i = 0; i < scripts.count; i++ {
        str name = scripts.items[i];
        str stem = path_stem(name);
        if wasm_skips(stem) { continue; }
        // "/" throughout: the path is a name inside the sandbox
        string src = str_concat("test/run/", name);
        defer free(src);
        ProcCmd c = {
            .args = { str_from(node.data, node.len), "tools/wasm_run.js",
                      str_from(wasm.data, wasm.len), str_from(src.data, src.len) },
            .capture = true,
            .split_stderr = true
        };
        golden_check(stem, str_from(src.data, src.len), &c);
    }
    // the package view, against a registry faked in the script
    ProcCmd c = {
        .args = { str_from(node.data, node.len), "tools/cdn_fs_check.js", str_from(wasm.data, wasm.len) },
        .capture = true
    };
    ProcResult r = proc_run(&c);
    if r.exit_code == 0 {
        pass("cdn_fs");
    } else {
        out(str_from(r.out.data, r.out.len));
        fail("cdn_fs", " (see output)");
    }
    proc_result_free(&r);
    // the page's examples that need no package; the rest run under the
    // examples verb, against the live registry
    ProcCmd ex = {
        .args = { str_from(node.data, node.len), "tools/examples_check.js", str_from(wasm.data, wasm.len) },
        .capture = true
    };
    ProcResult er = proc_run(&ex);
    if er.exit_code == 0 {
        pass("examples");
    } else {
        out(str_from(er.out.data, er.out.len));
        fail("examples", " (see output)");
    }
    proc_result_free(&er);
    return;
}

// Every example in the page through the module, packages fetched from
// the registry as the page fetches them. Needs the network, so it is a
// verb of its own rather than part of the test run.
i32 run_examples() {
    build_wasm();
    step("examples (node, live registry)");
    string node = find_node();
    defer free(node);
    if node.len == 0 {
        outln("  node not found (set NODE)");
        return 1;
    }
    string wasm = out_wasm();
    defer free(wasm);
    ProcCmd c = {
        .args = { str_from(node.data, node.len), "tools/examples_check.js", str_from(wasm.data, wasm.len), "--cdn" },
        .capture = true
    };
    ProcResult r = proc_run(&c);
    out(str_from(r.out.data, r.out.len));
    i32 rc = r.exit_code;
    proc_result_free(&r);
    return rc == 0 ? 0 : 1;
}

// Re-run every golden and differential script with collect-on-every-
// allocation, which also poisons what it sweeps, so a use-after-free or
// a missing root fails at once or corrupts the output; each run's output
// is held against a plain run of the same script. A script that never
// finishes is reported by name rather than left to hold the suite open;
// GC_STRESS_TIMEOUT overrides the limit (seconds).
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
            ProcCmd plain = {
                .args = { exe, str_from(src.data, src.len) },
                .capture = true,
                .timeout_ms = limit * 1000
            };
            ProcResult p = proc_run(&plain);
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
            } else if !p.timed_out && !same_text(str_from(p.out.data, p.out.len), str_from(r.out.data, r.out.len)) {
                fail(path_stem(name), " (--gc-stress output differs)");
                bad = bad + 1;
            }
            proc_result_free(&p);
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
    run_neg_tests(e);
    run_wasm_tests(&run_scripts);
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
    string node = find_node();
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

// minc wasm: the module and the page into build/web, then served by the
// native binary. --no-serve stops after assembling.
i32 run_wasm(i32 argc, i32 first_extra) {
    build_wasm();
    assemble_web();
    if argc > first_extra && str_equal(str_from_cstr(get_arg(first_extra)), "--no-serve") {
        return 0;
    }
    build_tsmc();
    string exe = out_exe();
    defer free(exe);
    step("serve");
    ProcCmd c = { .args = { str_from(exe.data, exe.len), "tools/serve.ts", "build/web" } };
    ProcResult r = proc_run(&c);
    i32 rc = r.exit_code;
    proc_result_free(&r);
    return rc;
}

void usage() {
    outln("usage: minc <build|test|bench|wasm|clean>");
    outln("  or:  build/build.exe <plugins|diff|examples|t262|release>   (no minc verb)");
    outln("  build   compile build/tsmc");
    outln("  plugins compile build/tsmc-plugins (loads minc plugins)");
    outln("  test    build, then run unit + cli + golden + wasm + gc-stress tests");
    outln("  bench   build, then time bench/*.ts");
    outln("  wasm    build tsmc.wasm and the page into build/web, then serve it");
    outln("          (--no-serve: stop after assembling)");
    outln("  diff    build, then diff test/diff/*.js vs node");
    outln("  examples build tsmc.wasm, then run every playground example through it");
    outln("          (the package ones fetch from the live registry)");
    outln("  t262    build, then run test262 (fetched to vendor/ on first use)");
    outln("  release build/release: a zip per platform holding the binary,");
    outln("          the licence and a readme, with a SHA256SUMS beside them");
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
    if str_equal(verb, "wasm") { return run_wasm(argc, 2); }
    if str_equal(verb, "diff") { return run_diff(); }
    if str_equal(verb, "examples") { return run_examples(); }
    if str_equal(verb, "t262") { return run_t262(argc, 2); }
    if str_equal(verb, "release") { return run_release(); }

    usage();
    return 0;
}

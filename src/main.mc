// main.mc — tsmc CLI entry point.
//
// Exit codes: 0 success, 1 uncaught exception, 2 usage, I/O, or
// compile errors.

import str;
import file;
import vm;
import codecache;
import builtins;
import module;
import prof;
import compiler;
import version;

const i32 EXIT_OK = 0;
const i32 EXIT_USAGE = 2;

private void print_usage() {
    print("usage: tsmc [--gc-stress] [--prof] [--phases] [--lazy] <script.ts>\n");
    print("       tsmc --version\n");
}

// The run itself. Separate from main() because a freestanding embedder
// has to equip the machine -- entropy, directories, whatever else it can
// answer for -- before a script is able to observe it, and that means
// owning the entry point. See src/uefi_host.mc.
i32 tsmc_main() {
    // Optional flags precede the script path.
    bool gc_stress = false;
    str code_cache;
    bool cc_verify = false;
    bool cc_ahead = false;
    bool profile = false;
    bool phases = false;
    i32 i = 1;
    while i < get_argc() {
        str a = str_from_cstr(get_arg(i));
        if str_equal(a, "--version") {
            print("tsmc {}\n", TSMC_VERSION);
            return EXIT_OK;
        }
        if str_equal(a, "--help") || str_equal(a, "-h") {
            print_usage();
            return EXIT_OK;
        }
        // collect-on-every-allocation; a slow but thorough check for
        // use-after-free / missing GC roots.
        if str_equal(a, "--gc-stress") { gc_stress = true; i++; continue; }
        // a sampling profile of the run and its counts, on stderr at exit
        if str_equal(a, "--prof") { profile = true; i++; continue; }
        // where the run's time went, by phase and by native, on stderr at exit
        if str_equal(a, "--phases") { phases = true; i++; continue; }
        // functions in a large source compiled on their first call
        if str_equal(a, "--lazy") { lazy_functions = true; i++; continue; }
        // the script's templates read from the file when it holds them,
        // and written to it after the run
        if str_equal(a, "--code-cache") && i + 1 < get_argc() { code_cache = str_from_cstr(get_arg(i + 1)); i += 2; continue; }
        // every compile written out, read back and run from the reading
        if str_equal(a, "--code-cache-verify") { cc_verify = true; i++; continue; }
        // the script compiled apart from the VM, the way an embedder's
        // thread would, and run from the bytes
        if str_equal(a, "--code-cache-ahead") { cc_ahead = true; i++; continue; }
        break;
    }
    // the first non-flag argument is the script; anything after it is
    // passed through to the program as process.argv user arguments.
    if i >= get_argc() {
        print_usage();
        return EXIT_USAGE;
    }

    str arg = str_from_cstr(get_arg(i));

    FileData src = file_read(arg);
    if src.data == null {
        eprint("tsmc: cannot read '{}'\n", arg);
        return EXIT_USAGE;
    }
    defer free(src.data);

    str source;
    source.data = src.data;
    source.len = cast(i32, src.len);

    VM m;
    vm_init(&m);
    m.heap.stress = gc_stress;
    if profile {
        if !PROF_ON {
            eprint("tsmc: --prof needs a profiling build (build/build.exe build --prof)\n");
            vm_destroy(&m);
            return EXIT_USAGE;
        }
        m.prof = prof_new();
    }
    builtins_install(&m);
    m.cc_verify = cc_verify;
    FileData cached = FileData{};
    if code_cache.len > 0 {
        cached = file_read(code_cache);
        if cached.data != null {
            m.cc_data = cached.data;
            m.cc_len = cast(i32, cached.len);
        }
    }
    // the script compiled ahead, and every lazy function of it, which the
    // run then takes through the hook, as an embedder's thread serves them
    CcOut ahead = CcOut{};
    CliAhead la = CliAhead{};
    if cc_ahead && cached.data == null {
        AheadCompile a;
        if ahead_begin(&a, source, arg, m.script_globals) {
            ahead = ahead_cache(&a);
            m.cc_data = ahead.data;
            m.cc_len = ahead.len;
            vec_init<CliAheadEntry>(&la.entries, 64);
            i32 start = 0;
            CcOut one = CcOut{};
            while ahead_next(&a, &start, &one) { vec_push(&la.entries, CliAheadEntry{ start, one }); }
            la.src_name = module_entry_name(arg);
            la.src_len = source.len;
            ahead_end(&a);
            m.lazy_ahead = &cli_lazy_ahead;
            m.lazy_ahead_ctx = &la;
        }
    }
    if phases { vm_phases_on(&m, 2); }
    vm_phase_begin(&m);
    i32 status = module_run_entry(&m, source, arg);
    vm_phase_end(&m);
    if phases {
        using string rep = vm_phase_report(&m, "tsmc: ", 20);
        eprint("{}", rep);
    }
    if ahead.data != null {
        if m.cache_loads == 0 { eprint("tsmc: the compile ahead was not taken\n"); }
        if la.entries.len > 0 && m.lazy_compiles > 0 { eprint("tsmc: {} lazy functions compiled ahead were not taken\n", m.lazy_compiles); }
        free(ahead.data);
    }
    for i32 k = 0; k < la.entries.len; k++ { free(vec_get(&la.entries, k).bytes.data); }
    if la.entries.data != null { vec_free(&la.entries); }
    if code_cache.len > 0 && m.first_root != null {
        CcOut o = vm_save_templates(&m, m.first_root, source);
        FileData fd = FileData{ .data = o.data, .len = o.len };
        if !file_write(code_cache, fd) { eprint("tsmc: cannot write '{}'\n", code_cache); }
        free(o.data);
    }
    if cached.data != null { free(cached.data); }
    if m.prof != null { prof_report(m.prof, m.heap.n_collections); }
    vm_destroy(&m);
    return status;
}

// Everywhere with an operating system under it, the CLI is the whole
// program. On the freestanding target the embedder writes main(), calls
// tsmc_set_uefi_host() and then tsmc_main().
when !os(uefi) {
    // --code-cache-ahead's lazy functions, compiled before the run and
// served at their calls; in source order, so found by bisection
struct CliAheadEntry {
    i32 start;
    CcOut bytes;
}

struct CliAhead {
    Vec<CliAheadEntry> entries;
    str src_name;
    i32 src_len;
}

private u8* cli_lazy_ahead(void* ctx, str src_name, i32 src_len, i32 start, i32* len_out) {
    CliAhead* la = cast(CliAhead*, ctx);
    if src_len != la.src_len || !str_equal(src_name, la.src_name) { return null; }
    i32 lo = 0;
    i32 hi = la.entries.len;
    while lo < hi {
        i32 mid = (lo + hi) / 2;
        CliAheadEntry* e = &la.entries.data[mid];
        if e.start == start { *len_out = e.bytes.len; return e.bytes.data; }
        if e.start < start { lo = mid + 1; } else { hi = mid; }
    }
    return null;
}

i32 main() { return tsmc_main(); }
}

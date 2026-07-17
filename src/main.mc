// main.mc — tsmc CLI entry point.
//
// Exit codes: 0 success, 1 uncaught exception, 2 usage, I/O, or
// compile errors.

import str;
import file;
import vm;
import builtins;
import module;

const i32 EXIT_OK = 0;
const i32 EXIT_USAGE = 2;

private void print_usage() {
    print("usage: tsmc [--gc-stress] <script.ts>\n");
    print("       tsmc --version\n");
}

i32 main() {
    // Optional flags precede the script path.
    bool gc_stress = false;
    i32 i = 1;
    while i < get_argc() {
        str a = str_from_cstr(get_arg(i));
        if str_equal(a, "--version") {
            print("tsmc 0.1.0-dev\n");
            return EXIT_OK;
        }
        if str_equal(a, "--help") || str_equal(a, "-h") {
            print_usage();
            return EXIT_OK;
        }
        // collect-on-every-allocation; a slow but thorough check for
        // use-after-free / missing GC roots.
        if str_equal(a, "--gc-stress") { gc_stress = true; i++; continue; }
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
    source.len = src.len;

    VM m;
    vm_init(&m);
    m.heap.stress = gc_stress;
    builtins_install(&m);
    i32 status = module_run_entry(&m, source, arg);
    vm_destroy(&m);
    return status;
}

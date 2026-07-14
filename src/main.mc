// main.mc — tsmc CLI entry point.
//
// Exit codes: 0 success, 1 uncaught exception, 2 usage, I/O, or
// compile errors.

import str;
import file;
import vm;

const i32 EXIT_OK = 0;
const i32 EXIT_USAGE = 2;

private void print_usage() {
    print("usage: tsmc <script.ts>\n");
    print("       tsmc --version\n");
}

i32 main() {
    if get_argc() != 2 {
        print_usage();
        return EXIT_USAGE;
    }

    str arg = str_from_cstr(get_arg(1));

    if str_equal(arg, "--version") {
        print("tsmc 0.1.0-dev\n");
        return EXIT_OK;
    }
    if str_equal(arg, "--help") || str_equal(arg, "-h") {
        print_usage();
        return EXIT_OK;
    }

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
    i32 status = vm_run_source(&m, source, arg);
    vm_destroy(&m);
    return status;
}

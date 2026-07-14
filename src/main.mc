// main.mc — tsmc CLI entry point.
//
// Exit codes: 0 success, 1 script error, 2 usage or I/O error,
// 3 feature not implemented yet.

import str;
import file;

const i32 EXIT_OK = 0;
const i32 EXIT_SCRIPT_ERROR = 1;
const i32 EXIT_USAGE = 2;
const i32 EXIT_UNIMPLEMENTED = 3;

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

    // Interpreter pipeline lands in later milestones.
    eprint("tsmc: cannot run '{}': interpreter not implemented\n", arg);
    return EXIT_UNIMPLEMENTED;
}

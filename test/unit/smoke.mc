// smoke.mc — proves the unit-test harness compiles, runs, and gates on exit code.

import str;

i32 main() {
    if !str_equal("tsmc", "tsmc") {
        eprint("smoke: str_equal failed\n");
        return 1;
    }
    return 0;
}

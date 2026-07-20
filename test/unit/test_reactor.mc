// test_reactor.mc — the I/O handle table + ref-count that governs when
// the event loop stays alive (M31). Exit 0 = pass.

import str;
import "../helpers/check.mc";
import "../../src/value.mc";
import "../../src/object.mc";
import "../../src/vm.mc";

// A timer callback that closes the handle registered below, so the loop
// has a reason to exit after firing.
i32 g_hidx = -1;

Value close_handle_native(void* vmp, Value callee, Value thisv, Value* args, i32 argc) {
    VM* vm = cast(VM*, vmp);
    vm_handle_close(vm, g_hidx);
    return value_undefined();
}

i32 main() {
    // --- ref-count logic ---
    VM m;
    vm_init(&m);
    check(!vm_handles_alive(&m), "no handles: not alive");
    i32 h = vm_handle_add(&m, -1, 0, value_undefined());
    check(vm_handles_alive(&m), "reffed handle: alive");
    vm_handle_unref(&m, h);
    check(!vm_handles_alive(&m), "unref: not alive");
    vm_handle_ref(&m, h);
    check(vm_handles_alive(&m), "re-ref: alive");
    vm_handle_close(&m, h);
    check(!vm_handles_alive(&m), "closed: not alive");
    // a second live handle keeps the loop alive even after the first closes
    i32 a = vm_handle_add(&m, -1, 0, value_undefined());
    i32 b = vm_handle_add(&m, -1, 0, value_undefined());
    vm_handle_close(&m, a);
    check(vm_handles_alive(&m), "one of two closed: still alive");
    vm_handle_close(&m, b);
    check(!vm_handles_alive(&m), "both closed: not alive");
    vm_destroy(&m);

    // --- loop integration: a live handle keeps the loop running until a
    // timer closes it, then the loop exits (rather than hanging). ---
    VM m2;
    vm_init(&m2);
    g_hidx = vm_handle_add(&m2, -1, 0, value_undefined());
    Value cb = vm_make_native(&m2, &close_handle_native, "closer");
    ignore vm_add_timer(&m2, cb, 0.0);
    i32 st = vm_run_event_loop(&m2);
    check_eq(st, 0, "loop terminates once the handle is closed");
    check(!vm_handles_alive(&m2), "handle closed after loop drains");
    vm_destroy(&m2);

    return check_done("reactor");
}

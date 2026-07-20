// os_time.mc — monotonic clock and a blocking wait.
//
// These sit below the builtins layer so the VM reactor
// (src/vm.mc) can sleep until the next timer is due without depending on
// builtins. `vm_clock_ns` is a monotonic nanosecond counter; `vm_wait_ms`
// blocks the calling thread for the given milliseconds.

when os(windows) {
    private extern "kernel32.dll" i32 QueryPerformanceCounter(i64* p);
    private extern "kernel32.dll" i32 QueryPerformanceFrequency(i64* p);
    private extern "kernel32.dll" void Sleep(u32 ms);

    u64 vm_clock_ns() {
        i64 freq = 0;
        i64 ctr = 0;
        ignore QueryPerformanceFrequency(&freq);
        ignore QueryPerformanceCounter(&ctr);
        if freq == 0 { return 0; }
        u64 uc = cast(u64, ctr);
        u64 uf = cast(u64, freq);
        // split to avoid overflow: ns = secs*1e9 + rem*1e9/freq
        u64 secs = uc / uf;
        u64 rem = uc % uf;
        return secs * 1000000000 + rem * 1000000000 / uf;
    }

    void vm_wait_ms(i64 ms) {
        if ms > 0 { Sleep(cast(u32, ms)); }
    }
}
else when os(wasm) {
    // Sandbox: the monotonic counter is the host clock import (qpf is 1e9
    // there); there is no thread to block, so the wait is a no-op.
    void vm_wait_ms(i64 ms) { }
    u64 vm_clock_ns() { return cast(u64, qpc()); }
}
else when os(macos) || os(ios) || os(linux) || os(android) {
    struct OsTimespec { i64 tv_sec; i64 tv_nsec; }

    when os(macos) || os(ios) {
        private extern "libSystem.B.dylib" i32 clock_gettime(i32 clk, OsTimespec* ts);
        private extern "libSystem.B.dylib" i32 nanosleep(OsTimespec* req, OsTimespec* rem);
        private i32 os_mono_clock() { return 6; }   // CLOCK_MONOTONIC (darwin)
    }
    else when os(android) {
        private extern "libc.so" i32 clock_gettime(i32 clk, OsTimespec* ts);
        private extern "libc.so" i32 nanosleep(OsTimespec* req, OsTimespec* rem);
        private i32 os_mono_clock() { return 1; }   // CLOCK_MONOTONIC (linux)
    }
    else {
        private extern "libc.so.6" i32 clock_gettime(i32 clk, OsTimespec* ts);
        private extern "libc.so.6" i32 nanosleep(OsTimespec* req, OsTimespec* rem);
        private i32 os_mono_clock() { return 1; }   // CLOCK_MONOTONIC (linux)
    }

    u64 vm_clock_ns() {
        OsTimespec ts;
        ts.tv_sec = 0;
        ts.tv_nsec = 0;
        ignore clock_gettime(os_mono_clock(), &ts);
        return cast(u64, ts.tv_sec) * 1000000000 + cast(u64, ts.tv_nsec);
    }

    void vm_wait_ms(i64 ms) {
        if ms <= 0 { return; }
        OsTimespec req;
        req.tv_sec = ms / 1000;
        req.tv_nsec = (ms % 1000) * 1000000;
        ignore nanosleep(&req, null);
    }
}
else {
    // No arm for this target. Add a `when os(...)` arm above rather than
    // silently falling back to another platform's syscalls.
    tsmc_unsupported_target__add_a_when_os_arm _unsupported_time;
}

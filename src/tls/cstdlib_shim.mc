// libc subset: <stdio.h>/<ctype.h>/<math.h>/<string.h>/<stdlib.h>, per OS.
//
// math, ctype, str*/mem*, qsort, rand and the number parsers come from
// the math module, which implements them in minc. Results are identical
// on every target.
//
import math;

// Aligned allocation
void* _picotls_aligned_malloc(u64 size, u64 align) {
    i64 a = cast(i64, align);
    if a < 1 { a = 1; }
    i64 slot = 8;
    u8* base = cast(u8*, alloc(cast(i64, size) + a + slot));
    if base == null { return null; }
    i64 aligned = (cast(i64, base) + slot + (a - 1)) & ~(a - 1);
    void** store = cast(void**, cast(u8*, aligned - slot));
    *store = cast(void*, base);
    return cast(u8*, aligned);
}
void _picotls_aligned_free(void* p) {
    if p == null { return; }
    void** store = cast(void**, cast(u8*, cast(i64, p) - 8));
    free(*store);
}

// POSIX aligned allocation.
i32 _picotls_posix_memalign(void** memptr, i32 alignment, u64 size) {
    *memptr = null;
    if alignment <= 0 || (alignment & (alignment - 1)) != 0 { return 22; }
    void* p = alloc(cast(i64, size));
    if p == null { return 12; }
    if (cast(i64, p) & cast(i64, alignment - 1)) != 0 {
        free(p);
        return 12;
    }
    *memptr = p;
    return 0;
}

when os(windows) {
    extern "msvcrt.dll" {
        // i32 _snprintf(u8* buf, u64 size, u8* fmt, ...);
        i32 sscanf(u8* s, u8* fmt, ...);
        i64 clock();
        i32 puts(u8* s);
    }
    // MSVC FP-usage sentinel.
    i32 _fltused = 0x9875;
    // POSIX errno; a process-wide slot (not thread-local).
    i32 errno = 0;
    // MSVC bit-scan intrinsic over minc's clz builtin. Returns
    // nonzero iff mask != 0.
    u8 _BitScanReverse(u32* index, u32 mask) {
        if mask == 0 { return 0; }
        *index = cast(u32, 31 - clz(cast(i32, mask)));
        return 1;
    }
}
when os(linux) {
    extern "libc.so.6" {
        i32 sscanf(u8* s, u8* fmt, ...);
        i64 clock();
        i32 puts(u8* s);
    }
}
when os(android) {
    // Android Bionic
    extern "libc.so" {
        i32 sscanf(u8* s, u8* fmt, ...);
        i64 clock();
        i32 puts(u8* s);
    }
}
// Numeric constants. Values are stable across platforms.
const i32 MAX_PATH = 260;
const i32 S_IFMT = 0xF000;
const i32 S_IFREG = 0x8000;
const i32 S_IFDIR = 0x4000;
when os(macos) || os(ios) {
    // On macOS, libSystem.B.dylib provides both libc and libm.
    extern "libSystem.B.dylib" {
        i32 sscanf(u8* s, u8* fmt, ...);
        i64 clock();
        i32 puts(u8* s);
    }
}

// <float.h> limits + <stdlib.h> RAND_MAX, as constants.
// rand() comes from the math module and RAND_MAX is 2^31-1.
const i32 RAND_MAX = 0x7FFFFFFF;

const f32 FLT_MAX = 3.40282347e38f;
const f32 FLT_MIN = 1.17549435e-38f;
const f32 FLT_EPSILON = 1.19209290e-7f;
const f64 DBL_MAX = 1.7976931348623157e308;
const f64 DBL_MIN = 2.2250738585072014e-308;
const f64 DBL_EPSILON = 2.2204460492503131e-16;

// <math.h> NAN / INFINITY as f32 constants.
const f32 NAN = 0.0f / 0.0f;
const f32 INFINITY = 1.0f / 0.0f;

// isnan / isinf / isfinite and copysign / ldexp / frexp / hypot come
// from the math module, as f32 and f64 overloads.

// assert(cond): aborts on failure. Param is i64; nonzero = true.
void assert(i64 cond) {
    if cond == 0 {
        eprint("assertion failed\n");
        exit(1);
    }
}

// Count trailing zeros (64-bit). Returns 64 on 0.
i32 __builtin_ctzl(u64 x) {
    if x == 0 { return 64; }
    i32 c = 0;
    while (x & cast(u64, 1)) == 0 {
        x = x >> cast(u64, 1);
        c = c + 1;
    }
    return c;
}

// POSIX <time.h>: timespec + clock_gettime.
struct timespec { i64 tv_sec; i64 tv_nsec; }
when os(windows) {
    i32 clock_gettime(i32 clk_id, timespec* tp) {
        i64 ticks = qpc();
        i64 freq = qpf();
        if freq == 0 { tp.tv_sec = 0; tp.tv_nsec = 0; return 0; }
        tp.tv_sec = ticks / freq;
        tp.tv_nsec = (ticks % freq) * 1000000000 / freq;
        return 0;
    }
} else when os(linux) {
    extern "libc.so.6" i32 clock_gettime(i32 clk_id, void* tp);
} else when os(macos) || os(ios) {
    extern "libSystem.B.dylib" i32 clock_gettime(i32 clk_id, void* tp);
}

// <stdio.h> file I/O. SEEK_* standard ANSI values.
const i32 SEEK_SET = 0;
const i32 SEEK_CUR = 1;
const i32 SEEK_END = 2;
when os(windows) {
    extern "msvcrt.dll" {
        u64 fwrite(void* p, u64 sz, u64 n, void* f);
        i64 time(i64* t);
    }
}
when os(linux) {
    extern "libc.so.6" {
        u64 fwrite(void* p, u64 sz, u64 n, void* f);
        i64 time(i64* t);
    }
}
when os(android) {
    extern "libc.so" {
        u64 fwrite(void* p, u64 sz, u64 n, void* f);
        i64 time(i64* t);
    }
}
when os(macos) || os(ios) {
    extern "libSystem.B.dylib" {
        u64 fwrite(void* p, u64 sz, u64 n, void* f);
        i64 time(i64* t);
    }
}


// --- wasm target ---
// libc subset for wasm.
when os(wasm) {

    // --- time ---
    // Host monotonic clock in nanoseconds.
    extern "env" i64 clock();
    i32 clock_gettime(i32 clk_id, void* tp) {
        i64 ns = clock();
        i64* p = cast(i64*, tp);
        *p = ns / 1000000000;
        *(p + 1) = ns % 1000000000;
        return 0;
    }
    // No blocking sleep in the browser; nanosleep is a no-op.
    i32 nanosleep(void* req, void* rem) { ignore req; ignore rem; return 0; }
    i64 time(i64* t) {
        i64 s = clock() / 1000000000;
        if t != null { *t = s; }
        return s;
    }

    // --- stdio (console) ---
    // puts writes the string + a newline to stdout.
    i32 puts(u8* s) {
        str line = { .data = s, .len = cast(i32, strlen(s)) };
        print("{}\n", line);
        return 0;
    }

    // --- buffered file I/O over the host VFS ---
    struct __rl_file { u8* data; i64 size; i64 pos; i32 err; }
    // The host VFS is read-only. Set err and return zero.
    u64 fwrite(void* p, u64 sz, u64 n, void* stream) {
        ignore p; ignore sz; ignore n;
        if stream != null {
            __rl_file* f = cast(__rl_file*, stream);
            f.err = 1;
        }
        return 0;
    }
}

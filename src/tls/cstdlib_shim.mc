

// Aligned allocation over the program allocator (no libc aligned-alloc).
// _aligned_malloc over-allocates and stashes the base pointer before the
// aligned address; _aligned_free recovers and releases it. posix_memalign
// returns a direct allocation (released by plain free), relying on the
// allocator's default alignment.
void* _aligned_malloc(u64 size, u64 align) {
    i64 a = cast(i64, align);
    if a < 1 { a = 1; }
    i64 slot = 8;
    u8* base = cast(u8*, alloc(cast(i64, size) + a + slot));
    if base == null { return null; }
    i64 aligned = (cast(i64, base) + slot + (a - 1)) & ~(a - 1);
    void** store = cast(void**, cast(u8*, aligned - slot));
    *store = cast(void*, base);
    return cast(void*, cast(u8*, aligned));
}
void _aligned_free(void* p) {
    if p == null { return; }
    void** store = cast(void**, cast(u8*, cast(i64, p) - 8));
    free(*store);
}
i32 posix_memalign(void** memptr, i32 alignment, u64 size) {
    ignore alignment;
    *memptr = alloc(cast(i64, size));
    if *memptr == null { return 12; }
    return 0;
}

when os(windows) {
    extern "msvcrt.dll" {
        i32 printf(u8* fmt, ...);
        i32 sprintf(u8* buf, u8* fmt, ...);
        i32 fprintf(void* stream, u8* fmt, ...);
        i64 clock();
        i32 strncmp(u8* a, u8* b, u64 n);
        i32 memcmp(void* a, void* b, u64 n);
        void* memchr(void* s, i32 c, u64 n);
        u64 strlen(u8* s);
        i32 atoi(u8* s);
        // fabs, sqrt: provided by the runtime.
        f64 floor(f64 x);
        f64 ceil(f64 x);
        f64 pow(f64 b, f64 e);
        f64 sin(f64 x);
        f64 cos(f64 x);
        f64 acos(f64 x);
        f64 asin(f64 x);
        f64 fmod(f64 x, f64 y);
        f64 tan(f64 x);
        f64 log(f64 x);
        f64 exp(f64 x);
        void abort();
    }
    // C99 math (round/log2/f32 variants) is in UCRT, not msvcrt.
    extern "ucrtbase.dll" {
        f64 round(f64 x);
        f64 log2(f64 x);
        f32 sinf(f32 x);
        f32 cosf(f32 x);
        f32 tanf(f32 x);
        f32 asinf(f32 x);
        f32 acosf(f32 x);
        f32 atanf(f32 x);
        f32 atan2f(f32 y, f32 x);
        // sqrtf: provided by the runtime.
        f32 powf(f32 b, f32 e);
        f32 expf(f32 x);
        f32 logf(f32 x);
        f32 floorf(f32 x);
        f32 ceilf(f32 x);
        f32 roundf(f32 x);
        f32 fmodf(f32 a, f32 b);
        // snprintf / vsnprintf: provided by cvararg_shim.mc.
        // memcpy, memset: provided by the runtime. memmove is not.
        void* memmove(void* dst, void* src, u64 n);
    }
    // MSVC FP-usage sentinel.
    i32 _fltused = 0x9875;
    // POSIX errno — a process-wide slot (not thread-local).
    i32 errno = 0;
    // Win32 high-resolution timer. void* params so LARGE_INTEGER need
    // not be in scope; callers pass a pointer to their own.
    extern "kernel32.dll" {
        i32 QueryPerformanceFrequency(void* p);
        i32 QueryPerformanceCounter(void* p);
    }
}
when os(linux) {
    extern "libc.so.6" {
        i32 printf(u8* fmt, ...);
        i32 sprintf(u8* buf, u8* fmt, ...);
        i32 fprintf(void* stream, u8* fmt, ...);
        i64 clock();
        i32 strncmp(u8* a, u8* b, u64 n);
        i32 memcmp(void* a, void* b, u64 n);
        void* memchr(void* s, i32 c, u64 n);
        u64 strlen(u8* s);
        i32 atoi(u8* s);
        // malloc, calloc, realloc, free: provided by the runtime allocator.
        void abort();
        void* memmove(void* dst, void* src, u64 n);
    }
    // glibc keeps the math functions in libm.so.6, not libc.so.6 — binding
    // them here is what pulls libm into DT_NEEDED so they resolve at runtime.
    extern "libm.so.6" {
        // fabs, sqrt, fabsf, sqrtf: provided by the runtime.
        f64 floor(f64 x);
        f64 ceil(f64 x);
        f64 pow(f64 b, f64 e);
        f64 sin(f64 x);
        f64 cos(f64 x);
        f64 acos(f64 x);
        f64 asin(f64 x);
        f64 fmod(f64 x, f64 y);
        f64 tan(f64 x);
        f64 log(f64 x);
        f64 exp(f64 x);
        f64 log2(f64 x);
        f64 round(f64 x);
        // f32 math
        f32 sinf(f32 x);
        f32 cosf(f32 x);
        f32 tanf(f32 x);
        f32 asinf(f32 x);
        f32 acosf(f32 x);
        f32 atanf(f32 x);
        f32 atan2f(f32 y, f32 x);
        f32 powf(f32 b, f32 e);
        f32 expf(f32 x);
        f32 logf(f32 x);
        f32 floorf(f32 x);
        f32 ceilf(f32 x);
        f32 roundf(f32 x);
        f32 fmodf(f32 a, f32 b);
    }
}
when os(android) {
    // Android Bionic
    extern "libc.so" {
        i32 printf(u8* fmt, ...);
        i32 sprintf(u8* buf, u8* fmt, ...);
        i32 fprintf(void* stream, u8* fmt, ...);
        i64 clock();
        i32 strncmp(u8* a, u8* b, u64 n);
        i32 memcmp(void* a, void* b, u64 n);
        void* memchr(void* s, i32 c, u64 n);
        u64 strlen(u8* s);
        i32 atoi(u8* s);
        void abort();
        void* memmove(void* dst, void* src, u64 n);
    }
    extern "libm.so" {
        f64 floor(f64 x);
        f64 ceil(f64 x);
        f64 pow(f64 b, f64 e);
        f64 sin(f64 x);
        f64 cos(f64 x);
        f64 acos(f64 x);
        f64 asin(f64 x);
        f64 fmod(f64 x, f64 y);
        f64 tan(f64 x);
        f64 log(f64 x);
        f64 exp(f64 x);
        f64 log2(f64 x);
        f64 round(f64 x);
        f32 sinf(f32 x);
        f32 cosf(f32 x);
        f32 tanf(f32 x);
        f32 asinf(f32 x);
        f32 acosf(f32 x);
        f32 atanf(f32 x);
        f32 atan2f(f32 y, f32 x);
        f32 powf(f32 b, f32 e);
        f32 expf(f32 x);
        f32 logf(f32 x);
        f32 floorf(f32 x);
        f32 ceilf(f32 x);
        f32 roundf(f32 x);
        f32 fmodf(f32 a, f32 b);
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
        i32 printf(u8* fmt, ...);
        i32 sprintf(u8* buf, u8* fmt, ...);
        i32 fprintf(void* stream, u8* fmt, ...);
        i64 clock();
        i32 strncmp(u8* a, u8* b, u64 n);
        i32 memcmp(void* a, void* b, u64 n);
        void* memchr(void* s, i32 c, u64 n);
        u64 strlen(u8* s);
        i32 atoi(u8* s);
        // fabs, sqrt: provided by the runtime.
        f64 floor(f64 x);
        f64 ceil(f64 x);
        f64 pow(f64 b, f64 e);
        f64 sin(f64 x);
        f64 cos(f64 x);
        f64 acos(f64 x);
        f64 asin(f64 x);
        f64 fmod(f64 x, f64 y);
        f64 tan(f64 x);
        f64 log(f64 x);
        f64 exp(f64 x);
        f64 log2(f64 x);
        f64 round(f64 x);
        // f32 math
        f32 sinf(f32 x);
        f32 cosf(f32 x);
        f32 tanf(f32 x);
        f32 asinf(f32 x);
        f32 acosf(f32 x);
        f32 atanf(f32 x);
        f32 atan2f(f32 y, f32 x);
        // sqrtf: provided by the runtime.
        f32 powf(f32 b, f32 e);
        f32 expf(f32 x);
        f32 logf(f32 x);
        // fabsf: provided by the runtime.
        f32 floorf(f32 x);
        f32 ceilf(f32 x);
        f32 roundf(f32 x);
        f32 fmodf(f32 a, f32 b);
        // malloc, calloc, realloc, free: provided by the runtime allocator.
        void abort();
        void* memmove(void* dst, void* src, u64 n);
    }
}

// <float.h> limits + <stdlib.h> RAND_MAX, as constants.
const i32 RAND_MAX = 32767;

const f32 FLT_MAX = 3.40282347e38f;
const f32 FLT_MIN = 1.17549435e-38f;
const f32 FLT_EPSILON = 1.19209290e-7f;
const f64 DBL_MAX = 1.7976931348623157e308;
const f64 DBL_MIN = 2.2250738585072014e-308;
const f64 DBL_EPSILON = 2.2204460492503131e-16;

// <math.h> NAN / INFINITY as f32 constants.
const f32 NAN = 0.0f / 0.0f;
const f32 INFINITY = 1.0f / 0.0f;

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

// POSIX <time.h>: timespec + clock_gettime. The real libc fn on
// linux/macos; on Windows (no libc clock_gettime) a monotonic
// implementation backed by the high-resolution performance counter.
struct timespec { i64 tv_sec; i64 tv_nsec; }
when os(windows) {
    i32 clock_gettime(i32 clk_id, timespec* tp) {
        i64 ticks = 0;
        i64 freq = 0;
        QueryPerformanceCounter(cast(void*, &ticks));
        QueryPerformanceFrequency(cast(void*, &freq));
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

// <stdio.h> file I/O. SEEK_* are the standard ANSI values.
const i32 SEEK_SET = 0;
const i32 SEEK_CUR = 1;
const i32 SEEK_END = 2;
when os(windows) {
    extern "msvcrt.dll" {
        i64 time(i64* t);
    }
}
when os(linux) {
    extern "libc.so.6" {
        i64 time(i64* t);
    }
}
when os(macos) || os(ios) {
    extern "libSystem.B.dylib" {
        i64 time(i64* t);
    }
}


// --- wasm target ---
// On wasm there is no system libc, so the libc subset is provided here
// (over the builtin allocator) or as host imports.
when os(wasm) {
    // Math is owned by the `math` module: it *defines* sinf/cosf/etc. on wasm,
    // so our own `extern "math"` for them would collide with a user's
    // `import math` (and with imgui, which imports this shim). Pull just the
    // transcendentals selectively — the listed names only, so `min`/`max` and
    // friends don't leak into consumers, and dedup'd against a user's full
    // `import math`.
    import { sin, cos, tan, asin, acos, atan, atan2, exp, log, pow, fmod, floor,
             ceil, round, sinf, cosf, tanf, asinf, acosf, atanf, atan2f, expf,
             logf, powf, fmodf, floorf, ceilf, roundf } from math;

    // --- allocator ---
    void* malloc(u64 size)            { return alloc(cast(i64, size)); }
    void* calloc(u64 count, u64 size) {
        i64 total = cast(i64, count) * cast(i64, size);
        void* p = alloc(total);
        if p != null { memset(p, 0, total); }
        return p;
    }

    // --- memory ---
    i32 memcmp(void* a, void* b, u64 n) {
        u8* pa = cast(u8*, a); u8* pb = cast(u8*, b);
        for u64 i = 0; i < n; i = i + 1 {
            if *(pa + i) != *(pb + i) {
                return cast(i32, *(pa + i)) - cast(i32, *(pb + i));
            }
        }
        return 0;
    }
    void* memmove(void* dst, void* src, u64 n) {
        u8* d = cast(u8*, dst); u8* s = cast(u8*, src);
        if cast(i64, d) < cast(i64, s) {
            for u64 i = 0; i < n; i = i + 1 { *(d + i) = *(s + i); }
        } else {
            for u64 i = n; i > 0; i = i - 1 { *(d + (i - 1)) = *(s + (i - 1)); }
        }
        return dst;
    }

    // --- strings ---
    u64 strlen(u8* s) { u64 n = 0; while *(s + n) != 0 { n = n + 1; } return n; }
    i32 strncmp(u8* a, u8* b, u64 n) {
        for u64 i = 0; i < n; i = i + 1 {
            u8 ca = *(a + i); u8 cb = *(b + i);
            if ca != cb { return cast(i32, ca) - cast(i32, cb); }
            if ca == 0 { return 0; }
        }
        return 0;
    }

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
    i32 atoi(u8* s) {
        i32 sign = 1; i32 v = 0;
        while *s == 32 || (*s >= 9 && *s <= 13) { s = s + 1; }
        if *s == 45 { sign = -1; s = s + 1; } else if *s == 43 { s = s + 1; }
        while *s >= 48 && *s <= 57 { v = v * 10 + cast(i32, *s - 48); s = s + 1; }
        return v * sign;
    }
}

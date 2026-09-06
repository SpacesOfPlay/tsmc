
import math;

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

// assert(cond): aborts on failure. Param is i64; nonzero = true.
void assert(i64 cond) {
    if cond == 0 {
        eprint("assertion failed\n");
        exit(1);
    }
}

when os(windows) {
    extern "msvcrt.dll" i32 fprintf(void* stream, u8* fmt, ...);
} else when os(linux) {
    extern "libc.so.6" i32 fprintf(void* stream, u8* fmt, ...);
} else when os(android) {
    extern "libc.so" i32 fprintf(void* stream, u8* fmt, ...);
} else when os(macos) || os(ios) {
    extern "libSystem.B.dylib" i32 fprintf(void* stream, u8* fmt, ...);
} else when os(wasm) {
    // No stream to write to. The one caller is a path the port never takes.
    i32 fprintf(void* stream, u8* fmt) { return 0; }
}

// No system allocator on wasm; the C shapes go over the builtin one.
when os(wasm) {
    void* malloc(u64 size)            { return alloc(cast(i64, size)); }
    void* calloc(u64 count, u64 size) {
        i64 total = cast(i64, count) * cast(i64, size);
        void* p = alloc(total);
        if p != null { memset(p, 0, total); }
        return p;
    }
}

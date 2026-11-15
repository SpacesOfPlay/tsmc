// Imports added on export so this module resolves standalone (LSP).
import ext_libc;

// Link-time fillers for picotls.

struct timeval {
    i64 tv_sec;
    i64 tv_usec;
}

i32 gettimeofday(timeval* tv, void* tz) {
    tv.tv_sec = 0;
    tv.tv_usec = 0;
    return 0;
}


// libc helpers picotls needs beyond ext_libc. The _picotls_ prefix keeps
// them clear of CRT and ext_libc names.

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

// MSVC bit-scan intrinsic over minc's clz builtin. Returns nonzero iff
// mask != 0.
u8 _picotls_BitScanReverse(u32* index, u32 mask) {
    if mask == 0 { return 0; }
    *index = cast(u32, 31 - clz(cast(i32, mask)));
    return 1;
}

// Count trailing zeros (64-bit). Returns 64 on 0.
i32 _picotls_ctzl(u64 x) {
    if x == 0 { return 64; }
    i32 c = 0;
    while (x & cast(u64, 1)) == 0 {
        x = x >> cast(u64, 1);
        c = c + 1;
    }
    return c;
}

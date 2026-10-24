// uefi_libc.mc — LOCAL (tsmc), not part of picotls-minc.
//
// ext_libc's printf writes through puts and its fprintf through fwrite.
// It binds both per OS and has no arm for the freestanding target, so the
// two sinks are supplied here. The runtime's console is what stdout means
// on that target; dropping the bytes instead would make a library
// diagnostic vanish exactly where there is no other way to see one.

when os(uefi) {
    i32 puts(u8* s) {
        i64 n = 0;
        while *(s + n) != 0 { n = n + 1; }
        ignore write(stdout(), cast(void*, s), cast(i32, n));
        str nl = "\n";
        ignore write(stdout(), cast(void*, nl.data), nl.len);
        return 0;
    }

    u64 fwrite(void* p, u64 size, u64 n, void* stream) {
        ignore stream;
        ignore write(stdout(), p, cast(i32, cast(i64, size) * cast(i64, n)));
        return n;
    }
}

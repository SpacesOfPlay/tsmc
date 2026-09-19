// uefi_host.mc — what a freestanding embedder supplies.
//
// On the uefi target there is no operating system under the program and
// no dynamic loader: the image is the machine, and whoever builds that
// image is the only thing that can answer for it. Files, a monotonic
// clock and threads cross over on their own because they lower to the
// runtime contract. Three things do not: entropy, the wall clock, and
// directories.
//
// Rather than guess at those, this declares a table the embedder fills in
// before running a script. Every entry may be left null, and the callers
// read null as "this target cannot" rather than substituting something
// weaker: crypto throws instead of handing out predictable bytes, Date is
// relative to boot instead of confidently wrong about the year, and the
// directory calls fail the way they do on a read-only file view. An
// embedder that installs nothing still runs a script.

when os(uefi) {

struct UefiHost {
    // Fill `buf` with `n` bytes from a real entropy source. True on
    // success. Null, or a false return, makes the crypto builtins throw.
    fn(u8*, i32): bool random_bytes;

    // Milliseconds since the Unix epoch, as the embedder best knows it:
    // an epoch read before firmware handed over, carried forward by the
    // monotonic counter, is the usual shape. 0 means the machine has no
    // such clock at all.
    fn(): i64 wall_ms;

    // Directories. Null throughout is a flat file view, which is what a
    // program gets until the embedder attaches a volume.
    fn(u8*): bool is_dir;
    fn(u8*): bool mkdir;
    fn(u8*): bool rmdir;

    // The `index`th name in `dir`, written into `buf`. Its length, or -1
    // once the directory is exhausted.
    fn(u8*, i32, u8*, i32): i32 list;
}

UefiHost* g_uefi_host = null;

// Install the table. The pointer is kept rather than copied, so it has to
// outlive the run; a global in the embedder is the usual shape.
void tsmc_set_uefi_host(UefiHost* h) { g_uefi_host = h; }

// --- what the arms below call --------------------------------------------
//
// Each one folds "no table" and "no entry" into the same answer, so the
// platform arms read as though the capability were simply absent.

bool uefi_random_bytes(u8* buf, i32 n) {
    if g_uefi_host == null || g_uefi_host.random_bytes == null { return false; }
    return g_uefi_host.random_bytes(buf, n);
}

// Without an embedder clock this falls back to the monotonic counter, so
// Date still advances and the difference between two readings is still
// right. Only the origin is wrong, which is the failure a program can see
// and correct for; a frozen clock is not.
i64 uefi_wall_ms() {
    if g_uefi_host != null && g_uefi_host.wall_ms != null {
        i64 w = g_uefi_host.wall_ms();
        if w != 0 { return w; }
    }
    i64 f = qpf();
    if f == 0 { return 0; }
    return qpc() / (f / 1000);
}

bool uefi_is_dir(u8* path) {
    if g_uefi_host == null || g_uefi_host.is_dir == null { return false; }
    return g_uefi_host.is_dir(path);
}

bool uefi_mkdir(u8* path) {
    if g_uefi_host == null || g_uefi_host.mkdir == null { return false; }
    return g_uefi_host.mkdir(path);
}

bool uefi_rmdir(u8* path) {
    if g_uefi_host == null || g_uefi_host.rmdir == null { return false; }
    return g_uefi_host.rmdir(path);
}

i32 uefi_list(u8* dir, i32 index, u8* buf, i32 cap) {
    if g_uefi_host == null || g_uefi_host.list == null { return 0 - 1; }
    return g_uefi_host.list(dir, index, buf, cap);
}

}

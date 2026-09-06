// wasm_host — the host functions the wasm build imports under the "tsmc"
// module, beyond the read-only file view, clock and console the standard
// library asks for. web/tsmc_host.js provides them, for a page and for a
// node runner alike.

when os(wasm) {
    extern "tsmc" {
        // 1 when path names a directory in the host's file view.
        i64 host_is_dir(u8* path) from "is_dir";
        // Fills buf with n bytes from the host's CSPRNG. 1 on success.
        i64 host_random_bytes(u8* buf, i64 n) from "random_bytes";
    }
}

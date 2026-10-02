// test_sha256_hw.mc -- SHA-256 on the CPU's instructions (sha256_compress,
// behind the LOCAL hook in src/tls/picotls_lib.mc) against cifra's own
// code: the FIPS 180-4 vectors, and random messages of every length to
// 300 bytes hashed whole and in random pieces both ways. A machine
// without the instructions checks cifra's code alone.
//
// Exit 0 means every check held.

@utf8_console

import "../../src/tls/picotls.mc";

i32 fails = 0;

void check(bool ok, str what) {
    if !ok {
        fails++;
        if fails < 10 { eprint("FAIL: {}\n", what); }
    }
}

u64 g_seed = 0x2545F4914F6CDD1D;
u8 rnd() {
    g_seed = g_seed ^ (g_seed << 13);
    g_seed = g_seed ^ (g_seed >> 7);
    g_seed = g_seed ^ (g_seed << 17);
    return cast(u8, g_seed >> 24);
}

// The digest of msg[0..n), fed in pieces of at most `piece` bytes.
void digest(u8* msg, u64 n, u64 piece, u8* out) {
    cf_sha256_context ctx;
    cf_sha256_init(&ctx);
    u64 at = 0;
    while at < n {
        u64 k = n - at;
        if k > piece { k = piece; }
        cf_sha256_update(&ctx, cast(void*, msg + at), k);
        at = at + k;
    }
    cf_sha256_digest_final(&ctx, out);
}

bool hex_is(u8* d, str want) {
    u8[16] hx = { 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 97, 98, 99, 100, 101, 102 };
    for i32 i = 0; i < 32; i++ {
        if *(want.data + 2 * i) != hx[d[i] >> 4] || *(want.data + 2 * i + 1) != hx[d[i] & 15] { return false; }
    }
    return true;
}

i32 main() {
    bool hw = sha256_hw_force(1);
    u8[32] d;
    u8[64] abc = { 97, 98, 99 };
    for i32 pass = 0; pass < 2; pass++ {
        ignore sha256_hw_force(pass == 0 ? 1 : 0);
        digest(&abc[0], 3, 64, &d[0]);
        check(hex_is(&d[0], "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"), "FIPS 180-4 abc");
        str two = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
        digest(two.data, cast(u64, two.len), 64, &d[0]);
        check(hex_is(&d[0], "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"), "FIPS 180-4 448-bit message");
        u8* ma = alloc<u8>(1000000);
        for i32 i = 0; i < 1000000; i++ { ma[i] = 97; }
        digest(ma, 1000000, 1000000, &d[0]);
        check(hex_is(&d[0], "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"), "a million a, whole");
        digest(ma, 1000000, 777, &d[0]);
        check(hex_is(&d[0], "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"), "a million a, in pieces");
        free(ma);
    }
    u8[300] msg;
    u8[32] a;
    u8[32] b;
    for i32 n = 0; n <= 300; n++ {
        for i32 i = 0; i < n; i++ { msg[i] = rnd(); }
        u64 piece = 1 + cast(u64, rnd()) % 80;
        ignore sha256_hw_force(0);
        digest(&msg[0], cast(u64, n), 300, &a[0]);
        ignore sha256_hw_force(1);
        digest(&msg[0], cast(u64, n), piece, &b[0]);
        bool same = true;
        for i32 i = 0; i < 32; i++ { if a[i] != b[i] { same = false; } }
        check(same, "random message: instructions in pieces = cifra whole");
    }
    ignore sha256_hw_force(1);
    if fails == 0 {
        if hw { print("sha256_hw ok (instructions and cifra)\n"); }
        else { print("sha256_hw ok (cifra only: no instructions here)\n"); }
        return 0;
    }
    return 1;
}

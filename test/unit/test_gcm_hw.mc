// test_gcm_hw.mc -- AES-GCM on the CPU's instructions against cifra's own
// software path, which test_aes_ct.mc holds to the specification.
//
// Random AES-128 and AES-256 keys, nonces, associated data and messages
// from empty to 20,000 bytes, with every length near the block, group and
// record sizes the hardware path treats differently: the ciphertext and
// the tag must be the same both ways, the hardware path must open what
// either sealed, and it must refuse a message whose tag or ciphertext was
// changed. A machine without the instructions passes trivially.
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

u64 g_seed = 0x9E3779B97F4A7C15;
u8 rnd() {
    g_seed = g_seed ^ (g_seed << 13);
    g_seed = g_seed ^ (g_seed >> 7);
    g_seed = g_seed ^ (g_seed << 17);
    return cast(u8, g_seed >> 24);
}

bool same(u8* a, u8* b, u64 n) {
    for u64 i = 0; i < n; i++ { if *(a + i) != *(b + i) { return false; } }
    return true;
}

i32 main() {
    if !cifra_hw_force(1) {
        print("gcm_hw ok (no AES or carry-less multiply instructions here)\n");
        return 0;
    }
    u64 most = 20000;
    u8* plain = alloc<u8>(cast(i64, most));
    u8* ct_hw = alloc<u8>(cast(i64, most));
    u8* ct_sw = alloc<u8>(cast(i64, most));
    u8* back = alloc<u8>(cast(i64, most));
    // The lengths around what the hardware path does differently: a block,
    // a group of 4 or 16 blocks, the switch to 16 at 1 KB, 4 KB pieces.
    u64[18] edges = { 0, 1, 15, 16, 17, 63, 64, 65, 255, 256, 257, 1008, 1023, 1024, 1025, 4095, 4097, 16384 };
    i32 cases = 0;
    for i32 t = 0; t < 600; t++ {
        u8[32] key;
        u64 nkey = 16;
        if t % 3 == 2 { nkey = 32; }
        for i32 k = 0; k < 32; k++ { key[k] = rnd(); }
        u8[12] nonce;
        for i32 k = 0; k < 12; k++ { nonce[k] = rnd(); }
        u8[64] aad;
        u64 naad = cast(u64, rnd()) % 65;
        if t % 5 == 0 { naad = 0; }
        for i32 k = 0; k < 64; k++ { aad[k] = rnd(); }
        u64 n = (cast(u64, rnd()) << 8 | cast(u64, rnd())) % most;
        if t < 18 * 2 { n = edges[t % 18]; }
        if t % 7 == 3 { n = cast(u64, rnd()) + cast(u64, rnd()); }
        for u64 k = 0; k < n; k++ { *(plain + k) = rnd(); }

        u8[16] tag_hw;
        u8[16] tag_sw;
        ignore cifra_hw_force(1);
        cf_aes_context hw;
        cf_aes_init(&hw, &key[0], nkey);
        cf_gcm_encrypt(&cf_aes, cast(void*, &hw), plain, n, &aad[0], naad, &nonce[0], 12, ct_hw, &tag_hw[0], 16);
        ignore cifra_hw_force(0);
        cf_aes_context sw;
        cf_aes_init(&sw, &key[0], nkey);
        cf_gcm_encrypt(&cf_aes, cast(void*, &sw), plain, n, &aad[0], naad, &nonce[0], 12, ct_sw, &tag_sw[0], 16);
        ignore cifra_hw_force(1);
        check(same(ct_hw, ct_sw, n), "the same ciphertext both ways");
        check(same(&tag_hw[0], &tag_sw[0], 16), "the same tag both ways");

        i32 r = cf_gcm_decrypt(&cf_aes, cast(void*, &hw), ct_sw, n, &aad[0], naad, &nonce[0], 12, &tag_sw[0], 16, back);
        check(r == 0 && same(back, plain, n), "the hardware opens what the software sealed");
        u8[16] bad;
        for i32 k = 0; k < 16; k++ { bad[k] = tag_hw[k]; }
        // The index in a variable: a compound assignment evaluates its
        // target's index expression twice.
        i32 bi = cast(i32, rnd()) % 16;
        i32 bb = cast(i32, rnd()) % 8;
        bad[bi] ^= cast(u8, 1 << bb);
        check(cf_gcm_decrypt(&cf_aes, cast(void*, &hw), ct_hw, n, &aad[0], naad, &nonce[0], 12, &bad[0], 16, back) != 0,
              "a changed tag is refused");
        if n > 0 {
            u64 at = (cast(u64, rnd()) << 8 | cast(u64, rnd())) % n;
            *(ct_hw + at) ^= 0x40;
            check(cf_gcm_decrypt(&cf_aes, cast(void*, &hw), ct_hw, n, &aad[0], naad, &nonce[0], 12, &tag_hw[0], 16, back) != 0,
                  "a changed byte of ciphertext is refused");
        }
        cases++;
    }
    if fails == 0 { print("gcm_hw ok ({} messages)\n", cases); return 0; }
    eprint("gcm_hw: {} failures\n", fails);
    return 1;
}

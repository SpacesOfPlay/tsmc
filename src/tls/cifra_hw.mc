// cifra_hw.mc: hardware AES and GHASH for cifra, behind the patch in
// ext/cifra/patches/0002-hw-aes-gcm.patch. cifra's aes.c, gf128.c and
// gcm.c call these hooks; each reports when the CPU has no AES round or
// carry-less multiply instructions, and cifra keeps its constant-time
// software path.
// The instructions are constant-time too.
//
// The CPU is asked once: CPUID is a VM exit under a hypervisor, too dear
// for every block. cifra_hw_force switches the hardware path off or on
// again, for tests that compare the two paths.

i32 g_cifra_hw = -1;           // -1 not asked yet, 0 software, 1 hardware

bool cifra_hw_on() {
    if g_cifra_hw < 0 {
        g_cifra_hw = 0;
        when arch(x64) || arch(arm64) {
            if cpu_has_aes() && cpu_has_clmul() { g_cifra_hw = 1; }
        }
    }
    return g_cifra_hw == 1;
}

// on: 0 for the software path, 1 for the hardware one where the CPU has
// it. Returns whether the hardware path is now in use.
bool cifra_hw_force(i32 on) {
    g_cifra_hw = -1;
    if on == 0 { g_cifra_hw = 0; }
    return cifra_hw_on();
}

// cifra keeps a block as u32 words, each the big-endian value of four
// bytes, stored little-endian: reversing the bytes of each word gives the
// block's bytes in order, and the same shuffle turns them back.
i8[16] g_cifra_hw_word_swap = { 3, 2, 1, 0, 7, 6, 5, 4, 11, 10, 9, 8, 15, 14, 13, 12 };

when arch(x64) || arch(arm64) {

// The round keys from cifra's schedule `ks` (rounds + 1 of them, four
// words each), as blocks in `hwks`. Returns 1, or 0 without the hardware.
i32 cf_aes_hw_init(u32* ks, u32 rounds, u8* hwks) {
    if !cifra_hw_on() { return 0; }
    i8x16 swap = i8x16_load(&g_cifra_hw_word_swap[0]);
    for u32 r = 0; r <= rounds; r++ {
        i8x16 k = i8x16_load(cast(i8*, &ks[4 * r]));
        i8x16_store(cast(i8*, &hwks[16 * r]), byte_shuffle(k, swap));
    }
    return 1;
}

// One block, `in` to `out`, with the round keys cf_aes_hw_init made.
void cf_aes_hw_encrypt(u8* hwks, u32 rounds, u8* in, u8* out) {
    i8x16 s = i8x16_load(cast(i8*, in)) ^ i8x16_load(cast(i8*, &hwks[0]));
    for u32 r = 1; r < rounds; r++ {
        s = aesenc(s, i8x16_load(cast(i8*, &hwks[16 * r])));
    }
    s = aesenclast(s, i8x16_load(cast(i8*, &hwks[16 * rounds])));
    i8x16_store(cast(i8*, out), s);
}

// GCM reads a block with the top bit of byte 0 as x^0. Reversing the
// bits of every byte, byte order kept, gives a little-endian integer
// whose bit i is x^i: the order clmul multiplies in.
u8[16] g_cifra_hw_rev_lo = { 0x00, 0x80, 0x40, 0xC0, 0x20, 0xA0, 0x60, 0xE0,
                             0x10, 0x90, 0x50, 0xD0, 0x30, 0xB0, 0x70, 0xF0 };
i8[16] g_cifra_hw_rev_hi = { 0x00, 0x08, 0x04, 0x0C, 0x02, 0x0A, 0x06, 0x0E,
                             0x01, 0x09, 0x05, 0x0D, 0x03, 0x0B, 0x07, 0x0F };
i8[16] g_cifra_hw_low4 = { 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15 };

i8x16 cifra_hw_bitrev(i8x16 v) {
    i8x16 mask = i8x16_load(&g_cifra_hw_low4[0]);
    i8x16 lo = v & mask;
    i8x16 hi = cast(i8x16, cast(u64x2, v) >> 4) & mask;
    return byte_shuffle(i8x16_load(cast(i8*, &g_cifra_hw_rev_lo[0])), lo) |
           byte_shuffle(i8x16_load(&g_cifra_hw_rev_hi[0]), hi);
}

// The 256-bit carry-less product hi:lo modulo x^128 + x^7 + x^2 + x + 1,
// with bit i of the little-endian values as x^i. The top 128 bits fold
// down one 64-bit word at a time: x^128 = 1 + x + x^2 + x^7, so word 3
// folds into words 1 and 2, then word 2 into words 0 and 1.
u64x2 cifra_hw_reduce(u64x2 lo, u64x2 hi) {
    u64 z0 = lo.x;
    u64 z1 = lo.y;
    u64 z2 = hi.x;
    u64 z3 = hi.y;
    z1 = z1 ^ z3 ^ (z3 << 1) ^ (z3 << 2) ^ (z3 << 7);
    z2 = z2 ^ (z3 >> 63) ^ (z3 >> 62) ^ (z3 >> 57);
    z0 = z0 ^ z2 ^ (z2 << 1) ^ (z2 << 2) ^ (z2 << 7);
    z1 = z1 ^ (z2 >> 63) ^ (z2 >> 62) ^ (z2 >> 57);
    return u64x2{z0, z1};
}

// a * b in GF(2^128): four clmuls give the 256-bit product.
u64x2 cifra_hw_gf_mul(u64x2 a, u64x2 b) {
    u64x2 p00 = clmul(a, b, 0x00);
    u64x2 p11 = clmul(a, b, 0x11);
    u64x2 mid = clmul(a, b, 0x01) ^ clmul(a, b, 0x10);
    u64x2 lo = p00 ^ cast(u64x2, byte_shl(cast(i8x16, mid), 8));
    u64x2 hi = p11 ^ cast(u64x2, byte_shr(cast(i8x16, mid), 8));
    return cifra_hw_reduce(lo, hi);
}

// out = x * y in GF(2^128), each a cifra cf_gf128 (four u32 words).
// Arguments may alias. Returns 1, or 0 without the hardware.
i32 cf_gf128_hw_mul(u32* x, u32* y, u32* out) {
    if !cifra_hw_on() { return 0; }
    i8x16 swap = i8x16_load(&g_cifra_hw_word_swap[0]);
    u64x2 a = cast(u64x2, cifra_hw_bitrev(byte_shuffle(i8x16_load(cast(i8*, x)), swap)));
    u64x2 b = cast(u64x2, cifra_hw_bitrev(byte_shuffle(i8x16_load(cast(i8*, y)), swap)));
    i8x16 r = byte_shuffle(cifra_hw_bitrev(cast(i8x16, cifra_hw_gf_mul(a, b))), swap);
    i8x16_store(cast(i8*, out), r);
    return 1;
}


// --- AES-GCM -------------------------------------------------------------
//
// Whole messages for cf_gcm_encrypt and cf_gcm_decrypt, when the key is an
// AES key with hardware round keys and the nonce is 96 bits. Counter mode
// runs eight blocks at a time, so their AES rounds overlap in the
// pipeline; GHASH takes four blocks per reduction, with H, H^2, H^3 and
// H^4 computed once per message. Called per block, the same work spends
// most of its time on calls and on cifra's word order.

// Y after absorbing `n` bytes at `p`, the last block padded with zeros.
// `hp` holds H, H^2, H^3 and H^4 as four 16-byte values.
u64x2 cifra_hw_ghash(u64x2 y, u8* hp, u8* p, u64 n) {
    u64x2 h1 = cast(u64x2, i8x16_load(cast(i8*, hp)));
    u64x2 h2 = cast(u64x2, i8x16_load(cast(i8*, hp + 16)));
    u64x2 h3 = cast(u64x2, i8x16_load(cast(i8*, hp + 32)));
    u64x2 h4 = cast(u64x2, i8x16_load(cast(i8*, hp + 48)));
    u64 i = 0;
    while i + 64 <= n {
        u64x2 b0 = y ^ cast(u64x2, cifra_hw_bitrev(i8x16_load(cast(i8*, p + i))));
        u64x2 b1 = cast(u64x2, cifra_hw_bitrev(i8x16_load(cast(i8*, p + i + 16))));
        u64x2 b2 = cast(u64x2, cifra_hw_bitrev(i8x16_load(cast(i8*, p + i + 32))));
        u64x2 b3 = cast(u64x2, cifra_hw_bitrev(i8x16_load(cast(i8*, p + i + 48))));
        u64x2 lo = clmul(b0, h4, 0x00) ^ clmul(b1, h3, 0x00) ^ clmul(b2, h2, 0x00) ^ clmul(b3, h1, 0x00);
        u64x2 hi = clmul(b0, h4, 0x11) ^ clmul(b1, h3, 0x11) ^ clmul(b2, h2, 0x11) ^ clmul(b3, h1, 0x11);
        u64x2 mid = clmul(b0, h4, 0x01) ^ clmul(b0, h4, 0x10) ^ clmul(b1, h3, 0x01) ^ clmul(b1, h3, 0x10)
                  ^ clmul(b2, h2, 0x01) ^ clmul(b2, h2, 0x10) ^ clmul(b3, h1, 0x01) ^ clmul(b3, h1, 0x10);
        lo = lo ^ cast(u64x2, byte_shl(cast(i8x16, mid), 8));
        hi = hi ^ cast(u64x2, byte_shr(cast(i8x16, mid), 8));
        y = cifra_hw_reduce(lo, hi);
        i = i + 64;
    }
    while i + 16 <= n {
        y = cifra_hw_gf_mul(y ^ cast(u64x2, cifra_hw_bitrev(i8x16_load(cast(i8*, p + i)))), h1);
        i = i + 16;
    }
    if i < n {
        u8[16] last;
        for i32 k = 0; k < 16; k++ { last[k] = 0; }
        for u64 k = 0; i + k < n; k++ { last[k] = *(p + i + k); }
        y = cifra_hw_gf_mul(y ^ cast(u64x2, cifra_hw_bitrev(i8x16_load(cast(i8*, &last[0])))), h1);
    }
    return y;
}

// Counter mode over `n` bytes, from `in` to `out` (which may be the same
// buffer), starting at counter `ctr`. A counter block is the 12-byte
// nonce in `j0` and the counter as 32 big-endian bits.
void cifra_hw_ctr(u8* rk, u32 rounds, u8* j0, u32 ctr, u8* in, u8* out, u64 n) {
    u8[128] cb;
    for i32 b = 0; b < 8; b++ {
        for i32 k = 0; k < 12; k++ { cb[16 * b + k] = *(j0 + k); }
    }
    u8* last = rk + 16 * cast(u64, rounds);
    u64 i = 0;
    while i + 128 <= n {
        for u32 b = 0; b < 8; b++ {
            u32 c = ctr + b;
            cb[16 * b + 12] = cast(u8, c >> 24);
            cb[16 * b + 13] = cast(u8, c >> 16);
            cb[16 * b + 14] = cast(u8, c >> 8);
            cb[16 * b + 15] = cast(u8, c);
        }
        ctr = ctr + 8;
        i8x16 k0 = i8x16_load(cast(i8*, rk));
        i8x16 s0 = i8x16_load(cast(i8*, &cb[0])) ^ k0;
        i8x16 s1 = i8x16_load(cast(i8*, &cb[16])) ^ k0;
        i8x16 s2 = i8x16_load(cast(i8*, &cb[32])) ^ k0;
        i8x16 s3 = i8x16_load(cast(i8*, &cb[48])) ^ k0;
        i8x16 s4 = i8x16_load(cast(i8*, &cb[64])) ^ k0;
        i8x16 s5 = i8x16_load(cast(i8*, &cb[80])) ^ k0;
        i8x16 s6 = i8x16_load(cast(i8*, &cb[96])) ^ k0;
        i8x16 s7 = i8x16_load(cast(i8*, &cb[112])) ^ k0;
        for u32 r = 1; r < rounds; r++ {
            i8x16 k = i8x16_load(cast(i8*, rk + 16 * cast(u64, r)));
            s0 = aesenc(s0, k);
            s1 = aesenc(s1, k);
            s2 = aesenc(s2, k);
            s3 = aesenc(s3, k);
            s4 = aesenc(s4, k);
            s5 = aesenc(s5, k);
            s6 = aesenc(s6, k);
            s7 = aesenc(s7, k);
        }
        i8x16 kl = i8x16_load(cast(i8*, last));
        u8* ip = in + i;
        u8* op = out + i;
        i8x16_store(cast(i8*, op), aesenclast(s0, kl) ^ i8x16_load(cast(i8*, ip)));
        i8x16_store(cast(i8*, op + 16), aesenclast(s1, kl) ^ i8x16_load(cast(i8*, ip + 16)));
        i8x16_store(cast(i8*, op + 32), aesenclast(s2, kl) ^ i8x16_load(cast(i8*, ip + 32)));
        i8x16_store(cast(i8*, op + 48), aesenclast(s3, kl) ^ i8x16_load(cast(i8*, ip + 48)));
        i8x16_store(cast(i8*, op + 64), aesenclast(s4, kl) ^ i8x16_load(cast(i8*, ip + 64)));
        i8x16_store(cast(i8*, op + 80), aesenclast(s5, kl) ^ i8x16_load(cast(i8*, ip + 80)));
        i8x16_store(cast(i8*, op + 96), aesenclast(s6, kl) ^ i8x16_load(cast(i8*, ip + 96)));
        i8x16_store(cast(i8*, op + 112), aesenclast(s7, kl) ^ i8x16_load(cast(i8*, ip + 112)));
        i = i + 128;
    }
    while i < n {
        cb[12] = cast(u8, ctr >> 24);
        cb[13] = cast(u8, ctr >> 16);
        cb[14] = cast(u8, ctr >> 8);
        cb[15] = cast(u8, ctr);
        ctr = ctr + 1;
        u8[16] ks;
        cf_aes_hw_encrypt(rk, rounds, &cb[0], &ks[0]);
        u64 m = n - i;
        if m > 16 { m = 16; }
        for u64 k = 0; k < m; k++ { *(out + i + k) = *(in + i + k) ^ ks[k]; }
        i = i + m;
    }
}

// H and its powers into `hp`, the nonce into the first 12 bytes of `j0`
// (J0 itself, counter 1), and E_K(J0) into `ej0`, for a 96-bit nonce.
void cifra_hw_gcm_setup(u8* rk, u32 rounds, u8* nonce, u8* hp, u8* j0, u8* ej0) {
    u8[16] h;
    for i32 k = 0; k < 16; k++ { h[k] = 0; }
    cf_aes_hw_encrypt(rk, rounds, &h[0], &h[0]);
    u64x2 h1 = cast(u64x2, cifra_hw_bitrev(i8x16_load(cast(i8*, &h[0]))));
    u64x2 h2 = cifra_hw_gf_mul(h1, h1);
    u64x2 h3 = cifra_hw_gf_mul(h2, h1);
    u64x2 h4 = cifra_hw_gf_mul(h3, h1);
    i8x16_store(cast(i8*, hp), cast(i8x16, h1));
    i8x16_store(cast(i8*, hp + 16), cast(i8x16, h2));
    i8x16_store(cast(i8*, hp + 32), cast(i8x16, h3));
    i8x16_store(cast(i8*, hp + 48), cast(i8x16, h4));
    for i32 k = 0; k < 12; k++ { *(j0 + k) = *(nonce + k); }
    *(j0 + 12) = 0;
    *(j0 + 13) = 0;
    *(j0 + 14) = 0;
    *(j0 + 15) = 1;
    cf_aes_hw_encrypt(rk, rounds, j0, ej0);
    for i32 k = 0; k < 16; k++ { h[k] = 0; }
}

// The full tag: GHASH of the lengths block, back in byte order, XOR
// E_K(J0).
void cifra_hw_gcm_tag(u64x2 y, u8* hp, u64 naad, u64 n, u8* ej0, u8* out) {
    u8[16] lens;
    u64 abits = naad * 8;
    u64 cbits = n * 8;
    for i32 k = 0; k < 8; k++ {
        lens[k] = cast(u8, abits >> cast(u64, 56 - 8 * k));
        lens[8 + k] = cast(u8, cbits >> cast(u64, 56 - 8 * k));
    }
    y = cifra_hw_ghash(y, hp, &lens[0], 16);
    i8x16 t = cifra_hw_bitrev(cast(i8x16, y)) ^ i8x16_load(cast(i8*, ej0));
    i8x16_store(cast(i8*, out), t);
}

// Encrypts `n` bytes of `plain` into `cipher` and writes `ntag` bytes of
// tag. Returns 1, or 0 without the hardware.
i32 cf_gcm_hw_seal(u8* rk, u32 rounds, u8* plain, u64 n, u8* aad, u64 naad,
                   u8* nonce, u8* cipher, u8* tag, u64 ntag) {
    if !cifra_hw_on() { return 0; }
    u8[64] hp;
    u8[16] j0;
    u8[16] ej0;
    u8[16] full;
    cifra_hw_gcm_setup(rk, rounds, nonce, &hp[0], &j0[0], &ej0[0]);
    u64x2 y = cifra_hw_ghash(u64x2{0, 0}, &hp[0], aad, naad);
    // Encrypt and hash 4 KB at a time, so the hash reads the ciphertext
    // from the cache. Every piece but the last is whole blocks.
    u64 done = 0;
    u32 ctr = 2;
    while done < n {
        u64 m = n - done;
        if m > 4096 { m = 4096; }
        cifra_hw_ctr(rk, rounds, &j0[0], ctr, plain + done, cipher + done, m);
        y = cifra_hw_ghash(y, &hp[0], cipher + done, m);
        ctr = ctr + cast(u32, m / 16);
        done = done + m;
    }
    cifra_hw_gcm_tag(y, &hp[0], naad, n, &ej0[0], &full[0]);
    for u64 k = 0; k < ntag && k < 16; k++ { *(tag + k) = full[k]; }
    for i32 k = 0; k < 64; k++ { hp[k] = 0; }
    for i32 k = 0; k < 16; k++ { ej0[k] = 0; full[k] = 0; }
    return 1;
}

// Checks the tag over `cipher`, then decrypts it into `plain`. Returns 0
// when the tag matches, 1 when it does not (and `plain` is untouched), or
// -1 without the hardware.
i32 cf_gcm_hw_open(u8* rk, u32 rounds, u8* cipher, u64 n, u8* aad, u64 naad,
                   u8* nonce, u8* tag, u64 ntag, u8* plain) {
    if !cifra_hw_on() { return 0 - 1; }
    u8[64] hp;
    u8[16] j0;
    u8[16] ej0;
    u8[16] full;
    cifra_hw_gcm_setup(rk, rounds, nonce, &hp[0], &j0[0], &ej0[0]);
    u64x2 y = cifra_hw_ghash(u64x2{0, 0}, &hp[0], aad, naad);
    y = cifra_hw_ghash(y, &hp[0], cipher, n);
    cifra_hw_gcm_tag(y, &hp[0], naad, n, &ej0[0], &full[0]);
    // Compared without an early exit, so the time does not depend on
    // where the tags differ.
    u8 diff = 0;
    for u64 k = 0; k < ntag && k < 16; k++ { diff = diff | (full[k] ^ *(tag + k)); }
    i32 err = 1;
    if diff == 0 {
        cifra_hw_ctr(rk, rounds, &j0[0], 2, cipher, plain, n);
        err = 0;
    }
    for i32 k = 0; k < 64; k++ { hp[k] = 0; }
    for i32 k = 0; k < 16; k++ { ej0[k] = 0; full[k] = 0; }
    return err;
}

} else {

i32 cf_aes_hw_init(u32* ks, u32 rounds, u8* hwks) { return 0; }
void cf_aes_hw_encrypt(u8* hwks, u32 rounds, u8* in, u8* out) {}
i32 cf_gf128_hw_mul(u32* x, u32* y, u32* out) { return 0; }
i32 cf_gcm_hw_seal(u8* rk, u32 rounds, u8* plain, u64 n, u8* aad, u64 naad,
                   u8* nonce, u8* cipher, u8* tag, u64 ntag) { return 0; }
i32 cf_gcm_hw_open(u8* rk, u32 rounds, u8* cipher, u64 n, u8* aad, u64 naad,
                   u8* nonce, u8* tag, u64 ntag, u8* plain) { return 0 - 1; }

}

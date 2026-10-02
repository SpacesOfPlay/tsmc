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

// The 256-bit arm (two blocks per VAESENC and VPCLMULQDQ), in an image
// built with CIFRA_HW_256 (an -avx2 target, where the 256-bit vectors
// are ymm registers) on a CPU that has both instructions.
i32 g_cifra_hw_wide = -1;      // -1 not asked yet, 0 128-bit, 1 256-bit

bool cifra_hw_wide() {
    if g_cifra_hw_wide < 0 {
        g_cifra_hw_wide = 0;
        when defined(CIFRA_HW_256) {
            when arch(x64) {
                if cifra_hw_on() && cpu_has_vaes() && cpu_has_vpclmulqdq() { g_cifra_hw_wide = 1; }
            }
        }
    }
    return g_cifra_hw_wide == 1;
}

// on: 0 for the 128-bit arm, 1 for the 256-bit one where it is built and
// the CPU has it. Returns whether the 256-bit arm is now in use.
bool cifra_hw_force_wide(i32 on) {
    g_cifra_hw_wide = -1;
    if on == 0 { g_cifra_hw_wide = 0; }
    return cifra_hw_wide();
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
// pipeline; GHASH takes four or sixteen blocks per reduction, with that
// many powers of H computed once per message and cleared after it.
// Called per block, the same work spends most of its time on calls and
// on cifra's word order.

// Y after absorbing `n` bytes at `p`, the last block padded with zeros.
//
// Y and the powers of H are kept byte-reversed: a block's 16 bytes loaded
// in reverse order, so bit i of the 128-bit value is x^(127-i), GCM's bit
// order reflected. The carry-less product of two reflected values is the
// reflected product shifted by one bit; H is stored shifted by one bit
// and reduced (cifra_hw_ghash_powers) so that the products come out
// aligned, and the reduction folds the top half down with shifts. This is
// the method of Intel's white paper on GCM and of OpenSSL's ghash-x86_64.
// A block is byte-swapped, one shuffle, where reversing its bits took six
// operations; each block takes three multiplies (Karatsuba: the halves'
// products, and the product of their sums, whose XOR with both is the
// middle); and a group of blocks, each multiplied by its own power of H,
// shares one reduction.
//
// `hp` holds H^1..H^nb, 16 bytes each, then for each power the XOR of its
// two halves (cifra_hw_ghash_powers); `nb` is 4 or 16.

i8[16] g_cifra_hw_bswap = { 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0 };
// Reverses the last four bytes of a block: a counter block's big-endian
// counter to a little-endian lane and back.
i8[16] g_cifra_hw_ctr_rev = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 15, 14, 13, 12 };
i8[16] g_cifra_hw_halves = { 8, 9, 10, 11, 12, 13, 14, 15, 0, 1, 2, 3, 4, 5, 6, 7 };

// The most powers of H a message needs, and the bytes that hold them and
// their halves' XORs.
const u64 CIFRA_HW_POWERS = 16;
const i32 CIFRA_HW_HP = 512;

u64x2 cifra_hw_load_rev(u8* p) {
    return cast(u64x2, byte_shuffle(i8x16_load(cast(i8*, p)), i8x16_load(&g_cifra_hw_bswap[0])));
}

// The XOR of a value's two 64-bit halves, in both lanes.
u64x2 cifra_hw_halves_xor(u64x2 v) {
    return v ^ cast(u64x2, byte_shuffle(cast(i8x16, v), i8x16_load(&g_cifra_hw_halves[0])));
}

// The 256-bit product hi:lo reduced, in the reflected order: the low
// half's multiples of the polynomial (shifts by 57, 62 and 63) fold into
// its upper word and the high half, then the low half and its shifts by
// 1, 2 and 7 are added to the high half.
u64x2 cifra_hw_reduce_rev(u64x2 lo, u64x2 hi) {
    u64x2 t2 = lo;
    u64x2 t1 = lo;
    u64x2 x = lo << 5;
    t1 = t1 ^ x;
    x = x << 1;
    x = x ^ t1;
    x = x << 57;
    t1 = x;
    x = cast(u64x2, byte_shl(cast(i8x16, x), 8));
    t1 = cast(u64x2, byte_shr(cast(i8x16, t1), 8));
    x = x ^ t2;
    hi = hi ^ t1;
    t2 = x;
    x = x >> 1;
    hi = hi ^ t2;
    t2 = t2 ^ x;
    x = x >> 5;
    x = x ^ t2;
    x = x >> 1;
    return x ^ hi;
}

// a * b, both reflected, with b's halves XORed in `bk`.
u64x2 cifra_hw_mul_rev(u64x2 a, u64x2 b, u64x2 bk) {
    u64x2 lo = clmul(a, b, 0x00);
    u64x2 hi = clmul(a, b, 0x11);
    u64x2 mid = clmul(cifra_hw_halves_xor(a), bk, 0x00) ^ lo ^ hi;
    lo = lo ^ cast(u64x2, byte_shl(cast(i8x16, mid), 8));
    hi = hi ^ cast(u64x2, byte_shr(cast(i8x16, mid), 8));
    return cifra_hw_reduce_rev(lo, hi);
}

// H^1..H^nb into `hp` from H's bytes, then each one's halves XORed:
// reflected, with H shifted left one bit and reduced, which makes the
// reflected products come out aligned.
void cifra_hw_ghash_powers(u8* h, u8* hp, u64 nb) {
    u64x2 r = cifra_hw_load_rev(h);
    u64 lo = r.x;
    u64 hi = r.y;
    u64 carry = hi >> 63;
    hi = (hi << 1) | (lo >> 63);
    lo = lo << 1;
    if carry != 0 {
        lo = lo ^ 1;
        hi = hi ^ 0xC200000000000000;
    }
    u64x2 h1 = u64x2{lo, hi};
    u64x2 h1k = cifra_hw_halves_xor(h1);
    u64x2 pw = h1;
    for u64 k = 0; k < nb; k++ {
        u64x2_store(cast(u64*, hp + 16 * k), pw);
        u64x2_store(cast(u64*, hp + 16 * (nb + k)), cifra_hw_halves_xor(pw));
        if k + 1 < nb { pw = cifra_hw_mul_rev(pw, h1, h1k); }
    }
}

// cifra_hw_ghash for whole groups of 4 blocks, against H^4 down to H;
// returns Y and leaves the bytes past the last whole group to the caller.
// Written out block by block: the blocks' multiplies are independent, and
// a loop would add a branch and a counter to each.
u64x2 cifra_hw_ghash4(u64x2 y, u8* hp, u8* p, u64 n, u64* done) {
    i8x16 bswap = i8x16_load(&g_cifra_hw_bswap[0]);
    u64 i = 0;
    while i + 64 <= n {
        u8* q = p + i;
        u64x2 lo = u64x2{0, 0};
        u64x2 hi = u64x2{0, 0};
        u64x2 mid = u64x2{0, 0};
        u64x2 x0 = cast(u64x2, byte_shuffle(i8x16_load(cast(i8*, q + 0)), bswap)) ^ y;
        u64x2 h0 = u64x2_load(cast(u64*, hp + 48));
        u64x2 l0 = clmul(x0, h0, 0x00);
        u64x2 t0 = clmul(x0, h0, 0x11);
        lo = lo ^ l0;
        hi = hi ^ t0;
        mid = mid ^ clmul(cifra_hw_halves_xor(x0), u64x2_load(cast(u64*, hp + 112)), 0x00) ^ l0 ^ t0;
        u64x2 x1 = cast(u64x2, byte_shuffle(i8x16_load(cast(i8*, q + 16)), bswap));
        u64x2 h1 = u64x2_load(cast(u64*, hp + 32));
        u64x2 l1 = clmul(x1, h1, 0x00);
        u64x2 t1 = clmul(x1, h1, 0x11);
        lo = lo ^ l1;
        hi = hi ^ t1;
        mid = mid ^ clmul(cifra_hw_halves_xor(x1), u64x2_load(cast(u64*, hp + 96)), 0x00) ^ l1 ^ t1;
        u64x2 x2 = cast(u64x2, byte_shuffle(i8x16_load(cast(i8*, q + 32)), bswap));
        u64x2 h2 = u64x2_load(cast(u64*, hp + 16));
        u64x2 l2 = clmul(x2, h2, 0x00);
        u64x2 t2 = clmul(x2, h2, 0x11);
        lo = lo ^ l2;
        hi = hi ^ t2;
        mid = mid ^ clmul(cifra_hw_halves_xor(x2), u64x2_load(cast(u64*, hp + 80)), 0x00) ^ l2 ^ t2;
        u64x2 x3 = cast(u64x2, byte_shuffle(i8x16_load(cast(i8*, q + 48)), bswap));
        u64x2 h3 = u64x2_load(cast(u64*, hp + 0));
        u64x2 l3 = clmul(x3, h3, 0x00);
        u64x2 t3 = clmul(x3, h3, 0x11);
        lo = lo ^ l3;
        hi = hi ^ t3;
        mid = mid ^ clmul(cifra_hw_halves_xor(x3), u64x2_load(cast(u64*, hp + 64)), 0x00) ^ l3 ^ t3;
        lo = lo ^ cast(u64x2, byte_shl(cast(i8x16, mid), 8));
        hi = hi ^ cast(u64x2, byte_shr(cast(i8x16, mid), 8));
        y = cifra_hw_reduce_rev(lo, hi);
        i = i + 64;
    }
    *done = i;
    return y;
}

// cifra_hw_ghash for whole groups of 16 blocks, against H^16 down to H;
// returns Y and leaves the bytes past the last whole group to the caller.
// Written out block by block: the blocks' multiplies are independent, and
// a loop would add a branch and a counter to each.
u64x2 cifra_hw_ghash16(u64x2 y, u8* hp, u8* p, u64 n, u64* done) {
    i8x16 bswap = i8x16_load(&g_cifra_hw_bswap[0]);
    u64 i = 0;
    while i + 256 <= n {
        u8* q = p + i;
        u64x2 lo = u64x2{0, 0};
        u64x2 hi = u64x2{0, 0};
        u64x2 mid = u64x2{0, 0};
        u64x2 x0 = cast(u64x2, byte_shuffle(i8x16_load(cast(i8*, q + 0)), bswap)) ^ y;
        u64x2 h0 = u64x2_load(cast(u64*, hp + 240));
        u64x2 l0 = clmul(x0, h0, 0x00);
        u64x2 t0 = clmul(x0, h0, 0x11);
        lo = lo ^ l0;
        hi = hi ^ t0;
        mid = mid ^ clmul(cifra_hw_halves_xor(x0), u64x2_load(cast(u64*, hp + 496)), 0x00) ^ l0 ^ t0;
        u64x2 x1 = cast(u64x2, byte_shuffle(i8x16_load(cast(i8*, q + 16)), bswap));
        u64x2 h1 = u64x2_load(cast(u64*, hp + 224));
        u64x2 l1 = clmul(x1, h1, 0x00);
        u64x2 t1 = clmul(x1, h1, 0x11);
        lo = lo ^ l1;
        hi = hi ^ t1;
        mid = mid ^ clmul(cifra_hw_halves_xor(x1), u64x2_load(cast(u64*, hp + 480)), 0x00) ^ l1 ^ t1;
        u64x2 x2 = cast(u64x2, byte_shuffle(i8x16_load(cast(i8*, q + 32)), bswap));
        u64x2 h2 = u64x2_load(cast(u64*, hp + 208));
        u64x2 l2 = clmul(x2, h2, 0x00);
        u64x2 t2 = clmul(x2, h2, 0x11);
        lo = lo ^ l2;
        hi = hi ^ t2;
        mid = mid ^ clmul(cifra_hw_halves_xor(x2), u64x2_load(cast(u64*, hp + 464)), 0x00) ^ l2 ^ t2;
        u64x2 x3 = cast(u64x2, byte_shuffle(i8x16_load(cast(i8*, q + 48)), bswap));
        u64x2 h3 = u64x2_load(cast(u64*, hp + 192));
        u64x2 l3 = clmul(x3, h3, 0x00);
        u64x2 t3 = clmul(x3, h3, 0x11);
        lo = lo ^ l3;
        hi = hi ^ t3;
        mid = mid ^ clmul(cifra_hw_halves_xor(x3), u64x2_load(cast(u64*, hp + 448)), 0x00) ^ l3 ^ t3;
        u64x2 x4 = cast(u64x2, byte_shuffle(i8x16_load(cast(i8*, q + 64)), bswap));
        u64x2 h4 = u64x2_load(cast(u64*, hp + 176));
        u64x2 l4 = clmul(x4, h4, 0x00);
        u64x2 t4 = clmul(x4, h4, 0x11);
        lo = lo ^ l4;
        hi = hi ^ t4;
        mid = mid ^ clmul(cifra_hw_halves_xor(x4), u64x2_load(cast(u64*, hp + 432)), 0x00) ^ l4 ^ t4;
        u64x2 x5 = cast(u64x2, byte_shuffle(i8x16_load(cast(i8*, q + 80)), bswap));
        u64x2 h5 = u64x2_load(cast(u64*, hp + 160));
        u64x2 l5 = clmul(x5, h5, 0x00);
        u64x2 t5 = clmul(x5, h5, 0x11);
        lo = lo ^ l5;
        hi = hi ^ t5;
        mid = mid ^ clmul(cifra_hw_halves_xor(x5), u64x2_load(cast(u64*, hp + 416)), 0x00) ^ l5 ^ t5;
        u64x2 x6 = cast(u64x2, byte_shuffle(i8x16_load(cast(i8*, q + 96)), bswap));
        u64x2 h6 = u64x2_load(cast(u64*, hp + 144));
        u64x2 l6 = clmul(x6, h6, 0x00);
        u64x2 t6 = clmul(x6, h6, 0x11);
        lo = lo ^ l6;
        hi = hi ^ t6;
        mid = mid ^ clmul(cifra_hw_halves_xor(x6), u64x2_load(cast(u64*, hp + 400)), 0x00) ^ l6 ^ t6;
        u64x2 x7 = cast(u64x2, byte_shuffle(i8x16_load(cast(i8*, q + 112)), bswap));
        u64x2 h7 = u64x2_load(cast(u64*, hp + 128));
        u64x2 l7 = clmul(x7, h7, 0x00);
        u64x2 t7 = clmul(x7, h7, 0x11);
        lo = lo ^ l7;
        hi = hi ^ t7;
        mid = mid ^ clmul(cifra_hw_halves_xor(x7), u64x2_load(cast(u64*, hp + 384)), 0x00) ^ l7 ^ t7;
        u64x2 x8 = cast(u64x2, byte_shuffle(i8x16_load(cast(i8*, q + 128)), bswap));
        u64x2 h8 = u64x2_load(cast(u64*, hp + 112));
        u64x2 l8 = clmul(x8, h8, 0x00);
        u64x2 t8 = clmul(x8, h8, 0x11);
        lo = lo ^ l8;
        hi = hi ^ t8;
        mid = mid ^ clmul(cifra_hw_halves_xor(x8), u64x2_load(cast(u64*, hp + 368)), 0x00) ^ l8 ^ t8;
        u64x2 x9 = cast(u64x2, byte_shuffle(i8x16_load(cast(i8*, q + 144)), bswap));
        u64x2 h9 = u64x2_load(cast(u64*, hp + 96));
        u64x2 l9 = clmul(x9, h9, 0x00);
        u64x2 t9 = clmul(x9, h9, 0x11);
        lo = lo ^ l9;
        hi = hi ^ t9;
        mid = mid ^ clmul(cifra_hw_halves_xor(x9), u64x2_load(cast(u64*, hp + 352)), 0x00) ^ l9 ^ t9;
        u64x2 x10 = cast(u64x2, byte_shuffle(i8x16_load(cast(i8*, q + 160)), bswap));
        u64x2 h10 = u64x2_load(cast(u64*, hp + 80));
        u64x2 l10 = clmul(x10, h10, 0x00);
        u64x2 t10 = clmul(x10, h10, 0x11);
        lo = lo ^ l10;
        hi = hi ^ t10;
        mid = mid ^ clmul(cifra_hw_halves_xor(x10), u64x2_load(cast(u64*, hp + 336)), 0x00) ^ l10 ^ t10;
        u64x2 x11 = cast(u64x2, byte_shuffle(i8x16_load(cast(i8*, q + 176)), bswap));
        u64x2 h11 = u64x2_load(cast(u64*, hp + 64));
        u64x2 l11 = clmul(x11, h11, 0x00);
        u64x2 t11 = clmul(x11, h11, 0x11);
        lo = lo ^ l11;
        hi = hi ^ t11;
        mid = mid ^ clmul(cifra_hw_halves_xor(x11), u64x2_load(cast(u64*, hp + 320)), 0x00) ^ l11 ^ t11;
        u64x2 x12 = cast(u64x2, byte_shuffle(i8x16_load(cast(i8*, q + 192)), bswap));
        u64x2 h12 = u64x2_load(cast(u64*, hp + 48));
        u64x2 l12 = clmul(x12, h12, 0x00);
        u64x2 t12 = clmul(x12, h12, 0x11);
        lo = lo ^ l12;
        hi = hi ^ t12;
        mid = mid ^ clmul(cifra_hw_halves_xor(x12), u64x2_load(cast(u64*, hp + 304)), 0x00) ^ l12 ^ t12;
        u64x2 x13 = cast(u64x2, byte_shuffle(i8x16_load(cast(i8*, q + 208)), bswap));
        u64x2 h13 = u64x2_load(cast(u64*, hp + 32));
        u64x2 l13 = clmul(x13, h13, 0x00);
        u64x2 t13 = clmul(x13, h13, 0x11);
        lo = lo ^ l13;
        hi = hi ^ t13;
        mid = mid ^ clmul(cifra_hw_halves_xor(x13), u64x2_load(cast(u64*, hp + 288)), 0x00) ^ l13 ^ t13;
        u64x2 x14 = cast(u64x2, byte_shuffle(i8x16_load(cast(i8*, q + 224)), bswap));
        u64x2 h14 = u64x2_load(cast(u64*, hp + 16));
        u64x2 l14 = clmul(x14, h14, 0x00);
        u64x2 t14 = clmul(x14, h14, 0x11);
        lo = lo ^ l14;
        hi = hi ^ t14;
        mid = mid ^ clmul(cifra_hw_halves_xor(x14), u64x2_load(cast(u64*, hp + 272)), 0x00) ^ l14 ^ t14;
        u64x2 x15 = cast(u64x2, byte_shuffle(i8x16_load(cast(i8*, q + 240)), bswap));
        u64x2 h15 = u64x2_load(cast(u64*, hp + 0));
        u64x2 l15 = clmul(x15, h15, 0x00);
        u64x2 t15 = clmul(x15, h15, 0x11);
        lo = lo ^ l15;
        hi = hi ^ t15;
        mid = mid ^ clmul(cifra_hw_halves_xor(x15), u64x2_load(cast(u64*, hp + 256)), 0x00) ^ l15 ^ t15;
        lo = lo ^ cast(u64x2, byte_shl(cast(i8x16, mid), 8));
        hi = hi ^ cast(u64x2, byte_shr(cast(i8x16, mid), 8));
        y = cifra_hw_reduce_rev(lo, hi);
        i = i + 256;
    }
    *done = i;
    return y;
}

when defined(CIFRA_HW_256) {
// cifra_hw_ghash16 two blocks to an instruction: pair j is blocks 2j and
// 2j+1 in one 256-bit vector, against H^(16-2j) and H^(15-2j), whose
// products and Karatsuba middles add up lane by lane; the two lanes fold
// into one 256-bit product before the reduction, as the 128-bit form
// does. The powers are laid out in pairs first, high power in the low
// lane, since `hp` holds them in ascending order.
u64x2 cifra_hw_ghash16w(u64x2 y, u8* hp, u8* p, u64 n, u64* done) {
    u8[512] hw;
    for i32 j = 0; j < 8; j++ {
        i8x16_store(cast(i8*, &hw[32 * j]), i8x16_load(cast(i8*, hp + 16 * (15 - 2 * j))));
        i8x16_store(cast(i8*, &hw[32 * j + 16]), i8x16_load(cast(i8*, hp + 16 * (14 - 2 * j))));
        i8x16_store(cast(i8*, &hw[256 + 32 * j]), i8x16_load(cast(i8*, hp + 256 + 16 * (15 - 2 * j))));
        i8x16_store(cast(i8*, &hw[256 + 32 * j + 16]), i8x16_load(cast(i8*, hp + 256 + 16 * (14 - 2 * j))));
    }
    i8x16 bswap1 = i8x16_load(&g_cifra_hw_bswap[0]);
    i8x16 halves1 = i8x16_load(&g_cifra_hw_halves[0]);
    i8x32 bswap = i8x32_pack(bswap1, bswap1);
    i8x32 halves = i8x32_pack(halves1, halves1);
    i8x16 zero = cast(i8x16, u64x2{0, 0});
    u64 i = 0;
    while i + 256 <= n {
        u8* q = p + i;
        i8x32 lo = i8x32_pack(zero, zero);
        i8x32 hi = lo;
        i8x32 mid = lo;
        for i32 j = 0; j < 8; j++ {
            i8x32 x = byte_shuffle(i8x32_load(cast(i8*, q + 32 * j)), bswap);
            if j == 0 { x = x ^ i8x32_pack(cast(i8x16, y), zero); }
            i8x32 h = i8x32_load(cast(i8*, &hw[32 * j]));
            i8x32 l = clmul(x, h, 0x00);
            i8x32 t = clmul(x, h, 0x11);
            lo = lo ^ l;
            hi = hi ^ t;
            mid = mid ^ clmul(x ^ byte_shuffle(x, halves), i8x32_load(cast(i8*, &hw[256 + 32 * j])), 0x00) ^ l ^ t;
        }
        u64x2 lo1 = cast(u64x2, i8x32_lo(lo) ^ i8x32_hi(lo));
        u64x2 hi1 = cast(u64x2, i8x32_lo(hi) ^ i8x32_hi(hi));
        i8x16 mid1 = i8x32_lo(mid) ^ i8x32_hi(mid);
        lo1 = lo1 ^ cast(u64x2, byte_shl(mid1, 8));
        hi1 = hi1 ^ cast(u64x2, byte_shr(mid1, 8));
        y = cifra_hw_reduce_rev(lo1, hi1);
        i = i + 256;
    }
    *done = i;
    return y;
}
}

u64x2 cifra_hw_ghash(u64x2 y, u8* hp, u64 nb, u8* p, u64 n) {
    u64 i = 0;
    bool wide = false;
    when defined(CIFRA_HW_256) {
        if nb == 16 && cifra_hw_wide() {
            y = cifra_hw_ghash16w(y, hp, p, n, &i);
            wide = true;
        }
    }
    if wide { }
    else if nb == 16 { y = cifra_hw_ghash16(y, hp, p, n, &i); }
    else { y = cifra_hw_ghash4(y, hp, p, n, &i); }
    u64x2 h1 = u64x2_load(cast(u64*, hp));
    u64x2 h1k = u64x2_load(cast(u64*, hp + 16 * nb));
    i8x16 bswap = i8x16_load(&g_cifra_hw_bswap[0]);
    while i + 16 <= n {
        y = cifra_hw_mul_rev(y ^ cast(u64x2, byte_shuffle(i8x16_load(cast(i8*, p + i)), bswap)), h1, h1k);
        i = i + 16;
    }
    if i < n {
        u8[16] last;
        for i32 k = 0; k < 16; k++ { last[k] = 0; }
        for u64 k = 0; i + k < n; k++ { last[k] = *(p + i + k); }
        y = cifra_hw_mul_rev(y ^ cifra_hw_load_rev(&last[0]), h1, h1k);
    }
    return y;
}

// The powers a message of `n` bytes is hashed with: sixteen from 4 KB,
// where the reductions they save outweigh the multiplies that make them.
u64 cifra_hw_ghash_powers_for(u64 n) {
    if n >= 4096 { return 16; }
    return 4;
}

// Counter mode over `n` bytes, from `in` to `out` (which may be the same
// buffer), starting at counter `ctr`. A counter block is the 12-byte
// nonce in `j0` and the counter as 32 big-endian bits. The eight blocks of
// a group are made in registers: the block with its last four bytes
// reversed holds the counter as lane 3 of an int4, where it is added to,
// and one shuffle puts each block back in order. Blocks written to memory
// a byte at a time and read back whole would wait for the bytes to reach
// the cache.
void cifra_hw_ctr(u8* rk, u32 rounds, u8* j0, u32 ctr, u8* in, u8* out, u64 n) {
    u8[16] cb;
    for i32 k = 0; k < 12; k++ { cb[k] = *(j0 + k); }
    u8* last = rk + 16 * cast(u64, rounds);
    u64 i = 0;
    i8x16 rev = i8x16_load(&g_cifra_hw_ctr_rev[0]);
    cb[12] = cast(u8, ctr);
    cb[13] = cast(u8, ctr >> 8);
    cb[14] = cast(u8, ctr >> 16);
    cb[15] = cast(u8, ctr >> 24);
    int4 cv = cast(int4, i8x16_load(cast(i8*, &cb[0])));
    int4 one = int4{0, 0, 0, 1};
    // Sixteen blocks at a time, two to an instruction, where the 256-bit
    // arm is in use; the rest as below.
    when defined(CIFRA_HW_256) {
        if n >= 256 && cifra_hw_wide() {
            u8[480] rk2;                                 // each round key twice
            for u32 r = 0; r <= rounds; r++ {
                i8x16 k = i8x16_load(cast(i8*, rk + 16 * cast(u64, r)));
                i8x32_store(cast(i8*, &rk2[32 * r]), i8x32_pack(k, k));
            }
            u8* last2 = &rk2[32 * rounds];
            while i + 256 <= n {
                i8x32 k0 = i8x32_load(cast(i8*, &rk2[0]));
                i8x16 c0 = byte_shuffle(cast(i8x16, cv), rev); cv = cv + one;
                i8x16 c1 = byte_shuffle(cast(i8x16, cv), rev); cv = cv + one;
                i8x32 s0 = i8x32_pack(c0, c1) ^ k0;
                c0 = byte_shuffle(cast(i8x16, cv), rev); cv = cv + one;
                c1 = byte_shuffle(cast(i8x16, cv), rev); cv = cv + one;
                i8x32 s1 = i8x32_pack(c0, c1) ^ k0;
                c0 = byte_shuffle(cast(i8x16, cv), rev); cv = cv + one;
                c1 = byte_shuffle(cast(i8x16, cv), rev); cv = cv + one;
                i8x32 s2 = i8x32_pack(c0, c1) ^ k0;
                c0 = byte_shuffle(cast(i8x16, cv), rev); cv = cv + one;
                c1 = byte_shuffle(cast(i8x16, cv), rev); cv = cv + one;
                i8x32 s3 = i8x32_pack(c0, c1) ^ k0;
                c0 = byte_shuffle(cast(i8x16, cv), rev); cv = cv + one;
                c1 = byte_shuffle(cast(i8x16, cv), rev); cv = cv + one;
                i8x32 s4 = i8x32_pack(c0, c1) ^ k0;
                c0 = byte_shuffle(cast(i8x16, cv), rev); cv = cv + one;
                c1 = byte_shuffle(cast(i8x16, cv), rev); cv = cv + one;
                i8x32 s5 = i8x32_pack(c0, c1) ^ k0;
                c0 = byte_shuffle(cast(i8x16, cv), rev); cv = cv + one;
                c1 = byte_shuffle(cast(i8x16, cv), rev); cv = cv + one;
                i8x32 s6 = i8x32_pack(c0, c1) ^ k0;
                c0 = byte_shuffle(cast(i8x16, cv), rev); cv = cv + one;
                c1 = byte_shuffle(cast(i8x16, cv), rev); cv = cv + one;
                i8x32 s7 = i8x32_pack(c0, c1) ^ k0;
                ctr = ctr + 16;
                for u32 r = 1; r < rounds; r++ {
                    i8x32 k = i8x32_load(cast(i8*, &rk2[32 * r]));
                    s0 = aesenc(s0, k);
                    s1 = aesenc(s1, k);
                    s2 = aesenc(s2, k);
                    s3 = aesenc(s3, k);
                    s4 = aesenc(s4, k);
                    s5 = aesenc(s5, k);
                    s6 = aesenc(s6, k);
                    s7 = aesenc(s7, k);
                }
                i8x32 kl = i8x32_load(cast(i8*, last2));
                u8* ip = in + i;
                u8* op = out + i;
                i8x32_store(cast(i8*, op), aesenclast(s0, kl) ^ i8x32_load(cast(i8*, ip)));
                i8x32_store(cast(i8*, op + 32), aesenclast(s1, kl) ^ i8x32_load(cast(i8*, ip + 32)));
                i8x32_store(cast(i8*, op + 64), aesenclast(s2, kl) ^ i8x32_load(cast(i8*, ip + 64)));
                i8x32_store(cast(i8*, op + 96), aesenclast(s3, kl) ^ i8x32_load(cast(i8*, ip + 96)));
                i8x32_store(cast(i8*, op + 128), aesenclast(s4, kl) ^ i8x32_load(cast(i8*, ip + 128)));
                i8x32_store(cast(i8*, op + 160), aesenclast(s5, kl) ^ i8x32_load(cast(i8*, ip + 160)));
                i8x32_store(cast(i8*, op + 192), aesenclast(s6, kl) ^ i8x32_load(cast(i8*, ip + 192)));
                i8x32_store(cast(i8*, op + 224), aesenclast(s7, kl) ^ i8x32_load(cast(i8*, ip + 224)));
                i = i + 256;
            }
        }
    }
    while i + 128 <= n {
        i8x16 k0 = i8x16_load(cast(i8*, rk));
        i8x16 s0 = byte_shuffle(cast(i8x16, cv), rev) ^ k0;
        cv = cv + one;
        i8x16 s1 = byte_shuffle(cast(i8x16, cv), rev) ^ k0;
        cv = cv + one;
        i8x16 s2 = byte_shuffle(cast(i8x16, cv), rev) ^ k0;
        cv = cv + one;
        i8x16 s3 = byte_shuffle(cast(i8x16, cv), rev) ^ k0;
        cv = cv + one;
        i8x16 s4 = byte_shuffle(cast(i8x16, cv), rev) ^ k0;
        cv = cv + one;
        i8x16 s5 = byte_shuffle(cast(i8x16, cv), rev) ^ k0;
        cv = cv + one;
        i8x16 s6 = byte_shuffle(cast(i8x16, cv), rev) ^ k0;
        cv = cv + one;
        i8x16 s7 = byte_shuffle(cast(i8x16, cv), rev) ^ k0;
        cv = cv + one;
        ctr = ctr + 8;
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

// H's first `nb` powers into `hp`, the nonce into the first 12 bytes of
// `j0` (J0 itself, counter 1), and E_K(J0) into `ej0`, for a 96-bit nonce.
void cifra_hw_gcm_setup(u8* rk, u32 rounds, u8* nonce, u8* hp, u64 nb, u8* j0, u8* ej0) {
    u8[16] h;
    for i32 k = 0; k < 16; k++ { h[k] = 0; }
    cf_aes_hw_encrypt(rk, rounds, &h[0], &h[0]);
    cifra_hw_ghash_powers(&h[0], hp, nb);
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
void cifra_hw_gcm_tag(u64x2 y, u8* hp, u64 nb, u64 naad, u64 n, u8* ej0, u8* out) {
    u8[16] lens;
    u64 abits = naad * 8;
    u64 cbits = n * 8;
    for i32 k = 0; k < 8; k++ {
        lens[k] = cast(u8, abits >> cast(u64, 56 - 8 * k));
        lens[8 + k] = cast(u8, cbits >> cast(u64, 56 - 8 * k));
    }
    y = cifra_hw_ghash(y, hp, nb, &lens[0], 16);
    i8x16 t = byte_shuffle(cast(i8x16, y), i8x16_load(&g_cifra_hw_bswap[0])) ^ i8x16_load(cast(i8*, ej0));
    i8x16_store(cast(i8*, out), t);
}

// Encrypts `n` bytes of `plain` into `cipher` and writes `ntag` bytes of
// tag. Returns 1, or 0 without the hardware.
i32 cf_gcm_hw_seal(u8* rk, u32 rounds, u8* plain, u64 n, u8* aad, u64 naad,
                   u8* nonce, u8* cipher, u8* tag, u64 ntag) {
    if !cifra_hw_on() { return 0; }
    u8[CIFRA_HW_HP] hp;
    u8[16] j0;
    u8[16] ej0;
    u8[16] full;
    u64 nb = cifra_hw_ghash_powers_for(n + naad);
    cifra_hw_gcm_setup(rk, rounds, nonce, &hp[0], nb, &j0[0], &ej0[0]);
    u64x2 y = cifra_hw_ghash(u64x2{0, 0}, &hp[0], nb, aad, naad);
    // Encrypt and hash 4 KB at a time, so the hash reads the ciphertext
    // from the cache. Every piece but the last is whole blocks.
    u64 done = 0;
    u32 ctr = 2;
    while done < n {
        u64 m = n - done;
        if m > 4096 { m = 4096; }
        cifra_hw_ctr(rk, rounds, &j0[0], ctr, plain + done, cipher + done, m);
        y = cifra_hw_ghash(y, &hp[0], nb, cipher + done, m);
        ctr = ctr + cast(u32, m / 16);
        done = done + m;
    }
    cifra_hw_gcm_tag(y, &hp[0], nb, naad, n, &ej0[0], &full[0]);
    for u64 k = 0; k < ntag && k < 16; k++ { *(tag + k) = full[k]; }
    for i32 k = 0; k < CIFRA_HW_HP; k++ { hp[k] = 0; }
    for i32 k = 0; k < 16; k++ { ej0[k] = 0; full[k] = 0; }
    return 1;
}

// Checks the tag over `cipher`, then decrypts it into `plain`. Returns 0
// when the tag matches, 1 when it does not (and `plain` is untouched), or
// -1 without the hardware.
i32 cf_gcm_hw_open(u8* rk, u32 rounds, u8* cipher, u64 n, u8* aad, u64 naad,
                   u8* nonce, u8* tag, u64 ntag, u8* plain) {
    if !cifra_hw_on() { return 0 - 1; }
    u8[CIFRA_HW_HP] hp;
    u8[16] j0;
    u8[16] ej0;
    u8[16] full;
    u64 nb = cifra_hw_ghash_powers_for(n + naad);
    cifra_hw_gcm_setup(rk, rounds, nonce, &hp[0], nb, &j0[0], &ej0[0]);
    u64x2 y = cifra_hw_ghash(u64x2{0, 0}, &hp[0], nb, aad, naad);
    y = cifra_hw_ghash(y, &hp[0], nb, cipher, n);
    cifra_hw_gcm_tag(y, &hp[0], nb, naad, n, &ej0[0], &full[0]);
    // Compared without an early exit, so the time does not depend on
    // where the tags differ.
    u8 diff = 0;
    for u64 k = 0; k < ntag && k < 16; k++ { diff = diff | (full[k] ^ *(tag + k)); }
    i32 err = 1;
    if diff == 0 {
        cifra_hw_ctr(rk, rounds, &j0[0], 2, cipher, plain, n);
        err = 0;
    }
    for i32 k = 0; k < CIFRA_HW_HP; k++ { hp[k] = 0; }
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

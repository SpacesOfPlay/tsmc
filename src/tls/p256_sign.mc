// p256_sign.mc -- ECDSA P-256 signing with a fixed-base table.
//
// A signature's cost is the multiplication k*G of the base point by the
// nonce. micro-ecc does it with a ladder over the 256 bits of k, about
// sixteen field multiplications per bit. G never changes, so its
// multiples can be computed once: for each of the 64 four-bit digits of
// k, the affine points i * 16^j * G for i in 1..15 (960 points, 61 KB on
// the heap, built at the first signature). k*G is then the sum of one
// table entry per digit, 64 mixed additions of eleven field operations
// each, several times fewer than the ladder.
//
// The nonce is secret, so the table is read the same way whatever its
// digits are: every entry of a digit's row is loaded and the wanted one
// kept with masks, and a zero digit, like the sum's starting point at
// infinity, is handled by masks rather than branches. The additions never
// meet a special case: the sum before digit j is m*G with m < 16^j, which
// equals neither d*16^j*G nor its negative for any k < n.
//
// The arithmetic is this module's own, as micro-ecc keeps its field
// routines private: elements as eight 32-bit words, least significant
// first; a product as 64 exact 32x32 multiplications summed per column
// (a square as 36), reduced with the NIST method for p-256 (FIPS 186-4
// D.2.3); inversion in the field by a fixed addition chain of 255
// squarings and 12 multiplications (constant time), and of the nonce by
// binary extended GCD behind a random blinding factor, as micro-ecc does
// it. Products mod n are Montgomery multiplications. The table's rows
// are made affine with one inversion each (Montgomery's trick).
// p256_selftest checks the arithmetic against bit-at-a-time references.
// The output is micro-ecc's, r || s big-endian, so a signature from here
// verifies wherever micro-ecc's does.

import cstdlib_shim;
import picotls_shim;
import picotls_lib;
import picotls_bridges;

// p = 2^256 - 2^224 + 2^192 + 2^96 - 1
u32[8] P256_P = { 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0x00000000, 0x00000000, 0x00000000, 0x00000001, 0xFFFFFFFF };
// the group order
u32[8] P256_N = { 0xFC632551, 0xF3B9CAC2, 0xA7179E84, 0xBCE6FAAD, 0xFFFFFFFF, 0xFFFFFFFF, 0x00000000, 0xFFFFFFFF };
u32[8] P256_GX = { 0xD898C296, 0xF4A13945, 0x2DEB33A0, 0x77037D81, 0x63A440F2, 0xF8BCE6E5, 0xE12C4247, 0x6B17D1F2 };
u32[8] P256_GY = { 0x37BF51F5, 0xCBB64068, 0x6B315ECE, 0x2BCE3357, 0x7C0F9E16, 0x8EE7EB4A, 0xFE1A7F9B, 0x4FE342E2 };

const i32 P256_ROWS = 64;       // four-bit digits of a 256-bit scalar
const i32 P256_COLS = 15;       // nonzero digit values

// Row j, column i - 1: x then y of i * 16^j * G, 16 words.
private u32* p256_table = null;

// --- 256-bit words ---------------------------------------------------------

private void w_set(u32* r, u32* a) { for i32 i = 0; i < 8; i++ { r[i] = a[i]; } }
private void w_zero(u32* r) { for i32 i = 0; i < 8; i++ { r[i] = 0; } }

private bool w_is_zero(u32* a) {
    u32 x = 0;
    for i32 i = 0; i < 8; i++ { x = x | a[i]; }
    return x == 0;
}

// r = a + b; the carry out.
private u32 w_add(u32* r, u32* a, u32* b) {
    u64 c = 0;
    for i32 i = 0; i < 8; i++ {
        c = c + cast(u64, a[i]) + cast(u64, b[i]);
        r[i] = cast(u32, c);
        c = c >> 32;
    }
    return cast(u32, c);
}

// r = a - b; the borrow out.
private u32 w_sub(u32* r, u32* a, u32* b) {
    i64 c = 0;
    for i32 i = 0; i < 8; i++ {
        c = c + cast(i64, a[i]) - cast(i64, b[i]);
        r[i] = cast(u32, c);
        c = c >> 32;
    }
    return cast(u32, 0 - c);
}

// r = a where mask is all ones, else unchanged.
private void w_select(u32* r, u32* a, u32 mask) {
    for i32 i = 0; i < 8; i++ { r[i] = (r[i] & ~mask) | (a[i] & mask); }
}

// a >= m, without a branch on the values.
private u32 w_geq_mask(u32* a, u32* m) {
    u32[8] t;
    u32 borrow = w_sub(&t[0], a, m);
    return borrow - 1;              // all ones when no borrow
}

private void w_from_bytes(u32* r, u8* b) {
    for i32 i = 0; i < 8; i++ {
        u8* q = b + 28 - 4 * i;
        r[i] = (cast(u32, q[0]) << 24) | (cast(u32, q[1]) << 16) | (cast(u32, q[2]) << 8) | cast(u32, q[3]);
    }
}

private void w_to_bytes(u8* b, u32* a) {
    for i32 i = 0; i < 8; i++ {
        u8* q = b + 28 - 4 * i;
        q[0] = cast(u8, a[i] >> 24);
        q[1] = cast(u8, a[i] >> 16);
        q[2] = cast(u8, a[i] >> 8);
        q[3] = cast(u8, a[i]);
    }
}

// --- the field mod p -------------------------------------------------------

private void fe_add(u32* r, u32* a, u32* b) {
    u32 carry = w_add(r, a, b);
    u32[8] t;
    u32 borrow = w_sub(&t[0], r, &P256_P[0]);
    // subtract p when the sum carried out or is at least p
    u32 m = (cast(u32, 0) - carry) | (borrow - 1);
    w_select(r, &t[0], m);
}

private void fe_sub(u32* r, u32* a, u32* b) {
    u32 borrow = w_sub(r, a, b);
    u32[8] t;
    ignore w_add(&t[0], r, &P256_P[0]);
    w_select(r, &t[0], cast(u32, 0) - borrow);
}

// r = the 16-word product a * b: 64 exact 32x32 products, each split into
// its low and high halves summed in separate column accumulators, so no
// sum can overflow and nothing waits on a comparison.
private void w_mul_wide(u32* r, u32* a, u32* b) {
    u64[17] lo;
    u64[17] hi;
    for i32 k = 0; k < 17; k++ { lo[k] = 0; hi[k] = 0; }
    for i32 i = 0; i < 8; i++ {
        u64 ai = cast(u64, a[i]);
        for i32 j = 0; j < 8; j++ {
            u64 p = ai * cast(u64, b[j]);
            lo[i + j] = lo[i + j] + (p & 0xFFFFFFFF);
            hi[i + j + 1] = hi[i + j + 1] + (p >> 32);
        }
    }
    u64 c = 0;
    for i32 k = 0; k < 16; k++ {
        c = c + lo[k] + hi[k];
        r[k] = cast(u32, c);
        c = c >> 32;
    }
}

// r = the 16-word c mod p (FIPS 186-4 D.2.3): r = s1 + 2 s2 + 2 s3 + s4
// + s5 - s6 - s7 - s8 - s9, each s a rearrangement of c's words, summed
// per word with signed carries. What passes 2^256 is folded back with
// 2^256 = 2^224 - 2^192 - 2^96 + 1 (mod p), twice: after the second fold
// the top carry is -1, 0 or 1, and the value is below p after one masked
// addition of p (when negative) and one masked subtraction (when at or
// above p).
private void fe_reduce(u32* r, u32* c) {
    i64 c8 = cast(i64, c[8]); i64 c9 = cast(i64, c[9]); i64 c10 = cast(i64, c[10]); i64 c11 = cast(i64, c[11]);
    i64 c12 = cast(i64, c[12]); i64 c13 = cast(i64, c[13]); i64 c14 = cast(i64, c[14]); i64 c15 = cast(i64, c[15]);
    i64 t0 = cast(i64, c[0]) + c8 + c9 - c11 - c12 - c13 - c14;
    i64 t1 = cast(i64, c[1]) + c9 + c10 - c12 - c13 - c14 - c15;
    i64 t2 = cast(i64, c[2]) + c10 + c11 - c13 - c14 - c15;
    i64 t3 = cast(i64, c[3]) + 2 * c11 + 2 * c12 + c13 - c15 - c8 - c9;
    i64 t4 = cast(i64, c[4]) + 2 * c12 + 2 * c13 + c14 - c9 - c10;
    i64 t5 = cast(i64, c[5]) + 2 * c13 + 2 * c14 + c15 - c10 - c11;
    i64 t6 = cast(i64, c[6]) + 3 * c14 + 2 * c15 + c13 - c8 - c9;
    i64 t7 = cast(i64, c[7]) + 3 * c15 + c8 - c10 - c11 - c12 - c13;
    i64 k = 0;
    for i32 round = 0; round < 2; round++ {
        t1 = t1 + (t0 >> 32); t0 = t0 & 0xFFFFFFFF;
        t2 = t2 + (t1 >> 32); t1 = t1 & 0xFFFFFFFF;
        t3 = t3 + (t2 >> 32); t2 = t2 & 0xFFFFFFFF;
        t4 = t4 + (t3 >> 32); t3 = t3 & 0xFFFFFFFF;
        t5 = t5 + (t4 >> 32); t4 = t4 & 0xFFFFFFFF;
        t6 = t6 + (t5 >> 32); t5 = t5 & 0xFFFFFFFF;
        t7 = t7 + (t6 >> 32); t6 = t6 & 0xFFFFFFFF;
        k = t7 >> 32; t7 = t7 & 0xFFFFFFFF;
        t0 = t0 + k; t3 = t3 - k; t6 = t6 - k; t7 = t7 + k;
    }
    t1 = t1 + (t0 >> 32); t0 = t0 & 0xFFFFFFFF;
    t2 = t2 + (t1 >> 32); t1 = t1 & 0xFFFFFFFF;
    t3 = t3 + (t2 >> 32); t2 = t2 & 0xFFFFFFFF;
    t4 = t4 + (t3 >> 32); t3 = t3 & 0xFFFFFFFF;
    t5 = t5 + (t4 >> 32); t4 = t4 & 0xFFFFFFFF;
    t6 = t6 + (t5 >> 32); t5 = t5 & 0xFFFFFFFF;
    t7 = t7 + (t6 >> 32); t6 = t6 & 0xFFFFFFFF;
    i64 top = t7 >> 32; t7 = t7 & 0xFFFFFFFF;
    u32[8] v = { cast(u32, t0), cast(u32, t1), cast(u32, t2), cast(u32, t3),
                 cast(u32, t4), cast(u32, t5), cast(u32, t6), cast(u32, t7) };
    u32[8] w;
    ignore w_add(&w[0], &v[0], &P256_P[0]);
    w_select(&v[0], &w[0], cast(u32, top >> 63));
    u32 borrow = w_sub(&w[0], &v[0], &P256_P[0]);
    w_select(&v[0], &w[0], (borrow - 1) | (cast(u32, 0) - cast(u32, (top + 1) >> 1)));
    w_set(r, &v[0]);
}

private void fe_mul(u32* r, u32* a, u32* b) {
    u32[16] c;
    w_mul_wide(&c[0], a, b);
    fe_reduce(r, &c[0]);
}

// r = a^2: the products a[i] a[j] with i < j once and doubled, the
// squares once, 36 multiplications where a product takes 64.
private void fe_sqr(u32* r, u32* a) {
    u64[17] lo;
    u64[17] hi;
    for i32 k = 0; k < 17; k++ { lo[k] = 0; hi[k] = 0; }
    for i32 i = 0; i < 8; i++ {
        u64 ai = cast(u64, a[i]);
        for i32 j = i + 1; j < 8; j++ {
            u64 p = ai * cast(u64, a[j]);
            lo[i + j] = lo[i + j] + (p & 0xFFFFFFFF);
            hi[i + j + 1] = hi[i + j + 1] + (p >> 32);
        }
    }
    for i32 k = 0; k < 17; k++ { lo[k] = lo[k] * 2; hi[k] = hi[k] * 2; }
    for i32 i = 0; i < 8; i++ {
        u64 p = cast(u64, a[i]) * cast(u64, a[i]);
        lo[2 * i] = lo[2 * i] + (p & 0xFFFFFFFF);
        hi[2 * i + 1] = hi[2 * i + 1] + (p >> 32);
    }
    u32[16] c;
    u64 cy = 0;
    for i32 k = 0; k < 16; k++ {
        cy = cy + lo[k] + hi[k];
        c[k] = cast(u32, cy);
        cy = cy >> 32;
    }
    fe_reduce(r, &c[0]);
}

// x squared n times.
private void fe_sqr_n(u32* r, u32* a, i32 n) {
    w_set(r, a);
    for i32 i = 0; i < n; i++ { fe_sqr(r, r); }
}

// r = a^(p - 2) = 1/a, by a fixed addition chain: 255
// squarings and 12 multiplications, the same whatever a is.
private void fe_inv(u32* r, u32* z) {
    u32[8] t10; u32[8] t11; u32[8] t111; u32[8] t111111; u32[8] x12; u32[8] x15; u32[8] x16;
    u32[8] x32; u32[8] i53; u32[8] x47; u32[8] t;
    fe_sqr(&t10[0], z);
    fe_mul(&t11[0], &t10[0], z);
    fe_sqr(&t[0], &t11[0]);
    fe_mul(&t111[0], &t[0], z);
    fe_sqr_n(&t[0], &t111[0], 3);
    fe_mul(&t111111[0], &t111[0], &t[0]);
    fe_sqr_n(&t[0], &t111111[0], 6);
    fe_mul(&x12[0], &t[0], &t111111[0]);
    fe_sqr_n(&t[0], &x12[0], 3);
    fe_mul(&x15[0], &t[0], &t111[0]);
    fe_sqr(&t[0], &x15[0]);
    fe_mul(&x16[0], &t[0], z);
    fe_sqr_n(&t[0], &x16[0], 16);
    fe_mul(&x32[0], &t[0], &x16[0]);
    fe_sqr_n(&i53[0], &x32[0], 15);
    fe_mul(&x47[0], &x15[0], &i53[0]);
    fe_sqr_n(&t[0], &i53[0], 17);
    fe_mul(&t[0], &t[0], z);
    fe_sqr_n(&t[0], &t[0], 143);
    fe_mul(&t[0], &t[0], &x47[0]);
    fe_sqr_n(&t[0], &t[0], 47);
    fe_mul(&t[0], &x47[0], &t[0]);
    fe_sqr_n(&t[0], &t[0], 2);
    fe_mul(r, &t[0], z);
}

// --- the curve ---------------------------------------------------------------

// Doubles the Jacobian point (x, y, z) in place (dbl-2001-b, a = -3).
private void jac_double(u32* x, u32* y, u32* z) {
    u32[8] delta; u32[8] gamma; u32[8] beta; u32[8] alpha; u32[8] t; u32[8] u;
    fe_sqr(&delta[0], z);
    fe_sqr(&gamma[0], y);
    fe_mul(&beta[0], x, &gamma[0]);
    fe_sub(&t[0], x, &delta[0]);
    fe_add(&u[0], x, &delta[0]);
    fe_mul(&alpha[0], &t[0], &u[0]);
    fe_add(&t[0], &alpha[0], &alpha[0]);
    fe_add(&alpha[0], &t[0], &alpha[0]);                     // 3 (x - delta)(x + delta)
    fe_add(&t[0], y, z);
    fe_sqr(&u[0], &t[0]);
    fe_sub(&u[0], &u[0], &gamma[0]);
    fe_sub(z, &u[0], &delta[0]);                             // z3 = (y + z)^2 - gamma - delta
    fe_add(&t[0], &beta[0], &beta[0]);
    fe_add(&t[0], &t[0], &t[0]);                             // 4 beta
    fe_sqr(&u[0], &alpha[0]);
    fe_sub(&u[0], &u[0], &t[0]);
    fe_sub(x, &u[0], &t[0]);                                 // x3 = alpha^2 - 8 beta
    fe_sub(&t[0], &t[0], x);
    fe_mul(&u[0], &alpha[0], &t[0]);
    fe_sqr(&t[0], &gamma[0]);
    fe_add(&t[0], &t[0], &t[0]);
    fe_add(&t[0], &t[0], &t[0]);
    fe_add(&t[0], &t[0], &t[0]);
    fe_sub(y, &u[0], &t[0]);                                 // y3 = alpha (4 beta - x3) - 8 gamma^2
}

// Adds the affine point (ax, ay) to the Jacobian point (x, y, z) in place
// (madd-2007-bl). The two must differ and neither be at infinity.
private void jac_add_affine(u32* x, u32* y, u32* z, u32* ax, u32* ay) {
    u32[8] z1z1; u32[8] u2; u32[8] s2; u32[8] h; u32[8] hh; u32[8] i; u32[8] j; u32[8] r; u32[8] v; u32[8] t;
    fe_sqr(&z1z1[0], z);
    fe_mul(&u2[0], ax, &z1z1[0]);
    fe_mul(&t[0], z, &z1z1[0]);
    fe_mul(&s2[0], ay, &t[0]);
    fe_sub(&h[0], &u2[0], x);
    fe_sqr(&hh[0], &h[0]);
    fe_add(&i[0], &hh[0], &hh[0]);
    fe_add(&i[0], &i[0], &i[0]);                             // 4 HH
    fe_mul(&j[0], &h[0], &i[0]);
    fe_sub(&r[0], &s2[0], y);
    fe_add(&r[0], &r[0], &r[0]);
    fe_mul(&v[0], x, &i[0]);
    fe_sqr(&t[0], &r[0]);
    fe_sub(&t[0], &t[0], &j[0]);
    fe_sub(&t[0], &t[0], &v[0]);
    fe_sub(&t[0], &t[0], &v[0]);                             // x3 = r^2 - J - 2V
    u32[8] zs;
    fe_add(&zs[0], z, &h[0]);
    fe_sqr(&zs[0], &zs[0]);
    fe_sub(&zs[0], &zs[0], &z1z1[0]);
    fe_sub(z, &zs[0], &hh[0]);                               // z3 = (z + H)^2 - Z1Z1 - HH
    fe_sub(&v[0], &v[0], &t[0]);
    fe_mul(&v[0], &r[0], &v[0]);
    fe_mul(&j[0], y, &j[0]);
    fe_add(&j[0], &j[0], &j[0]);
    fe_sub(y, &v[0], &j[0]);                                 // y3 = r (V - x3) - 2 y J
    w_set(x, &t[0]);
}

private void jac_to_affine(u32* ax, u32* ay, u32* x, u32* y, u32* z) {
    u32[8] zi; u32[8] zi2; u32[8] zi3;
    fe_inv(&zi[0], z);
    fe_sqr(&zi2[0], &zi[0]);
    fe_mul(&zi3[0], &zi2[0], &zi[0]);
    fe_mul(ax, x, &zi2[0]);
    fe_mul(ay, y, &zi3[0]);
}

// Builds the table; false when the heap cannot hold it. A row's fifteen
// points are found in Jacobian form and made affine with one inversion
// (Montgomery's trick: invert the product of the z's, then peel each off).
// Nothing here is secret, so ordinary branches are fine.
private bool p256_table_build() {
    if p256_table != null { return true; }
    u32* t = alloc<u32>(P256_ROWS * P256_COLS * 16);
    if t == null { return false; }
    u32* jx = alloc<u32>(P256_COLS * 8);
    u32* jy = alloc<u32>(P256_COLS * 8);
    u32* jz = alloc<u32>(P256_COLS * 8);
    u32* pre = alloc<u32>(P256_COLS * 8);
    defer free(jx);
    defer free(jy);
    defer free(jz);
    defer free(pre);
    u32[8] bx; u32[8] by;                  // 16^j * G, affine
    w_set(&bx[0], &P256_GX[0]);
    w_set(&by[0], &P256_GY[0]);
    for i32 row = 0; row < P256_ROWS; row++ {
        // i * base for i = 1..15: 1 the base, 2 its double, the rest sums.
        u32[8] x; u32[8] y; u32[8] z;
        w_set(&x[0], &bx[0]);
        w_set(&y[0], &by[0]);
        w_zero(&z[0]);
        z[0] = 1;
        for i32 col = 0; col < P256_COLS; col++ {
            w_set(jx + col * 8, &x[0]);
            w_set(jy + col * 8, &y[0]);
            w_set(jz + col * 8, &z[0]);
            if col == 0 { jac_double(&x[0], &y[0], &z[0]); }
            else { jac_add_affine(&x[0], &y[0], &z[0], &bx[0], &by[0]); }
        }
        // 16 * base, the next row's, from the 15th point plus the base.
        u32[8] nx; u32[8] ny; u32[8] nz;
        w_set(&nx[0], &x[0]);
        w_set(&ny[0], &y[0]);
        w_set(&nz[0], &z[0]);
        // pre[i] = z_0 * ... * z_i
        w_set(pre, jz);
        for i32 col = 1; col < P256_COLS; col++ { fe_mul(pre + col * 8, pre + (col - 1) * 8, jz + col * 8); }
        u32[8] inv;
        fe_inv(&inv[0], pre + (P256_COLS - 1) * 8);
        for i32 col = P256_COLS - 1; col >= 0; col-- {
            u32[8] zi;
            if col > 0 {
                fe_mul(&zi[0], &inv[0], pre + (col - 1) * 8);
                fe_mul(&inv[0], &inv[0], jz + col * 8);
            } else {
                w_set(&zi[0], &inv[0]);
            }
            u32[8] zi2; u32[8] zi3;
            fe_sqr(&zi2[0], &zi[0]);
            fe_mul(&zi3[0], &zi2[0], &zi[0]);
            u32* e = t + (row * P256_COLS + col) * 16;
            fe_mul(e, jx + col * 8, &zi2[0]);
            fe_mul(e + 8, jy + col * 8, &zi3[0]);
        }
        jac_to_affine(&bx[0], &by[0], &nx[0], &ny[0], &nz[0]);
    }
    p256_table = t;
    return true;
}

// All ones when a == b, else zero, without a branch (a, b < 2^31).
private u32 mask_eq(u32 a, u32 b) {
    u32 x = a ^ b;
    return cast(u32, 0) - ((x - 1) >> 31);
}

// (ax, ay) = k * G, affine; k in [1, n - 1]. False when the table could
// not be built.
bool p256_base_mult(u32* ax, u32* ay, u32* k) {
    if !p256_table_build() { return false; }
    u32[8] x; u32[8] y; u32[8] z;
    w_zero(&x[0]);
    w_zero(&y[0]);
    w_zero(&z[0]);
    u32[8] one;
    w_zero(&one[0]);
    one[0] = 1;
    u32 empty = cast(u32, 0) - 1;          // all ones while the sum is at infinity
    for i32 row = 0; row < P256_ROWS; row++ {
        u32 d = (k[row / 8] >> cast(u32, (row % 8) * 4)) & 15;
        // The entry for d, read by scanning the whole row.
        u32[16] e;
        for i32 w = 0; w < 16; w++ { e[w] = 0; }
        u32* rowp = p256_table + row * P256_COLS * 16;
        for i32 col = 0; col < P256_COLS; col++ {
            u32 m = mask_eq(d, cast(u32, col + 1));
            u32* src = rowp + col * 16;
            for i32 w = 0; w < 16; w++ { e[w] = e[w] | (src[w] & m); }
        }
        // The sum with the entry, kept only when d is nonzero; while the
        // sum is at infinity it becomes the entry itself.
        u32[8] nx; u32[8] ny; u32[8] nz;
        w_set(&nx[0], &x[0]);
        w_set(&ny[0], &y[0]);
        w_set(&nz[0], &z[0]);
        jac_add_affine(&nx[0], &ny[0], &nz[0], &e[0], &e[8]);
        u32 take = ~mask_eq(d, 0);
        u32 fresh = take & empty;
        u32 add = take & ~empty;
        w_select(&x[0], &nx[0], add);
        w_select(&y[0], &ny[0], add);
        w_select(&z[0], &nz[0], add);
        w_select(&x[0], &e[0], fresh);
        w_select(&y[0], &e[8], fresh);
        w_select(&z[0], &one[0], fresh);
        empty = empty & ~take;
    }
    jac_to_affine(ax, ay, &x[0], &y[0], &z[0]);
    return true;
}

// --- scalars mod n -----------------------------------------------------------

// r = the 16-word c mod n, by long division one bit at a time; the same
// operations whatever c is.
private void sc_reduce_wide(u32* r, u32* c) {
    u32[9] a;                              // the remainder, one word of headroom
    for i32 i = 0; i < 9; i++ { a[i] = 0; }
    u32[9] n9;
    for i32 i = 0; i < 8; i++ { n9[i] = P256_N[i]; }
    n9[8] = 0;
    for i32 bit = 511; bit >= 0; bit-- {
        // a = 2a + the next bit
        for i32 i = 8; i > 0; i-- { a[i] = (a[i] << 1) | (a[i - 1] >> 31); }
        a[0] = (a[0] << 1) | ((c[bit / 32] >> cast(u32, bit % 32)) & 1);
        // a -= n when a >= n
        u32[9] t;
        i64 br = 0;
        for i32 i = 0; i < 9; i++ {
            br = br + cast(i64, a[i]) - cast(i64, n9[i]);
            t[i] = cast(u32, br);
            br = br >> 32;
        }
        u32 m = cast(u32, br + 1) * 0xFFFFFFFF;    // all ones when no borrow
        for i32 i = 0; i < 9; i++ { a[i] = (a[i] & ~m) | (t[i] & m); }
    }
    for i32 i = 0; i < 8; i++ { r[i] = a[i]; }
}

// Montgomery multiplication mod n (CIOS, 32-bit words): r = a b / 2^256
// mod n. A product needs two of them, the second by 2^512 mod n.
private u32[8] p256_r2 = { 0, 0, 0, 0, 0, 0, 0, 0 };   // 2^512 mod n
private u32 p256_n0 = 0;                                // -1/n mod 2^32
private bool p256_mont_ready = false;

private void mont_mul(u32* r, u32* a, u32* b) {
    u64[10] t;
    for i32 i = 0; i < 10; i++ { t[i] = 0; }
    for i32 i = 0; i < 8; i++ {
        u64 c = 0;
        u64 bi = cast(u64, b[i]);
        for i32 j = 0; j < 8; j++ {
            c = t[j] + cast(u64, a[j]) * bi + c;
            t[j] = c & 0xFFFFFFFF;
            c = c >> 32;
        }
        c = t[8] + c;
        t[8] = c & 0xFFFFFFFF;
        t[9] = c >> 32;
        u64 m = (t[0] * cast(u64, p256_n0)) & 0xFFFFFFFF;
        c = (t[0] + m * cast(u64, P256_N[0])) >> 32;
        for i32 j = 1; j < 8; j++ {
            c = t[j] + m * cast(u64, P256_N[j]) + c;
            t[j - 1] = c & 0xFFFFFFFF;
            c = c >> 32;
        }
        c = t[8] + c;
        t[7] = c & 0xFFFFFFFF;
        t[8] = t[9] + (c >> 32);
    }
    u32[8] v;
    for i32 i = 0; i < 8; i++ { v[i] = cast(u32, t[i]); }
    u32[8] w;
    u32 borrow = w_sub(&w[0], &v[0], &P256_N[0]);
    w_select(&v[0], &w[0], (borrow - 1) | (cast(u32, 0) - cast(u32, t[8])));
    w_set(r, &v[0]);
}

private void mont_init() {
    if p256_mont_ready { return; }
    // -1/n mod 2^32 by Newton's iteration: each step doubles the bits.
    u32 inv = P256_N[0];
    for i32 i = 0; i < 5; i++ { inv = inv * (2 - P256_N[0] * inv); }
    p256_n0 = cast(u32, 0) - inv;
    // 2^256 mod n is 2^256 - n; its square mod n is 2^512 mod n.
    u32[8] rm;
    u32[8] zero;
    w_zero(&zero[0]);
    ignore w_sub(&rm[0], &zero[0], &P256_N[0]);
    u32[16] c;
    w_mul_wide(&c[0], &rm[0], &rm[0]);
    sc_reduce_wide(&p256_r2[0], &c[0]);
    p256_mont_ready = true;
}

// r = a b mod n.
private void sc_mul(u32* r, u32* a, u32* b) {
    mont_init();
    u32[8] t;
    mont_mul(&t[0], a, b);
    mont_mul(r, &t[0], &p256_r2[0]);
}

private void sc_add(u32* r, u32* a, u32* b) {
    u32 carry = w_add(r, a, b);
    u32[8] t;
    u32 borrow = w_sub(&t[0], r, &P256_N[0]);
    w_select(r, &t[0], (cast(u32, 0) - carry) | (borrow - 1));
}

private void w_shr1(u32* a, u32 top) {
    for i32 i = 0; i < 7; i++ { a[i] = (a[i] >> 1) | (a[i + 1] << 31); }
    a[7] = (a[7] >> 1) | (top << 31);
}

// x / 2 mod m, for the extended GCD below.
private void inv_half(u32* x, u32* m) {
    u32 carry = 0;
    if (x[0] & 1) != 0 { carry = w_add(x, x, m); }
    w_shr1(x, carry);
}

// r = 1/a mod m, by binary extended GCD (micro-ecc's uECC_vli_modInv). Its
// time depends on a, so a caller with a secret blinds it first.
private void sc_inv(u32* r, u32* a, u32* m) {
    if w_is_zero(a) { w_zero(r); return; }
    u32[8] u; u32[8] v; u32[8] x1; u32[8] x2;
    w_set(&u[0], a);
    w_set(&v[0], m);
    w_zero(&x1[0]);
    x1[0] = 1;
    w_zero(&x2[0]);
    while true {
        u32[8] d;
        u32 lt = w_sub(&d[0], &u[0], &v[0]);            // u < v
        if lt == 0 && w_is_zero(&d[0]) { break; }       // u == v
        if (u[0] & 1) == 0 {
            w_shr1(&u[0], 0);
            inv_half(&x1[0], m);
        } else if (v[0] & 1) == 0 {
            w_shr1(&v[0], 0);
            inv_half(&x2[0], m);
        } else if lt == 0 {
            ignore w_sub(&u[0], &u[0], &v[0]);
            w_shr1(&u[0], 0);
            if w_sub(&d[0], &x1[0], &x2[0]) != 0 { ignore w_add(&x1[0], &x1[0], m); }
            ignore w_sub(&x1[0], &x1[0], &x2[0]);
            inv_half(&x1[0], m);
        } else {
            ignore w_sub(&v[0], &v[0], &u[0]);
            w_shr1(&v[0], 0);
            if w_sub(&d[0], &x2[0], &x1[0]) != 0 { ignore w_add(&x2[0], &x2[0], m); }
            ignore w_sub(&x2[0], &x2[0], &x1[0]);
            inv_half(&x2[0], m);
        }
    }
    w_set(r, &x1[0]);
}

// A uniform random scalar in [1, n - 1].
private void sc_random(u32* r) {
    while true {
        u8[32] b;
        mc_csprng_bytes(cast(void*, &b[0]), 32);
        w_from_bytes(r, &b[0]);
        if !w_is_zero(r) && w_geq_mask(r, &P256_N[0]) == 0 { return; }
    }
}

// ECDSA P-256 as micro-ecc's uECC_sign: private_key and message_hash
// big-endian, signature r || s (64 bytes). 1 on success; 0 when the
// hash is not 32 bytes or the table cannot be built, which the caller
// meets with micro-ecc's own signing.
i32 p256_sign(u8* private_key, u8* message_hash, u32 hash_size, u8* signature) {
    if hash_size != 32 { return 0; }
    for i32 tries = 0; tries < 64; tries++ {
        u32[8] k;
        sc_random(&k[0]);
        u32[8] px; u32[8] py;
        if !p256_base_mult(&px[0], &py[0], &k[0]) { return 0; }
        // r = x mod n
        u32[8] t;
        u32 borrow = w_sub(&t[0], &px[0], &P256_N[0]);
        w_select(&px[0], &t[0], borrow - 1);
        if w_is_zero(&px[0]) { continue; }
        // 1/k, blinded by a random factor so the inversion's time says
        // nothing about k.
        u32[8] b;
        sc_random(&b[0]);
        sc_mul(&k[0], &k[0], &b[0]);
        sc_inv(&k[0], &k[0], &P256_N[0]);
        sc_mul(&k[0], &k[0], &b[0]);
        // s = (e + r d) / k
        u32[8] d; u32[8] e; u32[8] s;
        w_from_bytes(&d[0], private_key);
        sc_mul(&s[0], &d[0], &px[0]);
        w_from_bytes(&e[0], message_hash);
        u32 eb = w_sub(&t[0], &e[0], &P256_N[0]);
        w_select(&e[0], &t[0], eb - 1);                   // e mod n
        sc_add(&s[0], &e[0], &s[0]);
        sc_mul(&s[0], &s[0], &k[0]);
        w_zero(&d[0]);
        w_zero(&k[0]);
        if w_is_zero(&s[0]) { continue; }
        w_to_bytes(signature, &px[0]);
        w_to_bytes(signature + 32, &s[0]);
        return 1;
    }
    return 0;
}

// --- a self-test ---------------------------------------------------------------

// r = the 16-word c mod m, one bit at a time (the reference).
private void ref_reduce(u32* r, u32* c, u32* m) {
    u32[9] a;
    for i32 i = 0; i < 9; i++ { a[i] = 0; }
    for i32 bit = 511; bit >= 0; bit-- {
        for i32 i = 8; i > 0; i-- { a[i] = (a[i] << 1) | (a[i - 1] >> 31); }
        a[0] = (a[0] << 1) | ((c[bit / 32] >> cast(u32, bit % 32)) & 1);
        u32[9] t;
        i64 br = 0;
        for i32 i = 0; i < 9; i++ {
            br = br + cast(i64, a[i]) - cast(i64, i < 8 ? m[i] : cast(u32, 0));
            t[i] = cast(u32, br);
            br = br >> 32;
        }
        if br == 0 { for i32 i = 0; i < 9; i++ { a[i] = t[i]; } }
    }
    for i32 i = 0; i < 8; i++ { r[i] = a[i]; }
}

private bool w_eq(u32* a, u32* b) {
    for i32 i = 0; i < 8; i++ { if a[i] != b[i] { return false; } }
    return true;
}

// The field and scalar arithmetic against the references, on `rounds`
// random operands and on the values near 0, p and n where carries and
// reductions are most likely to go wrong. The number of mismatches.
i32 p256_selftest(i32 rounds) {
    i32 bad = 0;
    u32[8] pm1; u32[8] nm1; u32[8] one; u32[8] ones;
    w_set(&pm1[0], &P256_P[0]);
    pm1[0] = pm1[0] - 1;
    w_set(&nm1[0], &P256_N[0]);
    nm1[0] = nm1[0] - 1;
    w_zero(&one[0]);
    one[0] = 1;
    for i32 i = 0; i < 8; i++ { ones[i] = 0xFFFFFFFF; }
    for i32 r = 0; r < rounds; r++ {
        u32[8] a; u32[8] b;
        u8[32] ra; u8[32] rb;
        mc_csprng_bytes(cast(void*, &ra[0]), 32);
        mc_csprng_bytes(cast(void*, &rb[0]), 32);
        w_from_bytes(&a[0], &ra[0]);
        w_from_bytes(&b[0], &rb[0]);
        if r % 4 == 1 { w_set(&a[0], &pm1[0]); }
        if r % 4 == 2 { w_set(&b[0], &pm1[0]); w_set(&a[0], &pm1[0]); }
        if r % 8 == 3 { w_set(&a[0], &one[0]); }
        if r % 16 == 5 { a[0] = 0; a[1] = 0; a[2] = 0; a[3] = 0xFFFFFFFF; }
        // field operands below p
        u32[8] t;
        if w_sub(&t[0], &a[0], &P256_P[0]) == 0 { w_set(&a[0], &t[0]); }
        if w_sub(&t[0], &b[0], &P256_P[0]) == 0 { w_set(&b[0], &t[0]); }
        u32[16] c;
        u32[8] want; u32[8] got;
        w_mul_wide(&c[0], &a[0], &b[0]);
        ref_reduce(&want[0], &c[0], &P256_P[0]);
        fe_mul(&got[0], &a[0], &b[0]);
        if !w_eq(&want[0], &got[0]) { bad++; }
        w_mul_wide(&c[0], &a[0], &a[0]);
        ref_reduce(&want[0], &c[0], &P256_P[0]);
        fe_sqr(&got[0], &a[0]);
        if !w_eq(&want[0], &got[0]) { bad++; }
        if !w_is_zero(&a[0]) {
            fe_inv(&got[0], &a[0]);
            fe_mul(&got[0], &got[0], &a[0]);
            if !w_eq(&got[0], &one[0]) { bad++; }
        }
        // scalars below n
        if w_sub(&t[0], &a[0], &P256_N[0]) == 0 { w_set(&a[0], &t[0]); }
        if w_sub(&t[0], &b[0], &P256_N[0]) == 0 { w_set(&b[0], &t[0]); }
        if r % 4 == 3 { w_set(&b[0], &nm1[0]); }
        w_mul_wide(&c[0], &a[0], &b[0]);
        ref_reduce(&want[0], &c[0], &P256_N[0]);
        sc_mul(&got[0], &a[0], &b[0]);
        if !w_eq(&want[0], &got[0]) { bad++; }
        sc_reduce_wide(&got[0], &c[0]);
        if !w_eq(&want[0], &got[0]) { bad++; }
        if !w_is_zero(&a[0]) {
            sc_inv(&got[0], &a[0], &P256_N[0]);
            sc_mul(&got[0], &got[0], &a[0]);
            if !w_eq(&got[0], &one[0]) { bad++; }
        }
        // the largest products: every word all ones is 2^256 - 1
        if r == 0 {
            w_mul_wide(&c[0], &ones[0], &ones[0]);
            ref_reduce(&want[0], &c[0], &P256_P[0]);
            fe_reduce(&got[0], &c[0]);
            if !w_eq(&want[0], &got[0]) { bad++; }
        }
    }
    return bad;
}

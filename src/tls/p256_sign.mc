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
// routines private: elements as four 64-bit words, least significant
// first; a product as 16 exact 64x64 multiplications (`*` for the low
// half, `mulhi` for the high), a square as 10, reduced with the NIST
// method for p-256 (FIPS 186-4 D.2.3) over the 32-bit halves of the
// words; inversion in the field by a fixed addition chain of 255
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
u64[4] P256_P = { 0xFFFFFFFFFFFFFFFF, 0x00000000FFFFFFFF, 0x0000000000000000, 0xFFFFFFFF00000001 };
// the group order
u64[4] P256_N = { 0xF3B9CAC2FC632551, 0xBCE6FAADA7179E84, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFF00000000 };
u64[4] P256_GX = { 0xF4A13945D898C296, 0x77037D812DEB33A0, 0xF8BCE6E563A440F2, 0x6B17D1F2E12C4247 };
u64[4] P256_GY = { 0xCBB6406837BF51F5, 0x2BCE33576B315ECE, 0x8EE7EB4A7C0F9E16, 0x4FE342E2FE1A7F9B };

const i32 P256_ROWS = 64;       // four-bit digits of a 256-bit scalar
const i32 P256_COLS = 15;       // nonzero digit values

// Row j, column i - 1: x then y of i * 16^j * G, 8 words.
private u64* p256_table = null;

// --- 256-bit words ---------------------------------------------------------

private void w_set(u64* r, u64* a) { for i32 i = 0; i < 4; i++ { r[i] = a[i]; } }
private void w_zero(u64* r) { for i32 i = 0; i < 4; i++ { r[i] = 0; } }

private bool w_is_zero(u64* a) {
    u64 x = 0;
    for i32 i = 0; i < 4; i++ { x = x | a[i]; }
    return x == 0;
}

// r = a + b; the carry out. A carry is found by comparison: a sum
// below one of its operands wrapped.
private u64 w_add(u64* r, u64* a, u64* b) {
    u64 c = 0;
    for i32 i = 0; i < 4; i++ {
        u64 s = a[i] + b[i];
        u64 k = cast(u64, s < a[i]);
        u64 t = s + c;
        c = k + cast(u64, t < s);
        r[i] = t;
    }
    return c;
}

// r = a - b; the borrow out.
private u64 w_sub(u64* r, u64* a, u64* b) {
    u64 br = 0;
    for i32 i = 0; i < 4; i++ {
        u64 d = a[i] - b[i];
        u64 k = cast(u64, a[i] < b[i]);
        u64 t = d - br;
        br = k + cast(u64, d < br);
        r[i] = t;
    }
    return br;
}

// r = a where mask is all ones, else unchanged.
private void w_select(u64* r, u64* a, u64 mask) {
    for i32 i = 0; i < 4; i++ { r[i] = (r[i] & ~mask) | (a[i] & mask); }
}

// a >= m, without a branch on the values.
private u64 w_geq_mask(u64* a, u64* m) {
    u64[4] t;
    u64 borrow = w_sub(&t[0], a, m);
    return borrow - 1;              // all ones when no borrow
}

private void w_from_bytes(u64* r, u8* b) {
    for i32 i = 0; i < 4; i++ {
        u8* q = b + 24 - 8 * i;
        u64 w = 0;
        for i32 k = 0; k < 8; k++ { w = (w << 8) | cast(u64, q[k]); }
        r[i] = w;
    }
}

private void w_to_bytes(u8* b, u64* a) {
    for i32 i = 0; i < 4; i++ {
        u8* q = b + 24 - 8 * i;
        u64 w = a[i];
        for i32 k = 7; k >= 0; k-- { q[k] = cast(u8, w); w = w >> 8; }
    }
}

// --- the field mod p -------------------------------------------------------

private void fe_add(u64* r, u64* a, u64* b) {
    u64 carry = w_add(r, a, b);
    u64[4] t;
    u64 borrow = w_sub(&t[0], r, &P256_P[0]);
    // subtract p when the sum carried out or is at least p
    u64 m = (cast(u64, 0) - carry) | (borrow - 1);
    w_select(r, &t[0], m);
}

private void fe_sub(u64* r, u64* a, u64* b) {
    u64 borrow = w_sub(r, a, b);
    u64[4] t;
    ignore w_add(&t[0], r, &P256_P[0]);
    w_select(r, &t[0], cast(u64, 0) - borrow);
}

// r = the 8-word product a * b, a row of four products per word of b,
// each added into the running row with a one-word carry. The carry
// hi + k1 + k2 cannot wrap: a b + t + c is below 2^128.
private void w_mul_wide(u64* r, u64* a, u64* b) {
    for i32 k = 0; k < 8; k++ { r[k] = 0; }
    for i32 i = 0; i < 4; i++ {
        u64 c = 0;
        u64 bi = b[i];
        for i32 j = 0; j < 4; j++ {
            u64 lo = a[j] * bi;
            u64 hi = mulhi(a[j], bi);
            u64 s = r[i + j] + lo;
            u64 k = cast(u64, s < lo);
            u64 u = s + c;
            c = hi + k + cast(u64, u < c);
            r[i + j] = u;
        }
        r[i + 4] = c;
    }
}

// r = the 8-word c mod p (FIPS 186-4 D.2.3) over the sixteen 32-bit
// halves: r = s1 + 2 s2 + 2 s3 + s4 + s5 - s6 - s7 - s8 - s9, each s a
// rearrangement of the halves, summed per half with signed carries. What
// passes 2^256 is folded back with 2^256 = 2^224 - 2^192 - 2^96 + 1 (mod
// p), twice: after the second fold the top carry is -1, 0 or 1, and the
// value is below p after one masked addition of p (when negative) and
// one masked subtraction (when at or above p).
private void fe_reduce(u64* r, u64* c) {
    i64 c8 = cast(i64, c[4] & 0xFFFFFFFF); i64 c9 = cast(i64, c[4] >> 32);
    i64 c10 = cast(i64, c[5] & 0xFFFFFFFF); i64 c11 = cast(i64, c[5] >> 32);
    i64 c12 = cast(i64, c[6] & 0xFFFFFFFF); i64 c13 = cast(i64, c[6] >> 32);
    i64 c14 = cast(i64, c[7] & 0xFFFFFFFF); i64 c15 = cast(i64, c[7] >> 32);
    i64 t0 = cast(i64, c[0] & 0xFFFFFFFF) + c8 + c9 - c11 - c12 - c13 - c14;
    i64 t1 = cast(i64, c[0] >> 32) + c9 + c10 - c12 - c13 - c14 - c15;
    i64 t2 = cast(i64, c[1] & 0xFFFFFFFF) + c10 + c11 - c13 - c14 - c15;
    i64 t3 = cast(i64, c[1] >> 32) + 2 * c11 + 2 * c12 + c13 - c15 - c8 - c9;
    i64 t4 = cast(i64, c[2] & 0xFFFFFFFF) + 2 * c12 + 2 * c13 + c14 - c9 - c10;
    i64 t5 = cast(i64, c[2] >> 32) + 2 * c13 + 2 * c14 + c15 - c10 - c11;
    i64 t6 = cast(i64, c[3] & 0xFFFFFFFF) + 3 * c14 + 2 * c15 + c13 - c8 - c9;
    i64 t7 = cast(i64, c[3] >> 32) + 3 * c15 + c8 - c10 - c11 - c12 - c13;
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
    u64[4] v = { cast(u64, t0) | (cast(u64, t1) << 32), cast(u64, t2) | (cast(u64, t3) << 32),
                 cast(u64, t4) | (cast(u64, t5) << 32), cast(u64, t6) | (cast(u64, t7) << 32) };
    u64[4] w;
    ignore w_add(&w[0], &v[0], &P256_P[0]);
    w_select(&v[0], &w[0], cast(u64, top >> 63));
    u64 borrow = w_sub(&w[0], &v[0], &P256_P[0]);
    w_select(&v[0], &w[0], (borrow - 1) | (cast(u64, 0) - cast(u64, (top + 1) >> 1)));
    w_set(r, &v[0]);
}

private void fe_mul(u64* r, u64* a, u64* b) {
    u64[8] c;
    w_mul_wide(&c[0], a, b);
    fe_reduce(r, &c[0]);
}

// r = a^2: the products a[i] a[j] with i < j once and doubled, the
// squares once, 10 multiplications where a product takes 16.
private void fe_sqr(u64* r, u64* a) {
    u64[8] t;
    for i32 k = 0; k < 8; k++ { t[k] = 0; }
    for i32 i = 0; i < 3; i++ {
        u64 c = 0;
        u64 ai = a[i];
        for i32 j = i + 1; j < 4; j++ {
            u64 lo = ai * a[j];
            u64 hi = mulhi(ai, a[j]);
            u64 s = t[i + j] + lo;
            u64 k = cast(u64, s < lo);
            u64 u = s + c;
            c = hi + k + cast(u64, u < c);
            t[i + j] = u;
        }
        t[i + 4] = c;
    }
    u64 top = 0;
    for i32 k = 0; k < 8; k++ {
        u64 v = t[k];
        t[k] = (v << 1) | top;
        top = v >> 63;
    }
    u64 c = 0;
    for i32 i = 0; i < 4; i++ {
        u64 lo = a[i] * a[i];
        u64 hi = mulhi(a[i], a[i]);
        u64 s = t[2 * i] + lo;
        u64 k = cast(u64, s < lo);
        u64 u = s + c;
        c = k + cast(u64, u < c);
        t[2 * i] = u;
        s = t[2 * i + 1] + hi;
        k = cast(u64, s < hi);
        u = s + c;
        c = k + cast(u64, u < c);
        t[2 * i + 1] = u;
    }
    fe_reduce(r, &t[0]);
}

// x squared n times.
private void fe_sqr_n(u64* r, u64* a, i32 n) {
    w_set(r, a);
    for i32 i = 0; i < n; i++ { fe_sqr(r, r); }
}

// r = a^(p - 2) = 1/a, by a fixed addition chain: 255
// squarings and 12 multiplications, the same whatever a is.
private void fe_inv(u64* r, u64* z) {
    u64[4] t10; u64[4] t11; u64[4] t111; u64[4] t111111; u64[4] x12; u64[4] x15; u64[4] x16;
    u64[4] x32; u64[4] i53; u64[4] x47; u64[4] t;
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
private void jac_double(u64* x, u64* y, u64* z) {
    u64[4] delta; u64[4] gamma; u64[4] beta; u64[4] alpha; u64[4] t; u64[4] u;
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
private void jac_add_affine(u64* x, u64* y, u64* z, u64* ax, u64* ay) {
    u64[4] z1z1; u64[4] u2; u64[4] s2; u64[4] h; u64[4] hh; u64[4] i; u64[4] j; u64[4] r; u64[4] v; u64[4] t;
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
    u64[4] zs;
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

private void jac_to_affine(u64* ax, u64* ay, u64* x, u64* y, u64* z) {
    u64[4] zi; u64[4] zi2; u64[4] zi3;
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
    u64* t = alloc<u64>(P256_ROWS * P256_COLS * 8);
    if t == null { return false; }
    u64* jx = alloc<u64>(P256_COLS * 4);
    u64* jy = alloc<u64>(P256_COLS * 4);
    u64* jz = alloc<u64>(P256_COLS * 4);
    u64* pre = alloc<u64>(P256_COLS * 4);
    defer free(jx);
    defer free(jy);
    defer free(jz);
    defer free(pre);
    u64[4] bx; u64[4] by;                  // 16^j * G, affine
    w_set(&bx[0], &P256_GX[0]);
    w_set(&by[0], &P256_GY[0]);
    for i32 row = 0; row < P256_ROWS; row++ {
        // i * base for i = 1..15: 1 the base, 2 its double, the rest sums.
        u64[4] x; u64[4] y; u64[4] z;
        w_set(&x[0], &bx[0]);
        w_set(&y[0], &by[0]);
        w_zero(&z[0]);
        z[0] = 1;
        for i32 col = 0; col < P256_COLS; col++ {
            w_set(jx + col * 4, &x[0]);
            w_set(jy + col * 4, &y[0]);
            w_set(jz + col * 4, &z[0]);
            if col == 0 { jac_double(&x[0], &y[0], &z[0]); }
            else { jac_add_affine(&x[0], &y[0], &z[0], &bx[0], &by[0]); }
        }
        // 16 * base, the next row's, from the 15th point plus the base.
        u64[4] nx; u64[4] ny; u64[4] nz;
        w_set(&nx[0], &x[0]);
        w_set(&ny[0], &y[0]);
        w_set(&nz[0], &z[0]);
        // pre[i] = z_0 * ... * z_i
        w_set(pre, jz);
        for i32 col = 1; col < P256_COLS; col++ { fe_mul(pre + col * 4, pre + (col - 1) * 4, jz + col * 4); }
        u64[4] inv;
        fe_inv(&inv[0], pre + (P256_COLS - 1) * 4);
        for i32 col = P256_COLS - 1; col >= 0; col-- {
            u64[4] zi;
            if col > 0 {
                fe_mul(&zi[0], &inv[0], pre + (col - 1) * 4);
                fe_mul(&inv[0], &inv[0], jz + col * 4);
            } else {
                w_set(&zi[0], &inv[0]);
            }
            u64[4] zi2; u64[4] zi3;
            fe_sqr(&zi2[0], &zi[0]);
            fe_mul(&zi3[0], &zi2[0], &zi[0]);
            u64* e = t + (row * P256_COLS + col) * 8;
            fe_mul(e, jx + col * 4, &zi2[0]);
            fe_mul(e + 4, jy + col * 4, &zi3[0]);
        }
        jac_to_affine(&bx[0], &by[0], &nx[0], &ny[0], &nz[0]);
    }
    p256_table = t;
    return true;
}

// All ones when a == b, else zero, without a branch (a, b < 2^63).
private u64 mask_eq(u64 a, u64 b) {
    u64 x = a ^ b;
    return cast(u64, 0) - ((x - 1) >> 63);
}

// (ax, ay) = k * G, affine; k in [1, n - 1]. False when the table could
// not be built.
bool p256_base_mult(u64* ax, u64* ay, u64* k) {
    if !p256_table_build() { return false; }
    u64[4] x; u64[4] y; u64[4] z;
    w_zero(&x[0]);
    w_zero(&y[0]);
    w_zero(&z[0]);
    u64[4] one;
    w_zero(&one[0]);
    one[0] = 1;
    u64 empty = cast(u64, 0) - 1;          // all ones while the sum is at infinity
    for i32 row = 0; row < P256_ROWS; row++ {
        u64 d = (k[row / 16] >> cast(u64, (row % 16) * 4)) & 15;
        // The entry for d, read by scanning the whole row.
        u64[8] e;
        for i32 w = 0; w < 8; w++ { e[w] = 0; }
        u64* rowp = p256_table + row * P256_COLS * 8;
        for i32 col = 0; col < P256_COLS; col++ {
            u64 m = mask_eq(d, cast(u64, col + 1));
            u64* src = rowp + col * 8;
            for i32 w = 0; w < 8; w++ { e[w] = e[w] | (src[w] & m); }
        }
        // The sum with the entry, kept only when d is nonzero; while the
        // sum is at infinity it becomes the entry itself.
        u64[4] nx; u64[4] ny; u64[4] nz;
        w_set(&nx[0], &x[0]);
        w_set(&ny[0], &y[0]);
        w_set(&nz[0], &z[0]);
        jac_add_affine(&nx[0], &ny[0], &nz[0], &e[0], &e[4]);
        u64 take = ~mask_eq(d, 0);
        u64 fresh = take & empty;
        u64 add = take & ~empty;
        w_select(&x[0], &nx[0], add);
        w_select(&y[0], &ny[0], add);
        w_select(&z[0], &nz[0], add);
        w_select(&x[0], &e[0], fresh);
        w_select(&y[0], &e[4], fresh);
        w_select(&z[0], &one[0], fresh);
        empty = empty & ~take;
    }
    jac_to_affine(ax, ay, &x[0], &y[0], &z[0]);
    return true;
}

// --- scalars mod n -----------------------------------------------------------

// r = the 8-word c mod n, by long division one bit at a time; the same
// operations whatever c is.
private void sc_reduce_wide(u64* r, u64* c) {
    u64[5] a;                              // the remainder, one word of headroom
    for i32 i = 0; i < 5; i++ { a[i] = 0; }
    u64[5] n5;
    for i32 i = 0; i < 4; i++ { n5[i] = P256_N[i]; }
    n5[4] = 0;
    for i32 bit = 511; bit >= 0; bit-- {
        // a = 2a + the next bit
        for i32 i = 4; i > 0; i-- { a[i] = (a[i] << 1) | (a[i - 1] >> 63); }
        a[0] = (a[0] << 1) | ((c[bit / 64] >> cast(u64, bit % 64)) & 1);
        // a -= n when a >= n
        u64[5] t;
        u64 br = 0;
        for i32 i = 0; i < 5; i++ {
            u64 d = a[i] - n5[i];
            u64 k = cast(u64, a[i] < n5[i]);
            t[i] = d - br;
            br = k + cast(u64, d < br);
        }
        u64 m = br - 1;                    // all ones when no borrow
        for i32 i = 0; i < 5; i++ { a[i] = (a[i] & ~m) | (t[i] & m); }
    }
    for i32 i = 0; i < 4; i++ { r[i] = a[i]; }
}

// Montgomery multiplication mod n (CIOS, 64-bit words): r = a b / 2^256
// mod n. A product needs two of them, the second by 2^512 mod n.
private u64[4] p256_r2 = { 0, 0, 0, 0 };   // 2^512 mod n
private u64 p256_n0 = 0;                    // -1/n mod 2^64
private bool p256_mont_ready = false;

private void mont_mul(u64* r, u64* a, u64* b) {
    u64[6] t;
    for i32 i = 0; i < 6; i++ { t[i] = 0; }
    for i32 i = 0; i < 4; i++ {
        u64 c = 0;
        u64 bi = b[i];
        for i32 j = 0; j < 4; j++ {
            u64 lo = a[j] * bi;
            u64 hi = mulhi(a[j], bi);
            u64 s = t[j] + lo;
            u64 k = cast(u64, s < lo);
            u64 u = s + c;
            c = hi + k + cast(u64, u < c);
            t[j] = u;
        }
        u64 s4 = t[4] + c;
        t[4] = s4;
        t[5] = cast(u64, s4 < c);
        u64 m = t[0] * p256_n0;
        // t = (t + m n) / 2^64: the low word becomes zero and drops off.
        u64 lo0 = m * P256_N[0];
        u64 s0 = t[0] + lo0;
        c = mulhi(m, P256_N[0]) + cast(u64, s0 < lo0);
        for i32 j = 1; j < 4; j++ {
            u64 lo = m * P256_N[j];
            u64 hi = mulhi(m, P256_N[j]);
            u64 s = t[j] + lo;
            u64 k = cast(u64, s < lo);
            u64 u = s + c;
            c = hi + k + cast(u64, u < c);
            t[j - 1] = u;
        }
        u64 s3 = t[4] + c;
        t[3] = s3;
        t[4] = t[5] + cast(u64, s3 < c);
    }
    u64[4] v;
    for i32 i = 0; i < 4; i++ { v[i] = t[i]; }
    u64[4] w;
    u64 borrow = w_sub(&w[0], &v[0], &P256_N[0]);
    w_select(&v[0], &w[0], (borrow - 1) | (cast(u64, 0) - t[4]));
    w_set(r, &v[0]);
}

private void mont_init() {
    if p256_mont_ready { return; }
    // -1/n mod 2^64 by Newton's iteration: each step doubles the bits.
    u64 inv = P256_N[0];
    for i32 i = 0; i < 6; i++ { inv = inv * (2 - P256_N[0] * inv); }
    p256_n0 = cast(u64, 0) - inv;
    // 2^256 mod n is 2^256 - n; its square mod n is 2^512 mod n.
    u64[4] rm;
    u64[4] zero;
    w_zero(&zero[0]);
    ignore w_sub(&rm[0], &zero[0], &P256_N[0]);
    u64[8] c;
    w_mul_wide(&c[0], &rm[0], &rm[0]);
    sc_reduce_wide(&p256_r2[0], &c[0]);
    p256_mont_ready = true;
}

// r = a b mod n.
private void sc_mul(u64* r, u64* a, u64* b) {
    mont_init();
    u64[4] t;
    mont_mul(&t[0], a, b);
    mont_mul(r, &t[0], &p256_r2[0]);
}

private void sc_add(u64* r, u64* a, u64* b) {
    u64 carry = w_add(r, a, b);
    u64[4] t;
    u64 borrow = w_sub(&t[0], r, &P256_N[0]);
    w_select(r, &t[0], (cast(u64, 0) - carry) | (borrow - 1));
}

private void w_shr1(u64* a, u64 top) {
    for i32 i = 0; i < 3; i++ { a[i] = (a[i] >> 1) | (a[i + 1] << 63); }
    a[3] = (a[3] >> 1) | (top << 63);
}

// x / 2 mod m, for the extended GCD below.
private void inv_half(u64* x, u64* m) {
    u64 carry = 0;
    if (x[0] & 1) != 0 { carry = w_add(x, x, m); }
    w_shr1(x, carry);
}

// r = 1/a mod m, by binary extended GCD (micro-ecc's uECC_vli_modInv). Its
// time depends on a, so a caller with a secret blinds it first.
private void sc_inv(u64* r, u64* a, u64* m) {
    if w_is_zero(a) { w_zero(r); return; }
    u64[4] u; u64[4] v; u64[4] x1; u64[4] x2;
    w_set(&u[0], a);
    w_set(&v[0], m);
    w_zero(&x1[0]);
    x1[0] = 1;
    w_zero(&x2[0]);
    while true {
        u64[4] d;
        u64 lt = w_sub(&d[0], &u[0], &v[0]);            // u < v
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
private void sc_random(u64* r) {
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
        u64[4] k;
        sc_random(&k[0]);
        u64[4] px; u64[4] py;
        if !p256_base_mult(&px[0], &py[0], &k[0]) { return 0; }
        // r = x mod n
        u64[4] t;
        u64 borrow = w_sub(&t[0], &px[0], &P256_N[0]);
        w_select(&px[0], &t[0], borrow - 1);
        if w_is_zero(&px[0]) { continue; }
        // 1/k, blinded by a random factor so the inversion's time says
        // nothing about k.
        u64[4] b;
        sc_random(&b[0]);
        sc_mul(&k[0], &k[0], &b[0]);
        sc_inv(&k[0], &k[0], &P256_N[0]);
        sc_mul(&k[0], &k[0], &b[0]);
        // s = (e + r d) / k
        u64[4] d; u64[4] e; u64[4] s;
        w_from_bytes(&d[0], private_key);
        sc_mul(&s[0], &d[0], &px[0]);
        w_from_bytes(&e[0], message_hash);
        u64 eb = w_sub(&t[0], &e[0], &P256_N[0]);
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

// r = the 8-word c mod m, one bit at a time (the reference).
private void ref_reduce(u64* r, u64* c, u64* m) {
    u64[5] a;
    for i32 i = 0; i < 5; i++ { a[i] = 0; }
    for i32 bit = 511; bit >= 0; bit-- {
        for i32 i = 4; i > 0; i-- { a[i] = (a[i] << 1) | (a[i - 1] >> 63); }
        a[0] = (a[0] << 1) | ((c[bit / 64] >> cast(u64, bit % 64)) & 1);
        u64[5] t;
        u64 br = 0;
        for i32 i = 0; i < 5; i++ {
            u64 mi = i < 4 ? m[i] : cast(u64, 0);
            u64 d = a[i] - mi;
            u64 k = cast(u64, a[i] < mi);
            t[i] = d - br;
            br = k + cast(u64, d < br);
        }
        if br == 0 { for i32 i = 0; i < 5; i++ { a[i] = t[i]; } }
    }
    for i32 i = 0; i < 4; i++ { r[i] = a[i]; }
}

private bool w_eq(u64* a, u64* b) {
    for i32 i = 0; i < 4; i++ { if a[i] != b[i] { return false; } }
    return true;
}

// The field and scalar arithmetic against the references, on `rounds`
// random operands and on the values near 0, p and n where carries and
// reductions are most likely to go wrong. The number of mismatches.
i32 p256_selftest(i32 rounds) {
    i32 bad = 0;
    u64[4] pm1; u64[4] nm1; u64[4] one; u64[4] ones;
    w_set(&pm1[0], &P256_P[0]);
    pm1[0] = pm1[0] - 1;
    w_set(&nm1[0], &P256_N[0]);
    nm1[0] = nm1[0] - 1;
    w_zero(&one[0]);
    one[0] = 1;
    for i32 i = 0; i < 4; i++ { ones[i] = 0xFFFFFFFFFFFFFFFF; }
    for i32 r = 0; r < rounds; r++ {
        u64[4] a; u64[4] b;
        u8[32] ra; u8[32] rb;
        mc_csprng_bytes(cast(void*, &ra[0]), 32);
        mc_csprng_bytes(cast(void*, &rb[0]), 32);
        w_from_bytes(&a[0], &ra[0]);
        w_from_bytes(&b[0], &rb[0]);
        if r % 4 == 1 { w_set(&a[0], &pm1[0]); }
        if r % 4 == 2 { w_set(&b[0], &pm1[0]); w_set(&a[0], &pm1[0]); }
        if r % 8 == 3 { w_set(&a[0], &one[0]); }
        if r % 16 == 5 { a[0] = 0; a[1] = 0xFFFFFFFF00000000; }
        // field operands below p
        u64[4] t;
        if w_sub(&t[0], &a[0], &P256_P[0]) == 0 { w_set(&a[0], &t[0]); }
        if w_sub(&t[0], &b[0], &P256_P[0]) == 0 { w_set(&b[0], &t[0]); }
        u64[8] c;
        u64[4] want; u64[4] got;
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

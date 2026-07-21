// tls_p384.mc -- ECDSA verification over NIST P-384 (secp384r1), used for
// certificate chain signatures. Self-contained: 6x64-bit limb arithmetic,
// generic Montgomery multiplication (works for both the field prime p and
// the group order n), and Jacobian-coordinate point math with a = -3.
//
// Verification only. All inputs are public (certificate, signature, CA key),
// so the code favors clarity over constant-time execution. Failing any
// check returns false; there is no error detail by design.

// --- curve constants (little-endian u64 limbs) ------------------------------

private u64[6] P384_P = {
    0x00000000ffffffff, 0xffffffff00000000, 0xfffffffffffffffe,
    0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff };
private u64[6] P384_N = {
    0xecec196accc52973, 0x581a0db248b0a77a, 0xc7634d81f4372ddf,
    0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff };
private u64[6] P384_B = {
    0x2a85c8edd3ec2aef, 0xc656398d8a2ed19d, 0x0314088f5013875a,
    0x181d9c6efe814112, 0x988e056be3f82d19, 0xb3312fa7e23ee7e4 };
private u64[6] P384_GX = {
    0x3a545e3872760ab7, 0x5502f25dbf55296c, 0x59f741e082542a38,
    0x6e1d3b628ba79b98, 0x8eb1c71ef320ad74, 0xaa87ca22be8b0537 };
private u64[6] P384_GY = {
    0x7a431d7c90ea0e5f, 0x0a60b1ce1d7e819d, 0xe9da3113b5f0b8c0,
    0xf8f41dbd289a147c, 0x5d9e98bf9292dc29, 0x3617de4a96262c6f };

private {

// --- 6-limb helpers ---------------------------------------------------------

void fe_set(u64* out, u64* a) {
    for i32 i = 0; i < 6; i++ { out[i] = a[i]; }
}

void fe_zero(u64* out) {
    for i32 i = 0; i < 6; i++ { out[i] = 0; }
}

bool fe_is_zero(u64* a) {
    for i32 i = 0; i < 6; i++ { if a[i] != 0 { return false; } }
    return true;
}

bool fe_equal(u64* a, u64* b) {
    for i32 i = 0; i < 6; i++ { if a[i] != b[i] { return false; } }
    return true;
}

// -1, 0, 1 as a < b, a == b, a > b.
i32 fe_cmp(u64* a, u64* b) {
    for i32 i = 5; i >= 0; i-- {
        if a[i] > b[i] { return 1; }
        if a[i] < b[i] { return 0 - 1; }
    }
    return 0;
}

// out = a - b, returning the borrow.
u64 fe_sub_raw(u64* out, u64* a, u64* b) {
    u64 borrow = 0;
    for i32 i = 0; i < 6; i++ {
        u64 ai = a[i];
        u64 bi = b[i];
        u64 d = ai - bi;
        u64 b1 = cast(u64, ai < bi);
        u64 d2 = d - borrow;
        u64 b2 = cast(u64, d < borrow);
        out[i] = d2;
        borrow = b1 + b2;
    }
    return borrow;
}

// out = a + b, returning the carry.
u64 fe_add_raw(u64* out, u64* a, u64* b) {
    u64 carry = 0;
    for i32 i = 0; i < 6; i++ {
        u64 s1 = a[i] + b[i];
        u64 c1 = cast(u64, s1 < a[i]);
        u64 s2 = s1 + carry;
        u64 c2 = cast(u64, s2 < s1);
        out[i] = s2;
        carry = c1 + c2;
    }
    return carry;
}

// out = (a + b) mod m. Requires a, b < m.
void fe_mod_add(u64* out, u64* a, u64* b, u64* m) {
    u64 carry = fe_add_raw(out, a, b);
    if carry != 0 || fe_cmp(out, m) >= 0 {
        u64[6] t;
        ignore fe_sub_raw(&t[0], out, m);
        fe_set(out, &t[0]);
    }
}

// out = (a - b) mod m. Requires a, b < m.
void fe_mod_sub(u64* out, u64* a, u64* b, u64* m) {
    u64 borrow = fe_sub_raw(out, a, b);
    if borrow != 0 {
        u64[6] t;
        ignore fe_add_raw(&t[0], out, m);
        fe_set(out, &t[0]);
    }
}

// 64x64 -> 128 multiply.
void mul64(u64 a, u64 b, u64* hi, u64* lo) {
    u64 a0 = a & 4294967295;
    u64 a1 = a >> 32;
    u64 b0 = b & 4294967295;
    u64 b1 = b >> 32;
    u64 p00 = a0 * b0;
    u64 p01 = a0 * b1;
    u64 p10 = a1 * b0;
    u64 p11 = a1 * b1;
    u64 mid = (p00 >> 32) + (p01 & 4294967295) + (p10 & 4294967295);
    *lo = (p00 & 4294967295) | (mid << 32);
    *hi = p11 + (p01 >> 32) + (p10 >> 32) + (mid >> 32);
}

// -m^-1 mod 2^64 for odd m (Newton iteration).
u64 mont_n0inv(u64 m0) {
    u64 inv = m0;
    for i32 k = 0; k < 5; k++ { inv = inv * (cast(u64, 2) - m0 * inv); }
    return cast(u64, 0) - inv;
}

// Montgomery multiplication: out = a * b * R^-1 mod m (R = 2^384).
void mont_mul(u64* out, u64* a, u64* b, u64* m, u64 n0inv) {
    u64[8] t;
    for i32 i = 0; i < 8; i++ { t[i] = 0; }
    for i32 i = 0; i < 6; i++ {
        u64 bi = b[i];
        u64 C = 0;
        for i32 j = 0; j < 6; j++ {
            u64 phi;
            u64 plo;
            mul64(a[j], bi, &phi, &plo);
            u64 s1 = plo + t[j];
            u64 c1 = cast(u64, s1 < plo);
            u64 s2 = s1 + C;
            u64 c2 = cast(u64, s2 < s1);
            t[j] = s2;
            C = phi + c1 + c2;
        }
        u64 s = t[6] + C;
        u64 cc = cast(u64, s < t[6]);
        t[6] = s;
        t[7] = t[7] + cc;

        u64 mu = t[0] * n0inv;
        u64 phi0;
        u64 plo0;
        mul64(mu, m[0], &phi0, &plo0);
        u64 s0 = plo0 + t[0];
        u64 cc0 = cast(u64, s0 < plo0);
        C = phi0 + cc0;
        for i32 j = 1; j < 6; j++ {
            u64 phj;
            u64 plj;
            mul64(mu, m[j], &phj, &plj);
            u64 x1 = plj + t[j];
            u64 d1 = cast(u64, x1 < plj);
            u64 x2 = x1 + C;
            u64 d2 = cast(u64, x2 < x1);
            t[j - 1] = x2;
            C = phj + d1 + d2;
        }
        u64 s3 = t[6] + C;
        u64 cc3 = cast(u64, s3 < t[6]);
        t[5] = s3;
        t[6] = t[7] + cc3;
        t[7] = 0;
    }
    u64[6] tmp;
    u64 borrow = fe_sub_raw(&tmp[0], &t[0], m);
    if borrow > t[6] {
        for i32 j = 0; j < 6; j++ { out[j] = t[j]; }
    } else {
        for i32 j = 0; j < 6; j++ { out[j] = tmp[j]; }
    }
}

// R^2 mod m by repeated modular doubling of 1 (768 doublings).
void mont_r2(u64* r2, u64* m) {
    fe_zero(r2);
    r2[0] = 1;
    for i32 i = 0; i < 768; i++ { fe_mod_add(r2, r2, r2, m); }
}

// out = base^e mod m, standard domain in and out. e is 6 limbs, MSB-first
// square-and-multiply over all 384 bits.
void mont_powm(u64* out, u64* base, u64* e, u64* m, u64 n0inv, u64* r2) {
    u64[6] one;
    fe_zero(&one[0]);
    one[0] = 1;
    u64[6] base_m;
    mont_mul(&base_m[0], base, r2, m, n0inv);
    u64[6] res_m;
    mont_mul(&res_m[0], &one[0], r2, m, n0inv);
    u64[6] t;
    for i32 i = 383; i >= 0; i-- {
        mont_mul(&t[0], &res_m[0], &res_m[0], m, n0inv);
        fe_set(&res_m[0], &t[0]);
        if ((e[i / 64] >> cast(u64, i % 64)) & cast(u64, 1)) != cast(u64, 0) {
            mont_mul(&t[0], &res_m[0], &base_m[0], m, n0inv);
            fe_set(&res_m[0], &t[0]);
        }
    }
    mont_mul(out, &res_m[0], &one[0], m, n0inv);
}

// Big-endian bytes (len <= 48) -> 6 limbs.
void fe_from_be(u64* out, u8* be, i32 len) {
    fe_zero(out);
    for i32 i = 0; i < len; i++ {
        u64 bv = cast(u64, be[len - 1 - i]);
        out[i / 8] = out[i / 8] | (bv << cast(u64, (i % 8) * 8));
    }
}

// --- field context (built per call; cheap next to the point math) -----------

struct P384Ctx {
    u64 p_n0inv;
    u64 n_n0inv;
    u64[6] p_r2;
    u64[6] n_r2;
    u64[6] b_m;       // curve b, Montgomery domain
    u64[6] three_m;   // 3, Montgomery domain
}

void ctx_init(P384Ctx* c) {
    c.p_n0inv = mont_n0inv(P384_P[0]);
    c.n_n0inv = mont_n0inv(P384_N[0]);
    mont_r2(&c.p_r2[0], &P384_P[0]);
    mont_r2(&c.n_r2[0], &P384_N[0]);
    u64[6] t;
    fe_zero(&t[0]);
    t[0] = 3;
    mont_mul(&c.three_m[0], &t[0], &c.p_r2[0], &P384_P[0], c.p_n0inv);
    mont_mul(&c.b_m[0], &P384_B[0], &c.p_r2[0], &P384_P[0], c.p_n0inv);
}

// Field (mod p) Montgomery helpers over the context.
void fmul(P384Ctx* c, u64* out, u64* a, u64* b) {
    mont_mul(out, a, b, &P384_P[0], c.p_n0inv);
}

void fto_m(P384Ctx* c, u64* out, u64* a) {
    mont_mul(out, a, &c.p_r2[0], &P384_P[0], c.p_n0inv);
}

void ffrom_m(P384Ctx* c, u64* out, u64* a) {
    u64[6] one;
    fe_zero(&one[0]);
    one[0] = 1;
    mont_mul(out, a, &one[0], &P384_P[0], c.p_n0inv);
}

void fadd(u64* out, u64* a, u64* b) { fe_mod_add(out, a, b, &P384_P[0]); }
void fsub(u64* out, u64* a, u64* b) { fe_mod_sub(out, a, b, &P384_P[0]); }

// --- Jacobian point math (Montgomery-domain coordinates, a = -3) ------------

struct P384Point {
    u64[6] x;
    u64[6] y;
    u64[6] z;     // z == 0 marks the point at infinity
}

void pt_set(P384Point* out, P384Point* a) {
    fe_set(&out.x[0], &a.x[0]);
    fe_set(&out.y[0], &a.y[0]);
    fe_set(&out.z[0], &a.z[0]);
}

// out = 2*a.
void pt_double(P384Ctx* c, P384Point* out, P384Point* a) {
    if fe_is_zero(&a.z[0]) { pt_set(out, a); return; }
    u64[6] delta;
    u64[6] gamma;
    u64[6] beta;
    u64[6] alpha;
    u64[6] t1;
    u64[6] t2;
    fmul(c, &delta[0], &a.z[0], &a.z[0]);            // delta = Z^2
    fmul(c, &gamma[0], &a.y[0], &a.y[0]);            // gamma = Y^2
    fmul(c, &beta[0], &a.x[0], &gamma[0]);           // beta = X*gamma
    fsub(&t1[0], &a.x[0], &delta[0]);                // X - delta
    fadd(&t2[0], &a.x[0], &delta[0]);                // X + delta
    fmul(c, &alpha[0], &t1[0], &t2[0]);
    fmul(c, &t1[0], &alpha[0], &c.three_m[0]);       // alpha = 3*(X-d)*(X+d)
    fe_set(&alpha[0], &t1[0]);
    // X3 = alpha^2 - 8*beta
    fmul(c, &t1[0], &alpha[0], &alpha[0]);
    u64[6] beta8;
    fadd(&beta8[0], &beta[0], &beta[0]);             // 2b
    fadd(&beta8[0], &beta8[0], &beta8[0]);           // 4b
    u64[6] beta4;
    fe_set(&beta4[0], &beta8[0]);
    fadd(&beta8[0], &beta8[0], &beta8[0]);           // 8b
    u64[6] x3;
    fsub(&x3[0], &t1[0], &beta8[0]);
    // Z3 = (Y+Z)^2 - gamma - delta
    fadd(&t1[0], &a.y[0], &a.z[0]);
    fmul(c, &t2[0], &t1[0], &t1[0]);
    fsub(&t2[0], &t2[0], &gamma[0]);
    fsub(&t2[0], &t2[0], &delta[0]);
    fe_set(&out.z[0], &t2[0]);
    // Y3 = alpha*(4*beta - X3) - 8*gamma^2
    fsub(&t1[0], &beta4[0], &x3[0]);
    fmul(c, &t2[0], &alpha[0], &t1[0]);
    fmul(c, &t1[0], &gamma[0], &gamma[0]);
    fadd(&t1[0], &t1[0], &t1[0]);                    // 2g^2
    fadd(&t1[0], &t1[0], &t1[0]);                    // 4g^2
    fadd(&t1[0], &t1[0], &t1[0]);                    // 8g^2
    fsub(&out.y[0], &t2[0], &t1[0]);
    fe_set(&out.x[0], &x3[0]);
}

// out = a + b (general Jacobian addition).
void pt_add(P384Ctx* c, P384Point* out, P384Point* a, P384Point* b) {
    if fe_is_zero(&a.z[0]) { pt_set(out, b); return; }
    if fe_is_zero(&b.z[0]) { pt_set(out, a); return; }
    u64[6] z1z1;
    u64[6] z2z2;
    u64[6] u1;
    u64[6] u2;
    u64[6] s1;
    u64[6] s2;
    u64[6] t;
    fmul(c, &z1z1[0], &a.z[0], &a.z[0]);
    fmul(c, &z2z2[0], &b.z[0], &b.z[0]);
    fmul(c, &u1[0], &a.x[0], &z2z2[0]);
    fmul(c, &u2[0], &b.x[0], &z1z1[0]);
    fmul(c, &t[0], &b.z[0], &z2z2[0]);
    fmul(c, &s1[0], &a.y[0], &t[0]);
    fmul(c, &t[0], &a.z[0], &z1z1[0]);
    fmul(c, &s2[0], &b.y[0], &t[0]);
    if fe_equal(&u1[0], &u2[0]) {
        if !fe_equal(&s1[0], &s2[0]) {
            // a == -b: the sum is the point at infinity
            fe_zero(&out.x[0]);
            fe_zero(&out.y[0]);
            fe_zero(&out.z[0]);
            return;
        }
        pt_double(c, out, a);
        return;
    }
    u64[6] h;
    u64[6] r;
    u64[6] hh;
    u64[6] hhh;
    u64[6] v;
    fsub(&h[0], &u2[0], &u1[0]);
    fsub(&r[0], &s2[0], &s1[0]);
    fmul(c, &hh[0], &h[0], &h[0]);
    fmul(c, &hhh[0], &h[0], &hh[0]);
    fmul(c, &v[0], &u1[0], &hh[0]);
    // X3 = r^2 - hhh - 2v
    fmul(c, &t[0], &r[0], &r[0]);
    fsub(&t[0], &t[0], &hhh[0]);
    fsub(&t[0], &t[0], &v[0]);
    fsub(&t[0], &t[0], &v[0]);
    u64[6] x3;
    fe_set(&x3[0], &t[0]);
    // Y3 = r*(v - X3) - s1*hhh
    fsub(&t[0], &v[0], &x3[0]);
    fmul(c, &t[0], &r[0], &t[0]);
    u64[6] t2;
    fmul(c, &t2[0], &s1[0], &hhh[0]);
    fsub(&out.y[0], &t[0], &t2[0]);
    // Z3 = z1*z2*h
    fmul(c, &t[0], &a.z[0], &b.z[0]);
    fmul(c, &out.z[0], &t[0], &h[0]);
    fe_set(&out.x[0], &x3[0]);
}

}  // private

// Verify an ECDSA signature over P-384. pub_xy_96 is the uncompressed public
// point (X||Y, 48 bytes each); sig_raw_96 is r||s (48 bytes each); hash/hlen
// is the message digest (truncated to the leftmost 48 bytes if longer, per
// X9.62). Returns true only for a valid signature by that key.
bool p384_ecdsa_verify(u8* pub_xy_96, u8* hash, i32 hlen, u8* sig_raw_96) {
    P384Ctx ctx;
    ctx_init(&ctx);

    // load and range-check the public point: x, y < p, not the origin
    u64[6] qx;
    u64[6] qy;
    fe_from_be(&qx[0], pub_xy_96, 48);
    fe_from_be(&qy[0], pub_xy_96 + 48, 48);
    if fe_cmp(&qx[0], &P384_P[0]) >= 0 { return false; }
    if fe_cmp(&qy[0], &P384_P[0]) >= 0 { return false; }
    if fe_is_zero(&qx[0]) && fe_is_zero(&qy[0]) { return false; }

    // load and range-check r, s in [1, n-1]
    u64[6] r;
    u64[6] s;
    fe_from_be(&r[0], sig_raw_96, 48);
    fe_from_be(&s[0], sig_raw_96 + 48, 48);
    if fe_is_zero(&r[0]) || fe_is_zero(&s[0]) { return false; }
    if fe_cmp(&r[0], &P384_N[0]) >= 0 { return false; }
    if fe_cmp(&s[0], &P384_N[0]) >= 0 { return false; }

    // the curve equation must hold for Q: y^2 == x^3 - 3x + b (mod p)
    u64[6] qxm;
    u64[6] qym;
    fto_m(&ctx, &qxm[0], &qx[0]);
    fto_m(&ctx, &qym[0], &qy[0]);
    u64[6] lhs;
    u64[6] rhs;
    u64[6] t;
    fmul(&ctx, &lhs[0], &qym[0], &qym[0]);           // y^2
    fmul(&ctx, &t[0], &qxm[0], &qxm[0]);
    fmul(&ctx, &rhs[0], &t[0], &qxm[0]);             // x^3
    fmul(&ctx, &t[0], &qxm[0], &ctx.three_m[0]);     // 3x
    fsub(&rhs[0], &rhs[0], &t[0]);
    fadd(&rhs[0], &rhs[0], &ctx.b_m[0]);
    if !fe_equal(&lhs[0], &rhs[0]) { return false; }

    // e = leftmost min(8*hlen, 384) bits of the hash
    i32 elen = hlen < 48 ? hlen : 48;
    u64[6] e;
    fe_from_be(&e[0], hash, elen);
    if fe_cmp(&e[0], &P384_N[0]) >= 0 {              // one subtraction suffices
        u64[6] te;
        ignore fe_sub_raw(&te[0], &e[0], &P384_N[0]);
        fe_set(&e[0], &te[0]);
    }

    // w = s^-1 mod n (Fermat: s^(n-2)); u1 = e*w mod n; u2 = r*w mod n
    u64[6] nm2;
    fe_set(&nm2[0], &P384_N[0]);
    nm2[0] = nm2[0] - 2;                             // no borrow: low limb > 2
    u64[6] w;
    mont_powm(&w[0], &s[0], &nm2[0], &P384_N[0], ctx.n_n0inv, &ctx.n_r2[0]);
    // std * mont(w) through one Montgomery multiply strips the single R
    // factor, so u1/u2 land in the standard domain ready for the bit scan.
    u64[6] wm;
    u64[6] u1;
    u64[6] u2;
    mont_mul(&wm[0], &w[0], &ctx.n_r2[0], &P384_N[0], ctx.n_n0inv);
    mont_mul(&u1[0], &e[0], &wm[0], &P384_N[0], ctx.n_n0inv);    // e*w mod n
    mont_mul(&u2[0], &r[0], &wm[0], &P384_N[0], ctx.n_n0inv);    // r*w mod n

    // R = u1*G + u2*Q, Shamir double-and-add over 384 bits
    P384Point g;
    P384Point q;
    fto_m(&ctx, &g.x[0], &P384_GX[0]);
    fto_m(&ctx, &g.y[0], &P384_GY[0]);
    u64[6] one;
    fe_zero(&one[0]);
    one[0] = 1;
    fto_m(&ctx, &g.z[0], &one[0]);
    fe_set(&q.x[0], &qxm[0]);
    fe_set(&q.y[0], &qym[0]);
    fe_set(&q.z[0], &g.z[0]);
    P384Point acc;
    fe_zero(&acc.x[0]);
    fe_zero(&acc.y[0]);
    fe_zero(&acc.z[0]);
    P384Point tp;
    for i32 i = 383; i >= 0; i-- {
        pt_double(&ctx, &tp, &acc);
        pt_set(&acc, &tp);
        if ((u1[i / 64] >> cast(u64, i % 64)) & cast(u64, 1)) != cast(u64, 0) {
            pt_add(&ctx, &tp, &acc, &g);
            pt_set(&acc, &tp);
        }
        if ((u2[i / 64] >> cast(u64, i % 64)) & cast(u64, 1)) != cast(u64, 0) {
            pt_add(&ctx, &tp, &acc, &q);
            pt_set(&acc, &tp);
        }
    }
    if fe_is_zero(&acc.z[0]) { return false; }       // R at infinity: invalid

    // v = R.x affine = X/Z^2 mod p, then reduced mod n; valid iff v == r
    u64[6] z_std;
    ffrom_m(&ctx, &z_std[0], &acc.z[0]);
    u64[6] pm2;
    fe_set(&pm2[0], &P384_P[0]);
    pm2[0] = pm2[0] - 2;                             // no borrow: low limb > 2
    u64[6] zinv;
    mont_powm(&zinv[0], &z_std[0], &pm2[0], &P384_P[0], ctx.p_n0inv, &ctx.p_r2[0]);
    u64[6] zinv_m;
    fto_m(&ctx, &zinv_m[0], &zinv[0]);
    u64[6] zi2;
    fmul(&ctx, &zi2[0], &zinv_m[0], &zinv_m[0]);
    u64[6] xa_m;
    fmul(&ctx, &xa_m[0], &acc.x[0], &zi2[0]);
    u64[6] v;
    ffrom_m(&ctx, &v[0], &xa_m[0]);
    if fe_cmp(&v[0], &P384_N[0]) >= 0 {
        u64[6] tv;
        ignore fe_sub_raw(&tv[0], &v[0], &P384_N[0]);
        fe_set(&v[0], &tv[0]);
    }
    return fe_equal(&v[0], &r[0]);
}

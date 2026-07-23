// Imports added on export so this module resolves standalone (LSP).
import cstdlib_shim;
import picotls_shim;
import picotls_lib;
import picotls_bridges;
import picotls_bridges_p256;

// picotls_bridges_rsa.mc — RSASSA-PSS cert verify, SPKI-pinned.
//
// Supports rsa_pss_rsae_sha256/384/512. Modulus up to 4096 bits.

// --- bignum (rbn_): u64 words, little-endian ---

private {
void rbn_mul64(u64 a, u64 b, u64* hi, u64* lo) {
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
}

private {
u64 rbn_sub(u64* out, u64* a, u64* b, i32 nw) {
    u64 borrow = 0;
    for i32 j = 0; j < nw; j = j + 1 {
        u64 aj = a[j];
        u64 bj = b[j];
        u64 d = aj - bj;
        u64 b1 = cast(u64, aj < bj);
        u64 d2 = d - borrow;
        u64 b2 = cast(u64, d < borrow);
        out[j] = d2;
        borrow = b1 + b2;
    }
    return borrow;
}
}

private {
i32 rbn_cmp(u64* a, u64* b, i32 nw) {
    for i32 i = nw - 1; i >= 0; i = i - 1 {
        if a[i] > b[i] { return 1; }
        if a[i] < b[i] { return 0 - 1; }
    }
    return 0;
}
}

private {
i32 rbn_bitlen(u64* a, i32 nw) {
    for i32 i = nw - 1; i >= 0; i = i - 1 {
        if a[i] != 0 {
            i32 b = 0;
            u64 v = a[i];
            while v != 0 { v = v >> 1; b = b + 1; }
            return i * 64 + b;
        }
    }
    return 0;
}
}

private {
void rbn_from_be(u64* out, u8* bytes, i32 nbytes, i32 nw) {
    for i32 i = 0; i < nw; i = i + 1 { out[i] = 0; }
    for i32 i = 0; i < nbytes; i = i + 1 {
        u64 bv = cast(u64, bytes[nbytes - 1 - i]);
        i32 wi = i / 8;
        i32 sh = (i % 8) * 8;
        out[wi] = out[wi] | (bv << cast(u64, sh));
    }
}
}

private {
void rbn_to_be(u8* out, i32 nbytes, u64* in, i32 nw) {
    for i32 i = 0; i < nbytes; i = i + 1 {
        i32 wi = i / 8;
        i32 sh = (i % 8) * 8;
        out[nbytes - 1 - i] = cast(u8, (in[wi] >> cast(u64, sh)) & cast(u64, 255));
    }
}
}

private {
u64 rbn_n0inv(u64 n0) {
    u64 inv = n0;
    for i32 k = 0; k < 5; k = k + 1 {
        inv = inv * (cast(u64, 2) - n0 * inv);
    }
    return cast(u64, 0) - inv;
}
}

private {
void rbn_dbl(u64* x, u64* n, i32 nw) {
    u64 carry = 0;
    for i32 j = 0; j < nw; j = j + 1 {
        u64 xv = x[j];
        x[j] = (xv << 1) | carry;
        carry = xv >> 63;
    }
    u64[64] tmp;
    u64 borrow = rbn_sub(&tmp[0], x, n, nw);
    if carry != 0 || borrow == 0 {
        for i32 j = 0; j < nw; j = j + 1 { x[j] = tmp[j]; }
    }
}
}

private {
void rbn_r2(u64* r2, u64* n, i32 nw) {
    for i32 i = 0; i < nw; i = i + 1 { r2[i] = 0; }
    r2[0] = 1;
    i32 total = 2 * 64 * nw;
    for i32 i = 0; i < total; i = i + 1 { rbn_dbl(r2, n, nw); }
}
}

private {
void rbn_mont_mul(u64* out, u64* a, u64* b, u64* n, u64 n0inv, i32 nw) {
    u64[66] t;
    for i32 i = 0; i < nw + 2; i = i + 1 { t[i] = 0; }
    for i32 i = 0; i < nw; i = i + 1 {
        u64 bi = b[i];
        u64 C = 0;
        for i32 j = 0; j < nw; j = j + 1 {
            u64 phi; u64 plo;
            rbn_mul64(a[j], bi, &phi, &plo);
            u64 s1 = plo + t[j]; u64 c1 = cast(u64, s1 < plo);
            u64 s2 = s1 + C;     u64 c2 = cast(u64, s2 < s1);
            t[j] = s2;
            C = phi + c1 + c2;
        }
        u64 s = t[nw] + C; u64 cc = cast(u64, s < t[nw]);
        t[nw] = s;
        t[nw + 1] = t[nw + 1] + cc;

        u64 m = t[0] * n0inv;
        u64 phi0; u64 plo0;
        rbn_mul64(m, n[0], &phi0, &plo0);
        u64 s0 = plo0 + t[0]; u64 cc0 = cast(u64, s0 < plo0);
        C = phi0 + cc0;
        for i32 j = 1; j < nw; j = j + 1 {
            u64 phj; u64 plj;
            rbn_mul64(m, n[j], &phj, &plj);
            u64 x1 = plj + t[j]; u64 d1 = cast(u64, x1 < plj);
            u64 x2 = x1 + C;     u64 d2 = cast(u64, x2 < x1);
            t[j - 1] = x2;
            C = phj + d1 + d2;
        }
        u64 s3 = t[nw] + C; u64 cc3 = cast(u64, s3 < t[nw]);
        t[nw - 1] = s3;
        t[nw] = t[nw + 1] + cc3;
        t[nw + 1] = 0;
    }
    u64[64] tmp;
    u64 borrow = rbn_sub(&tmp[0], &t[0], n, nw);
    if borrow > t[nw] {
        for i32 j = 0; j < nw; j = j + 1 { out[j] = t[j]; }
    } else {
        for i32 j = 0; j < nw; j = j + 1 { out[j] = tmp[j]; }
    }
}
}

private {
void rbn_powm(u64* out, u64* base, u64 e, u64* n, i32 nw) {
    u64 n0inv = rbn_n0inv(n[0]);
    u64[64] r2;
    rbn_r2(&r2[0], n, nw);
    u64[64] one;
    for i32 i = 0; i < nw; i = i + 1 { one[i] = 0; }
    one[0] = 1;
    u64[64] base_m;
    rbn_mont_mul(&base_m[0], base, &r2[0], n, n0inv, nw);
    u64[64] res_m;
    rbn_mont_mul(&res_m[0], &one[0], &r2[0], n, n0inv, nw);
    i32 top = 63;
    while top >= 0 && ((e >> cast(u64, top)) & cast(u64, 1)) == cast(u64, 0) { top = top - 1; }
    u64[64] tmp;
    for i32 i = top; i >= 0; i = i - 1 {
        rbn_mont_mul(&tmp[0], &res_m[0], &res_m[0], n, n0inv, nw);
        for i32 j = 0; j < nw; j = j + 1 { res_m[j] = tmp[j]; }
        if ((e >> cast(u64, i)) & cast(u64, 1)) != cast(u64, 0) {
            rbn_mont_mul(&tmp[0], &res_m[0], &base_m[0], n, n0inv, nw);
            for i32 j = 0; j < nw; j = j + 1 { res_m[j] = tmp[j]; }
        }
    }
    rbn_mont_mul(out, &res_m[0], &one[0], n, n0inv, nw);
}
}

// --- SHA-2 + MGF1 + EMSA-PSS-VERIFY ---

// hlen: 32 = SHA-256, 48 = SHA-384, 64 = SHA-512.
private {
void rsa_hash(i32 hlen, u8* input, u64 len, u8* out) {
    if hlen == 48 {
        cf_sha512_context st;
        cf_sha384_init(&st);
        cf_sha384_update(&st, cast(void*, input), len);
        cf_sha384_digest_final(&st, out);
    } else if hlen == 64 {
        cf_sha512_context st;
        cf_sha512_init(&st);
        cf_sha512_update(&st, cast(void*, input), len);
        cf_sha512_digest_final(&st, out);
    } else {
        cf_sha256_context st;
        cf_sha256_init(&st);
        cf_sha256_update(&st, cast(void*, input), len);
        cf_sha256_digest_final(&st, out);
    }
}
}

private {
void mgf1(i32 hlen, u8* seed, i32 seedlen, u8* mask, i32 masklen) {
    u8[128] buf;
    for i32 i = 0; i < seedlen; i = i + 1 { buf[i] = seed[i]; }
    i32 counter = 0;
    i32 outpos = 0;
    while outpos < masklen {
        buf[seedlen + 0] = cast(u8, (counter >> 24) & 255);
        buf[seedlen + 1] = cast(u8, (counter >> 16) & 255);
        buf[seedlen + 2] = cast(u8, (counter >> 8) & 255);
        buf[seedlen + 3] = cast(u8, counter & 255);
        u8[64] h;
        rsa_hash(hlen, &buf[0], cast(u64, seedlen + 4), &h[0]);
        i32 ncopy = hlen;
        if masklen - outpos < ncopy { ncopy = masklen - outpos; }
        for i32 i = 0; i < ncopy; i = i + 1 { mask[outpos + i] = h[i]; }
        outpos = outpos + hlen;
        counter = counter + 1;
    }
}
}

// Salt length = hash length (required by TLS 1.3).
private {
bool emsa_pss_verify(i32 hlen, u8* mhash, u8* em, i32 emlen, i32 embits) {
    i32 slen = hlen;
    if emlen < hlen + slen + 2 { return false; }
    if cast(i32, em[emlen - 1]) != 0xbc { return false; }
    i32 dblen = emlen - hlen - 1;
    u8* maskedDB = em;
    u8* H = em + dblen;
    i32 zbits = 8 * emlen - embits;
    if zbits > 0 {
        i32 topmask = (0xff << (8 - zbits)) & 0xff;
        if (cast(i32, maskedDB[0]) & topmask) != 0 { return false; }
    }
    u8[600] dbmask;
    mgf1(hlen, H, hlen, &dbmask[0], dblen);
    u8[600] db;
    for i32 i = 0; i < dblen; i = i + 1 {
        db[i] = cast(u8, cast(i32, maskedDB[i]) ^ cast(i32, dbmask[i]));
    }
    if zbits > 0 { db[0] = cast(u8, cast(i32, db[0]) & (0xff >> zbits)); }
    i32 pslen = emlen - hlen - slen - 2;
    for i32 i = 0; i < pslen; i = i + 1 { if cast(i32, db[i]) != 0 { return false; } }
    if cast(i32, db[pslen]) != 0x01 { return false; }
    u8* salt = &db[pslen + 1];
    u8[200] mprime;
    for i32 i = 0; i < 8; i = i + 1 { mprime[i] = 0; }
    for i32 i = 0; i < hlen; i = i + 1 { mprime[8 + i] = mhash[i]; }
    for i32 i = 0; i < slen; i = i + 1 { mprime[8 + hlen + i] = salt[i]; }
    u8[64] hprime;
    rsa_hash(hlen, &mprime[0], cast(u64, 8 + hlen + slen), &hprime[0]);
    for i32 i = 0; i < hlen; i = i + 1 {
        if cast(i32, H[i]) != cast(i32, hprime[i]) { return false; }
    }
    return true;
}
}

// Verify an RSASSA-PSS signature. n_bytes and sig are big-endian.
bool rsa_pss_verify(u8* n_bytes, i32 klen, u64 e, u8* sig, i32 siglen, u8* mhash, i32 hlen) {
    if siglen != klen { return false; }
    if klen > 512 { return false; }
    i32 nw = (klen + 7) / 8;
    u64[64] n;
    u64[64] s;
    u64[64] m;
    rbn_from_be(&n[0], n_bytes, klen, nw);
    rbn_from_be(&s[0], sig, siglen, nw);
    if rbn_cmp(&s[0], &n[0], nw) >= 0 { return false; }
    rbn_powm(&m[0], &s[0], e, &n[0], nw);
    i32 modbits = rbn_bitlen(&n[0], nw);
    i32 embits = modbits - 1;
    i32 emlen = (embits + 7) / 8;
    u8[600] em;
    rbn_to_be(&em[0], emlen, &m[0], nw);
    return emsa_pss_verify(hlen, mhash, &em[0], emlen, embits);
}

// LOCAL ADDITION (tsmc) — generic RSA public-key operation for certificate
// signature verification: out_be = in_be^e mod n_be, big-endian, out is klen
// bytes. Rejects in >= n. The padding/DigestInfo check is done by the caller
// (encode-then-compare in tls_verify.mc). Re-apply on re-export (see
// src/tls/THIRD_PARTY.md).
bool mc_rsa_pub_modexp(u8* n_be, i32 klen, u64 e, u8* in_be, i32 in_len, u8* out_be) {
    if klen <= 0 || klen > 512 { return false; }
    if in_len > klen { return false; }
    i32 nw = (klen + 7) / 8;
    u64[64] n;
    u64[64] s;
    u64[64] m;
    rbn_from_be(&n[0], n_be, klen, nw);
    rbn_from_be(&s[0], in_be, in_len, nw);
    if rbn_cmp(&s[0], &n[0], nw) >= 0 { return false; }
    rbn_powm(&m[0], &s[0], e, &n[0], nw);
    rbn_to_be(out_be, klen, &m[0], nw);
    return true;
}

// --- DER / SPKI parsing ---

private {
u64 rsa_der_read_len(u8* buf, u64* off, u64 end) {
    if *off >= end { return cast(u64, 0xffffffffffffffff); }
    u8 first = buf[*off];
    *off = *off + 1;
    if first < cast(u8, 0x80) { return cast(u64, first); }
    u64 nlen = cast(u64, first) - cast(u64, 0x80);
    if nlen == cast(u64, 0) || nlen > cast(u64, 4) { return cast(u64, 0xffffffffffffffff); }
    if *off + nlen > end { return cast(u64, 0xffffffffffffffff); }
    u64 len = 0;
    for u64 i = 0; i < nlen; i++ { len = (len << 8) | cast(u64, buf[*off + i]); }
    *off = *off + nlen;
    return len;
}
}

// Find SubjectPublicKeyInfo inside an X.509 v3 cert.
private { i32 rsa_x509_locate_spki(u8* cert, u64 cert_len,
                                   u8** spki_start_out, u64* spki_len_out) {
    if cert_len < cast(u64, 32) { return 0 - 1; }
    u64 cur = 0;
    u64 end = cert_len;
    if cert[cur] != cast(u8, 0x30) { return 0 - 1; }
    cur = cur + 1;
    u64 outer_len = rsa_der_read_len(cert, &cur, end);
    if outer_len == cast(u64, 0xffffffffffffffff) { return 0 - 1; }
    u64 outer_end = cur + outer_len;
    if outer_end > end { return 0 - 1; }

    if cert[cur] != cast(u8, 0x30) { return 0 - 1; }
    cur = cur + 1;
    u64 tbs_len = rsa_der_read_len(cert, &cur, outer_end);
    if tbs_len == cast(u64, 0xffffffffffffffff) { return 0 - 1; }
    u64 tbs_end = cur + tbs_len;
    if tbs_end > outer_end { return 0 - 1; }

    if cert[cur] != cast(u8, 0xa0) { return 0 - 1; }
    cur = cur + 1;
    u64 ver_len = rsa_der_read_len(cert, &cur, tbs_end);
    if ver_len == cast(u64, 0xffffffffffffffff) { return 0 - 1; }
    cur = cur + ver_len;

    for i32 i = 0; i < 5; i++ {
        if cur >= tbs_end { return 0 - 1; }
        cur = cur + 1;
        u64 flen = rsa_der_read_len(cert, &cur, tbs_end);
        if flen == cast(u64, 0xffffffffffffffff) { return 0 - 1; }
        cur = cur + flen;
    }

    if cur >= tbs_end { return 0 - 1; }
    if cert[cur] != cast(u8, 0x30) { return 0 - 1; }
    u64 spki_tlv_start = cur;
    cur = cur + 1;
    u64 spki_inner_len = rsa_der_read_len(cert, &cur, tbs_end);
    if spki_inner_len == cast(u64, 0xffffffffffffffff) { return 0 - 1; }
    u64 spki_tlv_end = cur + spki_inner_len;
    if spki_tlv_end > tbs_end { return 0 - 1; }
    *spki_start_out = cert + spki_tlv_start;
    *spki_len_out = spki_tlv_end - spki_tlv_start;
    return 0;
}
}

// RSA public key extracted from a leaf cert.
struct rsa_verify_ctx_t {
    u8[512] modulus;
    i32 modulus_len;
    u64 exponent;
}

// Pull modulus + exponent out of an RSA SPKI.
private { i32 mc_spki_extract_rsa_pubkey(u8* spki, u64 spki_len,
                                         u8* mod_out, i32* mod_len_out, u64* exp_out) {
    if spki_len < cast(u64, 50) { return 0 - 1; }
    if spki[0] != cast(u8, 0x30) { return 0 - 1; }
    u64 cur = 1;
    u64 inner = rsa_der_read_len(spki, &cur, spki_len);
    if inner == cast(u64, 0xffffffffffffffff) { return 0 - 1; }
    u64 inner_end = cur + inner;
    if inner_end > spki_len { return 0 - 1; }

    if spki[cur] != cast(u8, 0x30) { return 0 - 1; }
    cur = cur + 1;
    u64 algo_len = rsa_der_read_len(spki, &cur, inner_end);
    if algo_len == cast(u64, 0xffffffffffffffff) { return 0 - 1; }
    cur = cur + algo_len;

    if cur >= inner_end || spki[cur] != cast(u8, 0x03) { return 0 - 1; }
    cur = cur + 1;
    u64 bs_len = rsa_der_read_len(spki, &cur, inner_end);
    if bs_len == cast(u64, 0xffffffffffffffff) { return 0 - 1; }
    u64 bs_end = cur + bs_len;
    if bs_end > inner_end { return 0 - 1; }
    if spki[cur] != cast(u8, 0x00) { return 0 - 1; }
    cur = cur + 1;

    if cur >= bs_end || spki[cur] != cast(u8, 0x30) { return 0 - 1; }
    cur = cur + 1;
    u64 rsapk_len = rsa_der_read_len(spki, &cur, bs_end);
    if rsapk_len == cast(u64, 0xffffffffffffffff) { return 0 - 1; }
    u64 rsapk_end = cur + rsapk_len;
    if rsapk_end > bs_end { return 0 - 1; }

    if cur >= rsapk_end || spki[cur] != cast(u8, 0x02) { return 0 - 1; }
    cur = cur + 1;
    u64 mod_len = rsa_der_read_len(spki, &cur, rsapk_end);
    if mod_len == cast(u64, 0xffffffffffffffff) { return 0 - 1; }
    if cur + mod_len > rsapk_end { return 0 - 1; }
    u64 msrc = cur;
    u64 mrem = mod_len;
    if mrem > cast(u64, 0) && spki[msrc] == cast(u8, 0) { msrc = msrc + 1; mrem = mrem - 1; }
    if mrem == cast(u64, 0) || mrem > cast(u64, 512) { return 0 - 1; }
    for u64 i = 0; i < mrem; i++ { mod_out[i] = spki[msrc + i]; }
    *mod_len_out = cast(i32, mrem);
    cur = cur + mod_len;

    if cur >= rsapk_end || spki[cur] != cast(u8, 0x02) { return 0 - 1; }
    cur = cur + 1;
    u64 exp_len = rsa_der_read_len(spki, &cur, rsapk_end);
    if exp_len == cast(u64, 0xffffffffffffffff) { return 0 - 1; }
    if cur + exp_len > rsapk_end { return 0 - 1; }
    if exp_len == cast(u64, 0) || exp_len > cast(u64, 8) { return 0 - 1; }
    u64 e = 0;
    for u64 i = 0; i < exp_len; i++ { e = (e << 8) | cast(u64, spki[cur + i]); }
    *exp_out = e;
    return 0;
}
}

// Returns 1 = EC, 2 = RSA, 0 = neither / malformed.
i32 mc_cert_leaf_key_type(u8* cert, u64 cert_len) {
    u8* spki;
    u64 spki_len;
    if rsa_x509_locate_spki(cert, cert_len, &spki, &spki_len) != 0 { return 0; }
    if spki_len < cast(u64, 4) || spki[0] != cast(u8, 0x30) { return 0; }
    u64 cur = 1;
    u64 inner = rsa_der_read_len(spki, &cur, spki_len);
    if inner == cast(u64, 0xffffffffffffffff) { return 0; }
    u64 inner_end = cur + inner;
    if inner_end > spki_len { return 0; }
    if spki[cur] != cast(u8, 0x30) { return 0; }
    cur = cur + 1;
    u64 alg_len = rsa_der_read_len(spki, &cur, inner_end);
    if alg_len == cast(u64, 0xffffffffffffffff) { return 0; }
    u64 alg_end = cur + alg_len;
    if alg_end > inner_end { return 0; }
    if spki[cur] != cast(u8, 0x06) { return 0; }
    cur = cur + 1;
    u64 oid_len = rsa_der_read_len(spki, &cur, alg_end);
    if oid_len == cast(u64, 0xffffffffffffffff) { return 0; }
    if cur + oid_len > alg_end { return 0; }
    u8[7] ec_oid = { 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01 };
    u8[9] rsa_oid = { 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01 };
    if oid_len == cast(u64, 7) {
        bool m = true;
        for u64 i = 0; i < 7; i++ { if spki[cur + i] != ec_oid[i] { m = false; break; } }
        if m { return 1; }
    }
    if oid_len == cast(u64, 9) {
        bool m = true;
        for u64 i = 0; i < 9; i++ { if spki[cur + i] != rsa_oid[i] { m = false; break; } }
        if m { return 2; }
    }
    return 0;
}

// --- picotls bridge ---

// rsa_pss_rsae_sha256/384/512.
u16[4] rsa_pss_pl_verify_algos = { 0x0804, 0x0805, 0x0806, 0xffff };

// Verifies the server's RSA-PSS CertificateVerify. Single-use ctx.
private { i32 rsa_pss_pl_verify_sign(void* verify_ctx, u16 algo,
                                     ptls_iovec_t data, ptls_iovec_t sig) {
    i32 hlen = 0;
    if algo == cast(u16, 0x0804) { hlen = 32; }
    else if algo == cast(u16, 0x0805) { hlen = 48; }
    else if algo == cast(u16, 0x0806) { hlen = 64; }
    else { free(verify_ctx); return 0 - 1; }
    rsa_verify_ctx_t* ctx = cast(rsa_verify_ctx_t*, verify_ctx);
    u8[64] digest;
    rsa_hash(hlen, data.base, data.len, &digest[0]);
    bool ok = rsa_pss_verify(&ctx.modulus[0], ctx.modulus_len, ctx.exponent,
                             sig.base, cast(i32, sig.len), &digest[0], hlen);
    free(verify_ctx);
    if !ok { return 0 - 1; }
    return 0;
}
}

// Cert callback: check the leaf SPKI matches `pin`, then arm a
// verify_sign for the upcoming CertificateVerify.
i32 rsa_pss_pinned_verify_cert_cb(ptls_verify_certificate_t* self,
                                  ptls_t* tls, u8* server_name,
                                  verify_sign_fn* out_verify_sign,
                                  void** out_verify_data,
                                  ptls_iovec_t* certs, u64 num_certs) {
    if num_certs == cast(u64, 0) { return 0 - 1; }
    pinned_verify_cert_t* pin = cast(pinned_verify_cert_t*, self);

    u8* spki_start;
    u64 spki_len;
    if rsa_x509_locate_spki(certs[0].base, certs[0].len, &spki_start, &spki_len) != 0 {
        eprint("rsa verify: SPKI locate failed\n");
        return 0 - 1;
    }
    u8[32] spki_hash;
    rsa_hash(32, spki_start, spki_len, &spki_hash[0]);
    bool match = true;
    for u64 i = 0; i < 32; i++ {
        if spki_hash[i] != pin.pinned_spki_sha256[i] { match = false; break; }
    }
    if !match {
        eprint("rsa verify: SPKI pin MISMATCH — refusing handshake\n");
        return 0 - 1;
    }

    rsa_verify_ctx_t* ctx = new(rsa_verify_ctx_t);
    if mc_spki_extract_rsa_pubkey(spki_start, spki_len, &ctx.modulus[0],
                                  &ctx.modulus_len, &ctx.exponent) != 0 {
        free(cast(void*, ctx));
        eprint("rsa verify: SPKI pubkey extract failed (not RSA?)\n");
        return 0 - 1;
    }
    *out_verify_sign = rsa_pss_pl_verify_sign;
    *out_verify_data = cast(void*, ctx);
    return 0;
}

// LOCAL ADDITION (tsmc) — accept any RSA cert without a pin: extract the
// pubkey and arm verify_sign (checks the handshake signature; not the
// chain/hostname). Returns -1 if the leaf is not RSA. Re-apply on re-export
// (see src/tls/THIRD_PARTY.md).
i32 rsa_pss_accept_verify_cert_cb(ptls_verify_certificate_t* self,
                                  ptls_t* tls, u8* server_name,
                                  verify_sign_fn* out_verify_sign,
                                  void** out_verify_data,
                                  ptls_iovec_t* certs, u64 num_certs) {
    if num_certs == cast(u64, 0) { return 0 - 1; }
    u8* spki_start;
    u64 spki_len;
    if rsa_x509_locate_spki(certs[0].base, certs[0].len, &spki_start, &spki_len) != 0 { return 0 - 1; }
    rsa_verify_ctx_t* ctx = new(rsa_verify_ctx_t);
    if mc_spki_extract_rsa_pubkey(spki_start, spki_len, &ctx.modulus[0],
                                  &ctx.modulus_len, &ctx.exponent) != 0 {
        free(cast(void*, ctx));
        return 0 - 1;
    }
    *out_verify_sign = rsa_pss_pl_verify_sign;
    *out_verify_data = cast(void*, ctx);
    return 0;
}

// ===========================================================================
// LOCAL ADDITION (tsmc) — RSA server-side signing (RSASSA-PSS). picotls-minc
// verifies RSA-PSS but cannot sign: rbn_powm takes a u64 exponent (the public
// e), not a full-width private d. Adds a big-exponent modexp, EMSA-PSS-encode,
// and the sign_certificate callback. Plain s = EM^d mod n (no CRT); n and d
// only. Re-apply on re-export (see src/tls/THIRD_PARTY.md).
// ===========================================================================

// Modular exponentiation with a big-endian byte-array exponent (the private
// d), Montgomery square-and-multiply — rbn_powm generalized past its u64
// exponent.
private {
void rbn_powm_bytes(u64* out, u64* base, u8* exp_be, i32 exp_len, u64* n, i32 nw) {
    u64 n0inv = rbn_n0inv(n[0]);
    u64[64] r2;
    rbn_r2(&r2[0], n, nw);
    u64[64] one;
    for i32 i = 0; i < nw; i = i + 1 { one[i] = 0; }
    one[0] = 1;
    u64[64] base_m;
    rbn_mont_mul(&base_m[0], base, &r2[0], n, n0inv, nw);
    u64[64] res_m;
    rbn_mont_mul(&res_m[0], &one[0], &r2[0], n, n0inv, nw);
    u64[64] tmp;
    bool started = false;
    for i32 bi = 0; bi < exp_len; bi = bi + 1 {
        i32 byte = cast(i32, exp_be[bi]);
        for i32 b = 7; b >= 0; b = b - 1 {
            i32 bit = (byte >> b) & 1;
            if !started {
                if bit == 0 { continue; }
                started = true;
            }
            rbn_mont_mul(&tmp[0], &res_m[0], &res_m[0], n, n0inv, nw);
            for i32 j = 0; j < nw; j = j + 1 { res_m[j] = tmp[j]; }
            if bit != 0 {
                rbn_mont_mul(&tmp[0], &res_m[0], &base_m[0], n, n0inv, nw);
                for i32 j = 0; j < nw; j = j + 1 { res_m[j] = tmp[j]; }
            }
        }
    }
    rbn_mont_mul(out, &res_m[0], &one[0], n, n0inv, nw);
}
}

// EMSA-PSS-ENCODE with a fresh random salt of length hlen (TLS 1.3). Produces
// em[0..emlen); embits = modbits - 1. The inverse of emsa_pss_verify above.
private {
bool emsa_pss_encode(i32 hlen, u8* mhash, u8* em, i32 emlen, i32 embits) {
    i32 slen = hlen;
    if emlen < hlen + slen + 2 { return false; }
    u8[64] salt;
    mc_csprng_bytes(cast(void*, &salt[0]), cast(u64, slen));

    u8[200] mprime;
    for i32 i = 0; i < 8; i = i + 1 { mprime[i] = 0; }
    for i32 i = 0; i < hlen; i = i + 1 { mprime[8 + i] = mhash[i]; }
    for i32 i = 0; i < slen; i = i + 1 { mprime[8 + hlen + i] = salt[i]; }
    u8[64] H;
    rsa_hash(hlen, &mprime[0], cast(u64, 8 + hlen + slen), &H[0]);

    i32 dblen = emlen - hlen - 1;
    i32 pslen = emlen - hlen - slen - 2;
    u8[600] db;
    for i32 i = 0; i < pslen; i = i + 1 { db[i] = 0; }
    db[pslen] = cast(u8, 0x01);
    for i32 i = 0; i < slen; i = i + 1 { db[pslen + 1 + i] = salt[i]; }

    u8[600] dbmask;
    mgf1(hlen, &H[0], hlen, &dbmask[0], dblen);
    for i32 i = 0; i < dblen; i = i + 1 {
        em[i] = cast(u8, cast(i32, db[i]) ^ cast(i32, dbmask[i]));
    }
    i32 zbits = 8 * emlen - embits;
    if zbits > 0 { em[0] = cast(u8, cast(i32, em[0]) & (0xff >> zbits)); }
    for i32 i = 0; i < hlen; i = i + 1 { em[dblen + i] = H[i]; }
    em[emlen - 1] = cast(u8, 0xbc);
    return true;
}
}

// EMSA-PSS-encode mhash for the given modulus; em_out gets emlen_out bytes.
bool mc_rsa_pss_prepare(i32 hlen, u8* mhash, i32 klen, u8* n_be, u8* em_out, i32* emlen_out) {
    if klen <= 0 || klen > 512 { return false; }
    i32 nw = (klen + 7) / 8;
    u64[64] n;
    rbn_from_be(&n[0], n_be, klen, nw);
    i32 modbits = rbn_bitlen(&n[0], nw);
    i32 embits = modbits - 1;
    i32 emlen = (embits + 7) / 8;
    if emlen < hlen + hlen + 2 { return false; }
    if !emsa_pss_encode(hlen, mhash, em_out, emlen, embits) { return false; }
    *emlen_out = emlen;
    return true;
}

// The plain RSA private operation: s = EM^d mod n. em is emlen big-endian
// bytes (must be < n); s_out gets klen big-endian bytes.
bool mc_rsa_privop_plain(u8* n_be, i32 klen, u8* d_be, i32 dlen, u8* em, i32 emlen, u8* s_out) {
    if klen <= 0 || klen > 512 { return false; }
    i32 nw = (klen + 7) / 8;
    u64[64] n;
    rbn_from_be(&n[0], n_be, klen, nw);
    u64[64] c;
    rbn_from_be(&c[0], em, emlen, nw);
    if rbn_cmp(&c[0], &n[0], nw) >= 0 { return false; }
    u64[64] s;
    rbn_powm_bytes(&s[0], &c[0], d_be, dlen, &n[0], nw);
    rbn_to_be(s_out, klen, &s[0], nw);
    return true;
}

// --- CRT private operation (~4x faster than the plain modexp) --------------

// out (nw words) = a + b, returns the carry out of the top word.
private {
u64 rbn_add(u64* out, u64* a, u64* b, i32 nw) {
    u64 carry = 0;
    for i32 j = 0; j < nw; j = j + 1 {
        u64 s1 = a[j] + b[j];  u64 c1 = cast(u64, s1 < a[j]);
        u64 s2 = s1 + carry;   u64 c2 = cast(u64, s2 < carry);
        out[j] = s2;
        carry = c1 + c2;
    }
    return carry;
}
}

// Schoolbook multiply: out (2*nw words) = a * b (each nw words).
private {
void rbn_mul_full(u64* out, u64* a, u64* b, i32 nw) {
    for i32 i = 0; i < 2 * nw; i = i + 1 { out[i] = 0; }
    for i32 i = 0; i < nw; i = i + 1 {
        u64 carry = 0;
        for i32 j = 0; j < nw; j = j + 1 {
            u64 hi; u64 lo;
            rbn_mul64(a[i], b[j], &hi, &lo);
            u64 s1 = out[i + j] + lo;  u64 c1 = cast(u64, s1 < lo);
            u64 s2 = s1 + carry;       u64 c2 = cast(u64, s2 < carry);
            out[i + j] = s2;
            carry = hi + c1 + c2;
        }
        i32 k = i + nw;
        while carry != 0 {
            u64 s = out[k] + carry;
            carry = cast(u64, s < carry);
            out[k] = s;
            k = k + 1;
        }
    }
}
}

// out (hw words) = c mod p, where c is cnw words and p is hw words (p < c
// possible). Bit-by-bit: shift-and-conditional-subtract, the same reduction
// rbn_dbl uses, so no general division is needed. out stays < p throughout.
private {
void rbn_mod_reduce(u64* out, u64* c, i32 cnw, u64* p, i32 hw) {
    for i32 i = 0; i < hw; i = i + 1 { out[i] = 0; }
    for i32 wi = cnw - 1; wi >= 0; wi = wi - 1 {
        for i32 b = 63; b >= 0; b = b - 1 {
            u64 bit = (c[wi] >> cast(u64, b)) & cast(u64, 1);
            u64 carry = bit;
            for i32 j = 0; j < hw; j = j + 1 {
                u64 v = out[j];
                out[j] = (v << 1) | carry;
                carry = v >> 63;
            }
            u64[64] tmp;
            u64 borrow = rbn_sub(&tmp[0], out, p, hw);
            if carry != 0 || borrow == 0 {
                for i32 j = 0; j < hw; j = j + 1 { out[j] = tmp[j]; }
            }
        }
    }
}
}

// a*b mod p via Montgomery (p odd). Result normal form.
private {
void rbn_modmul(u64* out, u64* a, u64* b, u64* p, i32 hw) {
    u64 n0inv = rbn_n0inv(p[0]);
    u64[64] r2;
    rbn_r2(&r2[0], p, hw);
    u64[64] bm;
    rbn_mont_mul(&bm[0], b, &r2[0], p, n0inv, hw);   // bm = b*R mod p
    rbn_mont_mul(out, a, &bm[0], p, n0inv, hw);       // out = a*b mod p
}
}

// The CRT RSA private operation: s = EM^d mod n, computed via p/q. Produces
// the same value as mc_rsa_privop_plain, faster. All inputs big-endian; s_out
// is klen bytes. klen = modulus byte length.
bool mc_rsa_privop_crt(u8* p_be, i32 plen, u8* q_be, i32 qlen,
                       u8* dp_be, i32 dplen, u8* dq_be, i32 dqlen,
                       u8* qinv_be, i32 qinvlen, i32 klen, u8* em, i32 emlen, u8* s_out) {
    i32 nw = (klen + 7) / 8;
    i32 hw = plen > qlen ? (plen + 7) / 8 : (qlen + 7) / 8;
    if hw <= 0 || 2 * hw > 64 { return false; }
    u64[64] p; rbn_from_be(&p[0], p_be, plen, hw);
    u64[64] q; rbn_from_be(&q[0], q_be, qlen, hw);
    u64[64] qinv; rbn_from_be(&qinv[0], qinv_be, qinvlen, hw);
    u64[64] c; rbn_from_be(&c[0], em, emlen, nw);

    u64[64] cp; rbn_mod_reduce(&cp[0], &c[0], nw, &p[0], hw);
    u64[64] cq; rbn_mod_reduce(&cq[0], &c[0], nw, &q[0], hw);
    u64[64] m1; rbn_powm_bytes(&m1[0], &cp[0], dp_be, dplen, &p[0], hw);
    u64[64] m2; rbn_powm_bytes(&m2[0], &cq[0], dq_be, dqlen, &q[0], hw);

    // m2 mod p (m2 < q < 2p, so at most one subtraction), then diff = m1 - m2p mod p
    u64[64] m2p;
    u64[64] t;
    u64 bsub = rbn_sub(&t[0], &m2[0], &p[0], hw);
    if bsub == 0 {
        for i32 i = 0; i < hw; i = i + 1 { m2p[i] = t[i]; }   // m2 >= p
    } else {
        for i32 i = 0; i < hw; i = i + 1 { m2p[i] = m2[i]; }
    }
    u64[64] diff;
    u64 db = rbn_sub(&diff[0], &m1[0], &m2p[0], hw);
    if db != 0 {
        u64[64] d2;
        ignore rbn_add(&d2[0], &diff[0], &p[0], hw);         // borrowed: + p
        for i32 i = 0; i < hw; i = i + 1 { diff[i] = d2[i]; }
    }

    u64[64] h;
    rbn_modmul(&h[0], &qinv[0], &diff[0], &p[0], hw);        // h = qinv*diff mod p

    u64[64] hq;                                              // h*q, up to 2*hw words
    rbn_mul_full(&hq[0], &h[0], &q[0], hw);
    u64[64] m2ext;                                           // m2 zero-extended to 2*hw
    for i32 i = 0; i < 2 * hw; i = i + 1 { m2ext[i] = i < hw ? m2[i] : cast(u64, 0); }
    u64[64] s;
    ignore rbn_add(&s[0], &hq[0], &m2ext[0], 2 * hw);        // s = m2 + h*q  (< n)

    rbn_to_be(s_out, klen, &s[0], nw);
    return true;
}

// RSASSA-PSS sign (plain path): PSS-encode then s = EM^d mod n. Kept as the
// CRT-less fallback and as the CRT unit test's oracle.
bool mc_rsa_pss_sign(u8* n_be, i32 klen, u8* d_be, i32 dlen, i32 hlen, u8* mhash, u8* sig_out) {
    u8[600] em;
    i32 emlen = 0;
    if !mc_rsa_pss_prepare(hlen, mhash, klen, n_be, &em[0], &emlen) { return false; }
    return mc_rsa_privop_plain(n_be, klen, d_be, dlen, &em[0], emlen, sig_out);
}

struct rsa_sign_cert_ctx_t {
    ptls_sign_certificate_t super;
    u8[512] n;    // modulus, big-endian
    i32 klen;
    u8[512] d;    // private exponent, big-endian
    i32 dlen;
    bool has_crt;             // p/q/dP/dQ/qInv present -> use the CRT path
    u8[256] p;    i32 plen;
    u8[256] q;    i32 qlen;
    u8[256] dp;   i32 dplen;
    u8[256] dq;   i32 dqlen;
    u8[256] qinv; i32 qinvlen;
}

// sign_certificate callback: pick a PSS hash the client offers (prefer
// sha256), hash the data, PSS-encode, and apply the private op (CRT when the
// key carries its parameters, otherwise plain EM^d mod n).
i32 rsa_pss_pl_sign_certificate(ptls_sign_certificate_t* self, ptls_t* tls,
                                ptls_async_job_t** async_job, u16* selected_algorithm,
                                ptls_buffer_t* output, ptls_iovec_t input,
                                u16* algorithms, u64 num_algorithms) {
    rsa_sign_cert_ctx_t* ctx = cast(rsa_sign_cert_ctx_t*, self);
    u16[3] want = { 0x0804, 0x0805, 0x0806 };
    i32[3] wanth = { 32, 48, 64 };
    u16 chosen = 0;
    i32 hlen = 0;
    for i32 k = 0; k < 3; k = k + 1 {
        bool offered = false;
        for u64 i = 0; i < num_algorithms; i = i + 1 {
            if algorithms[i] == want[k] { offered = true; break; }
        }
        if offered { chosen = want[k]; hlen = wanth[k]; break; }
    }
    if chosen == cast(u16, 0) { return 0 - 1; }
    *selected_algorithm = chosen;
    u8[64] mhash;
    rsa_hash(hlen, input.base, input.len, &mhash[0]);
    u8[600] em;
    i32 emlen = 0;
    if !mc_rsa_pss_prepare(hlen, &mhash[0], ctx.klen, &ctx.n[0], &em[0], &emlen) { return 0 - 1; }
    u8[512] sig;
    bool ok;
    if ctx.has_crt {
        ok = mc_rsa_privop_crt(&ctx.p[0], ctx.plen, &ctx.q[0], ctx.qlen,
                               &ctx.dp[0], ctx.dplen, &ctx.dq[0], ctx.dqlen,
                               &ctx.qinv[0], ctx.qinvlen, ctx.klen, &em[0], emlen, &sig[0]);
    } else {
        ok = mc_rsa_privop_plain(&ctx.n[0], ctx.klen, &ctx.d[0], ctx.dlen, &em[0], emlen, &sig[0]);
    }
    if !ok { return 0 - 1; }
    if ptls_buffer__do_pushv(output, &sig[0], cast(u64, ctx.klen)) != 0 { return 0 - 1; }
    return 0;
}

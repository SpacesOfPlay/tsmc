// Imports added on export so this module resolves standalone (LSP).
import cstdlib_shim;
import picotls_shim;
import picotls_lib;
import picotls_bridges;

// picotls_bridges_p256.mc — ECDSA-P256 cert verify, SPKI-pinned.

struct ecdsa_p256_verify_ctx_t {
    u8[64] public_key_xy;   // X then Y, 32 bytes each
}

// SHA-256 of input into digest_out (32 bytes).
private {
void mc_sha256_hash(u8* input, u64 len, u8* digest_out) {
    cf_sha256_context state;
    cf_sha256_init(&state);
    cf_sha256_update(&state, cast(void*, input), len);
    cf_sha256_digest_final(&state, digest_out);
}
}

// DER-encoded ECDSA signature -> flat 64-byte r||s.
private {
i32 mc_ecdsa_sig_der_to_raw(u8* der, u64 der_len, u8* raw_out) {
    if der_len < cast(u64, 8) { return 0 - 1; }
    if der[0] != cast(u8, 0x30) { return 0 - 1; }
    u64 seq_len = cast(u64, der[1]);
    u64 cur = 2;
    if seq_len >= cast(u64, 0x80) {
        u64 nlen = seq_len - cast(u64, 0x80);
        if nlen == cast(u64, 0) || nlen > cast(u64, 2) { return 0 - 1; }
        seq_len = 0;
        for u64 i = 0; i < nlen; i++ { seq_len = (seq_len << 8) | cast(u64, der[cur + i]); }
        cur = cur + nlen;
    }
    if cur + seq_len > der_len { return 0 - 1; }
    for u64 i = 0; i < 64; i++ { raw_out[i] = cast(u8, 0); }

    u64 dst_off = 0;
    for i32 which = 0; which < 2; which++ {
        if cur >= der_len { return 0 - 1; }
        if der[cur] != cast(u8, 0x02) { return 0 - 1; }
        cur = cur + 1;
        u64 ilen = cast(u64, der[cur]);
        cur = cur + 1;
        if ilen >= cast(u64, 0x80) {
            u64 nlen = ilen - cast(u64, 0x80);
            if nlen == cast(u64, 0) || nlen > cast(u64, 2) { return 0 - 1; }
            ilen = 0;
            for u64 i = 0; i < nlen; i++ { ilen = (ilen << 8) | cast(u64, der[cur + i]); }
            cur = cur + nlen;
        }
        if cur + ilen > der_len { return 0 - 1; }
        // Strip leading zero sign bytes; right-align in the 32-byte slot.
        u64 src = cur;
        u64 rem = ilen;
        while rem > cast(u64, 32) && der[src] == cast(u8, 0) {
            src = src + 1;
            rem = rem - 1;
        }
        if rem > cast(u64, 32) { return 0 - 1; }
        u64 pad = cast(u64, 32) - rem;
        for u64 i = 0; i < rem; i++ { raw_out[dst_off + pad + i] = der[src + i]; }
        cur = cur + ilen;
        dst_off = dst_off + 32;
    }
    return 0;
}
}

// Verifies the server's ECDSA-P256 CertificateVerify. Frees the
// ctx on every call (single-use).
private { i32 ecdsa_p256_pl_verify_sign(void* verify_ctx, u16 algo,
                                        ptls_iovec_t data, ptls_iovec_t sig) {
    if algo != cast(u16, 0x0403) { free(verify_ctx); return 0 - 1; }
    ecdsa_p256_verify_ctx_t* ctx = cast(ecdsa_p256_verify_ctx_t*, verify_ctx);
    u8[32] digest;
    mc_sha256_hash(data.base, data.len, &digest[0]);
    u8[64] raw_sig;
    if mc_ecdsa_sig_der_to_raw(sig.base, sig.len, &raw_sig[0]) != 0 {
        free(verify_ctx);
        return 0 - 1;
    }
    uECC_Curve curve = uECC_secp256r1();
    i32 ok = uECC_verify(&ctx.public_key_xy[0], &digest[0], cast(u32, 32),
                         &raw_sig[0], curve);
    free(verify_ctx);
    if ok != 1 { return 0 - 1; }
    return 0;
}
}

// Find SubjectPublicKeyInfo inside an X.509 v3 cert. Returns the
// SPKI start pointer + total length (tag/length header included).
private { i32 mc_x509_locate_spki(u8* cert, u64 cert_len,
                                   u8** spki_start_out, u64* spki_len_out) {
    if cert_len < cast(u64, 32) { return 0 - 1; }
    u64 cur = 0;
    u64 end = cert_len;
    if cert[cur] != cast(u8, 0x30) { return 0 - 1; }
    cur = cur + 1;
    u64 outer_len = mc_der_read_len(cert, &cur, end);
    if outer_len == cast(u64, 0xffffffffffffffff) { return 0 - 1; }
    u64 outer_end = cur + outer_len;
    if outer_end > end { return 0 - 1; }

    if cert[cur] != cast(u8, 0x30) { return 0 - 1; }
    cur = cur + 1;
    u64 tbs_len = mc_der_read_len(cert, &cur, outer_end);
    if tbs_len == cast(u64, 0xffffffffffffffff) { return 0 - 1; }
    u64 tbs_end = cur + tbs_len;
    if tbs_end > outer_end { return 0 - 1; }

    if cert[cur] != cast(u8, 0xa0) { return 0 - 1; }
    cur = cur + 1;
    u64 ver_len = mc_der_read_len(cert, &cur, tbs_end);
    if ver_len == cast(u64, 0xffffffffffffffff) { return 0 - 1; }
    cur = cur + ver_len;

    // Skip 5 fields ahead of SPKI: serial, sig-alg, issuer, validity, subject.
    for i32 i = 0; i < 5; i++ {
        if cur >= tbs_end { return 0 - 1; }
        cur = cur + 1;
        u64 flen = mc_der_read_len(cert, &cur, tbs_end);
        if flen == cast(u64, 0xffffffffffffffff) { return 0 - 1; }
        cur = cur + flen;
    }

    if cur >= tbs_end { return 0 - 1; }
    if cert[cur] != cast(u8, 0x30) { return 0 - 1; }
    u64 spki_tlv_start = cur;
    cur = cur + 1;
    u64 spki_inner_len = mc_der_read_len(cert, &cur, tbs_end);
    if spki_inner_len == cast(u64, 0xffffffffffffffff) { return 0 - 1; }
    u64 spki_tlv_end = cur + spki_inner_len;
    if spki_tlv_end > tbs_end { return 0 - 1; }
    *spki_start_out = cert + spki_tlv_start;
    *spki_len_out = spki_tlv_end - spki_tlv_start;
    return 0;
}
}

// Read a DER length field; advances *off past it. Returns ~0 on error.
private {
u64 mc_der_read_len(u8* buf, u64* off, u64 end) {
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

// Pull a 64-byte EC P-256 public key (X||Y) from an SPKI.
private {
i32 mc_spki_extract_p256_pubkey(u8* spki, u64 spki_len, u8* xy_out_64) {
    if spki_len < cast(u64, 70) { return 0 - 1; }
    if spki[0] != cast(u8, 0x30) { return 0 - 1; }
    u64 cur = 1;
    u64 inner = mc_der_read_len(spki, &cur, spki_len);
    if inner == cast(u64, 0xffffffffffffffff) { return 0 - 1; }
    u64 inner_end = cur + inner;
    if inner_end > spki_len { return 0 - 1; }

    if spki[cur] != cast(u8, 0x30) { return 0 - 1; }
    cur = cur + 1;
    u64 algo_len = mc_der_read_len(spki, &cur, inner_end);
    if algo_len == cast(u64, 0xffffffffffffffff) { return 0 - 1; }
    cur = cur + algo_len;

    if cur >= inner_end || spki[cur] != cast(u8, 0x03) { return 0 - 1; }
    cur = cur + 1;
    u64 bs_len = mc_der_read_len(spki, &cur, inner_end);
    if bs_len == cast(u64, 0xffffffffffffffff) { return 0 - 1; }
    if cur + bs_len > inner_end { return 0 - 1; }
    if bs_len != cast(u64, 66) { return 0 - 1; }
    if spki[cur] != cast(u8, 0x00) { return 0 - 1; }
    if spki[cur + 1] != cast(u8, 0x04) { return 0 - 1; }
    for u64 i = 0; i < 64; i++ { xy_out_64[i] = spki[cur + 2 + i]; }
    return 0;
}
}

// Pin a server by the SHA-256 of its leaf SubjectPublicKeyInfo.
struct pinned_verify_cert_t {
    ptls_verify_certificate_t super;
    u8[32] pinned_spki_sha256;
}

// Signature schemes accepted by the ECDSA-P256 verifier.
u16[2] ecdsa_p256_pl_verify_algos = { 0x0403, 0xffff };

// Cert callback: check the leaf SPKI matches `pin`, then arm a
// verify_sign that will check the upcoming CertificateVerify.
i32 ecdsa_p256_pinned_verify_cert_cb(ptls_verify_certificate_t* self,
                                     ptls_t* tls, u8* server_name,
                                     verify_sign_fn* out_verify_sign,
                                     void** out_verify_data,
                                     ptls_iovec_t* certs, u64 num_certs) {
    if num_certs == cast(u64, 0) { return 0 - 1; }
    pinned_verify_cert_t* pin = cast(pinned_verify_cert_t*, self);

    u8* spki_start;
    u64 spki_len;
    if mc_x509_locate_spki(certs[0].base, certs[0].len, &spki_start, &spki_len) != 0 {
        eprint("verify: SPKI locate failed\n");
        return 0 - 1;
    }
    u8[32] spki_hash;
    mc_sha256_hash(spki_start, spki_len, &spki_hash[0]);
    bool match = true;
    for u64 i = 0; i < 32; i++ {
        if spki_hash[i] != pin.pinned_spki_sha256[i] { match = false; break; }
    }
    if !match {
        eprint("verify: SPKI pin MISMATCH — refusing handshake\n");
        return 0 - 1;
    }

    ecdsa_p256_verify_ctx_t* ctx = new(ecdsa_p256_verify_ctx_t);
    if mc_spki_extract_p256_pubkey(spki_start, spki_len, &ctx.public_key_xy[0]) != 0 {
        free(cast(void*, ctx));
        eprint("verify: SPKI pubkey extract failed (not P-256?)\n");
        return 0 - 1;
    }
    *out_verify_sign = ecdsa_p256_pl_verify_sign;
    *out_verify_data = cast(void*, ctx);
    return 0;
}

// tls_verify.mc -- certificate signature verification for CA-chain trust.
// Given a parsed child and its issuer, checks that the child's
// signatureAlgorithm signature over its tbsCertificate verifies under the
// issuer's public key. Supports RSASSA-PKCS1-v1_5 and ECDSA-P256, the two
// algorithms real chains use. It reuses the vendored crypto (SHA-2, the RSA
// public-key operation, and uECC) but does the X.509-specific work -- key
// extraction from the issuer SPKI, DER signature decoding, and the PKCS#1
// v1.5 encode-then-compare -- here, where it is unit-tested in isolation.
//
// This checks only the signature. Names, validity, and CA constraints are
// the path validator's responsibility.

import "tls_x509.mc";
import "tls/picotls.mc";

// DigestInfo DER prefixes (AlgorithmIdentifier + NULL) that precede the raw
// hash in an EMSA-PKCS1-v1_5 block.
private u8[19] DI_SHA256 = {
    0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01,
    0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20 };
private u8[19] DI_SHA384 = {
    0x30, 0x41, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01,
    0x65, 0x03, 0x04, 0x02, 0x02, 0x05, 0x00, 0x04, 0x30 };
private u8[19] DI_SHA512 = {
    0x30, 0x51, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01,
    0x65, 0x03, 0x04, 0x02, 0x03, 0x05, 0x00, 0x04, 0x40 };

private {

// SHA-2 of input into out. hlen selects 32=SHA-256, 48=SHA-384, 64=SHA-512.
void sha2(i32 hlen, u8* input, u64 len, u8* out) {
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

// Extract the RSA modulus (big-endian, any leading zero stripped) and public
// exponent from an issuer's SubjectPublicKeyInfo. Returns the modulus byte
// length, or -1 on any malformation. mod_out must hold at least mod_cap bytes.
i32 spki_rsa_pubkey(X509Cert* c, u8* mod_out, i32 mod_cap, u64* exp_out) {
    DerCursor top = DerCursor{ .buf = c.buf, .pos = c.spki.off, .end = c.spki.off + c.spki.len };
    DerTlv spki;
    if !der_read_tlv(&top, &spki) { return 0 - 1; }
    if spki.tag != cast(u8, 0x30) { return 0 - 1; }
    DerCursor sc = der_enter(c.buf, &spki);
    DerTlv alg;
    if !der_read_tlv(&sc, &alg) { return 0 - 1; }          // AlgorithmIdentifier
    if alg.tag != cast(u8, 0x30) { return 0 - 1; }
    DerTlv bs;
    if !der_read_tlv(&sc, &bs) { return 0 - 1; }           // subjectPublicKey BIT STRING
    if bs.tag != cast(u8, 0x03) { return 0 - 1; }
    if bs.len < cast(u64, 1) { return 0 - 1; }
    if c.buf[bs.content] != cast(u8, 0) { return 0 - 1; }  // 0 unused bits

    DerCursor bc = DerCursor{ .buf = c.buf, .pos = bs.content + 1, .end = bs.content + bs.len };
    DerTlv seq;
    if !der_read_tlv(&bc, &seq) { return 0 - 1; }          // RSAPublicKey SEQUENCE
    if seq.tag != cast(u8, 0x30) { return 0 - 1; }
    DerCursor kc = der_enter(c.buf, &seq);
    DerTlv nTlv;
    if !der_read_tlv(&kc, &nTlv) { return 0 - 1; }         // modulus INTEGER
    if nTlv.tag != cast(u8, 0x02) { return 0 - 1; }
    u64 moff = nTlv.content;
    u64 mlen = nTlv.len;
    if mlen > cast(u64, 0) && c.buf[moff] == cast(u8, 0) { moff = moff + 1; mlen = mlen - 1; }
    if mlen == cast(u64, 0) || mlen > cast(u64, mod_cap) { return 0 - 1; }
    for u64 i = 0; i < mlen; i++ { mod_out[i] = c.buf[moff + i]; }
    DerTlv eTlv;
    if !der_read_tlv(&kc, &eTlv) { return 0 - 1; }         // publicExponent INTEGER
    if eTlv.tag != cast(u8, 0x02) { return 0 - 1; }
    if eTlv.len == cast(u64, 0) || eTlv.len > cast(u64, 8) { return 0 - 1; }
    u64 e = 0;
    for u64 i = 0; i < eTlv.len; i++ { e = (e << 8) | cast(u64, c.buf[eTlv.content + i]); }
    *exp_out = e;
    return cast(i32, mlen);
}

// Extract the 64-byte uncompressed P-256 point (X||Y) from an issuer SPKI.
bool spki_ec_point(X509Cert* c, u8* xy_out_64) {
    DerCursor top = DerCursor{ .buf = c.buf, .pos = c.spki.off, .end = c.spki.off + c.spki.len };
    DerTlv spki;
    if !der_read_tlv(&top, &spki) { return false; }
    if spki.tag != cast(u8, 0x30) { return false; }
    DerCursor sc = der_enter(c.buf, &spki);
    DerTlv alg;
    if !der_read_tlv(&sc, &alg) { return false; }
    if alg.tag != cast(u8, 0x30) { return false; }
    DerTlv bs;
    if !der_read_tlv(&sc, &bs) { return false; }
    if bs.tag != cast(u8, 0x03) { return false; }
    if bs.len != cast(u64, 66) { return false; }           // 1 unused-bits + 0x04 + 64
    if c.buf[bs.content] != cast(u8, 0) { return false; }
    if c.buf[bs.content + 1] != cast(u8, 0x04) { return false; }   // uncompressed point
    for u64 i = 0; i < 64; i++ { xy_out_64[i] = c.buf[bs.content + 2 + i]; }
    return true;
}

// Decode a DER ECDSA-Sig-Value SEQUENCE { INTEGER r, INTEGER s } into a flat
// 64-byte r||s, each right-aligned in its 32-byte half. False on malformation.
bool ecdsa_sig_to_raw(u8* buf, DerRange sig, u8* raw_out_64) {
    for i32 i = 0; i < 64; i++ { raw_out_64[i] = cast(u8, 0); }
    DerCursor top = DerCursor{ .buf = buf, .pos = sig.off, .end = sig.off + sig.len };
    DerTlv seq;
    if !der_read_tlv(&top, &seq) { return false; }
    if seq.tag != cast(u8, 0x30) { return false; }
    DerCursor sc = der_enter(buf, &seq);
    for i32 which = 0; which < 2; which++ {
        DerTlv intv;
        if !der_read_tlv(&sc, &intv) { return false; }
        if intv.tag != cast(u8, 0x02) { return false; }
        u64 src = intv.content;
        u64 rem = intv.len;
        while rem > cast(u64, 32) && buf[src] == cast(u8, 0) { src = src + 1; rem = rem - 1; }
        if rem == cast(u64, 0) || rem > cast(u64, 32) { return false; }
        u64 base = cast(u64, which) * 32 + (cast(u64, 32) - rem);
        for u64 i = 0; i < rem; i++ { raw_out_64[base + i] = buf[src + i]; }
    }
    return true;
}

// Build an EMSA-PKCS1-v1_5 block of length emlen for the given hash:
// 0x00 || 0x01 || 0xFF..(>=8).. || 0x00 || DigestInfo || H.
bool build_pkcs1v15(i32 hlen, u8* hash, u8* em, i32 emlen) {
    u8* di = null;
    i32 dilen = 19;
    if hlen == 32 { di = &DI_SHA256[0]; }
    else if hlen == 48 { di = &DI_SHA384[0]; }
    else if hlen == 64 { di = &DI_SHA512[0]; }
    else { return false; }
    i32 tlen = dilen + hlen;
    if emlen < tlen + 11 { return false; }     // require >= 8 bytes of 0xFF padding
    em[0] = cast(u8, 0x00);
    em[1] = cast(u8, 0x01);
    i32 pslen = emlen - tlen - 3;
    for i32 i = 0; i < pslen; i++ { em[2 + i] = cast(u8, 0xff); }
    em[2 + pslen] = cast(u8, 0x00);
    i32 off = 3 + pslen;
    for i32 i = 0; i < dilen; i++ { em[off + i] = di[i]; }
    for i32 i = 0; i < hlen; i++ { em[off + dilen + i] = hash[i]; }
    return true;
}

// RSASSA-PKCS1-v1_5 verify: recover m = sig^e mod n, rebuild the expected
// padded block, and compare byte for byte (never parse-then-trust).
bool rsa_pkcs1v15_verify(X509Cert* parent, u8* tbs_hash, i32 hlen, u8* sig, i32 siglen) {
    u8[512] modbuf;
    u64 e = 0;
    i32 klen = spki_rsa_pubkey(parent, &modbuf[0], 512, &e);
    if klen < 0 { return false; }
    if siglen != klen { return false; }        // signature length must equal the modulus
    u8[512] em;
    if !mc_rsa_pub_modexp(&modbuf[0], klen, e, sig, siglen, &em[0]) { return false; }
    u8[512] expected;
    if !build_pkcs1v15(hlen, tbs_hash, &expected[0], klen) { return false; }
    i32 diff = 0;
    for i32 i = 0; i < klen; i++ { diff = diff | (cast(i32, em[i]) ^ cast(i32, expected[i])); }
    return diff == 0;
}

// ECDSA-P256 verify over the tbs hash.
bool ecdsa_p256_verify(X509Cert* parent, u8* tbs_hash, i32 hlen, u8* buf, DerRange sig) {
    u8[64] pub;
    if !spki_ec_point(parent, &pub[0]) { return false; }
    u8[64] raw;
    if !ecdsa_sig_to_raw(buf, sig, &raw[0]) { return false; }
    uECC_Curve curve = uECC_secp256r1();
    i32 ok = uECC_verify(&pub[0], tbs_hash, cast(u32, hlen), &raw[0], curve);
    return ok == 1;
}

}  // private

// Verify that `child` is signed by `parent`'s public key using the algorithm
// named in child.signatureAlgorithm. Enforces inner==outer algorithm
// agreement and rejects SHA-1 and unknown algorithms (algorithm-confusion
// and weak-hash guards). Returns true only on a valid signature.
bool x509_verify_signature(X509Cert* child, X509Cert* parent) {
    u16 alg = child.sig_alg_id;
    if alg != child.tbs_sig_alg_id { return false; }   // inner/outer must agree

    i32 hlen = 0;
    bool is_rsa = false;
    bool is_ec = false;
    if alg == X509_SIG_RSA_SHA256 { hlen = 32; is_rsa = true; }
    else if alg == X509_SIG_RSA_SHA384 { hlen = 48; is_rsa = true; }
    else if alg == X509_SIG_RSA_SHA512 { hlen = 64; is_rsa = true; }
    else if alg == X509_SIG_ECDSA_SHA256 { hlen = 32; is_ec = true; }
    else if alg == X509_SIG_ECDSA_SHA384 { hlen = 48; is_ec = true; }
    else { return false; }                             // SHA-1 / unknown: refuse

    u8[64] digest;
    sha2(hlen, child.buf + child.tbs.off, child.tbs.len, &digest[0]);

    if is_rsa {
        return rsa_pkcs1v15_verify(parent, &digest[0], hlen,
                                   child.buf + child.sig_val.off, cast(i32, child.sig_val.len));
    }
    if is_ec {
        return ecdsa_p256_verify(parent, &digest[0], hlen, child.buf, child.sig_val);
    }
    return false;
}

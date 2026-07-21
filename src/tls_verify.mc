// tls_verify.mc -- certificate signature verification for CA-chain trust.
// Given a parsed child and its issuer, checks that the child's
// signatureAlgorithm signature over its tbsCertificate verifies under the
// issuer's public key. Supports RSASSA-PKCS1-v1_5 (>= 2048-bit) and ECDSA
// over P-256 and P-384, the algorithms real chains use. It reuses the
// vendored crypto (SHA-2, the RSA public-key operation, uECC for P-256) plus
// the local P-384 implementation, but does the X.509-specific work -- key
// extraction from the issuer SPKI, DER signature decoding, and the PKCS#1
// v1.5 encode-then-compare -- here, where it is unit-tested in isolation.
//
// This checks only the signature. Names, validity, and CA constraints are
// the path validator's responsibility.

import "tls_x509.mc";
import "tls_p384.mc";
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

// SHA-2 of input into out. hlen selects 32=SHA-256, 48=SHA-384, 64=SHA-512.
// Public: the TLS handshake verifier hashes with the same dispatch.
void x509_sha2(i32 hlen, u8* input, u64 len, u8* out) {
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
// exponent from a SubjectPublicKeyInfo. Returns the modulus byte length, or
// -1 on any malformation. mod_out must hold at least mod_cap bytes.
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

// namedCurve identifiers.
const i32 EC_CURVE_NONE = 0;
const i32 EC_CURVE_P256 = 1;   // 1.2.840.10045.3.1.7, 64-byte X||Y
const i32 EC_CURVE_P384 = 2;   // 1.3.132.0.34, 96-byte X||Y

// Extract the uncompressed EC point from an issuer SPKI into xy_out (sized
// for 96 bytes) and identify the named curve. The curve OID and the point
// length must agree — a mismatch is treated as malformed, never guessed.
i32 spki_ec_point(X509Cert* c, u8* xy_out) {
    DerCursor top = DerCursor{ .buf = c.buf, .pos = c.spki.off, .end = c.spki.off + c.spki.len };
    DerTlv spki;
    if !der_read_tlv(&top, &spki) { return EC_CURVE_NONE; }
    if spki.tag != cast(u8, 0x30) { return EC_CURVE_NONE; }
    DerCursor sc = der_enter(c.buf, &spki);
    DerTlv alg;
    if !der_read_tlv(&sc, &alg) { return EC_CURVE_NONE; }
    if alg.tag != cast(u8, 0x30) { return EC_CURVE_NONE; }
    // AlgorithmIdentifier: OID id-ecPublicKey, then the namedCurve OID
    DerCursor ac = der_enter(c.buf, &alg);
    DerTlv keyoid;
    if !der_read_tlv(&ac, &keyoid) { return EC_CURVE_NONE; }
    if keyoid.tag != cast(u8, 0x06) { return EC_CURVE_NONE; }
    DerTlv curveoid;
    if !der_read_tlv(&ac, &curveoid) { return EC_CURVE_NONE; }
    if curveoid.tag != cast(u8, 0x06) { return EC_CURVE_NONE; }
    i32 curve = EC_CURVE_NONE;
    if curveoid.len == cast(u64, 8) {
        // 1.2.840.10045.3.1.7 (prime256v1)
        u8[8] p256 = { 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07 };
        bool m = true;
        for u64 i = 0; i < 8; i++ { if c.buf[curveoid.content + i] != p256[i] { m = false; break; } }
        if m { curve = EC_CURVE_P256; }
    } else if curveoid.len == cast(u64, 5) {
        // 1.3.132.0.34 (secp384r1)
        u8[5] p384 = { 0x2b, 0x81, 0x04, 0x00, 0x22 };
        bool m = true;
        for u64 i = 0; i < 5; i++ { if c.buf[curveoid.content + i] != p384[i] { m = false; break; } }
        if m { curve = EC_CURVE_P384; }
    }
    if curve == EC_CURVE_NONE { return EC_CURVE_NONE; }
    i32 ptlen = curve == EC_CURVE_P256 ? 64 : 96;

    DerTlv bs;
    if !der_read_tlv(&sc, &bs) { return EC_CURVE_NONE; }
    if bs.tag != cast(u8, 0x03) { return EC_CURVE_NONE; }
    if bs.len != cast(u64, ptlen + 2) { return EC_CURVE_NONE; }  // unused-bits + 0x04 + X||Y
    if c.buf[bs.content] != cast(u8, 0) { return EC_CURVE_NONE; }
    if c.buf[bs.content + 1] != cast(u8, 0x04) { return EC_CURVE_NONE; }  // uncompressed
    for i32 i = 0; i < ptlen; i++ { xy_out[i] = c.buf[bs.content + 2 + cast(u64, i)]; }
    return curve;
}

// Decode a DER ECDSA-Sig-Value SEQUENCE { INTEGER r, INTEGER s } into flat
// r||s, each right-aligned in a csize-byte half (csize 32 or 48). False on
// malformation.
bool ecdsa_sig_to_raw(u8* buf, DerRange sig, i32 csize, u8* raw_out) {
    for i32 i = 0; i < 2 * csize; i++ { raw_out[i] = cast(u8, 0); }
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
        while rem > cast(u64, csize) && buf[src] == cast(u8, 0) { src = src + 1; rem = rem - 1; }
        if rem == cast(u64, 0) || rem > cast(u64, csize) { return false; }
        u64 base = cast(u64, which * csize) + (cast(u64, csize) - rem);
        for u64 i = 0; i < rem; i++ { raw_out[base + i] = buf[src + i]; }
    }
    return true;
}

private {

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
    if klen < 256 { return false; }            // require >= 2048-bit RSA
    if siglen != klen { return false; }        // signature length must equal the modulus
    u8[512] em;
    if !mc_rsa_pub_modexp(&modbuf[0], klen, e, sig, siglen, &em[0]) { return false; }
    u8[512] expected;
    if !build_pkcs1v15(hlen, tbs_hash, &expected[0], klen) { return false; }
    i32 diff = 0;
    for i32 i = 0; i < klen; i++ { diff = diff | (cast(i32, em[i]) ^ cast(i32, expected[i])); }
    return diff == 0;
}

// ECDSA verify over the tbs hash: extract the issuer's EC point, identify
// the curve, and dispatch. The digest is truncated to the leftmost curve-
// size bytes when longer (X9.62); P-384 truncates internally.
bool ecdsa_cert_verify(X509Cert* parent, u8* tbs_hash, i32 hlen, u8* buf, DerRange sig) {
    u8[96] pub;
    i32 curve = spki_ec_point(parent, &pub[0]);
    if curve == EC_CURVE_P256 {
        u8[64] raw;
        if !ecdsa_sig_to_raw(buf, sig, 32, &raw[0]) { return false; }
        i32 hl = hlen < 32 ? hlen : 32;
        i32 ok = uECC_verify(&pub[0], tbs_hash, cast(u32, hl), &raw[0], uECC_secp256r1());
        return ok == 1;
    }
    if curve == EC_CURVE_P384 {
        u8[96] raw;
        if !ecdsa_sig_to_raw(buf, sig, 48, &raw[0]) { return false; }
        return p384_ecdsa_verify(&pub[0], tbs_hash, hlen, &raw[0]);
    }
    return false;
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
    else if alg == X509_SIG_ECDSA_SHA512 { hlen = 64; is_ec = true; }
    else { return false; }                             // SHA-1 / unknown: refuse

    u8[64] digest;
    x509_sha2(hlen, child.buf + child.tbs.off, child.tbs.len, &digest[0]);

    if is_rsa {
        return rsa_pkcs1v15_verify(parent, &digest[0], hlen,
                                   child.buf + child.sig_val.off, cast(i32, child.sig_val.len));
    }
    if is_ec {
        return ecdsa_cert_verify(parent, &digest[0], hlen, child.buf, child.sig_val);
    }
    return false;
}

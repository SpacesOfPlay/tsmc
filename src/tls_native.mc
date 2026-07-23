// tls_native.mc -- non-blocking TLS 1.3 client sessions over the vendored
// picotls core (src/tls/). A session wraps a socket fd; the reactor pumps
// it: inbound ciphertext -> ptls_handshake/ptls_receive -> plaintext;
// outbound plaintext -> ptls_send -> ciphertext queued to the socket.
//
// X25519 + AES-128-GCM-SHA256 (the TLS 1.3 mandatory suite, so it
// interoperates with essentially every server). Trust is secure by
// default: the presented chain is validated against the bundled root
// store and the SNI hostname (src/tls_chain.mc), and the handshake
// CertificateVerify is checked against the leaf key. Insecure mode
// (rejectUnauthorized:false) skips chain+hostname but still verifies the
// handshake signature. See doc/PLAN_M34_tls.md and doc/PLAN_M35_ca_trust.md.

import "tls/picotls.mc";
import "tls_x509.mc";
import "tls_verify.mc";
import "tls_p384.mc";
import "tls_chain.mc";
import net_os;
import os_time;

// tls_pump result bits.
const i32 TLS_HANDSHAKE_DONE = 1;
const i32 TLS_HAS_DATA = 2;
const i32 TLS_EOF = 4;
const i32 TLS_ERR = 8;
const i32 TLS_WANT_WRITE = 16;

// --- shared client contexts (built once; must outlive every session) ---

private ptls_key_exchange_algorithm_t g_x25519;
private ptls_aead_algorithm_t g_aes128;
private ptls_cipher_suite_t g_cs128;
private ptls_key_exchange_algorithm_t*[2] g_keyex;
private ptls_cipher_suite_t*[2] g_cslist;
private ptls_context_t g_ctx;            // secure default: chain validation
private ptls_context_t g_ctx_insecure;   // opt-in: rejectUnauthorized false
private ptls_verify_certificate_t g_chain_verify;
private ptls_verify_certificate_t g_insecure_verify;
// signature schemes for CertificateVerify: ECDSA-P256/P-384 + RSA-PSS.
private u16[6] g_leaf_algos = { 0x0403, 0x0503, 0x0804, 0x0805, 0x0806, 0xffff };
private bool g_inited = false;

// Real wall clock for the TLS stack (certificate validity needs actual time).
private u64 tls_wall_time_cb(st_ptls_get_time_t* self) {
    return cast(u64, os_wall_ms());
}
private st_ptls_get_time_t g_tls_time = st_ptls_get_time_t{ .cb = tls_wall_time_cb };

// --- CertificateVerify: prove the peer holds the leaf cert's key -----------

private const i32 LEAF_KEY_P256 = 1;
private const i32 LEAF_KEY_P384 = 2;
private const i32 LEAF_KEY_RSA = 3;

private struct leaf_verify_ctx_t {
    i32 kind;
    u8[96] ec_xy;
    u8[512] rsa_mod;
    i32 rsa_mod_len;
    u64 rsa_exp;
}

// Verify the CertificateVerify signature against the armed leaf key.
// Single-use: frees the ctx on every path.
private i32 tls_leaf_verify_sign(void* verify_ctx, u16 algo,
                                 ptls_iovec_t data, ptls_iovec_t sig) {
    leaf_verify_ctx_t* ctx = cast(leaf_verify_ctx_t*, verify_ctx);
    bool ok = false;
    if ctx.kind == LEAF_KEY_P256 && algo == cast(u16, 0x0403) {
        u8[32] digest;
        x509_sha2(32, data.base, data.len, &digest[0]);
        u8[64] raw;
        DerRange r = DerRange{ .off = 0, .len = sig.len };
        if ecdsa_sig_to_raw(sig.base, r, 32, &raw[0]) {
            ok = uECC_verify(&ctx.ec_xy[0], &digest[0], cast(u32, 32), &raw[0],
                             uECC_secp256r1()) == 1;
        }
    } else if ctx.kind == LEAF_KEY_P384 && algo == cast(u16, 0x0503) {
        u8[48] digest;
        x509_sha2(48, data.base, data.len, &digest[0]);
        u8[96] raw;
        DerRange r = DerRange{ .off = 0, .len = sig.len };
        if ecdsa_sig_to_raw(sig.base, r, 48, &raw[0]) {
            ok = p384_ecdsa_verify(&ctx.ec_xy[0], &digest[0], 48, &raw[0]);
        }
    } else if ctx.kind == LEAF_KEY_RSA {
        i32 hlen = 0;
        if algo == cast(u16, 0x0804) { hlen = 32; }
        else if algo == cast(u16, 0x0805) { hlen = 48; }
        else if algo == cast(u16, 0x0806) { hlen = 64; }
        if hlen != 0 {
            u8[64] digest;
            x509_sha2(hlen, data.base, data.len, &digest[0]);
            ok = rsa_pss_verify(&ctx.rsa_mod[0], ctx.rsa_mod_len, ctx.rsa_exp,
                                sig.base, cast(i32, sig.len), &digest[0], hlen);
        }
    }
    free(verify_ctx);
    return ok ? 0 : 0 - 1;
}

// Extract the leaf's public key and arm tls_leaf_verify_sign for it.
private i32 tls_arm_leaf(X509Cert* leaf, verify_sign_fn* out_verify_sign,
                         void** out_verify_data) {
    leaf_verify_ctx_t* ctx = new(leaf_verify_ctx_t);
    i32 curve = spki_ec_point(leaf, &ctx.ec_xy[0]);
    if curve == EC_CURVE_P256 { ctx.kind = LEAF_KEY_P256; }
    else if curve == EC_CURVE_P384 { ctx.kind = LEAF_KEY_P384; }
    else {
        i32 klen = spki_rsa_pubkey(leaf, &ctx.rsa_mod[0], 512, &ctx.rsa_exp);
        if klen < 0 { free(cast(void*, ctx)); return 0 - 1; }
        ctx.rsa_mod_len = klen;
        ctx.kind = LEAF_KEY_RSA;
    }
    *out_verify_sign = tls_leaf_verify_sign;
    *out_verify_data = cast(void*, ctx);
    return 0;
}

// --- trust callbacks --------------------------------------------------------

// Last chain-validation failure; tls_pump moves it into the failing session
// (the reactor is single-threaded, so the handoff is synchronous).
private i32 g_last_chain_err = 0;

// Secure default: validate the presented chain against the bundled root
// store and the SNI hostname at the real wall clock, then arm the
// CertificateVerify check for the leaf key.
private i32 tls_chain_verify_cb(ptls_verify_certificate_t* self, ptls_t* tls,
                                u8* server_name, verify_sign_fn* out_verify_sign,
                                void** out_verify_data, ptls_iovec_t* certs, u64 num_certs) {
    if num_certs == cast(u64, 0) {
        g_last_chain_err = X509_V_ERR_EMPTY;
        return 0 - 1;
    }
    if num_certs > cast(u64, TLS_CHAIN_MAX) {
        g_last_chain_err = X509_V_ERR_TOO_LONG;
        return 0 - 1;
    }
    i32 n = cast(i32, num_certs);
    u8*[8] ders;
    u64[8] lens;
    for i32 i = 0; i < n; i++ {
        ders[i] = certs[i].base;
        lens[i] = certs[i].len;
    }
    i32 hostlen = 0;
    if server_name != null {
        while *(server_name + hostlen) != cast(u8, 0) { hostlen++; }
    }
    i64 now = os_wall_ms() / 1000;
    i32 rc = tls_chain_verify(&ders[0], &lens[0], n, server_name, hostlen, now, null, 0);
    if rc != X509_V_OK {
        g_last_chain_err = rc;
        return 0 - 1;
    }
    X509Cert leaf;
    if !x509_parse(certs[0].base, certs[0].len, &leaf)
       || tls_arm_leaf(&leaf, out_verify_sign, out_verify_data) != 0 {
        g_last_chain_err = X509_V_ERR_PARSE;
        return 0 - 1;
    }
    return 0;
}

// Opt-in insecure mode: skip chain and hostname validation, but still verify
// the CertificateVerify signature against the presented leaf key.
private i32 tls_insecure_verify_cb(ptls_verify_certificate_t* self, ptls_t* tls,
                                   u8* server_name, verify_sign_fn* out_verify_sign,
                                   void** out_verify_data, ptls_iovec_t* certs, u64 num_certs) {
    if num_certs == cast(u64, 0) { return 0 - 1; }
    X509Cert leaf;
    if !x509_parse(certs[0].base, certs[0].len, &leaf) { return 0 - 1; }
    return tls_arm_leaf(&leaf, out_verify_sign, out_verify_data);
}

private void tls_ctx_init() {
    if g_inited { return; }
    g_x25519 = ptls_key_exchange_algorithm_t{
        .id = cast(u16, 29),
        .create = x25519_pl_create,
        .exchange = x25519_pl_exchange,
        .data = cast(i64, 0),
        .name = "x25519",
    };
    g_aes128 = ptls_aead_algorithm_t{
        .name = "AES128-GCM",
        .confidentiality_limit = cast(u64, 16777216),
        .integrity_limit = cast(u64, 68719476736),
        .ctr_cipher = null,
        .ecb_cipher = null,
        .key_size = cast(u64, 16),
        .iv_size = cast(u64, 12),
        .tag_size = cast(u64, 16),
        .tls12 = { .fixed_iv_size = cast(u64, 4), .record_iv_size = cast(u64, 8) },
        .non_temporal = cast(u32, 0),
        .align_bits = cast(u8, 0),
        .context_size = sizeof(aesgcm_picotls_ctx_t),
        .setup_crypto = aesgcm_pl_setup_crypto_128,
    };
    g_cs128 = ptls_cipher_suite_t{
        .id = cast(u16, 4865),
        .aead = &g_aes128,
        .hash = cast(ptls_hash_algorithm_t*, &ptls_minicrypto_sha256),
        .name = "TLS_AES_128_GCM_SHA256",
    };
    g_keyex[0] = &g_x25519;
    g_keyex[1] = null;
    g_cslist[0] = &g_cs128;
    g_cslist[1] = null;
    g_ctx = ptls_context_t{};
    g_ctx.random_bytes = mc_csprng_bytes;
    g_ctx.get_time = &g_tls_time;
    g_ctx.key_exchanges = &g_keyex[0];
    g_ctx.cipher_suites = &g_cslist[0];
    // Secure by default: CA-chain + hostname validation, then the
    // CertificateVerify check. tls_set_ecdsa_pin replaces this with a pin.
    g_chain_verify.cb = tls_chain_verify_cb;
    g_chain_verify.algos = &g_leaf_algos[0];
    g_ctx.verify_certificate = &g_chain_verify;
    // The insecure context differs only in its verifier.
    g_ctx_insecure = g_ctx;
    g_insecure_verify.cb = tls_insecure_verify_cb;
    g_insecure_verify.algos = &g_leaf_algos[0];
    g_ctx_insecure.verify_certificate = &g_insecure_verify;
    g_inited = true;
}

// SPKI-pin trust (ECDSA-P256): the callback checks the leaf cert's
// SubjectPublicKeyInfo SHA-256 against `spki32` and verifies the handshake
// signature. A stopgap until general cert trust (DESIGN §4.1); the pin is
// process-global here.
private pinned_verify_cert_t g_ecdsa_pin;

void tls_set_ecdsa_pin(u8* spki32) {
    tls_ctx_init();
    g_ecdsa_pin.super.cb = ecdsa_p256_pinned_verify_cert_cb;
    g_ecdsa_pin.super.algos = &ecdsa_p256_pl_verify_algos[0];
    for i32 i = 0; i < 32; i++ { g_ecdsa_pin.pinned_spki_sha256[i] = *(spki32 + i); }
    g_ctx.verify_certificate = &g_ecdsa_pin.super;
}

// --- session ---------------------------------------------------------------

struct TlsSession {
    ptls_t* tls;
    ptls_buffer_t sendbuf;    // outbound ciphertext (handshake + app data)
    u8[1024] send_small;
    i64 send_off;             // flushed prefix of sendbuf
    ptls_buffer_t recvbuf;    // decrypted plaintext accumulated for the reader
    u8[8192] recv_small;
    u8[16384] cipher_in;      // inbound ciphertext awaiting decrypt
    i32 cipher_in_len;
    i32 chain_err;            // X509_V_* when the failure was cert validation
    bool checked_connect;     // confirmed the non-blocking TCP connect
    bool started;
    bool is_server;           // accepted connection: no connect, no ClientHello
    bool established;
    bool failed;
    bool eof;
}

TlsSession* tls_session_new(u8* sni, bool insecure) {
    tls_ctx_init();
    TlsSession* s = alloc<TlsSession>(1);
    s.tls = ptls_new(insecure ? &g_ctx_insecure : &g_ctx, 0);
    if s.tls == null { free(s); return null; }
    if sni != null {
        i32 slen = 0;
        while *(sni + slen) != cast(u8, 0) { slen++; }
        ptls_set_server_name(s.tls, sni, cast(u64, slen));
    }
    ptls_buffer_init(&s.sendbuf, &s.send_small[0], 1024);
    ptls_buffer_init(&s.recvbuf, &s.recv_small[0], 8192);
    s.send_off = 0;
    s.cipher_in_len = 0;
    s.chain_err = 0;
    s.checked_connect = false;
    s.started = false;
    s.is_server = false;
    s.established = false;
    s.failed = false;
    s.eof = false;
    return s;
}

void tls_session_free(TlsSession* s) {
    if s == null { return; }
    if s.tls != null { ptls_free(s.tls); }
    ptls_buffer_dispose(&s.sendbuf);
    ptls_buffer_dispose(&s.recvbuf);
    free(s);
}

// Drop `n` consumed bytes off the front of cipher_in.
private void tls_shift(TlsSession* s, i32 n) {
    if n <= 0 { return; }
    i32 rem = s.cipher_in_len - n;
    for i32 i = 0; i < rem; i++ { s.cipher_in[i] = s.cipher_in[n + i]; }
    s.cipher_in_len = rem;
}

// Feed accumulated ciphertext through the handshake / receive path.
private i32 tls_feed(TlsSession* s) {
    i32 flags = 0;
    while s.cipher_in_len > 0 && !s.failed {
        u64 consumed = cast(u64, s.cipher_in_len);
        void* input = cast(void*, &s.cipher_in[0]);
        if !s.established {
            i32 r = ptls_handshake(s.tls, &s.sendbuf, input, &consumed, null);
            if r != 0 && r != 514 {
                s.failed = true;
                // certificate rejections carry a specific reason
                if g_last_chain_err != 0 { s.chain_err = g_last_chain_err; g_last_chain_err = 0; }
                return flags | TLS_ERR;
            }
            tls_shift(s, cast(i32, consumed));
            // r==0 means the step succeeded, NOT that the handshake is done;
            // completion is signalled only by ptls_handshake_is_complete.
            if ptls_handshake_is_complete(s.tls) != 0 { s.established = true; flags = flags | TLS_HANDSHAKE_DONE; }
        } else {
            i32 r = ptls_receive(s.tls, &s.recvbuf, input, &consumed);
            tls_shift(s, cast(i32, consumed));
            // any code other than ok/in-progress ends the stream cleanly
            // (close_notify) — keep the plaintext already decrypted
            if r != 0 && r != 514 {
                s.eof = true;
                flags = flags | TLS_EOF;
                break;
            }
        }
        if consumed == 0 { break; }   // picotls needs more than we have
    }
    if s.recvbuf.off > 0 { flags = flags | TLS_HAS_DATA; }
    return flags;
}

bool tls_wants_write(TlsSession* s) {
    return s.send_off < cast(i64, s.sendbuf.off);
}

// Push queued outbound ciphertext to the socket (non-blocking).
private bool tls_flush(TlsSession* s, i64 fd) {
    while s.send_off < cast(i64, s.sendbuf.off) {
        i32 remain = cast(i32, cast(i64, s.sendbuf.off) - s.send_off);
        i32 n = net_os_send(fd, s.sendbuf.base + s.send_off, remain);
        if n == NET_WOULDBLOCK { return true; }
        if n < 0 { return false; }
        s.send_off += cast(i64, n);
    }
    s.sendbuf.off = cast(u64, 0);
    s.send_off = 0;
    return true;
}

// Drive one readiness event: kick the handshake, drain inbound ciphertext,
// flush outbound. Returns the TLS_* status bits.
i32 tls_pump(TlsSession* s, i64 fd) {
    if s.failed { return TLS_ERR; }
    i32 flags = 0;
    // A client confirms the non-blocking TCP connect and kicks the ClientHello;
    // a server's fd is already connected (from accept) and it waits for the
    // client to speak first, so tls_feed alone drives its handshake.
    if !s.is_server {
        if !s.checked_connect {
            if net_os_connect_result(fd) != 0 { s.failed = true; return TLS_ERR; }
            s.checked_connect = true;
        }
        if !s.started {
            s.started = true;
            u64 c = 0;
            i32 r = ptls_handshake(s.tls, &s.sendbuf, null, &c, null);
            if r != 0 && r != 514 { s.failed = true; return TLS_ERR; }
        }
    }
    if !tls_flush(s, fd) { s.failed = true; return TLS_ERR; }
    bool more = true;
    while more {
        more = false;
        u8[8192] tmp;
        i32 n = net_os_recv(fd, &tmp[0], 8192);
        if n == 0 {
            s.eof = true;
            flags = flags | TLS_EOF;
        } else if n > 0 {
            if s.cipher_in_len + n > 16384 {
                flags = flags | tls_feed(s);
                if s.cipher_in_len + n > 16384 { s.failed = true; return flags | TLS_ERR; }
            }
            for i32 i = 0; i < n; i++ { s.cipher_in[s.cipher_in_len + i] = tmp[i]; }
            s.cipher_in_len += n;
            more = true;
        }
        flags = flags | tls_feed(s);
        if !tls_flush(s, fd) { s.failed = true; flags = flags | TLS_ERR; }
        if (flags & TLS_ERR) != 0 || (flags & TLS_EOF) != 0 { break; }
    }
    if s.recvbuf.off > 0 { flags = flags | TLS_HAS_DATA; }
    if tls_wants_write(s) { flags = flags | TLS_WANT_WRITE; }
    return flags;
}

// Encrypt+queue plaintext for sending. Returns false on a picotls error.
bool tls_write(TlsSession* s, i64 fd, u8* data, i32 len) {
    if s.failed { return false; }
    i32 r = ptls_send(s.tls, &s.sendbuf, cast(void*, data), cast(u64, len));
    if r != 0 { s.failed = true; return false; }
    return tls_flush(s, fd);
}

// Copy up to `max` decrypted bytes into `out`; shift the rest. Returns n.
i32 tls_read(TlsSession* s, u8* out, i32 max) {
    i32 avail = cast(i32, s.recvbuf.off);
    if avail == 0 { return 0; }
    i32 n = avail < max ? avail : max;
    for i32 i = 0; i < n; i++ { *(out + i) = *(s.recvbuf.base + i); }
    i32 rem = avail - n;
    for i32 i = 0; i < rem; i++ { *(s.recvbuf.base + i) = *(s.recvbuf.base + n + i); }
    s.recvbuf.off = cast(u64, rem);
    return n;
}

bool tls_established(TlsSession* s) { return s.established; }
bool tls_failed(TlsSession* s) { return s.failed; }

// X509_V_* code when the failure was certificate validation, else 0.
i32 tls_chain_error(TlsSession* s) { return s.chain_err; }

// --- server: ECDSA-P256 X.509 certificate ----------------------------------

// Extract the 32-byte P-256 private scalar from an EC private key in DER, in
// either SEC1 (`ECPrivateKey`) or PKCS#8 (`PrivateKeyInfo` wrapping SEC1)
// form. A key that is not a 32-byte-scalar EC key is rejected (false), which
// keeps a wrong-curve or non-EC key out of the server rather than failing
// mid-handshake.
private bool tls_copy_scalar(u8* der, u64 off, u64 len, u8* out32) {
    while len > cast(u64, 32) && der[off] == cast(u8, 0) { off = off + 1; len = len - 1; }
    if len == cast(u64, 0) || len > cast(u64, 32) { return false; }
    for i32 i = 0; i < 32; i++ { out32[i] = cast(u8, 0); }
    u64 pad = cast(u64, 32) - len;
    for u64 i = 0; i < len; i++ { out32[pad + i] = der[off + i]; }
    return true;
}

private bool tls_parse_ec_scalar(u8* der, u64 der_len, u8* out32) {
    DerCursor c = DerCursor{ .buf = der, .pos = 0, .end = der_len };
    DerTlv seq;
    if !der_read_tlv(&c, &seq) || seq.tag != cast(u8, 0x30) { return false; }
    DerCursor in = der_enter(der, &seq);
    DerTlv ver;
    if !der_read_tlv(&in, &ver) || ver.tag != cast(u8, 0x02) { return false; }
    i32 version = ver.len > cast(u64, 0) ? cast(i32, der[ver.content + ver.len - 1]) : 0 - 1;
    if version == 1 {
        // SEC1: privateKey OCTET STRING is the scalar.
        DerTlv oct;
        if !der_read_tlv(&in, &oct) || oct.tag != cast(u8, 0x04) { return false; }
        return tls_copy_scalar(der, oct.content, oct.len, out32);
    }
    if version == 0 {
        // PKCS#8: skip AlgorithmIdentifier, then privateKey OCTET STRING holds
        // a SEC1 ECPrivateKey whose scalar we want.
        DerTlv alg;
        if !der_read_tlv(&in, &alg) || alg.tag != cast(u8, 0x30) { return false; }
        DerTlv pk;
        if !der_read_tlv(&in, &pk) || pk.tag != cast(u8, 0x04) { return false; }
        DerCursor sec = DerCursor{ .buf = der, .pos = pk.content, .end = pk.content + pk.len };
        DerTlv seq2;
        if !der_read_tlv(&sec, &seq2) || seq2.tag != cast(u8, 0x30) { return false; }
        DerCursor in2 = der_enter(der, &seq2);
        DerTlv ver2;
        if !der_read_tlv(&in2, &ver2) || ver2.tag != cast(u8, 0x02) { return false; }
        DerTlv oct2;
        if !der_read_tlv(&in2, &oct2) || oct2.tag != cast(u8, 0x04) { return false; }
        return tls_copy_scalar(der, oct2.content, oct2.len, out32);
    }
    return false;
}

// One INTEGER's content bytes, big-endian, with a leading 0x00 sign byte
// stripped. False if it overflows `cap`.
private bool tls_read_int(u8* der, DerTlv* t, u8* out, i32 cap, i32* out_len) {
    u64 off = t.content;
    u64 len = t.len;
    if len > cast(u64, 0) && der[off] == cast(u8, 0) { off = off + 1; len = len - 1; }
    if cast(i32, len) > cap { return false; }
    for u64 i = 0; i < len; i++ { out[i] = der[off + i]; }
    *out_len = cast(i32, len);
    return true;
}

// The parsed pieces of an RSA private key. The CRT fields are optional (a
// bare n/d key leaves has_crt false and the server uses the plain path).
struct TlsRsaKey {
    u8[512] n;    i32 klen;
    u8[512] d;    i32 dlen;
    bool has_crt;
    u8[256] p;    i32 plen;
    u8[256] q;    i32 qlen;
    u8[256] dp;   i32 dplen;
    u8[256] dq;   i32 dqlen;
    u8[256] qinv; i32 qinvlen;
}

// From a cursor positioned just after the version INTEGER of an RSAPrivateKey
// (SEQUENCE { version, n, e, d, p, q, dP, dQ, qInv }), read n and d, and the
// CRT parameters when present.
private bool tls_rsa_from_seq(u8* der, DerCursor* in, TlsRsaKey* k) {
    DerTlv nt;
    if !der_read_tlv(in, &nt) || nt.tag != cast(u8, 0x02) { return false; }
    if !tls_read_int(der, &nt, &k.n[0], 512, &k.klen) { return false; }
    DerTlv et;
    if !der_read_tlv(in, &et) || et.tag != cast(u8, 0x02) { return false; }   // e, skipped
    DerTlv dt;
    if !der_read_tlv(in, &dt) || dt.tag != cast(u8, 0x02) { return false; }
    if !tls_read_int(der, &dt, &k.d[0], 512, &k.dlen) { return false; }
    // optional CRT parameters (all five, or none)
    k.has_crt = false;
    DerTlv pt;
    if der_read_tlv(in, &pt) && pt.tag == cast(u8, 0x02)
       && tls_read_int(der, &pt, &k.p[0], 256, &k.plen) {
        DerTlv qt;
        DerTlv dpt;
        DerTlv dqt;
        DerTlv qit;
        if der_read_tlv(in, &qt) && qt.tag == cast(u8, 0x02) && tls_read_int(der, &qt, &k.q[0], 256, &k.qlen)
           && der_read_tlv(in, &dpt) && dpt.tag == cast(u8, 0x02) && tls_read_int(der, &dpt, &k.dp[0], 256, &k.dplen)
           && der_read_tlv(in, &dqt) && dqt.tag == cast(u8, 0x02) && tls_read_int(der, &dqt, &k.dq[0], 256, &k.dqlen)
           && der_read_tlv(in, &qit) && qit.tag == cast(u8, 0x02) && tls_read_int(der, &qit, &k.qinv[0], 256, &k.qinvlen) {
            k.has_crt = true;
        }
    }
    return true;
}

// Parse an RSA private key from DER, PKCS#1 (RSAPrivateKey) or PKCS#8
// (PrivateKeyInfo wrapping it).
private bool tls_parse_rsa_key(u8* der, u64 der_len, TlsRsaKey* k) {
    DerCursor c = DerCursor{ .buf = der, .pos = 0, .end = der_len };
    DerTlv seq;
    if !der_read_tlv(&c, &seq) || seq.tag != cast(u8, 0x30) { return false; }
    DerCursor in = der_enter(der, &seq);
    DerTlv ver;
    if !der_read_tlv(&in, &ver) || ver.tag != cast(u8, 0x02) { return false; }
    // after version: an INTEGER (the modulus) is PKCS#1; a SEQUENCE (the
    // AlgorithmIdentifier) is PKCS#8
    i32 next = der_peek_tag(&in);
    if next == 0x02 {
        return tls_rsa_from_seq(der, &in, k);
    }
    if next == 0x30 {
        DerTlv alg;
        if !der_read_tlv(&in, &alg) || alg.tag != cast(u8, 0x30) { return false; }
        DerTlv pk;
        if !der_read_tlv(&in, &pk) || pk.tag != cast(u8, 0x04) { return false; }
        DerCursor rc = DerCursor{ .buf = der, .pos = pk.content, .end = pk.content + pk.len };
        DerTlv seq2;
        if !der_read_tlv(&rc, &seq2) || seq2.tag != cast(u8, 0x30) { return false; }
        DerCursor in2 = der_enter(der, &seq2);
        DerTlv ver2;
        if !der_read_tlv(&in2, &ver2) || ver2.tag != cast(u8, 0x02) { return false; }
        return tls_rsa_from_seq(der, &in2, k);
    }
    return false;
}

// A server certificate + key, one per tls.createServer, kept alive for the
// server's lifetime (all its connections share it). Referenced from JS by a
// small registry id. Holds both sign-context shapes; whichever matches the
// key is wired into ctx.sign_certificate.
struct TlsServerCtx {
    ptls_context_t ctx;
    ecdsa_sign_cert_ctx_t ec_sign;
    rsa_sign_cert_ctx_t rsa_sign;
    ptls_iovec_t[1] certs;
    u8* cert_der;             // owned copy
    u64 cert_len;
}

private const i32 TLS_SERVER_CTX_MAX = 64;
private TlsServerCtx*[64] g_server_ctxs;
private bool g_server_ctxs_inited = false;

private void tls_server_ctxs_init() {
    if g_server_ctxs_inited { return; }
    for i32 i = 0; i < TLS_SERVER_CTX_MAX; i++ { g_server_ctxs[i] = null; }
    g_server_ctxs_inited = true;
}

// Build a server context from an X.509 cert DER and a private key DER,
// auto-detecting the key type: an ECDSA-P256 scalar, otherwise RSA. Returns a
// registry id, or -1 (bad/unsupported key, or registry full).
i32 tls_server_ctx_new(u8* cert_der, u64 cert_len, u8* key_der, u64 key_len) {
    tls_ctx_init();
    tls_server_ctxs_init();
    mc_ecdsa_p256_sign_init();

    u8[32] scalar;
    TlsRsaKey rsa;
    bool is_ec = tls_parse_ec_scalar(key_der, key_len, &scalar[0]);
    bool is_rsa = false;
    if !is_ec {
        is_rsa = tls_parse_rsa_key(key_der, key_len, &rsa);
        if is_rsa && (rsa.klen <= 0 || rsa.klen > 512) { is_rsa = false; }
    }
    if !is_ec && !is_rsa { return 0 - 1; }

    i32 slot = 0 - 1;
    for i32 i = 0; i < TLS_SERVER_CTX_MAX; i++ {
        if g_server_ctxs[i] == null { slot = i; break; }
    }
    if slot < 0 { return 0 - 1; }

    TlsServerCtx* sc = alloc<TlsServerCtx>(1);
    sc.cert_der = alloc<u8>(cert_len > cast(u64, 0) ? cast(i32, cert_len) : 1);
    for u64 i = 0; i < cert_len; i++ { sc.cert_der[i] = cert_der[i]; }
    sc.cert_len = cert_len;
    sc.certs[0] = ptls_iovec_init(sc.cert_der, cert_len);

    sc.ctx = ptls_context_t{};
    sc.ctx.random_bytes = mc_csprng_bytes;
    sc.ctx.get_time = &g_tls_time;
    sc.ctx.key_exchanges = &g_keyex[0];
    sc.ctx.cipher_suites = &g_cslist[0];
    sc.ctx.certificates.list = &sc.certs[0];
    sc.ctx.certificates.count = cast(u64, 1);

    if is_ec {
        sc.ec_sign = ecdsa_sign_cert_ctx_t{
            .super = ptls_sign_certificate_t{ .cb = ecdsa_p256_pl_sign_certificate },
        };
        for i32 i = 0; i < 32; i++ { sc.ec_sign.private_key[i] = scalar[i]; }
        sc.ctx.sign_certificate = &sc.ec_sign.super;
    } else {
        sc.rsa_sign = rsa_sign_cert_ctx_t{
            .super = ptls_sign_certificate_t{ .cb = rsa_pss_pl_sign_certificate },
        };
        sc.rsa_sign.klen = rsa.klen;
        sc.rsa_sign.dlen = rsa.dlen;
        for i32 i = 0; i < rsa.klen; i++ { sc.rsa_sign.n[i] = rsa.n[i]; }
        for i32 i = 0; i < rsa.dlen; i++ { sc.rsa_sign.d[i] = rsa.d[i]; }
        sc.rsa_sign.has_crt = rsa.has_crt;
        if rsa.has_crt {
            sc.rsa_sign.plen = rsa.plen;
            sc.rsa_sign.qlen = rsa.qlen;
            sc.rsa_sign.dplen = rsa.dplen;
            sc.rsa_sign.dqlen = rsa.dqlen;
            sc.rsa_sign.qinvlen = rsa.qinvlen;
            for i32 i = 0; i < rsa.plen; i++ { sc.rsa_sign.p[i] = rsa.p[i]; }
            for i32 i = 0; i < rsa.qlen; i++ { sc.rsa_sign.q[i] = rsa.q[i]; }
            for i32 i = 0; i < rsa.dplen; i++ { sc.rsa_sign.dp[i] = rsa.dp[i]; }
            for i32 i = 0; i < rsa.dqlen; i++ { sc.rsa_sign.dq[i] = rsa.dq[i]; }
            for i32 i = 0; i < rsa.qinvlen; i++ { sc.rsa_sign.qinv[i] = rsa.qinv[i]; }
        }
        sc.ctx.sign_certificate = &sc.rsa_sign.super;
    }
    // no verify_certificate: client-certificate auth is out of scope

    g_server_ctxs[slot] = sc;
    return slot;
}

void tls_server_ctx_free(i32 id) {
    if id < 0 || id >= TLS_SERVER_CTX_MAX { return; }
    TlsServerCtx* sc = g_server_ctxs[id];
    if sc == null { return; }
    free(cast(void*, sc.cert_der));
    free(cast(void*, sc));
    g_server_ctxs[id] = null;
}

// A server-side session for an already-accepted fd, using the shared context.
TlsSession* tls_server_session_new(i32 ctx_id) {
    if ctx_id < 0 || ctx_id >= TLS_SERVER_CTX_MAX { return null; }
    tls_server_ctxs_init();
    TlsServerCtx* sc = g_server_ctxs[ctx_id];
    if sc == null { return null; }
    TlsSession* s = alloc<TlsSession>(1);
    s.tls = ptls_new(&sc.ctx, 1);   // is_server = 1
    if s.tls == null { free(s); return null; }
    ptls_buffer_init(&s.sendbuf, &s.send_small[0], 1024);
    ptls_buffer_init(&s.recvbuf, &s.recv_small[0], 8192);
    s.send_off = 0;
    s.cipher_in_len = 0;
    s.chain_err = 0;
    s.checked_connect = false;
    s.started = false;
    s.is_server = true;
    s.established = false;
    s.failed = false;
    s.eof = false;
    return s;
}

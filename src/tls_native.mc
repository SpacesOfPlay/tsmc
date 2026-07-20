// tls_native.mc -- non-blocking TLS 1.3 client sessions over the vendored
// picotls core (src/tls/). A session wraps a socket fd; the reactor pumps
// it: inbound ciphertext -> ptls_handshake/ptls_receive -> plaintext;
// outbound plaintext -> ptls_send -> ciphertext queued to the socket.
//
// First cut: X25519 + AES-128-GCM-SHA256 (the TLS 1.3 mandatory suite, so
// it interoperates with essentially every server), no certificate
// verification yet (accepts any cert). See doc/PLAN_M34_tls.md.

import "tls/picotls.mc";
import net_os;

// tls_pump result bits.
const i32 TLS_HANDSHAKE_DONE = 1;
const i32 TLS_HAS_DATA = 2;
const i32 TLS_EOF = 4;
const i32 TLS_ERR = 8;
const i32 TLS_WANT_WRITE = 16;

// --- shared client context (built once; must outlive every session) ---

private ptls_key_exchange_algorithm_t g_x25519;
private ptls_aead_algorithm_t g_aes128;
private ptls_cipher_suite_t g_cs128;
private ptls_key_exchange_algorithm_t*[2] g_keyex;
private ptls_cipher_suite_t*[2] g_cslist;
private ptls_context_t g_ctx;
private bool g_inited = false;

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
    g_ctx.get_time = &mc_picotls_get_time;
    g_ctx.key_exchanges = &g_keyex[0];
    g_ctx.cipher_suites = &g_cslist[0];
    // verify_certificate left null -> accept any cert (insecure; TODO trust)
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
    bool started;
    bool established;
    bool failed;
    bool eof;
}

TlsSession* tls_session_new(u8* sni) {
    tls_ctx_init();
    TlsSession* s = alloc<TlsSession>(1);
    s.tls = ptls_new(&g_ctx, 0);
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
    s.started = false;
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
            if r != 0 && r != 514 { s.failed = true; return flags | TLS_ERR; }
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

private bool tls_wants_write(TlsSession* s) {
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
    if !s.started {
        s.started = true;
        u64 c = 0;
        i32 r = ptls_handshake(s.tls, &s.sendbuf, null, &c, null);
        if r != 0 && r != 514 { s.failed = true; return TLS_ERR; }
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

// test_tls.mc -- the vendored picotls TLS 1.3 core runs correctly when
// compiled alongside the tsmc VM + GC. Drives full in-memory handshakes
// (client and server in one process, buffer handoff) with a live VM heap
// so any allocator/ABI conflict between picotls's shims and the GC would
// surface. Two server-auth flavors: raw-Ed25519 (as shipped) and
// raw-ECDSA-P256, the latter exercising the tsmc-added P-256 sign bridge
// (src/tls/picotls_bridges_p256.mc). Exit 0 = pass.

import str;
import "../helpers/check.mc";
import "../helpers/rsa_key_fixture.mc";
import "../../src/value.mc";
import "../../src/object.mc";
import "../../src/vm.mc";
import "../../src/tls/picotls.mc";

// --- shared TLS 1.3 crypto config (X25519 / AES-128-GCM / SHA-256) ---------

private ptls_key_exchange_algorithm_t g_x25519;
private ptls_aead_algorithm_t g_aes128;
private ptls_cipher_suite_t g_cs;
private ptls_key_exchange_algorithm_t*[2] g_keyex;
private ptls_cipher_suite_t*[2] g_cslist;
private bool g_crypto_inited = false;

private void init_crypto() {
    if g_crypto_inited { return; }
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
    g_cs = ptls_cipher_suite_t{
        .id = cast(u16, 4865),
        .aead = &g_aes128,
        .hash = cast(ptls_hash_algorithm_t*, &ptls_minicrypto_sha256),
        .name = "TLS_AES_128_GCM_SHA256",
    };
    g_keyex[0] = &g_x25519;
    g_keyex[1] = null;
    g_cslist[0] = &g_cs;
    g_cslist[1] = null;
    g_crypto_inited = true;
}

// Common context fields shared by both endpoints.
private void fill_ctx(ptls_context_t* ctx) {
    ctx.random_bytes = mc_csprng_bytes;
    ctx.get_time = &mc_picotls_get_time;
    ctx.key_exchanges = &g_keyex[0];
    ctx.cipher_suites = &g_cslist[0];
}

// The handshake message exchange, independent of the server-auth flavor.
// Returns true iff both sides reach completion.
private bool drive_handshake(ptls_t* cli, ptls_t* srv) {
    ptls_buffer_t cli_buf;  u8[4096] cb_small;  ptls_buffer_init(&cli_buf, &cb_small[0], 4096);
    ptls_buffer_t srv_buf;  u8[4096] sb_small;  ptls_buffer_init(&srv_buf, &sb_small[0], 4096);

    u64 cli_in0 = 0;
    if ptls_handshake(cli, &cli_buf, null, &cli_in0, null) != 514 { return false; }

    u64 srv_in = cli_buf.off;
    i32 srv_r = ptls_handshake(srv, &srv_buf, cast(void*, cli_buf.base), &srv_in, null);
    if srv_r != 0 && srv_r != 514 { return false; }

    cli_buf.off = 0;
    u64 cli_in_2 = srv_buf.off;
    i32 cli_r2 = ptls_handshake(cli, &cli_buf, cast(void*, srv_buf.base), &cli_in_2, null);
    if cli_r2 != 0 && cli_r2 != 514 { return false; }

    // The client may consume the server's whole flight in one call, or stop
    // partway and need a second with the remainder; accept either shape.
    bool cli_done = ptls_handshake_is_complete(cli) != 0;
    if !cli_done && cli_in_2 < srv_buf.off {
        u64 remain = srv_buf.off - cli_in_2;
        u8* rest = srv_buf.base + cli_in_2;
        cli_buf.off = 0;
        u64 cli_in_3 = remain;
        if ptls_handshake(cli, &cli_buf, cast(void*, rest), &cli_in_3, null) != 0 { return false; }
        cli_done = ptls_handshake_is_complete(cli) != 0;
    }

    bool srv_done = false;
    if cli_buf.off > 0 {
        u64 srv_in_2 = cli_buf.off;
        if ptls_handshake(srv, &srv_buf, cast(void*, cli_buf.base), &srv_in_2, null) != 0 { return false; }
        srv_done = ptls_handshake_is_complete(srv) != 0;
    }

    ptls_buffer_dispose(&cli_buf);
    ptls_buffer_dispose(&srv_buf);
    return cli_done && srv_done;
}

// Raw-Ed25519 server cert (as picotls-minc ships).
private bool run_handshake_ed25519() {
    init_crypto();
    u8[32] srv_seed = {
        1,2,3,4,5,6,7,8, 9,10,11,12,13,14,15,16,
        17,18,19,20,21,22,23,24, 25,26,27,28,29,30,31,32,
    };
    u8[64] srv_sk;
    u8[32] srv_pk;
    crypto_eddsa_key_pair(&srv_sk[0], &srv_pk[0], &srv_seed[0]);

    u8[44] srv_cert_der;
    u8[12] spki_prefix = {
        0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65,
        0x70, 0x03, 0x21, 0x00,
    };
    for u64 i = 0; i < 12; i++ { srv_cert_der[i] = spki_prefix[i]; }
    for u64 i = 0; i < 32; i++ { srv_cert_der[12 + i] = srv_pk[i]; }
    ptls_iovec_t[1] srv_certs;
    srv_certs[0] = ptls_iovec_init(&srv_cert_der[0], 44);

    sign_cert_ctx_t srv_sign_ctx = sign_cert_ctx_t{
        .super = ptls_sign_certificate_t{ .cb = ed25519_pl_sign_certificate },
    };
    for u64 i = 0; i < 64; i++ { srv_sign_ctx.secret_key[i] = srv_sk[i]; }

    ptls_context_t srv_ctx = ptls_context_t{};
    fill_ctx(&srv_ctx);
    srv_ctx.use_raw_public_keys = cast(u32, 1);
    srv_ctx.certificates.list = &srv_certs[0];
    srv_ctx.certificates.count = cast(u64, 1);
    srv_ctx.sign_certificate = &srv_sign_ctx.super;

    ptls_context_t cli_ctx = ptls_context_t{};
    fill_ctx(&cli_ctx);
    cli_ctx.use_raw_public_keys = cast(u32, 1);
    ptls_verify_certificate_t verify_cert = ptls_verify_certificate_t{};
    verify_cert.cb = ed25519_pl_verify_cert_cb;
    verify_cert.algos = &ed25519_pl_verify_algos[0];
    cli_ctx.verify_certificate = &verify_cert;

    ptls_t* cli = ptls_new(&cli_ctx, 0);
    if cli == null { return false; }
    ptls_t* srv = ptls_new(&srv_ctx, 1);
    if srv == null { ptls_free(cli); return false; }
    bool ok = drive_handshake(cli, srv);
    ptls_free(cli);
    ptls_free(srv);
    return ok;
}

// Raw-ECDSA-P256 server cert: a freshly generated P-256 key, its
// SubjectPublicKeyInfo presented as the raw cert, signed by the tsmc-added
// ecdsa_p256_pl_sign_certificate and verified by the client.
private bool run_handshake_ecdsa() {
    init_crypto();
    mc_ecdsa_p256_sign_init();

    u8[64] srv_pub;   // X || Y
    u8[32] srv_priv;  // scalar
    if uECC_make_key(&srv_pub[0], &srv_priv[0], uECC_secp256r1()) != 1 { return false; }

    // Standard EC P-256 SubjectPublicKeyInfo: AlgId(id-ecPublicKey, prime256v1)
    // then a BIT STRING holding the uncompressed point (0x04 || X || Y).
    u8[27] spki_prefix = {
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86,
        0x48, 0xCE, 0x3D, 0x02, 0x01, 0x06, 0x08, 0x2A,
        0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03,
        0x42, 0x00, 0x04,
    };
    u8[91] srv_spki;
    for u64 i = 0; i < 27; i++ { srv_spki[i] = spki_prefix[i]; }
    for u64 i = 0; i < 64; i++ { srv_spki[27 + i] = srv_pub[i]; }
    ptls_iovec_t[1] srv_certs;
    srv_certs[0] = ptls_iovec_init(&srv_spki[0], 91);

    ecdsa_sign_cert_ctx_t srv_sign_ctx = ecdsa_sign_cert_ctx_t{
        .super = ptls_sign_certificate_t{ .cb = ecdsa_p256_pl_sign_certificate },
    };
    for u64 i = 0; i < 32; i++ { srv_sign_ctx.private_key[i] = srv_priv[i]; }

    ptls_context_t srv_ctx = ptls_context_t{};
    fill_ctx(&srv_ctx);
    srv_ctx.use_raw_public_keys = cast(u32, 1);
    srv_ctx.certificates.list = &srv_certs[0];
    srv_ctx.certificates.count = cast(u64, 1);
    srv_ctx.sign_certificate = &srv_sign_ctx.super;

    ptls_context_t cli_ctx = ptls_context_t{};
    fill_ctx(&cli_ctx);
    cli_ctx.use_raw_public_keys = cast(u32, 1);
    ptls_verify_certificate_t verify_cert = ptls_verify_certificate_t{};
    verify_cert.cb = ecdsa_p256_raw_verify_cert_cb;
    verify_cert.algos = &ecdsa_p256_pl_verify_algos[0];
    cli_ctx.verify_certificate = &verify_cert;

    ptls_t* cli = ptls_new(&cli_ctx, 0);
    if cli == null { return false; }
    ptls_t* srv = ptls_new(&srv_ctx, 1);
    if srv == null { ptls_free(cli); return false; }
    bool ok = drive_handshake(cli, srv);
    ptls_free(cli);
    ptls_free(srv);
    return ok;
}

// RSASSA-PSS sign (private d) round-trips through the existing verify (public
// e) for all three TLS 1.3 hash lengths, on the 2048-bit fixture key. Both
// sides take the same message digest, so a fixed synthetic digest exercises
// the sign/encode + modexp + verify path without needing the private hash.
private bool run_rsa_sign_verify() {
    i32[3] hlens = { 32, 48, 64 };
    for i32 k = 0; k < 3; k = k + 1 {
        i32 hlen = hlens[k];
        u8[64] mhash;
        for i32 i = 0; i < hlen; i = i + 1 { mhash[i] = cast(u8, (i * 7 + 3) & 0xFF); }
        u8[512] sig;
        if !mc_rsa_pss_sign(&RSA_TEST_N[0], RSA_TEST_KLEN, &RSA_TEST_D[0], RSA_TEST_KLEN,
                            hlen, &mhash[0], &sig[0]) { return false; }
        if !rsa_pss_verify(&RSA_TEST_N[0], RSA_TEST_KLEN, RSA_TEST_E,
                           &sig[0], RSA_TEST_KLEN, &mhash[0], hlen) { return false; }
        // a tampered signature must NOT verify
        sig[10] = cast(u8, cast(i32, sig[10]) ^ 1);
        if rsa_pss_verify(&RSA_TEST_N[0], RSA_TEST_KLEN, RSA_TEST_E,
                          &sig[0], RSA_TEST_KLEN, &mhash[0], hlen) { return false; }
    }
    return true;
}

// The CRT private operation produces EXACTLY the same signature as the plain
// EM^d mod n, over several message representatives, and the result verifies.
// The CRT==plain equality is deterministic (no PSS salt here — the raw op is
// applied to a fixed EM), so it is an exact cross-check of the new bignum.
private bool run_rsa_crt() {
    for i32 t = 0; t < 6; t = t + 1 {
        // a fixed EM < n: top byte 0x01 (< n's 0xc3), rest a per-t pattern
        u8[256] em;
        em[0] = cast(u8, 0x01);
        for i32 i = 1; i < RSA_TEST_KLEN; i = i + 1 {
            em[i] = cast(u8, (i * (t + 1) + 17) & 0xFF);
        }
        u8[256] s_plain;
        u8[256] s_crt;
        if !mc_rsa_privop_plain(&RSA_TEST_N[0], RSA_TEST_KLEN, &RSA_TEST_D[0], RSA_TEST_KLEN,
                                &em[0], RSA_TEST_KLEN, &s_plain[0]) { return false; }
        if !mc_rsa_privop_crt(&RSA_TEST_P[0], RSA_TEST_HLEN, &RSA_TEST_Q[0], RSA_TEST_HLEN,
                              &RSA_TEST_DP[0], RSA_TEST_HLEN, &RSA_TEST_DQ[0], RSA_TEST_HLEN,
                              &RSA_TEST_QINV[0], RSA_TEST_HLEN, RSA_TEST_KLEN,
                              &em[0], RSA_TEST_KLEN, &s_crt[0]) { return false; }
        for i32 i = 0; i < RSA_TEST_KLEN; i = i + 1 {
            if s_plain[i] != s_crt[i] { return false; }
        }
        // sanity: s^e mod n == em (the private op really inverts the public one)
        u8[256] back;
        if !mc_rsa_pub_modexp(&RSA_TEST_N[0], RSA_TEST_KLEN, RSA_TEST_E,
                              &s_crt[0], RSA_TEST_KLEN, &back[0]) { return false; }
        for i32 i = 0; i < RSA_TEST_KLEN; i = i + 1 {
            if back[i] != em[i] { return false; }
        }
    }
    // a full PSS sign through the CRT path still verifies
    u8[64] mhash;
    for i32 i = 0; i < 32; i = i + 1 { mhash[i] = cast(u8, (i * 11 + 5) & 0xFF); }
    u8[600] pem;
    i32 pemlen = 0;
    if !mc_rsa_pss_prepare(32, &mhash[0], RSA_TEST_KLEN, &RSA_TEST_N[0], &pem[0], &pemlen) { return false; }
    u8[256] sig;
    if !mc_rsa_privop_crt(&RSA_TEST_P[0], RSA_TEST_HLEN, &RSA_TEST_Q[0], RSA_TEST_HLEN,
                          &RSA_TEST_DP[0], RSA_TEST_HLEN, &RSA_TEST_DQ[0], RSA_TEST_HLEN,
                          &RSA_TEST_QINV[0], RSA_TEST_HLEN, RSA_TEST_KLEN,
                          &pem[0], pemlen, &sig[0]) { return false; }
    return rsa_pss_verify(&RSA_TEST_N[0], RSA_TEST_KLEN, RSA_TEST_E,
                          &sig[0], RSA_TEST_KLEN, &mhash[0], 32);
}

i32 main() {
    // Live VM heap alongside picotls: exercises both allocators together.
    VM m;
    vm_init(&m);
    GcString* g = gc_new_string(&m.heap, "coexist");
    gc_root(&m.heap, value_cell(&g.head));

    check(run_handshake_ed25519(), "in-memory TLS 1.3 handshake (Ed25519 server cert)");
    check(run_handshake_ecdsa(), "in-memory TLS 1.3 handshake (ECDSA-P256 server cert)");
    check(run_rsa_sign_verify(), "RSASSA-PSS sign/verify round-trip (2048-bit, sha256/384/512)");
    check(run_rsa_crt(), "RSA CRT private op equals plain EM^d mod n, and verifies");

    gc_collect(&m.heap);
    check(str_equal(gc_string_view(g), "coexist"), "GC heap intact after handshakes");
    vm_destroy(&m);
    return check_done("tls");
}

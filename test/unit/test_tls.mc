// test_tls.mc -- the vendored picotls TLS 1.3 core runs correctly when
// compiled alongside the tsmc VM + GC. Drives a full in-memory handshake
// (client and server in one process, buffer handoff) with a live VM heap
// so any allocator/ABI conflict between picotls's shims and the GC would
// surface. Exit 0 = pass.

import str;
import "../helpers/check.mc";
import "../../src/value.mc";
import "../../src/object.mc";
import "../../src/vm.mc";
import "../../src/tls/picotls.mc";

// A full TLS 1.3 handshake over in-memory buffers (X25519 / AES-128-GCM /
// SHA-256, raw-Ed25519 server cert). Returns true iff both sides complete.
private bool run_handshake() {
    ptls_key_exchange_algorithm_t x25519_algo = ptls_key_exchange_algorithm_t{
        .id = cast(u16, 29),
        .create = x25519_pl_create,
        .exchange = x25519_pl_exchange,
        .data = cast(i64, 0),
        .name = "x25519",
    };
    ptls_aead_algorithm_t aes128gcm_algo = ptls_aead_algorithm_t{
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
    ptls_cipher_suite_t cs = ptls_cipher_suite_t{
        .id = cast(u16, 4865),
        .aead = &aes128gcm_algo,
        .hash = cast(ptls_hash_algorithm_t*, &ptls_minicrypto_sha256),
        .name = "TLS_AES_128_GCM_SHA256",
    };
    ptls_key_exchange_algorithm_t*[2] keyex_list;
    keyex_list[0] = &x25519_algo;
    keyex_list[1] = null;
    ptls_cipher_suite_t*[2] cs_list;
    cs_list[0] = &cs;
    cs_list[1] = null;

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
    srv_ctx.random_bytes = mc_csprng_bytes;
    srv_ctx.get_time = &mc_picotls_get_time;
    srv_ctx.key_exchanges = &keyex_list[0];
    srv_ctx.cipher_suites = &cs_list[0];
    srv_ctx.use_raw_public_keys = cast(u32, 1);
    srv_ctx.certificates.list = &srv_certs[0];
    srv_ctx.certificates.count = cast(u64, 1);
    srv_ctx.sign_certificate = &srv_sign_ctx.super;

    ptls_context_t cli_ctx = ptls_context_t{};
    cli_ctx.random_bytes = mc_csprng_bytes;
    cli_ctx.get_time = &mc_picotls_get_time;
    cli_ctx.key_exchanges = &keyex_list[0];
    cli_ctx.cipher_suites = &cs_list[0];
    cli_ctx.use_raw_public_keys = cast(u32, 1);
    ptls_verify_certificate_t verify_cert = ptls_verify_certificate_t{};
    verify_cert.cb = ed25519_pl_verify_cert_cb;
    verify_cert.algos = &ed25519_pl_verify_algos[0];
    cli_ctx.verify_certificate = &verify_cert;

    ptls_t* cli = ptls_new(&cli_ctx, 0);
    if cli == null { return false; }
    ptls_t* srv = ptls_new(&srv_ctx, 1);
    if srv == null { return false; }

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

    bool cli_done = false;
    if cli_in_2 < srv_buf.off {
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

    ptls_free(cli);
    ptls_free(srv);
    ptls_buffer_dispose(&cli_buf);
    ptls_buffer_dispose(&srv_buf);
    return cli_done && srv_done;
}

i32 main() {
    // Live VM heap alongside picotls: exercises both allocators together.
    VM m;
    vm_init(&m);
    GcString* g = gc_new_string(&m.heap, "coexist");
    gc_root(&m.heap, value_cell(&g.head));

    bool ok = run_handshake();
    check(ok, "in-memory TLS 1.3 handshake completes inside the tsmc build");

    gc_collect(&m.heap);
    check(str_equal(gc_string_view(g), "coexist"), "GC heap intact after handshake");
    vm_destroy(&m);
    return check_done("tls");
}

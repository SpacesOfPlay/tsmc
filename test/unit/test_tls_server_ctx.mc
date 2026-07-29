// test_tls_server_ctx.mc -- a server TLS context carries the whole
// certificate chain it was given.
//
// A leaf issued by an intermediate cannot be verified from the leaf alone: a
// client holds root certificates only, so the intermediate has to travel with
// the leaf. The context therefore has to keep every certificate handed to it,
// in order, leaf first. Exit 0 = pass.

import str;
import "../helpers/check.mc";
import "../../src/tls_native.mc";

// A real EC P-256 private key in SEC1 DER (the one test/diff/https_server uses).
// The context parses the key, so a stand-in will not do here.
private u8[121] TEST_KEY_DER = {
    48, 119, 2, 1, 1, 4, 32, 232, 115, 187, 68, 143,
    127, 132, 44, 119, 116, 133, 61, 168, 146, 64, 43, 12,
    210, 185, 39, 76, 40, 2, 14, 153, 253, 230, 244, 179,
    73, 119, 35, 160, 10, 6, 8, 42, 134, 72, 206, 61,
    3, 1, 7, 161, 68, 3, 66, 0, 4, 90, 58, 176,
    253, 114, 75, 136, 185, 105, 107, 11, 117, 12, 251, 99,
    95, 112, 111, 28, 248, 15, 71, 206, 248, 124, 156, 69,
    224, 95, 28, 50, 95, 197, 128, 208, 163, 51, 71, 63,
    180, 18, 111, 246, 136, 58, 58, 18, 43, 163, 20, 156,
    200, 202, 25, 69, 220, 177, 191, 105, 124, 202, 84, 186,
    57
};

private bool run_chain_kept() {
    // the certificates themselves are copied rather than parsed, so stand-ins
    // with distinct lengths are enough to see where each one lands
    u8[300] blob;
    for i32 i = 0; i < 300; i++ { blob[i] = cast(u8, i & 255); }
    i32[3] lens;
    lens[0] = 100;
    lens[1] = 150;
    lens[2] = 50;

    i32 one = tls_server_ctx_new(&blob[0], &lens[0], 1, &TEST_KEY_DER[0], cast(u64, 121));
    if one < 0 { return false; }
    if tls_server_ctx_cert_count(one) != 1 { return false; }
    if tls_server_ctx_cert_len(one, 0) != 100 { return false; }
    tls_server_ctx_free(one);

    i32 three = tls_server_ctx_new(&blob[0], &lens[0], 3, &TEST_KEY_DER[0], cast(u64, 121));
    if three < 0 { return false; }
    if tls_server_ctx_cert_count(three) != 3 { return false; }
    if tls_server_ctx_cert_len(three, 0) != 100 { return false; }
    if tls_server_ctx_cert_len(three, 1) != 150 { return false; }
    if tls_server_ctx_cert_len(three, 2) != 50 { return false; }
    tls_server_ctx_free(three);
    return true;
}

private bool run_chain_limits() {
    u8[300] blob;
    for i32 i = 0; i < 300; i++ { blob[i] = cast(u8, 0); }
    i32[8] lens;
    for i32 i = 0; i < 8; i++ { lens[i] = 10; }
    // more certificates than the context holds is refused, not truncated: a
    // silently shortened chain is exactly the failure this guards against
    if tls_server_ctx_new(&blob[0], &lens[0], TLS_CHAIN_MAX + 1,
                          &TEST_KEY_DER[0], cast(u64, 121)) >= 0 { return false; }
    if tls_server_ctx_new(&blob[0], &lens[0], 0,
                          &TEST_KEY_DER[0], cast(u64, 121)) >= 0 { return false; }
    // a zero-length certificate is not a certificate
    lens[1] = 0;
    if tls_server_ctx_new(&blob[0], &lens[0], 3,
                          &TEST_KEY_DER[0], cast(u64, 121)) >= 0 { return false; }
    return true;
}

private bool run_bad_key() {
    u8[10] blob;
    for i32 i = 0; i < 10; i++ { blob[i] = cast(u8, 0); }
    i32[1] lens;
    lens[0] = 10;
    u8[4] junk;
    for i32 i = 0; i < 4; i++ { junk[i] = cast(u8, 1); }
    return tls_server_ctx_new(&blob[0], &lens[0], 1, &junk[0], cast(u64, 4)) < 0;
}

i32 main() {
    check(run_chain_kept(), "server context keeps every certificate, leaf first");
    check(run_chain_limits(), "an over-long, empty or malformed chain is refused");
    check(run_bad_key(), "an unparseable private key is refused");
    return check_done("tls_server_ctx");
}

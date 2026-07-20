// Imports added on export so this module resolves standalone (LSP).
import cstdlib_shim;
import cfile_shim;
import picotls_shim;
import picotls_lib;

// picotls bridges — cifra + monocypher backends for picotls.

// HPKE stub. Satisfies the linker; no backend included.
i32 ptls_hpke_setup_base_s(ptls_hpke_kem_t* kem,
                           ptls_hpke_cipher_suite_t* cipher,
                           ptls_iovec_t* pk_s,
                           ptls_aead_context_t** ctx,
                           ptls_iovec_t pk_r,
                           ptls_iovec_t info) {
    return 0 - 1;
}


// --- SHA-256 ---

struct cifra_sha256_picotls_ctx_t {
    ptls_hash_context_t super;
    cf_sha256_context state;
}

private {
void cifra_sha256_pl_update(ptls_hash_context_t* base_ctx, void* src, u64 len) {
    cifra_sha256_picotls_ctx_t* ctx = cast(cifra_sha256_picotls_ctx_t*, base_ctx);
    cf_sha256_update(&ctx.state, src, len);
}
}

private {
void cifra_sha256_pl_final(ptls_hash_context_t* base_ctx, void* md, ptls_hash_final_mode_t mode) {
    cifra_sha256_picotls_ctx_t* ctx = cast(cifra_sha256_picotls_ctx_t*, base_ctx);
    // md may be null when only releasing the context.
    if mode == PTLS_HASH_FINAL_MODE_SNAPSHOT {
        if md != null {
            cf_sha256_context copy = ctx.state;
            cf_sha256_digest(&copy, cast(u8*, md));
        }
        return;
    }
    if md != null {
        cf_sha256_digest_final(&ctx.state, cast(u8*, md));
    }
    if mode == PTLS_HASH_FINAL_MODE_RESET {
        cf_sha256_init(&ctx.state);
        return;
    }
    free(cast(void*, ctx));
}
}

private {
ptls_hash_context_t* cifra_sha256_pl_clone(ptls_hash_context_t* base_src) {
    cifra_sha256_picotls_ctx_t* src = cast(cifra_sha256_picotls_ctx_t*, base_src);
    cifra_sha256_picotls_ctx_t* dst = new(cifra_sha256_picotls_ctx_t);
    *dst = *src;
    return cast(ptls_hash_context_t*, dst);
}
}

private {
ptls_hash_context_t* cifra_sha256_pl_create() {
    cifra_sha256_picotls_ctx_t* ctx = new(cifra_sha256_picotls_ctx_t);
    ctx.super.update = cifra_sha256_pl_update;
    ctx.super.final = cifra_sha256_pl_final;
    ctx.super.clone_ = cifra_sha256_pl_clone;
    cf_sha256_init(&ctx.state);
    return cast(ptls_hash_context_t*, &ctx.super);
}
}

const ptls_hash_algorithm_t ptls_minicrypto_sha256 = ptls_hash_algorithm_t{
    .name = "sha256",
    .block_size = 64,
    .digest_size = 32,
    .create = cifra_sha256_pl_create,
    .empty_digest = {
        0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14,
        0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9, 0x24,
        0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c,
        0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
    },
};

// --- Ed25519 signature verify (monocypher) ---

struct ed25519_verify_ctx_t {
    u8[32] public_key;
}

type verify_sign_fn = fn(void*, u16, ptls_iovec_t, ptls_iovec_t): i32;

i32 ed25519_pl_verify_sign(void* verify_ctx, u16 algo,
                            ptls_iovec_t data, ptls_iovec_t sig) {
    if algo != cast(u16, 2055) { return 0 - 1; }   // 0x0807
    if sig.len != 64 { return 0 - 1; }
    ed25519_verify_ctx_t* ctx = cast(ed25519_verify_ctx_t*, verify_ctx);
    i32 r = crypto_eddsa_check(sig.base, &ctx.public_key[0], data.base, data.len);
    // Always free the ctx — single-use.
    if r != 0 { free(verify_ctx); return 0 - 1; }
    free(verify_ctx);
    return 0;
}

void* ed25519_pl_make_verify_ctx(u8* peer_pubkey) {
    ed25519_verify_ctx_t* ctx = new(ed25519_verify_ctx_t);
    for u64 i = 0; i < 32; i++ { ctx.public_key[i] = peer_pubkey[i]; }
    return cast(void*, ctx);
}

// Client cert callback for raw-pubkey servers. Extracts the
// 32-byte Ed25519 pubkey from the SPKI tail.
i32 ed25519_pl_verify_cert_cb(ptls_verify_certificate_t* self,
                              ptls_t* tls, u8* server_name,
                              verify_sign_fn* out_verify_sign,
                              void** out_verify_data,
                              ptls_iovec_t* certs, u64 num_certs) {
    if num_certs == 0 || certs[0].len < cast(u64, 32) { return 0 - 1; }
    u8* pubkey = certs[0].base + certs[0].len - cast(u64, 32);
    *out_verify_sign = ed25519_pl_verify_sign;
    *out_verify_data = ed25519_pl_make_verify_ctx(pubkey);
    eprint("ed25519_pl_verify_cert_cb returning 0\n");
    return 0;
}

// Ed25519 only. 0xffff terminates.
u16[2] ed25519_pl_verify_algos = { 2055, 65535 };

// --- Server-side Ed25519 sign (raw-pubkey server) ---

struct sign_cert_ctx_t {
    ptls_sign_certificate_t super;
    u8[64] secret_key;
}

i32 ed25519_pl_sign_certificate(ptls_sign_certificate_t* self,
                                ptls_t* tls,
                                ptls_async_job_t** async_job,
                                u16* selected_algorithm,
                                ptls_buffer_t* output,
                                ptls_iovec_t input,
                                u16* algorithms,
                                u64 num_algorithms) {
    sign_cert_ctx_t* ctx = cast(sign_cert_ctx_t*, self);
    bool ed_supported = false;
    for u64 i = 0; i < num_algorithms; i++ {
        if algorithms[i] == cast(u16, 2055) {   // 0x0807 = ed25519
            ed_supported = true;
            break;
        }
    }
    if !ed_supported { return 0 - 1; }
    *selected_algorithm = cast(u16, 2055);
    u8[64] sig;
    crypto_eddsa_sign(&sig[0], &ctx.secret_key[0], input.base, input.len);
    if ptls_buffer__do_pushv(output, &sig[0], 64) != 0 { return 0 - 1; }
    return 0;
}


// --- SHA-384 ---

struct cifra_sha384_picotls_ctx_t {
    ptls_hash_context_t super;
    cf_sha512_context state;
}

private {
void cifra_sha384_pl_update(ptls_hash_context_t* base_ctx, void* src, u64 len) {
    cifra_sha384_picotls_ctx_t* ctx = cast(cifra_sha384_picotls_ctx_t*, base_ctx);
    cf_sha384_update(&ctx.state, src, len);
}
}

private {
void cifra_sha384_pl_final(ptls_hash_context_t* base_ctx, void* md, ptls_hash_final_mode_t mode) {
    cifra_sha384_picotls_ctx_t* ctx = cast(cifra_sha384_picotls_ctx_t*, base_ctx);
    if mode == PTLS_HASH_FINAL_MODE_SNAPSHOT {
        if md != null {
            cf_sha512_context copy = ctx.state;
            cf_sha384_digest(&copy, cast(u8*, md));
        }
        return;
    }
    if md != null {
        cf_sha384_digest_final(&ctx.state, cast(u8*, md));
    }
    if mode == PTLS_HASH_FINAL_MODE_RESET {
        cf_sha384_init(&ctx.state);
        return;
    }
    free(cast(void*, ctx));
}
}

private {
ptls_hash_context_t* cifra_sha384_pl_clone(ptls_hash_context_t* base_src) {
    cifra_sha384_picotls_ctx_t* src = cast(cifra_sha384_picotls_ctx_t*, base_src);
    cifra_sha384_picotls_ctx_t* dst = new(cifra_sha384_picotls_ctx_t);
    *dst = *src;
    return cast(ptls_hash_context_t*, dst);
}
}

private {
ptls_hash_context_t* cifra_sha384_pl_create() {
    cifra_sha384_picotls_ctx_t* ctx = new(cifra_sha384_picotls_ctx_t);
    ctx.super.update = cifra_sha384_pl_update;
    ctx.super.final = cifra_sha384_pl_final;
    ctx.super.clone_ = cifra_sha384_pl_clone;
    cf_sha384_init(&ctx.state);
    return cast(ptls_hash_context_t*, &ctx.super);
}
}

const ptls_hash_algorithm_t ptls_minicrypto_sha384 = ptls_hash_algorithm_t{
    .name = "sha384",
    .block_size = 128,
    .digest_size = 48,
    .create = cifra_sha384_pl_create,
    .empty_digest = {
        0x38, 0xb0, 0x60, 0xa7, 0x51, 0xac, 0x96, 0x38,
        0x4c, 0xd9, 0x32, 0x7e, 0xb1, 0xb1, 0xe3, 0x6a,
        0x21, 0xfd, 0xb7, 0x11, 0x14, 0xbe, 0x07, 0x43,
        0x4c, 0x0c, 0xc7, 0xbf, 0x63, 0xf6, 0xe1, 0xda,
        0x27, 0x4e, 0xde, 0xbf, 0xe7, 0x6f, 0x65, 0xfb,
        0xd5, 0x1a, 0xd2, 0xf1, 0x48, 0x98, 0xb9, 0x5b,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
    },
};

// --- AES-128/256-GCM ---

struct aesgcm_picotls_ctx_t {
    ptls_aead_context_t super;
    cf_aes_context aes;
    u8[12] static_iv;
}

// dispose_crypto must not free — picotls owns the allocation and
// frees it.
private {
void aesgcm_pl_dispose(ptls_aead_context_t* base) {
}
}

private {
void aesgcm_pl_get_iv(ptls_aead_context_t* base, void* iv_out) {
    aesgcm_picotls_ctx_t* ctx = cast(aesgcm_picotls_ctx_t*, base);
    u8* out = cast(u8*, iv_out);
    for u64 i = 0; i < 12; i++ { out[i] = ctx.static_iv[i]; }
}
}

private {
void aesgcm_pl_set_iv(ptls_aead_context_t* base, void* iv_in) {
    aesgcm_picotls_ctx_t* ctx = cast(aesgcm_picotls_ctx_t*, base);
    u8* in_iv = cast(u8*, iv_in);
    for u64 i = 0; i < 12; i++ { ctx.static_iv[i] = in_iv[i]; }
}
}

// Per-record nonce = static_iv XOR seq.
private {
void build_aesgcm_nonce(u8* nonce_out, u8* static_iv, u64 seq) {
    for u64 i = 0; i < 12; i++ { nonce_out[i] = static_iv[i]; }
    for u64 i = 0; i < 8; i++ {
        u8 b = cast(u8, (seq >> (i * cast(u64, 8))) & cast(u64, 255));
        nonce_out[11 - i] = nonce_out[11 - i] ^ b;
    }
}
}

private { void aesgcm_pl_encrypt(ptls_aead_context_t* base, void* output, void* input, u64 inlen,
                                 u64 seq, void* aad, u64 aadlen,
                                 ptls_aead_supplementary_encryption_t* supp) {
    aesgcm_picotls_ctx_t* ctx = cast(aesgcm_picotls_ctx_t*, base);
    u8[12] nonce;
    build_aesgcm_nonce(&nonce[0], &ctx.static_iv[0], seq);
    u8* out = cast(u8*, output);
    cf_gcm_encrypt(&cf_aes, cast(void*, &ctx.aes),
                   cast(u8*, input), inlen,
                   cast(u8*, aad), aadlen,
                   &nonce[0], 12,
                   out, out + inlen, 16);
}
}

private { void aesgcm_pl_encrypt_v(ptls_aead_context_t* base, void* output, ptls_iovec_t* input, u64 incnt,
                                   u64 seq, void* aad, u64 aadlen) {
    u64 total = 0;
    for u64 i = 0; i < incnt; i++ { total = total + input[i].len; }
    u8* tmp = alloc<u8>(total);
    u64 off = 0;
    for u64 i = 0; i < incnt; i++ {
        u8* src = input[i].base;
        for u64 j = 0; j < input[i].len; j++ { *(tmp + off + j) = src[j]; }
        off = off + input[i].len;
    }
    aesgcm_pl_encrypt(base, output, cast(void*, tmp), total, seq, aad, aadlen, null);
    free(cast(void*, tmp));
}
}

private { u64 aesgcm_pl_decrypt(ptls_aead_context_t* base, void* output, void* input, u64 inlen,
                                u64 seq, void* aad, u64 aadlen) {
    aesgcm_picotls_ctx_t* ctx = cast(aesgcm_picotls_ctx_t*, base);
    if inlen < 16 { return cast(u64, 0 - 1); }
    u64 plain_len = inlen - 16;
    u8[12] nonce;
    build_aesgcm_nonce(&nonce[0], &ctx.static_iv[0], seq);
    u8* in_buf = cast(u8*, input);
    i32 ret = cf_gcm_decrypt(&cf_aes, cast(void*, &ctx.aes),
                             in_buf, plain_len,
                             cast(u8*, aad), aadlen,
                             &nonce[0], 12,
                             in_buf + plain_len, 16,
                             cast(u8*, output));
    if ret != 0 { return cast(u64, 0 - 1); }
    return plain_len;
}
}

i32 aesgcm_pl_setup_crypto_128(ptls_aead_context_t* base, i32 is_enc, void* key, void* iv) {
    aesgcm_picotls_ctx_t* ctx = cast(aesgcm_picotls_ctx_t*, base);
    ctx.super.dispose_crypto = aesgcm_pl_dispose;
    ctx.super.do_get_iv = aesgcm_pl_get_iv;
    ctx.super.do_set_iv = aesgcm_pl_set_iv;
    ctx.super.do_encrypt_init = null;
    ctx.super.do_encrypt_update = null;
    ctx.super.do_encrypt_final = null;
    ctx.super.do_encrypt = aesgcm_pl_encrypt;
    ctx.super.do_encrypt_v = aesgcm_pl_encrypt_v;
    ctx.super.do_decrypt = aesgcm_pl_decrypt;
    cf_aes_init(&ctx.aes, cast(u8*, key), 16);
    u8* iv_in = cast(u8*, iv);
    for u64 i = 0; i < 12; i++ { ctx.static_iv[i] = iv_in[i]; }
    return 0;
}

i32 aesgcm_pl_setup_crypto_256(ptls_aead_context_t* base, i32 is_enc, void* key, void* iv) {
    aesgcm_picotls_ctx_t* ctx = cast(aesgcm_picotls_ctx_t*, base);
    ctx.super.dispose_crypto = aesgcm_pl_dispose;
    ctx.super.do_get_iv = aesgcm_pl_get_iv;
    ctx.super.do_set_iv = aesgcm_pl_set_iv;
    ctx.super.do_encrypt_init = null;
    ctx.super.do_encrypt_update = null;
    ctx.super.do_encrypt_final = null;
    ctx.super.do_encrypt = aesgcm_pl_encrypt;
    ctx.super.do_encrypt_v = aesgcm_pl_encrypt_v;
    ctx.super.do_decrypt = aesgcm_pl_decrypt;
    cf_aes_init(&ctx.aes, cast(u8*, key), 32);
    u8* iv_in = cast(u8*, iv);
    for u64 i = 0; i < 12; i++ { ctx.static_iv[i] = iv_in[i]; }
    return 0;
}

// Build an AES-GCM context directly from a raw key + IV.
ptls_aead_context_t* aesgcm_new_direct(u8* key, u8* iv) {
    aesgcm_picotls_ctx_t* ctx = new(aesgcm_picotls_ctx_t);
    ctx.super.algo = null;
    ctx.super.dispose_crypto = aesgcm_pl_dispose;
    ctx.super.do_get_iv = aesgcm_pl_get_iv;
    ctx.super.do_set_iv = aesgcm_pl_set_iv;
    ctx.super.do_encrypt_init = null;
    ctx.super.do_encrypt_update = null;
    ctx.super.do_encrypt_final = null;
    ctx.super.do_encrypt = aesgcm_pl_encrypt;
    ctx.super.do_encrypt_v = aesgcm_pl_encrypt_v;
    ctx.super.do_decrypt = aesgcm_pl_decrypt;
    cf_aes_init(&ctx.aes, key, 16);
    for u64 i = 0; i < 12; i++ { ctx.static_iv[i] = iv[i]; }
    return cast(ptls_aead_context_t*, &ctx.super);
}

ptls_aead_context_t* aes256gcm_new_direct(u8* key, u8* iv) {
    aesgcm_picotls_ctx_t* ctx = new(aesgcm_picotls_ctx_t);
    ctx.super.algo = null;
    ctx.super.dispose_crypto = aesgcm_pl_dispose;
    ctx.super.do_get_iv = aesgcm_pl_get_iv;
    ctx.super.do_set_iv = aesgcm_pl_set_iv;
    ctx.super.do_encrypt_init = null;
    ctx.super.do_encrypt_update = null;
    ctx.super.do_encrypt_final = null;
    ctx.super.do_encrypt = aesgcm_pl_encrypt;
    ctx.super.do_encrypt_v = aesgcm_pl_encrypt_v;
    ctx.super.do_decrypt = aesgcm_pl_decrypt;
    cf_aes_init(&ctx.aes, key, 32);
    for u64 i = 0; i < 12; i++ { ctx.static_iv[i] = iv[i]; }
    return cast(ptls_aead_context_t*, &ctx.super);
}

// --- ChaCha20-Poly1305 ---

struct chapoly_picotls_ctx_t {
    ptls_aead_context_t super;
    u8[32] key;
    u8[12] static_iv;
}

private {
void chapoly_pl_dispose(ptls_aead_context_t* base) {
}
}

private {
void chapoly_pl_get_iv(ptls_aead_context_t* base, void* iv_out) {
    chapoly_picotls_ctx_t* ctx = cast(chapoly_picotls_ctx_t*, base);
    u8* out = cast(u8*, iv_out);
    for u64 i = 0; i < 12; i++ { out[i] = ctx.static_iv[i]; }
}
}

private {
void chapoly_pl_set_iv(ptls_aead_context_t* base, void* iv_in) {
    chapoly_picotls_ctx_t* ctx = cast(chapoly_picotls_ctx_t*, base);
    u8* in_iv = cast(u8*, iv_in);
    for u64 i = 0; i < 12; i++ { ctx.static_iv[i] = in_iv[i]; }
}
}

private { void chapoly_pl_encrypt(ptls_aead_context_t* base, void* output, void* input, u64 inlen,
                                  u64 seq, void* aad, u64 aadlen,
                                  ptls_aead_supplementary_encryption_t* supp) {
    chapoly_picotls_ctx_t* ctx = cast(chapoly_picotls_ctx_t*, base);
    u8[12] nonce;
    build_aesgcm_nonce(&nonce[0], &ctx.static_iv[0], seq);
    u8* out = cast(u8*, output);
    cf_chacha20poly1305_encrypt(&ctx.key[0], &nonce[0],
                                cast(u8*, aad), aadlen,
                                cast(u8*, input), inlen,
                                out, out + inlen);
}
}

private { void chapoly_pl_encrypt_v(ptls_aead_context_t* base, void* output, ptls_iovec_t* input, u64 incnt,
                                    u64 seq, void* aad, u64 aadlen) {
    u64 total = 0;
    for u64 i = 0; i < incnt; i++ { total = total + input[i].len; }
    u8* tmp = alloc<u8>(total);
    u64 off = 0;
    for u64 i = 0; i < incnt; i++ {
        u8* src = input[i].base;
        for u64 j = 0; j < input[i].len; j++ { *(tmp + off + j) = src[j]; }
        off = off + input[i].len;
    }
    chapoly_pl_encrypt(base, output, cast(void*, tmp), total, seq, aad, aadlen, null);
    free(cast(void*, tmp));
}
}

private { u64 chapoly_pl_decrypt(ptls_aead_context_t* base, void* output, void* input, u64 inlen,
                                 u64 seq, void* aad, u64 aadlen) {
    chapoly_picotls_ctx_t* ctx = cast(chapoly_picotls_ctx_t*, base);
    if inlen < 16 { return cast(u64, 0 - 1); }
    u64 plain_len = inlen - 16;
    u8[12] nonce;
    build_aesgcm_nonce(&nonce[0], &ctx.static_iv[0], seq);
    u8* in_buf = cast(u8*, input);
    i32 ret = cf_chacha20poly1305_decrypt(&ctx.key[0], &nonce[0],
                                          cast(u8*, aad), aadlen,
                                          in_buf, plain_len,
                                          in_buf + plain_len,
                                          cast(u8*, output));
    if ret != 0 { return cast(u64, 0 - 1); }
    return plain_len;
}
}

i32 chapoly_pl_setup_crypto(ptls_aead_context_t* base, i32 is_enc, void* key, void* iv) {
    chapoly_picotls_ctx_t* ctx = cast(chapoly_picotls_ctx_t*, base);
    ctx.super.dispose_crypto = chapoly_pl_dispose;
    ctx.super.do_get_iv = chapoly_pl_get_iv;
    ctx.super.do_set_iv = chapoly_pl_set_iv;
    ctx.super.do_encrypt_init = null;
    ctx.super.do_encrypt_update = null;
    ctx.super.do_encrypt_final = null;
    ctx.super.do_encrypt = chapoly_pl_encrypt;
    ctx.super.do_encrypt_v = chapoly_pl_encrypt_v;
    ctx.super.do_decrypt = chapoly_pl_decrypt;
    u8* key_in = cast(u8*, key);
    for u64 i = 0; i < 32; i++ { ctx.key[i] = key_in[i]; }
    u8* iv_in = cast(u8*, iv);
    for u64 i = 0; i < 12; i++ { ctx.static_iv[i] = iv_in[i]; }
    return 0;
}

ptls_aead_context_t* chapoly_new_direct(u8* key, u8* iv) {
    chapoly_picotls_ctx_t* ctx = new(chapoly_picotls_ctx_t);
    ctx.super.algo = null;
    ctx.super.dispose_crypto = chapoly_pl_dispose;
    ctx.super.do_get_iv = chapoly_pl_get_iv;
    ctx.super.do_set_iv = chapoly_pl_set_iv;
    ctx.super.do_encrypt_init = null;
    ctx.super.do_encrypt_update = null;
    ctx.super.do_encrypt_final = null;
    ctx.super.do_encrypt = chapoly_pl_encrypt;
    ctx.super.do_encrypt_v = chapoly_pl_encrypt_v;
    ctx.super.do_decrypt = chapoly_pl_decrypt;
    for u64 i = 0; i < 32; i++ { ctx.key[i] = key[i]; }
    for u64 i = 0; i < 12; i++ { ctx.static_iv[i] = iv[i]; }
    return cast(ptls_aead_context_t*, &ctx.super);
}

// --- X25519 key exchange (monocypher) ---

// RFC 7748 §5.2 Alice scalar — a KAT for the smoke test. The
// runtime exchange/create paths read a fresh scalar from the
// CSPRNG per call.
private {
u8[32] test_x25519_sk = {
    0xa5, 0x46, 0xe3, 0x6b, 0xf0, 0x52, 0x7c, 0x9d,
    0x3b, 0x16, 0x15, 0x4b, 0x82, 0x46, 0x5e, 0xdd,
    0x62, 0x14, 0x4c, 0x0a, 0xc1, 0xfc, 0x5a, 0x18,
    0x50, 0x6a, 0x22, 0x44, 0xba, 0x44, 0x9a, 0xc4,
}; }

private {
u8* malloc_copy(u8* src, u64 n) {
    u8* dst = alloc<u8>(n);
    for u64 i = 0; i < n; i++ { dst[i] = src[i]; }
    return dst;
}
}

i32 x25519_pl_exchange(ptls_key_exchange_algorithm_t* algo,
                       ptls_iovec_t* pubkey, ptls_iovec_t* secret,
                       ptls_iovec_t peerkey) {
    if peerkey.len != 32 { return 1; }
    u8[32] sk;
    mc_csprng_bytes(cast(void*, &sk[0]), cast(u64, 32));
    u8[32] pk_local;
    crypto_x25519_public_key(&pk_local[0], &sk[0]);
    u8[32] secret_local;
    crypto_x25519(&secret_local[0], &sk[0], peerkey.base);
    *pubkey = ptls_iovec_init(malloc_copy(&pk_local[0], 32), 32);
    *secret = ptls_iovec_init(malloc_copy(&secret_local[0], 32), 32);
    return 0;
}

struct x25519_picotls_ctx_t {
    ptls_key_exchange_context_t super;
    u8[32] secret_key;
}

private { i32 x25519_pl_on_exchange(ptls_key_exchange_context_t** keyex,
                                    i32 release, ptls_iovec_t* secret,
                                    ptls_iovec_t peerkey) {
    x25519_picotls_ctx_t* ctx = cast(x25519_picotls_ctx_t*, *keyex);
    if secret != null {
        if peerkey.len != 32 { return 1; }
        u8[32] secret_local;
        crypto_x25519(&secret_local[0], &ctx.secret_key[0], peerkey.base);
        *secret = ptls_iovec_init(malloc_copy(&secret_local[0], 32), 32);
    }
    if release != 0 {
        if ctx.super.pubkey.base != null { free(cast(void*, ctx.super.pubkey.base)); }
        free(cast(void*, ctx));
        *keyex = null;
    }
    return 0;
}
}

i32 x25519_pl_create(ptls_key_exchange_algorithm_t* algo,
                     ptls_key_exchange_context_t** out_ctx) {
    x25519_picotls_ctx_t* ctx = new(x25519_picotls_ctx_t);
    ctx.super.algo = algo;
    ctx.super.on_exchange = x25519_pl_on_exchange;
    mc_csprng_bytes(cast(void*, &ctx.secret_key[0]), cast(u64, 32));
    u8[32] pk_local;
    crypto_x25519_public_key(&pk_local[0], &ctx.secret_key[0]);
    ctx.super.pubkey = ptls_iovec_init(malloc_copy(&pk_local[0], 32), 32);
    *out_ctx = cast(ptls_key_exchange_context_t*, &ctx.super);
    return 0;
}

// --- Time + CSPRNG ---

// Fixed timestamp. Replace mc_picotls_get_time_cb for real wall-clock.
u64 mc_picotls_get_time_cb(st_ptls_get_time_t* self) {
    return cast(u64, 1700000000000);
}
st_ptls_get_time_t mc_picotls_get_time = st_ptls_get_time_t{.cb = mc_picotls_get_time_cb};

// Fill `buf` with cryptographic random bytes from the OS. Safe to
// call from multiple threads.
when os(windows) {
    extern "bcrypt.dll" {
        i32 BCryptGenRandom(void* hAlgorithm, u8* pbBuffer, u32 cbBuffer, u32 dwFlags);
    }
}
when os(linux) {
    extern "libc.so.6" {
        i64 getrandom(u8* buf, u64 buflen, u32 flags);
    }
}

void mc_csprng_bytes(void* buf, u64 len) {
    u8* p = cast(u8*, buf);
    u64 remaining = len;
    when os(windows) {
        while remaining > cast(u64, 0) {
            u32 chunk = remaining > cast(u64, 0x40000000) ? cast(u32, 0x40000000) : cast(u32, remaining);
            BCryptGenRandom(null, p, chunk, cast(u32, 2));
            p = p + chunk;
            remaining = remaining - cast(u64, chunk);
        }
    }
    when os(linux) {
        while remaining > cast(u64, 0) {
            i64 n = getrandom(p, remaining, cast(u32, 0));
            if n <= cast(i64, 0) { return; }
            p = p + cast(u64, n);
            remaining = remaining - cast(u64, n);
        }
    }
}

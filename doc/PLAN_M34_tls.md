# PLAN M34 — TLS / `https` (via vendored picotls)

Stage 3b of `doc/DESIGN_networking.md`. Lights up `https`/`wss` by driving
the vendored picotls TLS 1.3 core (`src/tls/`, DESIGN §4) over the
non-blocking socket reactor. Unblocked as of the minc generic-param fix
(the core now co-compiles with tsmc).

## Increments

1. **Coexistence proof (done).** `test/unit/test_tls.mc` runs a full
   in-memory TLS 1.3 handshake (X25519 / AES-128-GCM / SHA-256, raw
   Ed25519 cert) with a live VM heap alongside, so any allocator/ABI
   clash between picotls's shims and the GC would surface. Green; picotls
   is safe to compile into tsmc.
2. **Native TLS session + non-blocking pump (done).** `src/tls_native.mc`:
   client `ptls_context_t` built once (X25519, AES-128-GCM-SHA256), a
   `TlsSession` wrapping a socket fd with in/out buffers, and `tls_pump` /
   `tls_write` / `tls_read` driving `ptls_handshake`/`receive`/`send`
   non-blocking. Validated by `test/tls/https_get.mc` (manual, network):
   a real non-blocking HTTPS GET to example.com — X25519 + AES-128-GCM +
   ECDSA-P256 cert verify (SPKI pin) → `HTTP/1.1 200 OK`, 829 bytes.
   Key correctness points learned: completion is `ptls_handshake_is_complete`
   (NOT the `ptls_handshake` return code, which is 0 after just
   ServerHello); a non-0/514 `ptls_receive` code is a clean close_notify,
   not an error (keep the decrypted plaintext). `tls_set_ecdsa_pin` is a
   stopgap trust hook until §4.1 general trust.

Original increment-2 scope, for reference — A `src/tls_native.mc` that:
   - builds the client `ptls_context_t` (X25519, the three standard
     ciphersuites, `random_bytes`/`get_time`) once,
   - wraps a socket handle with a `ptls_t*` + in/out `ptls_buffer_t` and a
     plaintext queue,
   - drives the handshake and app-data via `ptls_handshake` /
     `ptls_receive` / `ptls_send` from the reactor dispatch hook (recv
     ciphertext → feed picotls → emit plaintext; JS write → `ptls_send` →
     queue ciphertext to the socket).
   Wires picotls into the tsmc binary (builtins imports it) — accepting
   the ~2x compile-time cost, justified once TLS is in use. Validate with
   a native non-blocking HTTPS GET to a real host (SPKI-pinned; non-gated,
   network-dependent).
3. **JS `tls` module + `https` (done).** picotls is now compiled into the
   tsmc binary (builtins imports `tls_native`; ~60k lines, build still
   ~1s). Native `__tls_connect/pump/read/write/close/established/pin_ecdsa`
   over the handle `ext` pointer (holding the `TlsSession`); the reactor's
   existing dispatch hook drives them via `owner.__onReady`. JS `tls`
   (`src/node_tls.mc`): `TLSSocket` shaped like `net.Socket`
   (`secureConnect`/`connect`/`data`/`end`/`close`), `tls.connect`,
   `tls.setEcdsaPin`. `https` (`src/node_https.mc`) = `http` with `_tls`
   +port 443; `node_http` `ClientRequest` connects via `tls.connect` when
   `_tls`; `node_fetch` routes `https:` through it. **Secure by default:**
   the context defaults to a *reject* verifier (a null one would abort on
   CertificateVerify), so untrusted https fails cleanly (`TLS error`)
   rather than crashing; a pin allows the connection. Verified end to end:
   `fetch('https://example.com')` with the pin returns `200 text/html`
   (`test/tls/https_fetch.js`, manual/network); no-pin rejects gracefully.
   A *gated* loopback https test still needs picotls server mode (below).
4. **Certificate trust.** First cut: SPKI pin / explicit
   `rejectUnauthorized:false` bypass (DESIGN §4.1 option b). CA-bundle
   chain validation is a later milestone.

## Known issues to handle before increment 2

- **Debug prints.** The vendored picotls emits `printf` debug lines (e.g.
  `ed25519_pl_verify_cert_cb returning 0`) that would pollute stdout/stderr
  and break diff tests. Silence them in the vendored copy (or re-export
  without them) before real TLS runs.
- **Context lifetime.** The `ptls_context_t` + algorithm vtables must
  outlive every session (build once, keep rooted/static), not be
  stack-locals as in the examples.

## Out of scope

- TLS 1.2, session resumption / 0-RTT, client certs, ALPN/HTTP-2.
- CA-bundle chain validation (own milestone).
- `wss` (needs a WebSocket layer first).

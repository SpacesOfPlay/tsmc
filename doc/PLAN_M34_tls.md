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
2. **Native TLS session + non-blocking pump.** A `src/tls_native.mc` that:
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
3. **JS `tls` module + `https`.** `tls.connect` → `TLSSocket` shaped like
   `net.Socket` (emits `secureConnect`/`data`/…). `node_http`/`node_fetch`
   switch on `https:` to route through a `TLSSocket`. Loopback https diff
   test with a pinned cert (deterministic).
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

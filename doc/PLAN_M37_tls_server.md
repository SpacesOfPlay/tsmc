# PLAN M37 — TLS 1.3 server (ECDSA-P256, HTTPS)

**Status: planned.**

Stage 5 of the networking roadmap (`memory: networking-roadmap`): an
outbound-and-inbound TLS story. Today tsmc is a TLS *client* only; this
adds a TLS 1.3 **server** presenting a real X.509 certificate, and
`https.createServer`, so a tsmc process can serve HTTPS.

Beyond the feature, this closes a real testing gap: the TLS client
success path is currently verified only *manually* against the internet
(`test/tls/*`, not gated). A loopback server lets the existing client be
exercised against a known peer in the gated suite — the first
hermetic TLS success-path test.

---

## 1. Goal / non-goal

**Goal.** `tls.createServer({ cert, key }, onSecure)` and
`https.createServer({ cert, key }, onRequest)` for an **ECDSA-P256**
certificate, over the vendored picotls in TLS 1.3
(X25519 + AES-128-GCM-SHA256, the same suite the client already speaks).
A hermetic loopback diff test: a tsmc HTTPS server + the tsmc HTTPS
client, byte-identical to the same script under Node.

**Why ECDSA-P256 specifically.** The signing *primitive* (`uECC_sign`)
is already vendored and compiled in — the client's ECDSA *verify* bridge
links uECC. So the server needs a `sign_certificate` bridge and key
parsing, but **no new elliptic-curve math**. (Audit in the networking
memory: Ed25519 signing also exists but is raw-pubkey only, not
X.509-interoperable; RSA signing is genuinely absent — no CRT private
operation — and is a separate, larger milestone.)

**Non-goal (this milestone).** RSA and Ed25519 server certificates;
client-certificate auth (`requestCert`); SNI-based cert selection;
session resumption / 0-RTT; ALPN. Their absence is a clean error or an
ignored option, never a wrong result. A non-ECDSA-P256 `key` is rejected
at `createServer` time with a clear message, not at handshake time.

---

## 2. What must exist (and what already does)

Already present, reused unchanged:
- **`uECC_sign` / `uECC_secp256r1`** — the P-256 signing primitive
  (vendored `picotls_lib.mc`).
- **`ptls_new(ctx, 1)` server mode + `sign_certificate` callback** —
  proven end-to-end in-memory by `test/unit/test_tls.mc` (which stands a
  client and a server up in one process). The callback contract is:
  picotls hands the bridge the already-constructed data-to-sign as
  `input`, and the bridge pushes the raw signature bytes to `output`
  (confirmed from `ed25519_pl_sign_certificate`).
- **The client session/pump** (`src/tls_native.mc`) — the server pump is
  the client pump minus the TCP-connect check and the initial
  ClientHello kick; `tls_feed` already drives both handshake directions.
- **The net accept seam** — `__net_accept` returns a handle id for the
  accepted fd, and `__net_set_owner` decides which JS object the reactor
  pumps. So a connection can be *upgraded* to TLS by swapping the
  handle's session and owner; no new accept loop.

To build:
1. An **ECDSA-P256 `sign_certificate` bridge** (SHA-256 the input,
   `uECC_sign`, DER-encode `r‖s`, advertise `0x0403`).
2. **EC private-key parsing**: PEM → DER in JS (`Buffer.from(b64,
   'base64')`), then a native DER walk to the 32-byte scalar (SEC1
   `ECPrivateKey` and PKCS#8 `PrivateKeyInfo` wrapping it), reusing the
   `tls_x509.mc` DER primitives.
3. A **server context + server session** in `tls_native.mc`, and the
   native surface to build one and wrap an accepted fd.
4. JS `tls.createServer` / `https.createServer`, and the http server
   machinery running over a TLSSocket.

---

## 3. The DER signature encoder (the one fiddly bit of crypto plumbing)

`uECC_sign` yields a flat 64-byte `r‖s`; TLS wants
`SEQUENCE { INTEGER r, INTEGER s }`. Each INTEGER is minimally encoded:
strip leading zero bytes, but if the top bit of the leading byte is set,
prepend one `0x00` so it is not read as negative. Max content per
integer is 33 bytes, so the whole `SEQUENCE` is < 128 bytes and uses
single-byte length encoding — a small fixed buffer, no long-form
lengths. This is the exact inverse of the client's existing
`mc_ecdsa_sig_der_to_raw`, and lands beside it as a `LOCAL ADDITION
(tsmc)` in `picotls_bridges_p256.mc` (re-apply on picotls re-export;
note in `THIRD_PARTY.md`).

---

## 4. Increments

- **I1 — sign bridge + crypto proof.** The DER encoder and
  `ecdsa_p256_pl_sign_certificate` in `picotls_bridges_p256.mc`. A unit
  test that signs a message and verifies it with the existing
  `uECC_verify` path, and — the real proof — an in-memory client+server
  TLS 1.3 handshake using an **ECDSA-P256** server cert (mirroring
  `test_tls.mc`, which today uses Ed25519), asserting both sides
  complete. No JS, no sockets: isolates the crypto.

- **I2 — server session + key parsing.** In `tls_native.mc`: a
  `TlsServerCtx` (its own `ptls_context_t` + sign ctx + owned cert DER,
  sharing the global key-exchange/cipher config) built from
  `(cert_der, key_scalar)`, and a server `TlsSession` (an `is_server`
  flag gating the connect-check and ClientHello kick). EC scalar
  extraction from SEC1 / PKCS#8 DER. Native globals:
  `__tls_server_ctx(certDer, keyDer)` → an id into a small server-context
  registry, and `__tls_server_wrap(handleId, ctxId)` installing a server
  session on an accepted fd. A native round-trip test (loopback socket,
  server-wrap one end, client the other) if practical before the JS
  layer.

- **I3 — JS tls/https server + hermetic diff test.** `tls.createServer`
  (build the ctx from `cert`/`key`, `net.createServer` under it, upgrade
  each connection, surface a server `TLSSocket`), the http server
  running over that socket, and `https.createServer` in `node_https.mc`.
  `test/diff/https_server.js`: a loopback HTTPS GET/POST round-trip, the
  tsmc client hitting the tsmc server, matched byte-for-byte to Node.
  The cert/key are a committed fixture (a long-dated self-signed
  ECDSA-P256 pair; `tools/gen_tls_server_cert.sh` documents
  regeneration, like `gen_ca_roots.sh`). The client uses
  `rejectUnauthorized: false` so the test is self-contained — it still
  verifies the server's CertificateVerify signature against the
  presented leaf key, so the ECDSA *sign*↔*verify* path is exercised for
  real; it just does not require wiring the `ca:` trust option.

- **I4 — docs.** `DESIGN_networking.md` server note,
  `npm-compatibility.md` (HTTPS server now supported), `THIRD_PARTY.md`
  local-addition entry, and the networking memory.

Each increment builds clean and keeps the suite green
(`build.ps1 test`, incl. `--gc-stress`) and the diff harness
byte-identical to Node.

---

## 5. Pitfalls to avoid

- **The server's private key must never reach a verify/trust path.** It
  signs, nothing more. Keep the sign context wholly inside
  `tls_native`; do not expose the scalar to JS after parsing.
- **Handshake completion is `ptls_handshake_is_complete`,** not the
  `ptls_handshake` return code — the same gotcha the client documents;
  the server pump must use it too.
- **Upgrade before the first read.** Swap the accepted fd to a TLS
  session synchronously in the `connection` handler, before any
  plaintext recv, or the ClientHello bytes are lost to the net reader.
- **Re-owning the handle.** After `__tls_server_wrap`, the reactor must
  pump the TLSSocket, not the orphaned net.Socket — set the owner in the
  same step and reset poll interest to the TLS pump's needs.
- **GC roots for the fixture-built context.** `TlsServerCtx` is native
  heap, referenced from a JS-visible id; keep it alive for the server's
  lifetime and free it on `server.close`. Exercise `--gc-stress` on the
  server test (a native-alloc bug there was exactly what gc-stress
  caught in the webapi work).
- **A bad key is a `createServer` error.** Parse and validate the key up
  front; do not defer a wrong-curve or malformed key to a mid-handshake
  failure.

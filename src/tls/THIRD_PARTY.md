# Vendored: picotls-minc (TLS 1.3)

The files in this directory are a vendored subset of **picotls-minc**, a
minc-language port of [picotls](https://github.com/h2o/picotls) (TLS 1.3)
with [cifra](https://github.com/ctz/cifra) (AEAD + hash) and
[monocypher](https://monocypher.org/) (X25519 + Ed25519).

- Snapshot: `transminc @ e952e38`, built 2026-07-20 (see the upstream
  `VERSION`).
- Upstream: the `picotls-minc` project by Mattias Ljungström / Spaces Of
  Play. Regenerated from C via transminc.

## What is vendored (and what is not)

Only the transport-agnostic TLS core and its crypto backends are copied:

| file | role |
|------|------|
| `picotls_lib.mc` | picotls core: `ptls_new/handshake/receive/send/free` + cifra/monocypher crypto |
| `picotls_bridges.mc` | AEAD/hash/key-exchange vtables |
| `picotls_bridges_p256.mc` | ECDSA-P256 cert verify |
| `picotls_bridges_rsa.mc` | RSA-PSS cert verify |
| `picotls_shim.mc` | picotls-specific glue |
| `cstdlib_shim.mc` | libc stand-ins over the program allocator |
| `cfile_shim.mc` | libc `FILE` stand-ins |
| `picotls.mc` | **local** trimmed router (this repo) — imports only the above |

The upstream `net.mc`, `thread.mc`, and `pico_https.mc` (blocking sockets
+ HTTP helper) are **deliberately excluded**: tsmc owns its non-blocking
sockets and event loop and drives TLS purely through the in-memory buffer
API (`ptls_handshake`/`ptls_receive`/`ptls_send`).

Files other than `picotls.mc` are copied verbatim **except** for the local
additions marked `LOCAL ADDITION (tsmc)`. **Re-apply all of them after
re-exporting picotls-minc** (or add them upstream); everything else is
verbatim — refresh by re-copying the list above.

- `ecdsa_p256_accept_verify_cert_cb` (`picotls_bridges_p256.mc`) and
  `rsa_pss_accept_verify_cert_cb` (`picotls_bridges_rsa.mc`): the pinned
  verify callbacks minus the SPKI-pin comparison (accept any cert, still
  verify the handshake signature), needed because the underlying
  `mc_*`/`*_pl_verify_sign` helpers are file-private.
- `mc_rsa_pub_modexp` (`picotls_bridges_rsa.mc`): a generic public
  `in^e mod n` primitive over the file-private bignum, used by the
  certificate-chain signature verifier (`src/tls_verify.mc`) for
  RSASSA-PKCS1-v1_5. The padding/DigestInfo check is done in the caller.

## Trusted root bundle (`ca_roots_data.mc`)

`ca_roots_data.mc` is **generated**, not part of picotls: it is the Mozilla
CA root set extracted via curl's `cacert.pem`
(<https://curl.se/docs/caextract.html>), emitted as one DER blob plus an
offset/length index by `tools/gen_ca_roots.sh`. Refresh periodically by
re-running that tool. The extraction convention and format are curl's (the
bundle is distributed under MPL-2.0); the certificates themselves belong to
their issuing CAs. The lookup logic lives in the hand-written
`src/ca_roots.mc`.

## Licensing

picotls © Kazuho Oku et al. (MIT). cifra © Joseph Birr-Pixton
(public-domain). monocypher © Loup Vaillant (CC0 / BSD-2). The minc port
is © Mattias Ljungström, Spaces Of Play UG. All permissively licensed and
vendorable with this attribution.

## Integration status

Verified to **compile and run a full TLS 1.3 handshake standalone** under
the project's minc (`test/tls/handshake_selftest.mc`). It is **not yet
wired into the `tsmc` binary** — see `doc/DESIGN_networking.md` §4 for the
one remaining blocker (a minc generic-type-parameter name collision) that
the TLS milestone must resolve first.

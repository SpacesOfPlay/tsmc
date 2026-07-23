# PLAN M38 — RSA server certificates (RSASSA-PSS)

**Status: planned.**

The follow-up left open by M37: `https.createServer` / `tls.createServer`
with an **RSA** certificate, alongside the ECDSA-P256 one already
supported. RSA is still the most common server-certificate key type, so
this is what makes tsmc's HTTPS server broadly usable.

Unlike M37, this needs genuinely new crypto: an RSA **private-key**
operation. The vendored picotls has RSA *verification* only — its
`rbn_powm` takes a `u64` exponent, enough for the public `e` (65537) but
not a ~2048-bit private `d`.

---

## 1. Goal / non-goal

**Goal.** A server may present an RSA certificate (2048/3072/4096-bit)
and sign its TLS 1.3 CertificateVerify with RSASSA-PSS
(`rsa_pss_rsae_sha256`, the default; sha384/sha512 if the client prefers
and the modulus allows). `tls.createServer` / `https.createServer`
auto-detect EC vs RSA from the key. A loopback HTTPS diff test with an
RSA cert, byte-identical to Node.

**Non-goal (this milestone).** RSA-PKCS#1-v1.5 signatures (TLS 1.3
mandates PSS for CertificateVerify; v1.5 is not offered), CRT-accelerated
signing (see §2), encrypted private keys, and everything M37 already put
out of scope (client-cert auth, SNI selection, resumption, ALPN).

---

## 2. The private-key operation: plain modexp, not CRT

RSA signing is `s = EM^d mod n`. Production stacks use the CRT
(`p, q, dP, dQ, qInv`) for a ~4× speedup, but CRT is substantially more
code — two half-width modexps, a modular subtraction, a mod-p multiply,
and a full-width multiply-add — and correspondingly more room for a
subtle bug in security-critical code.

This milestone uses the **plain** `EM^d mod n`. It needs only `n` and
`d` from the key (not the five CRT parameters), which also shrinks the
key parser, and it reuses the existing Montgomery multiply directly. The
cost is a full-width modexp per signature (~2048 squarings + ~1024
multiplies of 32-word Montgomery muls for a 2048-bit key), on the order
of tens of milliseconds — fine for a server that is not fielding
thousands of handshakes per second. CRT is noted as a future
optimization, not a correctness gap.

The one new bignum primitive is a **big-exponent modexp**: `rbn_powm`
generalized so the exponent is a big-endian byte array (the DER `d`)
rather than a `u64`. Structurally identical — Montgomery square-and-
multiply — only the bit source changes.

---

## 3. PSS encode (the inverse of what already exists)

The client already does EMSA-PSS-**verify** (`emsa_pss_verify`) plus
`mgf1` and `rsa_hash`. The server needs EMSA-PSS-**encode**:
`mHash = Hash(input)`; `M' = 0x00×8 ‖ mHash ‖ salt` (salt length = hash
length, per TLS 1.3); `H = Hash(M')`; `DB = 0x00×ps ‖ 0x01 ‖ salt`;
`maskedDB = DB ⊕ MGF1(H)`; clear the top bits of `maskedDB[0]`;
`EM = maskedDB ‖ H ‖ 0xbc`. The salt is fresh random from the module
CSPRNG (`mc_csprng_bytes`). Reuses `mgf1` / `rsa_hash` unchanged.

The signature is then `RSASP1(EM) = EM^d mod n`, big-endian, `klen`
bytes.

All of this lands as a `LOCAL ADDITION (tsmc)` in
`picotls_bridges_rsa.mc` (the `rbn_*` primitives are file-private), noted
in `THIRD_PARTY.md`, re-applied on re-export — the same pattern as the
ECDSA sign bridge.

---

## 4. Key parsing

Extract `n` and `d` (big-endian) from an RSA private key in DER, PKCS#1
(`RSAPrivateKey ::= SEQUENCE { version, n, e, d, p, q, dP, dQ, qInv }`)
or PKCS#8 (`PrivateKeyInfo` wrapping it). Only `n` (field 2) and `d`
(field 4) are needed; the CRT fields are skipped. Reuses the
`tls_x509.mc` DER primitives, beside the M37 EC parser.

`tls_server_ctx_new` becomes key-type-agnostic: try the EC parse; on
failure try RSA; wire the matching `sign_certificate`. A key that is
neither is rejected up front, as today.

---

## 5. Increments

- **I1 — RSA sign primitive + PSS encode.** `rbn_powm` big-exponent
  variant, `emsa_pss_encode`, and `rsa_pss_pl_sign_certificate` in
  `picotls_bridges_rsa.mc`. Unit test: sign a message with a fixed
  RSA-2048 `(n, d)` and verify it with the existing `rsa_pss_verify`
  (`n, e`), for sha256/384/512 — isolates the new crypto with no sockets.
- **I2 — RSA key parsing + server context.** `n`/`d` extraction; an
  RSA sign context in `TlsServerCtx`; `tls_server_ctx_new` auto-detects
  EC vs RSA. A native/JS smoke that builds a context from the RSA
  fixture.
- **I3 — end-to-end + diff test.** `tools/gen_tls_server_cert.sh` also
  emits an RSA fixture; `test/diff/https_server.js` (or a sibling) serves
  over an RSA cert as well, byte-identical to Node, clean under
  `--gc-stress`. No JS surface change beyond the fixture — the native
  auto-detects.
- **I4 — docs.** `PLAN`/`DESIGN_networking`/`npm-compatibility`/
  `THIRD_PARTY` and the networking memory.

---

## 6. Pitfalls to avoid

- **The private key stays inside tls_native.** `n` and `d` are parsed
  natively and never exposed to JS.
- **PSS salt must be fresh per signature** and its length must equal the
  hash length (TLS 1.3). A fixed or wrong-length salt is a
  spec/interop failure.
- **Top-bit masking.** `EM`'s leading byte must have its top
  `8·emlen − embits` bits cleared (`embits = modbits − 1`), or the
  signature is `> n` / malformed and verification fails.
- **`s < n`.** `EM` interpreted as an integer must be less than `n`;
  correct PSS encoding with the top-bit mask guarantees this, but assert
  it rather than assume.
- **Modulus-size bounds.** Keep the existing ≤ 4096-bit (nw ≤ 64) bound;
  reject larger keys at `createServer` rather than overrunning the
  fixed `u64[64]` buffers.
- **Hash choice vs modulus.** sha384/512 need a larger `emlen`; fall
  back to sha256 when the modulus is too small, and only advertise what
  fits.
- **Exercise `--gc-stress`** on the server test, as with M37.

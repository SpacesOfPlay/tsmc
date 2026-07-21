# PLAN M35 — CA-bundle certificate chain validation (secure TLS trust)

Makes `https`/`fetch` **secure by default**: validate the server's
certificate chain to a bundled trusted root, check validity dates, and
match the hostname — instead of the M34 "accept any cert but verify the
handshake signature" stopgap. This is DESIGN §4.1 option (a), the
milestone that turns tsmc's HTTPS from convenient-but-insecure into
actually-trustworthy.

**Security-critical.** A bug here is a silent authentication bypass. The
plan is deliberately conservative: small, individually-tested pieces;
explicit enumeration of what must be checked and the classic pitfalls;
negative tests as first-class. Nothing ships as "the default" until the
whole path is tested against known-good and known-bad certs.

---

## 1. Goal / non-goal

**Goal.** For an outbound TLS client: build and validate the chain
leaf → intermediate(s) → a trust anchor in a bundled root store, per a
pragmatic subset of RFC 5280 path validation, plus RFC 6125 hostname
matching. On success the connection proceeds; on any failure it is
refused with a clear error.

**Non-goal (this milestone).** Revocation (CRL/OCSP/OCSP-stapling), name
constraints, policy constraints/mapping, cross-signing gymnastics beyond a
linear chain, client-cert auth, and a live-updating root store. These are
follow-ups; their absence is documented, not silently skipped.

---

## 2. What must be verified (the checklist the code implements)

For a presented chain `C[0]=leaf … C[k]` and target host `H`:

1. **Parsing.** Every cert parses as a valid `Certificate` (tbsCertificate,
   signatureAlgorithm, signatureValue). Reject malformed DER.
2. **Chain linkage.** `issuer(C[i]) == subject(C[i+1])` by exact DER
   equality of the Name, for every `i`.
3. **Signatures.** `C[i]` is signed by the public key of `C[i+1]`
   (`signature(C[i])` over `tbsCertificate(C[i])` verifies under
   `SPKI(C[i+1])`), using the algorithm named in `signatureAlgorithm`,
   and that algorithm matches `C[i].tbs.signature` (inner/outer agree).
4. **Trust anchor.** There exists a root `R` in the store whose subject
   equals `issuer(C[k])` **and** whose key verifies `signature(C[k])`.
   (Match by DN to *find* the anchor, then verify by *signature* — never
   trust on DN alone.) A chain that ends in a self-signed cert not in the
   store is untrusted.
5. **Validity.** For every cert (and the anchor), `notBefore ≤ now ≤
   notAfter`, using `mc_picotls_get_time`.
6. **CA constraints.** Every non-leaf cert has `basicConstraints` with
   `cA=TRUE`. Honor `pathLenConstraint` if present. The leaf is not used
   as a CA. (keyUsage `digitalSignature`/`keyEncipherment` on the leaf and
   `keyCertSign` on CAs are checked when the extension is present.)
7. **Hostname.** `H` matches a `dNSName` in the leaf's
   subjectAltName (RFC 6125): case-insensitive, a single leftmost `*`
   wildcard matches one label only, no partial-label wildcards, no
   embedded NULs. **No CN fallback** (modern browsers dropped it).
8. **Algorithm hygiene.** Reject MD5/SHA-1 signatures. Bind the hash to the
   signature algorithm (no confusion). Enforce sane key sizes (RSA ≥ 2048,
   P-256).

Failing any check → refuse the handshake (the `verify_certificate`
callback returns nonzero).

---

## 3. What exists vs. what must be built

**Reusable from the vendored picotls (`src/tls/`):**
- Public-key extraction: `mc_spki_extract_p256_pubkey`,
  `mc_spki_extract_rsa_pubkey` (modulus/exponent).
- SPKI location: `mc_x509_locate_spki`, `rsa_x509_locate_spki`.
- ECDSA-P256 verify: uECC (`uECC_verify`) + `mc_ecdsa_sig_der_to_raw`.
- RSA modular exponentiation: inside `rsa_pss_verify` (RSA-PSS path).
- Hashes: `mc_sha256_hash`, SHA-384 (`ptls_minicrypto_sha384`), plus a
  SHA-512 path via `rsa_hash`.
- DER length helper: `der_len`. Clock: `mc_picotls_get_time`.

**Gaps to build (the milestone's real work):**
- **A). X.509 field parser.** A small, defensive ASN.1/DER walker that,
  from a `Certificate` DER, yields: the `tbsCertificate` byte range
  (for signature verification), `signatureAlgorithm` OID, `signatureValue`
  bits, and from the TBS: version, serial, inner sig alg, **issuer** and
  **subject** Name byte ranges, `notBefore`/`notAfter`, SPKI byte range,
  and the extensions — specifically **SAN**, **basicConstraints**,
  **keyUsage**. No allocation; return offsets/lengths into the cert. Bounds-
  checked everywhere (this is attacker-controlled input).
- **B). RSA PKCS#1 v1.5 verify.** Cert signatures are normally
  RSASSA-PKCS1-v1_5 (the vendored RSA is PSS-only). Implement EMSA-PKCS1-
  v1_5 by the safe **encode-then-compare** method: recover `m = s^e mod n`
  (reuse the modexp), build the expected `00 01 FF..FF 00 || DigestInfo ||
  H` and compare byte-for-byte. Reuse the existing modexp + hashes.
- **C). ECDSA cert-sig verify.** `uECC_verify(pubkey, sha(tbs), rawsig)`
  after `mc_ecdsa_sig_der_to_raw` — a thin wrapper (the handshake path
  already does the pieces).
- **D). The root store.** A generated `src/tls/ca_roots.mc`: the Mozilla
  root set (from curl's `cacert.pem`, ~140 roots) as one DER byte blob
  plus an index of `(subject-DN-sha256 → offset,len)` for lookup. A
  build-time tool (`tools/gen_ca_roots.*`, PEM→DER→.mc) produces it;
  checked in, refreshed periodically. ~150 KB in the binary. License:
  the bundle is MPL-2.0 / the certs are the CAs'; attribution in
  `THIRD_PARTY.md`.
- **E). The validator.** `tls_chain_verify(...)` implementing §2, wired as
  a new `verify_certificate` callback that replaces the accept-all default.
- **F). Name/DN + hostname matching.** Exact-DER DN compare; RFC 6125
  dNSName + wildcard matcher.

---

## 4. Architecture / integration

- `src/tls_x509.mc` — the parser (A), signature verify (B, C), DN compare,
  hostname matcher (F). Pure, allocation-light, unit-testable in isolation
  from any socket or the VM.
- `src/tls/ca_roots.mc` — generated root store (D) + lookup.
- `tls_native.mc` — a new `tls_chain_verify_cb` (E) that: collects the
  `certs[]` iovecs picotls passes, runs the validator against the store +
  the SNI hostname, and on success arms the same `verify_sign` the accept
  callbacks already do (so the handshake signature is still checked). It
  needs the target hostname — thread the SNI through (picotls passes
  `server_name` to the callback).
- **Trust posture flips:** `tls_chain_verify_cb` becomes the default.
  Accept-all becomes **opt-in**: `tls.connect({ rejectUnauthorized:false })`
  / a `NODE_TLS_REJECT_UNAUTHORIZED=0` env switch / `tls.setInsecure(true)`.
  `tls.setEcdsaPin` remains for pinning. So: secure by default, explicit
  escape hatch, pinning for the paranoid.

---

## 5. Increments (each builds green; validator stays behind a flag until I6)

1. **I1 — X.509 parser (A) + DN/host matchers (F). (done)** `src/tls_x509.mc`
   is a defensive, allocation-free DER walker returning byte ranges into the
   cert: tbsCertificate (the signed bytes), inner+outer signatureAlgorithm,
   signatureValue, issuer/subject Name TLVs, validity (UTCTime and
   GeneralizedTime → unix seconds), SPKI, and the SAN / basicConstraints /
   keyUsage extensions; unknown extensions are skipped. It bounds-checks every
   length/offset and rejects the indefinite form, non-minimal lengths,
   high-tag-number tags, and trailing garbage. Plus exact-DER DN compare
   (`x509_issuer_matches`) and an RFC 6125 hostname matcher (single leftmost
   `*` = one non-empty label, ≥2 suffix labels, no partial-label wildcards, no
   embedded NUL, case-insensitive, no CN fallback). `test/unit/test_x509.mc`
   (47 checks) drives an embedded controlled chain — root (RSA CA) →
   intermediate (ECDSA CA, pathlen:0) → leaf_ec/leaf_rsa — generated by
   `tools/gen_test_certs.sh`: asserts field extraction, chain linkage,
   hostname accept/reject (wildcard, embedded-NUL, partial-wildcard), and
   malformed-input rejection. Validity seconds match openssl exactly.
   Deterministic, no network.
2. **I2 — signature verify (B, C). (done)** `src/tls_verify.mc` —
   `x509_verify_signature(child, parent)` hashes the child tbsCertificate and
   verifies the signature under the parent's SPKI key. RSA path is
   RSASSA-PKCS1-v1_5 by **encode-then-compare**: recover m = sig^e mod n (via
   the one added vendored primitive `mc_rsa_pub_modexp`), rebuild the full
   `00 01 FF.. 00 || DigestInfo || H` block and compare byte-for-byte. ECDSA
   path decodes the DER Sig-Value to raw r||s and calls uECC over the P-256
   point pulled from the issuer SPKI. Enforces inner==outer signatureAlgorithm
   agreement and rejects SHA-1 / unknown algorithms. Key extraction, DER-sig
   decode and PKCS#1 build live here (unit-tested), not in the vendored crypto.
   `test/unit/test_tls_verify.mc` (16 checks): RSA positives (root self-sig,
   inter under root), ECDSA positives (both leaves under inter), wrong-issuer
   negatives, and tamper tests (flipped TBS byte and flipped signature byte →
   rejected, for both RSA and ECDSA). The DER-cursor primitives in
   `tls_x509.mc` were made public for reuse; `mc_rsa_pub_modexp` is a
   documented LOCAL ADDITION to the vendored RSA bridge.
3. **I3 — root store (D).** The generator tool + `ca_roots.mc` + a lookup
   test (find a known root by subject DN).
4. **I4 — path validation (E).** `tls_chain_verify` tying I1–I3 together;
   unit-tested against a full embedded real chain (positive) and negative
   chains (wrong host, expired via a pinned `now`, missing intermediate,
   tampered sig, self-signed-not-in-store, non-CA intermediate).
5. **I5 — wire into TLS.** `tls_chain_verify_cb` + SNI threading; make it
   default; add `rejectUnauthorized`/insecure opt-out. Manual real-server
   validation (example.com/google/github succeed; a known-bad host like
   `expired.badssl.com`/`wrong.host.badssl.com`/`self-signed.badssl.com`
   is refused).
6. **I6 — gated tests + docs.** Fold the deterministic positive/negative
   cases into the suite; update DESIGN §4.1, PLAN, THIRD_PARTY, and the
   security note (remove "insecure by default").

## 6. Testing strategy

- **Unit, deterministic:** embed real DER certs (a captured chain + roots)
  as byte arrays; test parse, sig-verify, DN/host match, and full-path
  positive/negative. Pin `now` for validity tests so they don't rot.
- **Negative-first:** every check gets a test that *fails* when the input
  is bad (tampered sig, wrong issuer, expired, wrong host, non-CA
  intermediate, untrusted root, SHA-1 sig).
- **Live (manual, non-gated):** badssl.com subdomains for the classic
  failure modes; a few real hosts for success.

## 7. Pitfalls to guard against (called out so review can check them)

- **Trust-on-DN-only:** matching a root by subject DN without verifying
  its key signed the chain = trivial bypass. Always verify the signature.
- **RSA PKCS#1 v1.5 padding:** use encode-then-compare (build the full
  expected block and `memcmp`), not parse-then-trust (Bleichenbacher/
  BERserk / trailing-data). Reject if the recovered block isn't exactly
  the padded DigestInfo.
- **Algorithm confusion:** the outer `signatureAlgorithm` must equal the
  inner `tbs.signature`; the hash used must be the one the alg names;
  reject MD5/SHA-1.
- **Hostname:** SAN dNSName only, one leftmost `*` = one label, no
  `f*o.com`, no embedded NUL, case-insensitive; never fall back to CN.
- **basicConstraints:** every intermediate must be `cA=TRUE`; the leaf
  must not sign the next cert.
- **Validity & clock:** reject expired/not-yet-valid; the clock must be
  real wall-clock (get_time), not the monotonic reactor clock.
- **DER robustness:** every length/offset bounds-checked; no integer
  overflow on lengths; reject indefinite-length and non-minimal encodings
  where it matters.
- **Chain shape:** cap chain length; a leaf that is itself a trusted root
  is fine, but a self-signed leaf not in the store is not.

## 8. Effort / risk

Large and delicate. The parser (A) and RSA-PKCS1v1.5 (B) are the bulk; the
validator (E) is where security bugs hide. Risk is mitigated by building
each primitive with its own negative tests before assembling the path, and
by keeping the accept-all default until the whole thing is tested. Realistic
scope: several focused increments, not one sitting.

## 9. Out of scope / follow-ups

Revocation (OCSP/CRL), name/policy constraints, an updatable/system trust
store, SHA-512-only chains if a primitive is missing, and TLS 1.2 servers.

# PLAN M39 — CRT-accelerated RSA signing

**Status: planned.**

The optimization M38 deferred. RSA server signing currently uses the
plain private operation `s = EM^d mod n` — a full-width modexp with a
~2048-bit exponent. The Chinese Remainder Theorem does the same work mod
`p` and mod `q` (half-width each), ~4× faster, which matters for a
server since the private-key op is the RSA handshake bottleneck.

The correctness bar is exact: the CRT result must equal the plain modexp
for the same input, bit for bit. That deterministic cross-check is the
centerpiece test.

---

## 1. Goal / non-goal

**Goal.** RSA server signing via CRT (`p, q, dP, dQ, qInv`), producing a
signature identical to the plain path, wired in transparently. The
existing RSA HTTPS diff test then exercises the CRT path, and a unit test
asserts CRT == plain over many inputs for the fixture key.

**Non-goal.** Constant-time / side-channel hardening (the vendored
bignum is not constant-time; this milestone matches its existing
posture and does not regress it), and blinding. A key missing any CRT
parameter simply falls back to the plain `n, d` path — no failure.

---

## 2. The CRT private operation

Given `c = EM` and the standard PKCS#1 CRT parameters:

    cp = c mod p ;  cq = c mod q
    m1 = cp^dP mod p ;  m2 = cq^dQ mod q
    h  = qInv · (m1 − (m2 mod p)) mod p
    s  = m2 + h·q          (0 ≤ s < n by CRT)

Reuses the existing Montgomery `rbn_mont_mul` / `rbn_r2` / `rbn_n0inv`
and the M38 big-exponent modexp `rbn_powm_bytes` (mod p and mod q,
half-width). New bignum helpers, all small and each independently
checkable:

- **`rbn_add`** — schoolbook add with carry.
- **`rbn_mul_full`** — schoolbook `nw × nw → 2·nw` multiply (for `h·q`).
- **`rbn_mod_reduce`** — reduce the wide `c` mod the half-width `p`/`q` by
  bit-shift (the same shift-and-conditional-subtract `rbn_dbl` already
  uses), avoiding a general bignum division.

The modular subtraction and `qInv·diff mod p` use `rbn_sub` and two
`rbn_mont_mul`s. Lands as a `LOCAL ADDITION (tsmc)` in
`picotls_bridges_rsa.mc` beside the M38 signer; `THIRD_PARTY.md` updated.

---

## 3. Key parsing and wiring

Extend the RSA key parser (`tls_native.mc`) to also read `p, q, dP, dQ,
qInv` (fields 5–9 of `RSAPrivateKey`; PKCS#8 wraps the same). The RSA
sign context gains those fields and a `has_crt` flag; the
`sign_certificate` callback uses the CRT op when present and the plain
`EM^d mod n` otherwise. n/d stay parsed regardless (the fallback, and the
public modulus).

---

## 4. Increments

- **I1 — CRT primitive + exact cross-check.** The helpers and
  `mc_rsa_crt_privop`. Unit test in `test/unit/test_tls.mc`: for the
  fixture key, over several fixed message representatives `EM`, assert
  `CRT(EM) == EM^d mod n` (the existing `rbn_powm_bytes` with `d`) word
  for word, and that the result verifies via `rsa_pss_verify`. Pure
  crypto, no sockets.
- **I2 — parse CRT params + wire + diff test.** Extend the key parser and
  the RSA sign context; the callback prefers CRT. The RSA HTTPS diff test
  (`https_server_rsa.js`) now runs over the CRT path unchanged and stays
  byte-identical to Node and clean under `--gc-stress`. Docs.

---

## 5. Pitfalls to avoid

- **`m2 mod p` before the subtraction.** `m2 < q`, which can exceed `p`;
  reduce it (one conditional subtract, since `q < 2p`) before
  `m1 − m2`, and add `p` when the subtraction borrows.
- **The wide-mod-halfwidth reduction bound.** After each shift the value
  is `< 2p`, so a single conditional subtract restores `< p`; the shift's
  carry-out bit must be part of the "subtract?" test, not just the
  compare (exactly what `rbn_dbl` does).
- **`h·q` width.** `h < p`, `q < 2^(hw·64)`, so `h·q < n` fits in `nw`
  words; `s = m2 + h·q < n`, no final carry — but size the buffers for
  `2·hw` and assert no overflow rather than assume.
- **Fallback, not failure.** A key without CRT params (or with malformed
  ones) must fall back to the plain path, never sign incorrectly.
- **Keep the plain path.** It stays as the fallback and as the unit
  test's oracle; do not delete it.
- **`--gc-stress`** on the server test, as always.

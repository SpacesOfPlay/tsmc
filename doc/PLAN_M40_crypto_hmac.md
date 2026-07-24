# M40 — crypto: HMAC and the common digest set

Status: complete

## Goal

Grow the `crypto` module from a single digest (`sha256`) to the set most
packages reach for, and add `createHmac`. Concretely:

- `crypto.createHash(algo)` for `md5`, `sha1`, `sha256`, `sha384`, `sha512`.
- `crypto.createHmac(algo, key)` for the same set, with a string or Buffer key.

Both keep the existing incremental shape (`update(...).digest([enc])`, where
`enc` is `hex`/`base64`/… or omitted for a Buffer).

Unblocks the HMAC/digest cluster the compatibility notes keep hitting —
`jsonwebtoken` (HS256/384/512 = HMAC-SHA-2), `object-hash` (sha1), and the
many libraries that call `createHash('md5')`.

## Backends

The vendored TLS crypto (cifra, in `src/tls/picotls_lib.mc`) already compiles
`cf_sha256` / `cf_sha384` / `cf_sha512` into the binary, exposed as one-shot
`cf_*_init` / `cf_*_update` / `cf_*_digest_final`. `builtins.mc` reaches them
by importing `"tls/picotls.mc"` — the same string `tls_native`/`tls_verify`
already use, so it dedups to a single compile rather than a second one.

cifra ships no SHA-1 or MD5 (both legacy), so those two are hand-rolled next
to the existing SHA-256 block function.

## Design

A small algorithm descriptor keyed by an internal id (`CRY_MD5`, `CRY_SHA1`,
`CRY_SHA256`, `CRY_SHA384`, `CRY_SHA512`):

- `crypto_algo_id(name)` → id or −1 (unknown ⇒ the Node "Digest method not
  supported" error).
- `crypto_algo_digest_len(id)` / `crypto_algo_block_len(id)`.
- `crypto_algo_hash(id, data, len, out)` — one-shot dispatch: MD5/SHA-1 to the
  hand-rolled functions, SHA-256 to the existing `sha256_hash`, SHA-384/512 to
  the cifra one-shot.

`createHash` records the id on the object and accumulates input bytes exactly
as today; `digest` dispatches on the stored id instead of assuming SHA-256.

`createHmac` reuses the same accumulator for the message, stores the key
bytes, and finalizes with a generic one-shot HMAC (RFC 2104) built only on
`crypto_algo_hash` + the block length: `K0 = H(key)` if the key exceeds the
block, else the key zero-padded; then `H((K0⊕opad) ‖ H((K0⊕ipad) ‖ msg))`.
`update` and the digest-encoding tail are shared between Hash and Hmac.

## Validation

Differential vs Node (byte-identical), which pins output against Node's
OpenSSL:

- `test/diff/crypto_hash.js` — every algo over empty / ASCII / UTF-8 / binary
  Buffer input; multi-`update` chains; `hex`, `base64`, and Buffer digests.
- `test/diff/crypto_hmac.js` — every algo with a string key and a Buffer key;
  short and block-spanning keys; the three digest encodings; an HS256-shaped
  case.

Both also run under `--gc-stress` via the suite.

## Out of scope

Ciphers, sign/verify, PBKDF2/scrypt, `crypto.getHashes()`, and streaming
(`Hash` as a real `stream.Transform`). Digests and HMAC are the compat
lever; the rest can follow if a package needs them.

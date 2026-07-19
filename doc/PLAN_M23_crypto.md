# M23 — `crypto` (SHA-256 + CSPRNG)

The `crypto` built-in: SHA-256 hashing plus secure random. Enough for
checksums, content hashing, ETags, cache keys, and IDs.

## Shipped

- **`createHash('sha256')`** → a Hash with `update(data, enc?)` (chainable,
  returns the hash; accepts a string in any Buffer encoding or a Buffer)
  and `digest(enc?)` (`hex`/`base64`/… string, or a Buffer when no
  encoding). Multi-`update` accumulates. Verified against the FIPS 180-4
  vectors and byte-identical to Node.
- **`randomBytes(n)`** → a Buffer of `n` cryptographically-secure bytes.
- **`randomUUID()`** → an RFC 4122 v4 UUID string.

SHA-256 is a clean-room FIPS 180-4 implementation (stack-allocated
message schedule / working state, no globals). The CSPRNG uses the
platform source: `RtlGenRandom` (Windows), `getrandom` (Linux),
`arc4random_buf` (macOS).

## Not doing (documented)

- **Only SHA-256** — `createHash('md5'|'sha1'|'sha512'|…)` throws
  (`Digest method not supported`). Node supports the full OpenSSL set;
  this is the deliberate divergence (so the unsupported-algorithm path is
  not in the diff suite — Node wouldn't throw).
- **HMAC, ciphers, sign/verify, key generation, PBKDF2/scrypt,
  DiffieHellman** — the asymmetric/symmetric surface is out of scope.
- **Streaming hash over an event loop** — `update`/`digest` are the sync
  path; the Hash is not a Stream.

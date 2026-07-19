# M28 — `zlib` (sync deflate/gzip)

The `zlib` built-in — compression, common for gzip payloads, npm tarballs,
HTTP content-encoding, and file formats. Reuses the minc stdlib's raw
DEFLATE `deflate`/`inflate` (like sha256 reused the compiler's), wrapping
them with the zlib and gzip framing.

## Shipped

- **`deflateRawSync(data)` / `inflateRawSync(data)`** — raw DEFLATE
  (no header).
- **`deflateSync(data)` / `inflateSync(data)`** — zlib format (2-byte
  header + DEFLATE + Adler-32 trailer).
- **`gzipSync(data)` / `gunzipSync(data)`** — gzip format (10-byte header +
  DEFLATE + CRC-32 + ISIZE trailer; `gunzip` skips the optional
  FEXTRA/FNAME/FCOMMENT/FHCRC fields).
- Input is a string (UTF-8) or a Buffer; output is a Buffer. Adler-32 and
  CRC-32 are computed inline; the decompressors grow their output buffer
  on demand (gunzip sizes from the ISIZE trailer).

Interop-verified against Node: tsmc decompresses a Node-produced gzip blob
byte-for-byte, and round-trips (`gunzipSync(gzipSync(x)) === x`, and the
zlib/raw pairs) match. Compressed *bytes* are not identical across
implementations (different DEFLATE encoders), which is expected and fine —
the formats are interoperable.

## Not doing (documented)

- **Async / streaming** — `gzip`/`createGzip`/`createGunzip` and the
  callback forms (would build on the `stream` module).
- **Brotli** (`brotliCompressSync` / `brotliDecompressSync`) — a separate
  codec, not in the reused stdlib.
- **Options** — `level`, `strategy`, `dictionary`, `windowBits` are
  accepted-and-ignored (the stdlib DEFLATE has fixed parameters).
- **`constants`** and the low-level `deflateSync` flush modes.

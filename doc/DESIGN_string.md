# String model — UTF-16 semantics over UTF-8 storage

JS strings are sequences of UTF-16 code units: `.length`, indexing,
`charCodeAt`, `slice`, and iteration are defined on code units (or code
points, for iteration). tsmc stores string bytes as UTF-8 inline in
`GcString`. This fixes how the UTF-16-observable surface maps onto that
storage.

## Decision

Keep UTF-8 storage; expose UTF-16 semantics at the JS boundary only.

- `GcString.len` stays the **byte** length. All internal machinery — GC,
  hashing, interning/atoms, `memcpy`, comparison, JSON escaping, console
  output, the regex engine, the lexer — keeps operating on bytes and is
  untouched.
- `GcString.u16len` caches the **UTF-16 code-unit** count, computed once
  at creation. It backs the JS `.length` property in O(1) and doubles as
  the ASCII test: `u16len == len` iff every code point is one byte, i.e.
  pure ASCII, in which case unit index == byte offset (the fast path
  every helper takes first).

Storing u16 wide strings instead would tax every string crossing the
engine boundary (lexer literals, atoms, console, JSON) with a
conversion, to fix a deviation that only surfaces in unit-level
introspection of non-ASCII text. UTF-8 storage with a cached unit count
keeps the boundary conversion-free and the ASCII path O(1).

## Code-unit accounting

Per code point, from the UTF-8 lead byte:

| lead byte | bytes | UTF-16 units |
|-----------|-------|--------------|
| `0x00–0x7F` | 1 | 1 |
| `0xC0–0xDF` | 2 | 1 |
| `0xE0–0xEF` | 3 | 1 |
| `0xF0–0xF7` | 4 | 2 (surrogate pair) |

Astral code points (4-byte UTF-8) count as two units and are exposed as
a high/low surrogate pair by `charCodeAt`/indexing.

## Lone surrogates → WTF-8

Operations can land between the two units of an astral pair —
`"😀"[0]`, `"😀".slice(0,1)`, `"😀".split("")`, `fromCharCode(0xD83D)`.
The result is a lone surrogate, which plain UTF-8 cannot encode. Those
are stored as **WTF-8**: the surrogate value `0xD800–0xDFFF` written as
its 3-byte sequence. Decoding treats a 3-byte sequence in that range as
one surrogate code unit, so it round-trips through `.length`, indexing,
and re-slicing. `fromCharCode` combines an adjacent high+low pair into
the astral code point.

## Helpers (`src/ustr.mc`)

`u16_count`, `u16_unit_at`, `u16_offset` (unit index → byte offset),
`u16_slice` (build the substring for a unit range, emitting WTF-8 at a
split surrogate), `cp_at`/`cp_advance` (code-point walk for iteration),
and `wtf8_put`/`wtf8_put_unit` builders. Pure functions over `str`; the
builtin surface calls these and never indexes bytes directly.

## JS-visible surface (UTF-16 indices)

`.length`, `[i]`, `charAt`, `charCodeAt`, `codePointAt`, `at`, `slice`,
`substring`, `substr`, `indexOf`/`lastIndexOf`/`includes`/`startsWith`/
`endsWith` (indices and return values), `padStart`/`padEnd` (target
length), `split("")` (code units), `fromCharCode`/`fromCodePoint`.
String iteration (`for-of`, spread, `Array.from`) yields **code points**.

## Deferred (documented gaps)

- **Comparison order.** `<`/sort use byte order, which equals UTF-16
  order for the BMP but differs for astral vs. `U+E000–U+FFFF`. Extreme
  edge; unchanged.
- **Canonical WTF-8 concatenation.** Joining a string ending in a high
  surrogate with one starting in a low surrogate does not recombine them
  into an astral code point.
- **Regex indices** remain byte-based.

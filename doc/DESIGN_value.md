# Value representation

Decision: **NaN-boxing in a single `u64`** (`struct Value { u64 bits; }`).

## Layout

An IEEE 754 f64 NaN has exponent bits all-one and a nonzero mantissa.
Hardware arithmetic on x64 and ARM64 only ever produces the quiet NaNs
`0x7FF8000000000000` and `0xFFF8000000000000`. Every bit pattern above
`0xFFF9000000000000` is therefore free for tags.

| Bits                       | Meaning                                  |
|----------------------------|------------------------------------------|
| `< 0xFFF9…` (everything else) | f64 number, raw IEEE bits             |
| `0xFFF9…` + low 32 bits    | small integer (i32 payload)              |
| `0xFFFA…` + low bits       | specials: undefined, null, false, true, hole |
| `0xFFFB…` + low 48 bits    | pointer to a GC cell                     |

- **Numbers**: f64 stored as raw bits. A separate i32 tag gives integer
  arithmetic and array indexing a fast path; `value_number_f64` reads
  either form as f64. Semantically both are the one JS number type.
- **Specials**: fixed bit patterns. `hole` marks array holes and TDZ
  slots; it is never visible to JS code.
- **Cells**: heap objects (strings, objects, functions, …) as 48-bit
  pointers. User-space addresses on all supported targets fit 48 bits.

## Invariants

- Arithmetic results need no normalization: hardware NaNs sit below the
  first tag. Only code that injects raw f64 bit patterns (typed arrays,
  DataView — later milestones) must canonicalize NaNs to
  `0x7FF8000000000000` before boxing.
- An i32 payload is written zero-extended via u32; readers sign-extend
  by truncating to i32. The unused upper 16 payload bits stay zero.
- A cell payload is read by masking to the low 48 bits.

## Alternative considered

A 16-byte tagged struct (`{ u32 tag; union payload }`) is simpler to
read but doubles the size of every stack slot, register save, and array
element, and makes Value copies two stores instead of one. The VM's
inner loop touches Values constantly; the compact form wins.

## Tests

`test/unit/test_value.mc`: round-trips for f64 (including -0.0,
infinities, NaN), i32 extremes, all specials, cell pointers; predicate
disjointness across all kinds.

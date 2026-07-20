# M30 — ArrayBuffer, typed arrays, and DataView

Binary data is the last big gap between tsmc and ordinary Node code:
encoders, parsers, crypto shims, and many npm packages assume
`Uint8Array` and friends exist. This milestone adds the full set of
integer/float typed arrays over a shared `ArrayBuffer`, plus `DataView`
for explicit-endian reads and writes.

## Design

- **`ArrayBuffer`** owns the raw storage: a `GcBytes` cell (a new no-scan
  GC kind, `GC_BYTES`, holding an inline length-prefixed byte run). The
  cell is parked in the buffer object's `elems[0]` so the existing object
  tracer keeps it alive with no special case.
- **Typed arrays** are `JsObject`s flagged `OBJF_TYPEDARRAY`. They share
  the backing buffer's `GcBytes` (again via `elems[0]`) and carry hidden
  layout props — `%taoff` (byte offset), `%talen` (element count),
  `%takind` (element kind 0–8), `%tabuf` (the `ArrayBuffer`). Element
  reads/writes go through `vm_ta_get` / `vm_ta_set`, wired into the
  `OP_GETINDEX` / `OP_SETINDEX` opcodes and the property path (so
  `t[0]`, `t["0"]`, spreads, and `Object.values` all reach the bytes).
- Storage is platform-endian (little-endian) via `memcpy` of the native
  width; `DataView` reverses bytes for its big-endian default.
- Per-kind prototypes (`Int8Array.prototype` … `Float64Array.prototype`)
  chain to one shared `%TypedArray%.prototype` that holds every method,
  so `instanceof` works per kind while the method set lives in one place.
- `length`, `byteLength`, `byteOffset`, and `buffer` are prototype
  getters (not own data props), so `hasOwnProperty`, `Object.keys`, and
  `JSON.stringify` see only the integer indices — matching Node.

## Shipped

- **Constructors**: `ArrayBuffer(len)`; the nine views
  (`Int8Array`, `Uint8Array`, `Uint8ClampedArray`, `Int16Array`,
  `Uint16Array`, `Int32Array`, `Uint32Array`, `Float32Array`,
  `Float64Array`) in all forms — `new TA(length)`, `new TA(buffer,
  byteOffset?, length?)`, `new TA(arrayOrTypedArray)`, `new TA(iterable)`,
  `new TA(arrayLike)`; and `DataView(buffer, byteOffset?, byteLength?)`.
- **Value coercion** per kind: two's-complement wraparound for the
  integer kinds, `Uint8ClampedArray` rounding/clamping to 0–255, and
  IEEE-754 round-trips for the float kinds.
- **Prototype methods**: `set`, `subarray` (shares storage), `slice`
  (copies), `fill`, `join`, `indexOf`, `lastIndexOf`, `includes`,
  `forEach`, `map`, `filter`, `reduce`, `reduceRight`, `find`,
  `findIndex`, `some`, `every`, `at`, `reverse`, `keys`, `values`,
  `entries`, `[Symbol.iterator]`, `toString`.
- **Statics**: `TA.from(src, mapFn?)`, `TA.of(...)`,
  `TA.BYTES_PER_ELEMENT`, `ArrayBuffer.isView`, `ArrayBuffer.prototype
  .slice`.
- **`DataView`** get/set for Int8/Uint8/Int16/Uint16/Int32/Uint32/
  Float32/Float64 with the little-/big-endian flag and bounds checks.
- **Reflection parity**: integer indices act as own enumerable
  properties for `Object.keys` / `values` / `entries`, `for…in`, object
  spread, `JSON.stringify` (`{"0":…}`), and `hasOwnProperty`.
- **Console**: `console.log` prints `Uint8Array(3) [ 1, 2, 3 ]` like Node.

Verified byte-identical to Node in `test/diff/typedarray.js` (all
construction forms, per-kind coercion, methods, iteration, DataView
endianness, and the reflection behaviours) and clean under `--gc-stress`.

## Not doing (documented)

- **`Object.prototype.toString` tag** — `Object.prototype.toString.call
  (new Uint8Array())` returns `[object Object]`, not `[object
  Uint8Array]`. tsmc's `Object.prototype.toString` is globally minimal
  (it returns `[object Object]` for arrays too); `Symbol.toStringTag`
  support is a separate, cross-cutting change, not typed-array-specific.
- **BigInt64Array / BigUint64Array** — omitted (the 64-bit-integer views).
- **Resizable / growable ArrayBuffers**, `SharedArrayBuffer`, and
  `Atomics` — not implemented.
- **`ArrayBuffer` / `DataView` in `console.log`** — these inspect as a
  plain `{}` rather than Node's `ArrayBuffer { … }` form; the byte
  contents are not surfaced.
- **`TypedArray.prototype.sort` / `toSorted` / `copyWithin` / `with`** —
  not yet added.

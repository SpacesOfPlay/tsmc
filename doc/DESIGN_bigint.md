# DESIGN — BigInt

JS `BigInt` is an arbitrary-precision integer primitive. It cannot fit
in the NaN-boxed `u64` `Value`, so it is a heap cell, like strings.

## Representation

`GC_BIGINT` (kind 10) — a `GcBigInt` cell: `{ GcCell head; bool neg;
i32 nlimbs; }` with `nlimbs` base-10⁹ limbs stored **inline** after the
struct (same variable-size trick as `GcString`). Sign-magnitude:

- Magnitude is little-endian limbs, each a `u32` in `0 … 999_999_999`
  (base 1e9). Zero is `nlimbs == 0` (or a single 0 limb), always
  `neg == false`.
- Base 1e9 makes decimal `toString`/parse trivial and keeps every limb
  product inside a `u64` (`(1e9-1)² < 1.8e19`).

The cell holds no pointers: its GC tracer and finalizer are no-ops (the
inline data dies with the cell).

`value_is_bigint(v)` = `value_is_cell(v) && cell.kind == GC_BIGINT`.

## Core (`src/bigint.mc`)

A small bignum over base-1e9 limbs: compare, add, sub, mul, divmod
(truncating toward zero), pow, from/to decimal string, from `i64`, to
`f64`. Pure functions on limb buffers; the VM layer wraps results in
cells.

## Semantics wired into the VM

- **Literals** `123n` — lexer token, parser node, constant `BigInt`
  cell.
- **`typeof`** → `"bigint"`; **ToBoolean** → `0n` is falsy.
- **Arithmetic** `+ - * / % **` on two BigInts. Mixing a BigInt with a
  Number throws `TypeError` (per spec). `/` and `%` truncate toward
  zero; `**` requires a non-negative exponent.
- **Comparison** `< > <= >=` allow BigInt↔Number (compared by
  mathematical value). **`===`** is true only for two equal BigInts;
  **`==`** compares a BigInt and a Number by value.
- **Conversion** `String(b)`, `` `${b}` ``, `Number(b)`, `BigInt(x)`
  (from number/string/boolean), `BigInt.prototype.toString([radix])`.

## Deferred (documented)

- **Bitwise** `& | ^ ~ << >>` on BigInt — two's-complement infinite
  semantics; a separate chunk. Using them throws for now.
- `BigInt.asIntN`/`asUintN`, `BigInt64Array`.
- Radix ≠ 10 for `toString` beyond the common cases.

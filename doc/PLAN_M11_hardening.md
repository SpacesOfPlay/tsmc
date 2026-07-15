# M11 — hardening & performance

Functional coverage is complete through M10. This milestone measures,
then optimizes the hot paths that measurement exposes, and hardens the
runtime against pathological inputs. No new language surface.

## Benchmark harness

`bench/*.ts` — workloads that run long enough to time from the shell:
recursive fib, string building, array map/filter/reduce/sort, object
property churn, JSON round trips, a small interpreter-in-the-
interpreter. `./build.ps1 bench` runs each with the built `tsmc` and
reports wall time. Not a CI gate — a tracking tool.

## Optimization targets (confirm by measurement first)

- **Property access.** Own property tables are a linear scan — fine
  and cache-friendly for small objects, O(n) for dictionary-pattern
  objects. Add a hash index above a size threshold; small objects stay
  linear.
- **Global access.** `OP_GETGLOBAL` hashes the name each time. Cache
  the resolved slot per instruction site if it profiles hot.
- **Dispatch / arithmetic.** Verify the interpreter loop is a jump
  table and the integer fast paths stay unboxed.

Only land changes with a measured win; record before/after in the
commit.

## Hardening

- **Deep recursion** must raise `RangeError`, never segfault — the
  frame-count guard has to trip before the native C stack overflows,
  including through native re-entry (`vm_call_value`).
- **Sustained allocation** under the real (non-stress) collector: a
  long-running allocator loop stays bounded and correct.
- **Pathological inputs**: huge literals, deeply nested structures,
  long strings, wide objects — bounded behavior or a clean error, no
  crash.
- Uncaught errors print name + message and exit 1; compile errors
  print with spans and exit 2 (already true — add regression coverage).

## Results

Landed, each with a measured win or a fixed hazard:

- **Property hash index** above 16 entries: a 500-key dictionary
  object doing 1M lookups went 0.53 s → 0.37 s (~30%); small objects
  and `fib` unchanged. Deletion rebuilds the index; enumeration order
  preserved.
- **Integer fast paths** on `-`, `*`, and the ordered comparisons
  (matching `+`), skipping the f64 round trip when both operands are
  small integers. `fib(34)` 1.29 s → 1.21 s.
- **Recursion limits split.** Direct JS recursion grows the frame
  array, not the C stack, so `VM_FRAMES_MAX` rose to 8000 — `sum(2000)`
  now succeeds where 256 used to throw. Native re-entry
  (`vm_call_value` → `vm_execute`) grows the real C stack, so a
  separate `exec_depth` cap (180) trips first there. Both runaway
  cases raise `RangeError`; neither segfaults.

## Tests

`test/unit/test_hardening.mc` — deep recursion → RangeError, sustained
allocation, deep nesting, wide objects. Benchmark scripts double as
smoke tests (must exit 0 with expected output). Large-object property
correctness under the new hash index.

## Differential conformance

`test/diff/*.js` run through both `tsmc` and a reference Node, byte-for-
byte comparing stdout (`./build.ps1 diff`). Every deviation the harness
surfaced was fixed to match Node:

- **ToPrimitive (ES 7.1.1).** `+`, comparisons, and `==` coerce
  references via `valueOf`/`toString` ordered by hint; `Array.prototype
  .toString` joins with `,`; `ToString` on objects routes through the
  method path so custom `toString`/`valueOf` win everywhere.
- **Number formatting.** `toExponential`, `toPrecision`, and a basic
  `toLocaleString` (grouping + ≤3 fraction digits), plus the ES
  `Number::toString` placement rules. minc's formatter has no `%e`/`%g`,
  so the digit rounding is done by hand.
- **Reflection.** `name`/`length` synthesized on functions and natives;
  class constructors carry the class name; anonymous functions assigned
  to a binding take its name (NamedEvaluation); prototypes link back to
  their constructor.
- **Library gaps.** Math hyperbolics/`log1p`/`expm1`/`fround`/`imul`/
  `clz32` and constants; `JSON.stringify` replacer (function + array)
  and `toJSON`; array `values`/`keys`/`entries`/`copyWithin`; `Array
  .from` over any iterable or array-like; string `substr`/`localeCompare`
  /`normalize`/`toLocale*`; `Object.getOwnPropertyNames`/`setPrototypeOf`.
- **Error text.** Property access on `null`/`undefined` reports the
  Node-style `Cannot read properties of X (reading 'k')`.
- **Property descriptors.** Each property carries writable/enumerable/
  configurable attribute bits (`Prop.flags`), objects carry a non-
  extensible bit. `Object.defineProperty`/`defineProperties`/
  `getOwnPropertyDescriptor`, `freeze`/`isFrozen`, `seal`/`isSealed`,
  `preventExtensions`/`isExtensible`; enumeration honors the enumerable
  flag and assignment honors writability/extensibility. Built-in
  methods, static methods, constructors, and class methods install
  non-enumerable (via `def_*` helpers and `OP_DEFMETHOD`), so
  `Object.keys(Array.prototype)`, `Object.keys(Math)`, and
  `Object.keys(SomeClass.prototype)` are empty like Node; class fields
  stay enumerable.

- **UTF-16 string semantics** (see `doc/DESIGN_string.md`). Strings keep
  UTF-8/WTF-8 storage; `GcString` caches `u16len` (code-unit count),
  computed once at creation and summed on concatenation. The whole
  JS-visible surface — `.length`, indexing, `charAt`/`charCodeAt`/
  `codePointAt`/`at`, `slice`/`substring`/`substr`, `indexOf`/
  `lastIndexOf` (unit indices), `split("")`/`padStart`/`padEnd`,
  iteration (code points via for-of/spread/`Array.from`),
  `fromCharCode`/`fromCodePoint` — now matches Node for BMP and astral
  text. Lone surrogates round-trip as WTF-8 and print as U+FFFD.
  `src/ustr.mc` holds the pure helpers; ASCII fast-paths keep the common
  case O(1) and the benchmarks flat.

- **Sparse-array holes.** Array literal elisions, `Array(n)`, and
  index-past-end assignment store a hole sentinel (`value_hole()`, shared
  with the TDZ marker) rather than `undefined`. Holes read as `undefined`
  but are absent from `Object.keys`/`for-in`/`in`/`hasOwnProperty`/
  `getOwnPropertyNames`; the callback methods that skip holes (forEach,
  map (preserving them), filter, some, every, reduce/reduceRight,
  indexOf) skip them, while those that visit them as `undefined` (find,
  findIndex, includes, join, fill, reverse) do; slice/concat preserve
  holes; console prints `<N empty item(s)>`. (Surfaced a minc codegen
  bug: `return`ing a struct-typed ternary picks the wrong branch —
  `doc/BUG_*` in the compiler repo; worked around by binding to a local.)

- **More builtins.** Date UTC accessors + `Date.UTC` (no timezone, so
  UTC aliases the plain accessors); `Symbol.prototype` toString/valueOf/
  description; `Number("0b…"/"0o…")`; **static class inheritance** — a
  derived constructor's `[[Prototype]]` is the parent constructor
  (`JsFunction.fproto`, walked in property lookup and `getPrototypeOf`),
  so inherited static methods/fields resolve; Latin-1 case mapping in
  `toUpperCase`/`toLowerCase` (ß→SS, ÿ↔Ÿ), replacing the ASCII-only map.

- **Statics & globals.** `Object.is`/`hasOwn`, `Object.fromEntries` over
  any iterable; array `lastIndexOf` and the ES2023 copying methods
  `toSorted`/`toReversed`/`with`; `encodeURIComponent`/`encodeURI`/
  `decodeURIComponent`/`decodeURI` (UTF-8 percent-coding, `decodeURI`
  keeps reserved-char escapes).

Known deferred gaps: no BigInt; `globalThis`, `structuredClone`,
private class fields (`#x`), tagged templates, and regex named groups
are unimplemented; `super` in a static method and `__proto__` (accessor)
are unsupported; `Object.keys` on a function omits static fields; class
getters/setters stay enumerable; case mapping beyond Latin-1 (Greek,
Cyrillic) is unmapped; string comparison uses byte order (differs from
UTF-16 only for astral vs. U+E000–U+FFFF); regex indices remain
byte-based.

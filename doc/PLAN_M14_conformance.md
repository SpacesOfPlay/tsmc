# M14 — coercion & builtins conformance

Root causes clustered from a test262 `test/language` sweep (coercion is
exercised across the whole tree, so these lift the global pass rate more
than any one directory's count suggests). Landed one at a time: plan
note, implementation, diff test, green suite, re-measure.

Tier 1 (cheap and broad):

1. **Number static constants** — `MAX_VALUE`/`MIN_VALUE` missing; the
   existing constants use default (writable/enumerable/configurable)
   attributes where the spec requires all three off.
2. **Primitive wrapper objects** — `new Number/String/Boolean` don't
   store or return their primitive (`valueOf` → `NaN`, coercion →
   `[object Object]`).
3. **Symbol coercion throws** — `"" + Symbol()`, `Symbol() + 1`, and
   template interpolation of a symbol must throw `TypeError`.
4. **`\u{…}` / `\uXXXX` escapes in identifiers** — the lexer rejects
   Unicode escapes in identifier/property-name position.

Tier 2 (shares the ToPrimitive path with #2):

5. **`Symbol.toPrimitive`** consulted first in ToPrimitive; **Date**
   default hint resolves to string.
6. **Reflection over callables** — DONE (below).

---

## 1. Number static constants — DONE

`Number.MAX_VALUE` and `Number.MIN_VALUE` were absent (→ `undefined`),
so `Number.MAX_VALUE + Number.MAX_VALUE` was `NaN` instead of `Infinity`
and every test touching those constants failed. The other constants
(`MAX_SAFE_INTEGER`, `EPSILON`, `POSITIVE_INFINITY`, …) existed but were
registered writable/enumerable/configurable.

### Approach

- Add `MAX_VALUE` (`1.7976931348623157e+308`) and `MIN_VALUE`
  (`5e-324`, the smallest positive denormal).
- Register all eight numeric constants with attributes `{ writable:
  false, enumerable: false, configurable: false }` (flags = 0) to match
  the spec, via a small local helper.

Cleared 5 of 27 test262 addition-area failures.

---

## 2. Primitive wrapper objects — DONE

`new Number(1)`, `new Boolean(true)`, `new String("hi")` produced an
object with the right prototype but never boxed the primitive, so
`valueOf()` was `NaN`, coercion gave `[object Object]`, and Boolean had
no prototype `valueOf`/`toString` at all.

### Approach — internal `%prim` slot

- Wrapper ctors detect construct mode (`this` is the fresh object) and
  box the computed primitive under the internal key `%prim` (the `%`
  prefix keeps it out of enumeration and reflection); a plain call still
  returns the primitive. `new String` also sets a frozen `length`.
- `Number`/`Boolean`/`String` `.prototype.valueOf`/`.toString` unwrap
  `%prim` (fast-path the matching primitive, else `TypeError`). The
  `num_this` helper feeds `toFixed`/`toExponential`/`toPrecision`/
  `toLocaleString`. `ToPrimitive` (which drives `+`, template literals,
  `String()`) then works unchanged because it already calls
  `valueOf`/`toString` on the object.

Cleared 10 more addition-area failures (22 → 12).

### Not doing (documented)

- **String exotic indexing** — `new String("hi")[0]`, index enumeration,
  and `Object.keys` over a String wrapper (integer-indexed char access on
  the wrapper object). Separate exotic-object behavior.
- **`JSON.stringify` of wrappers** — `JSON.stringify(new Number(5))`
  should serialize `5`, not `{}`. Lives in the JSON serializer.

---

## 3. Symbol coercion throws — DONE

Implicit `ToString`/`ToNumber` of a Symbol must throw a `TypeError`
(`"" + Symbol()`, `` `${sym}` ``, `Symbol() + 1`, `+sym`, `sym < 1`,
bitwise, `[sym].join()`), while the explicit conversions stay legal
(`String(sym)` and `sym.toString()` → `"Symbol(desc)"`, `console.log`).
Previously ToString gave `"Symbol()"` and ToNumber gave `NaN`.

### Approach

- `vm_symbol_desc` produces the descriptive string; `js_to_string_value`
  now throws on a Symbol, and the explicit callers (`String` ctor,
  `js_console_string`/`inspect`) use `vm_symbol_desc` instead.
- New `vm_to_number` throws on a Symbol and otherwise defers to
  `js_to_number`; it replaces `js_to_number` in the arithmetic, unary,
  relational, and bitwise opcodes (the `value_is_number`-guarded fast
  paths and the equality helpers are untouched, so `sym === sym` and
  `sym == 1` keep identity semantics). `Number`/`String` constructors
  check `has_pending` after coercing.
- Property keys are unaffected: `key_to_atom` maps Symbols to their
  reserved id before any string coercion.

---

## 4. Unicode escapes in identifiers — DONE

`def\u{61}ult`, `ca\u{66}e`, `\u{66}oo` — `\uXXXX` and `\u{…}` escapes in
identifier / property-name position. The lexer rejected the backslash
with "unexpected character", failing every test262 `*-escaped-*` test
broadly.

### Approach

- `scan_ident_escape` validates a `\uXXXX` / `\u{…}` escape and advances;
  `scan_ident` allows escapes in start and part positions, keeping the
  common escape-free case on the borrowed source view and decoding an
  escaped name into an owned buffer (`decode_ident`). The dispatch also
  enters `scan_ident` when a token starts with `\u`. Keyword lookup runs
  on the decoded name (so `def\u{61}ult` is a valid `default` property
  key).

### Not doing / follow-up

- **Non-ASCII identifier letters** (`café`, `π` written literally) — the
  `is_id_start`/`is_id_part` tables are ASCII-only; unchanged.

### Escaped/plain reserved words in shorthand binding — DONE (with #4)

#4 unmasked a pre-existing lenience: the parser accepted a *plain*
reserved word as an object shorthand binding (`({ break }) => {}`,
`var { default } = {}`, `function f({ if }) {}`) where spec requires a
SyntaxError. Both shorthand parsers (`parse_object` and the
`parse_binding` object pattern) now reject a `ReservedWord` key in
shorthand position via `is_reserved_word` (yield/await stay contextual);
`{ break: x }` with an explicit value is still fine. This recovers the
~256 escaped negative-parse tests (118/120 sampled now SyntaxError) and
fixes the equivalent plain-keyword cases. On the full tree the escape
work is net-positive (361 positive escaped tests vs 256 negatives, now
both correct); the `--limit 1500` window had over-sampled the negatives.

---

## 6. Reflection over callables — DONE

`getOwnPropertyDescriptor`, `hasOwnProperty` / `Object.hasOwn`,
`getOwnPropertyNames`, and `Object.keys` only read a `JsObject`'s props,
so every static on a constructor/function (`Number.MAX_VALUE`,
`Array.isArray`, …) was invisible to reflection even though direct reads
worked.

### Approach

- `value_props(v)` returns the own-property table for an object,
  function, or native (null for primitives), mirroring the VM's own
  object/function/native switch. The four reflection builtins use it, so
  a constructor's statics are now reachable; array index/length handling
  stays gated on `value_is_object`.
- A `reflect_key` helper resolves the key for `getOwnPropertyDescriptor`
  and both `hasOwn` variants: Symbols map to their reserved id (so
  `getOwnPropertyDescriptor(o, sym)` and `o.hasOwnProperty(sym)` work and
  no longer throw via the #3 ToString path), everything else is ToString'd.
- `getOwnPropertyNames` now includes non-enumerable own keys (its whole
  point) while skipping symbols and the engine's `%`-internal slots
  (so `%prim` never leaks); `Object.keys`/`vm_own_keys` gained callable
  support too.
- Constructor `prototype` was registered enumerable (`props_set`
  default) at all 17 built-in ctors, and `ensure_prototype` and the class
  compiler set it enumerable as well — so `Object.keys(C)` wrongly listed
  `prototype`. All now install it non-enumerable (built-ins frozen; the
  lazy/class paths writable-but-non-enumerable, matching a function's own
  `.prototype`).

### Not doing (documented)

- **Function `length`/`name` own properties** — user functions and
  classes don't materialize `length`/`name`, so
  `getOwnPropertyNames(f)` omits them (Node lists both). Separate from
  reflection-over-callables; the props simply don't exist yet.

---

## 7. Function length / name own properties — DONE

`f.length` and `f.name` read correctly but were synthesized virtually —
invisible to `getOwnPropertyDescriptor`/`getOwnPropertyNames`/`hasOwn`
(Node lists them). `length` also ignored default and rest parameters
(`function (a, b = 1, c)` reported 3, not 1).

### Approach

- `FnTemplate` gains `arity` — leading parameters before the first
  default value or rest — computed in `compile_callable`; the `.length`
  read path uses it. `chunk_finish` defaults `arity` to the required
  count for the non-user-function templates.
- The reflection builtins synthesize `length`/`name` as own properties of
  any callable via `fn_own_synth` (value from the existing read path,
  descriptor `{ writable: false, enumerable: false, configurable: true }`):
  `getOwnPropertyDescriptor`, `getOwnPropertyNames` (listed first),
  `hasOwn`, and `hasOwnProperty`. Kept as read-synthesis rather than
  materialized props to avoid a per-closure allocation on the hot path.

### Not doing (documented)

- **Native function `length`** — per-native argument counts aren't
  tracked, so a native's `length` reads 0. Would need per-builtin
  annotations.
- **Legacy `arguments`/`caller`** own props on functions — deprecated,
  not modelled.
- **Lazy `prototype` in `getOwnPropertyNames`** — a plain function whose
  `.prototype` hasn't been accessed won't list it (still lazily
  materialized); classes and accessed functions are fine.

---

## 8. Function global constructor — DONE

`Function` was undefined as a global. Beyond the obvious
`Function`/`Function.prototype`/`f.constructor === Function` references,
this blocked the whole `verifyProperty` suite: test262's
`propertyHelper.js` binds `Function.prototype.call` at load time, so
every test including it (most of `built-ins/*`) failed before running.

### Approach

- The function prototype object and its `call`/`apply`/`bind` already
  existed. Added the missing global constructor with `prototype =
  function_proto` (frozen) and the `constructor` back-link. Calling it
  throws — dynamic code compilation is unsupported — but references now
  resolve. The runner already content-skips tests that *call* `Function`.

### Not doing (documented)

- **`Function.prototype` is not itself callable** — `typeof
  Function.prototype` is `"object"`, not `"function"`. Making it a
  callable no-op is a separate change.
- **`new Function(src)`** — dynamic code; out of scope for a
  type-strip-and-run interpreter.

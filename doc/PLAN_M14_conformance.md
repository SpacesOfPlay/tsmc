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
6. **Reflection over callables** — `getOwnPropertyDescriptor`,
   `hasOwnProperty`/`Object.hasOwn`, `getOwnPropertyNames`, and
   `Object.keys` only read a `JsObject`'s props, so every static on a
   constructor/function (`Number.MAX_VALUE`, `Array.isArray`, …) is
   invisible to reflection even though direct reads work. Surfaced while
   landing #1. The VM already switches object/function/native for its
   own prop access; the reflection builtins need the same.

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

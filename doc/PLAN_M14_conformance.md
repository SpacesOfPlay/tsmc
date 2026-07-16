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

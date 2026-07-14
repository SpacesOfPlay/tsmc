# M6 — builtins core

The standard library surface that makes real scripts run. Design
context: `DESIGN_string.md`.

## Runtime groundwork

- **Ordered properties.** Object property tables become insertion-
  ordered arrays of `{atom, value}` pairs (linear lookup — objects
  are small until shapes land in M11). JS enumeration order for
  `Object.keys` and `JSON.stringify` depends on it.
- **Prototype objects.** The VM owns `Object.prototype`,
  `Array.prototype`, `String.prototype`, `Number.prototype`,
  `Boolean.prototype`, `Function.prototype`, and the Error-family
  prototypes. New objects and arrays link them; property access on
  primitives falls through to the matching prototype, so
  `"a".toUpperCase()` and `[1].map(f)` work without boxing objects.
- **Reentrant calls.** `vm_call_value` lets natives invoke JS
  (callbacks for map/filter/sort, `Function.prototype.call/apply/
  bind`). `vm_execute` propagates unhandled exceptions to its caller
  instead of printing, so a throw inside a callback unwinds through
  the native into the outer script's handlers.
- **Errors.** `Error` + `TypeError`/`RangeError`/`ReferenceError`/
  `SyntaxError` constructors and prototype chain; VM-thrown errors
  use them, so `catch (e)` sees `e instanceof TypeError` and
  `e.name`/`e.message`/`toString()`.
- Array `length` assignment truncates/extends.

## Surface

- **Object**: keys, values, entries, assign, create, getPrototypeOf;
  prototype: hasOwnProperty, toString. (No property descriptors —
  defineProperty and friends are out of scope until getters/setters.)
- **Array**: isArray, of, from (array/string, optional map fn);
  prototype: push, pop, shift, unshift, slice, splice, concat, join,
  indexOf, includes, map, filter, forEach, reduce, some, every, find,
  findIndex, reverse, sort (comparator via callback), fill.
- **String**: fromCharCode; prototype: charAt, charCodeAt, indexOf,
  lastIndexOf, includes, startsWith, endsWith, slice, substring,
  toUpperCase, toLowerCase, trim, split (string separators), repeat,
  padStart, padEnd, replace, replaceAll (string patterns).
- **Number**: constructor-as-conversion, isInteger, isFinite, isNaN,
  parseFloat, parseInt, MAX_SAFE_INTEGER, MIN_SAFE_INTEGER,
  POSITIVE_/NEGATIVE_INFINITY, NaN, EPSILON; prototype: toFixed,
  toString.
- **Boolean**, **Math** (floor, ceil, round, trunc, abs, sign, min,
  max, pow, sqrt, cbrt, exp, log, log2, log10, sin, cos, tan, asin,
  acos, atan, atan2, hypot, random, PI, E), **JSON** (parse,
  stringify with numeric indent; cycles throw TypeError),
  **Function.prototype** call/apply/bind, globals parseInt,
  parseFloat, isNaN, isFinite, console.warn/info.

Natives live in `src/builtins.mc`; `builtins_install(vm)` runs after
`vm_init` (one-way import: builtins → vm). `Math.random` is xorshift
seeded per-VM.

## Tests

`test_builtins.mc` probe suites per family; golden run tests:
strings, arrays (callbacks + sort), json (round-trip + indent),
errors (instanceof + catch shapes).

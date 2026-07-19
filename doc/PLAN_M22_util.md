# M22 — `util` module

The `util` built-in — commonly imported, and `promisify` pairs with the
callback-style APIs. Same built-in ES/CJS module delivery.

## Shipped

- **`promisify(fn)`** — returns a function that calls `fn(...args, cb)`
  with a Node-style `cb(err, value)` and resolves/rejects a Promise
  accordingly (preserving `this`). The headline: bridges callback APIs to
  `await`.
- **`callbackify(fn)`** — the inverse: wraps a promise-returning `fn` so
  the last argument is a `cb(err, value)` invoked on settle (via a
  microtask).
- **`format(fmt, ...args)`** — printf-style: `%s` `%d` `%i` `%f` `%j`
  `%o` `%O` `%c` `%%`, with unmatched trailing args appended
  (space-joined, `console.log`-style). Reuses the console formatter.
- **`inspect(value, opts?)`** — the `console.log` string form of a value
  (top-level strings quoted, like Node); `opts` accepted but only broadly
  honored. Backed by the shared console formatter, so it matches Node
  wherever `console.log` does.
- **`inherits(ctor, superCtor)`** — legacy prototypal inheritance
  (`ctor.prototype = Object.create(superCtor.prototype)`, `ctor.super_`).
- **`deprecate(fn, msg)`** — returns a passthrough wrapper (the warning
  itself is not emitted; see below).
- **`isDeepStrictEqual(a, b)`** — deep structural, type-strict equality
  over primitives (SameValue: `NaN` equal, `±0` distinct), arrays, plain
  objects, and Dates.
- **`types`** — `isDate`, `isRegExp`, `isMap`, `isSet`, `isPromise`,
  `isNativeError`, `isAsyncFunction`, `isGeneratorFunction`
  (`isTypedArray` / `isArrayBuffer` / `isProxy` present, always `false`).
- **`TextEncoder` / `TextDecoder`** — re-exported from the globals.

## Not doing (documented)

- **Full `inspect` fidelity** — depth/colors/compact/breakLength/getters/
  circular-marker options are not all honored; output matches Node only
  where `console.log` does (the common cases).
- **`deprecate` warning** — the wrapper forwards but emits no
  `DeprecationWarning` (Node's carries a pid and is non-deterministic).
- **`util.debuglog`, `util.parseArgs`, `util.styleText`, `promisify.custom`,
  `types.isTypedArray`-family truthy results** (no typed arrays yet).

# M15 — real-world coverage

Prioritized by what typical TypeScript programs hit, not by test262
percentage. Gaps found by probing common idioms against Node:

- **Dates** — `toString` was `[object Object]`, string parsing broken,
  no `toLocale*`. #1 below. **DONE.**
- **Error stack traces** — `error.stack` is `undefined`; `{cause}` option
  unsupported. Critical for debugging.
- **Async completeness** — DONE. `Promise.allSettled`, `Promise.any`,
  and `for await…of` (§3).
- **JSON.parse reviver** — DONE (§4).
- **Regex** — lookbehind and the `/u` flag are unsupported.
- **WeakMap / WeakSet** — DONE (§5).
- Lower ROI / bigger surface: `Intl`, Node globals (`process`, `fs`,
  `Buffer`), `TextEncoder`/`TextDecoder`, `Object.groupBy`.

The interpreter is **UTC-only** (no local time zone), so date/time output
is UTC and is golden-tested against `TZ=UTC node`, not the differential
suite.

---

## 1. Dates — DONE

`new Date(0).toString()` gave `[object Object]`, `new Date("2020-01-15")`
parsed to 1970, and the `toLocale*` / `toUTCString` methods were absent.

### Approach

- **Parsing** (`date_parse_iso`): ISO 8601 subset —
  `YYYY[-MM[-DD]][(T| )HH:mm[:ss[.sss]]][Z|±hh[:]mm]`. A date-only string
  or a trailing `Z` is UTC; a time with an explicit offset is shifted to
  UTC; a time without one is treated as UTC (no local zone). Invalid
  input yields `NaN` → `Invalid Date`. Wired into `new Date(string)` and
  `Date.parse`.
- **Formatting**: `toString` / `toDateString` / `toTimeString` produce
  the ES spec form (`Thu Jan 01 1970 00:00:00 GMT+0000 (Coordinated
  Universal Time)`); `toUTCString` (+ `toGMTString`) the RFC 7231 form;
  `toLocaleDateString` / `toLocaleTimeString` / `toLocaleString` a fixed
  en-US numeric form (`1/1/1970`, `12:00:00 AM`). One `date_string(mode)`
  drives them all; `NaN` → `Invalid Date`.
- `toString` now feeds `Date`'s `Symbol.toPrimitive`, so `date + date`
  concatenates the real string form.

Verified byte-identical to `TZ=UTC node` across the toString family, the
locale forms, ISO parsing (offsets, milliseconds), `Date.parse`, and
Invalid Date. Golden test: `test/run/dates.ts`.

### Not doing (documented)

- **Local time zone** — the interpreter has no zone; everything is UTC,
  so `getHours` == `getUTCHours` and `toString` shows `GMT+0000`.
- **Non-ISO parse formats** — `new Date("Jan 15, 2020")` and the
  `toString`/`toUTCString` forms are not re-parsed; ISO 8601 (the JSON
  interchange format) is covered.
- **Real `Intl` / locale data** — `toLocale*` is a fixed en-US format,
  not locale- or options-aware.

---

## 2. Error stack traces — DONE

`error.stack` was `undefined` and the `{ cause }` option was ignored.

### Approach

- **Position table**: `FnTemplate` gains a compact `PosEntry {code_off,
  line, col}` table (built in the `Chunk`, copied on `chunk_finish`) plus
  the source name. The compiler threads the module source + filename and
  records an entry at each statement and before each call/new/throw
  (line:col computed at compile time via `diag_line_col`, so the runtime
  needs no source).
- **Capture**: before invoking a native the VM stores the caller's `ip`
  in its frame, so at `new Error()` every live frame has a current `ip`.
  `vm_capture_stack` walks `vm.frames` top-down, maps each frame's call
  `ip` through its template's position table, and formats
  `    at <name> (<file>:<line>:<col>)`.
- **Wiring**: `error_ctor_impl` and `vm_make_error` (VM-thrown errors)
  set `.stack` = `"<Name>: <message>" + frames`. The `{ cause }` option
  is copied onto the error. Uncaught errors print the full stack.
- Each frame carries a `cur_ip` updated at every call site (not `ret_ip`,
  which holds the *caller's* resume point); the innermost frame's site is
  set when it constructs the error.

### Not doing (documented)

- **`Error.captureStackTrace` / stack getter laziness** — `.stack` is an
  eager string, not V8's lazy structured trace.
- **Exact column parity** — line numbers match; columns are best-effort
  at statement/call granularity.

---

## 3. Async completeness — DONE

`Promise.allSettled`, `Promise.any`, and `for await…of` were missing; the
rest of async (async/await, `Promise.all`/`race`, microtasks, timers) was
already solid.

- **allSettled / any** follow `Promise.all`'s shape via a `promise_combine`
  helper (shared state counted down by per-element natives). `allSettled`
  never rejects and records `{ status, value|reason }`; `any` fulfills on
  the first success and rejects with an `AggregateError` (name + `.errors`)
  only when all inputs reject. Array input only, like `all`/`race`.
- **for await…of** compiles to a loop that awaits both `iter.next()` and
  each yielded value, over the object's sync iterator. Our async
  generators return `{ value, done }` directly and awaiting a non-promise
  passes it through, so async generators, arrays of promises, and plain
  sync iterables all work with one desugaring; `break`/`continue`/
  destructuring included.

### Not doing (documented)

- **`AggregateError` global** — `Promise.any` builds an error with the
  right shape (`name`, `.errors`), but there is no `AggregateError`
  constructor, so `instanceof AggregateError` is false (`instanceof Error`
  is true).
- **`Symbol.asyncIterator`** — not added; `for await` uses the sync
  iterator, which covers our generators and iterables of promises.

---

## 4. JSON.parse reviver — DONE

`JSON.parse(text, reviver)` ignored the reviver. It now implements
InternalizeJSONProperty: after parsing, the result is walked under a
`{ "": result }` holder, reviving children bottom-up and calling
`reviver.call(holder, key, value)` at each node. Returning `undefined`
deletes the property (an array element becomes a hole); the root is
visited last with key `""`. Verified against Node for value transforms,
Date revival, deletion, visit order, and the `this`-is-holder binding.

---

## 5. WeakMap / WeakSet — DONE

Absent; they need genuine weak-reference GC support (not just a Map with
a flag).

### Approach

- `JsMap` gains a `weak` flag; a weak map's `js_trace` marks its prototype
  but **not** its keys/values.
- The collector gained an ephemeron phase (two hooks on `GcHeap`):
  after the normal mark drains, `vm_weak_mark` marks the value of every
  weak entry whose key is already live and loops to a fixpoint (a value
  may be another map's key — verified with a key-chain), tracing each
  wave; then `vm_weak_sweep` drops entries whose key did not survive,
  before the sweep clears marks.
- `WeakMap`/`WeakSet` constructors build a weak `JsMap` and validate that
  keys are references (objects/functions/arrays — primitives throw
  `TypeError`). `get`/`has`/`delete` reuse the Map natives; `set`/`add`
  add the key check. No `size`, iteration, `forEach`, or `clear`, matching
  the spec.

Functional behavior is identical to Node; the ephemeron marking (values
kept alive only by a live key, including chains) is exercised under
`--gc-stress`. Diff test `test/diff/weak.js`.

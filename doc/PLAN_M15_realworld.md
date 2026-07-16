# M15 — real-world coverage

Prioritized by what typical TypeScript programs hit, not by test262
percentage. Gaps found by probing common idioms against Node:

- **Dates** — `toString` was `[object Object]`, string parsing broken,
  no `toLocale*`. #1 below. **DONE.**
- **Error stack traces** — `error.stack` is `undefined`; `{cause}` option
  unsupported. Critical for debugging.
- **Async completeness** — `Promise.allSettled`, `Promise.any`, and
  `for await…of` missing (the rest of async is solid).
- **JSON.parse reviver** — the reviver callback is ignored.
- **Regex** — lookbehind and the `/u` flag are unsupported.
- **WeakMap / WeakSet** — absent (needs weak-ref GC support).
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

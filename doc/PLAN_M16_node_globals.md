# M16 — Node globals

Real-world TypeScript increasingly assumes a Node-like ambient
environment: `process`, `Buffer`, and the Web encoding APIs. None of
these were present (only `globalThis`, `setTimeout`/`setInterval`,
`queueMicrotask` existed). This milestone adds the high-value subset,
platform-portable via `when os(...)` externs.

Environment-dependent output (argv, env, cwd, pid, timings) can't go in
the differential suite — it differs from Node run-to-run and host-to-host.
These are covered by golden tests over the *shape* (types, structure,
round-trips) plus targeted probes, not byte-equality with Node.

## Roadmap

1. **`process`** — argv/argv0, env, platform, arch, pid, version(s),
   `cwd()`, `exit()`, `nextTick()`, `stdout`/`stderr`.write,
   `hrtime()`/`hrtime.bigint()`. **DONE.**
2. **`Buffer`** — `from`/`alloc`/`concat`, `toString(utf8|hex|base64|
   latin1)`, indexing, `length`, `slice`, `write`, `equals`.
3. **`TextEncoder` / `TextDecoder`** — UTF-8 encode/decode over the
   existing WTF-8 machinery.
4. **`__dirname` / `__filename`** — module-local bindings.

## 1. process — DONE

A namespace object installed as the `process` global (and mirrored onto
`globalThis`). Members:

- **`argv`** — `[execPath, scriptPath, ...userArgs]` (strings), matching
  Node's shape. `argv0` is the exec path.
- **`env`** — a snapshot object of the real environment, built by walking
  `GetEnvironmentStringsA` (Windows) / `environ` (POSIX). Enumerable
  string properties, so `Object.keys(process.env)` and
  `process.env.NAME` both work. Snapshot semantics: writes to `env` are
  local (not propagated to child processes, which we don't spawn). On
  Windows the environment is case-insensitive; rather than a case-folding
  proxy, keys are uppercased at snapshot time so the common
  `process.env.PATH` resolves (Node instead preserves the stored case and
  folds on access — enumeration case differs, lookups agree for the
  uppercase convention).
- **`platform`** / **`arch`** — resolved at compile time from
  `when os(...)` / `when arch(...)` (`win32`/`linux`/`darwin`,
  `x64`/`arm64`).
- **`pid`** — real process id.
- **`version`** / **`versions`** — a Node-compatibility version string
  plus a `versions` object that also carries `tsmc`. Documented as a
  stated stand-in, not a claim of Node feature parity.
- **`cwd()`** — real working directory.
- **`exit(code?)`** — flushes nothing (unbuffered) and terminates with
  the given code (default 0).
- **`nextTick(cb, ...args)`** — schedules `cb(...args)` on the microtask
  queue. Ordering note: modeled as a microtask, so it runs in FIFO with
  promise reactions rather than strictly ahead of them as in Node.
- **`stdout`** / **`stderr`** — objects with `write(chunk)` (ToString,
  no trailing newline, returns `true`) and `isTTY: false`.
- **`hrtime([prev])`** — `[seconds, nanoseconds]` from a monotonic clock;
  `hrtime.bigint()` returns nanoseconds as a BigInt.

### Not doing (documented)

- **Signals / IPC / child_process / streams** — no event loop surface for
  `process.on`, no real streams behind `stdout`/`stderr`.
- **`process.stdin`** — no interactive input.
- **Live `env`** — snapshot only; no propagation to spawned processes.

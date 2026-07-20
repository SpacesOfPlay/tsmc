# M29 — core-module forms of globals + `timers/promises`

Modern Node code prefers explicit imports of things that are also globals
(`import process from 'process'`, `import { Buffer } from 'buffer'`) and
uses `import { setTimeout } from 'timers/promises'` for awaitable delays.
These module forms were missing (a bare `import process from 'process'`
failed to resolve). This adds them.

## Shipped

- **`process`** — `require('process')` / `import process from 'process'`
  returns the `process` global; its own properties (`argv`, `env`, `cwd`,
  …) are also named exports, so `import { argv } from 'process'` works.
- **`buffer`** — exports `Buffer` (named + on the default object), matching
  `const { Buffer } = require('buffer')` and `import { Buffer } from
  'buffer'`.
- **`timers`** — the callback timer functions as a module
  (`setTimeout`/`clearTimeout`/`setInterval`/`clearInterval`/
  `queueMicrotask`), re-exporting the globals.
- **`timers/promises`** (JS-source) — `setTimeout(ms, value?)` and
  `setImmediate(value?)` return a Promise that resolves after the delay,
  so `await setTimeout(100)` works (incl. under top-level await).

Core modules take precedence over `node_modules` (matching Node), so these
names resolve to the built-ins even if a same-named package is installed.
Verified byte-identical to Node in `test/diff/coremodules.js` (CJS + the
awaitable forms) and via ESM import; clean under `--gc-stress`.

## Not doing (documented)

- **`timers/promises` `setInterval`** — Node's returns an async iterator;
  omitted.
- **`buffer` extras** — `Blob`, `File`, `atob`/`btoa`, `constants`,
  `kMaxLength`, `SlowBuffer`, `transcode` are not exported (just `Buffer`).
- **`setImmediate` / `clearImmediate` globals** — not added as globals; the
  promise form lives in `timers/promises` (implemented as a 0-ms timer).
- **`process` as a live binding** — the named exports snapshot the
  process object's properties at first import.

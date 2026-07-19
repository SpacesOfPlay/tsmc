# M17 — `fs` / `path` (sync subset) — DONE

The single highest-value step toward running real Node-style CLI scripts:
read a file, transform it, write it back, and manipulate paths. Scoped to
the **synchronous** surface — the async/stream/watch APIs are out.

Delivered as built-in ES modules (`import fs from 'fs'`, `path`, and the
`node:` forms). `path` verified byte-identical to Node in
`test/diff/path.mjs`; `fs` round-trips real files (write/read/append/stat/
rename/unlink/rmdir/mkdir, utf8+buffer+hex) identically to Node in
`test/diff/fs.mjs`. Both clean under `--gc-stress`. The diff/gc-stress
harness was extended to also run `test/diff/*.mjs` (ES-module tests that
Node runs as ESM and tsmc detects by import syntax).

## Delivery: built-in ES modules

Node reaches these via `import fs from 'fs'` / `'node:fs'` (and `path`).
tsmc is ES-module based (relative-path resolution only), so this adds
**built-in modules** the loader recognizes without touching the disk:

- The loader (`module.mc`) intercepts the specifiers `fs`, `node:fs`,
  `path`, `node:path` in its dependency-resolution loop, before file
  resolution, and binds a synthetic module whose namespace is prebuilt.
- The namespace carries `default` (→ the module object, for
  `import fs from 'fs'`) and every function as a named export (for
  `import { readFileSync } from 'fs'`). `import * as fs` binds the whole
  namespace. All three import forms work, matching Node ESM.
- The synthetic module is `MOD_DONE` on creation (no evaluation, no
  `FnTemplate`), deduped by specifier so repeated imports share it.

Only files that `import` these become module-mode; a plain script can't
use them, exactly as in Node (fs/path are not globals).

## `path` — pure string, platform-aware

`join`, `resolve`, `dirname`, `basename(p, ext?)`, `extname`,
`isAbsolute`, `normalize`, `relative`, `parse`, `sep`, `delimiter`.
POSIX/Windows separator per target; verified against `node` in the diff
suite (deterministic).

## `fs` — sync subset

- Backed by the minc `file` lib (`file_read`, `file_write`, `file_exists`,
  `file_stamp`) and `when os(...)` externs for the directory calls.
- **Shipped**: `readFileSync(path, enc?)` (encoding string or `{encoding}`
  → decoded string, else a Buffer), `writeFileSync(path, data, enc?)`
  (string or Buffer), `appendFileSync`, `existsSync`,
  `mkdirSync(path, {recursive}?)`, `rmdirSync`, `unlinkSync`,
  `renameSync`, `statSync` (→ `{ size, mtimeMs, isFile(), isDirectory() }`;
  type via `opendir`/`GetFileAttributes`, avoiding `struct stat` layout).
- Contents can't be diff-tested against a fixed golden (host state), so fs
  round-trips real files in a per-process (pid-keyed) temp dir and prints
  only content/sizes/booleans — verified equal to Node, and gc-stressed.

## Not doing / deferred (documented)

- **`readdirSync`** — deferred: the three `dirent` layouts (Windows
  `WIN32_FIND_DATA`, Linux, macOS) are the messiest platform surface; the
  read/write/stat core lands first. Next addition.
- **`error.code`** — thrown errors carry an `ENOENT: …` message but not
  yet a `.code` property; string-matching works, `e.code === 'ENOENT'`
  does not. Follow-up.
- **Async / promises / streams / watch** — `fs.promises`, callback APIs,
  `createReadStream`, `watch`.
- **File descriptors** — `openSync`/`readSync`/`writeSync(fd,...)`,
  `fstatSync`.
- **Permissions / ownership / links** — `chmodSync`, `symlinkSync`,
  `realpathSync`, mode bits beyond a default.
- **`require('fs')`** — no CommonJS; ES `import` only.
- **`path.relative`** — the other `path` members shipped; `relative`
  deferred (less common than join/resolve/dirname/basename).

## Notes

- **Cross-compile caveat**: `minc --target linux src/main.mc` fails with a
  pre-existing "unhandled IR 103 in x64 codegen" (reproduces with M17
  stashed), so the POSIX `fs`/`path` paths could not be exercised from the
  Windows host; they follow the `file` lib's proven libc patterns and are
  covered by the native Linux `build.sh` CI.
- **Pre-existing bug found**: `typeof <imported-binding>` returns
  `"undefined"` instead of the value's type (affects any ES import, not
  just built-ins) — orthogonal to M17; worth a separate fix.

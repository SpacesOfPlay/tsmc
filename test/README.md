# Tests

Run everything with `minc test`
(Linux/macOS). The suite must be green before any change lands.

## Tiers

- **`unit/*.mc`** — standalone minc programs, one per module under test.
  Each compiles on its own and exits 0 on pass. Shared assertions live
  in `helpers/check.mc` (outside the runner's glob); tests import it
  with a relative path and return `check_done()` from `main`.
- **CLI smoke** — flag handling and exit codes, checked inline by the
  build scripts.
- **`run/<name>.ts` + `run/<name>.expected`** — golden end-to-end tests.
  The runner executes the script with tsmc and diffs stdout against the
  `.expected` file. Exit code must be 0.
- **wasm** — the module is cross-compiled on every run. With node
  present, the golden tests also run through it (`tools/wasm_run.js`),
  except the two that need an environment or a socket.

## Conventions

- Name unit tests after the module they cover: `test_lexer.mc`,
  `test_hashmap.mc`.
- Keep golden tests small and single-purpose; one feature per file.
- Expected output is byte-exact (LF line endings).

# Tests

Run everything with `./build.ps1 test` (Windows) or `./build.sh test`
(Linux/macOS). The suite must be green before any change lands.

## Tiers

- **`unit/*.mc`** — standalone minc programs, one per module under test.
  Each compiles on its own and exits 0 on pass. Print a short diagnostic
  to stderr before returning nonzero so failures are readable.
- **CLI smoke** — flag handling and exit codes, checked inline by the
  build scripts.
- **`run/<name>.ts` + `run/<name>.expected`** — golden end-to-end tests.
  The runner executes the script with tsmc and diffs stdout against the
  `.expected` file. Exit code must be 0. These activate once the VM
  milestone lands.

## Conventions

- Name unit tests after the module they cover: `test_lexer.mc`,
  `test_hashmap.mc`.
- Keep golden tests small and single-purpose; one feature per file.
- Expected output is byte-exact (LF line endings).

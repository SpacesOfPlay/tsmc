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
- **`neg/<name>.js`** — programs the compiler must refuse. The first
  line is `// expect: <fragment>`; the runner requires exit code 2 and
  that fragment in the output. The valid programs that sit next to each
  rule live in `diff/early_valid.js`.
- **wasm** — the module is cross-compiled on every run. With node
  present, the golden tests also run through it (`tools/wasm_run.js`),
  except the two that need an environment or a socket; then the package
  view against a registry faked in `tools/cdn_fs_check.js`; then the
  playground's examples that import no package, through
  `tools/examples_check.js`. Each example block in `web/index.html`
  carries `data-expect`, a line its output must contain, so the text and
  its check sit together. `build/build.exe examples` runs all of them,
  packages included, against the live registry.
- **GC stress** — every golden and differential script runs again under
  `--gc-stress`, which collects on every allocation and poisons what it
  sweeps, and its output must match a plain run. A value used after its
  last root is gone fails here, whatever the memory happened to hold.

## Conventions

- Name unit tests after the module they cover: `test_lexer.mc`,
  `test_hashmap.mc`.
- Keep golden tests small and single-purpose; one feature per file.
- Expected output is byte-exact (LF line endings).

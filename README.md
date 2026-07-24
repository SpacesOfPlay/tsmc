# ts-minc

A TypeScript interpreter written in [minc](https://minc.dev).

`tsmc script.ts` runs TypeScript the way Bun and Deno do: type
annotations are parsed and erased, nothing is type-checked, and the TS
constructs with runtime semantics (`enum`, `namespace`, constructor
parameter properties) are lowered and executed. It is a bytecode VM with
a precise mark-sweep GC, written in minc. `.js` files run as well, and
`node_modules` resolve through the CommonJS and ESM algorithms.

## What runs

Supported ECMAScript includes classes, generators, async/await,
top-level await, modules (CommonJS and ESM, including dynamic
`import()`), Proxy/Reflect, BigInt, typed arrays,
`Map`/`Set`/`WeakMap`/`WeakSet`, and regular expressions including
Unicode property escapes.

A subset of the Node.js standard library is implemented: `fs` (with
`fs/promises`), `path`, `os`, `events`, `stream`, `util`, `buffer`,
`zlib`, `assert`, `process`, `timers`, and `tty`; `crypto` provides
MD5/SHA-1/SHA-256/SHA-384/SHA-512 hashes, HMAC, and the `random*`
functions. Networking covers `net`, `http`,
and `https` clients and servers, the `fetch` and `URL` globals, and a
TLS 1.3 stack: the client validates the server certificate against a
bundled root store, and the server presents an ECDSA-P256 or RSA
certificate.

Not supported: `eval` / `new Function` (no runtime code generation),
native addons, `Intl`, and several core modules (`child_process`,
`worker_threads`, `dns`, and others). `doc/npm-compatibility.md` lists
npm packages that have been run against the interpreter.

See `doc/META_PLAN.md` for the design decisions and architecture.

## Build

Requires the minc compiler. The project uses a local copy of a minc
deploy at `minc/` (gitignored) — the folder holding the compiler
binary, its `lib/`, and `LANGUAGE.md`. To update the compiler, copy a
new deploy over it. The `MINC` environment variable overrides the
install dir.

The build scripts prepend the install dir to their own PATH and invoke
`minc` from the project folder; the compiler finds its standard
library in `lib/` next to the binary.

```
./build.ps1 build      # Windows      -> build/tsmc.exe
./build.sh build       # Linux/macOS  -> build/tsmc
./build.ps1 test       # build + run the full test suite (incl. GC stress)
./build.ps1 diff       # differential test vs a reference node
./build.ps1 bench      # time bench/*.ts
./build.ps1 t262       # ECMAScript conformance (test262) — see below
./build.ps1 clean      # remove build/
```

## Conformance (test262)

tsmc strips types and runs the resulting ECMAScript, so conformance is
measured against the official ECMAScript suite,
[tc39/test262](https://github.com/tc39/test262) — not the TypeScript
type-checker tests, which don't apply to a type-stripping runtime.

The suite is **not vendored**. On first use it is fetched at a pinned
commit into `vendor/test262/` (gitignored), so any clone reproduces the
same tests:

```
./build.ps1 t262                                 # default: test/language
./build.sh  t262 test/built-ins/Array
./build.sh  t262 test/language --limit 500       # sample the first N
```

On Windows the runner is a portable bash script (`tools/test262.sh`)
run through Git Bash. It assembles each test with its harness includes,
runs the strict and sloppy variants, and honours the `negative`
frontmatter. Tests that need a feature the interpreter doesn't implement
(TypedArrays, Proxy/Reflect, Intl, `eval`, …) are **skipped**, not
failed — the honest metric is the pass rate over the tests that ran.
Failing test paths are written to `build/test262-fails.txt`. Pin a
different revision with the `T262_COMMIT` environment variable.

On the default `test/language` run, 9,579 of the 16,235 tests that ran
pass (about 59%); 7,478 more are skipped as unsupported. This is a
current snapshot and will change as the interpreter does.

## Layout

```
src/     interpreter source (modern minc)
doc/     design documents and milestone plans
test/    unit tests (minc), golden run tests, and differential (.js) tests
tools/   test262 conformance runner
minc/    local minc deploy: compiler + lib/ + docs (gitignored)
build/   build artifacts (gitignored)
vendor/  fetched test262 checkout (gitignored)
```

## License

MIT, once published. Not yet released.

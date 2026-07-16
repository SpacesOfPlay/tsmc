# ts-minc

A TypeScript interpreter written in [minc](https://github.com/mattiasljungstrom/minc).

Status: **early development (M0 scaffolding)**. Nothing runs yet.

## What it will be

`tsmc script.ts` — a CLI that runs TypeScript the way Bun and Deno do:
type annotations are parsed and erased, nothing is type-checked, and the
TS constructs with runtime semantics (`enum`, `namespace`, constructor
parameter properties) are lowered and executed. Bytecode VM, precise
mark-sweep GC, written fully in modern minc.

See `doc/META_PLAN.md` for the locked design decisions, architecture,
and milestone roadmap.

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
./build.ps1 test       # build + run the full test suite
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

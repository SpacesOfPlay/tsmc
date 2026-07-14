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
./build.ps1 clean      # remove build/
```

## Layout

```
src/    interpreter source (modern minc)
doc/    design documents and milestone plans
test/   unit tests (minc) and golden run tests (.ts + .expected)
minc/   local minc deploy: compiler + lib/ + docs (gitignored)
build/  build artifacts (gitignored)
```

## License

MIT, once published. Not yet released.

# ts-minc

TypeScript interpreter written in modern minc. CLI binary: `tsmc`.

## Read first

- **`AGENTS.md`** — minc language quick-reference + this project's
  conventions. Read before writing any code here.
- **`doc/META_PLAN.md`** — locked design decisions, architecture,
  milestone roadmap.

## Build

```
./build.ps1 build      # Windows      -> build/tsmc.exe
./build.sh build       # Linux/macOS  -> build/tsmc
./build.ps1 test       # build + full test suite
```

The compiler is a local minc deploy at `minc/` (gitignored; refresh by
copying in a new deploy). `MINC` env var overrides the install dir.
The scripts prepend it to PATH and run `minc` from the project folder.
No symlinks anywhere. The language reference is `minc/LANGUAGE.md`.

## Rules of the road

- Modern minc: tagged unions, generics, `defer`, `Vec<T>`, arenas.
- Comments: brief, neutral, project-specific. No references to other
  projects or to minc compiler internals — this repo will be public.
- Keep the test suite green; run `./build.ps1 test` before finishing.
- New milestone work starts with its `doc/PLAN_M<n>_<topic>.md`;
  cross-cutting choices get a `doc/DESIGN_<topic>.md` first.

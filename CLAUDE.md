# ts-minc

TypeScript interpreter written in modern minc. CLI binary: `tsmc`.

## Read first

- **`AGENTS.md`** — minc language quick-reference + this project's
  conventions. Read before writing any code here.
- **`doc/META_PLAN.md`** — locked design decisions, architecture,
  milestone roadmap.

## Build

```
minc build      # -> build/tsmc[.exe]
minc test       # build + full test suite
```

The compiler is found in this order: `MINC` (the install dir), a local
deploy at `minc/` (gitignored; refresh by copying in a new deploy), then
the `minc` on PATH. The deploy is a dev convenience — the repo builds
from an ordinary install. The scripts prepend the install dir to PATH
and run `minc` from the project folder. No symlinks anywhere. The
language reference is `minc/LANGUAGE.md` when the deploy is present,
otherwise the copy in the install dir.

## Rules of the road

- Modern minc: tagged unions, generics, `defer`, `Vec<T>`, arenas.
- Comments: brief, neutral, project-specific. No references to other
  projects or to minc compiler internals — this repo will be public.
- Keep the test suite green; run `minc test` before finishing.
- New milestone work starts with its `doc/PLAN_M<n>_<topic>.md`;
  cross-cutting choices get a `doc/DESIGN_<topic>.md` first.

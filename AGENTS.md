# ts-minc — guidance for AI coding agents

This file is read automatically by Claude, Cursor, Codex, Aider, and
other agent tools when it sits in a project's root directory. It
documents the minc language patterns and this project's conventions.

## What this project is

ts-minc is a **TypeScript interpreter written in modern minc**. The
`tsmc` CLI runs `.ts` files Bun-style: type annotations are parsed and
erased, nothing is type-checked, and TS constructs with runtime
semantics (`enum`, `namespace`, parameter properties) are lowered and
executed. Bytecode VM, precise mark-sweep GC.

- Pipeline: lexer → parser (full TS grammar) → AST → lowering →
  bytecode compiler → VM with GC heap → builtins → event loop.
- `doc/META_PLAN.md` holds the locked decisions, architecture, and
  milestones. Each milestone gets a `doc/PLAN_M<n>_<topic>.md`;
  cross-cutting decisions get a `doc/DESIGN_<topic>.md`. Read the
  relevant ones before changing pipeline shape or scope.

## What is minc

minc is a small C replacement that compiles `.mc` source files directly
to native binaries on every supported target — no assembler, no linker,
no runtime. The standard library is intentionally minimal: the compiler
ships built-in I/O and basic utilities, plus a small `lib/` of opt-in
modules. Programs `import` library modules; they don't `#include <…>`.

`minc/LANGUAGE.md` (in the project's local minc deploy) is the full
language reference. Read it once before writing minc code. The rest of
this file assumes you have.

## Differences from C

minc looks like C and most C reasoning carries over, but a handful of
differences matter at every keystroke.

**Things minc has that C does not:**

- **Function overloading by parameter type.** Resolution is by
  exact-type match; no implicit conversions used to disambiguate.
- **Tagged unions with pattern matching.** `union Token { Number(i32),
  Plus, Eof }`; construct with `Number(123)`; consume with `switch`,
  which enforces exhaustive coverage. Generic unions (`Option<T>`,
  `Result<T, E>`) work.
- **`defer stmt;` for LIFO cleanup at block exit.** Runs on every
  return path, including early ones.
- **`when os(linux) { ... }` / `when arch(arm64) { ... }`** for
  compile-time conditional code. Replaces `#ifdef`.
- **`import name;`** brings in a `lib/<name>.mc` module; quoted
  `import "file.mc";` resolves relative to the importing file. No
  header files.
- **`var x = expr;`** infers the type from the right-hand side.
- **`p.field` auto-dereferences pointers** — write `p.x`, not `p->x`.
- **`new(T)`** allocates a zero-initialised `T` on the heap;
  `alloc<T>(n)` allocates a typed uninitialised array.
- **Struct literals** — positional `Point{3, 4}` and named-field
  `Span{ .start = a, .end = b }`.
- **Variable destructuring** — `var (a, b) = pair_returning_fn();`.
- **Slices** — `T[]` is a length-carrying fat pointer; `T[N]` is a
  fixed array. No array-decays-to-pointer rule.
- **Generics.** `Vec<T>`, `struct Pair<A, B>`, constrained
  `T add<T: Numeric>(...)`. Monomorphised at compile time.
- **Owned strings.** `str` is a borrowed view (`{ u8* data; i32 len }`);
  `string` is owned — the compiler enforces free-or-move before scope
  exit. `defer free(s);` is the idiomatic cleanup.
- **`private { }` blocks** for file-scope visibility. Replaces C's
  file-scope `static`.

**Things minc does not have that C does:**

- **No undefined behavior.** Signed overflow wraps; divide by zero,
  null deref, and out-of-bounds indexing trap. Don't write defensive
  guards just to "avoid UB" — write the obvious code and trust it.
- **No preprocessor.** No `#define`, no macros. `const` for constants,
  `enum` for integer sets, `when` for conditional compilation.
- **No fall-through in `switch`.** Multi-value cases use commas:
  `case 1, 2, 3:`. Opt in per case with `fallthrough;`.
- **No implicit narrowing, no mixed-sign arithmetic.** Write
  `cast(i32, x)` explicitly. Implicit widening (i32→i64, u8→i32,
  i32→f64) is allowed and expected. Integer literals are exempt.
- **No null-terminated strings.** Strings are byte slices with an
  explicit length.

**Subtle behavior shifts:**

- Bounds checks are on by default, in release builds too.
- `null` is a keyword. `bool` is a real type; `if x` requires a bool.
- Switch cases need braces: `case X: { ... }`.
- Globals and locals are zero-initialised by default; `noinit` opts out.

## Style

- Unary minus: `-x`, never `0 - x`.
- `for i32 i = 0; i < n; i++` — postfix `++`/`--`, not `i = i + 1`.
- `var x = expr;` when the type is obvious from the right-hand side.
- Array initializers: `f32[4] v = { 1.0f, 2.0f, 3.0f, 4.0f };`.
- Hex/decimal literals coerce to any integer type — no cast needed.
- `alloc<T>(n)` returns `T*` directly; never `cast(T*, alloc(n))`.
- `noinit T[N] arr;` when seeding the array immediately afterward.
- `defer` for cleanup at block exit.
- No unnecessary `cast(...)` where implicit widening already applies.
- Fixed-size stack arrays over heap allocations for short-lived data.

## Comments

Hemingway rules. Short declarative sentences. Brief, neutral,
project-specific.

- Explain what the code cannot say: invariants, non-obvious choices,
  spec references (`// ES2023 7.1.4 ToNumber`).
- Skip the comment entirely if removing it wouldn't confuse a reader.
- Never reference anything outside this repository — other projects,
  compiler internals, sessions, fixes, PR numbers.
- No apologies, no hedging. Either fix it or leave it silent.

## ts-minc conventions

- **Kinds and variants.** Wide, growing variant sets — token kinds,
  AST nodes — use `enum` kinds over shared structs; consumers switch
  on the kinds they handle. Tagged unions serve small, closed variant
  sets where exhaustiveness pays (Option/Result-style returns).
- **Two allocation worlds.** Compile-phase data (tokens, AST) lives in
  arenas (`lib/mem.mc`), one per phase, freed wholesale. Runtime JS
  values live in the GC heap (`src/gc.mc`) and are never freed
  manually. Don't mix the two.
- **`Vec<T>`** (`lib/vec.mc`) for dynamic arrays. Don't roll your own.
- **Diagnostics go through `src/diag.mc`** with source spans. Never
  print a raw error string from elsewhere.
- **No global engine state.** Everything hangs off the runtime struct
  passed explicitly. This keeps the future embedding API possible.
  CLI-only state stays in `main.mc`.
- **Top-level constants carry `const`.** A bare `i32 X = 1;` at file
  scope is a mutable global — wrong for what's morally a constant.
- **Each file imports what it uses**, even when another import would
  pull it in transitively.
- **tsmc exit codes:** 0 success, 1 script error, 2 usage or I/O
  error, 3 not implemented yet.
- **Tests:** `test/unit/*.mc` standalone programs exiting 0 on pass;
  `test/run/*.ts` + `.expected` golden stdout tests. See
  `test/README.md`. Keep the suite green: `./build.ps1 test`.

## Where to look

- `doc/META_PLAN.md` — decisions, architecture, milestone roadmap.
- `doc/DESIGN_*.md` — cross-cutting technical designs.
- `doc/PLAN_M*.md` — per-milestone implementation plans.
- `minc/LANGUAGE.md` — full language reference (local minc deploy).
- `test/README.md` — test tiers and conventions.

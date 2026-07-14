# ts-minc — meta-plan

A TypeScript interpreter written in modern [minc](https://github.com/mattiasljungstrom/minc).

This is the umbrella plan. Each milestone gets its own detailed plan
document (`doc/PLAN_M<n>_<topic>.md`) before implementation starts.
Design decisions that shape multiple modules get their own design
documents (`doc/DESIGN_<topic>.md`).

## 1. Goal

Run real-world TypeScript from the command line:

```
tsmc script.ts
```

The interpreter executes TypeScript the way Bun and Deno do: type
annotations are parsed and erased, nothing is type-checked, and the
TS constructs that carry runtime semantics — `enum`, `namespace`,
constructor parameter properties — are lowered and executed correctly.
Type checking is out of scope. `tsc --noEmit` remains the checker.

Written fully in modern minc: tagged unions, generics, `defer`,
slices, `Vec<T>`, arenas. The source is meant to be open sourced —
human-readable, self-contained, brief neutral comments.

## 2. Locked decisions

| Decision | Choice |
|----------|--------|
| Type system | Bun-style: erase annotations, no checking; full runtime support for `enum`, `namespace`, parameter properties |
| Execution | Bytecode VM (AST compiles to bytecode, dispatch-loop interpreter) |
| Memory | Precise mark-sweep GC designed in from day one |
| Product | CLI runner first; architecture keeps an embeddable library API possible (no global engine state — everything hangs off a runtime struct) |

## 3. Scope

### In scope (roadmap order, see milestones)

- Modern ES core: closures, prototypes, `this`, classes, getters/setters,
  destructuring, spread/rest, template literals, optional chaining,
  nullish coalescing, iterators, `for-of`, symbols (well-known symbols
  included — iteration protocol needs them).
- Exceptions: `throw`, `try`/`catch`/`finally` via VM-level unwinding.
- Generators, `async`/`await`, Promises, microtask + macrotask event
  loop, `setTimeout`.
- Builtins: `Object`, `Array`, `Function`, `String`, `Number`, `Boolean`,
  `Math`, `JSON`, `Map`, `Set`, `Error` hierarchy, `console`, `Date`,
  `RegExp` (own engine, later milestone).
- ES modules: `import`/`export` with relative-path resolution.
- TS runtime constructs: `enum` (numeric + string, const enum inlining
  optional), `namespace`, parameter properties, `export =` rejected
  with a clear error.

### Out of scope (initially; some may never land)

- Type checking, JSX/TSX, decorators.
- `eval` / `new Function` (revisit later — the compiler is in-process,
  so it is feasible).
- `Proxy`/`Reflect` beyond basics, `Intl`, BigInt, WeakRef,
  FinalizationRegistry, SharedArrayBuffer, workers/threads.
- Node API compatibility (`fs`, `process`, npm resolution,
  `node_modules`). A small explicit host API can come with the
  embedding milestone.
- JIT compilation, source maps.

## 4. Architecture

Pipeline:

```
source (.ts, UTF-8)
  → lexer          tokens; template-literal modes; regex-literal
                   disambiguation; newline flags for ASI
  → parser         recursive descent + Pratt expressions; parses the
                   full TS grammar including type annotations (types
                   must be parsed to be stripped — generics vs `<`,
                   arrow return types, `as`, `satisfies`)
  → AST            arena-allocated, tagged unions
  → lowering       strip type-only nodes; lower enum / namespace /
                   parameter properties; hoisting + scope analysis
                   (var/let/const, TDZ, closure captures)
  → compiler       AST → bytecode; constant pools; function templates
  → VM             dispatch loop; call stack; unwinding tables for
                   try/finally; GC heap
  → builtins       native functions registered on the global object
  → event loop     microtasks (jobs), macrotasks (timers); CLI drains
                   the loop after the main script returns
```

Planned module layout (`src/`):

| Module | Responsibility |
|--------|----------------|
| `lexer.mc` | Tokenizer |
| `ast.mc` | AST node types, arena allocation |
| `parser.mc` | TS grammar → AST |
| `lower.mc` | Type stripping, TS-construct lowering, scope analysis |
| `bytecode.mc` | Opcode set, function templates, constant pools |
| `compiler.mc` | AST → bytecode |
| `value.mc` | JS value representation |
| `gc.mc` | Heap, cell layout, mark-sweep collector |
| `jsstring.mc` | JS string type, interning/atoms, UTF-8 ↔ UTF-16 |
| `object.mc` | Property storage, prototype chains, array elements |
| `vm.mc` | Dispatch loop, frames, exception unwinding |
| `builtin_*.mc` | One file per builtin family |
| `regex.mc` | Regex engine (own milestone) |
| `loop.mc` | Event loop, job queues, timers |
| `diag.mc` | Diagnostics with source spans |
| `main.mc` | CLI entry |

Infrastructure the minc standard library does not provide — build here:

- **Hash map.** Needed everywhere: property tables, atom table, Map/Set.
  One generic open-addressing map, plus a specialized atom-keyed
  property map if profiling asks for it.
- **Correctly-rounded decimal → f64 parsing** (Eisel-Lemire fast path,
  big-integer fallback). Number → string can use the Ryu formatter the
  minc library already ships.
- **UTF-8 ↔ UTF-16 conversion** at the source/string boundary.

## 5. Design documents to write before their milestones

Each of these locks a cross-cutting decision. Default positions listed;
the design doc confirms or overturns with rationale.

1. **Value representation** (`DESIGN_value.md`) — default: NaN-boxing
   in a `u64` (f64 numbers immediate; pointers, i32, bool, null,
   undefined in NaN payloads). Alternative: 16-byte tagged struct.
   Decide before M1.
2. **GC** (`DESIGN_gc.md`) — non-moving mark-sweep; cell header with
   type + mark bits; size-class allocator; precise roots from VM stack
   and globals; handle scheme for native frames (needed for the
   embedding API later). Decide before M1.
3. **String model** (`DESIGN_string.md`) — spec semantics are UTF-16
   code units (`.length`, indexing). Default: u16 storage first, add a
   latin1 narrow representation as an optimization later. Atoms
   (interned strings) for property keys.
4. **Bytecode shape** (`DESIGN_bytecode.md`) — default: stack-based
   (simpler compiler, QuickJS-proven). Register-based is the
   alternative if the VM loop profile demands it.
5. **Object model** (`DESIGN_object.md`) — default: per-object hash
   property table + separate dense element storage for arrays. Hidden
   classes / shapes deferred to a performance milestone.
6. **Generators & async** (`DESIGN_async.md`) — default: heap-allocated
   VM frames that suspend/resume (no OS/fiber stacks — keeps the
   embedding story simple and the VM portable).

## 6. Milestones

Each milestone lands with its own tests and a green test suite.

- **M0 — scaffolding.** Repo layout, build scripts (Windows + POSIX),
  test runner (golden tests: run `.ts`, compare stdout), CI-able
  `build test` entry point. README, AGENTS.md, LICENSE.
- **M1 — infrastructure.** Hash map, atoms, value representation,
  GC heap with mark-sweep (tested standalone), diagnostics module.
- **M2 — lexer.** Full token set: templates, regex literals, all
  numeric literal forms, Unicode escapes, ASI-relevant newline flags.
- **M3 — parser.** Expressions, statements, functions, classes,
  modules syntax, full type-annotation grammar (parsed, retained in
  AST as opaque spans or dropped nodes).
- **M4 — lowering.** Type stripping; enum/namespace/parameter-property
  lowering; scope analysis (hoisting, TDZ, capture lists).
- **M5 — VM core.** Bytecode + compiler + dispatch loop. Functions,
  closures, control flow, arithmetic with JS coercion rules, objects,
  arrays, prototypes, `this`, `new`, try/catch/finally, `typeof`,
  strict equality and `==` coercions. First `tsmc hello.ts`.
- **M6 — builtins core.** Object/Array/String/Number/Math/JSON/console/
  Error. Property descriptors as needed by these.
- **M7 — modern syntax surface.** Destructuring, spread/rest, template
  literals, optional chaining, nullish coalescing, getters/setters,
  computed properties, symbols, iterators, `for-of`, classes with
  inheritance.
- **M8 — async.** Generators, Promise, async/await, microtask queue,
  event loop, `setTimeout`.
- **M9 — collections & regex.** Map/Set, Date, regex engine +
  String/RegExp integration.
- **M10 — modules.** ESM import/export, module registry, relative
  resolution, cyclic imports per spec.
- **M11 — hardening & performance.** GC stress mode (collect every N
  allocations), benchmarks, string/object representation optimizations,
  inline caches if profiling justifies.
- **M12 — embedding API & conformance.** Public library surface
  (create runtime, eval script, bind native functions, handle scheme),
  CLI reduced to a thin client. test262 harness with a curated
  skip-list; conformance number tracked in CI.

Ordering notes: M1 before everything (retrofitting GC or value repr
is the classic mistake). M2–M4 can overlap M1. RegExp is late because
it is a self-contained subproject. The embedding constraint (no global
engine state) is enforced from M1, not added at M12.

## 7. Testing strategy

- **Unit tests** per module (lexer golden tokens, parser AST dumps,
  GC stress tests, hash map torture tests).
- **Golden end-to-end tests**: `test/run/*.ts` with expected stdout;
  the runner diffs output. This is the workhorse from M5 on.
- **GC stress mode** build flag: collect on every allocation to shake
  out missing roots early.
- **Differential testing** (dev tool, not in CI): run the same script
  under Node/Bun and compare output.
- **test262** subset at M12 with an explicit skip-list; the pass count
  is the conformance metric.

## 8. Conventions

- Modern minc throughout: tagged unions for AST/values where they fit,
  generics, `defer`, `Vec<T>`, arenas for parse-phase allocations.
  GC-managed cells for runtime values.
- Comments: brief, neutral, project-specific. Explain what the code
  cannot say — spec references (`// ES2023 7.1.4 ToNumber`), invariants,
  non-obvious choices. No history, no hedging, no references to
  anything outside this repository.
- Diagnostics carry source spans and go through `diag.mc`; nothing
  prints raw errors.
- Top-level constants use `const`. Every file imports what it uses.
- One arena per compile phase; the GC heap owns all runtime values.

## 9. Open items

- Binary and project naming: `tsmc` assumed; confirm before M0.
- License: same as minc, or MIT/Apache-2 dual — decide before first
  public commit.
- `const enum` inlining vs treating as regular enum — decide in M4 plan.
- Minimum host API for scripts (beyond `console`): decide at M12.

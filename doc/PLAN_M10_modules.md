# M10 — modules

ES modules: `import`/`export` across files with relative resolution
and cycle tolerance. The interpreter runs multi-file programs.

## Model

Each module compiles to a function that receives its own namespace
object plus its dependencies' namespace objects as arguments:

```
(function (%ns, %mod0, %mod1) { … })
```

- **Imports** bind as ordinary module-local consts, initialized in a
  prologue from the dependency namespaces (`local = %modK.exported`;
  `* as ns` binds the whole object; `default` reads `%modK.default`).
- **Exports** are ordinary locals that write through to `%ns`. The
  compiler collects the module's export table before hoisting and flags
  each module-scope binding it names; every store to a flagged binding,
  at its declaration or later, from the module body or through an
  upvalue from a nested function, is followed by `%ns.x = x` for each
  name the binding is exported under. Importers read the namespace, so
  the export is a live binding. A name in an `export {}` list that is
  not a module binding (an import, a global) is copied once at the
  statement.
- **Re-exports** (`export { a } from "m"`, `export * from "m"`) copy
  from a dependency namespace onto `%ns`; `export * as n from "m"`
  stores the dependency namespace object itself as `%ns.n`.

No per-identifier namespace routing: within a module, an exported name
is a normal local. This keeps the compiler change contained and needs
no changes to identifier resolution.

## Loading and evaluation

`module.mc` owns the flow. Resolve (relative `./ ../ /`, extension
inference `.ts .js .mjs .mts` and `/index`), read, parse, lower,
compile — recursively, deduped by resolved path. A module record is
marked *loading* before its dependencies are visited, so a cycle links
to the existing record instead of reloading. Namespace objects are
created up front (rooted for the run). Evaluation is post-order DFS;
a module already evaluating (a cycle back-edge) is skipped, its
partially-filled namespace visible to the importer.

The CLI routes through `module_run_entry`: if the entry has top-level
`import`/`export` it loads the graph, otherwise it runs as a plain
script (the existing path), so single-file programs are unaffected.

## Known deviations (documented)

- Exports were first mirrored once at their declaration, so a later
  reassignment of an exported `let` or `var` was not observed across
  modules; TypeScript's namespace output
  (`export var ns; (function (ns) { … })(ns || (ns = {}))`) left
  importers with `undefined`. Stores now write through (see Model);
  `test/diff/esm_live_bindings.mjs` holds the shapes against node.
- An import read checks that the namespace has the name. A cyclic early
  read of a `let`, `const` or class export throws a ReferenceError that
  names the import and its specifier, and so does a name the module
  never exports, which node rejects at link time instead. A hoisted
  function export is not reachable before its module has run, where
  node has it (`test/diff/esm_import_cycle.mjs`).
- Bare specifiers and `node_modules` (M44), `import()` and top-level
  `await` (M41) came later; import attributes stay unsupported.
- `export *` copies `default` too (minor); named re-export is exact.

## Implementation note

Imports turned out to need **live namespace reads**, not eval-time
snapshots: a nested function (a class method, a mutually-recursive
function in a cycle) referencing an import must read the dependency
namespace at call time. So imported names compile to a property read
on the dependency's namespace object, held in a captured `%modK`
binding. The `%ns`/`%modK` bindings are forced to be GC-boxed cells so
nested functions can capture them through the normal upvalue path.

## Tests

Resolver unit test (path join/normalize/extension inference).
Multi-file golden runs under `test/run/mod/`: named/default/namespace
imports, re-exports, a shared-dependency diamond, and a cycle.

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
- **Exports** are ordinary locals that also mirror onto `%ns` at their
  declaration: `export const x = …` compiles to a local `x` plus
  `%ns.x = x`. Functions mirror after hoisting; classes and `let`/
  `var` at their declaration.
- **Re-exports** (`export { a } from "m"`, `export * from "m"`) copy
  from a dependency namespace onto `%ns`.

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

- **Imports snapshot at evaluation time**, not live bindings: an
  importer sees a dependency's exported value as of when the importer
  evaluates. Correct for `const`/function/class exports (the norm);
  a later reassignment of an exported `let` is not observed across
  modules. Within a module the binding is live.
- No module-level TDZ across cycles: a cyclic early read yields
  `undefined` rather than throwing.
- Relative and absolute paths only — no bare specifiers, no
  `node_modules`, no import maps. `import()` dynamic import, top-level
  `await`, and import assertions stay unsupported (diagnostics).
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

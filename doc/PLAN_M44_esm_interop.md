# M44 — ESM: node_modules and CJS interop

Status: planned.

## Why

A `.ts` file is an ES module, and an ES module here cannot reach an npm
package or a CommonJS file. Measured against the current build:

| from an ESM file | node | tsmc |
|---|---|---|
| `import yaml from "js-yaml"` | works | `cannot resolve 'js-yaml'` |
| `import m from "./x.cjs"` | `m` is `module.exports` | `m` is `undefined` |
| `import * as ns from "./x.cjs"` | keys: `default` | keys: none |

That is the whole reason `examples/serve` is written in `.cts`. The
extension is Node's own spelling, so the example stays runnable under
`node`, but the constraint is ours, and it costs the example every form of
`import`, including `import type` and `export`, since any of them marks the
file as ESM.

It also puts every ESM-only package out of reach, which is a growing share
of npm.

## What already works

Dynamic import does both halves today:

```
await import("./x.cjs")   // default is module.exports, keys default,hi,n
await import("js-yaml")   // resolves, default is the package
```

`module_dynamic_import_ns` (`src/module.mc`) has three fallbacks in order:
a built-in name, then `resolve_specifier`, and when that fails or the file
is not ESM, `module_require` plus `js_builtin_namespace`. That last helper
is the CJS-to-ESM shim already: it puts `module.exports` on `default` and
copies the own keys as named exports.

So neither half is missing. Static import simply does not use them.

## The gap

The dependency loop in `load_module` (`src/module.mc`, the `specs` walk)
handles a built-in name, then `resolve_specifier`, then gives up:

```
cannot resolve '<spec>' from '<importer>'
```

It never falls back to `module_require`, and it never checks whether a
resolved file is CJS before handing it to the ESM loader. A CJS file loaded
that way parses fine, exports nothing, and yields an empty namespace. No
error, which is why `import m from "./x.cjs"` gives `undefined` rather than
a failure.

## Tier 1: static import of CJS files and CJS packages

Give the dependency loop the same fallbacks dynamic import has. A
dependency that is not an ESM file becomes a synthetic, pre-evaluated
module, the way `load_builtin_module` already registers built-ins: one
entry in the loader table whose `ns` is the namespace built from
`module.exports`.

One decision to make rather than stumble into. Static dependencies are
resolved during the load phase, and `module_require` evaluates the target
immediately. Doing it there runs a CJS dependency's body before any ESM
body in the graph, which is not Node's order. The alternative is to
register the entry during load and require it during `eval_module`, in
dependency order, which matches. Prefer the second unless it fights the
loader's shape.

Scope: `src/module.mc` only. No compiler change, since named imports read
off the namespace object at run time.

## Tier 2: ESM-only packages

Tier 1 unlocks packages whose entry point is CommonJS. An ESM-only package
needs three more things, none of which exist yet:

- The `import` condition. `is_require_condition` matches `require`, `node`
  and `default`. Resolution has to know which side is asking, and pick
  `import` for an ESM importer.
- `"type": "module"`. Nothing in the tree reads it (grep for it finds only
  a Buffer field, an `os` export and a lexer keyword). Inside such a
  package a `.js` file is ESM, and today it would be treated as CommonJS.
- Routing. Once a package resolves to an ESM file, it has to load through
  the shared loader rather than `module_require`.

A dual package will keep working after tier 1 by taking its `require`
branch, so tier 2 is specifically about packages that ship ESM only.

## Tier 3: the payoff

- `examples/serve` moves from `.cts` to `.ts` and uses `import`. Its README
  loses the section explaining why it could not.
- The README's line about a bare specifier needing `require` goes.
- `doc/npm-compatibility.md` says resolution is CommonJS-only in its
  header. That becomes true of neither tier once this lands, and the
  package table wants a re-run.

## Acceptance

A diff test, `test/diff/esm_interop.mjs`, matching node on:

- `import m from "./x.cjs"` gives `module.exports`
- `import * as ns` has `default`
- `import pkg from "js-yaml"` resolves and works
- a CJS dependency's side effects run in dependency order, not before the
  whole graph
- a package with a subpath export, `require("pkg/sub")` and its `import`
  spelling, agreeing
- the failure mode for a specifier that resolves nowhere is still an error,
  not an empty namespace

Then `examples/serve` converted, and `check.cjs` producing the same
transcript it does now, which is the real regression test for the example.

## Notes

- Named imports from a CJS module are more permissive here than in node.
  `js_builtin_namespace` copies every own key, where node relies on a lexer
  and refuses what it cannot see. Permissive in the direction that runs
  more code, so it is worth keeping and worth writing down.
- Circular imports across the ESM/CJS boundary are the sharp edge. An ESM
  module that imports a CJS file that requires it back has no good answer
  in any runtime, and the loader's dedup key needs to be the same for both
  paths or the cycle turns into two copies.
- `examples/serve` runs on `node` today. Whatever lands has to keep that
  true, since it is what makes the example honest.

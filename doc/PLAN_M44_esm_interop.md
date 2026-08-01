# M44 — ESM: node_modules and CJS interop

Status: complete.

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

## Tier 1 as built

The dependency loop takes `resolve_require` when `resolve_specifier` finds
nothing, and classifies whatever comes back: an ESM file goes to the ESM
loader, anything else becomes a synthetic module that `require` owns. The
require runs in `eval_module`, so a CommonJS dependency's body lands in
dependency order, which is the option the plan preferred and which matches
node:

    cjs body ran
    esm dep body ran
    importer body ran

Keyed by the target's canonical path, so a file imported statically and
again through `await import()` is one module. `test/diff/esm_interop.mjs`
checks that, along with the default export and the namespace shape.

A `.ts` file can now import an npm package:

    import yaml from 'js-yaml';
    import MarkdownIt from 'markdown-it';

The classification also fixes a relative `.js` import whose target turns
out to be CommonJS. That used to parse as ESM, export nothing, and yield
an empty namespace with no error.

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

## Tier 2 as built

Measuring first cut this down. Of five ESM-only package shapes, three
already worked after tier 1, because the source sniff catches `export`
syntax wherever it appears. Two did not, and those are what tier 2 is:

- A package gating its entry on the `import` condition. `is_active_condition`
  now takes who is asking: `node` and `default` always match, then `import`
  for an ESM importer and `require` for a require(). The flag is threaded
  from the two call sites down through the target resolver.
- A `"type": "module"` entry whose own syntax gives nothing away. A body
  with top-level await and no import or export was classified as CommonJS
  and failed to parse. `pkg_type_is_module` walks up to the nearest
  package.json and lets it decide, before the sniff.

`test/diff/esm_packages.mjs` covers both against node, with a fixture
carrying its own node_modules so the walk starts beside it. The dual
package in it proves the split works in both directions: `import` takes
the ESM branch, `require` the CommonJS one, from the same package.

## Tier 3: the payoff

- `examples/serve` moves from `.cts` to `.ts` and uses `import`. Its README
  loses the section explaining why it could not.
- The README's line about a bare specifier needing `require` goes.
- `doc/npm-compatibility.md` says resolution is CommonJS-only in its
  header. That becomes true of neither tier once this lands, and the
  package table wants a re-run.

## Tier 3 as built

`examples/serve` is `.ts` throughout, with `import` and `export`. The
transcript `check.cjs` prints is byte-identical to the `.cts` version, over
plain HTTP and over TLS, which is the regression test that matters here.

Two things came out of the conversion.

`import.meta.dirname` and `.filename` did not exist. An ESM file has no
`__dirname` in node, and the example needs its own directory to find
`content/`. tsmc had `__dirname` in ESM, which node does not, so writing
the example against it would have taught a spelling that only works here.
Both are compile-time constants now, like `import.meta.url` beside them.

`export enum` and `export namespace` exported the name with the value
undefined. The lowering emits `var E` and then an IIFE that fills it, and
an export copies the binding where it stands, which is before the IIFE
runs. `import { Outcome }` therefore gave undefined, and the server threw
on its first request. A second export after the IIFE carries the value.
`test/run/export_enum.ts` covers both forms.

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
- `examples/serve` does not run on plain `node`, which the earlier note
  here got wrong: node 22 needs `--experimental-strip-types` for a `.cts`
  or `.ts` file, and refuses the first `interface` without it. Only
  `check.cjs` is portable, being plain JavaScript.

# M20 — `require` / CommonJS

Adds synchronous CommonJS module loading (`require(...)`, `module.exports`,
`exports`) alongside the existing ES-module system, so real Node-style
CJS scripts and multi-file programs run.

## Model

A CJS module is a **function** with the Node wrapper scope
`(exports, require, module, __dirname, __filename)`, run to completion the
first time it is required. Its `module.exports` (initially `exports`, an
empty object aliased by both) is the require result.

- **Compiler**: `compile_cjs_module` compiles a program body as a
  5-parameter function (the wrapper names, forced to cells so nested
  functions capture them). Free identifiers still resolve to globals
  (`console`, `Buffer`, `process`, …). No textual wrapping, so line
  numbers in stack traces are unshifted.
- **`require(spec)`** (in `module.mc`, exposed as a native bound to the
  requiring module's path):
  1. **Built-in** (`fs`/`path`/`os`, `node:` prefix) → the module object
     (the `default` of the built-in namespace).
  2. **Relative/absolute file** (`./`, `../`, `/`, or a Windows drive) →
     resolved via the same candidate rules as ESM (`.ts`/`.js`/`.mjs`/
     `/index.*`).
  3. Anything else (bare `lodash`) → `Cannot find module` (node_modules
     is the documented deferral).
- **Cache**: a per-VM object keyed by canonical path stores the `module`
  object; a hit returns its current `module.exports`. The module is cached
  **before** its body runs, so a circular `require` sees the partial
  exports (Node semantics).
- **Entry**: a plain script (no `import`/`export`) runs with a `require`
  global bound to the entry file, plus the existing `__dirname` /
  `__filename`. So `node script.js` that uses `require` works.

## Interop / scope

- `require('fs')` etc. return the same built-in module objects ESM
  `import` binds.
- `module.exports = fn` (whole-object replacement) and
  `exports.foo = …` (property attach) both work; the result re-reads
  `module.exports` after the body, so reassignment is honored.
- ESM and CJS coexist: import-syntax files take the ESM path; everything
  else can use `require`.

## Not doing (documented)

- **`node_modules` resolution / npm** — bare specifiers don't resolve;
  this is the big follow-up that unlocks packages.
- **`require.resolve` / `require.cache` / `require.main`**, conditional
  `exports` maps, `.node` native addons, `.json` auto-parse.
- **ESM ⇄ CJS interop niceties** — `import` of a CJS file, or `require`
  of an ESM file, are not bridged.

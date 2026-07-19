# M20 — `require` / CommonJS

Adds synchronous CommonJS module loading (`require(...)`, `module.exports`,
`exports`) alongside the existing ES-module system, so real Node-style
CJS scripts and multi-file programs run. **`node_modules` resolution is
implemented** (see below), so bare specifiers and installed packages load.

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
     LOAD_AS_FILE (`base`, then `.js`/`.ts`/`.cjs`/`.mjs`/`.json`; a
     directory never matches as a file) then LOAD_AS_DIRECTORY
     (`package.json` `main`, else `index.*`).
  3. **Bare specifier** (`lodash`, `@scope/pkg`, `pkg/sub`) →
     LOAD_NODE_MODULES: split into package + subpath (first segment, or
     first two for `@scope/name`), then walk up from the requiring
     module's dir trying `<d>/node_modules/<pkg>[/<subpath>]` at each
     level (LOAD_AS_FILE then LOAD_AS_DIRECTORY) to the filesystem root.
  4. **`.json`** → parsed with the JSON engine and returned directly (the
     value is the exports; no code is run).
  5. Unresolved → `Cannot find module`.
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

- **`package.json` `exports` maps** — only the legacy `main` field is
  read; conditional/subpath `exports` (the modern `"."` → `{require,
  import, default}` form) is not resolved, so packages that ship *only*
  an `exports` map (no `main`, no `index.js`) won't resolve. Covers most
  CJS packages; the follow-up is a conditional-exports resolver.
- **`require.resolve` / `require.cache` / `require.main`**, `.node`
  native addons.
- **ESM ⇄ CJS interop niceties** — `import` of a CJS file, or `require`
  of an ESM file, are not bridged.
- **npm itself** — resolution works against an existing `node_modules`
  tree; installing packages is out of scope (use npm/pnpm to populate it).

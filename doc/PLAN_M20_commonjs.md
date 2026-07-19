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
     module's dir to the filesystem root. At each level, if
     `<d>/node_modules/<pkg>` is a directory, resolve within it and stop.
  4. **`package.json` `exports`** — when present it is **authoritative**:
     a string / array-fallback / conditions object maps `.`, or a
     subpath map (`.`-prefixed keys) maps `.`/`./sub`. Conditions are
     matched in key order against the require set (`node`/`require`/
     `default`); nested conditions and arrays resolve recursively.
     Non-listed subpaths are **blocked** (error), and `main` is ignored
     when `exports` is present — matching Node. Without `exports`, the
     legacy `main` / `index.*` / subpath-as-file applies.
  5. **`.json`** → parsed with the JSON engine and returned directly (the
     value is the exports; no code is run).
  6. Unresolved → `Cannot find module` (error carries
     `.code = "MODULE_NOT_FOUND"`).
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

- **`exports` wildcard subpaths** (`"./*": "./src/*.js"` pattern
  matching) and the `imports` map (`#internal`) are not handled; explicit
  subpath keys and the main entry are.
- **Non-require conditions** — only `node`/`require`/`default` are matched
  (not `import`/`browser`/`development`/custom `--conditions`), so a
  package's `import`-only entry isn't reachable from `require`.
- **`ERR_PACKAGE_PATH_NOT_EXPORTED` fidelity** — a blocked subpath throws
  with the `Cannot find module` message + `.code = "MODULE_NOT_FOUND"`,
  not Node's distinct `ERR_PACKAGE_PATH_NOT_EXPORTED` code. It blocks
  correctly; only the code differs.
- **`require.resolve` / `require.cache` / `require.main`**, `.node`
  native addons.
- **ESM ⇄ CJS interop niceties** — `import` of a CJS file, or `require`
  of an ESM file, are not bridged.
- **npm itself** — resolution works against an existing `node_modules`
  tree; installing packages is out of scope (use npm/pnpm to populate it).

# M41 — dynamic import() and import.meta

Status: complete

## Goal

Support `import(specifier)` as an expression: it returns a promise that
resolves to the target module's namespace. Also give `import.meta` a `url`.
Closes a language gap that blocked a class of modern packages (the compiler
previously rejected both with "expression not supported yet").

## Semantics

- `import(spec)` returns a promise. The specifier is `ToString`'d, resolved
  relative to the importing module/script, the target is loaded and evaluated,
  and the promise settles with the namespace (or rejects with the error).
- ESM targets get their real namespace (named exports + `default`), and their
  static-import dependencies load and evaluate too. A module imported both
  statically and dynamically is one instance (singleton).
- Built-in, CommonJS, and JSON targets go through `require()` and are wrapped
  with Node's interop shape: `default` is `module.exports`, plus its enumerable
  own keys as named bindings. (Node derives CJS *named* exports by static
  analysis, which a runtime view cannot match exactly; only `default` is
  relied on for CJS.)
- `import.meta.url` is a `file://` URL of the current module.

## Implementation

- **Parser** already produced `N_IMPORT_EXPR` / `N_IMPORT_META`.
- **Compiler** (`compile_call`): a call whose callee is `N_IMPORT_EXPR`
  compiles the specifier, pushes this module's path as a constant, and emits
  `OP_DYNIMPORT`. `import.meta` builds an object literal with `url` (the path
  as a file URL, computed at compile time). Bare `import` is an error.
- **VM**: `OP_DYNIMPORT` pops (spec, referrer) and calls `vm.dynimport_hook`,
  installed by the module layer — the same decoupling the reactor hook uses,
  keeping vm.mc free of the loader. The operands stay on the stack across the
  hook (rooted) since it allocates and may evaluate a module.
- **Module layer**: the hook resolves the target and returns a settled
  promise. ESM files load through a persistent `Loader` now owned by
  `module_run_entry` and shared with static loading (so dedup gives singleton
  semantics); evaluation uses a capturing post-order walk so a throw rejects
  the promise instead of printing. `.mjs`/`.mts` entries and targets are
  treated as modules regardless of syntax.

## Not covered

- Import attributes (`with { type: 'json' }`) are parsed-position-ignored; JSON
  imports work by extension without the attribute.
- Top-level `await` inside a *dynamically* imported module is not driven to
  completion (would require re-entering the event loop); such a module's async
  exports may be incomplete. Synchronous module bodies (the common case) are
  fully evaluated.

## Validation

`test/diff/dynimport.mjs` (fixtures under `dynimport_fixtures/`, not globbed as
standalone tests) is byte-identical to Node: ESM named/default, `.then`, async
function, transitive static deps, CJS `default` interop, a built-in, singleton
identity, `import.meta.url`, and rejection. Full suite + `--gc-stress` green.

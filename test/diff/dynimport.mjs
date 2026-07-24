// Dynamic import(): ESM, CJS-default interop, a built-in, transitive deps,
// import.meta.url, and rejection — the behavior that matches Node.
// Fixtures live in dynimport_fixtures/ so the diff runner does not pick them
// up as standalone tests.

// Top-level await of an ESM module.
const m = await import('./dynimport_fixtures/esm_mod.mjs');
console.log('esm named:', m.answer, m.add(2, 3));
console.log('esm default:', m.default('x'));

// The returned object really is a module namespace.
console.log('has default+named:', 'default' in m, 'answer' in m);

// .then() form.
await import('./dynimport_fixtures/esm_mod.mjs').then((mod) => {
  console.log('then:', mod.answer);
});

// import() inside a regular async function.
async function load() {
  const mod = await import('./dynimport_fixtures/esm_mod.mjs');
  return mod.add(100, 1);
}
console.log('in async fn:', await load());

// An ESM module with its own static import dependency.
const re = await import('./dynimport_fixtures/esm_reexport.mjs');
console.log('transitive dep:', re.sum, re.label);

// CJS module: default is module.exports (named CJS exports are not asserted —
// Node derives them by static analysis, which differs from a runtime view).
const c = await import('./dynimport_fixtures/cjs_mod.cjs');
console.log('cjs default:', c.default.cjsVal, c.default.cjsFn(5));

// A built-in module through import().
const os = await import('node:os');
console.log('builtin default is object:', typeof os.default);

// Two imports of the same module are the same namespace (singleton).
const a1 = await import('./dynimport_fixtures/esm_mod.mjs');
const a2 = await import('./dynimport_fixtures/esm_mod.mjs');
console.log('singleton:', a1 === a2);

// import.meta.url is a file:// URL of this module.
console.log('meta url:', import.meta.url.endsWith('dynimport.mjs'), import.meta.url.startsWith('file://'));

// A missing specifier rejects.
try {
  await import('./dynimport_fixtures/does-not-exist.mjs');
  console.log('no throw');
} catch (e) {
  console.log('rejected:', e instanceof Error);
}

// Before a graph runs, every named import and re-export must resolve to
// one binding: a re-export cycle, a name two `export *` modules both
// provide, and a name the module does not export are each a SyntaxError
// at link time, so a dynamic import of such a module rejects. A name
// reached twice through the same binding is fine, and `export *` never
// forwards a default.

const outcome = async (spec) => {
  try {
    const ns = await import(spec);
    return 'ok ' + Object.keys(ns).sort().map((k) => k + '=' + String(ns[k])).join(' ');
  } catch (e) {
    return e.constructor.name;
  }
};
for (const spec of ['./esm_link/circ_a.mjs', './esm_link/ambiguous.mjs', './esm_link/unambiguous.mjs', './esm_link/via_same.mjs', './esm_link/missing.mjs', './esm_link/reexport_missing.mjs', './esm_link/wants_star_default.mjs', './esm_link/agg.mjs']) {
  console.log(spec.replace('./esm_link/', ''), await outcome(spec));
}

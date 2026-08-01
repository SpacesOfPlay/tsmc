// Resolving a package from an ES module. Covers the import condition of a
// dual package, and a "type": "module" package whose entry needs ESM
// parsing to work at all: its body has a top-level await and no import or
// export syntax to give it away.
//
// The fixture keeps its own node_modules, so the walk starts next to
// esm_pkg/app.mjs rather than in the repo.

import { report } from './esm_pkg/app.mjs';
console.log(report.join('\n'));

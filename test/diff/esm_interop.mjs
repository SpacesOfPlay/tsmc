// ESM reaching a CommonJS file. module.exports becomes the default export,
// and the dependency runs in order with the ESM bodies around it.
//
// A bare specifier out of node_modules is covered by the example, not here:
// the diff suite has no node_modules of its own to resolve against.

import dep from './esm_interop/dep.cjs';
import * as ns from './esm_interop/dep.cjs';
import { mid } from './esm_interop/mid.mjs';
import sub from './esm_interop/sub.cjs';

console.log('importer body ran');
console.log('default is exports:', dep.name, dep.add(2, 3));
console.log('namespace has default:', typeof ns.default, ns.default === dep);
console.log('esm dep still works:', mid);
console.log('second cjs file:', sub.deep);

// The same file imported twice is one module.
const again = await import('./esm_interop/dep.cjs');
console.log('dynamic agrees with static:', again.default === dep);

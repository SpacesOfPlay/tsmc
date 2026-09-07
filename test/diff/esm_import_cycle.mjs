// A cycle: b runs first and reads a's `const` before a's body has run,
// which is a ReferenceError, not undefined. Once a has run, the same
// binding reads through.
import './esm_cycle/a.mjs';
import { readAgain } from './esm_cycle/b.mjs';
console.log('after both ran:', readAgain());

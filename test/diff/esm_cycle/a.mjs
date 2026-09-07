// The importer of b; b reads an export of a before a's body has run.
import { fromB } from './b.mjs';
export const x = 'x from a';
console.log('a body: b saw', fromB);

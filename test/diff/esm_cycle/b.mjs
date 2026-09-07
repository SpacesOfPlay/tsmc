import { x } from './a.mjs';
let seen;
try { seen = x; } catch (e) { seen = e.constructor.name; }
export const fromB = seen;
console.log('b body:', seen);
export function readAgain() { return x; }

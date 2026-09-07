// Every way a module can store to an exported binding after it is
// declared. The importer reads each one before and after.

// the shape TypeScript emits for a namespace
export var util;
(function (util) {
  util.x = 1;
  util.double = (n) => n * 2;
})(util || (util = {}));

// declared, assigned later at module level
export let later;
later = 'set after declaration';

// stores from nested functions, through an upvalue
export var counter = 0;
export function bump() { counter++; }
export function add(n) { counter += n; }
export const reset = () => { counter = 0; };

// one binding under two exported names
let a = 1;
export { a as b, a };
export function setA(v) { a = v; }

// destructuring assignment onto exported bindings
export let p = 'p0', q = 'q0';
export function swap() { [p, q] = [q, p]; }

// a for-of head that is an exported var
export var last;
for (last of [1, 2, 3]) {}

// export list before the declaration it names
export { fromBelow };
let fromBelow = 'declared after the export list';

// a named default function is a binding like any other
export default function main() { return 'first main'; }
export function replaceMain() { main = function () { return 'second main'; }; }

// a class binding reassigned
export class Shape {}
export function replaceShape() { Shape = class Circle {}; }

// logical assignment
export let cached;
export function fill() { cached ??= 'filled'; }

// console.assert, on its own because it writes to stderr. Mixing the two
// streams in one file makes the merged order depend on flushing.

console.assert(true, 'not shown');
console.assert(1, 'not shown either');
console.assert(false, 'shown %s and %d', 'here', 42);
console.assert(false);
console.assert(false, { a: 1 });
console.assert(0, 'falsy zero');

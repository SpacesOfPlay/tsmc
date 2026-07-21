// Non-mutating Array.prototype methods accept an array-like `this` (an object
// with a numeric length), as in Node: the classic `.call(arguments)` /
// `.call(arrayLike)` idioms. Compared byte-for-byte against Node.
//
// Mutating methods (push/pop/splice/sort/…) still require a real array here;
// that array-like write-back case is out of scope for now.

// the canonical slice.call(arguments) conversion
function toArr() { return Array.prototype.slice.call(arguments); }
console.log(toArr(1, 2, 3).join(','));
function tail() { return Array.prototype.slice.call(arguments, 1); }
console.log(tail('a', 'b', 'c').join(','));

// a plain array-like object
const like = { length: 3, 0: 'x', 1: 'y', 2: 'z' };
console.log(Array.prototype.join.call(like, '-'));
console.log(Array.prototype.indexOf.call(like, 'y'));
console.log(Array.prototype.includes.call(like, 'z'));
console.log(Array.prototype.slice.call(like, 1).join(','));
console.log(Array.prototype.at.call(like, -1));

// iteration methods over an array-like
console.log(Array.prototype.map.call(like, s => s.toUpperCase()).join(','));
console.log(Array.prototype.filter.call({ length: 4, 0: 1, 1: 0, 2: 2, 3: 0 }, Boolean).join(','));
console.log(Array.prototype.reduce.call({ length: 3, 0: 1, 1: 2, 2: 3 }, (a, b) => a + b, 0));
let acc = '';
Array.prototype.forEach.call(like, s => { acc += s; });
console.log(acc);

// over the arguments object specifically
console.log((function () { return Array.prototype.map.call(arguments, x => x * x); })(2, 3, 4).join(','));

// real arrays are unaffected (same fast path)
console.log([5, 6, 7].slice(1).join(','));
console.log([1, 2, 3].map(x => x + 1).join(','));

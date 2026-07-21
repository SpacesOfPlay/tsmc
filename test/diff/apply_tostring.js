// Function.prototype.apply / Reflect.apply accept any array-like args list
// (a real array, the arguments object, a {length,...} object), and
// Object.prototype.toString returns the correct [[Class]] tag. Both are
// ubiquitous library primitives. Compared byte-for-byte against Node.

// apply with a real array, and forwarding the arguments object
function add() { let s = 0; for (let i = 0; i < arguments.length; i++) s += arguments[i]; return s; }
console.log(add.apply(null, [1, 2, 3, 4]));
function fwd() { return add.apply(this, arguments); }
console.log(fwd(5, 6, 7));

// apply with a plain array-like object
console.log((function (a, b, c) { return a + b + c; }).apply(null, { length: 3, 0: 10, 1: 20, 2: 30 }));

// apply with null/undefined list -> zero args
console.log((function () { return arguments.length; }).apply(null));
console.log((function () { return arguments.length; }).apply(null, undefined));

// the classic curry pattern: fn.apply(this, arguments) inside a wrapper
function _curry1(fn) {
  return function f1(a) {
    if (arguments.length === 0) return f1;
    return fn.apply(this, arguments);
  };
}
const inc = _curry1((x) => x + 1);
console.log(inc(9), typeof inc());

// Reflect.apply with an array-like
console.log(Reflect.apply((a, b) => a * b, null, { length: 2, 0: 6, 1: 7 }));

// Object.prototype.toString [[Class]] tags
const ts = Object.prototype.toString;
console.log(ts.call([1, 2]), ts.call('s'), ts.call(5), ts.call(true), ts.call(null), ts.call(undefined));
console.log(ts.call({}), ts.call(function () {}), ts.call(/re/), ts.call(new Date(0)), ts.call(new Error('e')));
console.log(ts.call(10n), ts.call(Symbol('x')));

// the type-detection idiom libraries rely on
const isArr = (x) => Object.prototype.toString.call(x) === '[object Array]';
const isStr = (x) => Object.prototype.toString.call(x) === '[object String]';
console.log(isArr([1]), isArr('x'), isArr({}), isStr('x'), isStr([1]));

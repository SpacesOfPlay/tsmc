// util module. require('util') works in Node CJS and tsmc alike.
const util = require("util");
process.noDeprecation = true; // suppress node's pid-bearing deprecation warning

// format
console.log(util.format("%s-%d-%i-%f", "x", 3.9, 3.9, 3.9));
console.log(util.format("%j", { a: 1, b: [2, 3] }));
console.log(util.format("%o", { a: 1 }), util.format("%s", { x: 1 }));
console.log(util.format("hi %s, n=%d", "bob", 42));
console.log(util.format("no specifiers", "extra", 1));
console.log(util.format("100%% done"));

// inspect
console.log(util.inspect("a string"), util.inspect({ a: 1, b: "two" }), util.inspect([1, 2, 3]));

// types
console.log(util.types.isDate(new Date()), util.types.isRegExp(/x/), util.types.isMap(new Map()), util.types.isSet(new Set()));
console.log(util.types.isPromise(Promise.resolve()), util.types.isNativeError(new TypeError("x")), util.types.isDate({}));
console.log(util.types.isAsyncFunction(async () => {}), util.types.isGeneratorFunction(function* () {}), util.types.isAsyncFunction(() => {}));
console.log(util.types.isTypedArray(new Map()), util.types.isArrayBuffer({}));

// isDeepStrictEqual
console.log(util.isDeepStrictEqual({ a: [1, 2], b: { c: 3 } }, { a: [1, 2], b: { c: 3 } }));
console.log(util.isDeepStrictEqual({ a: 1 }, { a: "1" }), util.isDeepStrictEqual([1, NaN], [1, NaN]));
console.log(util.isDeepStrictEqual(new Date(1000), new Date(1000)), util.isDeepStrictEqual(new Date(1), new Date(2)));

// inherits
function Animal(n) { this.n = n; }
Animal.prototype.speak = function () { return this.n + " speaks"; };
function Dog(n) { Animal.call(this, n); }
util.inherits(Dog, Animal);
Dog.prototype.bark = function () { return "woof"; };
const d = new Dog("Rex");
console.log(d.speak(), d.bark(), d instanceof Animal, Dog.super_ === Animal);

// deprecate (passthrough)
const add = util.deprecate((a, b) => a + b, "add is deprecated");
console.log(add(2, 3));

// promisify + callbackify (async — settle after the script)
const later = (x, cb) => cb(null, x * 10);
const failing = (cb) => cb(new Error("nope"));
util.promisify(later)(5).then((r) => console.log("promisify ok", r));
util.promisify(failing)().catch((e) => console.log("promisify err", e.message));

const asyncDouble = (x) => Promise.resolve(x * 2);
util.callbackify(asyncDouble)(21, (err, v) => console.log("callbackify", err, v));

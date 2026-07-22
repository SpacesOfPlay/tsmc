// A Symbol is a valid property key for defineProperty, which used to run the
// key through ToString and throw "Cannot convert a Symbol value to a string".
// Object.getOwnPropertySymbols is the mirror of getOwnPropertyNames.
// Compared byte-for-byte against Node.

const S = Symbol('k');
const o = {};

// data property under a symbol key, then redefined
Object.defineProperty(o, S, { value: 42, writable: true, enumerable: false });
console.log('data:', o[S]);
Object.defineProperty(o, S, { value: 43 });
console.log('redefined:', o[S]);

// accessor under a symbol key
const A = Symbol('acc');
Object.defineProperty(o, A, {
  get() { return 'G' + this[S]; },
  set(v) { this._v = v; },
  configurable: true
});
console.log('getter:', o[A]);
o[A] = 9;
console.log('setter:', o._v);

// descriptor round-trip through a symbol key
const d = Object.getOwnPropertyDescriptor(o, S);
console.log('descriptor:', d.value, d.enumerable, d.writable);

// symbol keys stay out of the string-key enumerations
console.log('keys:', JSON.stringify(Object.keys(o)));
console.log('names:', JSON.stringify(Object.getOwnPropertyNames(o)));

// getOwnPropertySymbols
const B = Symbol('b');
const p = { plain: 1, [B]: 2 };
Object.defineProperty(p, Symbol('c'), { value: 3, enumerable: true });
const syms = Object.getOwnPropertySymbols(p);
console.log('symbols:', syms.length, syms.map(s => s.description).join(','));
console.log('symbol values:', syms.map(s => p[s]).join(','));
console.log('none:', Object.getOwnPropertySymbols({}).length);
console.log('on function:', Object.getOwnPropertySymbols(function () {}).length);

// Reflect.defineProperty with a symbol key, and a symbol key on a function
const R = Symbol('r');
console.log('reflect:', Reflect.defineProperty(o, R, { value: 7 }), o[R]);
function fn() {}
Object.defineProperty(fn, S, { value: 'onFn', enumerable: true });
console.log('fn symbol key:', fn[S], Object.getOwnPropertySymbols(fn).length);

// the well-known iterator symbol still works as a key
const iterable = { [Symbol.iterator]() { let i = 0; return { next: () => ({ value: i, done: i++ >= 2 }) }; } };
console.log('iterator:', JSON.stringify([...iterable]));

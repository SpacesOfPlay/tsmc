// isPrototypeOf, and what getPrototypeOf reports for the values that are not
// plain objects: a Set, a Map, a generator, a primitive.

const rows = [];
const T = (l, f) => { try { rows.push(l + ' = ' + JSON.stringify(f())); } catch (e) { rows.push(l + ' = THROW:' + e.name); } };
function* g() { yield 1; }

// --- isPrototypeOf ----------------------------------------------------------
T('isPrototypeOf-type', () => typeof Object.prototype.isPrototypeOf);
T('obj-plain', () => Object.prototype.isPrototypeOf({}));
T('obj-direct', () => { const p = {}; return p.isPrototypeOf(Object.create(p)); });
T('obj-deep', () => { const p = {}; return p.isPrototypeOf(Object.create(Object.create(p))); });
T('obj-self', () => { const p = {}; return p.isPrototypeOf(p); });
T('obj-unrelated', () => ({}).isPrototypeOf({}));
T('null-proto-arg', () => Object.prototype.isPrototypeOf(Object.create(null)));
T('primitive-arg', () => Object.prototype.isPrototypeOf(5));
T('string-arg', () => String.prototype.isPrototypeOf('a'));
T('null-arg', () => Object.prototype.isPrototypeOf(null));
T('no-arg', () => Object.prototype.isPrototypeOf());
T('array', () => Array.prototype.isPrototypeOf([]));
T('set', () => Set.prototype.isPrototypeOf(new Set()));
T('map', () => Map.prototype.isPrototypeOf(new Map()));
T('date', () => Date.prototype.isPrototypeOf(new Date(0)));
T('regexp', () => RegExp.prototype.isPrototypeOf(/x/));
T('error', () => Error.prototype.isPrototypeOf(new TypeError('x')));
T('error-direct', () => TypeError.prototype.isPrototypeOf(new TypeError('x')));
T('class', () => { class A {} class B extends A {} return A.prototype.isPrototypeOf(new B()); });
T('class-static', () => { class A {} class B extends A {} return A.isPrototypeOf(B); });
T('fn', () => Function.prototype.isPrototypeOf(function () {}));
T('object-on-array', () => Object.prototype.isPrototypeOf([]));
T('object-on-fn', () => Object.prototype.isPrototypeOf(function () {}));
T('promise', () => Promise.prototype.isPrototypeOf(Promise.resolve(1)));
T('generator', () => Object.prototype.isPrototypeOf(g()));
T('wrong-way-round', () => Object.create(Object.prototype).isPrototypeOf(Object.prototype));

// --- getPrototypeOf ---------------------------------------------------------
T('getproto-obj', () => Object.getPrototypeOf({}) === Object.prototype);
T('getproto-arr', () => Object.getPrototypeOf([]) === Array.prototype);
T('getproto-set', () => Object.getPrototypeOf(new Set()) === Set.prototype);
T('getproto-map', () => Object.getPrototypeOf(new Map()) === Map.prototype);
T('getproto-date', () => Object.getPrototypeOf(new Date(0)) === Date.prototype);
T('getproto-regexp', () => Object.getPrototypeOf(/x/) === RegExp.prototype);
T('getproto-gen-not-null', () => Object.getPrototypeOf(g()) === null);
T('getproto-number', () => Object.getPrototypeOf(5) === Number.prototype);
T('getproto-string', () => Object.getPrototypeOf('a') === String.prototype);
T('getproto-bool', () => Object.getPrototypeOf(true) === Boolean.prototype);
T('getproto-symbol', () => Object.getPrototypeOf(Symbol('s')) === Symbol.prototype);
T('getproto-bigint', () => Object.getPrototypeOf(1n) === BigInt.prototype);
T('getproto-fn', () => Object.getPrototypeOf(function () {}) === Function.prototype);
T('getproto-null', () => Object.getPrototypeOf(null));
T('getproto-undefined', () => Object.getPrototypeOf(undefined));
T('getproto-null-proto', () => Object.getPrototypeOf(Object.create(null)));
T('dunder-proto-primitive', () => (5).__proto__ === Number.prototype);
T('dunder-proto-set', () => new Set().__proto__ === Set.prototype);

// --- the same chain seen through instanceof ----------------------------------
T('set-instanceof', () => new Set() instanceof Set);
T('map-instanceof', () => new Map() instanceof Map);
T('gen-instanceof-object', () => g() instanceof Object);

console.log(rows.join('\n'));

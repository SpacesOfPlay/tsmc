// `__proto__`, and the rule that an object literal *defines* its properties
// rather than assigning them, so an inherited setter is never invoked.

const out = [];
const r = (label, v) => out.push(label + '=' + v);

// The accessor on Object.prototype, reachable from anything inheriting it.
r('read', ({}).__proto__ === Object.prototype);
r('read-array', [].__proto__ === Array.prototype);
r('read-class', (() => { class A {} return new A().__proto__ === A.prototype; })());
r('write', (() => { const p = { a: 1 }; const c = {}; c.__proto__ = p; return c.a; })());
r('write-null', (() => { const c = { a: 1 }; c.__proto__ = null; return Object.getPrototypeOf(c); })());

// A plain `__proto__:` key in a literal sets the prototype.
const proto = { inherited: 1 };
const lit = { __proto__: proto };
r('literal', lit.inherited + ',' + (Object.getPrototypeOf(lit) === proto));
r('literal-quoted', (() => { const o = { '__proto__': proto }; return Object.getPrototypeOf(o) === proto; })());
r('literal-null', Object.getPrototypeOf({ __proto__: null }));
// A non-object, non-null value leaves the prototype alone.
r('literal-number', Object.getPrototypeOf({ __proto__: 5 }) === Object.prototype);
// It is not an own property.
r('literal-not-own', Object.keys({ __proto__: proto }).length + ',' + JSON.stringify({ __proto__: proto }));

// The other spellings stay ordinary properties.
r('computed', (() => { const k = '__proto__'; const o = { [k]: proto }; return o.__proto__ === proto && Object.getPrototypeOf(o) === Object.prototype; })());
r('shorthand', (() => { const __proto__ = { a: 1 }; const o = { __proto__ }; return Object.getPrototypeOf(o) === Object.prototype; })());
r('method', typeof ({ __proto__() { return 1; } }).__proto__);

// A literal defines, so an inherited setter is not called.
Object.defineProperty(Object.prototype, 'trapped', {
  set() { throw new Error('setter ran'); },
  get() { return 'inherited'; },
  configurable: true,
});
r('literal-defines', (() => { const o = { trapped: 'own' }; return o.trapped; })());
// Plain assignment still goes through the setter.
r('assignment-sets', (() => { try { const o = {}; o.trapped = 1; return 'no-throw'; } catch (e) { return e.message; } })());
delete Object.prototype.trapped;

// Ordinary literal behaviour is unchanged.
r('computed-numeric', JSON.stringify({ [0]: 'a', [1]: 'b' }));
r('duplicate-key', JSON.stringify({ a: 1, a: 2 }));
r('spread', JSON.stringify({ ...{ a: 1 }, b: 2 }));
r('getter', (() => { const o = { get v() { return 3; } }; return o.v + ',' + Object.keys(o); })());
r('shorthand-value', (() => { const x = 7; return JSON.stringify({ x }); })());

// Array.prototype.findLastIndex.
r('findLastIndex', [3, 1, 2].findLastIndex((x) => x > 1));
r('findLastIndex-none', [1].findLastIndex((x) => x > 5));
r('findLast-pair', [3, 1, 2].findLast((x) => x > 1));

// Every regular expression flag is reported as its own property.
const re = /ab/gi;
r('flags-gi', [re.global, re.ignoreCase, re.multiline, re.dotAll, re.unicode, re.sticky].join(','));
const re2 = /a/msuy;
r('flags-msuy', [re2.global, re2.ignoreCase, re2.multiline, re2.dotAll, re2.unicode, re2.sticky].join(','));
r('flags-string', re.flags + ',' + re.source);

console.log(out.join('\n'));

// Object literals: the order keys end up in, what a repeated key does, and how
// plain keys mix with spreads, computed keys, accessors and `__proto__`. A
// literal's plain keys are defined by a dedicated instruction that appends
// without looking, so every way a key can already be there is covered here.
const J = JSON.stringify;
const src = { a: 9, z: 8 };

// a repeated key keeps its first position and takes the last value
console.log(J({ a: 1, a: 2 }), J(Object.keys({ a: 1, a: 2 })));
console.log(J({ a: 1, b: 2, a: 3 }), J(Object.keys({ a: 1, b: 2, a: 3 })));

// integer-like keys read first, in numeric order, whatever order they were written
console.log(J({ b: 1, 2: 2, a: 3, 1: 4 }), J(Object.keys({ b: 1, 2: 2, a: 3, 1: 4 })));
console.log(J({ 1: 'a', '1': 'b' }), J({ '01': 'a', 1: 'b' }));

// a spread may carry any key, so what follows it can be a redefinition
console.log(J({ ...src, a: 1 }), J({ a: 1, ...src }), J({ a: 1, ...src, a: 3 }));

// so may a computed key
console.log(J({ ['a']: 1, a: 2 }), J({ a: 2, ['a']: 1 }), J({ a: 1, ['b']: 2, a: 3 }));

// an accessor and a data property over one another
const g1 = { get a() { return 1; }, a: 2 };
console.log(g1.a, J(Object.getOwnPropertyDescriptor(g1, 'a')));
const g2 = { a: 2, get a() { return 1; } };
console.log(g2.a, typeof Object.getOwnPropertyDescriptor(g2, 'a').get);
const g3 = { get a() { return 1; }, set a(v) { this.seen = v; }, b: 2 };
g3.a = 5;
console.log(g3.a, g3.seen, J(Object.keys(g3)));

// `__proto__` written plainly sets the prototype and defines nothing
const p = { __proto__: { inh: 7 }, own: 1 };
console.log(p.inh, J(p), J(Object.keys(p)), Object.getPrototypeOf(p).inh);
// every other spelling of it is an ordinary property
const p2 = { ['__proto__']: 1, a: 2 };
console.log(p2.__proto__, J(Object.keys(p2)));
const p3 = { __proto__() { return 3; } };
console.log(typeof p3.__proto__, J(Object.keys(p3)));

// a method is a plain key, and a later plain key replaces it
const m = { m() { return 4; }, m: 5 };
console.log(m.m, J(Object.keys(m)));

// the attributes a literal's key gets
const d = { x: 1, y: 2 };
console.log(J(Object.getOwnPropertyDescriptor(d, 'x')), Object.isExtensible(d));

// the values are evaluated in source order, repeated key and all
let n = 0;
const ord = { a: (n++, 'A'), b: (n++, 'B'), a: (n++, 'C') };
console.log(J(ord), n, J(Object.keys(ord)));

// past the size at which a property table takes a key index
const big = {
  k0: 0, k1: 1, k2: 2, k3: 3, k4: 4, k5: 5, k6: 6, k7: 7, k8: 8, k9: 9,
  k10: 10, k11: 11, k12: 12, k13: 13, k14: 14, k15: 15, k16: 16, k17: 17,
  k7: 70,
};
console.log(Object.keys(big).length, big.k7, big.k17, J(big).length);

// symbols are keys too, and not among the string ones
const sym = Symbol('s');
const sy = { [sym]: 1, a: 2 };
console.log(sy[sym], sy.a, J(Object.keys(sy)));

// nesting, and a literal built from another
console.log(J({ a: { b: { c: 1 } }, d: [{ e: 2 }] }));
console.log(J({ ...{ ...src }, y: 1 }));
console.log(J(Object.entries({ q: 1, r: 2 })), J({}), J(Object.keys({})));

// shorthand, and the name an anonymous value takes from its key
const a = 1, z = 2;
console.log(J({ a, z }), ({ f: function () {} }).f.name, ({ g: () => {} }).g.name);

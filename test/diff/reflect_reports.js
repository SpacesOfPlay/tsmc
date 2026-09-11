// The Reflect entries answer with the outcome of the internal method: a
// property the object refuses to write, define or delete is `false`, not a
// thrown error. Only code running inside the operation — a setter, a proxy
// trap — still throws. Object.* keeps throwing, which is its job.

const T = (l, f) => {
  try { console.log(l, '->', String(f())); }
  catch (e) { console.log(l, 'threw', e.constructor.name); }
};

const readOnly = () => { const o = {}; Object.defineProperty(o, 'p', { value: 1 }); return o; };

// --- Reflect.set -----------------------------------------------------------
T('a frozen object', () => Reflect.set(Object.freeze({ a: 1 }), 'a', 2));
T('a read-only property', () => Reflect.set(readOnly(), 'p', 2));
T('a new name on a non-extensible object', () => Reflect.set(Object.preventExtensions({}), 'n', 1));
T('a getter with no setter', () => Reflect.set({ get g() { return 1; } }, 'g', 2));
T('an inherited read-only', () => Reflect.set(Object.create(readOnly()), 'p', 2));
T('a frozen array element', () => Reflect.set(Object.freeze([1]), 0, 2));
T('a sealed array past the end', () => Reflect.set(Object.seal([1]), 1, 2));
T('and the write that works', () => { const o = {}; return [Reflect.set(o, 'a', 1), o.a].join(','); });
T('the value is left alone', () => { const o = readOnly(); Reflect.set(o, 'p', 2); return o.p; });
T('a setter still runs', () => { let seen; const o = { set s(v) { seen = v; } }; return [Reflect.set(o, 's', 5), seen].join(','); });
T('a setter that throws still throws', () => Reflect.set({ set s(v) { throw new RangeError('no'); } }, 's', 1));

// --- Reflect.defineProperty ------------------------------------------------
T('define on a frozen object', () => Reflect.defineProperty(Object.freeze({}), 'x', { value: 1 }));
T('redefine a non-configurable one', () => Reflect.defineProperty(readOnly(), 'p', { value: 2, configurable: true }));
T('define on a non-extensible object', () => Reflect.defineProperty(Object.preventExtensions({}), 'x', { value: 1 }));
T('and the definition that works', () => { const o = {}; return [Reflect.defineProperty(o, 'x', { value: 1 }), o.x].join(','); });
T('a descriptor that is not an object still throws', () => Reflect.defineProperty({}, 'x', 1));

// --- Reflect.deleteProperty ------------------------------------------------
T('delete a non-configurable property', () => Reflect.deleteProperty(readOnly(), 'p'));
T('delete from a frozen object', () => Reflect.deleteProperty(Object.freeze({ a: 1 }), 'a'));
T('delete a name it does not have', () => Reflect.deleteProperty({}, 'nope'));
T('and the delete that works', () => { const o = { a: 1 }; return [Reflect.deleteProperty(o, 'a'), 'a' in o].join(','); });
T('the property survives a refusal', () => { const o = readOnly(); Reflect.deleteProperty(o, 'p'); return o.p; });

// --- Reflect.setPrototypeOf ------------------------------------------------
T('a prototype change a non-extensible object refuses', () => Reflect.setPrototypeOf(Object.preventExtensions({}), {}));
T('the prototype it already has', () => Reflect.setPrototypeOf(Object.preventExtensions({}), Object.prototype));
T('and the change that works', () => { const o = {}; const p = {}; return [Reflect.setPrototypeOf(o, p), Object.getPrototypeOf(o) === p].join(','); });

// --- Object.* still throws -------------------------------------------------
T('Object.defineProperty on a frozen object', () => { Object.defineProperty(Object.freeze({}), 'x', { value: 1 }); return 'defined'; });
T('Object.setPrototypeOf on a non-extensible one', () => { Object.setPrototypeOf(Object.preventExtensions({}), {}); return 'ok'; });
T('Object.defineProperty hands the object back', () => { const o = {}; return Object.defineProperty(o, 'x', { value: 1 }) === o; });
T('Object.setPrototypeOf hands it back', () => { const o = {}; return Object.setPrototypeOf(o, null) === o; });
T('a strict assignment still throws', () => { 'use strict'; const o = readOnly(); o.p = 2; return 'wrote'; });
T('a sloppy one is still dropped', () => { const o = readOnly(); o.p = 2; return o.p; });

// --- through a proxy -------------------------------------------------------
T('a defineProperty trap that says no', () => Reflect.defineProperty(new Proxy({}, { defineProperty: () => false }), 'x', { value: 1 }));
T('a set trap that says no', () => Reflect.set(new Proxy({}, { set: () => false }), 'x', 1));
T('a trap that throws', () => Reflect.set(new Proxy({}, { set() { throw new RangeError('no'); } }), 'x', 1));
T('no trap falls through to the target', () => { const t = {}; return [Reflect.set(new Proxy(t, {}), 'x', 1), t.x].join(','); });

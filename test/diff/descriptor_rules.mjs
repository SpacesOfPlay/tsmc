// Property descriptors and object integrity: defineProperty's defaults and its
// redefinition rules, the non-writable / non-configurable refusals, freeze,
// seal and preventExtensions, and how enumerability shows through.
//
// .mjs on purpose: tsmc runs strict, so every operation a descriptor or an
// integrity level forbids is a TypeError. As CommonJS node would silently
// ignore most of these and roughly a third of the file would differ on mode
// alone.

const rows = [];
function T(label, fn) {
  let v;
  try { v = fn(); }
  catch (e) { v = 'THROW:' + (e && e.constructor ? e.constructor.name : String(e)); }
  try { v = JSON.stringify(v); } catch (e) { v = String(v); }
  rows.push(label + ' = ' + v);
}
const D = (o, k) => JSON.stringify(Object.getOwnPropertyDescriptor(o, k));

// --- defineProperty defaults and shape ---
T('define-defaults', () => { const o = {}; Object.defineProperty(o, 'x', { value: 1 }); return D(o, 'x'); });
T('define-explicit', () => { const o = {}; Object.defineProperty(o, 'x', { value: 1, writable: true, enumerable: true, configurable: true }); return D(o, 'x'); });
T('define-accessor', () => { const o = {}; Object.defineProperty(o, 'x', { get() { return 5; } }); const d = Object.getOwnPropertyDescriptor(o, 'x'); return [typeof d.get, d.set, d.enumerable, d.configurable, o.x]; });
T('define-returns-object', () => { const o = {}; return Object.defineProperty(o, 'x', { value: 1 }) === o; });
T('define-literal-defaults', () => { const o = { x: 1 }; return D(o, 'x'); });
T('define-both-value-and-get', () => { const o = {}; Object.defineProperty(o, 'x', { value: 1, get() { return 2; } }); });
T('define-on-nonobject', () => Object.defineProperty(5, 'x', { value: 1 }));
T('define-symbol-key', () => { const s = Symbol('k'); const o = {}; Object.defineProperty(o, s, { value: 7 }); return o[s]; });

// --- non-writable ---
T('nonwritable-assign-throws', () => { const o = {}; Object.defineProperty(o, 'x', { value: 1, configurable: true }); o.x = 2; return o.x; });
T('nonwritable-define-again', () => { const o = {}; Object.defineProperty(o, 'x', { value: 1, configurable: true }); Object.defineProperty(o, 'x', { value: 2 }); return o.x; });
T('nonwritable-nonconfig-redefine', () => { const o = {}; Object.defineProperty(o, 'x', { value: 1 }); Object.defineProperty(o, 'x', { value: 2 }); });
T('nonwritable-same-value-ok', () => { const o = {}; Object.defineProperty(o, 'x', { value: 1 }); Object.defineProperty(o, 'x', { value: 1 }); return o.x; });
T('nonwritable-on-proto-blocks', () => { const proto = {}; Object.defineProperty(proto, 'x', { value: 1 }); const o = Object.create(proto); o.x = 2; return o.x; });
T('writable-false-then-true', () => { const o = {}; Object.defineProperty(o, 'x', { value: 1, writable: false, configurable: true }); Object.defineProperty(o, 'x', { writable: true }); o.x = 3; return o.x; });

// --- non-configurable ---
T('nonconfig-delete', () => { const o = {}; Object.defineProperty(o, 'x', { value: 1 }); delete o.x; return 'x' in o; });
T('nonconfig-change-enumerable', () => { const o = {}; Object.defineProperty(o, 'x', { value: 1 }); Object.defineProperty(o, 'x', { enumerable: true }); });
T('nonconfig-data-to-accessor', () => { const o = {}; Object.defineProperty(o, 'x', { value: 1 }); Object.defineProperty(o, 'x', { get() { return 2; } }); });
T('config-delete-ok', () => { const o = {}; Object.defineProperty(o, 'x', { value: 1, configurable: true }); delete o.x; return 'x' in o; });

// --- accessors ---
T('getter-only-assign-throws', () => { const o = { get x() { return 1; } }; o.x = 2; return o.x; });
T('setter-only-read', () => { const o = { set x(v) {} }; return o.x; });
T('accessor-descriptor-shape', () => { const o = { get x() { return 1; }, set x(v) {} }; const d = Object.getOwnPropertyDescriptor(o, 'x'); return [typeof d.get, typeof d.set, d.enumerable, d.configurable, 'value' in d, 'writable' in d]; });
T('accessor-this', () => { const o = { v: 3, get x() { return this.v; } }; return o.x; });

// --- defineProperties and create ---
T('defineProperties', () => { const o = Object.defineProperties({}, { a: { value: 1, enumerable: true }, b: { value: 2 } }); return [o.a, o.b, Object.keys(o)]; });
T('create-with-descriptors', () => { const o = Object.create(null, { a: { value: 1, enumerable: true } }); return [o.a, Object.keys(o)]; });
T('create-proto-and-descriptors', () => { const proto = { p: 1 }; const o = Object.create(proto, { a: { value: 2, enumerable: true } }); return [o.p, o.a]; });
T('create-null-proto', () => { const o = Object.create(null); o.x = 1; return [Object.getPrototypeOf(o), o.x]; });
T('descriptors-roundtrip', () => { const src = { a: 1, get b() { return 2; } }; const copy = Object.create(Object.getPrototypeOf(src), Object.getOwnPropertyDescriptors(src)); return [copy.a, copy.b]; });
T('getOwnPropertyDescriptors-keys', () => Object.keys(Object.getOwnPropertyDescriptors({ a: 1, b: 2 })));

// --- freeze ---
T('freeze-blocks-write', () => { const o = Object.freeze({ a: 1 }); o.a = 2; return o.a; });
T('freeze-blocks-add', () => { const o = Object.freeze({}); o.b = 1; return 'b' in o; });
T('freeze-blocks-delete', () => { const o = Object.freeze({ a: 1 }); delete o.a; return o.a; });
T('freeze-is-frozen', () => [Object.isFrozen(Object.freeze({})), Object.isFrozen({}), Object.isFrozen(Object.freeze({ a: 1 }))]);
T('freeze-descriptor', () => { const o = Object.freeze({ a: 1 }); return D(o, 'a'); });
T('freeze-shallow', () => { const o = Object.freeze({ inner: { a: 1 } }); o.inner.a = 2; return o.inner.a; });
T('freeze-primitive', () => [Object.isFrozen(5), Object.freeze(5)]);
T('freeze-empty-is-frozen', () => Object.isFrozen(Object.preventExtensions({})));
T('freeze-accessor-still-runs', () => { let n = 0; const o = Object.freeze({ get a() { n++; return 1; } }); o.a; o.a; return n; });
T('freeze-array-write', () => { const a = Object.freeze([1, 2]); a[0] = 9; return a[0]; });
T('freeze-array-push', () => { const a = Object.freeze([1]); a.push(2); });
T('freeze-returns-same', () => { const o = {}; return Object.freeze(o) === o; });

// --- seal ---
T('seal-blocks-add', () => { const o = Object.seal({ a: 1 }); o.b = 2; return 'b' in o; });
T('seal-allows-write', () => { const o = Object.seal({ a: 1 }); o.a = 2; return o.a; });
T('seal-blocks-delete', () => { const o = Object.seal({ a: 1 }); delete o.a; return o.a; });
T('seal-is-sealed', () => [Object.isSealed(Object.seal({})), Object.isSealed({}), Object.isSealed(Object.freeze({}))]);
T('seal-descriptor', () => { const o = Object.seal({ a: 1 }); return D(o, 'a'); });

// --- preventExtensions ---
T('prevent-blocks-add', () => { const o = Object.preventExtensions({ a: 1 }); o.b = 2; return 'b' in o; });
T('prevent-allows-write', () => { const o = Object.preventExtensions({ a: 1 }); o.a = 2; return o.a; });
T('prevent-allows-delete', () => { const o = Object.preventExtensions({ a: 1 }); delete o.a; return 'a' in o; });
T('prevent-is-extensible', () => [Object.isExtensible({}), Object.isExtensible(Object.preventExtensions({}))]);
T('prevent-define-throws', () => { const o = Object.preventExtensions({}); Object.defineProperty(o, 'x', { value: 1 }); });
T('prevent-setproto-throws', () => { const o = Object.preventExtensions({}); Object.setPrototypeOf(o, { a: 1 }); });

// --- enumerability effects ---
T('nonenum-not-in-keys', () => { const o = { a: 1 }; Object.defineProperty(o, 'h', { value: 2 }); return [Object.keys(o), Object.getOwnPropertyNames(o)]; });
T('nonenum-not-in-json', () => { const o = { a: 1 }; Object.defineProperty(o, 'h', { value: 2 }); return JSON.stringify(o); });
T('nonenum-not-in-forin', () => { const o = {}; Object.defineProperty(o, 'h', { value: 2 }); const r = []; for (const k in o) r.push(k); return r; });
T('nonenum-not-spread', () => { const o = {}; Object.defineProperty(o, 'h', { value: 2, enumerable: false }); return Object.keys({ ...o }); });
T('nonenum-still-readable', () => { const o = {}; Object.defineProperty(o, 'h', { value: 2 }); return [o.h, 'h' in o, Object.hasOwn(o, 'h')]; });

// --- builtin descriptors ---
T('array-length-descriptor', () => D([1, 2], 'length'));
T('function-name-descriptor', () => { function f() {} return D(f, 'name'); });
T('function-length-descriptor', () => { function f(a, b) {} return D(f, 'length'); });
T('proto-method-descriptor', () => { class C { m() {} } return D(C.prototype, 'm'); });
T('class-field-descriptor', () => { class C { x = 1; } return D(new C(), 'x'); });

console.log(rows.join('\n'));

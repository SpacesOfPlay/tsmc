// Own property order: array-index keys ascending first, then other string
// keys in insertion order, then symbols — across every enumeration path.
// Also array `length` semantics and what `delete` leaves behind.

const rows = [];
function T(label, fn) {
  let v;
  try { v = fn(); }
  catch (e) { v = 'THROW:' + (e && e.constructor ? e.constructor.name : String(e)); }
  try { v = JSON.stringify(v); } catch (e) { v = String(v); }
  rows.push(label + ' = ' + v);
}

// Which keys count as array indices.
T('order-int-before-string', () => Object.keys({ b: 1, 2: 2, a: 3, 1: 4 }));
T('order-int-ascending', () => Object.keys({ 10: 1, 2: 2, 1: 3 }));
T('order-string-insertion', () => Object.keys({ z: 1, a: 2, m: 3 }));
T('order-negative-not-index', () => Object.keys({ '-1': 1, 0: 2 }));
T('order-float-not-index', () => Object.keys({ '1.5': 1, 1: 2 }));
T('order-leading-zero-not-index', () => Object.keys({ '01': 1, 1: 2 }));
T('order-plus-not-index', () => Object.keys({ '+1': 1, 1: 2 }));
T('order-empty-key', () => Object.keys({ '': 1, 0: 2 }));
T('order-space-key', () => Object.keys({ ' 1': 1, 1: 2 }));
T('order-zero-included', () => Object.keys({ b: 1, 0: 2 }));
// 2^32-1 is not an index; 2^32-2 is the largest one.
T('order-big-index', () => Object.keys({ 4294967295: 1, 4294967294: 2, 1: 3 }));
T('order-exp-notation-not-index', () => Object.keys({ '1e2': 1, 100: 2 }));

// Every enumeration path agrees.
T('order-json-stringify', () => JSON.stringify({ b: 1, 2: 2, a: 3, 1: 4 }));
T('order-for-in', () => { const o = { b: 1, 2: 2, a: 3, 1: 4 }; const r = []; for (const k in o) r.push(k); return r; });
T('order-entries', () => Object.entries({ b: 1, 1: 2 }).map((e) => e[0]));
T('order-values', () => Object.values({ b: 'x', 1: 'y' }));
T('order-assign-preserves', () => Object.keys(Object.assign({}, { b: 1, 1: 2, a: 3 })));
T('order-spread-preserves', () => Object.keys({ ...{ b: 1, 1: 2, a: 3 } }));
T('order-rest-preserves', () => { const { z, ...r } = { z: 0, b: 1, 1: 2, a: 3 }; return Object.keys(r); });
T('order-getOwnPropertyNames', () => Object.getOwnPropertyNames({ b: 1, 2: 2, a: 3 }));
T('order-ownKeys', () => Reflect.ownKeys({ b: 1, 2: 2, a: 3 }));
T('order-symbols-last', () => { const s = Symbol('s'); const ks = Reflect.ownKeys({ b: 1, [s]: 2, 1: 3 }); return [ks[0], ks[1], typeof ks[2]]; });

// Order is stable under mutation.
T('order-after-delete-readd', () => { const o = { a: 1, b: 2 }; delete o.a; o.a = 3; return Object.keys(o); });
T('order-index-added-later', () => { const o = { b: 1 }; o[0] = 2; return Object.keys(o); });
T('order-index-deleted', () => { const o = { 1: 1, 0: 2, b: 3 }; delete o[0]; return Object.keys(o); });
T('order-repeated-enumeration', () => { const o = { b: 1, 1: 2 }; Object.keys(o); return Object.keys(o); });
T('order-many-indices', () => { const o = {}; for (let i = 9; i >= 0; i--) o[i] = i; return Object.keys(o).join(''); });
T('order-defineProperty', () => { const o = { b: 1 }; Object.defineProperty(o, '0', { value: 2, enumerable: true, configurable: true, writable: true }); return Object.keys(o); });

// Arrays and class prototypes.
T('order-array-keys', () => Object.keys([1, 2, 3]));
T('order-array-extra-prop', () => { const a = [1]; a.x = 2; return Object.keys(a); });
T('order-class-proto-methods', () => { class C { m() {} n() {} } return Object.getOwnPropertyNames(C.prototype); });
T('order-inherited-for-in', () => { const p = { pa: 1 }; const o = Object.create(p); o.own = 2; const r = []; for (const k in o) r.push(k); return r; });
T('order-nested-json', () => JSON.stringify({ outer: { b: 1, 1: 2 }, 3: 'x', a: 'y' }));

// Array length.
T('len-truncate', () => { const a = [1, 2, 3]; a.length = 1; return a; });
T('len-truncate-releases', () => { const a = [1, 2, 3]; a.length = 1; return [a.length, 1 in a, a[1]]; });
T('len-grow-holes', () => { const a = [1]; a.length = 3; return [a.length, 1 in a, JSON.stringify(a)]; });
T('len-zero', () => { const a = [1, 2]; a.length = 0; return [a.length, JSON.stringify(a)]; });
T('len-same', () => { const a = [1, 2]; a.length = 2; return a; });
T('len-set-string', () => { const a = [1, 2, 3]; a.length = '1'; return a; });
T('len-invalid-throws', () => { const a = [1]; a.length = -1; });
T('len-fractional-throws', () => { const a = [1]; a.length = 1.5; });
T('len-nan-throws', () => { const a = [1]; a.length = NaN; });
T('len-grow-by-index', () => { const a = []; a[4] = 1; return [a.length, JSON.stringify(a)]; });
T('len-index-past-end', () => { const a = [1]; a[3] = 2; return [a.length, 1 in a, 3 in a]; });
T('len-string-index-not-counted', () => { const a = [1]; a['x'] = 2; return a.length; });
T('len-numeric-string-index', () => { const a = [1]; a['1'] = 2; return [a.length, a[1]]; });
T('len-descriptor', () => JSON.stringify(Object.getOwnPropertyDescriptor([1, 2], 'length')));
T('len-not-enumerable', () => Object.keys([1, 2]).indexOf('length'));
T('len-after-push', () => { const a = []; a.push(1, 2); return a.length; });
T('len-after-pop-empty', () => { const a = []; return [a.pop(), a.length]; });

// delete on an array leaves a hole, not undefined.
T('del-leaves-hole', () => { const a = [1, 2, 3]; delete a[1]; return [a.length, 1 in a]; });
T('del-reads-undefined', () => { const a = [1, 2, 3]; delete a[1]; return a[1]; });
T('del-json-null', () => { const a = [1, 2, 3]; delete a[1]; return JSON.stringify(a); });
T('del-join-empty', () => { const a = [1, 2, 3]; delete a[1]; return a.join('-'); });
T('del-forEach-skips', () => { const a = [1, 2, 3]; delete a[1]; let n = 0; a.forEach(() => n++); return n; });
T('del-map-preserves-hole', () => { const a = [1, 2, 3]; delete a[1]; const m = a.map((x) => x * 2); return [1 in m, JSON.stringify(m)]; });
T('del-keys-skips', () => { const a = [1, 2, 3]; delete a[1]; return Object.keys(a); });
T('del-spread-fills-undefined', () => { const a = [1, 2, 3]; delete a[1]; return JSON.stringify([...a]); });
T('del-filter-skips', () => { const a = [1, 2, 3]; delete a[1]; return a.filter(() => true).length; });
T('del-indexOf-skips', () => { const a = [1, 2, 3]; delete a[1]; return a.indexOf(undefined); });
T('del-includes-finds', () => { const a = [1, 2, 3]; delete a[1]; return a.includes(undefined); });
T('del-last-element', () => { const a = [1, 2]; delete a[1]; return [a.length, JSON.stringify(a)]; });
T('del-returns-true', () => { const a = [1]; return delete a[0]; });
T('del-out-of-range', () => { const a = [1]; return delete a[5]; });

// Sparse arrays built by length.
T('len-sparse-join', () => { const a = [1]; a.length = 3; return a.join('-'); });
T('len-sparse-map-skips', () => { const a = [1]; a.length = 3; let n = 0; a.map(() => n++); return n; });
T('len-sparse-forEach-skips', () => { const a = [1]; a.length = 3; let n = 0; a.forEach(() => n++); return n; });
T('len-sparse-spread-fills', () => { const a = [1]; a.length = 3; return JSON.stringify([...a]); });

console.log(rows.join('\n'));

// Not asserted: array `length` is not modelled as a real property with a
// writable attribute, so `Object.freeze(a); a.length = 1` still truncates and
// `Object.defineProperty(a, 'length', { writable: false })` does not make a
// later push throw.

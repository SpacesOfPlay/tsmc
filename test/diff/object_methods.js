// Dense coverage of the Object statics, property descriptors, and the
// integrity levels.

const rows = [];
function T(label, fn) {
  let v;
  try { v = fn(); }
  catch (e) { v = 'THROW:' + (e && e.constructor ? e.constructor.name : String(e)); }
  try { v = JSON.stringify(v); } catch (e) { v = String(v); }
  rows.push(label + ' = ' + v);
}

const o = { a: 1, b: 2 };

T('keys', () => Object.keys(o));
T('values', () => Object.values(o));
T('entries', () => Object.entries(o));
T('assign', () => Object.assign({}, o, { c: 3 }));
T('assign-overwrite', () => Object.assign({ a: 9 }, { a: 1 }));
T('assign-returns-target', () => { const t = {}; return Object.assign(t, { a: 1 }) === t; });
T('freeze', () => { const f = Object.freeze({ x: 1 }); try { f.x = 2; } catch (e) { } return [f.x, Object.isFrozen(f)]; });
T('freeze-add', () => { const f = Object.freeze({}); try { f.n = 1; } catch (e) { } return Object.keys(f).length; });
T('seal', () => { const s = Object.seal({ x: 1 }); s.x = 2; return [s.x, Object.isSealed(s)]; });
T('seal-add', () => { const s = Object.seal({}); s.n = 1; return Object.keys(s).length; });
T('preventExtensions', () => { const p = {}; Object.preventExtensions(p); p.n = 1; return [Object.isExtensible(p), p.n]; });
T('create', () => Object.create({ z: 9 }).z);
T('create-null', () => Object.getPrototypeOf(Object.create(null)));
T('defineProperty-default', () => { const d = {}; Object.defineProperty(d, 'x', { value: 1 }); return [d.x, Object.keys(d).length]; });
T('defineProperty-enumerable', () => { const d = {}; Object.defineProperty(d, 'x', { value: 1, enumerable: true }); return Object.keys(d); });
T('defineProperty-accessor', () => { const d = {}; Object.defineProperty(d, 'x', { get() { return 5; } }); return d.x; });
T('defineProperties', () => { const d = {}; Object.defineProperties(d, { a: { value: 1, enumerable: true }, b: { value: 2 } }); return [d.a, d.b, Object.keys(d)]; });
T('getOwnPropertyNames', () => Object.getOwnPropertyNames({ a: 1 }));
T('getOwnPropertyNames-nonenum', () => { const d = {}; Object.defineProperty(d, 'h', { value: 1 }); return Object.getOwnPropertyNames(d); });
T('getOwnPropertyDescriptor', () => Object.getOwnPropertyDescriptor({ a: 1 }, 'a'));
T('getOwnPropertyDescriptor-missing', () => Object.getOwnPropertyDescriptor({}, 'zz'));
T('getOwnPropertyDescriptors', () => Object.keys(Object.getOwnPropertyDescriptors({ a: 1, b: 2 })));
T('accessor-descriptor', () => { const d = Object.getOwnPropertyDescriptor({ get v() { return 1; } }, 'v'); return [typeof d.get, d.set === undefined, d.enumerable, d.configurable]; });
T('getPrototypeOf', () => [Object.getPrototypeOf([]) === Array.prototype, Object.getPrototypeOf({}) === Object.prototype]);
T('setPrototypeOf', () => { const s = {}; Object.setPrototypeOf(s, { q: 1 }); return s.q; });
T('fromEntries', () => Object.fromEntries([['a', 1], ['b', 2]]));
T('fromEntries-map', () => Object.fromEntries(new Map([['a', 1]])));
T('is', () => [Object.is(NaN, NaN), Object.is(0, -0), Object.is(1, 1)]);
T('hasOwn', () => [Object.hasOwn({ a: 1 }, 'a'), Object.hasOwn({}, 'a')]);
T('hasOwnProperty-inherited', () => { const c = Object.create({ p: 1 }); return [c.p, c.hasOwnProperty('p')]; });
T('propertyIsEnumerable', () => ({ a: 1 }).propertyIsEnumerable('a'));
T('spread', () => ({ ...o, c: 3 }));
T('spread-overwrite', () => ({ a: 9, ...{ a: 1 } }));
T('getter-enumerable', () => { const g = { get v() { return 1; } }; return [Object.keys(g), g.v]; });
T('symbol-key', () => { const s = Symbol('k'); const x = { [s]: 1 }; return [x[s], Object.getOwnPropertySymbols(x).length, Object.keys(x).length]; });
T('delete', () => { const d = { a: 1 }; const r = delete d.a; return [r, Object.keys(d).length]; });
T('delete-missing', () => delete ({}).zz);
T('in-operator', () => { const c = Object.create({ p: 1 }); return ['p' in c, 'zz' in c]; });
T('for-in-inherited', () => { const c = Object.create({ p: 1 }); c.own = 2; const k = []; for (const x in c) k.push(x); return k.sort(); });
T('json-round-trip', () => JSON.parse(JSON.stringify({ a: [1, { b: 2 }] })));
T('constructor-property', () => ({}).constructor === Object);
T('valueOf', () => typeof ({}).valueOf());
T('toString', () => ({}).toString());
T('keys-of-string', () => Object.keys('ab'));
T('values-of-array', () => Object.values([1, 2]));
T('assign-getter-invoked', () => { let n = 0; const src = { get v() { n++; return 1; } }; const t = Object.assign({}, src); return [t.v, n]; });

console.log(rows.join('\n'));

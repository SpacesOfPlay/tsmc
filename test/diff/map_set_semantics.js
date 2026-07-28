// Map, Set, WeakMap and WeakSet: the mutators and their return values, key
// identity under SameValueZero, insertion order, the iterators (which are live
// views, not snapshots) and what the weak collections refuse.

const rows = [];
function T(label, fn) {
  let v;
  try { v = fn(); }
  catch (e) { v = 'THROW:' + (e && e.constructor ? e.constructor.name : String(e)); }
  try { v = JSON.stringify(v); } catch (e) { v = String(v); }
  rows.push(label + ' = ' + v);
}

// --- Map basics ---
T('map-set-get', () => { const m = new Map(); m.set('a', 1); return [m.get('a'), m.size]; });
T('map-get-missing', () => new Map().get('nope'));
T('map-has', () => { const m = new Map([['a', 1]]); return [m.has('a'), m.has('b')]; });
T('map-delete', () => { const m = new Map([['a', 1]]); return [m.delete('a'), m.delete('a'), m.size]; });
T('map-clear', () => { const m = new Map([['a', 1], ['b', 2]]); m.clear(); return m.size; });
T('map-set-chains', () => { const m = new Map(); return m.set('a', 1) === m; });
T('map-overwrite', () => { const m = new Map(); m.set('a', 1); m.set('a', 2); return [m.get('a'), m.size]; });
T('map-from-iterable', () => { const m = new Map([['a', 1], ['b', 2]]); return [m.size, m.get('b')]; });
T('map-from-map', () => { const m = new Map(new Map([['a', 1]])); return m.get('a'); });
T('map-from-null', () => new Map(null).size);
T('map-from-noniterable', () => new Map(5));
T('map-from-bad-entry', () => new Map([1, 2]));
T('map-without-new', () => Map());
T('map-size-not-writable', () => { const m = new Map(); try { m.size = 5; } catch (e) { return 'THROW:' + e.constructor.name; } return m.size; });

// --- key identity (SameValueZero) ---
T('map-nan-key', () => { const m = new Map(); m.set(NaN, 'n'); return [m.get(NaN), m.has(NaN), m.size]; });
T('map-zero-keys', () => { const m = new Map(); m.set(0, 'p'); m.set(-0, 'n'); return [m.size, m.get(0), m.get(-0)]; });
T('map-zero-key-normalised', () => { const m = new Map(); m.set(-0, 'x'); return Object.is([...m.keys()][0], 0); });
T('map-object-identity', () => { const a = {}, b = {}; const m = new Map(); m.set(a, 1); return [m.get(a), m.get(b), m.has(b)]; });
T('map-string-vs-number', () => { const m = new Map(); m.set(1, 'n'); m.set('1', 's'); return [m.size, m.get(1), m.get('1')]; });
T('map-bool-keys', () => { const m = new Map(); m.set(true, 't'); return [m.get(true), m.get(1)]; });
T('map-undefined-null-keys', () => { const m = new Map(); m.set(undefined, 'u'); m.set(null, 'n'); return [m.size, m.get(undefined), m.get(null)]; });
T('map-symbol-key', () => { const s = Symbol('k'); const m = new Map(); m.set(s, 1); return [m.get(s), m.get(Symbol('k'))]; });

// --- Map iteration ---
T('map-iteration-order', () => [...new Map([['b', 1], ['a', 2], ['c', 3]]).keys()]);
T('map-order-after-delete-readd', () => { const m = new Map([['a', 1], ['b', 2]]); m.delete('a'); m.set('a', 3); return [...m.keys()]; });
T('map-order-overwrite-keeps-place', () => { const m = new Map([['a', 1], ['b', 2]]); m.set('a', 9); return [...m.keys()]; });
T('map-entries', () => [...new Map([['a', 1]]).entries()]);
T('map-values', () => [...new Map([['a', 1], ['b', 2]]).values()]);
T('map-spread', () => [...new Map([['a', 1]])]);
T('map-foreach-args', () => { const out = []; new Map([['a', 1]]).forEach((v, k, m) => out.push([v, k, m instanceof Map])); return out; });
T('map-foreach-thisarg', () => { const out = []; new Map([['a', 1]]).forEach(function () { out.push(this.tag); }, { tag: 't' }); return out; });
T('map-array-from', () => Array.from(new Map([['a', 1]])));
T('map-fromEntries', () => Object.fromEntries(new Map([['a', 1], ['b', 2]])));
T('map-delete-during-iteration', () => { const m = new Map([['a', 1], ['b', 2], ['c', 3]]); const seen = []; for (const [k] of m) { seen.push(k); if (k === 'a') m.delete('b'); } return seen; });
T('map-add-during-iteration', () => { const m = new Map([['a', 1]]); const seen = []; for (const [k] of m) { seen.push(k); if (seen.length < 3 && k === 'a') m.set('b', 2); } return seen; });
T('map-iterator-is-iterable', () => { const it = new Map([['a', 1]]).keys(); return it[Symbol.iterator]() === it; });

// --- Set ---
T('set-add-has', () => { const s = new Set(); s.add(1); return [s.has(1), s.size]; });
T('set-dedup', () => new Set([1, 1, 2]).size);
T('set-add-chains', () => { const s = new Set(); return s.add(1) === s; });
T('set-delete', () => { const s = new Set([1]); return [s.delete(1), s.delete(1), s.size]; });
T('set-clear', () => { const s = new Set([1, 2]); s.clear(); return s.size; });
T('set-nan', () => { const s = new Set(); s.add(NaN); s.add(NaN); return [s.size, s.has(NaN)]; });
T('set-zeros', () => { const s = new Set(); s.add(0); s.add(-0); return [s.size, Object.is([...s][0], 0)]; });
T('set-object-identity', () => new Set([{}, {}]).size);
T('set-from-string', () => [...new Set('aab')]);
T('set-iteration-order', () => [...new Set(['b', 'a', 'c'])]);
T('set-entries', () => [...new Set([1]).entries()]);
T('set-keys-is-values', () => { const s = new Set([1]); return [[...s.keys()], [...s.values()]]; });
T('set-foreach-args', () => { const out = []; new Set([1]).forEach((v, k, s) => out.push([v, k, s instanceof Set])); return out; });
T('set-spread', () => [...new Set([1, 2])]);
T('set-json', () => JSON.stringify(new Set([1])));

// --- WeakMap / WeakSet ---
T('weakmap-basic', () => { const k = {}; const w = new WeakMap(); w.set(k, 1); return [w.get(k), w.has(k), w.delete(k), w.has(k)]; });
T('weakmap-primitive-key', () => new WeakMap().set(1, 'x'));
T('weakmap-string-key', () => new WeakMap().set('a', 'x'));
T('weakmap-no-size', () => new WeakMap().size);
T('weakmap-not-iterable', () => [...new WeakMap()]);
T('weakmap-from-iterable', () => { const k = {}; return new WeakMap([[k, 1]]).get(k); });
T('weakmap-get-missing', () => new WeakMap().get({}));
T('weakset-basic', () => { const o = {}; const w = new WeakSet(); w.add(o); return [w.has(o), w.delete(o), w.has(o)]; });
T('weakset-primitive', () => new WeakSet().add(1));
T('weakmap-symbol-key', () => { const s = Symbol('k'); try { const w = new WeakMap(); w.set(s, 1); return w.get(s); } catch (e) { return 'THROW:' + e.constructor.name; } });

// --- prototypes and tags ---
T('map-proto-methods', () => ['get', 'set', 'has', 'delete', 'clear', 'forEach'].every((m) => typeof Map.prototype[m] === 'function'));
T('map-size-is-accessor', () => { const d = Object.getOwnPropertyDescriptor(Map.prototype, 'size'); return [typeof d.get, d.set]; });
T('map-instanceof', () => [new Map() instanceof Map, new Set() instanceof Set, new Map() instanceof Set]);
T('map-tostring', () => [String(new Map()), Object.prototype.toString.call(new Map())]);
T('set-subclass', () => { class S extends Set {} const s = new S([1]); return [s.size, s instanceof Set, s instanceof S]; });
T('map-keys-not-own-props', () => { const m = new Map([['a', 1]]); return [Object.keys(m), JSON.stringify(m)]; });

console.log(rows.join('\n'));

// What counts as the same key in a Map or a Set: SameValueZero, so 5 and 5.0
// meet, -0 is stored as +0, NaN finds NaN, a string matches by contents and a
// BigInt by its value, and everything else is identity. Insertion order
// survives deletion and reinsertion.

const T = (l, f) => { try { console.log(l, '->', JSON.stringify(f())); } catch (e) { console.log(l, 'threw', e.constructor.name); } };
T('bigint key', () => { const m = new Map(); m.set(1n, 'a'); return [m.get(1n), m.has(1n), m.size]; });
T('bigint in array', () => [1n, 2n].includes(2n));
T('number spellings', () => { const m = new Map(); m.set(5, 'a'); return [m.get(5.0), m.has(5)]; });
T('minus zero', () => { const m = new Map(); m.set(-0, 'a'); return [m.get(0), [...m.keys()][0]]; });
T('NaN key', () => { const m = new Map(); m.set(NaN, 'a'); return [m.get(NaN), m.size]; });
T('string key', () => { const m = new Map(); m.set('a' + 'b', 1); return m.get('ab'); });
T('object identity', () => { const k1 = {}, k2 = {}; const m = new Map([[k1, 1], [k2, 2]]); return [m.get(k1), m.get(k2), m.size]; });
T('delete then reinsert', () => { const m = new Map(); for (let i = 0; i < 20; i++) m.set('k' + i, i); for (let i = 0; i < 20; i += 2) m.delete('k' + i); for (let i = 0; i < 20; i += 2) m.set('k' + i, i * 10); return [m.size, m.get('k0'), m.get('k1'), [...m.keys()].length]; });
T('insertion order after churn', () => { const m = new Map(); for (let i = 0; i < 10; i++) m.set(i, i); m.delete(3); m.set(3, 33); return [...m.keys()].join(','); });
T('clear then use', () => { const m = new Map(); for (let i = 0; i < 20; i++) m.set('k' + i, i); m.clear(); m.set('k5', 99); return [m.size, m.get('k5'), m.get('k0')]; });
T('set ops', () => { const a = new Set([1,2,3,4]); const b = new Set([3,4,5]); return [[...a.union(b)].join(','), [...a.intersection(b)].join(','), [...a.difference(b)].join(',')]; });
T('symbol keys', () => { const s1 = Symbol('x'), s2 = Symbol('x'); const m = new Map([[s1,1],[s2,2]]); return [m.get(s1), m.get(s2), m.size]; });
T('weakmap', () => { const k = {}; const w = new WeakMap(); w.set(k, 5); return [w.get(k), w.has(k), w.has({})]; });

// Map, Set, the weak collections, and JSON in both directions.

const rows = [];
function T(label, fn) {
  let v;
  try { v = fn(); }
  catch (e) { v = 'THROW:' + (e && e.constructor ? e.constructor.name : String(e)); }
  try { v = JSON.stringify(v); } catch (e) { v = String(v); }
  rows.push(label + ' = ' + v);
}

T('map-basic', () => { const m = new Map([[1, 'a']]); m.set(2, 'b'); return [m.size, m.get(1), m.has(3), m.get(9)]; });
T('map-insertion-order', () => { const m = new Map(); m.set('b', 1); m.set('a', 2); m.set('b', 3); return [...m.keys()]; });
T('map-overwrite', () => { const m = new Map(); m.set('k', 1); m.set('k', 2); return [m.size, m.get('k')]; });
T('map-delete', () => { const m = new Map([[1, 1]]); return [m.delete(1), m.delete(1), m.size]; });
T('map-clear', () => { const m = new Map([[1, 1]]); m.clear(); return m.size; });
T('map-NaN-key', () => { const m = new Map(); m.set(NaN, 1); return m.get(NaN); });
T('map-object-key', () => { const k = {}; const m = new Map([[k, 1]]); return [m.get(k), m.get({})]; });
T('map-chaining', () => { const m = new Map(); return m.set(1, 'a').set(2, 'b').size; });
T('map-forEach', () => { const m = new Map([[1, 'a'], [2, 'b']]); const o = []; m.forEach((v, k) => o.push(k + v)); return o; });
T('map-iteration', () => { const m = new Map([[1, 'a']]); return [[...m.keys()], [...m.values()], [...m.entries()], [...m]]; });
T('map-from-map', () => { const a = new Map([[1, 'x']]); return [...new Map(a)]; });
T('map-size-readonly', () => { const m = new Map(); m.size = 99; return m.size; });

T('set-basic', () => { const s = new Set([1, 1, 2]); return [s.size, s.has(1), s.has(9)]; });
T('set-order', () => [...new Set(['b', 'a', 'b'])]);
T('set-add-delete', () => { const s = new Set(); s.add(1); return [s.size, s.delete(1), s.delete(1), s.size]; });
T('set-clear', () => { const s = new Set([1]); s.clear(); return s.size; });
T('set-chaining', () => new Set().add(1).add(2).size);
T('set-forEach', () => { const s = new Set([1, 2]); const o = []; s.forEach((v, k) => o.push(v === k)); return o; });
T('set-iteration', () => { const s = new Set([1]); return [[...s.keys()], [...s.values()], [...s.entries()]]; });
T('set-from-string', () => [...new Set('aab')]);
T('set-object-identity', () => { const s = new Set(); s.add({}); s.add({}); return s.size; });

T('weakmap', () => { const k = {}; const w = new WeakMap([[k, 1]]); return [w.get(k), w.has(k), w.has({})]; });
T('weakmap-delete', () => { const k = {}; const w = new WeakMap([[k, 1]]); return [w.delete(k), w.has(k)]; });
T('weakmap-primitive-key', () => new WeakMap().set(1, 'x'));
T('weakset', () => { const k = {}; const w = new WeakSet([k]); return [w.has(k), w.has({})]; });

T('json-stringify-basic', () => JSON.stringify({ b: 1, a: [1, null, undefined], c: undefined }));
T('json-stringify-nested', () => JSON.stringify([[1, [2]], { a: { b: 1 } }]));
T('json-indent', () => JSON.stringify({ a: 1, b: [2] }, null, 2));
T('json-indent-string', () => JSON.stringify({ a: 1 }, null, '\t'));
T('json-replacer-fn', () => JSON.stringify({ a: 1, b: 2 }, (k, v) => k === 'b' ? undefined : v));
T('json-replacer-array', () => JSON.stringify({ a: 1, b: 2 }, ['a']));
T('json-toJSON', () => JSON.stringify({ toJSON() { return 'X'; } }));
T('json-toJSON-nested', () => JSON.stringify({ d: { toJSON() { return 1; } } }));
T('json-escapes', () => JSON.stringify('a"\n\t\\b'));
T('json-unicode', () => JSON.stringify('é😀'));
T('json-control-chars', () => JSON.stringify(''));
T('json-special-numbers', () => JSON.stringify([NaN, Infinity, -0]));
T('json-function-value', () => JSON.stringify({ f() { } }));
T('json-symbol-value', () => JSON.stringify({ s: Symbol('x') }));
T('json-bigint-throws', () => JSON.stringify({ a: 1n }));
T('json-circular-throws', () => { const c = {}; c.self = c; return JSON.stringify(c); });
T('json-array-holes', () => JSON.stringify([1, , 3]));
T('json-date', () => JSON.stringify({ d: new Date(0) }));
T('json-map-set', () => JSON.stringify({ m: new Map([[1, 2]]), s: new Set([1]) }));

T('json-parse', () => JSON.parse('{"a":[1,2],"b":{"c":3}}'));
T('json-parse-primitives', () => [JSON.parse('1'), JSON.parse('"s"'), JSON.parse('true'), JSON.parse('null')]);
T('json-parse-reviver', () => JSON.parse('{"a":1,"b":2}', (k, v) => typeof v === 'number' ? v * 2 : v));
T('json-parse-reviver-delete', () => JSON.parse('{"a":1,"b":2}', (k, v) => k === 'b' ? undefined : v));
T('json-parse-escapes', () => JSON.parse('"a\\nb\\u0041"'));
T('json-parse-nested-array', () => JSON.parse('[[1],[2,[3]]]'));
T('json-parse-whitespace', () => JSON.parse(' { "a" : 1 } '));
T('json-parse-bad', () => JSON.parse('{bad}'));
T('json-parse-trailing-comma', () => JSON.parse('[1,]'));
T('json-parse-single-quotes', () => JSON.parse("{'a':1}"));
T('json-round-trip', () => JSON.parse(JSON.stringify({ a: [1, { b: null }] })));

console.log(rows.join('\n'));

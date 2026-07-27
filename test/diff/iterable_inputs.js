// Every place that accepts an iterable, fed each of the iterable kinds.
// Maps, sets and generators are not ordinary objects internally, so a branch
// that tests for "object" before iterating silently sees nothing — this pins
// all of those entry points at once.

const rows = [];
function T(label, fn) {
  let v;
  try { v = fn(); }
  catch (e) { v = 'THROW:' + (e && e.constructor ? e.constructor.name : String(e)); }
  try { v = JSON.stringify(v); } catch (e) { v = String(v); }
  rows.push(label + ' = ' + v);
}

function* gen() { yield 1; yield 2; }
const mkSet = () => new Set([1, 2]);
const mkMap = () => new Map([['a', 1], ['b', 2]]);
const custom = () => ({ [Symbol.iterator]() { let i = 1; return { next: () => ({ value: i, done: i++ > 2 }) }; } });

// Array.from
T('from-set', () => Array.from(mkSet()));
T('from-map', () => Array.from(mkMap()));
T('from-gen', () => Array.from(gen()));
T('from-custom', () => Array.from(custom()));
T('from-string', () => Array.from('ab'));
T('from-arraylike', () => Array.from({ length: 2, 0: 'x', 1: 'y' }));
T('from-set-mapfn', () => Array.from(mkSet(), (x) => x * 2));
T('from-gen-mapfn', () => Array.from(gen(), (x) => x * 10));

// Spread into an array
T('spread-set', () => [...mkSet()]);
T('spread-map', () => [...mkMap()]);
T('spread-gen', () => [...gen()]);
T('spread-custom', () => [...custom()]);
T('spread-string', () => [...'ab']);
T('spread-mixed', () => [0, ...mkSet(), 9]);

// Spread into a call
T('call-spread-set', () => Math.max(...mkSet()));
T('call-spread-gen', () => Math.max(...gen()));

// Collection constructors
T('set-from-gen', () => [...new Set(gen())]);
T('set-from-set', () => [...new Set(mkSet())]);
T('set-from-string', () => [...new Set('aab')]);
T('map-from-gen', () => { function* p() { yield ['k', 1]; } return [...new Map(p())]; });
T('map-from-map', () => [...new Map(mkMap())]);
T('map-from-array', () => [...new Map([['k', 1]])]);
T('weakset-from-gen', () => { const o = {}; function* p() { yield o; } return new WeakSet(p()).has(o); });

// Typed arrays and buffers
T('u8-from-set', () => Array.from(new Uint8Array(mkSet())));
T('u8-from-gen', () => Array.from(new Uint8Array(gen())));
T('u8-from-custom', () => Array.from(new Uint8Array(custom())));
T('u8-from-array', () => Array.from(new Uint8Array([1, 2])));
T('u8-static-from-set', () => Array.from(Uint8Array.from(mkSet())));

// Object.fromEntries
T('fromEntries-map', () => Object.fromEntries(mkMap()));
T('fromEntries-gen', () => { function* p() { yield ['k', 1]; } return Object.fromEntries(p()); });
T('fromEntries-set-of-pairs', () => Object.fromEntries(new Set([['k', 1]])));
T('fromEntries-array', () => Object.fromEntries([['k', 1]]));

// Promise combinators
T('all-from-gen', () => { function* p() { yield Promise.resolve(1); yield 2; } return Promise.all(p()).constructor.name; });
T('all-from-set', () => Promise.all(new Set([1, 2])).constructor.name);

// for-of and destructuring
T('for-of-set', () => { const o = []; for (const v of mkSet()) o.push(v); return o; });
T('for-of-map', () => { const o = []; for (const [k, v] of mkMap()) o.push(k + v); return o; });
T('for-of-gen', () => { const o = []; for (const v of gen()) o.push(v); return o; });
T('destructure-set', () => { const [a, b] = mkSet(); return [a, b]; });
T('destructure-gen', () => { const [a, b] = gen(); return [a, b]; });
T('destructure-rest-gen', () => { const [a, ...r] = gen(); return [a, r]; });
T('destructure-map', () => { const [first] = mkMap(); return first; });

// yield* delegation
T('yield-star-set', () => { function* d() { yield* mkSet(); } return [...d()]; });
T('yield-star-gen', () => { function* d() { yield* gen(); } return [...d()]; });
T('yield-star-string', () => { function* d() { yield* 'ab'; } return [...d()]; });

// JSON sees them as plain objects with no enumerable keys
T('json-set', () => JSON.stringify({ s: mkSet() }));
T('json-map', () => JSON.stringify({ m: mkMap() }));
T('json-gen', () => JSON.stringify({ g: gen() }));

// Reflection over the non-object kinds
T('keys-of-set', () => Object.keys(mkSet()));
T('typeof-kinds', () => [typeof mkSet(), typeof mkMap(), typeof gen()]);
T('instanceof-kinds', () => [mkSet() instanceof Set, mkMap() instanceof Map, mkSet() instanceof Object]);

console.log(rows.join('\n'));

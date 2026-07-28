// Array methods: construction, searching with SameValueZero, sorting (default
// lexicographic order, stability, where holes and undefined land), the
// change-by-copy methods, mutation and folding, and generic array-like
// receivers.

const rows = [];
function T(label, fn) {
  let v;
  try { v = fn(); }
  catch (e) { v = 'THROW:' + (e && e.constructor ? e.constructor.name : String(e)); }
  try { v = JSON.stringify(v); } catch (e) { v = String(v); }
  rows.push(label + ' = ' + v);
}

// --- construction ---
T('ctor-length', () => { const a = new Array(3); return [a.length, 0 in a, JSON.stringify(a)]; });
T('ctor-elements', () => new Array(1, 2));
T('ctor-invalid-length', () => new Array(-1));
T('array-of', () => [Array.of(3), Array.of(1, 2)]);
T('array-from-iterable', () => Array.from(new Set([1, 2])));
T('array-from-arraylike', () => Array.from({ length: 2, 0: 'a', 1: 'b' }));
T('array-from-mapfn', () => Array.from([1, 2], (x, i) => x * 10 + i));
T('array-from-thisarg', () => Array.from([1], function () { return this.tag; }, { tag: 't' }));
T('array-from-string', () => Array.from('ab'));
T('array-from-length-only', () => Array.from({ length: 2 }));
T('isArray', () => [Array.isArray([]), Array.isArray({}), Array.isArray('a')]);

// --- access ---
T('at', () => { const a = [1, 2, 3]; return [a.at(0), a.at(-1), a.at(5), a.at(-9)]; });
T('indexOf-nan', () => [NaN].indexOf(NaN));
T('includes-nan', () => [NaN].includes(NaN));
T('includes-zeros', () => [[-0].includes(0), [0].includes(-0)]);
T('indexOf-from', () => ['a', 'b', 'a'].indexOf('a', 1));
T('indexOf-negative-from', () => ['a', 'b', 'a'].indexOf('a', -1));
T('lastIndexOf-from', () => ['a', 'b', 'a'].lastIndexOf('a', 1));
T('includes-from', () => [1, 2, 3].includes(1, 1));

// --- sorting ---
T('sort-default-lexicographic', () => [10, 9, 1, 2].sort());
T('sort-comparator', () => [10, 9, 1, 2].sort((a, b) => a - b));
T('sort-in-place-returns-same', () => { const a = [2, 1]; return a.sort() === a; });
T('sort-stability', () => {
  const a = [{ k: 'b', i: 0 }, { k: 'a', i: 1 }, { k: 'b', i: 2 }, { k: 'a', i: 3 }];
  return a.sort((x, y) => x.k < y.k ? -1 : x.k > y.k ? 1 : 0).map((o) => o.k + o.i);
});
T('sort-undefined-last', () => [3, undefined, 1].sort());
T('sort-holes-last', () => { const a = [3, , 1]; a.sort(); return [a.length, JSON.stringify(a), 1 in a]; });
T('sort-comparator-nonnumber', () => [3, 1, 2].sort(() => 0));
T('sort-strings', () => ['b', 'A', 'a', 'B'].sort());
T('sort-mixed', () => [1, 'a', true, null].sort());
T('toSorted', () => { const a = [3, 1]; const b = a.toSorted?.(); return [b, a]; });
T('toReversed', () => { const a = [1, 2]; const b = a.toReversed?.(); return [b, a]; });
T('toSpliced', () => { const a = [1, 2, 3]; const b = a.toSpliced?.(1, 1, 'x'); return [b, a]; });
T('with', () => { const a = [1, 2]; const b = a.with?.(0, 9); return [b, a]; });
T('with-negative', () => [1, 2].with?.(-1, 9));
T('with-out-of-range', () => { try { return [1, 2].with(5, 9); } catch (e) { return 'THROW:' + e.constructor.name; } });

// --- mutation ---
T('push-returns-length', () => { const a = [1]; return [a.push(2, 3), a]; });
T('pop-shift-unshift', () => { const a = [1, 2, 3]; return [a.pop(), a.shift(), a.unshift(0), a]; });
T('pop-empty', () => { const a = []; return [a.pop(), a.shift(), a.length]; });
T('splice-remove', () => { const a = [1, 2, 3]; return [a.splice(1, 1), a]; });
T('splice-insert', () => { const a = [1, 4]; a.splice(1, 0, 2, 3); return a; });
T('splice-negative', () => { const a = [1, 2, 3]; return [a.splice(-2, 1), a]; });
T('splice-no-count', () => { const a = [1, 2, 3]; return [a.splice(1), a]; });
T('reverse-in-place', () => { const a = [1, 2]; return [a.reverse() === a, a]; });
T('fill', () => [[1, 2, 3].fill(0), [1, 2, 3].fill(0, 1), [1, 2, 3].fill(0, -1)]);
T('copyWithin', () => [[1, 2, 3, 4, 5].copyWithin(0, 3), [1, 2, 3].copyWithin(1, 0)]);

// --- iteration and folding ---
T('reduce', () => [[1, 2, 3].reduce((a, b) => a + b), [1, 2].reduce((a, b) => a + b, 10)]);
T('reduce-empty-throws', () => [].reduce((a, b) => a + b));
T('reduce-empty-initial', () => [].reduce((a, b) => a + b, 5));
T('reduceRight', () => ['a', 'b', 'c'].reduceRight((a, b) => a + b));
T('reduce-index-args', () => { const seen = []; [1, 2].reduce((acc, v, i, arr) => { seen.push([v, i, arr.length]); return acc; }, 0); return seen; });
T('every-some-empty', () => [[].every(() => false), [].some(() => true)]);
T('findLast', () => [[1, 2, 3].findLast?.((x) => x < 3), [1, 2, 3].findLastIndex?.((x) => x < 3)]);
T('flat', () => [[1, [2, [3]]].flat(), [1, [2, [3]]].flat(2), [1, [2, [3]]].flat(Infinity)]);
T('flat-holes', () => { const a = [1, , 2]; return a.flat(); });
T('flatMap', () => [1, 2].flatMap((x) => [x, x * 2]));
T('flatMap-no-deep-flatten', () => [1].flatMap((x) => [[x]]));
T('entries-keys-values', () => [[...['a'].entries()], [...['a'].keys()], [...['a'].values()]]);

// --- joining and slicing ---
T('join', () => [[1, 2].join('-'), [1, 2].join(), [].join('-')]);
T('join-nullish', () => [null, undefined, 1].join('-'));
T('join-nested', () => [[1, 2], [3]].join('-'));
T('toString', () => String([1, [2, 3]]));
T('slice', () => [[1, 2, 3].slice(1), [1, 2, 3].slice(-2), [1, 2, 3].slice(1, -1)]);
T('concat', () => [[1].concat([2], 3), [1].concat()]);

// --- generic receivers ---
T('generic-join', () => Array.prototype.join.call({ length: 2, 0: 'a', 1: 'b' }, '-'));
T('generic-map', () => Array.prototype.map.call({ length: 2, 0: 1, 1: 2 }, (x) => x * 2));
T('generic-push', () => { const o = { length: 0 }; Array.prototype.push.call(o, 'x'); return [o.length, o[0]]; });
T('generic-slice', () => Array.prototype.slice.call({ length: 2, 0: 'a', 1: 'b' }));

// --- newer statics ---
T('groupBy', () => typeof Object.groupBy);
T('map-groupBy', () => typeof Map.groupBy);

T('groupBy-shape', () => { const g = Object.groupBy([1, 2, 3], (n) => n % 2 ? 'odd' : 'even'); return [g.odd, g.even, Object.getPrototypeOf(g)]; });
T('groupBy-index-arg', () => Object.groupBy([1, 2, 3], (v, i) => i < 2 ? 'lo' : 'hi'));
T('groupBy-iterable', () => Object.groupBy(new Set(['a', 'bb']), (s) => s.length));
T('groupBy-empty', () => Object.groupBy([], () => 'x'));
T('groupBy-bad-callback', () => Object.groupBy([1], 5));
T('map-groupBy-shape', () => { const m = Map.groupBy([1, 2, 3], (n) => n % 2 ? 'odd' : 'even'); return [m instanceof Map, m.size, [...m]]; });
T('map-groupBy-object-key', () => { const k = {}; const m = Map.groupBy([1, 2], () => k); return [m.size, m.get(k)]; });

console.log(rows.join('\n'));

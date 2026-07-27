// Dense coverage of Array.prototype and the Array statics, including the
// sparse-array and callback-ordering corners that are easy to get subtly wrong.

const rows = [];
function T(label, fn) {
  let v;
  try { v = fn(); }
  catch (e) { v = 'THROW:' + (e && e.constructor ? e.constructor.name : String(e)); }
  try { v = JSON.stringify(v); } catch (e) { v = String(v); }
  rows.push(label + ' = ' + v);
}

const a = [3, 1, 2];

T('at', () => [a.at(-1), a.at(0), a.at(99)]);
T('concat', () => [1].concat([2], 3));
T('concat-nested', () => [1].concat([[2]]));
T('copyWithin', () => [1, 2, 3, 4, 5].copyWithin(0, 3));
T('entries', () => [...['x'].entries()]);
T('every', () => [a.every((x) => x > 0), a.every((x) => x > 2)]);
T('fill', () => [new Array(3).fill(7), [1, 2, 3].fill(0, 1)]);
T('filter', () => a.filter((x) => x > 1));
T('find', () => [a.find((x) => x > 1), a.find((x) => x > 9)]);
T('findIndex', () => [a.findIndex((x) => x > 1), a.findIndex((x) => x > 9)]);
T('findLast', () => a.findLast((x) => x > 1));
T('findLastIndex', () => [a.findLastIndex((x) => x > 1), a.findLastIndex((x) => x > 9)]);
T('flat', () => [1, [2, [3]]].flat(2));
T('flat-infinity', () => [1, [2, [3, [4]]]].flat(Infinity));
T('flatMap', () => [1, 2].flatMap((x) => [x, x]));
T('forEach', () => { let n = 0; a.forEach((x) => n += x); return n; });
T('forEach-index', () => { const o = []; ['x', 'y'].forEach((v, i) => o.push(i + v)); return o; });
T('includes', () => [a.includes(2), a.includes(9)]);
T('includes-NaN', () => [NaN].includes(NaN));
T('indexOf-NaN', () => [NaN].indexOf(NaN));
T('indexOf', () => [a.indexOf(2), a.indexOf(9)]);
T('join', () => [a.join('-'), a.join(), [].join('-')]);
T('join-nullish', () => [1, null, undefined, 2].join(','));
T('keys', () => [...['x', 'y'].keys()]);
T('lastIndexOf', () => [1, 2, 1].lastIndexOf(1));
T('map', () => a.map((x) => x * 2));
T('map-index', () => ['a', 'b'].map((v, i) => i + v));
T('pop', () => { const b = [1, 2]; const v = b.pop(); return [v, b]; });
T('pop-empty', () => [].pop());
T('push', () => { const b = [1]; const n = b.push(2, 3); return [n, b]; });
T('reduce', () => a.reduce((x, y) => x + y));
T('reduce-initial', () => a.reduce((x, y) => x + y, 10));
T('reduce-empty', () => [].reduce((x, y) => x + y, 5));
T('reduce-empty-noinit', () => [].reduce((x, y) => x + y));
T('reduceRight', () => ['a', 'b'].reduceRight((x, y) => x + y));
T('reverse', () => [1, 2, 3].reverse());
T('shift', () => { const b = [1, 2]; const v = b.shift(); return [v, b]; });
T('slice', () => [a.slice(1), a.slice(-1), a.slice(1, 2)]);
T('some', () => [a.some((x) => x > 2), a.some((x) => x > 9)]);
T('sort-default', () => [10, 9, 1].sort());
T('sort-cmp', () => [10, 9, 1].sort((x, y) => x - y));
T('sort-stable', () => [{ k: 1, v: 'a' }, { k: 1, v: 'b' }, { k: 0, v: 'c' }].sort((x, y) => x.k - y.k).map((o) => o.v));
T('sort-strings', () => ['b', 'a', 'C'].sort());
T('splice', () => { const b = [1, 2, 3]; const r = b.splice(1, 1, 'x'); return [r, b]; });
T('splice-insert', () => { const b = [1, 4]; b.splice(1, 0, 2, 3); return b; });
T('splice-negative', () => { const b = [1, 2, 3]; return [b.splice(-1), b]; });
T('unshift', () => { const b = [2]; const n = b.unshift(1); return [n, b]; });
T('toString', () => String([1, [2, 3]]));
T('isArray', () => [Array.isArray([]), Array.isArray({}), Array.isArray('a')]);
T('from-string', () => Array.from('ab'));
T('from-maplike', () => Array.from({ length: 2 }, (_, i) => i));
T('from-set', () => Array.from(new Set([1, 1, 2])));
T('of', () => Array.of(1, 2));
T('of-single-number', () => [Array.of(3).length, new Array(3).length]);
T('toSorted', () => { const b = [3, 1]; return [b.toSorted(), b]; });
T('toReversed', () => { const b = [1, 2]; return [b.toReversed(), b]; });
T('with', () => { const b = [1, 2]; return [b.with(0, 9), b]; });
T('holes-map', () => { const h = [1, , 3]; return h.map((x) => x); });
T('holes-join', () => [1, , 3].join(','));
T('holes-forEach', () => { let n = 0; [1, , 3].forEach(() => n++); return n; });
T('holes-in', () => { const h = [1, , 3]; return [1 in h, h.length]; });
T('length-truncate', () => { const b = [1, 2, 3]; b.length = 1; return b; });
T('length-grow', () => { const b = [1]; b.length = 3; return [b.length, 1 in b]; });
T('negative-index', () => { const b = []; b[-1] = 1; return [b.length, b[-1]]; });
T('string-index', () => { const b = [1]; return [b['0'], b[0]]; });
T('nested-json', () => JSON.stringify([[1, [2]], { a: 1 }]));

console.log(rows.join('\n'));

// Array#sort: what takes part and in what order. A hole takes no part and ends
// up at the end, undefined is written after the sorted values and never reaches
// the comparator, equal elements keep their order, and a comparator that is
// neither a function nor undefined is a TypeError.

const T = (l, f) => { try { console.log(l, '->', JSON.stringify(f())); } catch (e) { console.log(l, 'threw', e.constructor.name); } };
T('undefined and holes', () => { const a = [3, undefined, 1, , 2]; a.sort((x, y) => x - y); return [a, a.length, 1 in a, 3 in a, 4 in a]; });
T('default compare', () => [10, 9, 1, undefined, , 2].sort());
T('stability', () => { const a = []; for (let i = 0; i < 20; i++) a.push({ k: i % 3, i }); a.sort((p, q) => p.k - q.k); return a.map(o => o.i).join(','); });
T('comparator never sees undefined', () => { let calls = 0; let sawUndef = false; [1, undefined, 2].sort((x, y) => { calls++; if (x === undefined || y === undefined) sawUndef = true; return 0; }); return [calls, sawUndef]; });
T('comparator throws', () => { const a = [3, 1, 2]; try { a.sort(() => { throw new RangeError('x'); }); } catch (e) { return ['threw', a]; } });
T('non-callable comparator', () => [2, 1].sort(1));
T('length after sort with holes', () => { const a = [ , 1, , 2]; a.sort(); return [a.length, JSON.stringify(a), 2 in a, 3 in a]; });

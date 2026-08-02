// Iterator helpers: the Iterator global, the prototype every iterator
// inherits, and the eleven methods on it.
//
// Two shape details are not checked, because tsmc does not have them. There
// are no per-kind iterator prototypes (Array Iterator, String Iterator and so
// on), so an iterator inherits the shared prototype directly and the hop count
// differs from node's. Generator functions have no per-function `prototype`
// layer either. What the checks below use instead is isPrototypeOf, which
// holds in both.

const rows = [];
function show(v) {
  if (v === undefined) return 'undefined';
  if (v === null) return 'null';
  if (typeof v === 'string') return JSON.stringify(v);
  if (Array.isArray(v)) return '[' + v.join(',') + ']';
  if (typeof v === 'object') { try { return JSON.stringify(v); } catch (e) { return String(v); } }
  return String(v);
}
function T(label, fn) {
  let v;
  try { v = fn(); }
  catch (e) { v = 'THROW:' + (e && e.name ? e.name : String(e)); }
  rows.push(label + ' = ' + show(v));
}
function* nums(n) { for (let i = 1; i <= n; i++) yield i; }

// --- the global -------------------------------------------------------------
T('typeof', () => typeof Iterator);
T('name', () => Iterator.name);
T('call-throws', () => { Iterator(); return 'no throw'; });
T('new-throws', () => { new Iterator(); return 'no throw'; });
T('subclass-ok', () => {
  class C extends Iterator { next() { return { done: true, value: undefined }; } }
  return new C() instanceof Iterator;
});
T('proto-of-proto', () => Object.getPrototypeOf(Iterator.prototype) === Object.prototype);
T('proto-methods', () => Object.getOwnPropertyNames(Iterator.prototype).sort().join(','));
T('proto-symbols', () => Object.getOwnPropertySymbols(Iterator.prototype).map(String).sort().join(','));
T('symiter-returns-this', () => { const o = {}; return Iterator.prototype[Symbol.iterator].call(o) === o; });
T('ctor-descriptor', () => Object.keys(Object.getOwnPropertyDescriptor(Iterator.prototype, 'constructor')).sort().join(','));
T('tag-descriptor', () => Object.keys(Object.getOwnPropertyDescriptor(Iterator.prototype, Symbol.toStringTag)).sort().join(','));
T('tag-value', () => Iterator.prototype[Symbol.toStringTag]);
T('ctor-getter-value', () => Iterator.prototype.constructor === Iterator);
T('method-descriptor', () => JSON.stringify(Object.getOwnPropertyDescriptor(Iterator.prototype, 'map')).replace(/"value":[^,]+,/, ''));
T('method-names', () => [Iterator.prototype.map.name, Iterator.prototype.toArray.name]);
// the setters refuse the prototype itself and give an instance its own property
T('proto-ctor-assign', () => { Iterator.prototype.constructor = 5; return 'no throw'; });
T('proto-tag-assign', () => { Iterator.prototype[Symbol.toStringTag] = 'x'; return 'no throw'; });
T('instance-ctor-assign', () => { const o = [].values(); o.constructor = 5; return [o.constructor, Object.getOwnPropertyDescriptor(o, 'constructor').enumerable]; });

// --- reachability from the built-in iterators --------------------------------
T('array-iter-has-map', () => typeof [1].values().map);
T('string-iter-has-map', () => typeof 'ab'[Symbol.iterator]().map);
T('set-iter-has-map', () => typeof new Set([1]).values().map);
T('map-iter-has-map', () => typeof new Map([[1, 2]]).entries().map);
T('generator-has-map', () => typeof nums(1).map);
T('array-entries-has-map', () => typeof [1].entries().map);
T('regexp-iter-has-map', () => typeof 'aa'.matchAll(/a/g).map);
T('array-iter-inherits', () => Iterator.prototype.isPrototypeOf([1].values()));
T('generator-inherits', () => Iterator.prototype.isPrototypeOf(nums(1)));
T('instanceof', () => [1].values() instanceof Iterator);
T('gen-instanceof', () => nums(1) instanceof Iterator);
T('async-gen-has-no-map', () => typeof (async function* () {})().map);

// --- map --------------------------------------------------------------------
T('map-basic', () => [...nums(3).map((x) => x * 2)]);
T('map-index', () => [...nums(3).map((x, i) => i)]);
T('map-array-source', () => [...[1, 2].values().map((x) => x + 1)]);
T('map-lazy', () => { let n = 0; nums(3).map(() => n++); return n; });
T('map-is-iterable', () => { const h = nums(1).map((x) => x); return h[Symbol.iterator]() === h; });
T('map-helper-tag', () => Object.prototype.toString.call(nums(1).map((x) => x)));
T('map-helper-inherits', () => Iterator.prototype.isPrototypeOf(nums(1).map((x) => x)));
T('helper-own-props', () => Object.getOwnPropertyNames([1].values().map((x) => x)).join(','));
T('helper-proto-names', () => Object.getOwnPropertyNames(Object.getPrototypeOf([1].values().map((x) => x))).sort().join(','));
T('helper-next-detached', () => { const h = [1, 2].values().map((x) => x); const n = h.next; return n.call(h).value; });
T('map-bad-fn', () => nums(1).map(5));
T('map-no-fn', () => nums(1).map());
T('map-on-non-object', () => Iterator.prototype.map.call(5, (x) => x));
T('map-on-plain', () => {
  let i = 0;
  const it = { next() { return i < 2 ? { done: false, value: i++ } : { done: true }; } };
  return [...Iterator.prototype.map.call(it, (x) => x + 1)];
});
T('map-result-shape', () => { const r = nums(2).map((x) => x).next(); return [r.done, r.value]; });
T('map-after-done', () => { const h = nums(1).map((x) => x); h.next(); h.next(); return h.next().done; });
T('map-throws-closes', () => {
  let closed = false;
  function* g() { try { yield 1; yield 2; } finally { closed = true; } }
  try { [...g().map(() => { throw new Error('x'); })]; } catch (e) { /* ignore */ }
  return closed;
});

// --- filter -----------------------------------------------------------------
T('filter-basic', () => [...nums(6).filter((x) => x % 2 === 0)]);
T('filter-index', () => [...nums(4).filter((x, i) => i < 2)]);
T('filter-none', () => [...nums(3).filter(() => false)]);
T('filter-bad-fn', () => nums(1).filter('x'));
T('filter-helper-tag', () => Object.prototype.toString.call([1].values().filter(() => true)));

// --- take / drop ------------------------------------------------------------
T('take-basic', () => [...nums(5).take(2)]);
T('take-more-than-there-is', () => [...nums(2).take(9)]);
T('take-zero', () => [...nums(5).take(0)]);
T('take-truncates', () => [...nums(5).take(2.9)]);
T('take-infinity', () => [...nums(3).take(Infinity)]);
T('take-negative', () => nums(3).take(-1));
T('take-nan', () => nums(3).take(NaN));
T('take-undefined', () => nums(3).take());
T('take-string', () => [...nums(5).take('2')]);
T('take-closes-source', () => {
  let closed = false;
  function* g() { try { yield 1; yield 2; yield 3; } finally { closed = true; } }
  [...g().take(1)];
  return closed;
});
T('take-zero-pulls-nothing', () => {
  let pulled = 0;
  function* g() { while (true) { pulled++; yield 1; } }
  [...g().take(0)];
  return pulled;
});
T('take-then-return', () => { const h = [1, 2, 3].values().take(2); h.next(); const r = h.return(); return [r.done, r.value]; });
T('drop-basic', () => [...nums(5).drop(2)]);
T('drop-all', () => [...nums(2).drop(5)]);
T('drop-zero', () => [...nums(3).drop(0)]);
T('drop-negative', () => nums(3).drop(-2));
T('drop-nan', () => nums(3).drop(NaN));
T('drop-lazy', () => { let n = 0; function* g() { while (true) { n++; yield 1; } } g().drop(3); return n; });

// --- flatMap ----------------------------------------------------------------
T('flatMap-arrays', () => [...nums(3).flatMap((x) => [x, x])]);
T('flatMap-empty', () => [...nums(3).flatMap(() => [])]);
T('flatMap-generator', () => [...nums(2).flatMap(function* (x) { yield x; yield -x; })]);
T('flatMap-one-level', () => [...[[1, [2]]].values().flatMap((x) => x)].length);
T('flatMap-string', () => [...['ab'].values().flatMap((x) => x)]);
T('flatMap-number', () => [...nums(2).flatMap((x) => x)]);
T('flatMap-index', () => [...nums(2).flatMap((x, i) => [i])]);
T('flatMap-inner-close', () => {
  let closed = false;
  function* inner() { try { yield 1; yield 2; } finally { closed = true; } }
  const h = [0].values().flatMap(() => inner());
  h.next();
  h.return();
  return closed;
});

// --- the methods that run an iterator down -----------------------------------
T('reduce', () => nums(4).reduce((a, b) => a + b));
T('reduce-initial', () => nums(3).reduce((a, b) => a + b, 10));
T('reduce-empty-no-initial', () => nums(0).reduce((a, b) => a + b));
T('reduce-empty-initial', () => nums(0).reduce((a, b) => a + b, 7));
T('reduce-index', () => nums(3).reduce((a, b, i) => a + i, 0));
T('reduce-bad-fn', () => nums(1).reduce(1));
T('reduce-throws-closes', () => {
  let closed = false;
  function* g() { try { yield 1; yield 2; } finally { closed = true; } }
  try { g().reduce(() => { throw new Error('x'); }); } catch (e) { /* ignore */ }
  return closed;
});
T('toArray', () => nums(3).toArray());
T('toArray-empty', () => nums(0).toArray());
T('toArray-is-array', () => Array.isArray(nums(1).toArray()));
T('toArray-on-plain', () => {
  let i = 0;
  return Iterator.prototype.toArray.call({ next() { return i < 3 ? { done: false, value: i++ } : { done: true }; } });
});
T('forEach', () => { const o = []; nums(3).forEach((x, i) => o.push(x + ':' + i)); return o.join(','); });
T('forEach-returns', () => nums(1).forEach(() => {}));
T('some-true', () => nums(5).some((x) => x === 3));
T('some-false', () => nums(3).some((x) => x > 9));
T('some-short-circuits', () => { let n = 0; nums(9).some((x) => { n++; return x === 2; }); return n; });
T('some-closes', () => {
  let closed = false;
  function* g() { try { yield 1; yield 2; } finally { closed = true; } }
  g().some((x) => x === 1);
  return closed;
});
T('every-true', () => nums(3).every((x) => x > 0));
T('every-false', () => nums(3).every((x) => x > 1));
T('every-empty', () => nums(0).every(() => false));
T('find', () => nums(5).find((x) => x > 3));
T('find-missing', () => nums(3).find((x) => x > 9));
T('find-index-arg', () => nums(3).find((x, i) => i === 2));

// --- Iterator.from ----------------------------------------------------------
T('from-type', () => typeof Iterator.from);
T('from-array', () => Iterator.from([1, 2, 3]).toArray());
T('from-string', () => Iterator.from('abc').toArray());
T('from-set', () => Iterator.from(new Set([1, 2])).toArray());
T('from-generator-identity', () => { const g = nums(2); return Iterator.from(g) === g; });
T('from-plain-iterator', () => {
  let i = 0;
  const it = { next() { return i < 2 ? { done: false, value: i++ } : { done: true }; } };
  return Iterator.from(it).map((x) => x * 10).toArray();
});
T('from-plain-is-iterator', () => Iterator.from({ next() { return { done: true }; } }) instanceof Iterator);
T('from-tag', () => Object.prototype.toString.call(Iterator.from({ next() { return { done: true }; } })));
T('from-number', () => Iterator.from(5));
T('from-null', () => Iterator.from(null));
T('from-no-next', () => Iterator.from({}));
T('from-wrapper-return', () => {
  let closed = false;
  const it = { next() { return { done: false, value: 1 }; }, return() { closed = true; return { done: true }; } };
  const w = Iterator.from(it);
  w.next();
  w.return();
  return closed;
});

// --- chaining ---------------------------------------------------------------
T('chain', () => nums(10).filter((x) => x % 2).map((x) => x * x).take(3).toArray());
T('chain-drop-take', () => nums(10).drop(2).take(3).toArray());
T('chain-lazy-count', () => {
  let pulled = 0;
  function* g() { let i = 0; while (true) { pulled++; yield i++; } }
  g().map((x) => x).take(2).toArray();
  return pulled;
});
T('set-iter-helper', () => new Set([1, 2, 3]).values().filter((x) => x > 1).toArray());
T('map-iter-helper', () => new Map([['a', 1], ['b', 2]]).entries().map(([k, v]) => k + v).toArray());
T('string-iter-helper', () => 'hello'[Symbol.iterator]().take(2).toArray().join(''));
T('for-of-helper', () => { const o = []; for (const x of nums(4).map((v) => v * 3)) o.push(x); return o; });
T('spread-helper', () => [...nums(3).drop(1)]);
T('destructure-helper', () => { const [a, b] = nums(4).map((x) => x * 2); return [a, b]; });

// --- abandoning a helper ----------------------------------------------------
T('helper-return', () => { const h = nums(3).map((x) => x); const r = h.return(); return [r.done, r.value]; });
T('helper-return-closes', () => {
  let closed = false;
  function* g() { try { yield 1; } finally { closed = true; } }
  g().map((x) => x).return();
  return closed;
});
T('helper-after-return', () => { const h = nums(3).map((x) => x); h.return(); return h.next().done; });

console.log(rows.join('\n'));

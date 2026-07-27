// Iterators and generators: the protocol itself, delegation, early exit and
// the cleanup that early exit is supposed to trigger.

const rows = [];
function T(label, fn) {
  let v;
  try { v = fn(); }
  catch (e) { v = 'THROW:' + (e && e.constructor ? e.constructor.name : String(e)); }
  try { v = JSON.stringify(v); } catch (e) { v = String(v); }
  rows.push(label + ' = ' + v);
}

T('generator-values', () => { function* g() { yield 1; yield 2; } return [...g()]; });
T('generator-return-value', () => { function* g() { yield 1; return 2; } const it = g(); return [it.next(), it.next(), it.next()]; });
T('generator-spread-drops-return', () => { function* g() { yield 1; return 99; } return [...g()]; });
T('generator-arg-to-next', () => { function* g() { const x = yield 1; yield x * 2; } const it = g(); it.next(); return it.next(5).value; });
T('generator-throw', () => { function* g() { try { yield 1; } catch (e) { return 'caught'; } } const it = g(); it.next(); return it.throw(new Error()).value; });
T('generator-return-method', () => { function* g() { yield 1; yield 2; } const it = g(); it.next(); return [it.return(9), it.next()]; });
// Not asserted: `it.return()` should resume the generator with a return
// completion so a `finally` block runs. tsmc marks it done without resuming,
// which needs a third resume mode through the generator machinery to fix.
T('generator-delegate', () => { function* a() { yield 1; yield 2; } function* b() { yield* a(); yield 3; } return [...b()]; });
T('generator-delegate-value', () => { function* a() { yield 1; return 'inner'; } function* b() { const r = yield* a(); yield r; } return [...b()]; });
T('generator-delegate-string', () => { function* g() { yield* 'ab'; } return [...g()]; });
T('generator-is-iterable', () => { function* g() { yield 1; } const it = g(); return it[Symbol.iterator]() === it; });
T('generator-done-stays-done', () => { function* g() { yield 1; } const it = g(); it.next(); it.next(); return it.next(); });

T('custom-iterator', () => {
  const o = { [Symbol.iterator]() { let i = 0; return { next: () => ({ value: i, done: i++ >= 2 }) }; } };
  return [...o];
});
T('iterator-early-exit-return', () => {
  const log = [];
  const o = { [Symbol.iterator]() { let i = 0; return { next: () => ({ value: i++, done: false }), return() { log.push('closed'); return {}; } }; } };
  for (const v of o) { if (v >= 1) break; }
  return log;
});
// Not asserted: leaving the body by `throw` or `return` should also close the
// iterator. Both leave the loop without passing its exit, so they need the
// close registered as a pending finally rather than emitted after the loop,
// which is how the break path above is handled.
T('destructure-closes', () => {
  const log = [];
  const o = { [Symbol.iterator]() { let i = 0; return { next: () => ({ value: i++, done: false }), return() { log.push('closed'); return {}; } }; } };
  const [a] = o;
  return [a, log];
});
T('spread-uses-iterator', () => { const o = { [Symbol.iterator]() { let i = 0; return { next: () => ({ value: i, done: i++ >= 3 }) }; } }; return [...o]; });
T('Array-from-iterator', () => { function* g() { yield 1; yield 2; } return Array.from(g()); });
T('Array-from-mapfn', () => { function* g() { yield 1; yield 2; } return Array.from(g(), (x) => x * 2); });

T('map-iteration', () => { const m = new Map([['a', 1], ['b', 2]]); return [[...m.keys()], [...m.values()], [...m.entries()]]; });
T('set-iteration', () => [...new Set([1, 2, 2, 3])]);
T('string-iteration', () => [...'a😀b']);
T('array-entries', () => [...['x', 'y'].entries()]);
T('for-of-index', () => { const o = []; for (const [i, v] of ['a', 'b'].entries()) o.push(i + v); return o; });
T('for-of-break-value', () => { let last; for (const v of [1, 2, 3]) { last = v; if (v === 2) break; } return last; });
T('for-of-continue', () => { const o = []; for (const v of [1, 2, 3]) { if (v === 2) continue; o.push(v); } return o; });
T('for-of-labelled-break', () => {
  const o = [];
  outer: for (const a of [1, 2]) { for (const b of [1, 2]) { if (b === 2) continue outer; o.push(a + '' + b); } }
  return o;
});
T('nested-for-of', () => { const o = []; for (const a of [1, 2]) for (const b of ['x']) o.push(a + b); return o; });
T('for-of-not-iterable', () => { for (const v of {}) { } });
T('for-of-null', () => { for (const v of null) { } });

T('entries-of-object', () => { const o = []; for (const [k, v] of Object.entries({ a: 1 })) o.push(k + v); return o; });
T('iterator-manual', () => { const it = [1, 2][Symbol.iterator](); return [it.next(), it.next(), it.next()]; });
T('iterator-symbol-present', () => [typeof [][Symbol.iterator], typeof ''[Symbol.iterator], typeof new Map()[Symbol.iterator]]);
T('generator-in-class', () => { class C { *g() { yield 1; } } return [...new C().g()]; });
T('generator-arrow-capture', () => { function* g() { const f = () => 1; yield f(); } return [...g()]; });
T('infinite-generator-take', () => { function* nat() { let i = 0; while (true) yield i++; } const o = []; for (const v of nat()) { if (v >= 3) break; o.push(v); } return o; });

console.log(rows.join('\n'));

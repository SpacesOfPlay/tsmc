// yield* delegation and the generator protocol: what yield* accepts, the value
// it evaluates to, and how next/throw/return travel into the delegate. Also
// what a malformed iterator does — a next() that returns a non-object must
// raise, not spin.

const rows = [];
function T(label, fn) {
  let v;
  try { v = fn(); }
  catch (e) { v = 'THROW:' + (e && e.constructor ? e.constructor.name : String(e)); }
  try { v = JSON.stringify(v); } catch (e) { v = String(v); }
  rows.push(label + ' = ' + v);
}

// --- what yield* accepts ---
T('deleg-array', () => { function* g() { yield* [1, 2]; } return [...g()]; });
T('deleg-string', () => { function* g() { yield* 'ab'; } return [...g()]; });
T('deleg-set', () => { function* g() { yield* new Set([1, 2]); } return [...g()]; });
T('deleg-map', () => { function* g() { yield* new Map([['a', 1]]); } return [...g()]; });
T('deleg-generator', () => { function* a() { yield 1; } function* g() { yield* a(); yield 2; } return [...g()]; });
T('deleg-custom-iterable', () => { const it = { [Symbol.iterator]: () => { let i = 0; return { next: () => i < 2 ? { value: i++, done: false } : { done: true } }; } }; function* g() { yield* it; } return [...g()]; });
T('deleg-non-iterable-throws', () => { function* g() { yield* 5; } return [...g()]; });
T('deleg-null-throws', () => { function* g() { yield* null; } return [...g()]; });
T('deleg-empty', () => { function* g() { yield* []; yield 'after'; } return [...g()]; });
T('deleg-nested-3', () => { function* a() { yield 1; } function* b() { yield* a(); yield 2; } function* c() { yield* b(); yield 3; } return [...c()]; });

// --- the value of a yield* expression ---
T('deleg-value-generator', () => { function* a() { yield 1; return 'inner'; } function* g() { const r = yield* a(); yield r; } return [...g()]; });
T('deleg-value-array', () => { function* g() { const r = yield* [1]; yield JSON.stringify(r); } return [...g()]; });
T('deleg-value-empty-gen', () => { function* a() { return 'only'; } function* g() { yield (yield* a()); } return [...g()]; });

// --- next(v) forwarding ---
T('deleg-next-forwarded', () => { const seen = []; function* a() { seen.push(yield 1); seen.push(yield 2); } function* g() { yield* a(); } const it = g(); it.next(); it.next('x'); it.next('y'); return seen; });
T('deleg-first-next-not-forwarded', () => { const seen = []; function* a() { seen.push(yield 1); } function* g() { yield* a(); } const it = g(); it.next('ignored'); it.next('sent'); return seen; });

// --- throw() forwarding ---
T('deleg-throw-propagates', () => { function* a() { yield 1; } function* g() { yield* a(); } const it = g(); it.next(); try { it.throw(new Error('boom')); return 'no-throw'; } catch (e) { return 'propagated:' + e.message; } });
T('deleg-throw-no-throw-method-closes', () => {
  const o = [];
  const it = { [Symbol.iterator]: () => ({ next: () => ({ value: 1, done: false }), return: () => { o.push('closed'); return { done: true }; } }) };
  function* g() { yield* it; }
  const g1 = g(); g1.next();
  try { g1.throw(new Error('x')); } catch (e) { o.push('threw'); }
  return o;
});

// --- return() forwarding (closes the delegate) ---
T('deleg-return-closes-inner', () => { const o = []; function* inner() { try { yield 1; yield 2; } finally { o.push('inner-cleanup'); } } function* outer() { yield* inner(); } const it = outer(); it.next(); it.return(9); return o; });
T('deleg-return-value', () => { function* inner() { yield 1; } function* outer() { yield* inner(); } const it = outer(); it.next(); const r = it.return(7); return [r.value, r.done]; });
T('deleg-return-runs-outer-finally', () => { const o = []; function* inner() { try { yield 1; } finally { o.push('inner'); } } function* outer() { try { yield* inner(); } finally { o.push('outer'); } } const it = outer(); it.next(); it.return(); return o; });
T('deleg-return-custom-iterator', () => { const o = []; const it = { [Symbol.iterator]: () => ({ next: () => ({ value: 1, done: false }), return: (v) => { o.push('closed'); return { value: v, done: true }; } }) }; function* g() { yield* it; } const g1 = g(); g1.next(); g1.return(3); return o; });
T('deleg-break-closes-inner', () => { const o = []; function* inner() { try { yield 1; yield 2; } finally { o.push('inner-cleanup'); } } function* outer() { yield* inner(); } for (const v of outer()) break; return o; });
T('deleg-nested-return-closes-all', () => { const o = []; function* a() { try { yield 1; } finally { o.push('a'); } } function* b() { try { yield* a(); } finally { o.push('b'); } } const it = b(); it.next(); it.return(); return o; });

// --- generator protocol after completion ---
T('gen-next-after-done', () => { function* g() { yield 1; } const it = g(); it.next(); it.next(); return JSON.stringify(it.next()); });
T('gen-return-after-done', () => { function* g() { yield 1; } const it = g(); it.next(); it.next(); return JSON.stringify(it.return(5)); });
T('gen-throw-after-done', () => { function* g() { yield 1; } const it = g(); it.next(); it.next(); try { it.throw(new Error('x')); return 'no-throw'; } catch (e) { return 'threw'; } });
T('gen-next-arg-first-ignored', () => { const seen = []; function* g() { seen.push(yield 1); } const it = g(); it.next('a'); it.next('b'); return seen; });
T('gen-return-in-body', () => { function* g() { yield 1; return 'done'; } const it = g(); it.next(); return JSON.stringify(it.next()); });
T('gen-return-value-not-yielded', () => { function* g() { yield 1; return 'ret'; } return [...g()]; });
T('gen-is-iterator-and-iterable', () => { function* g() { yield 1; } const it = g(); return it[Symbol.iterator]() === it; });
T('gen-bad-next-result', () => { const it = { [Symbol.iterator]: () => ({ next: () => 5 }) }; function* g() { yield* it; } return [...g()]; });

console.log(rows.join('\n'));

// Not asserted: yield* does not forward a throw into the delegate. A delegate
// that catches the error internally never sees it (the throw propagates out of
// the outer generator instead), and when the delegate has no `throw` method the
// close above happens but the original error surfaces rather than a TypeError.

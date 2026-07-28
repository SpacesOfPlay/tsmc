// Control flow through `finally`, and iterator/generator closing on an early
// exit. A `finally` must run on every completion and can override the one in
// flight; a for-of that leaves early — break, return, or throw — must close
// its iterator, and closing a generator resumes it with a return completion so
// its `finally` blocks run.

const rows = [];
function T(label, fn) {
  let v;
  try { v = fn(); }
  catch (e) { v = 'THROW:' + (e && e.constructor ? e.constructor.name : ':' + String(e)); }
  try { v = JSON.stringify(v); } catch (e) { v = String(v); }
  rows.push(label + ' = ' + v);
}

// --- finally overriding completions ---
T('fin-runs-on-normal', () => { const o = []; (function () { try { o.push('t'); } finally { o.push('f'); } })(); return o; });
T('fin-runs-on-return', () => { const o = []; (function () { try { o.push('t'); return; } finally { o.push('f'); } })(); return o; });
T('fin-return-overrides', () => (function () { try { return 'try'; } finally { return 'finally'; } })());
T('fin-return-overrides-throw', () => (function () { try { throw new Error('x'); } finally { return 'finally'; } })());
T('fin-throw-overrides-return', () => (function () { try { return 'try'; } finally { throw new Error('fin'); } })());
T('fin-value-evaluated-before', () => { let n = 1; const r = (function () { try { return n; } finally { n = 2; } })(); return [r, n]; });
T('fin-nested', () => { const o = []; (function () { try { try { return; } finally { o.push('inner'); } } finally { o.push('outer'); } })(); return o; });
T('fin-rethrow-after-catch', () => { const o = []; try { (function () { try { throw new Error('a'); } catch (e) { throw new Error('b'); } finally { o.push('f'); } })(); } catch (e) { o.push(e.message); } return o; });
T('fin-catch-then-finally-order', () => { const o = []; try { o.push('t'); throw 1; } catch (e) { o.push('c'); } finally { o.push('f'); } return o; });
T('fin-no-catch-propagates', () => { const o = []; try { (function () { try { throw new Error('x'); } finally { o.push('f'); } })(); } catch (e) { o.push('caught'); } return o; });

// --- break / continue crossing finally ---
T('fin-break-runs', () => { const o = []; for (let i = 0; i < 3; i++) { try { if (i === 1) break; o.push(i); } finally { o.push('f' + i); } } return o; });
T('fin-continue-runs', () => { const o = []; for (let i = 0; i < 3; i++) { try { if (i === 1) continue; o.push(i); } finally { o.push('f' + i); } } return o; });
T('fin-break-overridden-by-return', () => (function () { for (let i = 0; i < 3; i++) { try { break; } finally { return 'fin'; } } return 'after'; })());
T('fin-labeled-break', () => { const o = []; outer: for (let i = 0; i < 2; i++) { for (let j = 0; j < 2; j++) { try { if (j === 0) continue outer; o.push('body'); } finally { o.push('f' + i + j); } } } return o; });
T('fin-break-in-finally', () => { const o = []; for (let i = 0; i < 3; i++) { try { o.push(i); } finally { if (i === 1) break; } } return o; });
T('fin-while-continue', () => { const o = []; let i = 0; while (i < 3) { i++; try { if (i === 2) continue; o.push(i); } finally { o.push('f'); } } return o; });
T('fin-return-in-loop', () => { const o = []; const r = (function () { for (let i = 0; i < 3; i++) { try { if (i === 1) return 'ret'; } finally { o.push('f' + i); } } })(); return [r, o]; });
T('fin-switch-break', () => { const o = []; switch (1) { case 1: try { o.push('c'); break; } finally { o.push('f'); } } return o; });

// --- finally + loops without try ---
T('fin-do-while', () => { const o = []; let i = 0; do { try { o.push(i); } finally { o.push('f'); } i++; } while (i < 2); return o; });
T('fin-for-of-break', () => { const o = []; for (const x of [1, 2, 3]) { try { if (x === 2) break; o.push(x); } finally { o.push('f' + x); } } return o; });

// --- generators: finally on early termination ---
T('gen-finally-on-return', () => { const o = []; function* g() { try { yield 1; yield 2; } finally { o.push('cleanup'); } } const it = g(); it.next(); it.return(9); return o; });
T('gen-return-value', () => { function* g() { try { yield 1; } finally { } } const it = g(); it.next(); return it.return(9); });
T('gen-finally-on-throw', () => { const o = []; function* g() { try { yield 1; } finally { o.push('cleanup'); } } const it = g(); it.next(); try { it.throw(new Error('x')); } catch (e) { o.push('propagated'); } return o; });
T('gen-finally-on-break', () => { const o = []; function* g() { try { yield 1; yield 2; } finally { o.push('cleanup'); } } for (const v of g()) break; return o; });
T('gen-finally-completes-normally', () => { const o = []; function* g() { try { yield 1; } finally { o.push('cleanup'); } } for (const v of g()) o.push(v); return o; });
T('gen-return-inside-finally-yield', () => { function* g() { try { yield 1; } finally { } } const it = g(); it.next(); const r = it.return(5); return [r.value, r.done, JSON.stringify(it.next())]; });
T('gen-done-after-return', () => { function* g() { yield 1; yield 2; } const it = g(); it.next(); it.return(); return JSON.stringify(it.next()); });
T('gen-return-before-start', () => { const o = []; function* g() { try { yield 1; } finally { o.push('cleanup'); } } const it = g(); const r = it.return(7); return [r.value, r.done, o.length]; });
T('gen-throw-before-start', () => { function* g() { try { yield 1; } catch (e) { return 'caught'; } } const it = g(); try { return JSON.stringify(it.throw(new Error('x'))); } catch (e) { return 'THREW:' + e.constructor.name; } });
T('gen-delegate-return-closes-inner', () => { const o = []; function* inner() { try { yield 1; yield 2; } finally { o.push('inner-cleanup'); } } function* outer() { yield* inner(); } const it = outer(); it.next(); it.return(9); return o; });
T('gen-nested-finally', () => { const o = []; function* g() { try { try { yield 1; } finally { o.push('inner'); } } finally { o.push('outer'); } } const it = g(); it.next(); it.return(); return o; });
T('gen-destructure-closes', () => { const o = []; function* g() { try { yield 1; yield 2; yield 3; } finally { o.push('cleanup'); } } const [a] = g(); return [a, o]; });
T('gen-spread-completes', () => { const o = []; function* g() { try { yield 1; } finally { o.push('cleanup'); } } const a = [...g()]; return [a, o]; });

// --- iterator close on early exit (non-generator) ---
T('iter-close-on-break', () => { const o = []; const it = { [Symbol.iterator]: () => ({ next: () => ({ value: 1, done: false }), return: () => { o.push('closed'); return { done: true }; } }) }; for (const x of it) break; return o; });
T('iter-close-on-throw', () => { const o = []; const it = { [Symbol.iterator]: () => ({ next: () => ({ value: 1, done: false }), return: () => { o.push('closed'); return { done: true }; } }) }; try { for (const x of it) throw new Error('x'); } catch (e) { o.push('caught'); } return o; });
T('iter-close-on-return', () => { const o = []; const it = { [Symbol.iterator]: () => ({ next: () => ({ value: 1, done: false }), return: () => { o.push('closed'); return { done: true }; } }) }; (function () { for (const x of it) return; })(); return o; });
T('iter-no-close-on-normal', () => { const o = []; const it = { [Symbol.iterator]: () => { let i = 0; return { next: () => i++ < 1 ? { value: i, done: false } : { done: true }, return: () => { o.push('closed'); return { done: true }; } }; } }; for (const x of it) {} return o; });

console.log(rows.join('\n'));

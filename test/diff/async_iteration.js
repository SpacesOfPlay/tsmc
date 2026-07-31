// Async iteration: async generators, for await, delegation, cleanup.
//
// Checks run one at a time and each is raced against a timer, so a
// regression that never settles shows up as TIMEOUT instead of wedging the
// suite.
//
// Two gaps are left out because sync generators share them, so they belong
// to yield* and to the generator object rather than to anything async:
// yield* does not forward throw() into the delegate, and getPrototypeOf on
// a generator returns null instead of walking to its prototype.

const out = [];

function show(v) {
  if (v === undefined) return 'undefined';
  if (v === null) return 'null';
  if (typeof v === 'string') return JSON.stringify(v);
  if (typeof v === 'symbol') return v.toString();
  if (typeof v === 'function') return 'fn:' + (v.name || '?');
  if (Array.isArray(v)) return '[' + v.map(show).join(', ') + ']';
  if (typeof v === 'object') {
    if (v instanceof Error) return v.constructor.name + '(' + v.message + ')';
    try { return JSON.stringify(v); } catch (e) { return String(v); }
  }
  return String(v);
}

async function T(label, fn) {
  let v;
  try {
    v = await Promise.race([
      Promise.resolve().then(fn),
      new Promise((r) => setTimeout(() => r('TIMEOUT'), 5000)),
    ]);
  } catch (e) {
    v = 'THROW:' + (e && e.constructor ? e.constructor.name : String(e)) +
        (e && e.message ? ':' + e.message : '');
  }
  out.push(label + ' = ' + show(v));
}

const tick = () => new Promise((r) => setTimeout(r, 1));

async function collect(it) {
  const seen = [];
  for await (const v of it) seen.push(v);
  return seen;
}

async function main() {
  // --- shape of the object -------------------------------------------------
  await T('next-returns-promise', () => {
    async function* g() { yield 1; }
    return g().next() instanceof Promise;
  });
  await T('has-asyncIterator', () => {
    async function* g() { yield 1; }
    return typeof g()[Symbol.asyncIterator];
  });
  await T('asyncIterator-returns-self', () => {
    async function* g() { yield 1; }
    const it = g();
    return it[Symbol.asyncIterator]() === it;
  });
  await T('no-sync-iterator', () => {
    async function* g() { yield 1; }
    return typeof g()[Symbol.iterator];
  });
  await T('toStringTag', () => {
    async function* g() { yield 1; }
    return Object.prototype.toString.call(g());
  });

  // --- awaiting inside the body --------------------------------------------
  await T('await-then-yield', async () => {
    async function* g() { await tick(); yield 1; await tick(); yield 2; }
    return await collect(g());
  });
  await T('await-value-used', async () => {
    async function* g() { const v = await Promise.resolve(7); yield v * 2; }
    return await collect(g());
  });
  await T('await-between-every-yield', async () => {
    async function* g() {
      for (let i = 0; i < 3; i++) { await tick(); yield i; }
    }
    return await collect(g());
  });
  await T('await-rejection-caught-inside', async () => {
    async function* g() {
      try { await Promise.reject(new RangeError('r')); yield 'no'; }
      catch (e) { yield 'caught:' + e.constructor.name; }
    }
    return await collect(g());
  });
  await T('reject-awaited', async () => {
    async function* g() { await Promise.reject(new RangeError('r')); yield 1; }
    try { await collect(g()); return 'no-throw'; }
    catch (e) { return e.constructor.name + ':' + e.message; }
  });
  await T('return-while-awaiting-runs-finally', async () => {
    const log = [];
    async function* g() {
      try { await tick(); yield 1; await tick(); yield 2; }
      finally { log.push('cleanup'); }
    }
    const it = g();
    await it.next();
    await it.return('done');
    return log;
  });

  // --- production ----------------------------------------------------------
  await T('yields', async () => {
    async function* g() { yield 1; yield 2; yield 3; }
    return await collect(g());
  });
  await T('yield-awaits-promise', async () => {
    async function* g() { yield Promise.resolve('p'); yield 'plain'; }
    return await collect(g());
  });
  await T('empty', async () => {
    async function* g() {}
    return await collect(g());
  });
  await T('return-value-not-yielded', async () => {
    async function* g() { yield 1; return 99; }
    return await collect(g());
  });

  // --- next() --------------------------------------------------------------
  await T('next-result-shape', async () => {
    async function* g() { yield 1; }
    const it = g();
    const a = await it.next();
    const b = await it.next();
    return [a.value, a.done, b.value, b.done];
  });
  await T('next-after-done', async () => {
    async function* g() { yield 1; }
    const it = g();
    await it.next();
    await it.next();
    const c = await it.next();
    return [c.value, c.done];
  });
  await T('next-arg-is-yield-result', async () => {
    async function* g() { const got = yield 1; yield got; }
    const it = g();
    await it.next();
    const b = await it.next('sent');
    return b.value;
  });
  await T('concurrent-nexts-queue', async () => {
    async function* g() { yield 1; yield 2; }
    const it = g();
    const both = await Promise.all([it.next(), it.next()]);
    return both.map((r) => r.value);
  });

  // --- delegation ----------------------------------------------------------
  await T('yield-star-async', async () => {
    async function* inner() { yield 1; yield 2; }
    async function* outer() { yield 0; yield* inner(); yield 3; }
    return await collect(outer());
  });
  await T('yield-star-sync-iterable', async () => {
    async function* g() { yield* [1, 2]; }
    return await collect(g());
  });
  await T('yield-star-string', async () => {
    async function* g() { yield* 'ab'; }
    return await collect(g());
  });
  await T('yield-star-value', async () => {
    async function* inner() { yield 1; return 'ret'; }
    async function* outer() { const r = yield* inner(); yield r; }
    return await collect(outer());
  });

  // --- errors --------------------------------------------------------------
  await T('body-throw-rejects', async () => {
    async function* g() { yield 1; throw new TypeError('boom'); }
    try { await collect(g()); return 'no-throw'; }
    catch (e) { return e.constructor.name + ':' + e.message; }
  });
  await T('yielded-rejection', async () => {
    async function* g() { yield Promise.reject(new EvalError('y')); }
    try { await collect(g()); return 'no-throw'; }
    catch (e) { return e.constructor.name + ':' + e.message; }
  });
  await T('throw-method', async () => {
    async function* g() { try { yield 1; } catch (e) { yield 'caught:' + e.message; } }
    const it = g();
    await it.next();
    const r = await it.throw(new Error('in'));
    return r.value;
  });

  // --- cleanup -------------------------------------------------------------
  await T('return-method', async () => {
    async function* g() { yield 1; yield 2; }
    const it = g();
    await it.next();
    const r = await it.return('early');
    const after = await it.next();
    return [r.value, r.done, after.value, after.done];
  });
  await T('break-runs-finally', async () => {
    const log = [];
    async function* g() {
      try { yield 1; yield 2; } finally { log.push('cleanup'); }
    }
    for await (const v of g()) { log.push(v); break; }
    return log;
  });
  await T('throw-in-loop-runs-finally', async () => {
    const log = [];
    async function* g() {
      try { yield 1; } finally { log.push('cleanup'); }
    }
    try {
      for await (const v of g()) { log.push(v); throw new Error('stop'); }
    } catch (e) { log.push('caught'); }
    return log;
  });

  // --- for await over other things -----------------------------------------
  await T('for-await-array-of-promises', async () =>
    await collect([Promise.resolve(1), Promise.resolve(2)]));
  await T('for-await-plain-array', async () => await collect([1, 2]));
  await T('for-await-string', async () => await collect('hi'));
  await T('for-await-custom-async', async () => {
    const obj = {
      [Symbol.asyncIterator]() {
        let i = 0;
        return { next: () => Promise.resolve({ value: i, done: i++ >= 2 }) };
      },
    };
    return await collect(obj);
  });
  await T('for-await-sync-iterator-fallback', async () => {
    const obj = {
      [Symbol.iterator]() {
        let i = 0;
        return { next: () => ({ value: i, done: i++ >= 2 }) };
      },
    };
    return await collect(obj);
  });
  await T('for-await-rejects-on-bad', async () => {
    try { await collect(42); return 'no-throw'; }
    catch (e) { return e.constructor.name; }
  });

  // --- placement -----------------------------------------------------------
  await T('method-shorthand', async () => {
    const o = { async *g() { yield 'm'; } };
    return await collect(o.g());
  });
  await T('class-method', async () => {
    class C { async *g() { yield 'c'; } }
    return await collect(new C().g());
  });
  await T('static-method', async () => {
    class C { static async *g() { yield 's'; } }
    return await collect(C.g());
  });
  await T('expression-form', async () => {
    const g = async function* () { yield 'e'; };
    return await collect(g());
  });

  // --- ordering ------------------------------------------------------------
  await T('interleave', async () => {
    const log = [];
    async function* g() { log.push('a'); yield 1; log.push('b'); yield 2; log.push('c'); }
    for await (const v of g()) log.push('got' + v);
    return log.join(',');
  });

  // --- the request queue ---------------------------------------------------
  await T('three-concurrent-nexts', async () => {
    async function* g() { yield 1; yield 2; yield 3; }
    const it = g();
    const r = await Promise.all([it.next(), it.next(), it.next()]);
    return r.map((x) => x.value + ':' + x.done);
  });
  await T('concurrent-past-the-end', async () => {
    async function* g() { yield 1; }
    const it = g();
    const r = await Promise.all([it.next(), it.next(), it.next()]);
    return r.map((x) => show(x.value) + ':' + x.done);
  });
  await T('concurrent-with-awaits', async () => {
    async function* g() { await tick(); yield 1; await tick(); yield 2; }
    const it = g();
    const r = await Promise.all([it.next(), it.next(), it.next()]);
    return r.map((x) => show(x.value) + ':' + x.done);
  });
  await T('next-then-return-queued', async () => {
    const log = [];
    async function* g() {
      try { await tick(); yield 1; await tick(); yield 2; } finally { log.push('fin'); }
    }
    const it = g();
    const [a, b] = await Promise.all([it.next(), it.return('stop')]);
    return [show(a.value), a.done, show(b.value), b.done, log.join(',')].join('/');
  });
  await T('next-then-throw-queued', async () => {
    async function* g() { await tick(); yield 1; yield 2; }
    const it = g();
    const rs = await Promise.allSettled([it.next(), it.throw(new RangeError('q'))]);
    return rs.map((r) => r.status + ':' + (r.value ? show(r.value.value) : r.reason.constructor.name));
  });
  await T('return-then-next', async () => {
    async function* g() { yield 1; yield 2; }
    const it = g();
    await it.next();
    const r = await it.return('x');
    const n = await it.next();
    return [show(r.value), r.done, show(n.value), n.done].join('/');
  });

  // --- cleanup while suspended --------------------------------------------
  await T('return-before-start', async () => {
    const log = [];
    async function* g() { try { yield 1; } finally { log.push('fin'); } }
    const it = g();
    const r = await it.return('early');
    return [show(r.value), r.done, log.length].join('/');
  });
  await T('throw-before-start', async () => {
    async function* g() { yield 1; }
    const it = g();
    try { await it.throw(new TypeError('t')); return 'no-throw'; }
    catch (e) { return e.constructor.name; }
  });
  await T('finally-yields-on-return', async () => {
    async function* g() {
      try { yield 1; } finally { yield 'from-finally'; }
    }
    const it = g();
    await it.next();
    const r = await it.return('r');
    const after = await it.next();
    return [show(r.value), r.done, show(after.value), after.done].join('/');
  });
  await T('finally-awaits-on-return', async () => {
    const log = [];
    async function* g() {
      try { yield 1; } finally { await tick(); log.push('after-await'); }
    }
    const it = g();
    await it.next();
    const r = await it.return('r');
    return [show(r.value), r.done, log.join(',')].join('/');
  });
  await T('return-value-awaited', async () => {
    async function* g() { yield 1; return Promise.resolve('late'); }
    const it = g();
    await it.next();
    const r = await it.next();
    return [show(r.value), r.done].join('/');
  });

  // --- delegation ----------------------------------------------------------
  await T('delegate-sent-value', async () => {
    async function* inner() { const got = yield 'a'; yield 'got:' + got; }
    async function* outer() { yield* inner(); }
    const it = outer();
    await it.next();
    const r = await it.next('sent');
    return r.value;
  });
  await T('delegate-body-throws', async () => {
    async function* inner() { yield 1; throw new RangeError('inner'); }
    async function* outer() { try { yield* inner(); } catch (e) { yield 'caught:' + e.constructor.name; } }
    return await collect(outer());
  });
  await T('delegate-custom-async-iterable', async () => {
    const obj = {
      [Symbol.asyncIterator]() {
        let i = 0;
        return { next: () => Promise.resolve({ value: i, done: i++ >= 2 }) };
      },
    };
    async function* g() { yield* obj; }
    return await collect(g());
  });
  await T('delegate-with-awaits-inside', async () => {
    async function* inner() { await tick(); yield 1; await tick(); yield 2; }
    async function* outer() { await tick(); yield 0; yield* inner(); await tick(); yield 3; }
    return await collect(outer());
  });
  await T('nested-delegation', async () => {
    async function* a() { yield 1; }
    async function* b() { yield* a(); yield 2; }
    async function* c() { yield* b(); yield 3; }
    return await collect(c());
  });
  await T('delegate-return-forwarded', async () => {
    const log = [];
    async function* inner() { try { yield 1; yield 2; } finally { log.push('inner-fin'); } }
    async function* outer() { yield* inner(); }
    const it = outer();
    await it.next();
    await it.return('done');
    await tick();
    return log.join(',');
  });

  // --- ordering ------------------------------------------------------------
  await T('yield-vs-promise-order', async () => {
    const log = [];
    async function* g() { yield 1; yield 2; }
    const p = (async () => { for await (const v of g()) log.push('g' + v); })();
    Promise.resolve().then(() => log.push('micro'));
    await p;
    return log.join(',');
  });
  await T('body-runs-lazily', async () => {
    const log = [];
    async function* g() { log.push('started'); yield 1; }
    const it = g();
    log.push('created');
    await it.next();
    return log.join(',');
  });
  await T('await-does-not-yield-turn-early', async () => {
    const log = [];
    async function* g() { log.push('a'); await null; log.push('b'); yield 1; }
    const it = g();
    const p = it.next();
    log.push('called');
    await p;
    return log.join(',');
  });

  // --- shapes --------------------------------------------------------------
  await T('fn-toStringTag', () => {
    async function* g() { yield 1; }
    return Object.prototype.toString.call(g);
  });
  await T('next-is-not-own', () => {
    async function* g() { yield 1; }
    const it = g();
    return Object.prototype.hasOwnProperty.call(it, 'next');
  });
  await T('methods-are-functions', () => {
    async function* g() { yield 1; }
    const it = g();
    return [typeof it.next, typeof it.return, typeof it.throw].join('/');
  });
  await T('for-of-rejects', () => {
    async function* g() { yield 1; }
    try { for (const v of g()) { void v; } return 'no-throw'; }
    catch (e) { return e.constructor.name; }
  });
  await T('plain-async-still-works', async () => {
    async function f() { const a = await 1; const b = await Promise.resolve(2); return a + b; }
    return await f();
  });
  await T('sync-generator-unchanged', () => {
    function* g() { const got = yield 1; yield got; }
    const it = g();
    const a = it.next();
    const b = it.next('s');
    return [a.value, a.done, b.value, b.done].join('/');
  });
  await T('sync-delegation-unchanged', () => {
    function* inner() { yield 1; return 'r'; }
    function* outer() { const r = yield* inner(); yield r; }
    return [...outer()];
  });
  await T('for-await-in-plain-async', async () => {
    async function f() {
      const seen = [];
      for await (const v of [Promise.resolve(1), 2]) seen.push(v);
      return seen;
    }
    return await f();
  });
  await T('await-in-for-await-body', async () => {
    const seen = [];
    for await (const v of [1, 2]) { await tick(); seen.push(v); }
    return seen;
  });
  await T('generator-in-class-unchanged', () => {
    class C { *g() { yield 'sync'; } }
    return [...new C().g()];
  });

  console.log(out.join('\n'));
}

main();

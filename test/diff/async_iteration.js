// Async iteration: async generators, for await, delegation, cleanup.
//
// Checks run one at a time and each is raced against a timer, so a
// regression that never settles shows up as TIMEOUT instead of wedging the
// suite.
//
// Not covered, because tsmc drives an async generator with the synchronous
// generator machinery: the object's shape (next() returns a plain result,
// Symbol.asyncIterator missing, Symbol.iterator present, the Generator tag)
// and any body that awaits. An await compiles to the same opcode as a
// yield, so the awaited value escapes to the consumer. See
// doc/PLAN_M43_async_generators.md. Every generator below only yields.

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

async function collect(it) {
  const seen = [];
  for await (const v of it) seen.push(v);
  return seen;
}

async function main() {
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

  console.log(out.join('\n'));
}

main();

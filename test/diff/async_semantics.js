// Async semantics: async functions, async generators, for await, the
// interleaving of awaits with the microtask queue, and the Promise statics.
//
// Checks run one at a time, so an ordering probe builds its own local log and
// returns it joined. Nothing depends on wall-clock time, so the output is
// deterministic. Each check is raced against a generous timer: a regression
// that never settles then shows up as a "TIMEOUT" mismatch instead of wedging
// the whole suite.
//
// Async generators live in async_iteration.js.
//
// Deliberately not covered, because tsmc does not implement them yet:
//   - A function's constructor is Function for every kind, so
//     `f.constructor.name === 'AsyncFunction'` does not hold. Functions share
//     one prototype object rather than one per kind. The Symbol.toStringTag
//     spellings *are* right, so toString.call(f) distinguishes them.
//   - Symbol.species: a Promise subclass's then() returns a base Promise.

const out = [];

function show(v) {
  if (v === undefined) return 'undefined';
  if (v === null) return 'null';
  if (typeof v === 'string') return JSON.stringify(v);
  if (typeof v === 'bigint') return v + 'n';
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

// --- async function basics --------------------------------------------------

async function basics() {
  await T('return-wraps', () => {
    const p = (async () => 5)();
    return p instanceof Promise;
  });
  await T('return-value', async () => (async () => 5)());
  await T('throw-rejects', async () => {
    try { await (async () => { throw new TypeError('boom'); })(); } catch (e) { return e; }
  });
  await T('await-nonpromise', async () => await 42);
  await T('await-null', async () => await null);
  await T('await-undefined', async () => await undefined);
  await T('await-thenable', async () => await { then(r) { r('th'); } });
  await T('await-thenable-reject', async () => {
    try { await { then(r, j) { j(new RangeError('nope')); } }; } catch (e) { return e; }
  });
  await T('await-throwing-then', async () => {
    try { await { then() { throw new EvalError('inthen'); } }; } catch (e) { return e; }
  });
  await T('await-then-getter-throws', async () => {
    try { await { get then() { throw new URIError('getter'); } }; } catch (e) { return e; }
  });
  await T('await-rejected-promise', async () => {
    try { await Promise.reject(new Error('r')); } catch (e) { return e; }
  });
  await T('tag-async-fn', () => Object.prototype.toString.call(async function () {}));
  await T('tag-async-gen-fn', () => Object.prototype.toString.call(async function* () {}));
  await T('tag-gen-fn', () => Object.prototype.toString.call(function* () {}));
  await T('tag-plain-fn', () => Object.prototype.toString.call(function () {}));
  await T('async-fn-length', () => (async function (a, b) {}).length);
  await T('async-fn-name', () => (async function named() {}).name);
  await T('async-arrow-name', () => { const f = async () => {}; return f.name; });
  // an async function is not constructible, so it has no .prototype at all
  await T('async-no-prototype', () => (async function () {}).prototype === undefined);
  await T('arrow-no-prototype', () => (() => {}).prototype === undefined);
  await T('method-no-prototype', () => ({ m() {} }).m.prototype === undefined);
  await T('gen-has-prototype', () => typeof (function* () {}).prototype);
  await T('async-not-constructible', () => {
    try { new (async function () {})(); return 'ok'; } catch (e) { return 'THROW:' + e.constructor.name; }
  });
  await T('async-method-in-obj', async () => {
    const o = { async m() { return this.v; }, v: 7 };
    return o.m();
  });
  await T('async-in-class', async () => {
    class C { async m() { return 'cm'; } }
    return new C().m();
  });
  await T('await-in-finally', async () => {
    const log = [];
    async function f() {
      try { log.push('try'); return 'ret'; } finally { log.push('fin-start'); await null; log.push('fin-end'); }
    }
    const r = await f();
    return log.join(',') + '|' + r;
  });
  await T('finally-overrides-return', async () => {
    async function f() {
      try { return 'a'; } finally { return 'b'; }
    }
    return f();
  });
  await T('throw-in-finally-wins', async () => {
    async function f() {
      try { throw new Error('first'); } finally { throw new Error('second'); }
    }
    try { await f(); } catch (e) { return e.message; }
  });
  await T('nested-await-catch', async () => {
    async function inner() { await null; throw new Error('deep'); }
    async function outer() { try { await inner(); } catch (e) { return 'caught:' + e.message; } }
    return outer();
  });
}

// --- async generators (yield-only; see the header) --------------------------

async function generators() {
  await T('agen-basic', async () => {
    async function* g() { yield 1; yield 2; yield 3; }
    const seen = [];
    for await (const v of g()) seen.push(v);
    return seen;
  });
  await T('agen-next-shape', async () => {
    async function* g() { yield 'x'; }
    const it = g();
    const a = await it.next();
    const b = await it.next();
    return [Object.keys(a).join('+'), a.value, a.done, b.value, b.done];
  });
  await T('agen-yield-awaits', async () => {
    async function* g() { yield Promise.resolve('unwrapped'); }
    const seen = [];
    for await (const v of g()) seen.push(v);
    return seen;
  });
  await T('agen-return-value', async () => {
    async function* g() { yield 1; return 'done-val'; }
    const it = g();
    await it.next();
    return await it.next();
  });
  await T('agen-throws', async () => {
    async function* g() { yield 1; throw new TypeError('agen'); }
    const seen = [];
    try { for await (const v of g()) seen.push(v); } catch (e) { return seen.join(',') + '|' + e.constructor.name; }
  });
  await T('agen-return-method', async () => {
    const log = [];
    async function* g() { try { yield 1; yield 2; } finally { log.push('fin'); } }
    const it = g();
    await it.next();
    const r = await it.return('early');
    return [log.join(','), r.value, r.done];
  });
  await T('agen-throw-method', async () => {
    async function* g() { try { yield 1; } catch (e) { yield 'caught:' + e.message; } }
    const it = g();
    await it.next();
    const r = await it.throw(new Error('injected'));
    return [r.value, r.done];
  });
  // leaving early must run the generator's finally
  await T('agen-break-closes', async () => {
    const log = [];
    async function* g() { try { yield 1; yield 2; yield 3; } finally { log.push('closed'); } }
    for await (const v of g()) { if (v === 2) break; }
    return log.join(',');
  });
  await T('agen-send-value', async () => {
    async function* g() { const a = yield 1; const b = yield a + 1; return b; }
    const it = g();
    const r1 = await it.next();
    const r2 = await it.next(10);
    const r3 = await it.next(99);
    return [r1.value, r2.value, r3.value, r3.done];
  });
  await T('agen-delegate-sync', async () => {
    async function* g() { yield* [1, 2]; yield 3; }
    const seen = [];
    for await (const v of g()) seen.push(v);
    return seen;
  });
  await T('agen-delegate-async', async () => {
    async function* inner() { yield 'a'; yield 'b'; }
    async function* g() { yield* inner(); yield 'c'; }
    const seen = [];
    for await (const v of g()) seen.push(v);
    return seen;
  });
  await T('agen-after-done', async () => {
    async function* g() { yield 1; }
    const it = g();
    await it.next();
    await it.next();
    const r = await it.next();
    return [r.value, r.done];
  });
}

// --- for await --------------------------------------------------------------

async function forAwait() {
  await T('fa-array', async () => {
    const seen = [];
    for await (const v of [1, 2, 3]) seen.push(v);
    return seen;
  });
  await T('fa-array-of-promises', async () => {
    const seen = [];
    for await (const v of [Promise.resolve('p1'), 'plain', Promise.resolve('p3')]) seen.push(v);
    return seen;
  });
  await T('fa-string', async () => {
    const seen = [];
    for await (const c of 'abc') seen.push(c);
    return seen;
  });
  await T('fa-set', async () => {
    const seen = [];
    for await (const v of new Set([1, 2])) seen.push(v);
    return seen;
  });
  await T('fa-map', async () => {
    const seen = [];
    for await (const [k, v] of new Map([['a', 1]])) seen.push(k + '=' + v);
    return seen;
  });
  await T('fa-sync-generator', async () => {
    function* g() { yield 1; yield 2; }
    const seen = [];
    for await (const v of g()) seen.push(v);
    return seen;
  });
  await T('fa-custom-asynciterable', async () => {
    const obj = {
      [Symbol.asyncIterator]() {
        let i = 0;
        return { next() { i++; return Promise.resolve(i <= 2 ? { value: 'i' + i, done: false } : { value: undefined, done: true }); } };
      },
    };
    const seen = [];
    for await (const v of obj) seen.push(v);
    return seen;
  });
  await T('fa-prefers-async-over-sync', async () => {
    const obj = {
      [Symbol.iterator]() { return [1][Symbol.iterator](); },
      [Symbol.asyncIterator]() {
        let done = false;
        return { next() { const d = done; done = true; return Promise.resolve(d ? { done: true } : { value: 'async', done: false }); } };
      },
    };
    const seen = [];
    for await (const v of obj) seen.push(v);
    return seen;
  });
  await T('fa-rejected-element', async () => {
    const seen = [];
    try {
      for await (const v of [Promise.resolve(1), Promise.reject(new Error('bad'))]) seen.push(v);
    } catch (e) { return seen.join(',') + '|' + e.message; }
  });
  await T('fa-next-rejects', async () => {
    const obj = { [Symbol.asyncIterator]() { return { next() { return Promise.reject(new RangeError('nx')); } }; } };
    try { for await (const v of obj) { /* unreachable */ } } catch (e) { return e.constructor.name; }
  });
  // an iterator that answers with a non-object has broken the protocol
  await T('fa-non-object-result', async () => {
    const obj = { [Symbol.asyncIterator]() { return { next() { return Promise.resolve(7); } }; } };
    try { for await (const v of obj) { break; } } catch (e) { return 'THROW:' + e.constructor.name; }
    return 'no-throw';
  });
  await T('fa-not-iterable', async () => {
    try { for await (const v of 5) { /* unreachable */ } } catch (e) { return 'THROW:' + e.constructor.name; }
    return 'no-throw';
  });
  // abandoning the loop releases the iterator, by either exit
  await T('fa-break-calls-return', async () => {
    const log = [];
    const obj = {
      [Symbol.asyncIterator]() {
        let i = 0;
        return {
          next() { i++; return Promise.resolve({ value: i, done: false }); },
          return() { log.push('returned'); return Promise.resolve({ done: true }); },
        };
      },
    };
    for await (const v of obj) { if (v === 2) break; }
    return log.join(',');
  });
  await T('fa-throw-calls-return', async () => {
    const log = [];
    const obj = {
      [Symbol.asyncIterator]() {
        let i = 0;
        return {
          next() { i++; return Promise.resolve({ value: i, done: false }); },
          return() { log.push('returned'); return Promise.resolve({ done: true }); },
        };
      },
    };
    try { for await (const v of obj) { throw new Error('stop'); } } catch (e) { /* expected */ }
    return log.join(',');
  });
  await T('fa-exhausted-no-return', async () => {
    const log = [];
    const obj = {
      [Symbol.asyncIterator]() {
        let i = 0;
        return {
          next() { i++; return Promise.resolve(i <= 2 ? { value: i, done: false } : { done: true }); },
          return() { log.push('returned'); return Promise.resolve({ done: true }); },
        };
      },
    };
    for await (const v of obj) { /* run to exhaustion */ }
    return log.length === 0 ? 'not-called' : log.join(',');
  });
  await T('fa-empty', async () => {
    let count = 0;
    for await (const v of []) count++;
    return count;
  });
  await T('fa-sync-iterable-of-thenables', async () => {
    const seen = [];
    for await (const v of [{ then(r) { r('t1'); } }, { then(r) { r('t2'); } }]) seen.push(v);
    return seen;
  });
}

// --- ordering ---------------------------------------------------------------

async function ordering() {
  await T('order-sync-prefix', async () => {
    const log = [];
    async function f() { log.push('a1'); await null; log.push('a2'); }
    const p = f();
    log.push('sync');
    await p;
    return log.join(',');
  });
  await T('order-await-vs-then', async () => {
    const log = [];
    const t = Promise.resolve()
      .then(() => log.push('t1'))
      .then(() => log.push('t2'))
      .then(() => log.push('t3'));
    const a = (async () => {
      log.push('s');
      await null; log.push('a1');
      await null; log.push('a2');
      await null; log.push('a3');
    })();
    await Promise.all([t, a]);
    return log.join(',');
  });
  await T('order-await-native-promise', async () => {
    const log = [];
    const t = Promise.resolve()
      .then(() => log.push('t1'))
      .then(() => log.push('t2'))
      .then(() => log.push('t3'));
    const a = (async () => { await Promise.resolve(); log.push('a1'); })();
    await Promise.all([t, a]);
    return log.join(',');
  });
  await T('order-await-thenable', async () => {
    const log = [];
    const t = Promise.resolve()
      .then(() => log.push('t1'))
      .then(() => log.push('t2'))
      .then(() => log.push('t3'));
    const a = (async () => { await { then(r) { r(); } }; log.push('a1'); })();
    await Promise.all([t, a]);
    return log.join(',');
  });
  await T('order-microtask-vs-promise', async () => {
    const log = [];
    const done = [];
    queueMicrotask(() => log.push('qm1'));
    done.push(Promise.resolve().then(() => log.push('p1')));
    queueMicrotask(() => log.push('qm2'));
    done.push(Promise.resolve().then(() => log.push('p2')));
    await Promise.all(done);
    return log.join(',');
  });
  await T('order-two-async-interleave', async () => {
    const log = [];
    async function f(tag) { log.push(tag + '0'); await null; log.push(tag + '1'); await null; log.push(tag + '2'); }
    await Promise.all([f('x'), f('y')]);
    return log.join(',');
  });
  await T('order-agen-consumption', async () => {
    const log = [];
    async function* g() { log.push('g1'); yield 1; log.push('g2'); yield 2; log.push('g3'); }
    for await (const v of g()) log.push('c' + v);
    return log.join(',');
  });
  await T('order-resolve-with-promise', async () => {
    const log = [];
    const inner = Promise.resolve('inner');
    const outer = new Promise((r) => r(inner));
    const t = Promise.resolve()
      .then(() => log.push('t1'))
      .then(() => log.push('t2'))
      .then(() => log.push('t3'));
    const o = outer.then((v) => log.push('outer:' + v));
    await Promise.all([t, o]);
    return log.join(',');
  });
  await T('order-all-resolution', async () => {
    const log = [];
    await Promise.all([
      (async () => { await null; log.push('one'); })(),
      (async () => { log.push('two'); })(),
    ]);
    return log.join(',');
  });
  // finally costs the chain an extra tick: its handler awaits the callback's
  // result before forwarding the settlement
  await T('order-finally-tick', async () => {
    const log = [];
    const p = Promise.resolve('v')
      .finally(() => log.push('fin'))
      .then((v) => log.push('then:' + v));
    const t = Promise.resolve().then(() => log.push('t1')).then(() => log.push('t2'));
    await Promise.all([p, t]);
    return log.join(',');
  });
}

// --- promise statics --------------------------------------------------------

async function statics() {
  await T('resolve-identity', () => {
    const p = Promise.resolve(1);
    return Promise.resolve(p) === p;
  });
  await T('reject-no-unwrap', async () => {
    const inner = Promise.resolve('x');
    try { await Promise.reject(inner); } catch (e) { return e === inner; }
  });
  await T('executor-throw-rejects', async () => {
    try { await new Promise(() => { throw new SyntaxError('exec'); }); } catch (e) { return e.constructor.name; }
  });
  await T('resolve-twice-ignored', async () => {
    return new Promise((r) => { r('first'); r('second'); });
  });
  await T('resolve-then-reject-ignored', async () => {
    return new Promise((res, rej) => { res('kept'); rej(new Error('dropped')); });
  });
  // a promise resolved with itself can never settle, so it rejects instead
  await T('resolve-self-rejects', async () => {
    let resolve;
    const p = new Promise((r) => { resolve = r; });
    resolve(p);
    try { await p; } catch (e) { return e.constructor.name; }
  });
  await T('all-empty', async () => Promise.all([]));
  await T('all-order-preserved', async () => Promise.all([
    new Promise((r) => Promise.resolve().then(() => Promise.resolve().then(() => r('slow')))),
    Promise.resolve('fast'),
  ]));
  await T('all-rejects-first', async () => {
    try { await Promise.all([Promise.reject(new Error('e1')), Promise.reject(new Error('e2'))]); } catch (e) { return e.message; }
  });
  await T('allSettled-shape', async () => {
    const r = await Promise.allSettled([Promise.resolve(1), Promise.reject(new Error('no'))]);
    return [Object.keys(r[0]).join('+'), r[0].status, r[0].value,
            Object.keys(r[1]).join('+'), r[1].status, r[1].reason.message];
  });
  await T('allSettled-empty', async () => Promise.allSettled([]));
  await T('race-first-settled', async () => Promise.race([
    new Promise((r) => Promise.resolve().then(() => Promise.resolve().then(() => r('slow')))),
    Promise.resolve('quick'),
  ]));
  await T('race-rejection-wins', async () => {
    try { await Promise.race([Promise.reject(new Error('rej')), new Promise(() => {})]); } catch (e) { return e.message; }
  });
  await T('any-first-fulfilled', async () => Promise.any([Promise.reject(new Error('a')), Promise.resolve('good')]));
  await T('any-all-reject', async () => {
    try { await Promise.any([Promise.reject(new Error('a')), Promise.reject(new Error('b'))]); } catch (e) {
      return [e.constructor.name, Array.isArray(e.errors), e.errors.map((x) => x.message).join(','), e.message];
    }
  });
  await T('any-empty', async () => {
    try { await Promise.any([]); } catch (e) { return [e.constructor.name, e.errors.length]; }
  });
  await T('withResolvers', async () => {
    const { promise, resolve } = Promise.withResolvers();
    resolve('wr');
    return [Object.keys(Promise.withResolvers()).sort().join('+'), await promise];
  });
  await T('then-non-callable-passthrough', async () => Promise.resolve('pt').then(null).then(undefined));
  await T('catch-passthrough', async () => {
    try { await Promise.reject(new Error('cp')).catch(null); } catch (e) { return e.message; }
  });
  await T('finally-passes-value', async () => Promise.resolve('fv').finally(() => 'ignored'));
  await T('finally-throw-overrides', async () => {
    try { await Promise.resolve('x').finally(() => { throw new Error('fo'); }); } catch (e) { return e.message; }
  });
  // finally must not swallow the rejection it was attached to
  await T('finally-on-rejection', async () => {
    const log = [];
    try { await Promise.reject(new Error('fr')).finally(() => log.push('ran')); } catch (e) { return log.join(',') + '|' + e.message; }
  });
  await T('finally-rejection-not-converted', async () => {
    let settled = 'neither';
    await Promise.reject(new Error('x')).finally(() => {}).then(
      () => { settled = 'fulfilled'; },
      () => { settled = 'rejected'; },
    );
    return settled;
  });
  await T('promise-tag', () => Object.prototype.toString.call(Promise.resolve()));
  await T('then-returns-new', () => {
    const p = Promise.resolve();
    return p.then(() => {}) !== p;
  });
  await T('all-non-iterable', async () => {
    try { await Promise.all(5); } catch (e) { return 'THROW:' + e.constructor.name; }
  });
}

async function main() {
  await basics();
  await generators();
  await forAwait();
  await ordering();
  await statics();
  console.log(out.join('\n'));
}

main();

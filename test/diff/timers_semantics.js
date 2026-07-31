// Timers and the order things run in.
//
// Nothing depends on wall clock time, only on relative ordering, so the
// output is stable. setImmediate against setTimeout(0) is left out on
// purpose: node does not order those two deterministically outside an I/O
// callback, so a check on it would flake in node itself.
//
// unref is not covered here. It decides whether the process exits, which a
// script that has to print its own result cannot observe. test/run has it.

const rows = [];
function show(v) {
  if (v === undefined) return 'undefined';
  if (v === null) return 'null';
  if (typeof v === 'string') return JSON.stringify(v);
  if (typeof v === 'function') return 'fn:' + (v.name || '?');
  if (Array.isArray(v)) return '[' + v.map(show).join(', ') + ']';
  if (typeof v === 'object') { try { return JSON.stringify(v); } catch (e) { return String(v); } }
  return String(v);
}
function T(label, v) { rows.push(label + ' = ' + show(v)); }
async function TA(label, fn) {
  let v;
  try {
    v = await Promise.race([
      Promise.resolve().then(fn),
      new Promise((r) => setTimeout(() => r('TIMEOUT'), 4000)),
    ]);
  } catch (e) { v = 'THROW:' + (e && e.constructor ? e.constructor.name : String(e)); }
  rows.push(label + ' = ' + show(v));
}
const after = (ms) => new Promise((r) => setTimeout(r, ms));

async function main() {
  // --- ordering between the queues ----------------------------------------
  await TA('micro-before-macro', async () => {
    const log = [];
    const p = new Promise((res) => setTimeout(() => { log.push('timeout'); res(); }, 0));
    Promise.resolve().then(() => log.push('promise'));
    queueMicrotask(() => log.push('microtask'));
    await p;
    return log.join(',');
  });
  await TA('nexttick-before-promise', async () => {
    const log = [];
    const p = new Promise((res) => setTimeout(res, 0));
    Promise.resolve().then(() => log.push('promise'));
    process.nextTick(() => log.push('tick'));
    await p;
    return log.join(',');
  });
  await TA('timeouts-fifo-same-delay', async () => {
    const log = [];
    const p = new Promise((res) => {
      setTimeout(() => log.push('a'), 0);
      setTimeout(() => log.push('b'), 0);
      setTimeout(() => { log.push('c'); res(); }, 0);
    });
    await p;
    return log.join(',');
  });
  await TA('timeouts-ordered-by-delay', async () => {
    const log = [];
    const p = new Promise((res) => {
      setTimeout(() => log.push('late'), 12);
      setTimeout(() => log.push('early'), 1);
      setTimeout(() => { log.push('last'); res(); }, 20);
    });
    await p;
    return log.join(',');
  });
  await TA('immediate-fifo', async () => {
    const log = [];
    const p = new Promise((res) => {
      setImmediate(() => log.push('i1'));
      setImmediate(() => log.push('i2'));
      setImmediate(() => { log.push('i3'); res(); });
    });
    await p;
    return log.join(',');
  });
  await TA('nested-timeout-runs-later', async () => {
    const log = [];
    const p = new Promise((res) => {
      setTimeout(() => {
        log.push('outer');
        setTimeout(() => { log.push('inner'); res(); }, 0);
      }, 0);
      setTimeout(() => log.push('sibling'), 0);
    });
    await p;
    return log.join(',');
  });
  await TA('microtask-drains-between-timers', async () => {
    const log = [];
    const p = new Promise((res) => {
      setTimeout(() => { log.push('t1'); Promise.resolve().then(() => log.push('m1')); }, 0);
      setTimeout(() => { log.push('t2'); res(); }, 0);
    });
    await p;
    return log.join(',');
  });

  // --- clearing ------------------------------------------------------------
  await TA('clearTimeout-stops-it', async () => {
    const log = [];
    const id = setTimeout(() => log.push('should-not-run'), 0);
    clearTimeout(id);
    await after(10);
    return log.length;
  });
  await TA('clearImmediate-stops-it', async () => {
    const log = [];
    const id = setImmediate(() => log.push('should-not-run'));
    clearImmediate(id);
    await after(10);
    return log.length;
  });
  await TA('clear-inside-own-callback', async () => {
    let n = 0;
    const id = setInterval(() => { n++; if (n >= 3) clearInterval(id); }, 1);
    await after(60);
    return n;
  });
  await TA('clearTimeout-undefined-is-safe', () => {
    clearTimeout(undefined);
    clearInterval(undefined);
    clearImmediate(undefined);
    return 'ok';
  });
  await TA('clear-twice-is-safe', async () => {
    const id = setTimeout(() => {}, 0);
    clearTimeout(id);
    clearTimeout(id);
    return 'ok';
  });

  // --- intervals -----------------------------------------------------------
  await TA('interval-repeats', async () => {
    let n = 0;
    const id = setInterval(() => n++, 1);
    await after(40);
    clearInterval(id);
    return n >= 3;
  });
  await TA('interval-cleared-stops', async () => {
    let n = 0;
    const id = setInterval(() => n++, 1);
    await after(20);
    clearInterval(id);
    const seen = n;
    await after(20);
    return n === seen;
  });

  // --- arguments and delays -----------------------------------------------
  await TA('extra-args-passed', async () => {
    const log = [];
    const p = new Promise((res) => setTimeout((a, b) => { log.push(a, b); res(); }, 0, 'x', 7));
    await p;
    return log;
  });
  await TA('immediate-args-passed', async () => {
    const log = [];
    const p = new Promise((res) => setImmediate((a) => { log.push(a); res(); }, 'im'));
    await p;
    return log;
  });
  await TA('negative-delay-runs', async () => {
    const p = new Promise((res) => setTimeout(() => res('ran'), -5));
    return await p;
  });
  await TA('nan-delay-runs', async () => {
    const p = new Promise((res) => setTimeout(() => res('ran'), NaN));
    return await p;
  });
  await TA('no-delay-runs', async () => {
    const p = new Promise((res) => setTimeout(() => res('ran')));
    return await p;
  });
  await TA('string-delay-coerced', async () => {
    const p = new Promise((res) => setTimeout(() => res('ran'), '1'));
    return await p;
  });

  // --- shapes --------------------------------------------------------------
  T('setTimeout-is-fn', typeof setTimeout);
  T('setInterval-is-fn', typeof setInterval);
  T('setImmediate-is-fn', typeof setImmediate);
  T('queueMicrotask-is-fn', typeof queueMicrotask);
  T('clearTimeout-is-fn', typeof clearTimeout);
  T('nextTick-is-fn', typeof process.nextTick);
  T('timeout-has-unref', (() => {
    const id = setTimeout(() => {}, 0);
    const r = typeof (id && id.unref);
    clearTimeout(id);
    return r;
  })());
  T('timeout-refresh', (() => {
    const id = setTimeout(() => {}, 0);
    const r = typeof (id && id.refresh);
    clearTimeout(id);
    return r;
  })());

  // --- errors --------------------------------------------------------------
  await TA('non-callable-throws', () => {
    try { setTimeout('not a function', 0); return 'accepted'; }
    catch (e) { return e.constructor.name; }
  });
  await TA('queueMicrotask-non-callable', () => {
    try { queueMicrotask(42); return 'accepted'; }
    catch (e) { return e.constructor.name; }
  });
  await TA('nextTick-extra-args', async () => {
    const log = [];
    const p = new Promise((res) => process.nextTick((a, b) => { log.push(a, b); res(); }, 1, 2));
    await p;
    return log;
  });

  // --- timers/promises -----------------------------------------------------
  await TA('timers-promises-setTimeout', async () => {
    const { setTimeout: delay } = require('timers/promises');
    return await delay(1, 'value');
  });
  await TA('timers-promises-immediate', async () => {
    const { setImmediate: soon } = require('timers/promises');
    return await soon('now');
  });

  console.log(rows.join('\n'));
}

main();

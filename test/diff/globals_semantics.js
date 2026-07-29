// The runtime environment: globalThis, process, and the timer and tick
// ordering that everything asynchronous is built on.
//
// Host-specific values (versions, pids, paths) are reported by shape only.
// Timer checks use distinct delays and compare ordering within one mechanism,
// never across two whose interleaving is unspecified.
//
// One ordering is deliberately NOT asserted: process.nextTick relative to
// queueMicrotask. node keeps nextTick in a queue of its own, drained around
// the microtask checkpoint rather than inside it, so the two interleave
// differently depending on what is already running. tsmc schedules a tick as
// an ordinary microtask, which is predictable but not the same. What is
// checked is what holds either way -- synchronous code first, timers last,
// and every callback run exactly once.

const out = [];

function show(v) {
  if (v === undefined) return 'undefined';
  if (v === null) return 'null';
  if (typeof v === 'string') return JSON.stringify(v);
  if (typeof v === 'bigint') return typeof v;
  if (typeof v === 'function') return 'fn';
  if (Array.isArray(v)) return '[' + v.map(show).join(', ') + ']';
  if (typeof v === 'object') { try { return JSON.stringify(v); } catch (e) { return String(v); } }
  return String(v);
}

function T(label, fn) {
  let v;
  try { v = fn(); } catch (e) {
    v = 'THROW:' + (e && e.constructor ? e.constructor.name : String(e));
  }
  out.push(label + ' = ' + show(v));
}

// --- globalThis -------------------------------------------------------------

T('globalThis-exists', () => typeof globalThis);
T('globalThis-self-reference', () => globalThis.globalThis === globalThis);
T('global-alias', () => typeof global === 'object' && global === globalThis);
T('builtins-are-properties', () => ['Object', 'Array', 'JSON', 'Math', 'Promise']
  .map((k) => typeof globalThis[k]).join(','));
// a value put on globalThis is reachable as a bare name, and the reverse
T('assign-then-read-bare', () => {
  globalThis.__probeA = 'viaGlobal';
  return __probeA;
});
T('declare-then-read-on-global', () => {
  __probeB = 'viaBare';
  return globalThis.__probeB;
});
T('mutation-is-shared', () => {
  globalThis.__probeC = 1;
  __probeC = 2;
  return [globalThis.__probeC, __probeC];
});
T('delete-from-global', () => {
  globalThis.__probeD = 'x';
  const had = typeof __probeD;
  delete globalThis.__probeD;
  return [had, typeof __probeD, 'in' in globalThis ? 'x' : ('__probeD' in globalThis)];
});
T('typeof-undeclared-is-undefined', () => typeof __neverDeclaredAnywhere);
T('reading-undeclared-throws', () => {
  try { return __neverDeclaredAnywhere2; } catch (e) { return 'THROW:' + e.constructor.name; }
});
T('globalThis-in-property', () => {
  globalThis.__probeE = 5;
  return ['__probeE' in globalThis, Object.prototype.hasOwnProperty.call(globalThis, '__probeE')];
});
T('var-visibility', () => typeof globalThis.__neverSetAtAll);

// --- process ----------------------------------------------------------------

T('process-shape', () => ['argv', 'env', 'platform', 'arch', 'version', 'versions', 'pid']
  .map((k) => k + ':' + typeof process[k]).join(' '));
T('argv-shape', () => [Array.isArray(process.argv), process.argv.length >= 2,
                       typeof process.argv[0], typeof process.argv[1]]);
T('env-read-write', () => {
  process.env.__PROBE_VAR = 'set';
  return [typeof process.env, process.env.__PROBE_VAR,
          process.env.__NOT_SET_ANYWHERE === undefined];
});
T('cwd', () => [typeof process.cwd(), process.cwd().length > 0]);
T('platform-values', () => ['win32', 'linux', 'darwin'].includes(process.platform));
T('version-shape', () => [typeof process.version, process.version.charAt(0),
                          typeof process.versions.node]);
T('pid', () => [typeof process.pid, process.pid > 0]);
T('exitCode-writable', () => {
  const before = process.exitCode;
  process.exitCode = 0;
  const after = process.exitCode;
  process.exitCode = before;
  return after;
});
T('hrtime', () => {
  if (typeof process.hrtime !== 'function') return 'missing';
  const a = process.hrtime();
  const b = process.hrtime(a);
  return [Array.isArray(a), a.length, Array.isArray(b), b[0] >= 0];
});
T('hrtime-bigint', () => {
  if (!process.hrtime || typeof process.hrtime.bigint !== 'function') return 'missing';
  const a = process.hrtime.bigint();
  return [typeof a, a > 0n];
});
T('uptime', () => typeof process.uptime === 'function' ? typeof process.uptime() : 'missing');
T('memoryUsage', () => typeof process.memoryUsage === 'function'
  ? typeof process.memoryUsage().heapUsed : 'missing');
T('stdout-shape', () => [typeof process.stdout, typeof process.stdout.write,
                         typeof process.stderr.write]);
T('nextTick-is-function', () => typeof process.nextTick);

// --- other globals ----------------------------------------------------------

T('queueMicrotask', () => typeof queueMicrotask);
T('structuredClone', () => {
  if (typeof structuredClone !== 'function') return 'missing';
  const src = { a: 1, b: [1, 2], d: new Date(0), m: new Map([['k', 'v']]) };
  const copy = structuredClone(src);
  return [copy.a, copy.b.join(','), copy.b !== src.b, copy.d instanceof Date,
          copy.m instanceof Map, copy.m.get('k')];
});
T('console-shape', () => ['log', 'error', 'warn', 'info', 'debug']
  .map((k) => typeof console[k]).join(','));
T('timer-functions', () => ['setTimeout', 'clearTimeout', 'setInterval', 'clearInterval',
                            'setImmediate', 'clearImmediate']
  .map((k) => k + ':' + typeof globalThis[k]).join(' '));

// --- ordering ---------------------------------------------------------------

const log = [];

function timers() {
  return new Promise((resolve) => {
    // distinct delays: later fires later, regardless of registration order
    setTimeout(() => log.push('t20'), 20);
    setTimeout(() => log.push('t1'), 1);
    setTimeout(() => log.push('t10'), 10);
    setTimeout(() => { log.push('t30'); resolve(); }, 30);
  });
}

function equalDelays() {
  return new Promise((resolve) => {
    // equal delays fire in registration order
    setTimeout(() => log.push('a'), 5);
    setTimeout(() => log.push('b'), 5);
    setTimeout(() => { log.push('c'); resolve(); }, 5);
  });
}

function cleared() {
  return new Promise((resolve) => {
    const id = setTimeout(() => log.push('SHOULD-NOT-RUN'), 5);
    clearTimeout(id);
    setTimeout(() => { log.push('after-clear'); resolve(); }, 15);
  });
}

function interval() {
  return new Promise((resolve) => {
    let n = 0;
    const id = setInterval(() => {
      n++;
      log.push('i' + n);
      if (n === 3) { clearInterval(id); resolve(); }
    }, 5);
  });
}

function timerArgs() {
  return new Promise((resolve) => {
    setTimeout((a, b) => { log.push('args:' + a + ':' + b); resolve(); }, 1, 'x', 'y');
  });
}

function tickOrder() {
  return new Promise((resolve) => {
    // every deferred mechanism runs after synchronous code and before a timer
    setTimeout(() => { log.push('timer'); resolve(); }, 5);
    Promise.resolve().then(() => log.push('promise'));
    process.nextTick(() => log.push('tick'));
    queueMicrotask(() => log.push('micro'));
    log.push('sync');
  });
}

// each group is collected before the next resets the shared log
const ordered = [];
async function run() {
  await timers();
  ordered.push('delays:' + log.join(','));
  log.length = 0;
  await equalDelays();
  ordered.push('equal:' + log.join(','));
  log.length = 0;
  await cleared();
  ordered.push('cleared:' + log.join(','));
  log.length = 0;
  await interval();
  ordered.push('interval:' + log.join(','));
  log.length = 0;
  await timerArgs();
  ordered.push('args:' + log.join(','));
  log.length = 0;
  await tickOrder();
  // the three deferred callbacks are compared as a set, since nextTick's
  // position among them is engine-specific (see the header)
  ordered.push('ticks-first:' + log[0]);
  ordered.push('ticks-last:' + log[log.length - 1]);
  ordered.push('ticks-deferred:' + log.slice(1, -1).sort().join(','));
  for (const line of ordered) out.push('order-' + line);
  console.log(out.join('\n'));
}

run();

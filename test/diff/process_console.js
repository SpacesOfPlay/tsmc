// process and console. Anything that depends on the machine is checked by
// shape, never by content, so the output is the same on any box.
//
// Left out, still divergent: process.env does not coerce a value to a
// string on assignment, and console.table is missing.

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
function T(label, fn) {
  let v;
  try { v = fn(); }
  catch (e) { v = 'THROW:' + (e && e.constructor ? e.constructor.name : String(e)); }
  rows.push(label + ' = ' + show(v));
}

// --- process shape ----------------------------------------------------------
T('process-is-object', () => typeof process);
T('argv-is-array', () => Array.isArray(process.argv));
T('argv-min-length', () => process.argv.length >= 2);
T('argv-entries-are-strings', () => process.argv.every((a) => typeof a === 'string'));
T('platform-type', () => typeof process.platform);
T('arch-type', () => typeof process.arch);
T('pid-type', () => typeof process.pid);
T('version-type', () => typeof process.version);
T('versions-type', () => typeof process.versions);
T('cwd-type', () => typeof process.cwd());
T('cwd-is-absolute', () => {
  const c = process.cwd();
  return c.length > 1 && (c[0] === '/' || /^[A-Za-z]:/.test(c));
});
T('uptime-type', () => typeof process.uptime());
T('exit-is-fn', () => typeof process.exit);
T('nextTick-is-fn', () => typeof process.nextTick);
T('exitCode-default', () => process.exitCode);
T('exitCode-settable', () => { process.exitCode = 0; return process.exitCode; });

// --- process.env ------------------------------------------------------------
T('env-is-object', () => typeof process.env);
T('env-roundtrip', () => { process.env.TSMC_PROBE = 'hi'; return process.env.TSMC_PROBE; });
T('env-delete', () => { process.env.TSMC_GONE = 'x'; delete process.env.TSMC_GONE; return process.env.TSMC_GONE; });
T('env-missing-is-undefined', () => process.env.TSMC_NEVER_SET_ANYWHERE);
T('env-in-operator', () => { process.env.TSMC_IN = '1'; return 'TSMC_IN' in process.env; });
T('env-keys-are-strings', () => Object.keys(process.env).every((k) => typeof k === 'string'));

// --- process streams --------------------------------------------------------
T('stdout-write-is-fn', () => typeof process.stdout.write);
T('stderr-write-is-fn', () => typeof process.stderr.write);
T('stdout-write-returns', () => typeof process.stdout.write(''));

// --- console shape ----------------------------------------------------------
T('console-log', () => typeof console.log);
T('console-error', () => typeof console.error);
T('console-warn', () => typeof console.warn);
T('console-info', () => typeof console.info);
T('console-debug', () => typeof console.debug);
T('console-trace', () => typeof console.trace);
T('console-dir', () => typeof console.dir);
T('console-assert', () => typeof console.assert);
T('console-group', () => typeof console.group);
T('console-count', () => typeof console.count);
T('console-time', () => typeof console.time);

console.log(rows.join('\n'));

// --- console output, compared as printed ------------------------------------
console.log('plain', 'two', 3);
console.log('%s and %s', 'a', 'b');
console.log('%d items', 5);
console.log('%i rounded', 5.9);
console.log('%f float', 1.5);
console.log('%j json', { a: 1 });
console.log('%o obj', { a: 1 });
console.log('%% literal');
console.log('%s extra', 'one', 'two');
console.log('%s missing');
console.log('%d not-a-number', 'abc');
console.log('no specifier', { a: 1 });
console.log(1, 'two', true, null, undefined);
console.log([1, 2, 3]);
console.log({ nested: { deep: { deeper: 1 } } });
console.log('');
console.log();

// --- util.format edge cases, which console.log now shares --------------------
console.log('', 'a', 'b');
console.log('%i', '');
console.log('%i', '12px');
console.log('%d', '');
console.log('%s', null, undefined);

// --- group, count, assert, dir ----------------------------------------------
console.group('Group A');
console.log('inside');
console.log({ multi: 1, line: 2 });
console.group();
console.log('deeper');
console.groupEnd();
console.log('back');
console.groupEnd();
console.log('outside');
console.count();
console.count();
console.count('x');
console.countReset();
console.count();
console.assert(true, 'not shown');
console.assert(false, 'shown %s', 'here');
console.assert(false);
console.dir({ a: { b: { c: 1 } } });

// Built-in os. Host values differ per machine, so shape and invariants are
// what is checked, never the content. That is also what lets the two runs
// agree: freemem and uptime move between them.
//
// Still missing, so left out: release, version, machine, networkInterfaces,
// getPriority, setPriority, constants.

const os = require('os');
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

// --- what exists ------------------------------------------------------------
for (const name of [
  'platform', 'arch', 'type', 'endianness', 'homedir', 'tmpdir', 'hostname',
  'cpus', 'userInfo', 'uptime', 'totalmem', 'freemem', 'loadavg',
  'availableParallelism',
]) T('has-' + name, () => typeof os[name]);
T('has-EOL', () => typeof os.EOL);
T('has-devNull', () => typeof os.devNull);

// --- values that must agree with the host ----------------------------------
T('platform-matches-process', () => os.platform() === process.platform);
T('arch-matches-process', () => os.arch() === process.arch);
T('endianness-value', () => os.endianness());
T('eol-is-newline-ish', () => os.EOL === '\n' || os.EOL === '\r\n');
T('homedir-nonempty', () => os.homedir().length > 0);
T('tmpdir-nonempty', () => os.tmpdir().length > 0);
T('tmpdir-no-trailing-sep', () => {
  const t = os.tmpdir();
  return t.length > 1 && t[t.length - 1] !== '/' && t[t.length - 1] !== '\\';
});
T('hostname-nonempty', () => os.hostname().length > 0);
T('type-nonempty', () => os.type().length > 0);

// --- cpus -------------------------------------------------------------------
T('cpus-is-array', () => Array.isArray(os.cpus()));
T('cpus-nonempty', () => os.cpus().length >= 1);
T('cpus-entry-shape', () => {
  const c = os.cpus()[0];
  return [typeof c.model, typeof c.speed, typeof c.times].join('/');
});
T('cpus-times-shape', () => {
  const t = os.cpus()[0].times;
  return ['user', 'nice', 'sys', 'idle', 'irq'].map((k) => typeof t[k]).join('/');
});

// --- userInfo ---------------------------------------------------------------
T('userinfo-shape', () => {
  const u = os.userInfo();
  return ['username', 'homedir', 'shell'].map((k) => typeof u[k]).join('/');
});
T('userinfo-ids-are-numbers', () => {
  const u = os.userInfo();
  return typeof u.uid + '/' + typeof u.gid;
});
T('userinfo-homedir-matches', () => os.userInfo().homedir === os.homedir());

// --- memory, uptime, load ---------------------------------------------------
T('totalmem-type', () => typeof os.totalmem());
T('totalmem-positive', () => os.totalmem() > 0);
T('freemem-type', () => typeof os.freemem());
T('freemem-not-above-total', () => os.freemem() <= os.totalmem());
T('uptime-type', () => typeof os.uptime());
T('uptime-positive', () => os.uptime() > 0);
T('loadavg-is-array', () => Array.isArray(os.loadavg()));
T('loadavg-length', () => os.loadavg().length);
T('loadavg-numbers', () => os.loadavg().every((n) => typeof n === 'number'));
T('parallelism-type', () => typeof os.availableParallelism());
T('parallelism-positive', () => os.availableParallelism() >= 1);
T('parallelism-matches-cpus', () => os.availableParallelism() === os.cpus().length);
T('devNull-value', () => os.devNull);

console.log(rows.join('\n'));

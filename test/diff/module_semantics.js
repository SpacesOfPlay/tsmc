// CommonJS: the module cache, the two ways of exporting, circular requires,
// and what a module knows about itself. Fixtures live in ./modfix.
//
// Paths are reported as basenames, since the absolute ones are host-specific.

const path = require('path');

const out = [];

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
  try { v = fn(); } catch (e) {
    v = 'THROW:' + (e && e.constructor ? e.constructor.name : String(e)) +
        (e && e.code ? ':' + e.code : '');
  }
  out.push(label + ' = ' + show(v));
}

const F = (n) => './modfix/' + n;

// --- the cache --------------------------------------------------------------

// A module body runs once; every later require hands back the same exports.
T('cache-same-object', () => {
  const a = require(F('counter.js'));
  const b = require(F('counter.js'));
  return [a === b, a.stamp === b.stamp, a.loads, b.loads];
});
T('cache-extension-optional', () => {
  const withExt = require(F('counter.js'));
  const without = require('./modfix/counter');
  return withExt === without;
});
T('cache-object-identity-survives-mutation', () => {
  const a = require(F('counter.js'));
  a.added = 'mutated';
  return require(F('counter.js')).added;
});
T('require-cache-exists', () => typeof require.cache);
T('require-resolve', () => typeof require.resolve === 'function'
  ? path.basename(require.resolve(F('counter.js'))) : 'missing');

// --- exporting --------------------------------------------------------------

T('module-exports-function', () => {
  const fn = require(F('reassign.js'));
  return [typeof fn, fn(), fn.extra];
});
// Reassigning module.exports detaches `exports`: anything written through the
// old alias after that point goes nowhere.
T('exports-alias-detached', () => {
  const m = require(F('alias.js'));
  return [m.after, m.before, m.stranded];
});

// --- circular requires ------------------------------------------------------

// b runs while a is only part-way through, so it sees a's exports as they
// stood at that moment -- the defining property of a cycle in CommonJS.
T('circular-partial-view', () => {
  const a = require(F('circ-a.js'));
  return [a.stage, a.sawFromB];
});

// --- what gets required -----------------------------------------------------

T('require-json', () => {
  const d = require(F('data.json'));
  return [d.name, d.nested.n, d.list.join('+'), typeof d];
});
T('require-json-cached', () => require(F('data.json')) === require(F('data.json')));
T('require-directory-index', () => require('./modfix/dir').from);
T('require-missing', () => {
  try { require('./modfix/nope.js'); return 'no-throw'; }
  catch (e) { return [e.constructor.name, e.code]; }
});
T('require-missing-package', () => {
  try { require('a-package-that-is-not-installed'); return 'no-throw'; }
  catch (e) { return [e.constructor.name, e.code]; }
});

// --- what a module knows about itself ---------------------------------------

// __dirname and __filename are per-module in node: a module resolving a path
// against its own location must not be handed the entry file's.
T('per-module-paths', () => {
  const p = require(F('paths.js'));
  return [p.dirBase, p.fileBase];
});
T('module-filename', () => require(F('paths.js')).moduleFileBase);
T('module-loaded-during-load', () => require(F('paths.js')).loadedDuringLoad);
T('this-module-paths', () => [path.basename(__dirname), path.basename(__filename)]);
T('module-object-shape', () => ['exports', 'id', 'filename', 'loaded']
  .map((k) => k + ':' + typeof module[k]).join(' '));
T('module-exports-is-exports', () => module.exports === exports);
T('require-is-function', () => [typeof require, typeof require.main]);

console.log(out.join('\n'));

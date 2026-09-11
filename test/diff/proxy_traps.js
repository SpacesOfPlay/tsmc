// Which handler traps an operation reaches. The ones checked here are the
// operations whose whole answer is one trap. Left out: the compositions the
// specification builds from several traps (a set through a receiver, a
// construct reading .prototype, an enumeration filtering by descriptor), and
// the invariant checks that hold a trap's answer against the target.

const log = [];
const handler = (names) => {
  const h = {};
  for (const n of names) h[n] = function (...a) { log.push(n); return Reflect[n](...a); };
  return h;
};
const all = ['get', 'set', 'has', 'deleteProperty', 'ownKeys', 'getOwnPropertyDescriptor',
  'defineProperty', 'getPrototypeOf', 'setPrototypeOf', 'isExtensible', 'preventExtensions',
  'apply', 'construct'];

const T = (l, f) => {
  log.length = 0;
  let out;
  try { out = String(f()); } catch (e) { out = 'threw ' + e.constructor.name; }
  console.log(l, '->', log.join(',') || '(none)', '|', out);
};

const p = () => new Proxy(function T() {}, handler(all));

T('get', () => p().x);
T('has', () => 'x' in p());
T('delete', () => delete p().x);
T('getOwnPropertyDescriptor', () => String(Object.getOwnPropertyDescriptor(p(), 'x')));
T('defineProperty', () => { Object.defineProperty(p(), 'y', { value: 1, configurable: true }); return 'defined'; });
T('getPrototypeOf', () => Object.getPrototypeOf(p()) === Function.prototype);
T('setPrototypeOf', () => { Object.setPrototypeOf(p(), null); return 'set'; });
T('isExtensible', () => Object.isExtensible(p()));
T('preventExtensions', () => { Object.preventExtensions(p()); return 'closed'; });
T('apply', () => { p()(); return 'called'; });
T('Reflect.isExtensible', () => Reflect.isExtensible(p()));
T('Reflect.preventExtensions', () => Reflect.preventExtensions(p()));
T('Reflect.setPrototypeOf', () => Reflect.setPrototypeOf(p(), null));

// a handler with no trap acts on the target
const bare = (t) => new Proxy(t, {});
const B = (l, f) => { try { console.log(l, '->', String(f())); } catch (e) { console.log(l, 'threw', e.constructor.name); } };
B('no isExtensible trap', () => Object.isExtensible(bare({})));
B('no preventExtensions trap', () => { const t = {}; Object.preventExtensions(bare(t)); return Object.isExtensible(t); });
B('no trap, the target closes', () => { const t = {}; const b = bare(t); Object.preventExtensions(b); return Object.isExtensible(b); });
B('no setPrototypeOf trap', () => { const t = {}; const q = {}; Object.setPrototypeOf(bare(t), q); return Object.getPrototypeOf(t) === q; });
B('no ownKeys trap', () => JSON.stringify(Object.getOwnPropertyNames(bare({ a: 1, b: 2 }))));

// a trap that refuses
B('preventExtensions says false', () => Reflect.preventExtensions(new Proxy({}, { preventExtensions: () => false })));
B('setPrototypeOf says false, reported', () => Reflect.setPrototypeOf(new Proxy({}, { setPrototypeOf: () => false }), null));
B('setPrototypeOf says false, thrown', () => { Object.setPrototypeOf(new Proxy({}, { setPrototypeOf: () => false }), null); return 'ok'; });
B('a trap that throws', () => Object.isExtensible(new Proxy({}, { isExtensible() { throw new RangeError('no'); } })));

// a function is an object for this purpose
B('a function is extensible', () => { const f = function () {}; return [Object.isExtensible(f), Reflect.isExtensible(f)].join(','); });
B('and can be closed', () => { const f = function () {}; Object.preventExtensions(f); return [Object.isExtensible(f), (() => { f.nope = 1; return typeof f.nope; })()].join(','); });
B('a closed function keeps what it had', () => { const f = function () {}; f.kept = 1; Object.preventExtensions(f); f.kept = 2; return f.kept; });
B('a strict write to a closed function', () => { 'use strict'; const f = function () {}; Object.preventExtensions(f); f.nope = 1; return 'added'; });
B('a native too', () => { const m = Math.max; return Object.isExtensible(m); });

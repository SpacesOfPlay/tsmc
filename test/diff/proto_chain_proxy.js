// A proxy on the prototype chain answers for everything past itself: an
// inherited read is its get trap, an inherited `in` its has trap. And an
// element an array does not have — past the end, or a hole — belongs to the
// prototype chain, proxy or not.

const log = [];
const traps = () => new Proxy({ onTarget: 'T', 0: 'zero' }, {
  get(t, k, r) { log.push('get ' + String(k)); return Reflect.get(t, k, r); },
  has(t, k) { log.push('has ' + String(k)); return Reflect.has(t, k); },
});

const R = (label, f) => {
  log.length = 0;
  let out;
  try { out = String(f()); } catch (e) { out = 'threw ' + e.constructor.name; }
  console.log(label, '->', log.join(',') || '(none)', '|', out);
};
const T = (l, f) => {
  try { console.log(l, '->', String(f())); }
  catch (e) { console.log(l, 'threw', e.constructor.name); }
};

R('an inherited read', () => Object.create(traps()).onTarget);
R('an inherited miss', () => Object.create(traps()).nope);
R('an inherited in', () => 'onTarget' in Object.create(traps()));
R('an inherited in, missing', () => 'nope' in Object.create(traps()));
R('two levels down', () => Object.create(Object.create(traps())).onTarget);
R('an own property shadows it', () => { const o = Object.create(traps()); o.onTarget = 'own'; return o.onTarget; });
R('an index name', () => Object.create(traps())[0]);
R('a symbol', () => { const s = Symbol('s'); return Object.create(traps())[s]; });
R('a method reached through it', () => {
  const p = new Proxy({ m() { return 'called'; } }, {});
  return Object.create(p).m();
});
R('after setPrototypeOf', () => { const o = {}; Object.setPrototypeOf(o, traps()); return o.onTarget; });

T('a class whose prototype inherits one', () => {
  const p = new Proxy({ inherited: 'I' }, {});
  class C {}
  Object.setPrototypeOf(C.prototype, p);
  return new C().inherited;
});

// a handler with no trap reaches whatever the target is
T('a function target', () => ['name' in new Proxy(function f() {}, {}), 'nope' in new Proxy(function f() {}, {})].join(','));
T('a proxy target', () => 'a' in new Proxy(new Proxy({ a: 1 }, {}), {}));
T('an undefined trap', () => 'a' in new Proxy({ a: 1 }, { has: undefined }));
T('a null trap over a proxy target', () => 'a' in new Proxy(new Proxy({ a: 1 }, {}), { has: null }));
T('a trap that is not callable', () => 'a' in new Proxy({}, { has: 1 }));
T('delete through a proxy target', () => {
  const t = { a: 1 };
  const p = new Proxy(new Proxy(t, {}), {});
  return [delete p.a, 'a' in t].join(',');
});

// an array's absent elements come from its prototype
T('past the end', () => { const a = []; Object.setPrototypeOf(a, { 5: 'five', n: 'N' }); return JSON.stringify([a[5], 5 in a, a.n, a[0]]); });
T('a hole in range', () => { const b = [1, , 3]; Object.setPrototypeOf(b, { 1: 'proto' }); return JSON.stringify([b[1], 1 in b, b.length]); });
T('a present element still wins', () => { const c = [7]; Object.setPrototypeOf(c, { 0: 'proto' }); return JSON.stringify([c[0], 0 in c]); });
T('through a proxy prototype', () => { const p = new Proxy({ 5: 'five' }, {}); const a = []; Object.setPrototypeOf(a, p); return JSON.stringify([a[5], 5 in a]); });
T('Array.prototype is not shadowed', () => { const a = [1, 2]; return [a.length, typeof a.map].join(','); });
T('a hole still reads undefined with no prototype', () => { const d = [1, , 3]; return JSON.stringify([d[1], 1 in d]); });

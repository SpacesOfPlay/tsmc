// A class field is defined, not assigned, so a proxy standing in for the
// instance sees its defineProperty trap and not its set trap. A private
// member is the other way round: the proxy carries no brand of its own, so
// it cannot be reached through one.

const T = (l, f) => {
  try { console.log(l, '->', String(f())); }
  catch (e) { console.log(l, 'threw', e.constructor.name); }
};

const logging = (log) => ({
  defineProperty(t, k, d) {
    log.push('define ' + String(k) + ' ' + JSON.stringify([d.value, d.writable, d.enumerable, d.configurable]));
    return Reflect.defineProperty(t, k, d);
  },
  set(t, k, v) { log.push('set ' + String(k)); return Reflect.set(t, k, v); },
});

T('a field on a proxy receiver', () => {
  const log = [];
  class Base { constructor() { return new Proxy({}, logging(log)); } }
  class C extends Base { f = 1; }
  const c = new C();
  return [log.join(' | '), c.f].join(' -> ');
});
T('a computed field', () => {
  const log = [];
  class Base { constructor() { return new Proxy({}, logging(log)); } }
  class C extends Base { ['g'] = 2; }
  return [log.join(' | '), new C().g].join(' -> ');
});
T('several, in order', () => {
  const log = [];
  class Base { constructor() { return new Proxy({}, logging(log)); } }
  class C extends Base { a = 1; b = 2; ['c'] = 3; }
  new C();
  return log.length;
});
T('a trap that refuses', () => {
  class Base { constructor() { return new Proxy({}, { defineProperty: () => false }); } }
  class C extends Base { f = 1; }
  return new C().f;
});
T('a trap that throws', () => {
  class Base { constructor() { return new Proxy({}, { defineProperty() { throw new RangeError('no'); } }); } }
  class C extends Base { f = 1; }
  return new C().f;
});
T('no trap falls through to the target', () => {
  const target = {};
  class Base { constructor() { return new Proxy(target, {}); } }
  class C extends Base { f = 1; }
  new C();
  return JSON.stringify(Object.getOwnPropertyDescriptor(target, 'f'));
});
T('an object literal is unaffected', () => {
  const log = [];
  const p = new Proxy({}, logging(log));
  p.x = 1;
  return [log.join(' | '), p.x].join(' -> ');
});
T('Object.defineProperty still traps', () => {
  const log = [];
  const p = new Proxy({}, logging(log));
  Object.defineProperty(p, 'y', { value: 2, configurable: true });
  return [log.length, p.y].join(',');
});

// a private member belongs to the object it was installed on
T('a private field through a proxy', () => {
  class C { #x = 1; static read(o) { return o.#x; } }
  return C.read(new Proxy(new C(), {}));
});
T('a private method through a proxy', () => {
  class C { #m() { return 1; } static call(o) { return o.#m(); } }
  return C.call(new Proxy(new C(), {}));
});
T('a private getter through a proxy', () => {
  class C { get #g() { return 1; } static read(o) { return o.#g; } }
  return C.read(new Proxy(new C(), {}));
});
T('the brand check', () => {
  class C { #x = 1; static has(o) { return #x in o; } }
  const c = new C();
  return [C.has(c), C.has(new Proxy(c, {}))].join(',');
});
T('the target itself is fine', () => {
  class C { #x = 1; static read(o) { return o.#x; } }
  const c = new C();
  const p = new Proxy(c, {});
  return [C.read(c), typeof p].join(',');
});

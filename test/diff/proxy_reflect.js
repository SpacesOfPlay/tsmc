// Proxy traps and their Reflect counterparts, including which operations a
// trap is expected to intercept and what happens with no handler.

const rows = [];
function T(label, fn) {
  let v;
  try { v = fn(); }
  catch (e) { v = 'THROW:' + (e && e.constructor ? e.constructor.name : String(e)); }
  try { v = JSON.stringify(v); } catch (e) { v = String(v); }
  rows.push(label + ' = ' + v);
}

// get / set.
T('get-trap', () => { const p = new Proxy({}, { get: (t, k) => k === 'x' ? 1 : 2 }); return [p.x, p.y]; });
T('get-receives-target', () => { const p = new Proxy({ v: 5 }, { get: (t, k) => t[k] }); return p.v; });
T('get-passthrough', () => new Proxy({ a: 1 }, {}).a);
T('set-trap', () => { const log = []; const p = new Proxy({}, { set: (t, k, v) => { log.push(k + '=' + v); t[k] = v; return true; } }); p.a = 1; return [log, p.a]; });
T('set-passthrough', () => { const t = {}; const p = new Proxy(t, {}); p.a = 1; return t.a; });
T('get-computed', () => { const p = new Proxy({}, { get: (t, k) => String(k) }); return p['dyn']; });

// has / deleteProperty.
T('has-trap', () => { const p = new Proxy({}, { has: () => true }); return ['zz' in p, 'a' in p]; });
T('has-passthrough', () => { const p = new Proxy({ a: 1 }, {}); return ['a' in p, 'b' in p]; });
T('delete-trap', () => { const log = []; const p = new Proxy({ a: 1 }, { deleteProperty: (t, k) => { log.push(k); delete t[k]; return true; } }); delete p.a; return log; });
T('delete-computed', () => { const log = []; const p = new Proxy({ a: 1 }, { deleteProperty: (t, k) => { log.push(k); return true; } }); delete p['a']; return log; });

// ownKeys and enumeration.
T('ownKeys-trap', () => { const p = new Proxy({ a: 1 }, { ownKeys: () => ['a'] }); return Object.keys(p); });
T('ownKeys-for-in', () => { const p = new Proxy({ a: 1, b: 2 }, { ownKeys: () => ['a', 'b'] }); const k = []; for (const x in p) k.push(x); return k; });
T('ownKeys-spread', () => { const p = new Proxy({ a: 1, b: 2 }, {}); return { ...p }; });
T('ownKeys-json', () => JSON.stringify(new Proxy({ a: 1 }, {})));
T('ownKeys-values', () => Object.values(new Proxy({ a: 1 }, {})));
T('ownKeys-entries', () => Object.entries(new Proxy({ a: 1 }, {})));
T('ownKeys-assign', () => Object.assign({}, new Proxy({ a: 1 }, {})));

// Descriptors.
T('getOwnPropertyDescriptor-trap', () => {
  const p = new Proxy({}, { getOwnPropertyDescriptor: () => ({ value: 9, configurable: true, enumerable: true }) });
  return Object.getOwnPropertyDescriptor(p, 'any').value;
});
T('defineProperty-trap', () => { const log = []; const p = new Proxy({}, { defineProperty: (t, k, d) => { log.push(k); return true; } }); Object.defineProperty(p, 'x', { value: 1 }); return log; });

// Prototype and extensibility.
T('getPrototypeOf-passthrough', () => Object.getPrototypeOf(new Proxy({}, {})) === Object.prototype);
T('instanceof-through-proxy', () => { class C { } return new Proxy(new C(), {}) instanceof C; });

// apply / construct.
T('apply-trap', () => { const p = new Proxy(function () { return 'orig'; }, { apply: () => 'trapped' }); return p(); });
T('apply-args', () => { const p = new Proxy(function () { }, { apply: (t, thisArg, args) => args.join(',') }); return p(1, 2); });
T('apply-passthrough', () => new Proxy((a, b) => a + b, {})(1, 2));
T('construct-trap', () => { const p = new Proxy(class { }, { construct: () => ({ made: true }) }); return new p().made; });
T('construct-passthrough', () => { class C { constructor(x) { this.x = x; } } return new (new Proxy(C, {}))(5).x; });
T('callable-typeof', () => [typeof new Proxy(function () { }, {}), typeof new Proxy({}, {})]);
T('proxy-of-array-isArray', () => Array.isArray(new Proxy([], {})));
T('proxy-of-array-json', () => JSON.stringify(new Proxy([1, 2], {})));
T('proxy-of-array-length', () => new Proxy([1, 2], {}).length);

// revocable.
T('revocable', () => { const { proxy, revoke } = Proxy.revocable({ a: 1 }, {}); const before = proxy.a; revoke(); let after; try { proxy.a; after = 'no-throw'; } catch (e) { after = e.constructor.name; } return [before, after]; });

// Reflect parity.
T('reflect-get', () => Reflect.get({ a: 1 }, 'a'));
T('reflect-get-default', () => Reflect.get({}, 'zz'));
T('reflect-set', () => { const o = {}; const ok = Reflect.set(o, 'a', 1); return [ok, o.a]; });
T('reflect-has', () => [Reflect.has({ a: 1 }, 'a'), Reflect.has({}, 'a')]);
T('reflect-deleteProperty', () => { const o = { a: 1 }; return [Reflect.deleteProperty(o, 'a'), o.a]; });
T('reflect-ownKeys', () => Reflect.ownKeys({ a: 1, b: 2 }));
T('reflect-ownKeys-nonenum', () => { const o = {}; Object.defineProperty(o, 'h', { value: 1 }); return Reflect.ownKeys(o); });
T('reflect-getPrototypeOf', () => Reflect.getPrototypeOf([]) === Array.prototype);
T('reflect-setPrototypeOf', () => { const o = {}; Reflect.setPrototypeOf(o, { q: 1 }); return o.q; });
T('reflect-defineProperty', () => { const o = {}; const ok = Reflect.defineProperty(o, 'x', { value: 1 }); return [ok, o.x]; });
T('reflect-getOwnPropertyDescriptor', () => Reflect.getOwnPropertyDescriptor({ a: 1 }, 'a').value);
T('reflect-apply', () => Reflect.apply((a, b) => a + b, null, [1, 2]));
T('reflect-apply-this', () => Reflect.apply(function () { return this.t; }, { t: 'x' }, []));
T('reflect-construct', () => { class C { constructor(x) { this.x = x; } } return Reflect.construct(C, [3]).x; });
T('reflect-construct-newtarget', () => { class A { constructor() { this.n = new.target.name; } } class B { } return Reflect.construct(A, [], B).n; });
T('reflect-isExtensible', () => [Reflect.isExtensible({}), Reflect.isExtensible(Object.freeze({}))]);
T('reflect-preventExtensions', () => { const o = {}; Reflect.preventExtensions(o); return Reflect.isExtensible(o); });
T('reflect-on-function', () => Reflect.get(function f() { }, 'name'));
T('reflect-non-object', () => Reflect.get(5, 'x'));

console.log(rows.join('\n'));

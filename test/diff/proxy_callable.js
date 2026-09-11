// A proxy whose target is callable is a function everywhere, not only at a
// direct call: Function.prototype's methods reach it, Reflect.apply reaches
// it, and it sits on Function.prototype's chain.

const T = (l, f) => {
  try { console.log(l, '->', String(f())); }
  catch (e) { console.log(l, 'threw', e.constructor.name); }
};

const target = function (a, b) { return 'target ' + a + b; };
const trapped = new Proxy(target, { apply(t, c, args) { return 'trap ' + args.join('/') + ' this=' + (c && c.tag); } });
const bare = new Proxy(target, {});

T('typeof', () => [typeof trapped, typeof bare].join(','));
T('a direct call', () => trapped(1, 2));
T('a direct call, no trap', () => bare(1, 2));
T('call', () => trapped.call({ tag: 'ctx' }, 1, 2));
T('call, no trap', () => bare.call({ tag: 'ctx' }, 1, 2));
T('apply', () => trapped.apply({ tag: 'ctx' }, [1, 2]));
T('bind', () => trapped.bind({ tag: 'ctx' }, 1)(2));
T('Reflect.apply', () => Reflect.apply(trapped, { tag: 'ctx' }, [1, 2]));
T('call, borrowed', () => Function.prototype.call.call(trapped, { tag: 'ctx' }, 1, 2));
T('apply, borrowed', () => Function.prototype.apply.call(trapped, { tag: 'ctx' }, [1, 2]));
T('name and length come from the target', () => JSON.stringify([trapped.name, trapped.length]));
T('instanceof Function', () => [trapped instanceof Function, bare instanceof Function].join(','));
T('Function.prototype.isPrototypeOf', () => Function.prototype.isPrototypeOf(trapped));
T('the prototype it reports', () => Object.getPrototypeOf(bare) === Function.prototype);
T('a proxy of a proxy', () => { const pp = new Proxy(trapped, {}); return [typeof pp, pp(3, 4), pp instanceof Function].join(','); });
T('a class as the target', () => {
  class C { constructor(x) { this.x = x; } }
  const p = new Proxy(C, {});
  const made = new p(5);
  return [made.x, made instanceof C, made instanceof p].join(',');
});
T('a construct trap', () => {
  class C {}
  const p = new Proxy(C, { construct: (t, args) => ({ made: args[0] }) });
  return new p(7).made;
});
T('a non-callable target is not callable', () => { const p = new Proxy({}, {}); return typeof p; });
T('and calling it throws', () => { const p = new Proxy({}, {}); return p(); });
T('a method on a proxied object', () => {
  const o = { m() { return this === p2 ? 'proxy this' : 'other this'; } };
  const p2 = new Proxy(o, {});
  return p2.m();
});
T('sort through a proxied comparator', () => [3, 1, 2].sort(new Proxy((a, b) => a - b, {})).join(','));
T('map through one', () => [1, 2].map(new Proxy((x) => x * 2, {})).join(','));

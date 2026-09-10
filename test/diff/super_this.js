// A base constructor that returns an object of its own settles what the
// derived constructor's `this` is, so the fields and private methods are
// installed on that object and it is what `new` hands back.

const T = (l, f) => {
  try { console.log(l, '->', String(f())); }
  catch (e) { console.log(l, 'threw', e.constructor.name); }
};

class Base { constructor(o) { return o; } }

T('this is the returned object', () => {
  const o = { tag: 'given' };
  let seen;
  class D extends Base { constructor(x) { super(x); seen = this === o; } }
  new D(o);
  return seen;
});

T('new hands it back', () => {
  const o = {};
  class D extends Base {}
  return new D(o) === o;
});

T('fields land on it', () => {
  const o = {};
  class D extends Base { f = 1; ['c'] = 2; }
  new D(o);
  return [o.f, o.c].join(',');
});

T('a private method lands on it', () => {
  const o = {};
  class D extends Base { #m() { return 'm'; } static has(x) { return #m in x; } }
  new D(o);
  return D.has(o);
});

T('installing twice is refused', () => {
  const o = {};
  class D extends Base { #m() {} }
  new D(o);
  new D(o);
  return 'no throw';
});

T('a field twice is refused too', () => {
  const o = {};
  class D extends Base { #f = 1; }
  new D(o);
  new D(o);
  return 'no throw';
});

T('a plain return is ignored', () => {
  class B2 { constructor() { return 1; } }
  class D extends B2 { f = 1; }
  const d = new D();
  return [d instanceof D, d.f].join(',');
});

T('through a spread call', () => {
  const o = {};
  class D extends Base { constructor(...a) { super(...a); } f = 3; }
  return [new D(o) === o, o.f].join(',');
});

T('two levels deep', () => {
  const o = { tag: 'deep' };
  class Mid extends Base { m = 1; }
  class Leaf extends Mid { l = 2; }
  const made = new Leaf(o);
  return [made === o, o.m, o.l].join(',');
});

T('a derived constructor of its own', () => {
  class D extends Base { constructor() { super(undefined); return { own: 1 }; } }
  return new D().own;
});

// what the constructor returns still governs a plain class
T('base returning an object', () => {
  class B3 { constructor() { return { tag: 'other' }; } f = 1; }
  const b = new B3();
  return [b.tag, b.f].join(',');
});

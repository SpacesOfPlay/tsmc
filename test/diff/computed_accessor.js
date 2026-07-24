// Computed accessors: `get [expr]() {}` / `set [expr](v) {}` in both class
// bodies and object literals.

const k = 'x';
const sym = Symbol('s');
const prefix = 'da';

class C {
  get [k]() { return 1; }
  set [k](v) { this._x = v; }
  get [sym]() { return 'sym'; }
  static get ['sk']() { return 'static'; }
  static set ['sk'](v) { C._sk = v; }
  get [prefix + 'ta']() { return 'concat'; }
}

const c = new C();
console.log('class get:', c.x);
c.x = 9;
console.log('class set:', c._x);
console.log('symbol key:', c[sym]);
console.log('static get:', C.sk);
C.sk = 'set!';
console.log('static set:', C._sk);
console.log('expression key:', c.data);

// get and set with the same computed key land on one accessor property.
const d = Object.getOwnPropertyDescriptor(C.prototype, 'x');
console.log('one property:', typeof d.get, typeof d.set, d.enumerable);

const o = {
  get [k]() { return 2; },
  set [k](v) { this._o = v; },
  get [sym]() { return 'osym'; },
  get [prefix + 'ta']() { return 'oconcat'; },
};
console.log('object get:', o.x);
o.x = 7;
console.log('object set:', o._o);
console.log('object symbol:', o[sym]);
console.log('object expression key:', o.data);

const od = Object.getOwnPropertyDescriptor(o, 'x');
console.log('object descriptor:', typeof od.get, typeof od.set, od.enumerable);

// Non-computed accessors are unchanged.
class P {
  get a() { return 'A'; }
  set a(v) { this._a = v; }
}
const p = new P();
p.a = 3;
console.log('plain class:', p.a, p._a);

const po = { get b() { return 'B'; }, set b(v) { this._b = v; } };
po.b = 4;
console.log('plain object:', po.b, po._b);

// A computed key is evaluated once, in source order.
const order = [];
function key(name) { order.push(name); return name; }
const seq = {
  get [key('first')]() { return 1; },
  [key('middle')]: 2,
  set [key('last')](v) {},
};
console.log('key order:', order.join(','));

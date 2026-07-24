// `super[expr]` — the computed form of `super.name`, as a read and as a call.

class P {
  greet() { return 'P.greet'; }
  add(a, b) { return a + b; }
  get val() { return 'P.val'; }
  [Symbol.iterator]() { return 'P.iter'; }
}

const K = 'greet';

class C extends P {
  greet() { return 'C+' + super[K](); }
  readVal() { return super['val']; }
  dyn(name) { return super[name](); }
  args(a, b) { return super['add'](a, b) * 2; }
  missing() { return super['nope'] === undefined; }
  spread(...xs) { return super['add'](...xs); }
  [Symbol.iterator]() { return 'C+' + super[Symbol.iterator](); }
}

const c = new C();
console.log('call:', c.greet());
console.log('read getter:', c.readVal());
console.log('dynamic name:', c.dyn('greet'));
console.log('arguments:', c.args(3, 4));
console.log('missing key:', c.missing());
console.log('spread args:', c.spread(5, 6));
console.log('symbol key:', c[Symbol.iterator]());

// `this` is the receiver, not the parent prototype.
class Q { who() { return this.tag; } }
class R extends Q {
  tag = 'R';
  who() { return super['who'](); }
}
console.log('receiver:', new R().who());

// super.name still behaves the same.
class D extends P {
  greet() { return 'D+' + super.greet(); }
  readVal() { return super.val; }
}
const d = new D();
console.log('dotted call:', d.greet());
console.log('dotted getter:', d.readVal());

// A computed super key is an ordinary expression.
class E extends P {
  greet() { return super['gr' + 'eet'](); }
}
console.log('expression key:', new E().greet());

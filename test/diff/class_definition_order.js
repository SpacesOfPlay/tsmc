// What a class body does, and when. Every computed key is evaluated once,
// in source order, as the class is defined; the methods are all in place
// before any static initializer runs; and static fields and static blocks
// run in the order they were written.

const log = [];
const k = (s) => { log.push(s); return s; };

class A {
  [k('a')] = 1;
  static [k('b')] = 2;
  [k('c')]() {}
  static { log.push('block'); }
  [k('d')] = 3;
  static [k('e')] = 4;
}
console.log('order:', log.join(','));

// the keys are evaluated when the class is defined, not per instance
let n = 0;
class B { [(n++, 'x')] = 1; }
console.log('before any instance:', n);
new B(); new B();
console.log('after two instances:', n);

// a static initializer sees every method
class C {
  static a = typeof C.prototype.m + ',' + typeof C.s;
  m() {}
  static s() {}
}
console.log('static sees methods:', C.a);

// a field is defined, so an inherited setter does not run
class D { set x(v) { console.log('SETTER RAN'); } }
class E extends D { x = 1; ['y'] = 2; }
const e = new E();
console.log('field descriptor:', JSON.stringify(Object.getOwnPropertyDescriptor(e, 'x')));
console.log('computed field descriptor:', JSON.stringify(Object.getOwnPropertyDescriptor(e, 'y')));

// an anonymous initializer takes the name of the key it is stored under
class F {
  f = function () {};
  g = () => {};
  #p = function () {};
  'str' = function () {};
  3 = function () {};
  static s = function () {};
  static [k('sk')] = function () {};
  #m() {}
  names() { return [this.#p.name, this.#m.name]; }
}
const f = new F();
console.log('names:', JSON.stringify([f.f.name, f.g.name, f.str.name, f[3].name, F.s.name, F.sk.name]));
console.log('private names:', JSON.stringify(f.names()));

// the class binding is still uninitialized while the keys are evaluated,
// and in place by the time a static initializer runs
try {
  class G { static [typeof G] = 1; }
} catch (err) {
  console.log('name during keys:', err.constructor.name);
}
class I { static self = I; static [ 'k' ] = typeof I; }
console.log('name during static init:', I.self === I, I.k);

// an abrupt key stops the definition where it happened
const order = [];
try {
  class H {
    [order.push('one') && 'p']() {}
    [(() => { throw new RangeError('key'); })()]() {}
    [order.push('three') && 'q']() {}
  }
} catch (err) {
  console.log('abrupt key:', err.constructor.name, 'after', order.join(','));
}

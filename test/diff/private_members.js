// A private method belongs to the object it was installed on, not to the
// prototype: an object that merely inherits from the prototype does not
// carry the brand. A method cannot be written to, a getter-only cannot be
// read from the other side, and only a field is writable.

const T = (l, f) => {
  try { console.log(l, '->', String(f())); }
  catch (e) { console.log(l, 'threw', e.constructor.name); }
};

class A {
  #f = 1;
  #m() { return 'm'; }
  get #g() { return 'g'; }
  set #s(v) { this.seen = v; }
  get #both() { return this.#f; }
  set #both(v) { this.#f = v; }

  static has(o) { return #m in o; }
  static hasField(o) { return #f in o; }
  static call(o) { return o.#m(); }

  read() { return [this.#f, this.#m(), this.#g].join(','); }
  writeMethod() { this.#m = 1; }
  writeGetter() { this.#g = 1; }
  readSetter() { return this.#s; }
  useSetter() { this.#s = 7; return this.seen; }
  pair() { this.#both = 5; return this.#both; }
  writeField() { this.#f = 9; return this.#f; }
}

const a = new A();
T('read', () => a.read());
T('own names', () => JSON.stringify(Object.getOwnPropertyNames(a)));
T('prototype names', () => JSON.stringify(Object.getOwnPropertyNames(A.prototype)));
T('brand on an instance', () => A.has(a));
T('brand on an heir of the prototype', () => A.has(Object.create(A.prototype)));
T('field on an heir of the prototype', () => A.hasField(Object.create(A.prototype)));
T('call through an heir', () => A.call(Object.create(A.prototype)));
T('brand on a plain object', () => A.has({}));
T('write to a method', () => a.writeMethod());
T('write to a getter-only', () => a.writeGetter());
T('read a setter-only', () => a.readSetter());
T('use the setter', () => a.useSetter());
T('a getter/setter pair', () => a.pair());
T('write to a field', () => a.writeField());

// static private members live on the class, and a subclass is not the class
class B {
  static #sf = 1;
  static #sm() { return 'sm'; }
  static get #sg() { return 'sg'; }
  static read() { return [B.#sf, B.#sm(), B.#sg].join(','); }
  static readFrom(o) { return o.#sf; }
  static callFrom(o) { return o.#sm(); }
  static has(o) { return #sm in o; }
}
class Sub extends B {}
T('static read', () => B.read());
T('static brand on the class', () => B.has(B));
T('static brand on a subclass', () => B.has(Sub));
T('static read through a subclass', () => B.readFrom(Sub));
T('static call through a subclass', () => B.callFrom(Sub));

// a nested class may use the same spelling for something else
class Outer {
  #x() { return 'outer'; }
  static probe() {
    class Inner { get #x() { return 'inner'; } static has(o) { return #x in o; } }
    return Inner.has(new Outer());
  }
  static has(o) { return #x in o; }
}
T('the inner name is not the outer one', () => Outer.probe());
T('the outer name still holds', () => Outer.has(new Outer()));

// the names an anonymous private member takes
class C {
  #p = function () {};
  #m() {}
  get #g() { return 1; }
  set #s(v) {}
  static #sm() {}
  names() { return JSON.stringify([this.#p.name, this.#m.name]); }
  descs() {
    const d = Object.getOwnPropertyDescriptor(this, 'x');
    return String(d);
  }
  static staticName() { return C.#sm.name; }
}
T('private names', () => new C().names());
T('static private name', () => C.staticName());

// two instances get their own installations, and one object gets one
class D { #v = 0; static bump(o) { return ++o.#v; } }
const d1 = new D(), d2 = new D();
T('separate instances', () => [D.bump(d1), D.bump(d1), D.bump(d2)].join(','));

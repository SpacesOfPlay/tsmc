// A private name belongs to the class that declares it. Reading, writing
// or calling it on an object of another class is a TypeError; two classes
// may use one name for different things; the check reaches methods,
// accessors, statics and every form of assignment.

const attempt = (f) => { try { return String(f()); } catch (e) { return e.constructor.name + ': ' + e.message; } };

class A {
  #x = 'A.x';
  #n = 1;
  #m() { return 'A.m'; }
  static #s = 'A.s';
  static #sm() { return 'A.sm'; }
  static read(o) { return o.#x; }
  static call(o) { return o.#m(); }
  static write(o, v) { o.#x = v; return o.#x; }
  static add(o) { o.#x += '!'; return o.#x; }
  static inc(o) { return ++o.#n; }
  static logical(o) { o.#x ??= 'set'; return o.#x; }
  static destr(o) { [o.#x] = ['from array']; return o.#x; }
  static has(o) { return #x in o; }
  static statics(k) { return [k.#s, k.#sm()]; }
  static optional(o) { return o?.#x; }
}
class B {
  #x = 'B.x';
  static read(o) { return o.#x; }
  static has(o) { return #x in o; }
}
const a = new A(), b = new B();
console.log(A.read(a), B.read(b), A.has(a), A.has(b), B.has(a), B.has(b));
console.log(attempt(() => A.read(b)));
console.log(attempt(() => A.read({})));
console.log(attempt(() => A.call(b)));
console.log(attempt(() => A.write(b, 1)));
console.log(attempt(() => A.add(b)));
console.log(attempt(() => A.inc(b)));
console.log(attempt(() => A.logical(b)));
console.log(attempt(() => A.destr(b)));
console.log(A.optional(null), attempt(() => A.optional(b)));
console.log(A.write(a, 'w'), A.add(a), A.inc(a), A.logical(a), A.destr(a), A.call(a));
console.log(A.statics(A).join(','), attempt(() => A.statics(B)), attempt(() => A.statics(a)));

// a nested class sees the enclosing class's names as well as its own,
// and a name it declares itself shadows the outer one
class Outer {
  #o = 'outer';
  #shadowed = 'outer';
  make() {
    const self = this;
    return class Inner {
      #i = 'inner';
      #shadowed = 'inner';
      read() { return [self.#o, this.#i, this.#shadowed]; }
      outer() { return self.#shadowed; }
    };
  }
}
const Inner = new Outer().make();
console.log(new Inner().read().join(','), attempt(() => new Inner().outer()));

// a subclass instance carries the base class's names
class Base {
  #b = 'b';
  #bm() { return 'bm'; }
  get() { return this.#b; }
  callm() { return this.#bm(); }
}
class Sub extends Base {}
console.log(new Sub().get(), new Sub().callm(), attempt(() => Base.prototype.get.call({})));

// accessors are checked like fields
class Acc {
  get #v() { return 'acc'; }
  set #v(x) { this.last = x; }
  static go(o) { o.#v = 1; return [o.#v, o.last]; }
}
console.log(Acc.go(new Acc()).join(','), attempt(() => Acc.go({})));

// a class expression's names work for the class it produced
const mk = () => class { #p = 'p'; static read(o) { return o.#p; } };
const C1 = mk();
console.log(C1.read(new C1()));

// the field is defined at construction, before the constructor body reads it
class Ctor { #f = 'field'; constructor() { this.seen = this.#f; } }
console.log(new Ctor().seen);

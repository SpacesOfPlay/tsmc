// A static member's home object is the class, so `super.x` there reads the
// parent class rather than the parent's prototype, and `this` is the class.
// A static field whose value happens to be a function is still a field.

const T = (l, f) => {
  try { console.log(l, '->', String(f())); }
  catch (e) { console.log(l, 'threw', e.constructor.name); }
};

class Base {
  static sm() { return 'base-sm'; }
  static get sg() { return 'base-sg'; }
  static sv = 'base-sv';
  m() { return 'base-m'; }
  static ['computed']() { return 'base-computed'; }
}

class D extends Base {
  static viaMethod() { return super.sm(); }
  static viaGetter() { return super.sg; }
  static viaIndex() { return super['sm'](); }
  static viaValue() { return super.sv; }
  static viaComputedName() { return super.computed(); }
  static get accessor() { return super.sm(); }
  static viaArrowInMethod() { return (() => super.sm())(); }
  static field = super.sm();
  static arrowField = () => super.sm();
  static { D.fromBlock = super.sm(); }
  viaInstance() { return super.m(); }
  instanceField = super.m();
  instanceArrow = () => super.m();
}

T('static method', () => D.viaMethod());
T('static getter through super', () => D.viaGetter());
T('static index', () => D.viaIndex());
T('a plain inherited value', () => D.viaValue());
T('a computed-name parent method', () => D.viaComputedName());
T('a static accessor of our own', () => D.accessor);
T('an arrow inside a static method', () => D.viaArrowInMethod());
T('a static field initializer', () => D.field);
T('an arrow in a static field', () => D.arrowField());
T('a static block', () => D.fromBlock);
T('an instance method', () => new D().viaInstance());
T('an instance field', () => new D().instanceField);
T('an arrow in an instance field', () => new D().instanceArrow());

// `this` in a static initializer, and in an arrow inside one
class E {
  static a = 1;
  static b = this.a + 1;
  static viaArrow = () => this;
  static viaIife = (() => this.a + 10)();
  static { E.fromBlock = this === E; }
  static viaArrowInBlockHolder;
  static { E.viaArrowInBlockHolder = () => this; }
}
T('this in a static field', () => E.b);
T('this in an arrow of a static field', () => E.viaArrow() === E);
T('this in an iife of a static field', () => E.viaIife);
T('this in a static block', () => E.fromBlock);
T('this in an arrow of a static block', () => E.viaArrowInBlockHolder() === E);

// a static field is a field whatever its value is
class F {
  static fn = function () {};
  static arrow = () => {};
  static plain = 1;
  static method() {}
  static get g() { return 1; }
}
T('own keys', () => JSON.stringify(Object.keys(F)));
T('a function-valued field', () => JSON.stringify(Object.getOwnPropertyDescriptor(F, 'fn')));
T('a method', () => JSON.stringify(Object.getOwnPropertyDescriptor(F, 'method')));
T('the names', () => JSON.stringify([F.fn.name, F.arrow.name, F.method.name]));

// a computed key names the value it is stored under, not the expression
const k = 'ck';
class G { static [k] = function () {}; [k] = function () {}; }
T('a computed static field name', () => G.ck.name);
T('a computed instance field name', () => new G().ck.name);
T('computed static keys', () => JSON.stringify(Object.keys(G)));

// a private static method reads super the same way
class H extends Base {
  static #p() { return super.sm(); }
  static run() { return H.#p(); }
}
T('a private static method', () => H.run());

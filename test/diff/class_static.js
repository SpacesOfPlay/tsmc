// Class static blocks and static field initializers: the class name and
// `this` both refer to the class inside them, before the outer binding is set.

// Class name referenced in a static block (was a TDZ error).
class C { static x; static { C.x = 5; } }
console.log('name-in-block:', C.x);

// `this` and the class name in a static block.
class D {
  static a = 1;
  static { D.b = D.a + 10; this.c = 99; }
}
console.log('this-in-block:', D.a, D.b, D.c);

// `this` and the class name in static field initializers.
class E { static a = 7; static b = this.a * 2; static c = E.a + 1; }
console.log('this-in-field:', E.a, E.b, E.c);

// Named class expression: only the inner name is in scope.
const X = class Inner { static y = 1; static z = Inner.y + 2; getN() { return Inner.name; } };
console.log('expr-inner-name:', X.z, new X().getN());

// Arrow in a static block captures the class as `this`.
class F {
  static tag = 'F';
  static val;
  static { const get = () => this.tag + '!'; F.val = get(); }
}
console.log('arrow-captures-this:', F.val);

// Derived class: static-block `this` and name, with static inheritance.
class Base { static kind = 'base'; }
class Sub extends Base {
  static own;
  static { Sub.own = this.kind + '/sub'; }
}
console.log('derived:', Sub.own, Sub.kind);

// Instance methods keep their own `this` (no regression).
class G {
  v = 42;
  get() { return this.v; }
  arrow() { const f = () => this.v; return f(); }
}
const g = new G();
console.log('method-this:', g.get(), g.arrow());

// Multiple static blocks run in order and observe prior mutations.
class H {
  static log = [];
  static { this.log.push('a'); }
  static m = 1;
  static { this.log.push('b:' + this.m); }
}
console.log('ordered-blocks:', H.log.join(','));

// Instance field initializer referencing the class name.
class J {
  static base = 100;
  offset = J.base + 1;
}
console.log('instance-field-name:', new J().offset);

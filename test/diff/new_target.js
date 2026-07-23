// new.target: the constructor a call was reached through (undefined for a
// plain call), lexically captured by arrows like `this`, and propagated to a
// base constructor through super() and through Reflect.construct. Was parsed
// but not compiled ("expression not supported yet"). Compared byte-for-byte
// against Node.

// plain function: `new` vs call
function F() { return new.target; }
console.log('new:', new F() instanceof F, 'call:', F(), 'name:', (new F()).name);

// class constructor, direct
class Base { constructor() { this.t = new.target ? new.target.name : 'none'; } }
console.log('direct:', new Base().t);

// derived via a default constructor (super(...args) spread path)
class Sub extends Base {}
console.log('derived default ctor:', new Sub().t);

// derived via an explicit constructor (super() with no spread)
class Sub2 extends Base { constructor() { super(); } }
console.log('derived explicit ctor:', new Sub2().t);

// multi-level: new.target is the most-derived class at every level
class A { constructor() { this.nt = new.target && new.target.name; } }
class B extends A {}
class C extends B { constructor(...a) { super(...a); } }
console.log('multi-level:', new A().nt, new B().nt, new C().nt);

// arrows capture the enclosing constructor's new.target lexically
class WithArrow {
  constructor() { const f = () => new.target && new.target.name; this.viaArrow = f(); }
}
console.log('arrow-in-ctor:', new WithArrow().viaArrow);
function G() { const f = () => new.target; return f() && f().name; }
console.log('arrow-in-fn:', new G() && 'set', G());

// the Error-subclass pattern (the common real-world use, e.g. zod)
class MyError extends Error {
  constructor(msg) {
    super(msg);
    Object.setPrototypeOf(this, new.target.prototype);
    this.name = new.target.name;
  }
}
class SubError extends MyError {}
const e1 = new MyError('boom');
const e2 = new SubError('nested');
console.log('MyError:', e1 instanceof MyError, e1 instanceof Error, e1.name, e1.message);
console.log('SubError:', e2 instanceof SubError, e2 instanceof Error, e2.name);

// Reflect.construct sets new.target (to the explicit newTarget, or the target)
console.log('Reflect.construct:', Reflect.construct(Base, []).t);
function H() { return new.target && new.target.name; }
class Marker {}
console.log('Reflect newTarget arg:', Reflect.construct(H, [], Marker) === 'Marker' ? 'Marker' : 'wrong');

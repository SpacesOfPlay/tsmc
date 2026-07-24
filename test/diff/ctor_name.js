// A function's .prototype carries a constructor back-reference, and console
// output prefixes an object with its constructor's name.

// --- prototype.constructor -------------------------------------------------
function Old() { this.b = 2; }
console.log('backref:', Old.prototype.constructor === Old);
console.log('instance:', new Old().constructor === Old);
const cd = Object.getOwnPropertyDescriptor(Old.prototype, 'constructor');
console.log('descriptor:', cd.enumerable, cd.writable, cd.configurable);
console.log('not enumerated:', JSON.stringify(Object.keys(Old.prototype)));

class C {}
console.log('class backref:', C.prototype.constructor === C, new C().constructor === C);

// A generator's .prototype is bare — it is only what its results inherit from.
const gen = function* () {};
console.log('generator proto props:', Object.getOwnPropertyNames(gen.prototype).length);

// The classic prototype pattern works end to end.
function Point(x, y) { this.x = x; this.y = y; }
Point.prototype.sum = function () { return this.x + this.y; };
const pt = new Point(3, 4);
console.log('pattern:', pt.sum(), pt.constructor === Point, pt instanceof Point);

// Inheriting the ES5 way.
function Base() {}
function Derived() { Base.call(this); }
Derived.prototype = Object.create(Base.prototype);
Derived.prototype.constructor = Derived;
console.log('es5 inherit:', new Derived() instanceof Base, new Derived().constructor === Derived);

// --- console output --------------------------------------------------------
class Plain {}
class WithField { constructor() { this.a = 1; } }
console.log(new Plain());
console.log(new WithField());
console.log(new Old());
console.log({ a: 1 });
console.log(Object.create(null));
const nullp = Object.create(null);
nullp.x = 1;
console.log(nullp);

// An anonymous class takes the name it is assigned to.
const anon = class {};
console.log(new anon());

// An object whose prototype is plain has no prefix.
console.log(Object.create({}));

// Nested and inside an array.
class Nested { constructor() { this.inner = new Plain(); } }
console.log(new Nested());
console.log([new Plain(), { a: 1 }]);

// A subclass reports its own name.
class Sub extends WithField {}
console.log(new Sub());

// The name comes from the nearest prototype that declares a constructor.
console.log(Object.assign(Object.create(Plain.prototype), { z: 9 }));

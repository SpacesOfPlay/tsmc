// Function name/length and constructor back-links.

function foo(a, b) { return a + b; }
const bar = (x) => x;
console.log(foo.name, bar.name, foo.length, ((a, b, c) => a).length);
console.log([].map.name, Object.keys.name, Array.name, Object.name, Error.name);

console.log(({}).constructor === Object, [].constructor === Array);
console.log((5).constructor === Number, "s".constructor === String, true.constructor === Boolean);
console.log(({}).constructor.name, [].constructor.name, (5).constructor.name);

console.log(new Error("x").constructor.name, new TypeError("y").constructor.name);
console.log(new RangeError("z").constructor.name);

class Animal { constructor(n) { this.n = n; } }
class Dog extends Animal {}
console.log(new Animal("a").constructor.name, new Dog().constructor.name);
console.log(Animal.name, Dog.name, new Dog().constructor === Dog);

const named = class Widget {};
console.log(named.name);

// static inheritance: derived ctor's [[Prototype]] is the parent ctor
class Base { static make() { return "base"; } static kind = "B"; }
class Derived extends Base {}
class Deeper extends Derived {}
console.log(Derived.make(), Deeper.make(), Derived.kind, Deeper.kind);
console.log(Object.getPrototypeOf(Derived) === Base, Object.getPrototypeOf(Deeper) === Derived);

// Symbol
const sym = Symbol("tag");
console.log(sym.toString(), sym.description, typeof sym);
console.log(Symbol().toString(), Symbol().description, String(Symbol("z")));

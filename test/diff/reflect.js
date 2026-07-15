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

const J = JSON.stringify;
const o = { b: 2, a: 1, c: 3 };
console.log(J(Object.keys(o)), J(Object.values(o)), J(Object.entries(o)));
console.log(J(o), J(o, null, 2));
console.log(J([1, "two", true, null, { x: 1 }]));
console.log(JSON.parse('{"a":[1,2,{"b":3}]}').a[2].b);
console.log(J({ ...o, d: 4, a: 10 }));
console.log(J(Object.assign({}, o, { e: 5 })));
console.log("a" in o, "z" in o, o.hasOwnProperty("a"));
const { a, ...rest } = o;
console.log(a, J(rest));
class Animal { constructor(n) { this.name = n; } speak() { return this.name + " speaks"; } }
class Dog extends Animal { speak() { return super.speak() + " woof"; } }
const d = new Dog("Rex");
console.log(d.speak(), d instanceof Animal, d instanceof Dog);
const counter = (() => { let n = 0; return () => ++n; })();
console.log(counter(), counter(), counter());
console.log(typeof {}, typeof [], typeof null, typeof (() => {}), typeof "x", typeof 1, typeof undefined, typeof true);
console.log(J({ und: undefined, fn: () => {}, n: null }));
console.log(J(Object.fromEntries([["x", 1], ["y", 2]])));

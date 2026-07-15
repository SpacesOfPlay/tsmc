// Standard library coverage: string, array, object statics, iterators.

// String extras
console.log("x".localeCompare("y"), "b".localeCompare("a"), "m".localeCompare("m"));
console.log("hello".substr(1, 3), "hello".substr(-2), "hi".substr(0));
console.log("abc".toLocaleUpperCase(), "ABC".toLocaleLowerCase(), "abc".normalize());

// Array iterators and copyWithin
console.log([...[10, 20, 30].keys()].join(","));
console.log([...[10, 20, 30].values()].join(","));
console.log([...["a", "b", "c"].entries()].map((e) => e.join(":")).join(" "));
console.log([1, 2, 3, 4].copyWithin(0, 2).join(","));
console.log([1, 2, 3, 4, 5].copyWithin(1, 3).join(","));

// Array.from over iterables and array-likes
console.log(Array.from(new Set([1, 1, 2, 3])).join(","));
console.log(Array.from(new Map([["a", 1], ["b", 2]])).map((e) => e.join("=")).join(","));
function* gen() { yield 1; yield 2; yield 3; }
console.log(Array.from(gen()).join(","), Array.from(gen(), (x) => x * 10).join(","));
console.log(Array.from({ length: 3, 0: "a", 1: "b", 2: "c" }).join(","));

// Object statics
console.log(Object.getOwnPropertyNames({ a: 1, b: 2 }).join(","));
console.log(Object.getOwnPropertyNames([10, 20]).join(","));
const proto = { greet() { return "hi"; } };
const obj = {};
Object.setPrototypeOf(obj, proto);
console.log(obj.greet(), Object.getPrototypeOf(obj) === proto);

// Error messages for property access on null/undefined
try { (void 0).x; } catch (e) { console.log(e.message); }
try { null.foo; } catch (e) { console.log(e.message); }
let a;
try { a.b.c; } catch (e) { console.log(e.message); }

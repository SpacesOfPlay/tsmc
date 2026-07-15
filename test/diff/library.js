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

// Object.is / Object.hasOwn
console.log(Object.is(NaN, NaN), Object.is(-0, 0), Object.is(1, 1), Object.is("a", "a"));
console.log(Object.hasOwn({ x: 1 }, "x"), Object.hasOwn({ x: 1 }, "y"), Object.hasOwn([1, 2], 0));
console.log(Object.fromEntries(new Map([["m", 1], ["n", 2]])).n);

// Array ES2023 copying methods (do not mutate the source)
const src = [3, 1, 2];
console.log(src.toSorted().join(","), src.join(","));
console.log([1, 2, 3].toReversed().join(","), [1, 2, 3].with(1, 9).join(","));
console.log([5, 3, 8, 1].toSorted((x, y) => x - y).join(","));
console.log([1, 2, 2, 3].lastIndexOf(2), [1, 2, 3].lastIndexOf(9));

// URI encoding
console.log(encodeURIComponent("a b&c=d/e"), encodeURI("http://x.com/a b?q=1&r=2"));
console.log(decodeURIComponent("a%20b%26c"), decodeURI("a%20b%2Fc%3Fd"));
console.log(encodeURIComponent("café"), decodeURIComponent(encodeURIComponent("héllo wörld")));

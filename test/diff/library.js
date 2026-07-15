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

// globalThis mirrors the built-in globals
console.log(typeof globalThis, globalThis.Math === Math, globalThis.JSON === JSON);
console.log(globalThis.Array === Array, globalThis.globalThis === globalThis);
console.log(globalThis.parseInt("42"), typeof globalThis.undefined, globalThis.Infinity);

// structuredClone: deep, independent, preserves cycles/Map/Set/Date/holes
const orig = { a: [1, 2], b: { c: 3 } };
const clone = structuredClone(orig);
clone.a.push(9);
clone.b.c = 99;
console.log(JSON.stringify(orig), JSON.stringify(clone), clone !== orig, clone.a !== orig.a);
const cyc = {};
cyc.self = cyc;
const cc = structuredClone(cyc);
console.log(cc.self === cc, cc !== cyc);
const cm = structuredClone(new Map([["x", 1]]));
cm.set("y", 2);
console.log(cm.size, cm.get("x"));
const cs = structuredClone(new Set([1, 2, 3]));
console.log([...cs].join(","));
const cd = structuredClone(new Date(1000));
console.log(cd.getTime(), cd instanceof Date);
console.log(Object.keys(structuredClone([1, , 3])).join(","));

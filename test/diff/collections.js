// Map, Set, generators, and closures.

const m = new Map([["a", 1], ["b", 2]]);
m.set("c", 3);
m.delete("a");
console.log(m.size, [...m.keys()].join(","), [...m.values()].join(","));
for (const [k, v] of m) console.log(k, v);
console.log([...m.entries()].map((e) => e.join(":")).join(" "));
m.forEach((v, k) => console.log("fe", k, v));

const s = new Set([1, 2, 2, 3]);
s.add(4);
s.delete(2);
console.log(s.size, [...s].join(","), s.has(3), s.has(2));

function* gen() {
  yield 1;
  yield* [2, 3];
  return 99;
}
const g = gen();
console.log(g.next().value, g.next().value, g.next().value, g.next().value, g.next().done);
console.log([...gen()].join(","));

function makeCounter() {
  let n = 0;
  return () => ++n;
}
const c = makeCounter();
console.log(c(), c(), c());

const adders = [];
for (let i = 0; i < 3; i++) adders.push(() => i);
console.log(adders.map((f) => f()).join(","));

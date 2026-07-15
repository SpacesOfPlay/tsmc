// Modern syntax: destructuring, spread, optional chaining, nullish, typeof.

const [a, b = 10, ...rest] = [1, undefined, 3, 4];
console.log(a, b, rest.join(","));
const { x, y = 5, z: { w } = { w: 7 } } = { x: 1 };
console.log(x, y, w);

function f(p, q = p * 2, ...r) {
  return [p, q, r.length];
}
console.log(f(3).join(","), f(3, 4, 5, 6).join(","));

const merged = { ...{ a: 1, b: 2 }, ...{ b: 3, c: 4 } };
console.log(JSON.stringify(merged));
console.log(Math.max(...[3, 1, 4, 1, 5, 9, 2, 6]));

const o = { p: { q: null } };
console.log(o?.p?.q ?? "def", o?.p?.r ?? "def2", o?.x?.y?.z);
console.log(0 ?? "a", "" ?? "b", null ?? "c", undefined ?? "d");

console.log(typeof undefined, typeof null, typeof 1, typeof "s", typeof true);
console.log(typeof {}, typeof [], typeof f, typeof Symbol());
console.log(typeof NaN);

console.log("Hello".padStart(8, "*"), "Hi".padEnd(5, "."), "a-b-c".replaceAll("-", "_"));
console.log("  trim  ".trim().length, "ABC".at(-1));
console.log([..."abc"].join("|"), "a,b,,c".split(",").length);

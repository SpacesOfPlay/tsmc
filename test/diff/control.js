let out = [];
for (let i = 0; i < 5; i++) { if (i === 2) continue; if (i === 4) break; out.push(i); }
console.log(out.join(","));
let s = 0; let i = 0; while (i < 10) { s += i; i++; } console.log(s);
let d = 0; do { d++; } while (d < 3); console.log(d);
function classify(n) { switch (true) { case n < 0: return "neg"; case n === 0: return "zero"; default: return "pos"; } }
console.log(classify(-5), classify(0), classify(5));
outer: for (let x = 0; x < 3; x++) { for (let y = 0; y < 3; y++) { if (x + y === 3) break outer; out.push(x * 10 + y); } }
console.log(out.join(","));
function tryDemo() { try { throw new Error("boom"); } catch (e) { return "caught " + e.message; } finally { out.push(99); } }
console.log(tryDemo(), out[out.length - 1]);
const arr = [1, 2, 3]; for (const x of arr) s += x; console.log(s);
for (const k in { a: 1, b: 2 }) out.push(k); console.log(out.slice(-2).join(""));
console.log([1, 2, 3].map((x) => x ** 2).join(","));
const [p, q = 10, ...r] = [1]; console.log(p, q, r.length);
const { m = 5, n } = { n: 7 }; console.log(m, n);
console.log((() => { let a = 1; const f = () => a++; f(); f(); return a; })());
console.log(0 || "a", 1 && "b", null ?? "c", undefined?.x, "x"?.length);
console.log(3 > 2 ? "y" : "n", (1, 2, 3), void 0);

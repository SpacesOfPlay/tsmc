// Property reads and writes that walk a prototype chain, and the same reads
// over objects of several shapes: the polymorphic case an interpreter pays a
// dictionary lookup for either way.
const a = { av: 1, m() { return this.av; } };
const b = Object.create(a); b.bv = 2;
const c = Object.create(b); c.cv = 3;
const d = Object.create(c); d.dv = 4;
const shapes = [{ p: 1 }, { q: 1, p: 2 }, { r: 1, s: 2, p: 3 }, Object.create({ p: 4 })];
let acc = 0;
for (let i = 0; i < 1200000; i++) {
  acc = (acc + d.av + d.bv + d.cv + d.dv + d.m()) | 0;
  acc = (acc + shapes[i & 3].p) | 0;
  d.own = i;
  acc = (acc + d.own) | 0;
}
console.log(acc);

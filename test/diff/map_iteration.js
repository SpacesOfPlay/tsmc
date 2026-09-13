// Iterating a Map or a Set: what each of keys/values/entries yields, what
// happens to an iterator when the collection changes under it, and the shape of
// the result a hand-called next() returns. for-of steps these iterators without
// building a result object, so everything that can observe one is here.
const J = JSON.stringify;
const m = new Map([['a', 1], ['b', 2], ['c', 3]]);
const s = new Set([1, 2, 3]);

const out = [];
for (const [k, v] of m) out.push(k + v);
console.log(J(out), J([...m]), J([...m.keys()]), J([...m.values()]), J([...m.entries()]));
console.log(J([...s]), J([...s.keys()]), J([...s.values()]), J([...s.entries()]));

// an entry deleted before it is reached is not visited
const d = new Map([['x', 1], ['y', 2], ['z', 3]]);
const seen = [];
for (const [k] of d) { seen.push(k); if (k === 'x') d.delete('y'); }
console.log(J(seen), d.size);

// one added during iteration is
const g = new Map([['p', 1]]);
const got = [];
for (const [k] of g) { got.push(k); if (got.length < 3) g.set('n' + got.length, 1); }
console.log(J(got));

// clearing it ends the iteration
const c = new Map([['a', 1], ['b', 2]]);
const cs = [];
for (const [k] of c) { cs.push(k); c.clear(); }
console.log(J(cs), c.size);

// a hand-called next() still returns a real result object
const it = m[Symbol.iterator]();
const r = it.next();
console.log(J(r), J(Object.keys(r)), r.done, J(it.next().value));

// an iterator already part-way through, spread from where it stands
const it3 = m.keys();
it3.next();
console.log(J([...it3]));

// a replaced next() is the one that runs
const it2 = m.keys();
let once = false;
it2.next = () => { const done = once; once = true; return { value: 'patched', done }; };
console.log(J([...{ [Symbol.iterator]: () => it2 }]));

// an exhausted iterator stays exhausted
const it4 = new Map([['k', 1]]).values();
console.log(J(it4.next()), J(it4.next()), J(it4.next()));

// destructuring, Array.from, spread into a call, and yield*
const [f1, f2] = m;
console.log(J(f1), J(f2), J(Array.from(m, ([k, v]) => k + v)));
console.log(Math.max(...s), J(Object.fromEntries(m)), m.size, s.size);
function* deleg() { yield* m.keys(); }
console.log(J([...deleg()]));

// a Set's entries pairs the value with itself
for (const [a, b] of s.entries()) console.log('set entry', a, b);

// the iterator objects themselves
console.log(typeof new WeakMap()[Symbol.iterator], typeof m.keys()[Symbol.iterator]);
console.log(m.keys()[Symbol.iterator]() === m.keys()[Symbol.iterator]());

// a Map of objects, and one whose keys are numbers
const om = new Map([[{ id: 1 }, 'a'], [2, 'b'], [NaN, 'c'], [-0, 'd']]);
const ks = [];
for (const [k] of om) ks.push(typeof k === 'object' ? k.id : String(k));
console.log(J(ks), om.get(NaN), om.get(0));

// nested iteration over the same collection
const pairs = [];
for (const a of s) for (const b of s) pairs.push(a * 10 + b);
console.log(J(pairs));

// forEach is not this path, and must agree with it
const fe = [];
m.forEach((v, k) => fe.push(k + v));
console.log(J(fe), J([...m].map(([k, v]) => k + v)));

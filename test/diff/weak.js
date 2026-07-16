// WeakMap / WeakSet. Functional behavior matches Node; under --gc-stress
// the ephemeron marking (values kept alive by a live key, including
// key-chains) is exercised too.

const wm = new WeakMap();
const k1 = { id: 1 }, k2 = { id: 2 }, k3 = { id: 3 };
console.log(wm.set(k1, "a").set(k2, 2) === wm, wm.get(k1), wm.get(k2), wm.has(k3));
console.log(wm.delete(k1), wm.has(k1), wm.get(k1));

const wm2 = new WeakMap([[k2, "x"], [k3, "y"]]);
console.log(wm2.get(k2), wm2.get(k3));

// non-object keys throw
function bad(f) { try { f(); return "no throw"; } catch (e) { return e.constructor.name; } }
console.log(bad(() => wm.set(1, 0)), bad(() => wm.set("s", 0)), bad(() => new WeakSet([true])));

// function and array keys are valid
const fn = () => {}, arr = [];
wm.set(fn, "fn").set(arr, "arr");
console.log(wm.get(fn), wm.get(arr));

// WeakSet
const ws = new WeakSet();
const o = {};
console.log(ws.add(o).add(k2) === ws, ws.has(o), ws.has(k1), ws.delete(o), ws.has(o));

// no size / iteration
console.log(wm.size, wm.forEach, ws.size);

// values reachable only through a live key survive collection
const holder = new WeakMap();
const key = {};
holder.set(key, { deep: { n: 7 } });
const chainKey = {}, chainVal = {};
holder.set(chainKey, chainVal);
const holder2 = new WeakMap();
holder2.set(chainVal, "chained");   // chainVal is live only via holder[chainKey]
for (let i = 0; i < 300; i++) { const junk = { a: i, b: [i] }; }
console.log(holder.get(key).deep.n, holder2.get(chainVal));

// Proxy core traps (get/set/has/deleteProperty) + Reflect defaults, object
// targets. Compared byte-for-byte against Node. (apply/construct, ownKeys,
// and the descriptor/proto traps are later increments.)

// every trap fires and defaults through Reflect
const log = [];
const p = new Proxy({ a: 1, b: 2 }, {
  get(t, k, r) { log.push('get:' + String(k)); return Reflect.get(t, k, r); },
  set(t, k, v, r) { log.push('set:' + String(k) + '=' + v); return Reflect.set(t, k, v, r); },
  has(t, k) { log.push('has:' + String(k)); return Reflect.has(t, k); },
  deleteProperty(t, k) { log.push('del:' + String(k)); return Reflect.deleteProperty(t, k); },
});
console.log(p.a, p.b);
p.c = 3;
console.log(p.c, ('c' in p), ('z' in p));
console.log(delete p.b, p.b);            // dot-form delete
console.log(delete p['a']);              // computed-form delete
console.log(log.join(' '));

// trap-absent operations default to the target
const q = new Proxy({ x: 10 }, {});
q.y = 20;
console.log(q.x, q.y, ('x' in q), delete q.x, q.x);

// a validating proxy: set trap can reject
const v = new Proxy({}, {
  set(t, k, val) { if (typeof val !== 'number') throw new TypeError('num only'); t[k] = val; return true; },
});
v.n = 5;
console.log(v.n);
try { v.s = 'x'; console.log('no throw'); } catch (e) { console.log(e.constructor.name, e.message); }

// nested/recursive proxies from a get (the reactivity pattern)
function reactive(o) {
  return new Proxy(o, { get(t, k) { const val = t[k]; return (val && typeof val === 'object') ? reactive(val) : val; } });
}
const r = reactive({ nested: { deep: { v: 42 } }, arr: [1, 2, 3] });
console.log(r.nested.deep.v, r.arr[1]);

// a symbol-keyed get traps too
const S = Symbol('s');
const sp = new Proxy({ [S]: 'sym' }, { get(t, k, rec) { return Reflect.get(t, k, rec); } });
console.log(sp[S]);

// typeof an object-target proxy is 'object'; Reflect.getPrototypeOf sees it
console.log(typeof p, Reflect.getPrototypeOf(p) === Object.prototype);

// a non-object handler / target is a TypeError
try { new Proxy(42, {}); } catch (e) { console.log(e.constructor.name); }
try { new Proxy({}, null); } catch (e) { console.log(e.constructor.name); }

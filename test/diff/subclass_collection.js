// Subclassing the built-in collections: `class X extends Set / Map`.
// The instance keeps the collection's behavior while staying an ordinary
// object, so fields assigned in the subclass constructor survive.

class MySet extends Set {}
const s = new MySet([1, 2]);
s.add(3);
console.log('set:', s.size, [...s].join(','), s.has(2));
console.log('set instanceof:', s instanceof MySet, s instanceof Set);

class MyMap extends Map {}
const m = new MyMap([['a', 1]]);
m.set('b', 2);
console.log('map:', m.size, m.get('a'), m.has('b'), [...m.keys()].join(','));
console.log('map instanceof:', m instanceof MyMap, m instanceof Map);

// A subclass that adds state and behavior.
class Tagged extends Set {
  constructor(tag, items) { super(items); this.tag = tag; }
  describe() { return this.tag + ':' + [...this].join('|'); }
}
const t = new Tagged('T', ['x', 'y']);
console.log('own field:', t.tag);
console.log('method:', t.describe());
t.add('z');
console.log('after add:', t.describe(), t.size);

// Iteration protocols all resolve through the subclass instance.
const seen = [];
for (const v of s) { seen.push(v); }
s.forEach((v) => seen.push('f' + v));
console.log('iteration:', seen.join(','));
console.log('entries:', [...m.entries()].map((e) => e.join('=')).join(','));
console.log('values/keys:', [...s.values()].join(','), [...m.values()].join(','));

// Constructing from another instance's iterator (a common clone pattern).
class RefSet extends Set { clone() { return new RefSet(this.values()); } }
const r = new RefSet([1, 2, 3]);
console.log('clone:', r.clone().size, [...r.clone()].join(','));

// Deeper inheritance chains.
class A extends Set {}
class B extends A {}
const b = new B([9]);
console.log('deep:', b.size, b instanceof A, b instanceof Set);

// delete / clear on a subclass.
const d = new MySet([1, 2, 3]);
d.delete(2);
console.log('delete:', d.size, [...d].join(','));
d.clear();
console.log('clear:', d.size);

// The internal storage stays invisible to property inspection.
const p = new MySet([1]);
p.extra = 'e';
console.log('keys:', JSON.stringify(Object.keys(p)));
console.log('ownNames:', JSON.stringify(Object.getOwnPropertyNames(p)));
console.log('json:', JSON.stringify(p));
console.log('spread:', JSON.stringify({ ...p }));
const forin = [];
for (const k in p) { forin.push(k); }
console.log('for-in:', JSON.stringify(forin));
console.log('field intact:', p.extra, p.size);

// Plain collections are unchanged.
const ps = new Set([1, 1, 2]);
const pm = new Map([[1, 'a']]);
console.log('plain:', ps.size, pm.size, pm.get(1));

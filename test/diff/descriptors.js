// Property descriptors, enumerability, freeze/seal/extensibility.

// defineProperty: non-enumerable hides from keys/JSON/for-in
const o1 = {};
Object.defineProperty(o1, "hidden", { value: 5, enumerable: false });
Object.defineProperty(o1, "shown", { value: 6, enumerable: true });
console.log(o1.hidden, o1.shown, Object.keys(o1).join(","), JSON.stringify(o1));
const seen = [];
for (const k in o1) seen.push(k);
console.log(seen.join(","));

// accessor descriptor
const o2 = {};
Object.defineProperty(o2, "r", { get() { return 42; }, enumerable: true });
console.log(o2.r);

// non-writable data property ignores writes
const o3 = {};
Object.defineProperty(o3, "w", { value: 1, writable: false });
o3.w = 99;
console.log(o3.w);

// freeze / seal / preventExtensions
const f = Object.freeze({ a: 1 });
f.a = 2;
f.b = 3;
console.log(f.a, f.b, Object.isFrozen(f), Object.isSealed(f));

const s = Object.seal({ a: 1 });
s.a = 2;
s.b = 3;
console.log(s.a, s.b, Object.isSealed(s), Object.isFrozen(s));

const p = {};
Object.preventExtensions(p);
p.x = 1;
console.log(p.x, Object.isExtensible(p), Object.isExtensible({}));

// getOwnPropertyDescriptor
console.log(JSON.stringify(Object.getOwnPropertyDescriptor({ a: 1 }, "a")));
const o4 = {};
Object.defineProperty(o4, "x", { value: 7, writable: true, enumerable: false, configurable: true });
console.log(JSON.stringify(Object.getOwnPropertyDescriptor(o4, "x")));
console.log(JSON.stringify(Object.getOwnPropertyDescriptor([10, 20], "1")));
console.log(Object.getOwnPropertyDescriptor({}, "missing"));

// defineProperties
const o5 = {};
Object.defineProperties(o5, {
  a: { value: 1, enumerable: true },
  b: { value: 2, enumerable: false },
});
console.log(o5.a, o5.b, Object.keys(o5).join(","));

// primitives report frozen/sealed true, not extensible
console.log(Object.isFrozen(5), Object.isSealed("x"), Object.isExtensible(3));

// built-in and class methods are non-enumerable; fields stay enumerable
console.log(Object.keys(Array.prototype).length, Object.keys(Math).length);
class Widget {
  x = 1;
  y = 2;
  render() {}
  update() {}
}
console.log(Object.keys(Widget.prototype).length);
console.log(Object.getOwnPropertyNames(Widget.prototype).sort().join(","));
console.log(Object.keys(new Widget()).join(","));
console.log(Object.keys(new Widget()).length, new Widget().constructor.name);

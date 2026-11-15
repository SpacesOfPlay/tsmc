// a class that extends a native constructor gets the object the base
// built as its instance, under its own prototype
class U8 extends Uint8Array { }
const u = new U8([1, 2, 3]);
console.log(u.length, u instanceof U8, u instanceof Uint8Array, u.buffer.byteLength);
class F32 extends Float32Array { tag: string; constructor(n: number) { super(n); this.tag = 'f'; } }
const h = new F32(4);
console.log(h.length, h.tag, new Uint8Array(h.buffer).length, Object.getPrototypeOf(h) === F32.prototype);
class Arr extends Array { }
const a = new Arr(3);
console.log(a.length, Array.isArray(a), a instanceof Arr);
class Err extends Error { k: number; constructor(m: string) { super(m); this.k = 1; } }
const e = new Err('x');
console.log(e.message, e.k, e instanceof Err, e instanceof Error);
class M extends Map<number, number> { }
const m = new M(); m.set(1, 2);
console.log(m.get(1), m instanceof M);
class Deep extends F32 { }
const d = new Deep(2);
console.log(d.length, d.tag, d instanceof Deep, d instanceof Float32Array);

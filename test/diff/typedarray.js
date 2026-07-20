// TypedArray / ArrayBuffer / DataView conformance vs Node.

// --- construction forms ---
const a = new Uint8Array(4);
console.log(a.length, a.byteLength, a.BYTES_PER_ELEMENT, a[0]);
a[0] = 255; a[1] = 256; a[2] = -1; a[3] = 3.9;
console.log(a[0], a[1], a[2], a[3]);
console.log(a);

const b = new Uint8Array([10, 20, 30]);
console.log(b, b.length);

const c = new Int8Array([127, 128, -1, 255]);
console.log(c);

const cl = new Uint8ClampedArray([-5, 3.5, 300, 127.5]);
console.log(cl);

const i16 = new Int16Array([1, -1, 32768, 65535]);
console.log(i16);
const u16 = new Uint16Array([0, 65535, 65536, -1]);
console.log(u16);
const i32 = new Int32Array([-1, 2147483647, 2147483648]);
console.log(i32);
const u32 = new Uint32Array([0, 4294967295, 4294967296]);
console.log(u32);

const f32 = new Float32Array([1.5, -2.25, 3.14]);
console.log(f32[0], f32[1], Math.abs(f32[2] - 3.14) < 0.001);
const f64 = new Float64Array([1.5, -2.25, Math.PI]);
console.log(f64);

// --- shared ArrayBuffer views ---
const buf = new ArrayBuffer(8);
console.log(buf.byteLength, ArrayBuffer.isView(buf));
const v8 = new Uint8Array(buf);
const v32 = new Uint32Array(buf);
v32[0] = 0x04030201;
console.log(v8[0], v8[1], v8[2], v8[3]);
console.log(ArrayBuffer.isView(v8));

// offset + length view
const part = new Uint8Array(buf, 4, 2);
console.log(part.length, part.byteOffset, part.byteLength);
part[0] = 99;
console.log(v8[4]);

// --- methods ---
const m = new Uint8Array([1, 2, 3, 4, 5]);
console.log(m.map(x => x * 2));
console.log(m.filter(x => x % 2 === 0));
console.log(m.reduce((acc, x) => acc + x, 0));
console.log(m.reduceRight((acc, x) => acc + '' + x, ''));
console.log(m.indexOf(3), m.indexOf(99), m.includes(4), m.includes(99));
console.log(m.join('-'), m.toString());
console.log(m.at(-1), m.at(0), m.at(10));
console.log(m.some(x => x > 4), m.every(x => x > 0));
console.log(m.find(x => x > 3), m.findIndex(x => x > 3));

const sub = m.subarray(1, 3);
console.log(sub, sub.length);
sub[0] = 200;
console.log(m[1]);   // subarray shares storage

const sl = m.slice(1, 3);
sl[0] = 7;
console.log(m[1], sl);   // slice copies

const fl = new Uint8Array(4).fill(9);
console.log(fl);
fl.fill(1, 1, 3);
console.log(fl);

const rev = new Uint8Array([1, 2, 3]).reverse();
console.log(rev);

// set()
const dst = new Uint8Array(5);
dst.set([1, 2, 3], 1);
console.log(dst);

// from / of
console.log(Uint8Array.of(1, 2, 3));
console.log(Uint8Array.from([4, 5, 6]));
console.log(Uint16Array.from([1, 2, 3], x => x * 100));

// iteration
console.log([...new Uint8Array([9, 8, 7])]);
let acc = 0;
for (const x of new Uint8Array([1, 2, 3])) { acc += x; }
console.log(acc);
console.log([...m.keys()]);
console.log([...m.entries()]);

// instanceof
console.log(b instanceof Uint8Array, b instanceof Int8Array);

// forEach
const seen = [];
new Uint8Array([5, 6]).forEach((x, i) => seen.push(i + ':' + x));
console.log(seen);

// --- DataView ---
const dv = new DataView(new ArrayBuffer(24));
dv.setUint8(0, 255);
dv.setInt16(1, -1000);        // big-endian
dv.setInt16(3, -1000, true);  // little-endian
dv.setUint32(5, 0xDEADBEEF);
dv.setFloat64(9, 3.141592653589793);
console.log(dv.getUint8(0));
console.log(dv.getInt16(1), dv.getInt16(3, true));
console.log(dv.getUint32(5).toString(16));
console.log(dv.getFloat64(9));
console.log(dv.byteLength, dv.byteOffset);

// endianness cross-check
const eb = new ArrayBuffer(4);
const edv = new DataView(eb);
edv.setUint32(0, 0x01020304, false);
const ev = new Uint8Array(eb);
console.log(ev[0], ev[1], ev[2], ev[3]);
edv.setUint32(0, 0x01020304, true);
console.log(ev[0], ev[1], ev[2], ev[3]);

// --- reflection: indices behave as own properties ---
const r = new Uint8Array([10, 20, 30]);
console.log(Object.keys(r));
console.log(Object.values(r));
console.log(Object.entries(r));
console.log(r.hasOwnProperty('length'), r.hasOwnProperty('0'), r.hasOwnProperty('buffer'));
console.log(JSON.stringify(r));
console.log(JSON.stringify({ data: new Int16Array([1, -2, 3]) }));
console.log(JSON.stringify(new Float64Array([1.5, 2.5]), null, 2));
console.log({ ...r });
let inKeys = [];
for (const k in r) { inKeys.push(k); }
console.log(inKeys);
console.log(r['1'], r['10']);   // string-index get
r['2'] = 99;                    // string-index set
console.log(r[2]);
const dvv = new DataView(new ArrayBuffer(8), 2, 4);
console.log(dvv.byteLength, dvv.byteOffset, dvv.buffer.byteLength);
console.log(dvv.hasOwnProperty('byteLength'));
const abuf = new ArrayBuffer(16);
console.log(abuf.byteLength, abuf.hasOwnProperty('byteLength'));
console.log(r.buffer instanceof ArrayBuffer, r.constructor === Uint8Array);

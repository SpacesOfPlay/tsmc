// TypedArrays, ArrayBuffer and DataView: construction from every source and
// the range checks that go with it, per-type element coercion, indexing,
// the view methods, and DataView's endianness.

const rows = [];
function T(label, fn) {
  let v;
  try { v = fn(); }
  catch (e) { v = 'THROW:' + (e && e.constructor ? e.constructor.name : String(e)); }
  try { v = JSON.stringify(v); } catch (e) { v = String(v); }
  rows.push(label + ' = ' + v);
}
const A = (ta) => Array.from(ta);

// --- construction ---
T('from-length', () => { const t = new Uint8Array(3); return [t.length, A(t)]; });
T('from-array', () => A(new Int16Array([1, -2, 3])));
T('from-iterable', () => A(new Uint8Array(new Set([1, 2]))));
T('from-typedarray', () => A(new Uint8Array(new Int16Array([1, 300]))));
T('from-buffer', () => { const b = new ArrayBuffer(4); const t = new Uint8Array(b); return [t.length, t.buffer === b]; });
T('from-buffer-offset', () => { const b = new ArrayBuffer(8); const t = new Uint16Array(b, 2, 2); return [t.length, t.byteOffset, t.byteLength]; });
T('from-buffer-bad-offset', () => new Uint32Array(new ArrayBuffer(8), 3));
T('from-buffer-misaligned-length', () => new Uint32Array(new ArrayBuffer(7)));
T('from-no-args', () => new Uint8Array().length);
T('bytes-per-element', () => [Uint8Array.BYTES_PER_ELEMENT, Int16Array.BYTES_PER_ELEMENT, Float64Array.BYTES_PER_ELEMENT]);
T('byteLength', () => { const t = new Int32Array(3); return [t.byteLength, t.byteOffset, t.length]; });
T('of', () => A(Uint8Array.of(1, 2)));
T('from-mapfn', () => A(Uint8Array.from([1, 2], (x) => x * 2)));
T('from-arraylike', () => A(Uint8Array.from({ length: 2, 0: 5, 1: 6 })));

// --- element coercion ---
T('int8-wrap', () => A(new Int8Array([127, 128, -129, 255])));
T('uint8-wrap', () => A(new Uint8Array([255, 256, -1, 1.7])));
T('uint8clamped', () => A(new Uint8ClampedArray([-5, 300, 1.5, 2.5, 3.5])));
T('int16-wrap', () => A(new Int16Array([32767, 32768, -32769])));
T('int32-truncate', () => A(new Int32Array([1.9, -1.9, 2147483648])));
T('float32-precision', () => A(new Float32Array([0.1, 1 / 3])));
T('float64-exact', () => A(new Float64Array([0.1])));
T('nan-and-infinity', () => [A(new Int32Array([NaN, Infinity])), A(new Float64Array([NaN, Infinity]))]);
T('string-coercion', () => A(new Uint8Array(['7', 'x'])));

// --- indexing ---
T('read-out-of-range', () => { const t = new Uint8Array(2); return [t[5], t[-1]]; });
T('write-out-of-range-ignored', () => { const t = new Uint8Array(2); t[5] = 9; return [t.length, t[5], A(t)]; });
T('write-coerces', () => { const t = new Uint8Array(1); t[0] = 300; return t[0]; });
T('has-index', () => { const t = new Uint8Array(2); return [0 in t, 5 in t]; });
T('keys-are-indices', () => Object.keys(new Uint8Array(2)));
T('json-is-object', () => JSON.stringify(new Uint8Array([1, 2])));
T('spread', () => [...new Uint8Array([1, 2])]);

// --- methods ---
T('set-from-array', () => { const t = new Uint8Array(4); t.set([1, 2], 1); return A(t); });
T('set-from-typedarray', () => { const t = new Uint8Array(3); t.set(new Uint8Array([7, 8]), 1); return A(t); });
T('set-out-of-range', () => { const t = new Uint8Array(2); t.set([1, 2, 3]); });
T('subarray', () => { const t = new Uint8Array([1, 2, 3, 4]); const s = t.subarray(1, 3); return [A(s), s.byteOffset, s.buffer === t.buffer]; });
T('subarray-negative', () => A(new Uint8Array([1, 2, 3]).subarray(-2)));
T('subarray-shares', () => { const t = new Uint8Array([1, 2, 3]); const s = t.subarray(1); s[0] = 9; return A(t); });
T('slice-copies', () => { const t = new Uint8Array([1, 2, 3]); const s = t.slice(1); s[0] = 9; return [A(t), A(s)]; });
T('fill', () => A(new Uint8Array(4).fill(7, 1, 3)));
T('copyWithin', () => A(new Uint8Array([1, 2, 3, 4]).copyWithin(0, 2)));
T('sort-numeric', () => A(new Int32Array([10, 9, 1]).sort()));
T('sort-comparator', () => A(new Int32Array([1, 2, 3]).sort((a, b) => b - a)));
T('reverse', () => A(new Uint8Array([1, 2, 3]).reverse()));
T('indexOf-includes', () => { const t = new Float64Array([NaN, 1]); return [t.indexOf(NaN), t.includes(NaN), t.indexOf(1)]; });
T('join', () => new Uint8Array([1, 2]).join('-'));
T('map-returns-same-type', () => { const r = new Uint8Array([1, 2]).map((x) => x * 2); return [A(r), r.constructor.name]; });
T('filter-returns-same-type', () => { const r = new Int16Array([1, 2, 3]).filter((x) => x > 1); return [A(r), r.constructor.name]; });
T('reduce', () => new Uint8Array([1, 2, 3]).reduce((a, b) => a + b));
T('at', () => { const t = new Uint8Array([1, 2, 3]); return [t.at(0), t.at(-1)]; });
T('find-methods', () => { const t = new Uint8Array([1, 2, 3]); return [t.find((x) => x > 1), t.findIndex((x) => x > 1), t.findLast?.((x) => x < 3)]; });

// --- identity and tags ---
T('tostring-tag', () => [Object.prototype.toString.call(new Uint8Array(1)), Object.prototype.toString.call(new Float32Array(1))]);
T('ctor-name', () => new Uint8Array(1).constructor.name);
T('instanceof', () => [new Uint8Array(1) instanceof Uint8Array, new Uint8Array(1) instanceof Int8Array]);
T('shared-proto', () => Object.getPrototypeOf(Uint8Array.prototype) === Object.getPrototypeOf(Int8Array.prototype));
T('isArray-false', () => Array.isArray(new Uint8Array(1)));
T('ArrayBuffer-isView', () => [ArrayBuffer.isView(new Uint8Array(1)), ArrayBuffer.isView([]), ArrayBuffer.isView(new DataView(new ArrayBuffer(1)))]);

// --- ArrayBuffer ---
T('buffer-byteLength', () => new ArrayBuffer(8).byteLength);
T('buffer-slice', () => { const b = new ArrayBuffer(4); new Uint8Array(b).set([1, 2, 3, 4]); return A(new Uint8Array(b.slice(1, 3))); });
T('buffer-slice-negative', () => new ArrayBuffer(4).slice(-2).byteLength);
T('buffer-tag', () => Object.prototype.toString.call(new ArrayBuffer(1)));
T('buffer-zero', () => new ArrayBuffer(0).byteLength);

// --- DataView ---
T('dv-basics', () => { const d = new DataView(new ArrayBuffer(8)); return [d.byteLength, d.byteOffset, d.buffer.byteLength]; });
T('dv-offset', () => { const d = new DataView(new ArrayBuffer(8), 2, 4); return [d.byteLength, d.byteOffset]; });
T('dv-int8', () => { const d = new DataView(new ArrayBuffer(2)); d.setInt8(0, -1); return [d.getInt8(0), d.getUint8(0)]; });
T('dv-endianness', () => { const d = new DataView(new ArrayBuffer(4)); d.setUint16(0, 0x0102); return [d.getUint16(0), d.getUint16(0, true), d.getUint8(0), d.getUint8(1)]; });
T('dv-int32', () => { const d = new DataView(new ArrayBuffer(4)); d.setInt32(0, -2, true); return [d.getInt32(0, true), d.getUint32(0, true)]; });
T('dv-float', () => { const d = new DataView(new ArrayBuffer(8)); d.setFloat64(0, 0.5); d.setFloat32(0, 0.5, true); return [d.getFloat32(0, true)]; });
T('dv-out-of-bounds', () => { const d = new DataView(new ArrayBuffer(2)); return d.getInt32(0); });
T('dv-set-out-of-bounds', () => { const d = new DataView(new ArrayBuffer(2)); d.setInt32(0, 1); });
T('dv-tag', () => Object.prototype.toString.call(new DataView(new ArrayBuffer(1))));
T('dv-shares-buffer', () => { const b = new ArrayBuffer(2); const d = new DataView(b); d.setUint8(0, 9); return new Uint8Array(b)[0]; });

// Range checks on a buffer-backed view.
T('ctor-offset-past-end', () => new Uint8Array(new ArrayBuffer(4), 5));
T('ctor-length-past-end', () => new Uint8Array(new ArrayBuffer(4), 2, 5));
T('ctor-offset-at-end', () => new Uint8Array(new ArrayBuffer(4), 4).length);
T('ctor-aligned-offset', () => new Uint32Array(new ArrayBuffer(8), 4).length);
T('clamped-ties-to-even', () => Array.from(new Uint8ClampedArray([0.5, 1.5, 2.5, 3.5, 4.5])));

console.log(rows.join('\n'));

// Not asserted: BigInt64Array and BigUint64Array do not exist, so a reference
// to either is a ReferenceError rather than the TypeError a wrong element type
// would give. They need bigint-valued element storage.

// Typed arrays, ArrayBuffer and DataView: element coercion and wrapping, the
// shared-buffer views, and the array methods that carry over.

const rows = [];
function T(label, fn) {
  let v;
  try { v = fn(); }
  catch (e) { v = 'THROW:' + (e && e.constructor ? e.constructor.name : String(e)); }
  try { v = JSON.stringify(v); } catch (e) { v = String(v); }
  rows.push(label + ' = ' + v);
}

T('from-array', () => { const t = new Uint8Array([1, 2, 3]); return [t.length, t[0], t[2], Array.from(t)]; });
T('from-length', () => { const t = new Uint8Array(3); return [t.length, t[0]]; });
T('from-typedarray', () => Array.from(new Uint8Array(new Int8Array([1, 2]))));
T('from-iterable', () => Array.from(new Uint8Array(new Set([1, 2]))));
T('of', () => Array.from(Uint8Array.of(1, 2)));
T('from-static', () => Array.from(Uint8Array.from([1, 2], (x) => x * 2)));

T('uint8-wrap', () => { const t = new Uint8Array(1); t[0] = 300; return t[0]; });
T('uint8-negative', () => { const t = new Uint8Array(1); t[0] = -1; return t[0]; });
T('int8-wrap', () => { const t = new Int8Array(1); t[0] = 200; return t[0]; });
T('clamped', () => { const t = new Uint8ClampedArray(3); t[0] = 300; t[1] = -5; t[2] = 1.6; return [t[0], t[1], t[2]]; });
T('int16-wrap', () => { const t = new Int16Array(1); t[0] = 40000; return t[0]; });
T('uint32', () => { const t = new Uint32Array(1); t[0] = -1; return t[0]; });
T('int32-truncate', () => { const t = new Int32Array(1); t[0] = 1.9; return t[0]; });
T('float32-precision', () => { const t = new Float32Array(1); t[0] = 1.1; return t[0]; });
T('float64', () => { const t = new Float64Array(1); t[0] = 1.1; return t[0]; });
T('float-nan', () => { const t = new Float64Array(1); t[0] = NaN; return String(t[0]); });
T('int-from-nan', () => { const t = new Int32Array(1); t[0] = NaN; return t[0]; });
T('oob-write-ignored', () => { const t = new Uint8Array(1); t[5] = 9; return [t.length, t[5]]; });
T('oob-read', () => String(new Uint8Array(1)[5]));

T('BYTES_PER_ELEMENT', () => [Uint8Array.BYTES_PER_ELEMENT, Int16Array.BYTES_PER_ELEMENT, Float64Array.BYTES_PER_ELEMENT]);
T('byteLength', () => { const t = new Int32Array(3); return [t.byteLength, t.length, t.byteOffset]; });
T('buffer-prop', () => { const t = new Uint8Array(4); return [t.buffer.byteLength, t.buffer instanceof ArrayBuffer]; });

T('shared-buffer', () => {
  const b = new ArrayBuffer(4);
  const u8 = new Uint8Array(b);
  const u32 = new Uint32Array(b);
  u32[0] = 0x01020304;
  return [u8[0], u8[1], u8[2], u8[3]];
});
T('view-offset', () => { const b = new ArrayBuffer(4); const v = new Uint8Array(b, 1, 2); return [v.length, v.byteOffset]; });
T('buffer-slice', () => { const b = new ArrayBuffer(4); return [b.slice(1).byteLength, new Uint8Array(b.slice(1)).length]; });
T('arraybuffer-isView', () => [ArrayBuffer.isView(new Uint8Array(1)), ArrayBuffer.isView([])]);

T('subarray', () => { const t = new Uint8Array([1, 2, 3, 4]); return Array.from(t.subarray(1, 3)); });
T('subarray-shares', () => { const t = new Uint8Array([1, 2, 3]); const s = t.subarray(1); s[0] = 9; return [t[1], s[0]]; });
T('slice-copies', () => { const t = new Uint8Array([1, 2, 3]); const s = t.slice(1); s[0] = 9; return [t[1], s[0]]; });
T('set-from-array', () => { const t = new Uint8Array(3); t.set([7, 8], 1); return Array.from(t); });
T('fill', () => Array.from(new Uint8Array(3).fill(5)));
T('fill-range', () => Array.from(new Uint8Array(4).fill(1, 1, 3)));
T('copyWithin', () => Array.from(new Uint8Array([1, 2, 3, 4]).copyWithin(0, 2)));

T('map', () => Array.from(new Uint8Array([1, 2]).map((x) => x * 2)));
T('filter', () => Array.from(new Uint8Array([1, 2, 3]).filter((x) => x > 1)));
T('reduce', () => new Uint8Array([1, 2, 3]).reduce((a, b) => a + b));
T('forEach', () => { let s = 0; new Uint8Array([1, 2]).forEach((x) => s += x); return s; });
T('indexOf', () => [new Uint8Array([1, 2]).indexOf(2), new Uint8Array([1]).indexOf(9)]);
T('includes', () => new Uint8Array([1, 2]).includes(2));
T('join', () => new Uint8Array([1, 2]).join('-'));
T('reverse', () => Array.from(new Uint8Array([1, 2, 3]).reverse()));
T('sort', () => Array.from(new Uint8Array([3, 1, 2]).sort()));
T('sort-numeric-default', () => Array.from(new Int32Array([10, 9, 1]).sort()));
T('find', () => new Uint8Array([1, 2, 3]).find((x) => x > 1));
T('some-every', () => [new Uint8Array([1, 2]).some((x) => x > 1), new Uint8Array([1, 2]).every((x) => x > 0)]);
T('at', () => [new Uint8Array([1, 2]).at(-1), String(new Uint8Array([1]).at(5))]);
T('iteration', () => [...new Uint8Array([1, 2])]);
T('entries', () => [...new Uint8Array([7]).entries()]);
T('json', () => JSON.stringify(new Uint8Array([1, 2])));
T('toString', () => String(new Uint8Array([1, 2])));

T('dataview-int32', () => { const d = new DataView(new ArrayBuffer(4)); d.setInt32(0, 1); return d.getInt32(0); });
T('dataview-endian', () => { const d = new DataView(new ArrayBuffer(4)); d.setInt32(0, 1, true); return d.getInt32(0, false); });
T('dataview-mixed', () => {
  const d = new DataView(new ArrayBuffer(8));
  d.setUint8(0, 255); d.setInt16(1, -2); d.setFloat32(4, 1.5);
  return [d.getUint8(0), d.getInt16(1), d.getFloat32(4)];
});
T('dataview-oob', () => new DataView(new ArrayBuffer(2)).getInt32(0));
T('dataview-props', () => { const b = new ArrayBuffer(4); const d = new DataView(b, 1); return [d.byteLength, d.byteOffset]; });

T('instanceof', () => { const t = new Uint8Array(1); return [t instanceof Uint8Array, t instanceof Object]; });
T('constructor-name', () => new Uint8Array(1).constructor.name);
T('is-not-array', () => Array.isArray(new Uint8Array(1)));
T('negative-length', () => new Uint8Array(-1));

console.log(rows.join('\n'));

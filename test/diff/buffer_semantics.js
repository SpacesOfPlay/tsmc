// Buffer: construction, the encodings, the numeric accessors and the search
// and comparison methods. Buffers are shown as hex so the output stays ASCII
// and stable.
//
// NOT covered, because tsmc backs a Buffer with a JS array rather than a
// Uint8Array over an ArrayBuffer. All of these follow from that one choice,
// and doc/PLAN_M42_buffer_uint8array.md tracks the conversion -- re-add them
// here as it lands, they are its acceptance criteria:
//   - `b instanceof Uint8Array`, `ArrayBuffer.isView(b)`, and the
//     `[object Uint8Array]` tag
//   - assigning out of range truncates to a byte (`b[0] = 300` -> 44)
//   - slice() and subarray() return views that share memory, not copies
//   - `.buffer`, `.byteOffset`, `.byteLength`
//   - `Buffer.from(arrayBuffer)`, which aliases its source
//   - the BigInt64 accessors

const out = [];

function show(v) {
  if (v === undefined) return 'undefined';
  if (v === null) return 'null';
  if (typeof v === 'string') return JSON.stringify(v);
  if (typeof v === 'bigint') return v + 'n';
  if (Buffer.isBuffer(v)) return 'buf<' + v.toString('hex') + '>';
  if (ArrayBuffer.isView(v)) return v.constructor.name + '<' + Array.from(v).join(',') + '>';
  if (v instanceof ArrayBuffer) return 'ab(' + v.byteLength + ')';
  if (Array.isArray(v)) return '[' + v.map(show).join(', ') + ']';
  if (typeof v === 'number' && Object.is(v, -0)) return '-0';
  if (typeof v === 'object') { try { return JSON.stringify(v); } catch (e) { return String(v); } }
  return String(v);
}

function T(label, fn) {
  let v;
  try { v = fn(); } catch (e) {
    v = 'THROW:' + (e && e.constructor ? e.constructor.name : String(e));
  }
  out.push(label + ' = ' + show(v));
}

// --- construction -----------------------------------------------------------

T('alloc-zeroed', () => Buffer.alloc(4));
T('alloc-fill-byte', () => Buffer.alloc(4, 7));
T('alloc-fill-string', () => Buffer.alloc(6, 'ab'));
T('alloc-zero-length', () => [Buffer.alloc(0).length, Buffer.alloc(0)]);
T('allocUnsafe-length', () => Buffer.allocUnsafe(5).length);
T('from-string-default', () => Buffer.from('abc'));
T('from-string-utf8-multibyte', () => Buffer.from('café'));
T('from-string-emoji', () => Buffer.from('\u{1f600}'));
T('from-array', () => Buffer.from([1, 2, 255]));
T('from-array-truncates', () => Buffer.from([256, -1, 1.7, NaN]));
T('from-buffer-copies', () => {
  const a = Buffer.from([1, 2, 3]);
  const b = Buffer.from(a);
  a[0] = 9;
  return [show(a), show(b), a[0] === b[0]];
});
T('from-uint8array', () => Buffer.from(new Uint8Array([1, 2, 3])));
T('from-invalid', () => Buffer.from(5));
T('isBuffer', () => [Buffer.isBuffer(Buffer.alloc(1)), Buffer.isBuffer(new Uint8Array(1)),
                     Buffer.isBuffer('x'), Buffer.isBuffer(null)]);
T('ctor-name', () => Buffer.alloc(0).constructor.name);

// --- encodings --------------------------------------------------------------

T('hex-roundtrip', () => {
  const b = Buffer.from('deadBEEF', 'hex');
  return [b.length, b.toString('hex')];
});
T('hex-odd-length', () => Buffer.from('abc', 'hex'));
T('hex-invalid-chars', () => Buffer.from('zz', 'hex'));
T('base64-roundtrip', () => {
  const b = Buffer.from('hello world');
  const e = b.toString('base64');
  return [e, Buffer.from(e, 'base64').toString('utf8')];
});
T('base64-padding', () => [Buffer.from('a').toString('base64'),
                           Buffer.from('ab').toString('base64'),
                           Buffer.from('abc').toString('base64')]);
T('base64-decode-unpadded', () => Buffer.from('aGVsbG8', 'base64').toString('utf8'));
T('base64url', () => {
  const b = Buffer.from([251, 255, 190]);
  return [b.toString('base64'), b.toString('base64url')];
});
T('base64url-decode', () => Buffer.from('-_8', 'base64url').toString('hex'));
T('latin1', () => {
  const b = Buffer.from([0xe9, 0x41]);
  return [b.toString('latin1'), Buffer.from('éA', 'latin1').toString('hex')];
});
T('ascii-strips-high-bit', () => Buffer.from([0xc9, 0x41]).toString('ascii'));
T('utf16le', () => {
  const b = Buffer.from('hi', 'utf16le');
  return [b.toString('hex'), b.toString('utf16le')];
});
T('ucs2-alias', () => Buffer.from('hi', 'ucs2').toString('hex'));
T('utf8-invalid-sequence', () => Buffer.from([0xff, 0xfe]).toString('utf8'));
T('unknown-encoding', () => Buffer.from('abc', 'nope'));
T('byteLength', () => [Buffer.byteLength('abc'), Buffer.byteLength('café'),
                       Buffer.byteLength('\u{1f600}'), Buffer.byteLength('abc', 'hex'),
                       Buffer.byteLength('aGVsbG8=', 'base64')]);
T('tostring-range', () => {
  const b = Buffer.from('abcdef');
  return [b.toString('utf8', 1, 3), b.toString('utf8', 2), b.toString('utf8', 0, 0),
          b.toString('utf8', 4, 99)];
});
T('tostring-default-encoding', () => Buffer.from([104, 105]).toString());

// --- reading and writing bytes ----------------------------------------------

T('index-access', () => {
  const b = Buffer.from([1, 2, 3]);
  b[1] = 250;
  return [b[0], b[1], b[9], show(b)];
});
T('write-utf8', () => {
  const b = Buffer.alloc(6);
  const n = b.write('abc', 1);
  return [n, show(b)];
});
T('write-truncated', () => {
  const b = Buffer.alloc(2);
  const n = b.write('abcdef');
  return [n, show(b)];
});
T('write-with-encoding', () => {
  const b = Buffer.alloc(3);
  const n = b.write('ff00aa', 'hex');
  return [n, show(b)];
});
T('fill', () => [Buffer.alloc(4).fill(1), Buffer.alloc(4).fill(2, 1),
                 Buffer.alloc(4).fill(3, 1, 3), Buffer.alloc(4).fill('ab')]);
T('fill-returns-self', () => {
  const b = Buffer.alloc(2);
  return b.fill(1) === b;
});

// --- numeric accessors ------------------------------------------------------

T('uint8', () => {
  const b = Buffer.alloc(1);
  b.writeUInt8(200, 0);
  return [b.readUInt8(0), b.readInt8(0)];
});
T('int8-negative', () => {
  const b = Buffer.alloc(1);
  b.writeInt8(-2, 0);
  return [show(b), b.readInt8(0), b.readUInt8(0)];
});
T('uint16', () => {
  const b = Buffer.alloc(2);
  b.writeUInt16BE(0x1234, 0);
  const be = b.toString('hex');
  b.writeUInt16LE(0x1234, 0);
  return [be, b.toString('hex'), b.readUInt16LE(0), b.readUInt16BE(0)];
});
T('int16-negative', () => {
  const b = Buffer.alloc(2);
  b.writeInt16BE(-2, 0);
  return [b.toString('hex'), b.readInt16BE(0), b.readUInt16BE(0)];
});
T('uint32', () => {
  const b = Buffer.alloc(4);
  b.writeUInt32BE(0xdeadbeef, 0);
  const be = b.toString('hex');
  b.writeUInt32LE(0xdeadbeef, 0);
  return [be, b.toString('hex'), b.readUInt32BE(0) === 0xdeadbeef];
});
T('int32', () => {
  const b = Buffer.alloc(4);
  b.writeInt32BE(-123456, 0);
  return [b.toString('hex'), b.readInt32BE(0), b.readUInt32BE(0)];
});
T('float', () => {
  const b = Buffer.alloc(4);
  b.writeFloatBE(1.5, 0);
  return [b.toString('hex'), b.readFloatBE(0)];
});
T('double', () => {
  const b = Buffer.alloc(8);
  b.writeDoubleLE(Math.PI, 0);
  return [b.toString('hex'), b.readDoubleLE(0) === Math.PI];
});
T('read-out-of-range', () => {
  const b = Buffer.alloc(2);
  return [(() => { try { return b.readUInt32BE(0); } catch (e) { return 'THROW:' + e.constructor.name; } })(),
          (() => { try { return b.readUInt8(5); } catch (e) { return 'THROW:' + e.constructor.name; } })()];
});
T('write-returns-offset', () => {
  const b = Buffer.alloc(8);
  return [b.writeUInt8(1, 0), b.writeUInt16BE(1, 1), b.writeUInt32BE(1, 3)];
});
T('uintbe-variable', () => {
  const b = Buffer.from([1, 2, 3]);
  return typeof b.readUIntBE === 'function'
    ? [b.readUIntBE(0, 3), b.readUIntLE(0, 3), b.readUIntBE(1, 2)]
    : 'missing';
});

// --- slicing and copying ----------------------------------------------------

T('slice-negative', () => {
  const b = Buffer.from([1, 2, 3, 4]);
  return [b.slice(-2), b.slice(1, -1), b.slice(3, 1)];
});
T('slice-is-buffer', () => Buffer.isBuffer(Buffer.from([1, 2]).slice(0, 1)));
T('copy', () => {
  const src = Buffer.from([1, 2, 3, 4]);
  const dst = Buffer.alloc(4);
  const n = src.copy(dst, 1, 1, 3);
  return [n, show(dst)];
});
T('copy-full', () => {
  const dst = Buffer.alloc(3);
  const n = Buffer.from([7, 8, 9]).copy(dst);
  return [n, show(dst)];
});
T('copy-overlapping', () => {
  const b = Buffer.from([1, 2, 3, 4, 5]);
  b.copy(b, 0, 2);
  return show(b);
});
T('concat', () => Buffer.concat([Buffer.from([1]), Buffer.from([2, 3])]));
T('concat-with-length', () => [Buffer.concat([Buffer.from([1, 2]), Buffer.from([3])], 2),
                               Buffer.concat([Buffer.from([1])], 3)]);
T('concat-empty', () => [Buffer.concat([]).length, Buffer.concat([]) instanceof Buffer]);

// --- comparison and search --------------------------------------------------

T('equals', () => {
  const a = Buffer.from([1, 2]);
  return [a.equals(Buffer.from([1, 2])), a.equals(Buffer.from([1, 3])),
          a.equals(Buffer.from([1, 2, 3]))];
});
T('compare-method', () => {
  const a = Buffer.from([1, 2]);
  return [a.compare(Buffer.from([1, 2])), a.compare(Buffer.from([1, 3])),
          a.compare(Buffer.from([1, 1])), a.compare(Buffer.from([1]))];
});
T('compare-static', () => typeof Buffer.compare === 'function'
  ? [Buffer.compare(Buffer.from([1]), Buffer.from([2])),
     [Buffer.from([3]), Buffer.from([1])].sort(Buffer.compare).map((b) => b[0])]
  : 'missing');
T('indexOf-byte', () => {
  const b = Buffer.from([1, 2, 3, 2]);
  return [b.indexOf(2), b.indexOf(2, 2), b.indexOf(9), b.lastIndexOf(2)];
});
T('indexOf-string', () => {
  const b = Buffer.from('hello world');
  return [b.indexOf('world'), b.indexOf('o'), b.lastIndexOf('o'), b.indexOf('zz')];
});
T('indexOf-buffer', () => Buffer.from('abcabc').indexOf(Buffer.from('bc')));
T('includes', () => {
  const b = Buffer.from('abc');
  return [b.includes('b'), b.includes('z'), b.includes(98)];
});

// --- other ------------------------------------------------------------------

T('toJSON', () => Buffer.from([1, 2]).toJSON());
T('json-stringify', () => JSON.stringify({ b: Buffer.from([1, 2]) }));
T('iteration', () => [...Buffer.from([1, 2, 3])]);
T('entries-keys-values', () => {
  const b = Buffer.from([9, 8]);
  return [[...b.keys()], [...b.values()], [...b.entries()].map((e) => e.join(':'))];
});
T('typedarray-methods', () => {
  const b = Buffer.from([3, 1, 2]);
  return [Array.from(b.filter((x) => x > 1)), b.reduce((a, x) => a + x, 0),
          Array.from(Buffer.from([3, 1, 2]).sort())];
});
T('swap16', () => typeof Buffer.from([1, 2, 3, 4]).swap16 === 'function'
  ? Buffer.from([1, 2, 3, 4]).swap16() : 'missing');
T('swap32', () => typeof Buffer.from([1, 2, 3, 4]).swap32 === 'function'
  ? Buffer.from([1, 2, 3, 4]).swap32() : 'missing');
T('poolSize-exists', () => typeof Buffer.poolSize);
T('isEncoding', () => typeof Buffer.isEncoding === 'function'
  ? [Buffer.isEncoding('utf8'), Buffer.isEncoding('hex'), Buffer.isEncoding('nope')]
  : 'missing');

console.log(out.join('\n'));

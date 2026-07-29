// zlib: round-trips, framing, and the fixed vectors that prove the output is
// really gzip and really deflate.
//
// Compressed bytes are deliberately never compared between engines. Two
// conforming compressors may emit different, equally valid streams for the
// same input, so a byte comparison would fail on a correct implementation.
// What is compared instead: that decompressing gives back exactly what went
// in, and that a stream produced elsewhere decodes to the right text.

const zlib = require('zlib');

const out = [];

function show(v) {
  if (v === undefined) return 'undefined';
  if (v === null) return 'null';
  if (typeof v === 'string') return JSON.stringify(v);
  if (Buffer.isBuffer(v)) return 'buf<' + v.toString('hex') + '>';
  if (Array.isArray(v)) return '[' + v.map(show).join(', ') + ']';
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

// Produced by an independent implementation (python's gzip/zlib), so decoding
// them proves this reads real streams rather than only its own output.
const PLAIN = 'The quick brown fox jumps over the lazy dog.\n';
const GZIP_HEX = '1f8b080000000000020a0bc94855282ccd4cce56482aca2fcf5348cbaf50c82acd2d2856c82f4b2d5228014ae72456552aa4e4a7eb7101006acc50eb2d000000';
const ZLIB_HEX = '789c0bc94855282ccd4cce56482aca2fcf5348cbaf50c82acd2d2856c82f4b2d5228014ae72456552aa4e4a7eb7101007bf61012';
const RAW_HEX = '0bc94855282ccd4cce56482aca2fcf5348cbaf50c82acd2d2856c82f4b2d5228014ae72456552aa4e4a7eb710100';

// --- decoding streams made elsewhere ----------------------------------------

T('gunzip-fixed-vector', () =>
  zlib.gunzipSync(Buffer.from(GZIP_HEX, 'hex')).toString('utf8'));
T('inflate-fixed-vector', () =>
  zlib.inflateSync(Buffer.from(ZLIB_HEX, 'hex')).toString('utf8'));
T('inflate-raw-fixed-vector', () =>
  zlib.inflateRawSync(Buffer.from(RAW_HEX, 'hex')).toString('utf8'));
T('unzip-detects-gzip', () => typeof zlib.unzipSync === 'function'
  ? zlib.unzipSync(Buffer.from(GZIP_HEX, 'hex')).toString('utf8') : 'missing');
T('unzip-detects-zlib', () => typeof zlib.unzipSync === 'function'
  ? zlib.unzipSync(Buffer.from(ZLIB_HEX, 'hex')).toString('utf8') : 'missing');

// --- round-trips ------------------------------------------------------------

const trip = (comp, decomp, input) => decomp(comp(input)).toString('utf8');

T('gzip-roundtrip', () => trip(zlib.gzipSync, zlib.gunzipSync, PLAIN));
T('deflate-roundtrip', () => trip(zlib.deflateSync, zlib.inflateSync, PLAIN));
T('deflateRaw-roundtrip', () => trip(zlib.deflateRawSync, zlib.inflateRawSync, PLAIN));
T('gzip-empty', () => {
  const z = zlib.gzipSync('');
  return [z.length > 0, zlib.gunzipSync(z).length];
});
T('gzip-binary', () => {
  const src = Buffer.from([0, 1, 255, 128, 0, 0, 7]);
  const back = zlib.gunzipSync(zlib.gzipSync(src));
  return [back.length, back.toString('hex'), back.equals(src)];
});
T('gzip-unicode', () => {
  const s = 'café \u{1f600} — dash';
  return zlib.gunzipSync(zlib.gzipSync(Buffer.from(s, 'utf8'))).toString('utf8') === s;
});
T('gzip-large-repetitive', () => {
  const src = 'abcdefgh'.repeat(4000);
  const z = zlib.gzipSync(src);
  const back = zlib.gunzipSync(z).toString('utf8');
  // highly repetitive input must compress, and come back byte for byte
  return [back === src, back.length, z.length < src.length / 4];
});
T('gzip-incompressible', () => {
  // a pseudo-random but fixed sequence: barely compressible, still exact
  let s = '';
  let x = 12345;
  for (let i = 0; i < 4000; i++) {
    x = (x * 1103515245 + 12345) % 2147483648;
    s += String.fromCharCode(32 + (x % 95));
  }
  return zlib.gunzipSync(zlib.gzipSync(s)).toString('utf8') === s;
});

// --- framing ----------------------------------------------------------------

T('gzip-header-magic', () => {
  const z = zlib.gzipSync('x');
  return [z[0], z[1], z[2]];   // 31, 139, 8 = gzip magic + deflate method
});
T('zlib-header-cmf', () => {
  const z = zlib.deflateSync('x');
  // low nibble 8 = deflate; the whole first pair is a multiple of 31
  return [(z[0] & 15), ((z[0] << 8) + z[1]) % 31];
});
T('raw-has-no-header', () => {
  const r = zlib.deflateRawSync('x');
  const d = zlib.deflateSync('x');
  return [r[0] !== 31, d.length > r.length];
});

// --- options ----------------------------------------------------------------

T('level-option-accepted', () => {
  const a = zlib.gzipSync(PLAIN, { level: 1 });
  const b = zlib.gzipSync(PLAIN, { level: 9 });
  return [zlib.gunzipSync(a).toString('utf8') === PLAIN,
          zlib.gunzipSync(b).toString('utf8') === PLAIN];
});
T('level-zero-stores', () => {
  const src = 'abcdefgh'.repeat(500);
  const z = zlib.gzipSync(src, { level: 0 });
  // no compression: the payload is stored, so the result is bigger than the
  // input rather than smaller
  return [zlib.gunzipSync(z).toString('utf8') === src, z.length > src.length];
});
T('constants', () => typeof zlib.constants === 'object'
  ? ['Z_NO_COMPRESSION', 'Z_BEST_SPEED', 'Z_BEST_COMPRESSION', 'Z_DEFAULT_COMPRESSION']
      .map((k) => k + ':' + typeof zlib.constants[k]).join(' ')
  : 'missing');

// --- failure ----------------------------------------------------------------

T('gunzip-garbage', () => {
  try { zlib.gunzipSync(Buffer.from([1, 2, 3, 4, 5, 6, 7, 8])); return 'no-throw'; }
  catch (e) { return 'THROW:' + e.constructor.name; }
});
T('gunzip-truncated', () => {
  const z = zlib.gzipSync(PLAIN);
  try { zlib.gunzipSync(z.slice(0, z.length - 5)); return 'no-throw'; }
  catch (e) { return 'THROW:' + e.constructor.name; }
});
T('inflate-garbage', () => {
  try { zlib.inflateSync(Buffer.from([9, 9, 9, 9])); return 'no-throw'; }
  catch (e) { return 'THROW:' + e.constructor.name; }
});

// --- module surface ---------------------------------------------------------

T('sync-fns', () => ['gzipSync', 'gunzipSync', 'deflateSync', 'inflateSync',
                     'deflateRawSync', 'inflateRawSync', 'unzipSync']
  .map((k) => k + ':' + typeof zlib[k]).join(' '));
T('async-fns', () => ['gzip', 'gunzip', 'deflate', 'inflate']
  .map((k) => k + ':' + typeof zlib[k]).join(' '));

function asyncRoundTrip() {
  return new Promise((resolve) => {
    if (typeof zlib.gzip !== 'function') { resolve('missing'); return; }
    zlib.gzip(PLAIN, (err, z) => {
      if (err) { resolve('gzip-error'); return; }
      zlib.gunzip(z, (err2, back) => {
        resolve(err2 ? 'gunzip-error' : String(back.toString('utf8') === PLAIN));
      });
    });
  });
}

asyncRoundTrip().then((r) => {
  out.push('async-roundtrip = ' + JSON.stringify(r));
  console.log(out.join('\n'));
});

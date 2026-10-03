// crypto.createHash across the supported digest set, vs Node.
const crypto = require('crypto');

const algos = ['md5', 'sha1', 'sha256', 'sha384', 'sha512'];

function hash(algo, data, enc) {
  const h = crypto.createHash(algo);
  h.update(data);
  return enc ? h.digest(enc) : h.digest();
}

const inputs = [
  '',
  'abc',
  'The quick brown fox jumps over the lazy dog',
  'héllo — unicode ✓ 𝟙 café',
];

for (const algo of algos) {
  for (const inp of inputs) {
    console.log(algo, JSON.stringify(inp), hash(algo, inp, 'hex'));
  }
  // base64 + raw Buffer output
  console.log(algo, 'base64', hash(algo, 'abc', 'base64'));
  console.log(algo, 'buffer', hash(algo, 'abc').toString('hex'));
  // binary Buffer input (includes 0x00 and 0xff)
  const bin = Buffer.from([0, 1, 2, 250, 251, 255, 128, 64]);
  console.log(algo, 'bin', hash(algo, bin, 'hex'));
}

// Padding boundaries: lengths around one and two block sizes catch off-by-one
// in the length-suffix placement (64-byte block for md5/sha1/sha256, 128 for
// sha384/sha512).
for (const algo of algos) {
  for (const n of [0, 1, 55, 56, 63, 64, 65, 111, 112, 119, 120, 127, 128, 129, 200]) {
    const s = 'a'.repeat(n);
    console.log(algo, 'len' + n, hash(algo, s, 'hex'));
  }
}

// Chunked update must equal a single update.
for (const algo of algos) {
  const whole = hash(algo, 'abcdefghij', 'hex');
  const h = crypto.createHash(algo);
  h.update('abc');
  h.update('');
  h.update(Buffer.from('def'));
  h.update('ghij');
  console.log(algo, 'chunked-ok', h.digest('hex') === whole);
}

// Many updates of sizes that cross block boundaries, a large Buffer among
// them, and a typed-array view: the SHA-2 hashes take each update as it
// comes, so the state carried between them must come out the same.
for (const algo of ['md5', 'sha1', 'sha224', 'sha256', 'sha384', 'sha512']) {
  const h = crypto.createHash(algo);
  const parts = [];
  let seed = 7;
  for (let i = 0; i < 40; i++) {
    seed = (seed * 1103515245 + 12345) >>> 0;
    const n = [1, 3, 63, 64, 65, 127, 128, 129, 1000, 70000][seed % 10];
    const b = Buffer.alloc(n);
    for (let k = 0; k < n; k++) b[k] = (seed + k * 31) & 0xff;
    parts.push(b);
    h.update(i % 7 === 3 ? new Uint8Array(b.buffer, b.byteOffset, b.length) : b);
  }
  h.update('tail ✓', 'utf8');
  parts.push(Buffer.from('tail ✓', 'utf8'));
  console.log(algo, 'many', h.digest('hex'), crypto.createHash(algo).update(Buffer.concat(parts)).digest('hex'));
}

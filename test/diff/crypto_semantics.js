// crypto: the hash and HMAC surface, the random generators, key derivation,
// and the comparison helper.
//
// Digests are compared against fixed published vectors (RFC 4231 for HMAC,
// RFC 6070 for PBKDF2), so a wrong answer shows up as a wrong string rather
// than only as a difference from node -- the values are checkable on their
// own. The random checks assert shape and distinctness only, since the values
// differ every run.

const crypto = require('crypto');

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

const H = (alg, data, enc) => crypto.createHash(alg).update(data).digest(enc || 'hex');

// --- digests against known vectors ------------------------------------------

T('sha256-empty', () => H('sha256', ''));
T('sha256-abc', () => H('sha256', 'abc'));
T('sha1-abc', () => H('sha1', 'abc'));
T('sha512-abc', () => H('sha512', 'abc'));
T('sha384-abc', () => H('sha384', 'abc'));
T('md5-abc', () => H('md5', 'abc'));
T('sha224-abc', () => H('sha224', 'abc'));
T('sha256-long', () => H('sha256', 'a'.repeat(1000)));
T('sha256-block-boundary', () => ['a'.repeat(55), 'a'.repeat(56), 'a'.repeat(64), 'a'.repeat(65)]
  .map((s) => H('sha256', s).slice(0, 16)));
T('sha256-multibyte', () => H('sha256', 'café\u{1f600}'));

// --- digest encodings -------------------------------------------------------

T('digest-buffer-default', () => {
  const d = crypto.createHash('sha256').update('abc').digest();
  return [Buffer.isBuffer(d), d.length, d.toString('hex').slice(0, 16)];
});
T('digest-base64', () => H('sha256', 'abc', 'base64'));
T('digest-base64url', () => H('sha256', 'abc', 'base64url'));
T('digest-latin1-length', () => H('sha256', 'abc', 'latin1').length);

// --- update semantics -------------------------------------------------------

T('update-chaining-returns-hash', () => {
  const h = crypto.createHash('sha256');
  return h.update('a') === h;
});
T('update-in-pieces-matches-whole', () => {
  const a = crypto.createHash('sha256').update('hello').update(' ').update('world').digest('hex');
  const b = H('sha256', 'hello world');
  return a === b;
});
T('update-buffer', () => {
  const a = crypto.createHash('sha256').update(Buffer.from('abc')).digest('hex');
  return a === H('sha256', 'abc');
});
T('update-empty-pieces', () => {
  const a = crypto.createHash('sha256').update('').update('abc').update('').digest('hex');
  return a === H('sha256', 'abc');
});
T('update-with-encoding', () => {
  const a = crypto.createHash('sha256').update('616263', 'hex').digest('hex');
  return a === H('sha256', 'abc');
});
T('update-base64-encoding', () => {
  const a = crypto.createHash('sha256').update(Buffer.from('abc').toString('base64'), 'base64').digest('hex');
  return a === H('sha256', 'abc');
});
T('digest-twice-throws', () => {
  const h = crypto.createHash('sha256');
  h.update('a');
  h.digest('hex');
  try { h.digest('hex'); return 'no-throw'; } catch (e) { return 'THROW:' + e.constructor.name; }
});
T('update-after-digest-throws', () => {
  const h = crypto.createHash('sha256');
  h.digest();
  try { h.update('x'); return 'no-throw'; } catch (e) { return 'THROW:' + e.constructor.name; }
});
T('unknown-algorithm', () => {
  try { crypto.createHash('not-a-hash'); return 'no-throw'; } catch (e) { return 'THROW:' + e.constructor.name; }
});
T('algorithm-case-insensitive', () => crypto.createHash('SHA256').update('abc').digest('hex') === H('sha256', 'abc'));
T('two-hashes-independent', () => {
  const a = crypto.createHash('sha256');
  const b = crypto.createHash('sha256');
  a.update('x');
  return b.update('abc').digest('hex') === H('sha256', 'abc');
});

// --- HMAC -------------------------------------------------------------------

const M = (alg, key, data, enc) => crypto.createHmac(alg, key).update(data).digest(enc || 'hex');

// RFC 4231 test case 1
T('hmac-sha256-rfc4231-1', () => M('sha256', Buffer.alloc(20, 0x0b), 'Hi There'));
// RFC 4231 test case 2
T('hmac-sha256-rfc4231-2', () => M('sha256', 'Jefe', 'what do ya want for nothing?'));
T('hmac-sha1-rfc2202-1', () => M('sha1', Buffer.alloc(20, 0x0b), 'Hi There'));
T('hmac-sha512-jefe', () => M('sha512', 'Jefe', 'what do ya want for nothing?'));
T('hmac-md5-jefe', () => M('md5', 'Jefe', 'what do ya want for nothing?'));
// a key longer than the block size is hashed first
T('hmac-long-key', () => M('sha256', Buffer.alloc(200, 0xaa), 'x'));
T('hmac-empty-key', () => M('sha256', '', 'abc'));
T('hmac-empty-data', () => M('sha256', 'k', ''));
T('hmac-chaining', () => {
  const h = crypto.createHmac('sha256', 'k');
  return h.update('a') === h;
});
T('hmac-in-pieces', () => M('sha256', 'k', 'abcdef') ===
  crypto.createHmac('sha256', 'k').update('abc').update('def').digest('hex'));
T('hmac-buffer-key-equals-string-key', () => M('sha256', Buffer.from('secret'), 'x') === M('sha256', 'secret', 'x'));
T('hmac-digest-twice-throws', () => {
  const h = crypto.createHmac('sha256', 'k');
  h.digest();
  try { h.digest(); return 'no-throw'; } catch (e) { return 'THROW:' + e.constructor.name; }
});
T('hmac-unknown-algorithm', () => {
  try { crypto.createHmac('nope', 'k'); return 'no-throw'; } catch (e) { return 'THROW:' + e.constructor.name; }
});

// --- randomness (shape only; values differ every run) -----------------------

T('randomBytes-shape', () => {
  const b = crypto.randomBytes(16);
  return [Buffer.isBuffer(b), b.length];
});
T('randomBytes-zero', () => crypto.randomBytes(0).length);
T('randomBytes-differs', () => {
  const a = crypto.randomBytes(32).toString('hex');
  const b = crypto.randomBytes(32).toString('hex');
  return a !== b;
});
T('randomBytes-not-all-zero', () => {
  const b = crypto.randomBytes(64);
  return b.some((x) => x !== 0);
});
T('randomUUID-format', () => {
  const u = crypto.randomUUID();
  return [typeof u, u.length,
          /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(u)];
});
T('randomUUID-differs', () => crypto.randomUUID() !== crypto.randomUUID());
T('randomFillSync', () => {
  if (typeof crypto.randomFillSync !== 'function') return 'missing';
  const b = Buffer.alloc(16);
  const r = crypto.randomFillSync(b);
  return [r === b, b.some((x) => x !== 0)];
});
T('randomInt', () => {
  if (typeof crypto.randomInt !== 'function') return 'missing';
  const vals = [];
  for (let i = 0; i < 50; i++) vals.push(crypto.randomInt(5));
  return [vals.every((v) => v >= 0 && v < 5 && Number.isInteger(v)),
          crypto.randomInt(7, 9) >= 7];
});

// --- comparison -------------------------------------------------------------

T('timingSafeEqual', () => {
  if (typeof crypto.timingSafeEqual !== 'function') return 'missing';
  const a = Buffer.from('abcd');
  return [crypto.timingSafeEqual(a, Buffer.from('abcd')),
          crypto.timingSafeEqual(a, Buffer.from('abce'))];
});
T('timingSafeEqual-length-mismatch', () => {
  if (typeof crypto.timingSafeEqual !== 'function') return 'missing';
  try { crypto.timingSafeEqual(Buffer.from('ab'), Buffer.from('abc')); return 'no-throw'; }
  catch (e) { return 'THROW:' + e.constructor.name; }
});

// --- key derivation ---------------------------------------------------------

T('pbkdf2Sync', () => typeof crypto.pbkdf2Sync === 'function'
  ? crypto.pbkdf2Sync('password', 'salt', 1, 20, 'sha1').toString('hex') : 'missing');
T('pbkdf2Sync-4096', () => typeof crypto.pbkdf2Sync === 'function'
  ? crypto.pbkdf2Sync('password', 'salt', 4096, 20, 'sha256').toString('hex') : 'missing');

// --- module shape -----------------------------------------------------------

T('getHashes', () => typeof crypto.getHashes === 'function'
  ? ['sha1', 'sha256', 'sha512', 'md5'].map((a) => crypto.getHashes().includes(a)) : 'missing');
T('hash-object-shape', () => {
  const h = crypto.createHash('sha256');
  return ['update', 'digest'].map((k) => k + ':' + typeof h[k]).join(' ');
});
T('createHash-is-function', () => [typeof crypto.createHash, typeof crypto.createHmac,
                                   typeof crypto.randomBytes, typeof crypto.randomUUID]);

console.log(out.join('\n'));

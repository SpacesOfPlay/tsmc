// The `crypto` global: randomUUID, getRandomValues and subtle.digest.
//
// Random output cannot be compared between two engines, so the cases below
// check shape, length, that the bytes actually changed, and that two calls
// differ. The digests are checked against published vectors, which is what
// makes them worth anything.
//
// crypto.subtle carries digest and nothing else here. The key half of
// SubtleCrypto (importKey, sign, encrypt) is absent rather than stubbed, so a
// feature check gets an honest answer.

const nodeCrypto = require('crypto');
const rows = [];
function show(v) {
  if (v === undefined) return 'undefined';
  if (v === null) return 'null';
  if (typeof v === 'string') return JSON.stringify(v);
  if (Array.isArray(v)) return '[' + v.join(',') + ']';
  if (typeof v === 'object') { try { return JSON.stringify(v); } catch (e) { return String(v); } }
  return String(v);
}
function T(label, fn) {
  let v;
  try { v = fn(); }
  catch (e) { v = 'THROW:' + (e && e.name ? e.name : String(e)); }
  rows.push(label + ' = ' + show(v));
}
const hex = (ab) => Array.from(new Uint8Array(ab)).map((b) => b.toString(16).padStart(2, '0')).join('');

// --- shape ------------------------------------------------------------------
T('typeof', () => typeof crypto);
T('tag', () => Object.prototype.toString.call(crypto));
T('members', () => ['randomUUID', 'getRandomValues', 'subtle'].map((k) => typeof crypto[k]).join(','));
T('subtle-tag', () => Object.prototype.toString.call(crypto.subtle));
T('subtle-digest', () => typeof crypto.subtle.digest);
T('globalThis-identity', () => globalThis.crypto === crypto);
T('webcrypto-identity', () => nodeCrypto.webcrypto === crypto);
T('module-randomUUID', () => typeof nodeCrypto.randomUUID);

// --- randomUUID -------------------------------------------------------------
T('uuid-shape', () => /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(crypto.randomUUID()));
T('uuid-length', () => crypto.randomUUID().length);
T('uuid-unique', () => crypto.randomUUID() !== crypto.randomUUID());
T('uuid-module-same-shape', () => /^[0-9a-f-]{36}$/.test(nodeCrypto.randomUUID()));

// --- getRandomValues --------------------------------------------------------
T('grv-returns-same', () => { const a = new Uint8Array(8); return crypto.getRandomValues(a) === a; });
T('grv-fills', () => { const a = new Uint8Array(32); crypto.getRandomValues(a); return a.some((b) => b !== 0); });
T('grv-uint8clamped', () => { const a = new Uint8ClampedArray(8); crypto.getRandomValues(a); return a.length; });
T('grv-int16', () => { const a = new Int16Array(4); crypto.getRandomValues(a); return a.length; });
T('grv-uint16', () => { const a = new Uint16Array(4); crypto.getRandomValues(a); return a.length; });
T('grv-int32', () => { const a = new Int32Array(4); crypto.getRandomValues(a); return a.length; });
T('grv-uint32', () => { const a = new Uint32Array(4); crypto.getRandomValues(a); return a.length === 4 && a.some((b) => b !== 0); });
T('grv-int8', () => { const a = new Int8Array(4); crypto.getRandomValues(a); return a.length; });
T('grv-empty', () => { const a = new Uint8Array(0); return crypto.getRandomValues(a).length; });
T('grv-offset-view', () => {
  // a view part-way into a buffer must fill only its own bytes
  const buf = new ArrayBuffer(16);
  const whole = new Uint8Array(buf);
  const middle = new Uint8Array(buf, 4, 8);
  crypto.getRandomValues(middle);
  const head = whole.slice(0, 4).every((b) => b === 0);
  const tail = whole.slice(12).every((b) => b === 0);
  const body = whole.slice(4, 12).some((b) => b !== 0);
  return [head, tail, body].join(',');
});
T('grv-float32', () => crypto.getRandomValues(new Float32Array(4)));
T('grv-float64', () => crypto.getRandomValues(new Float64Array(4)));
T('grv-plain-array', () => crypto.getRandomValues([1, 2, 3]));
T('grv-too-big', () => crypto.getRandomValues(new Uint8Array(65537)));
T('grv-at-limit', () => crypto.getRandomValues(new Uint8Array(65536)).length);
T('grv-no-arg', () => crypto.getRandomValues());
T('grv-different-each-time', () => {
  const a = new Uint8Array(16);
  const b = new Uint8Array(16);
  crypto.getRandomValues(a);
  crypto.getRandomValues(b);
  return a.join(',') !== b.join(',');
});

// --- subtle.digest ----------------------------------------------------------
const bytes = (s) => { const a = new Uint8Array(s.length); for (let i = 0; i < s.length; i++) a[i] = s.charCodeAt(i); return a; };

async function main() {
  const out = [];
  const push = async (label, fn) => {
    try { out.push(label + ' = ' + show(await fn())); }
    catch (e) { out.push(label + ' = THROW:' + (e && e.name ? e.name : String(e))); }
  };
  // published vectors for "abc"
  await push('digest-sha256', async () => hex(await crypto.subtle.digest('SHA-256', bytes('abc'))));
  await push('digest-sha1', async () => hex(await crypto.subtle.digest('SHA-1', bytes('abc'))));
  await push('digest-sha384-len', async () => (await crypto.subtle.digest('SHA-384', bytes('abc'))).byteLength);
  await push('digest-sha512-len', async () => (await crypto.subtle.digest('SHA-512', bytes('abc'))).byteLength);
  await push('digest-empty', async () => hex(await crypto.subtle.digest('SHA-256', new Uint8Array(0))));
  await push('digest-long', async () => hex(await crypto.subtle.digest('SHA-256', bytes('a'.repeat(1000)))));
  await push('digest-object-algo', async () => hex(await crypto.subtle.digest({ name: 'SHA-256' }, bytes('abc'))));
  await push('digest-lowercase-algo', async () => hex(await crypto.subtle.digest('sha-256', bytes('abc'))));
  await push('digest-arraybuffer-input', async () => hex(await crypto.subtle.digest('SHA-256', bytes('abc').buffer)));
  await push('digest-buffer-input', async () => hex(await crypto.subtle.digest('SHA-256', Buffer.from('abc'))));
  await push('digest-offset-view', async () => {
    const all = bytes('xxabcxx');
    return hex(await crypto.subtle.digest('SHA-256', new Uint8Array(all.buffer, 2, 3)));
  });
  await push('digest-returns-arraybuffer', async () => (await crypto.subtle.digest('SHA-256', bytes('x'))) instanceof ArrayBuffer);
  await push('digest-is-promise', async () => {
    const p = crypto.subtle.digest('SHA-256', bytes('x'));
    const isP = p instanceof Promise;
    await p;
    return isP;
  });
  await push('digest-unknown-algo', async () => await crypto.subtle.digest('MD5', bytes('abc')));
  await push('digest-no-data', async () => await crypto.subtle.digest('SHA-256'));
  await push('digest-bad-data', async () => await crypto.subtle.digest('SHA-256', 'a string'));
  await push('digest-matches-module', async () => {
    const web = hex(await crypto.subtle.digest('SHA-256', bytes('same input')));
    return web === nodeCrypto.createHash('sha256').update('same input').digest('hex');
  });
  console.log(rows.join('\n'));
  console.log(out.join('\n'));
}
main();

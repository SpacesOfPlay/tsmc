// TextEncoder and TextDecoder: encoding, labels, options, malformed input.
//
// Not covered: encode() returns a Buffer, so it fails an
// `instanceof Uint8Array` check. See doc/PLAN_M42_buffer_uint8array.md.

const rows = [];
function show(v) {
  if (v === undefined) return 'undefined';
  if (v === null) return 'null';
  if (typeof v === 'string') return JSON.stringify(v);
  if (typeof v === 'function') return 'fn:' + (v.name || '?');
  if (Array.isArray(v)) return '[' + v.join(',') + ']';
  if (typeof v === 'object') { try { return JSON.stringify(v); } catch (e) { return String(v); } }
  return String(v);
}
function T(label, fn) {
  let v;
  try { v = fn(); }
  catch (e) { v = 'THROW:' + (e && e.constructor ? e.constructor.name : String(e)); }
  rows.push(label + ' = ' + show(v));
}
const bytes = (u8) => Array.from(u8);

// --- TextEncoder ------------------------------------------------------------
T('enc-encoding', () => new TextEncoder().encoding);
T('enc-tag', () => Object.prototype.toString.call(new TextEncoder()));
T('enc-ctor-name', () => new TextEncoder().constructor.name);
T('enc-ascii', () => bytes(new TextEncoder().encode('abc')));
T('enc-empty', () => bytes(new TextEncoder().encode('')));
T('enc-no-arg', () => bytes(new TextEncoder().encode()));
T('enc-2byte', () => bytes(new TextEncoder().encode('é')));
T('enc-3byte', () => bytes(new TextEncoder().encode('€')));
T('enc-4byte', () => bytes(new TextEncoder().encode('😀')));
T('enc-lone-surrogate', () => bytes(new TextEncoder().encode('\uD800')));
T('enc-trailing-surrogate', () => bytes(new TextEncoder().encode('a\uDC00b')));
T('enc-result-length', () => new TextEncoder().encode('héllo').length);
T('enc-number-coerced', () => bytes(new TextEncoder().encode(12)));

T('encodeInto-exists', () => typeof new TextEncoder().encodeInto);
T('encodeInto-fits', () => {
  const dst = new Uint8Array(5);
  const r = new TextEncoder().encodeInto('abc', dst);
  return [r.read, r.written, bytes(dst).join('')].join('/');
});
T('encodeInto-truncates', () => {
  const dst = new Uint8Array(2);
  const r = new TextEncoder().encodeInto('abcd', dst);
  return [r.read, r.written].join('/');
});
T('encodeInto-no-split-multibyte', () => {
  const dst = new Uint8Array(2);
  const r = new TextEncoder().encodeInto('a€', dst);
  return [r.read, r.written].join('/');
});

// --- TextDecoder ------------------------------------------------------------
T('dec-encoding', () => new TextDecoder().encoding);
T('dec-tag', () => Object.prototype.toString.call(new TextDecoder()));
T('dec-label-utf8', () => new TextDecoder('utf8').encoding);
T('dec-label-upper', () => new TextDecoder('UTF-8').encoding);
T('dec-label-unknown', () => new TextDecoder('nope-8').encoding);
T('dec-fatal-flag', () => new TextDecoder('utf-8', { fatal: true }).fatal);
T('dec-ignoreBOM-flag', () => new TextDecoder('utf-8', { ignoreBOM: true }).ignoreBOM);
T('dec-default-flags', () => [new TextDecoder().fatal, new TextDecoder().ignoreBOM].join('/'));

T('dec-no-arg', () => new TextDecoder().decode());
T('dec-ascii', () => new TextDecoder().decode(new Uint8Array([104, 105])));
T('dec-multibyte', () => new TextDecoder().decode(new Uint8Array([226, 130, 172])));
T('dec-4byte', () => new TextDecoder().decode(new Uint8Array([240, 159, 152, 128])));
T('dec-empty', () => new TextDecoder().decode(new Uint8Array([])));
T('dec-from-buffer', () => new TextDecoder().decode(Buffer.from('hi')));
T('dec-from-arraybuffer', () => new TextDecoder().decode(new Uint8Array([97, 98]).buffer));
T('dec-bom-stripped', () => new TextDecoder().decode(new Uint8Array([239, 187, 191, 97])));
T('dec-bom-kept', () => {
  const s = new TextDecoder('utf-8', { ignoreBOM: true }).decode(new Uint8Array([239, 187, 191, 97]));
  return s.length + ':' + s.charCodeAt(0);
});
T('dec-invalid-replacement', () => {
  const s = new TextDecoder().decode(new Uint8Array([0xff, 0xfe]));
  return s.length + ':' + s.charCodeAt(0);
});
T('dec-truncated-replacement', () => {
  const s = new TextDecoder().decode(new Uint8Array([226, 130]));
  return s.length + ':' + s.charCodeAt(0);
});
T('dec-fatal-throws', () => new TextDecoder('utf-8', { fatal: true }).decode(new Uint8Array([0xff])));
T('dec-overlong', () => new TextDecoder().decode(new Uint8Array([0xc0, 0x80])).length);
T('dec-surrogate-bytes', () => new TextDecoder().decode(new Uint8Array([0xed, 0xa0, 0x80])).length);
T('dec-roundtrip', () => {
  const src = 'héllo 😀 €';
  return new TextDecoder().decode(new TextEncoder().encode(src)) === src;
});

// --- the same decoder backs Buffer.toString ---------------------------------
T('buf-truncated', () => Buffer.from([226, 130]).toString('utf8').length);
T('buf-invalid', () => Buffer.from([0xff, 0xfe]).toString('utf8').length);
T('buf-roundtrip', () => Buffer.from('héllo 😀').toString('utf8') === 'héllo 😀');

console.log(rows.join('\n'));

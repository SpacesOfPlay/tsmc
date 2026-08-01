// Small pieces of the node surface that nothing referenced: base64 globals,
// the buffer validators, zlib.crc32, and three util helpers.
//
// debuglog is only exercised switched off, which is how it runs here.
// Switched on it writes "SECTION PID: message" to stderr, and the pid makes
// that uncomparable between two processes. Checked by hand against node.

const buffer = require('buffer');
const zlib = require('zlib');
const util = require('util');

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
  catch (e) { v = 'THROW:' + (e && e.name ? e.name : (e && e.constructor ? e.constructor.name : String(e))); }
  rows.push(label + ' = ' + show(v));
}

// --- base64 -----------------------------------------------------------------
T('btoa-type', () => typeof btoa);
T('atob-type', () => typeof atob);
T('btoa-simple', () => btoa('hello'));
T('btoa-padding-1', () => btoa('a'));
T('btoa-padding-2', () => btoa('ab'));
T('btoa-empty', () => btoa(''));
T('btoa-high-byte', () => btoa('\xff\xfe'));
T('btoa-non-latin1', () => btoa('\u{1F600}'));
T('btoa-coerces', () => btoa(123));
T('atob-simple', () => atob('aGVsbG8='));
T('atob-empty', () => atob(''));
T('atob-roundtrip', () => atob(btoa('round trip')) === 'round trip');
T('atob-high-byte', () => atob('//4=').length);
T('atob-bad-char', () => atob('not base64!!'));
T('atob-no-padding', () => atob('aGVsbG8'));
T('buffer-exports-atob', () => [typeof buffer.atob, typeof buffer.btoa].join('/'));
T('buffer-atob-same', () => buffer.btoa('x') === btoa('x'));

// --- buffer validators ------------------------------------------------------
T('isUtf8-valid', () => buffer.isUtf8(Buffer.from('héllo')));
T('isUtf8-invalid', () => buffer.isUtf8(Buffer.from([0xff, 0xfe])));
T('isUtf8-truncated', () => buffer.isUtf8(Buffer.from([0xe2, 0x82])));
T('isUtf8-empty', () => buffer.isUtf8(Buffer.from([])));
T('isUtf8-typedarray', () => buffer.isUtf8(new Uint8Array([104, 105])));
T('isAscii-yes', () => buffer.isAscii(Buffer.from('plain')));
T('isAscii-no', () => buffer.isAscii(Buffer.from('héllo')));
T('isAscii-empty', () => buffer.isAscii(Buffer.from([])));
T('kMaxLength-type', () => typeof buffer.kMaxLength);
T('kMaxLength-positive', () => buffer.kMaxLength > 0);

// --- zlib.crc32 -------------------------------------------------------------
T('crc32-string', () => zlib.crc32('hello'));
T('crc32-empty', () => zlib.crc32(''));
T('crc32-buffer', () => zlib.crc32(Buffer.from('hello')));
T('crc32-check', () => zlib.crc32('123456789'));
T('crc32-unsigned', () => zlib.crc32('\xff\xff\xff\xff') >= 0);

// --- util helpers -----------------------------------------------------------
T('stripVT-plain', () => util.stripVTControlCharacters('plain'));
T('stripVT-colour', () => util.stripVTControlCharacters('[31mred[39m'));
T('stripVT-keeps-text', () => util.stripVTControlCharacters('a[1mb[0mc'));
T('toUSVString-clean', () => util.toUSVString('ok'));
T('toUSVString-lone', () => util.toUSVString('a\uD800b').charCodeAt(1));
T('debuglog-type', () => typeof util.debuglog('probe'));
T('debuglog-enabled', () => util.debuglog('probe').enabled);
T('debuglog-call-is-quiet', () => { util.debuglog('probe')('nothing'); return 'ok'; });

console.log(rows.join('\n'));

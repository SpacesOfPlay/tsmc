// querystring, string_decoder and punycode.
//
// The deprecation warning node prints for punycode goes to stderr, which the
// harness merges into the output, so it is switched off before the require.

process.noDeprecation = true;

const qs = require('querystring');
const { StringDecoder } = require('string_decoder');
const punycode = require('punycode');

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

// --- querystring: parsing ---------------------------------------------------
T('qs-parse', () => qs.parse('a=1&b=2'));
T('qs-parse-empty', () => qs.parse(''));
T('qs-parse-repeat', () => qs.parse('a=1&a=2&a=3'));
T('qs-parse-novalue', () => qs.parse('a&b=2'));
T('qs-parse-encoded', () => qs.parse('a=hello%20world&b=%2B'));
T('qs-parse-plus', () => qs.parse('a=hello+world'));
T('qs-parse-equals-in-value', () => qs.parse('a=1=2'));
T('qs-parse-leading-amp', () => qs.parse('&a=1&&b=2&'));
T('qs-parse-sep', () => qs.parse('a:1;b:2', ';', ':'));
T('qs-parse-multichar-sep', () => qs.parse('a=1||b=2', '||'));
T('qs-parse-maxkeys', () => qs.parse('a=1&b=2&c=3', '&', '=', { maxKeys: 2 }));
T('qs-parse-maxkeys-zero', () => Object.keys(qs.parse('a=1&b=2&c=3', '&', '=', { maxKeys: 0 })).length);
T('qs-parse-proto-key', () => JSON.stringify(qs.parse('__proto__=1&a=2')));
T('qs-parse-null-proto', () => Object.getPrototypeOf(qs.parse('a=1')) === null);
T('qs-parse-nonstring', () => qs.parse(5));
T('qs-parse-utf8', () => qs.parse('n=caf%C3%A9'));
T('qs-parse-bad-percent', () => qs.parse('a=%E0%A4%A'));
T('qs-parse-key-encoded', () => qs.parse('a%20b=1'));

// --- querystring: building --------------------------------------------------
T('qs-stringify', () => qs.stringify({ a: 1, b: 'two' }));
T('qs-stringify-array', () => qs.stringify({ a: [1, 2] }));
T('qs-stringify-empty', () => qs.stringify({}));
T('qs-stringify-space', () => qs.stringify({ a: 'hello world' }));
T('qs-stringify-unicode', () => qs.stringify({ n: 'café' }));
T('qs-stringify-types', () => qs.stringify({ a: null, b: undefined, c: true, d: 1.5, e: '' }));
T('qs-stringify-infinity', () => qs.stringify({ a: Infinity, b: NaN }));
T('qs-stringify-nested', () => qs.stringify({ a: { b: 1 } }));
T('qs-stringify-sep', () => qs.stringify({ a: 1, b: 2 }, ';', ':'));
T('qs-stringify-null-arg', () => qs.stringify(null));
T('qs-stringify-string-arg', () => qs.stringify('str'));
T('qs-stringify-symbol-value', () => qs.stringify({ a: Symbol('x') }));

// --- querystring: escaping --------------------------------------------------
T('qs-escape', () => qs.escape('a b&c=d/e?f'));
T('qs-escape-unreserved', () => qs.escape("~!*'()-._"));
T('qs-escape-unicode', () => qs.escape('café ☕'));
T('qs-escape-surrogate-pair', () => qs.escape('😀'));
T('qs-escape-lone-surrogate', () => qs.escape('\uD800'));
T('qs-escape-number', () => qs.escape(5));
T('qs-escape-null', () => qs.escape(null));
T('qs-escape-object', () => qs.escape({}));
T('qs-unescape', () => qs.unescape('a%20b%26c'));
T('qs-unescape-keeps-plus', () => qs.unescape('a+b'));
T('qs-unescape-invalid', () => qs.unescape('%E0%A4%A'));
T('qs-roundtrip', () => qs.parse(qs.stringify({ k: 'a b&c=d' })).k);
T('qs-aliases', () => [typeof qs.decode, typeof qs.encode, qs.decode === qs.parse].join(','));
T('qs-node-prefix', () => require('node:querystring').parse('x=1').x);

// --- the URI escapes querystring is built on --------------------------------
//
// Malformed input is a URIError, not a replacement character: code that
// validates a value by decoding it in a try/catch depends on that.
T('euc-lone-high-surrogate', () => encodeURIComponent('\uD800'));
T('euc-lone-low-surrogate', () => encodeURIComponent('\uDC00'));
T('euc-surrogate-in-middle', () => encodeURIComponent('a\uD800b'));
T('euc-pair', () => encodeURIComponent('😀'));
T('euri-lone-surrogate', () => encodeURI('\uD800'));
T('escape-lone-surrogate-allowed', () => escape('\uD800'));
T('duc-single-high-byte', () => decodeURIComponent('%FF'));
T('duc-truncated', () => decodeURIComponent('%C3'));
T('duc-overlong', () => decodeURIComponent('%C0%80'));
T('duc-surrogate', () => decodeURIComponent('%ED%A0%80'));
T('duc-past-max', () => decodeURIComponent('%F5%80%80%80'));
T('duc-bad-continuation', () => decodeURIComponent('%C3%28'));
T('duc-unescaped-continuation', () => decodeURIComponent('%C3é'));
T('duc-valid-2byte', () => decodeURIComponent('%C3%A9'));
T('duc-valid-3byte', () => decodeURIComponent('%E2%98%95'));
T('duc-valid-4byte', () => decodeURIComponent('%F0%9F%98%80'));
T('duc-literal-surrogate-passes', () => decodeURIComponent('\uD800').length);
T('duri-reserved-kept', () => decodeURI('%2F%3F'));
T('duri-malformed', () => decodeURI('%FF'));

// --- string_decoder ---------------------------------------------------------
T('sd-simple', () => new StringDecoder('utf8').write(Buffer.from('hello')));
T('sd-default-encoding', () => new StringDecoder().encoding);
T('sd-dash-encoding', () => new StringDecoder('utf-8').encoding);
T('sd-upper-encoding', () => new StringDecoder('UTF8').encoding);
T('sd-ucs2-alias', () => new StringDecoder('ucs2').encoding);
T('sd-binary-alias', () => new StringDecoder('binary').encoding);
T('sd-bad-encoding', () => new StringDecoder('nope'));
T('sd-write-string', () => new StringDecoder('utf8').write('abc'));
T('sd-write-empty', () => new StringDecoder('utf8').write(Buffer.from([])));
T('sd-split-2byte', () => {
  const d = new StringDecoder('utf8');
  const b = Buffer.from('é');
  return [d.write(b.slice(0, 1)), d.write(b.slice(1))].join('|');
});
T('sd-split-3byte', () => {
  const d = new StringDecoder('utf8');
  const b = Buffer.from('€');
  return [d.write(b.slice(0, 1)), d.write(b.slice(1, 2)), d.write(b.slice(2))].join('|');
});
T('sd-split-4byte', () => {
  const d = new StringDecoder('utf8');
  const b = Buffer.from('😀');
  return [d.write(b.slice(0, 2)), d.write(b.slice(2))].join('|');
});
T('sd-lastNeed', () => {
  const d = new StringDecoder('utf8');
  d.write(Buffer.from('€').slice(0, 1));
  return [d.lastNeed, d.lastTotal].join(',');
});
T('sd-end-partial', () => {
  const d = new StringDecoder('utf8');
  const b = Buffer.from('€');
  return [d.write(b.slice(0, 2)), d.end()].join('|');
});
T('sd-end-empty', () => new StringDecoder('utf8').end());
T('sd-end-with-buffer', () => new StringDecoder('utf8').end(Buffer.from('hi')));
T('sd-byte-at-a-time', () => {
  const d = new StringDecoder('utf8');
  const b = Buffer.from('a€b😀c');
  let out = '';
  for (let i = 0; i < b.length; i++) out += d.write(b.slice(i, i + 1));
  return out + d.end();
});
T('sd-invalid-bytes', () => new StringDecoder('utf8').write(Buffer.from([0xff, 0xfe])));
T('sd-continues-after-invalid', () => {
  const d = new StringDecoder('utf8');
  return d.write(Buffer.from([0xff])) + d.write(Buffer.from('ok'));
});
T('sd-hex', () => new StringDecoder('hex').write(Buffer.from([0xde, 0xad])));
T('sd-latin1', () => new StringDecoder('latin1').write(Buffer.from([0xff, 0x41])));
T('sd-ascii-strips-high-bit', () => new StringDecoder('ascii').write(Buffer.from([200, 65])));
T('sd-base64', () => new StringDecoder('base64').write(Buffer.from('hello')));
T('sd-base64-split', () => {
  const d = new StringDecoder('base64');
  const b = Buffer.from('hello');
  return [d.write(b.slice(0, 2)), d.write(b.slice(2)), d.end()].join('|');
});
T('sd-utf16le', () => new StringDecoder('utf16le').write(Buffer.from('hi', 'utf16le')));
T('sd-utf16le-split', () => {
  const d = new StringDecoder('utf16le');
  const b = Buffer.from('hi', 'utf16le');
  return [d.write(b.slice(0, 1)), d.write(b.slice(1))].join('|');
});
T('sd-utf16le-surrogate-split', () => {
  const d = new StringDecoder('utf16le');
  const b = Buffer.from('😀', 'utf16le');
  return [d.write(b.slice(0, 2)), d.write(b.slice(2))].join('|');
});

// --- punycode ---------------------------------------------------------------
T('py-encode', () => punycode.encode('münchen'));
T('py-encode-ascii-only', () => punycode.encode('abc'));
T('py-encode-empty', () => punycode.encode(''));
T('py-encode-chinese', () => punycode.encode('测试'));
T('py-encode-emoji', () => punycode.encode('😀'));
T('py-decode', () => punycode.decode('mnchen-3ya'));
T('py-decode-empty', () => punycode.decode(''));
T('py-decode-chinese', () => punycode.decode('0zwm56d'));
T('py-decode-invalid', () => punycode.decode('!!!'));
T('py-decode-roundtrip-emoji', () => punycode.decode(punycode.encode('😀')));
T('py-roundtrip-long', () => punycode.decode(punycode.encode('ärgerlich-über-straße')));
T('py-toASCII', () => punycode.toASCII('münchen.de'));
T('py-toASCII-plain', () => punycode.toASCII('example.com'));
T('py-toASCII-mixed-labels', () => punycode.toASCII('www.bücher.de'));
T('py-toASCII-tilde', () => punycode.toASCII('mañana.com'));
T('py-toASCII-already-encoded', () => punycode.toASCII('xn--mnchen-3ya.de'));
T('py-toASCII-empty-labels', () => punycode.toASCII('a..b'));
T('py-toASCII-email', () => punycode.toASCII('user@münchen.de'));
T('py-toUnicode', () => punycode.toUnicode('xn--mnchen-3ya.de'));
T('py-toUnicode-plain', () => punycode.toUnicode('example.com'));
T('py-toUnicode-invalid', () => punycode.toUnicode('xn--!!!.de'));
T('py-roundtrip-domain', () => punycode.toUnicode(punycode.toASCII('höhle.example')));
T('py-ucs2-decode', () => punycode.ucs2.decode('a😀b'));
T('py-ucs2-decode-lone-surrogate', () => punycode.ucs2.decode('\uD800'));
T('py-ucs2-encode', () => punycode.ucs2.encode([97, 128512, 98]));
T('py-version', () => punycode.version);

console.log(rows.join('\n'));

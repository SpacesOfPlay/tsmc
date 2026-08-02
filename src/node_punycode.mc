// node_punycode.mc -- the `punycode` module.
//
// RFC 3492: how a domain label outside ASCII is carried through systems that
// only accept ASCII. `münchen` becomes `xn--mnchen-3ya`, and back. Deprecated
// in node, still required by a good deal of published code.
//
// Embedded JS: no backslash escapes (minc processes them in string literals)
// and no double quotes.

str node_punycode_source() {
    return "'use strict';

const BASE = 36;
const TMIN = 1;
const TMAX = 26;
const SKEW = 38;
const DAMP = 700;
const INITIAL_BIAS = 72;
const INITIAL_N = 128;
const DELIMITER = '-';
const MAX_INT = 2147483647;

function fail(msg) { throw new RangeError(msg); }

// Code points, so a surrogate pair counts once.
function ucs2decode(str) {
  const out = [];
  let i = 0;
  while (i < str.length) {
    const c = str.charCodeAt(i++);
    if (c >= 0xD800 && c <= 0xDBFF && i < str.length) {
      const c2 = str.charCodeAt(i);
      if (c2 >= 0xDC00 && c2 <= 0xDFFF) {
        i++;
        out.push(((c - 0xD800) * 0x400) + (c2 - 0xDC00) + 0x10000);
        continue;
      }
    }
    out.push(c);
  }
  return out;
}

function ucs2encode(codes) {
  let out = '';
  for (const c of codes) out += String.fromCodePoint(c);
  return out;
}

function basicToDigit(c) {
  if (c >= 48 && c < 58) return c - 22;      // 0-9 map to 26-35
  if (c >= 65 && c < 91) return c - 65;      // A-Z
  if (c >= 97 && c < 123) return c - 97;     // a-z
  return BASE;
}

function digitToBasic(digit, flag) {
  return digit + 22 + (digit < 26 ? 75 : 0) - (flag !== 0 ? 32 : 0);
}

function adapt(delta, numPoints, firstTime) {
  let k = 0;
  let d = firstTime ? Math.floor(delta / DAMP) : delta >> 1;
  d += Math.floor(d / numPoints);
  while (d > ((BASE - TMIN) * TMAX) >> 1) {
    d = Math.floor(d / (BASE - TMIN));
    k += BASE;
  }
  return Math.floor(k + (BASE - TMIN + 1) * d / (d + SKEW));
}

function decode(input) {
  const output = [];
  const inputLength = input.length;
  let i = 0;
  let n = INITIAL_N;
  let bias = INITIAL_BIAS;

  let basic = input.lastIndexOf(DELIMITER);
  if (basic < 0) basic = 0;
  for (let j = 0; j < basic; j++) {
    if (input.charCodeAt(j) >= 0x80) fail('Illegal input >= 0x80 (not a basic code point)');
    output.push(input.charCodeAt(j));
  }

  let index = basic > 0 ? basic + 1 : 0;
  while (index < inputLength) {
    const oldi = i;
    let w = 1;
    for (let k = BASE; ; k += BASE) {
      if (index >= inputLength) fail('Invalid input');
      const digit = basicToDigit(input.charCodeAt(index++));
      if (digit >= BASE) fail('Invalid input');
      if (digit > Math.floor((MAX_INT - i) / w)) fail('Overflow: input needs wider integers to process');
      i += digit * w;
      const t = k <= bias ? TMIN : (k >= bias + TMAX ? TMAX : k - bias);
      if (digit < t) break;
      if (w > Math.floor(MAX_INT / (BASE - t))) fail('Overflow: input needs wider integers to process');
      w *= BASE - t;
    }
    const outLength = output.length + 1;
    bias = adapt(i - oldi, outLength, oldi === 0);
    if (Math.floor(i / outLength) > MAX_INT - n) fail('Overflow: input needs wider integers to process');
    n += Math.floor(i / outLength);
    i %= outLength;
    output.splice(i++, 0, n);
  }
  return ucs2encode(output);
}

function encode(input) {
  const output = [];
  const codes = ucs2decode(String(input));
  const inputLength = codes.length;
  let n = INITIAL_N;
  let delta = 0;
  let bias = INITIAL_BIAS;

  for (const c of codes) {
    if (c < 0x80) output.push(String.fromCharCode(c));
  }
  const basicLength = output.length;
  let handled = basicLength;
  if (basicLength > 0) output.push(DELIMITER);

  while (handled < inputLength) {
    let m = MAX_INT;
    for (const c of codes) {
      if (c >= n && c < m) m = c;
    }
    if (m - n > Math.floor((MAX_INT - delta) / (handled + 1))) {
      fail('Overflow: input needs wider integers to process');
    }
    delta += (m - n) * (handled + 1);
    n = m;
    for (const c of codes) {
      if (c < n && ++delta > MAX_INT) fail('Overflow: input needs wider integers to process');
      if (c === n) {
        let q = delta;
        for (let k = BASE; ; k += BASE) {
          const t = k <= bias ? TMIN : (k >= bias + TMAX ? TMAX : k - bias);
          if (q < t) break;
          const qMinusT = q - t;
          const baseMinusT = BASE - t;
          output.push(String.fromCharCode(digitToBasic(t + qMinusT % baseMinusT, 0)));
          q = Math.floor(qMinusT / baseMinusT);
        }
        output.push(String.fromCharCode(digitToBasic(q, 0)));
        bias = adapt(delta, handled + 1, handled === basicLength);
        delta = 0;
        handled++;
      }
    }
    delta++;
    n++;
  }
  return output.join('');
}

// The label separators an IDN may use, folded to a plain dot. An address is
// split at the @ first, so only the domain part is mapped.
function foldSeparators(s) {
  let out = '';
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c === 0x3002 || c === 0xFF0E || c === 0xFF61) out += '.';
    else out += s[i];
  }
  return out;
}

function mapDomain(input, fn) {
  const s = String(input);
  const at = s.indexOf('@');
  let head = '';
  let rest = s;
  if (at >= 0) {
    head = s.slice(0, at + 1);
    rest = s.slice(at + 1);
  }
  const labels = foldSeparators(rest).split('.');
  const done = [];
  for (const label of labels) done.push(fn(label));
  return head + done.join('.');
}

function hasNonAscii(s) {
  for (let i = 0; i < s.length; i++) {
    if (s.charCodeAt(i) >= 0x80) return true;
  }
  return false;
}

function toASCII(input) {
  return mapDomain(input, function (label) {
    return hasNonAscii(label) ? 'xn--' + encode(label) : label;
  });
}

function toUnicode(input) {
  return mapDomain(input, function (label) {
    const low = label.toLowerCase();
    return low.slice(0, 4) === 'xn--' ? decode(low.slice(4)) : label;
  });
}

module.exports = {
  version: '2.1.0',
  ucs2: { decode: ucs2decode, encode: ucs2encode },
  decode: decode,
  encode: encode,
  toASCII: toASCII,
  toUnicode: toUnicode,
};
";
}

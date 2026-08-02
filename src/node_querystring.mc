// node_querystring.mc -- the `querystring` module.
//
// The pre-URLSearchParams query API, still what a lot of code reaches for.
// Its escaping is not URLSearchParams': a space is %20, not +, on the way
// out, while `+` does mean a space on the way in.
//
// Embedded JS: no backslash escapes (minc processes them in string literals)
// and no double quotes.

str node_querystring_source() {
    return "'use strict';

// Percent-encoding over UTF-8, leaving the unreserved set alone. This is
// exactly encodeURIComponent, down to refusing a lone surrogate.
function escape(str) {
  return encodeURIComponent(typeof str === 'string' ? str : String(str));
}

// A percent sequence that is not valid UTF-8 does not fail the whole parse:
// the bad run becomes one replacement character and the rest is kept as it
// was written, which is what the reference implementation does.
function decodeLoose(s) {
  const bytes = [];
  let i = 0;
  while (i < s.length) {
    const c = s.charCodeAt(i);
    if (c === 37 && i + 2 < s.length) {
      const hi = hexVal(s.charCodeAt(i + 1));
      const lo = hexVal(s.charCodeAt(i + 2));
      if (hi >= 0 && lo >= 0) {
        bytes.push(hi * 16 + lo);
        i += 3;
        continue;
      }
    }
    const one = Buffer.from(s[i], 'utf8');
    for (let k = 0; k < one.length; k++) bytes.push(one[k]);
    i++;
  }
  return Buffer.from(bytes).toString('utf8');
}

function hexVal(c) {
  if (c >= 48 && c <= 57) return c - 48;
  if (c >= 97 && c <= 102) return c - 87;
  if (c >= 65 && c <= 70) return c - 55;
  return -1;
}

function unescape(str, decodeSpaces) {
  let s = typeof str === 'string' ? str : String(str);
  if (decodeSpaces) s = s.split('+').join(' ');
  try {
    return decodeURIComponent(s);
  } catch (e) {
    return decodeLoose(s);
  }
}

// Anything that is not a string, a finite number, a bigint or a boolean
// contributes an empty value rather than its toString.
function primitive(v) {
  if (typeof v === 'string') return v;
  if (typeof v === 'number') return isFinite(v) ? String(v) : '';
  if (typeof v === 'bigint') return String(v);
  if (typeof v === 'boolean') return v ? 'true' : 'false';
  return '';
}

// The result has a null prototype, so a query naming __proto__ cannot reach
// Object.prototype through it.
function parse(str, sep, eq, options) {
  const out = Object.create(null);
  if (typeof str !== 'string' || str.length === 0) return out;
  const s = sep || '&';
  const e = eq || '=';
  let maxKeys = 1000;
  if (options && typeof options.maxKeys === 'number') maxKeys = options.maxKeys;
  const parts = str.split(s);
  let count = 0;
  for (const part of parts) {
    if (part.length === 0) continue;
    if (maxKeys > 0 && count >= maxKeys) break;
    const at = part.indexOf(e);
    let k;
    let v;
    if (at < 0) {
      k = unescape(part, true);
      v = '';
    } else {
      k = unescape(part.slice(0, at), true);
      v = unescape(part.slice(at + e.length), true);
    }
    const seen = Object.prototype.hasOwnProperty.call(out, k);
    if (!seen) {
      out[k] = v;
      count++;
    } else if (Array.isArray(out[k])) {
      out[k].push(v);
    } else {
      out[k] = [out[k], v];
    }
  }
  return out;
}

function stringify(obj, sep, eq, options) {
  const s = sep || '&';
  const e = eq || '=';
  if (obj === null || typeof obj !== 'object') return '';
  let enc = escape;
  if (options && typeof options.encodeURIComponent === 'function') {
    enc = options.encodeURIComponent;
  }
  const out = [];
  for (const k of Object.keys(obj)) {
    const key = enc(primitive(k));
    const v = obj[k];
    if (Array.isArray(v)) {
      for (const one of v) out.push(key + e + enc(primitive(one)));
    } else {
      out.push(key + e + enc(primitive(v)));
    }
  }
  return out.join(s);
}

module.exports = {
  parse: parse,
  stringify: stringify,
  decode: parse,
  encode: stringify,
  escape: escape,
  unescape: unescape,
};
";
}

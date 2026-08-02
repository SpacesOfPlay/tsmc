// node_strdec.mc -- the `string_decoder` module.
//
// Decoding a byte stream one chunk at a time. A character can straddle two
// chunks, so the decoder holds the incomplete tail back until the bytes that
// finish it arrive. Without that, a stream carrying anything but ASCII shows
// replacement characters wherever a chunk boundary happens to fall.
//
// Embedded JS: no backslash escapes (minc processes them in string literals)
// and no double quotes.

str node_strdec_source() {
    return "'use strict';

const REPLACEMENT = String.fromCharCode(0xFFFD);

function normalize(enc) {
  const e = String(enc === undefined || enc === null ? 'utf8' : enc).toLowerCase();
  if (e === 'utf8' || e === 'utf-8') return 'utf8';
  if (e === 'utf16le' || e === 'utf-16le' || e === 'ucs2' || e === 'ucs-2') return 'utf16le';
  if (e === 'latin1' || e === 'binary') return 'latin1';
  if (e === 'base64' || e === 'base64url' || e === 'hex' || e === 'ascii') return e;
  throw new TypeError('Unknown encoding: ' + enc);
}

function toBytes(buf) {
  const out = [];
  if (buf === undefined || buf === null) return out;
  for (let i = 0; i < buf.length; i++) out.push(buf[i] & 255);
  return out;
}

// How many bytes the sequence starting with this one takes, or 0 when it is
// not a leading byte.
function leadLen(b) {
  if ((b & 0xE0) === 0xC0) return 2;
  if ((b & 0xF0) === 0xE0) return 3;
  if ((b & 0xF8) === 0xF0) return 4;
  return 0;
}

class StringDecoder {
  constructor(encoding) {
    this.encoding = normalize(encoding);
    this.lastNeed = 0;
    this.lastTotal = 0;
    this._pend = [];
  }

  write(buf) {
    if (typeof buf === 'string') return buf;
    const bytes = this._pend.concat(toBytes(buf));
    this._pend = [];
    this.lastNeed = 0;
    this.lastTotal = 0;
    if (bytes.length === 0) return '';
    if (this.encoding === 'utf8') return this._utf8(bytes);
    if (this.encoding === 'utf16le') return this._utf16(bytes);
    if (this.encoding === 'base64') return this._base64(bytes);
    return Buffer.from(bytes).toString(this.encoding);
  }

  // Holds back a trailing sequence that is not complete yet.
  _utf8(bytes) {
    let keep = 0;
    let i = bytes.length - 1;
    const floor = bytes.length - 4 > 0 ? bytes.length - 4 : 0;
    while (i >= floor) {
      const need = leadLen(bytes[i]);
      if (need > 0) {
        const have = bytes.length - i;
        if (need > have) {
          keep = have;
          this.lastNeed = need - have;
          this.lastTotal = need;
        }
        break;
      }
      if ((bytes[i] & 0xC0) !== 0x80) break;
      i--;
    }
    if (keep > 0) {
      this._pend = bytes.slice(bytes.length - keep);
      bytes = bytes.slice(0, bytes.length - keep);
    }
    if (bytes.length === 0) return '';
    return Buffer.from(bytes).toString('utf8');
  }

  // Two bytes per code unit, and a high surrogate waits for its low one.
  _utf16(bytes) {
    let usable = bytes.length - (bytes.length % 2);
    let s = usable > 0 ? Buffer.from(bytes.slice(0, usable)).toString('utf16le') : '';
    if (s.length > 0) {
      const last = s.charCodeAt(s.length - 1);
      if (last >= 0xD800 && last <= 0xDBFF) {
        s = s.slice(0, s.length - 1);
        usable -= 2;
      }
    }
    this._pend = bytes.slice(usable);
    this.lastNeed = this._pend.length > 0 ? 1 : 0;
    return s;
  }

  // Only whole three-byte groups encode without padding; the rest waits.
  _base64(bytes) {
    const usable = bytes.length - (bytes.length % 3);
    this._pend = bytes.slice(usable);
    this.lastNeed = this._pend.length > 0 ? 3 - this._pend.length : 0;
    this.lastTotal = 3;
    if (usable === 0) return '';
    return Buffer.from(bytes.slice(0, usable)).toString('base64');
  }

  // Whatever is left cannot be completed now: an unfinished UTF-8 sequence
  // becomes one replacement character, and base64 flushes with padding.
  end(buf) {
    let out = buf === undefined || buf === null ? '' : this.write(buf);
    if (this._pend.length === 0) return out;
    const rest = this._pend;
    this._pend = [];
    this.lastNeed = 0;
    if (this.encoding === 'utf8') return out + REPLACEMENT;
    if (this.encoding === 'base64') return out + Buffer.from(rest).toString('base64');
    if (this.encoding === 'utf16le') {
      const usable = rest.length - (rest.length % 2);
      if (usable === 0) return out;
      return out + Buffer.from(rest.slice(0, usable)).toString('utf16le');
    }
    return out + Buffer.from(rest).toString(this.encoding);
  }
}

module.exports = { StringDecoder: StringDecoder };
";
}

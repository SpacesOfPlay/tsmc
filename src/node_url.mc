// node_url.mc -- the `url` module.
//
// The WHATWG classes are globals already; this module re-exports them and
// adds the legacy API (`parse`, `format`, `resolve`, the `Url` object) plus
// the file-path conversions. The legacy parser is not a URL standard: it is
// a fixed set of habits that a great deal of code still relies on, so it is
// reproduced habit for habit rather than derived from the WHATWG one.
//
// Embedded JS: no backslash escapes (minc processes them in string literals)
// and no double quotes. Regular expressions that would need a backslash are
// written as character scans instead.

str node_url_source() {
    return "'use strict';

const querystring = require('querystring');
const punycode = require('punycode');
const path = require('path');

const Q = String.fromCharCode(34);
const SQ = String.fromCharCode(39);
const BS = String.fromCharCode(92);
const isWindows = process.platform === 'win32';

// Errors carry the same codes and messages as the reference runtime, since
// code that catches them tends to switch on `code`.
function describe(v) {
  if (v === undefined || v === null) return 'Received ' + v;
  if (typeof v === 'function') return 'Received function ' + (v.name || '');
  if (typeof v === 'object') {
    const c = v.constructor;
    if (c && c.name) return 'Received an instance of ' + c.name;
    return 'Received ' + require('util').inspect(v, { depth: -1 });
  }
  let s = require('util').inspect(v, { colors: false });
  if (s.length > 28) s = s.slice(0, 25) + '...';
  return 'Received type ' + typeof v + ' (' + s + ')';
}

function argTypeError(name, expected, v) {
  const types = [];
  const instances = [];
  for (const t of expected) {
    if (t === 'Object' || t === 'Function') types.push(t.toLowerCase());
    else if (t[0] >= 'A' && t[0] <= 'Z') instances.push(t);
    else types.push(t);
  }
  let msg = 'The ' + Q + name + Q + ' argument must be ';
  if (types.length) {
    msg += (types.length > 1 ? 'one of type ' : 'of type ') + joinOr(types);
    if (instances.length) msg += ' or an instance of ' + joinOr(instances);
  } else {
    msg += 'an instance of ' + joinOr(instances);
  }
  const e = new TypeError(msg + '. ' + describe(v));
  e.code = 'ERR_INVALID_ARG_TYPE';
  return e;
}

function joinOr(list) {
  if (list.length === 1) return list[0];
  if (list.length === 2) return list[0] + ' or ' + list[1];
  return list.slice(0, -1).join(', ') + ', or ' + list[list.length - 1];
}

function invalidUrl(input) {
  const e = new TypeError('Invalid URL');
  e.code = 'ERR_INVALID_URL';
  e.input = input;
  return e;
}

function codedTypeError(code, msg) {
  const e = new TypeError(msg);
  e.code = code;
  return e;
}

function validateString(v, name) {
  if (typeof v !== 'string') throw argTypeError(name, ['string'], v);
}

// The protocol sets. `javascript:` never has a host; the slashed set always
// carries `//` and gets a `/` pathname when it has a host and no path.
const hostless = { 'javascript': 1, 'javascript:': 1 };
const unsafe = hostless;
const slashed = {
  'http': 1, 'http:': 1, 'https': 1, 'https:': 1, 'ftp': 1, 'ftp:': 1,
  'gopher': 1, 'gopher:': 1, 'file': 1, 'file:': 1,
  'ws': 1, 'ws:': 1, 'wss': 1, 'wss:': 1,
};
function has(set, k) { return Object.prototype.hasOwnProperty.call(set, k); }

function Url() {
  this.protocol = null;
  this.slashes = null;
  this.auth = null;
  this.host = null;
  this.port = null;
  this.hostname = null;
  this.hash = null;
  this.search = null;
  this.query = null;
  this.pathname = null;
  this.path = null;
  this.href = null;
}

const protocolPattern = /^[a-z0-9.+-]+:/i;
const portPattern = /:[0-9]*$/;
const hostPattern = /^[/][/][^@/]+@[^@/]+/;
const hostnameMaxLen = 255;

// The whitespace class of a regular expression, written out.
function isSpace(c) {
  return c === 32 || (c >= 9 && c <= 13) || c === 160 || c === 0x1680 ||
    (c >= 0x2000 && c <= 0x200a) || c === 0x2028 || c === 0x2029 ||
    c === 0x202f || c === 0x205f || c === 0x3000 || c === 0xfeff;
}

// `/path`, `//path` (not `///`), optionally `?query`, no whitespace: the
// cheap case that skips the whole protocol/host machinery.
function simplePath(rest) {
  if (rest.charCodeAt(0) !== 47) return null;
  let i = 1;
  if (rest.charCodeAt(1) === 47) {
    if (rest.charCodeAt(2) === 47) return null;
    i = 2;
  }
  let q = -1;
  for (; i < rest.length; i++) {
    const c = rest.charCodeAt(i);
    if (isSpace(c)) return null;
    if (c === 63 && q < 0) q = i;
  }
  if (q < 0) return [rest, ''];
  return [rest.slice(0, q), rest.slice(q)];
}

function isIpv6Hostname(h) {
  return h.charCodeAt(0) === 91 && h.charCodeAt(h.length - 1) === 93;
}

function forbiddenHostChar(c, ipv6) {
  if (c === 0 || c === 9 || c === 10 || c === 13 || c === 32 || c === 35 ||
      c === 37 || c === 47 || c === 60 || c === 62 || c === 63 || c === 64 ||
      c === 92 || c === 94 || c === 124) return true;
  if (!ipv6 && (c === 58 || c === 91 || c === 93)) return true;
  return false;
}

function hasForbiddenHostChar(h, ipv6) {
  for (let i = 0; i < h.length; i++) if (forbiddenHostChar(h.charCodeAt(i), ipv6)) return true;
  return false;
}

Url.prototype.parse = function parse(url, parseQueryString, slashesDenoteHost) {
  validateString(url, 'url');

  // Trim, turn backslashes into slashes up to the first `?` or `#`, and
  // note whether an `@` or `#` was seen at all.
  let hasHash = false;
  let hasAt = false;
  let start = -1;
  let end = -1;
  let rest = '';
  let lastPos = 0;
  for (let i = 0, inWs = false, split = false; i < url.length; ++i) {
    const code = url.charCodeAt(i);
    const isWs = code < 33 || code === 160 || code === 0xfeff;
    if (start === -1) {
      if (isWs) continue;
      lastPos = start = i;
    } else if (inWs) {
      if (!isWs) { end = -1; inWs = false; }
    } else if (isWs) {
      end = i;
      inWs = true;
    }
    if (!split) {
      switch (code) {
        case 64: hasAt = true; break;
        case 35: hasHash = true;
        case 63: split = true; break;
        case 92:
          if (i - lastPos > 0) rest += url.slice(lastPos, i);
          rest += '/';
          lastPos = i + 1;
          break;
      }
    } else if (!hasHash && code === 35) {
      hasHash = true;
    }
  }
  if (start !== -1) {
    if (lastPos === start) {
      if (end === -1) rest = start === 0 ? url : url.slice(start);
      else rest = url.slice(start, end);
    } else if (end === -1 && lastPos < url.length) {
      rest += url.slice(lastPos);
    } else if (end !== -1 && lastPos < end) {
      rest += url.slice(lastPos, end);
    }
  }

  if (!slashesDenoteHost && !hasHash && !hasAt) {
    const sp = simplePath(rest);
    if (sp) {
      this.path = rest;
      this.href = rest;
      this.pathname = sp[0];
      if (sp[1]) {
        this.search = sp[1];
        this.query = parseQueryString ? querystring.parse(this.search.slice(1)) : this.search.slice(1);
      } else if (parseQueryString) {
        this.search = null;
        this.query = { __proto__: null };
      }
      return this;
    }
  }

  let proto = protocolPattern.exec(rest);
  let lowerProto;
  if (proto) {
    proto = proto[0];
    lowerProto = proto.toLowerCase();
    this.protocol = lowerProto;
    rest = rest.slice(proto.length);
  }

  let slashes;
  if (slashesDenoteHost || proto || hostPattern.test(rest)) {
    slashes = rest.charCodeAt(0) === 47 && rest.charCodeAt(1) === 47;
    if (slashes && !(proto && has(hostless, lowerProto))) {
      rest = rest.slice(2);
      this.slashes = true;
    }
  }

  if (!has(hostless, lowerProto) && (slashes || (proto && !has(slashed, proto)))) {
    // The host runs to the first delimiter; an `@` before that restarts
    // it, since everything before the last `@` is the auth part.
    let hostEnd = -1;
    let atSign = -1;
    let nonHost = -1;
    for (let i = 0; i < rest.length; ++i) {
      switch (rest.charCodeAt(i)) {
        case 9: case 10: case 13:
          rest = rest.slice(0, i) + rest.slice(i + 1);
          i -= 1;
          break;
        case 32: case 34: case 37: case 39: case 59: case 60: case 62:
        case 92: case 94: case 96: case 123: case 124: case 125:
          if (nonHost === -1) nonHost = i;
          break;
        case 35: case 47: case 63:
          if (nonHost === -1) nonHost = i;
          hostEnd = i;
          break;
        case 64:
          atSign = i;
          nonHost = -1;
          break;
      }
      if (hostEnd !== -1) break;
    }
    start = 0;
    if (atSign !== -1) {
      this.auth = decodeURIComponent(rest.slice(0, atSign));
      start = atSign + 1;
    }
    if (nonHost === -1) {
      this.host = rest.slice(start);
      rest = '';
    } else {
      this.host = rest.slice(start, nonHost);
      rest = rest.slice(nonHost);
    }

    this.parseHost();
    if (typeof this.hostname !== 'string') this.hostname = '';

    const hostname = this.hostname;
    const ipv6Hostname = isIpv6Hostname(hostname);

    // A hostname is cut at the first character that cannot be part of
    // one; the remainder becomes the start of the path.
    if (!ipv6Hostname) {
      for (let i = 0; i < hostname.length; ++i) {
        const c = hostname.charCodeAt(i);
        if (c === 47 || c === 92 || c === 35 || c === 63 || c === 58) {
          this.hostname = hostname.slice(0, i);
          rest = '/' + hostname.slice(i) + rest;
          break;
        }
      }
    }

    if (this.hostname.length > hostnameMaxLen) {
      this.hostname = '';
    } else {
      this.hostname = this.hostname.toLowerCase();
    }

    if (this.hostname !== '') {
      if (ipv6Hostname) {
        if (hasForbiddenHostChar(this.hostname, true)) throw invalidUrl(url);
      } else {
        this.hostname = toASCII(this.hostname);
        if (this.hostname === '' || hasForbiddenHostChar(this.hostname, false)) throw invalidUrl(url);
      }
    }

    const p = this.port ? ':' + this.port : '';
    const h = this.hostname || '';
    this.host = h + p;

    if (ipv6Hostname) {
      this.hostname = this.hostname.slice(1, -1);
      if (rest[0] !== '/') rest = '/' + rest;
    }
  }

  if (!has(unsafe, lowerProto)) rest = autoEscapeStr(rest);

  let questionIdx = -1;
  let hashIdx = -1;
  for (let i = 0; i < rest.length; ++i) {
    const code = rest.charCodeAt(i);
    if (code === 35) {
      this.hash = rest.slice(i);
      hashIdx = i;
      break;
    } else if (code === 63 && questionIdx === -1) {
      questionIdx = i;
    }
  }

  if (questionIdx !== -1) {
    if (hashIdx === -1) {
      this.search = rest.slice(questionIdx);
      this.query = rest.slice(questionIdx + 1);
    } else {
      this.search = rest.slice(questionIdx, hashIdx);
      this.query = rest.slice(questionIdx + 1, hashIdx);
    }
    if (parseQueryString) this.query = querystring.parse(this.query);
  } else if (parseQueryString) {
    this.search = null;
    this.query = { __proto__: null };
  }

  const useQuestionIdx = questionIdx !== -1 && (hashIdx === -1 || questionIdx < hashIdx);
  const firstIdx = useQuestionIdx ? questionIdx : hashIdx;
  if (firstIdx === -1) {
    if (rest.length > 0) this.pathname = rest;
  } else if (firstIdx > 0) {
    this.pathname = rest.slice(0, firstIdx);
  }
  if (has(slashed, lowerProto) && this.hostname && !this.pathname) this.pathname = '/';

  if (this.pathname || this.search) {
    this.path = (this.pathname || '') + (this.search || '');
  }

  this.href = this.format();
  return this;
};

// Non-ASCII labels become punycode; anything already ASCII is left alone.
function toASCII(h) {
  for (let i = 0; i < h.length; i++) if (h.charCodeAt(i) > 127) return punycode.toASCII(h);
  return h;
}

// The handful of characters the legacy parser percent-encodes on its own
// in the path and query (a space, quotes, angle brackets, ...).
const escapedCodes = {
  9: '%09', 10: '%0A', 13: '%0D', 32: '%20', 34: '%22', 39: '%27',
  60: '%3C', 62: '%3E', 92: '%5C', 94: '%5E', 96: '%60',
  123: '%7B', 124: '%7C', 125: '%7D',
};

function autoEscapeStr(rest) {
  let escaped = '';
  let lastEscapedPos = 0;
  for (let i = 0; i < rest.length; ++i) {
    const escapedChar = escapedCodes[rest.charCodeAt(i)];
    if (escapedChar) {
      if (i > lastEscapedPos) escaped += rest.slice(lastEscapedPos, i);
      escaped += escapedChar;
      lastEscapedPos = i + 1;
    }
  }
  if (lastEscapedPos === 0) return rest;
  if (lastEscapedPos < rest.length) escaped += rest.slice(lastEscapedPos);
  return escaped;
}

// The auth part is percent-encoded on output, keeping only the unreserved
// characters, the colon and the sub-delims `!'()*`.
function keepInAuth(c) {
  return c === 33 || c === 39 || (c >= 40 && c <= 42) || c === 45 || c === 46 ||
    (c >= 48 && c <= 58) || (c >= 65 && c <= 90) || c === 95 ||
    (c >= 97 && c <= 122) || c === 126;
}

function encodeAuth(s) {
  let out = '';
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c < 128) {
      if (keepInAuth(c)) out += s[i];
      else out += '%' + (c < 16 ? '0' : '') + c.toString(16).toUpperCase();
    } else if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length) {
      out += encodeURIComponent(s.slice(i, i + 2));
      i++;
    } else {
      out += encodeURIComponent(s[i]);
    }
  }
  return out;
}

Url.prototype.format = function format() {
  let auth = this.auth || '';
  if (auth) auth = encodeAuth(auth) + '@';

  let protocol = this.protocol || '';
  let pathname = this.pathname || '';
  let hash = this.hash || '';
  let host = '';
  let query = '';

  if (this.host) {
    host = auth + this.host;
  } else if (this.hostname) {
    host = auth + (this.hostname.indexOf(':') >= 0 && !isIpv6Hostname(this.hostname)
      ? '[' + this.hostname + ']' : this.hostname);
    if (this.port) host += ':' + this.port;
  }

  if (this.query !== null && typeof this.query === 'object') query = querystring.stringify(this.query);

  let search = this.search || (query && ('?' + query)) || '';

  if (protocol && protocol.charCodeAt(protocol.length - 1) !== 58) protocol += ':';

  // A `#` or `?` inside the pathname would be read back as a delimiter.
  pathname = pathname.split('#').join('%23').split('?').join('%3F');

  if (this.slashes || has(slashed, protocol)) {
    if (this.slashes || host) {
      if (pathname && pathname.charCodeAt(0) !== 47) pathname = '/' + pathname;
      host = '//' + host;
    } else if (protocol.slice(0, 4) === 'file') {
      host = '//';
    }
  }

  search = search.split('#').join('%23');

  if (hash && hash.charCodeAt(0) !== 35) hash = '#' + hash;
  if (search && search.charCodeAt(0) !== 63) search = '?' + search;

  return protocol + host + pathname + search + hash;
};

Url.prototype.parseHost = function parseHost() {
  let host = this.host;
  let port = portPattern.exec(host);
  if (port) {
    port = port[0];
    if (port !== ':') this.port = port.slice(1);
    host = host.slice(0, host.length - port.length);
  }
  if (host) this.hostname = host;
};

Url.prototype.resolve = function resolve(relative) {
  return this.resolveObject(urlParse(relative, false, true)).format();
};

Url.prototype.resolveObject = function resolveObject(relative) {
  if (typeof relative === 'string') {
    const rel = new Url();
    rel.parse(relative, false, true);
    relative = rel;
  }

  const result = new Url();
  Object.assign(result, this);

  // The hash is always the relative one, even when empty.
  result.hash = relative.hash;

  if (relative.href === '') {
    result.href = result.format();
    return result;
  }

  // `//host/path` takes everything but the protocol.
  if (relative.slashes && !relative.protocol) {
    for (const key of Object.keys(relative)) {
      if (key !== 'protocol') result[key] = relative[key];
    }
    if (has(slashed, result.protocol) && result.hostname && !result.pathname) {
      result.path = result.pathname = '/';
    }
    result.href = result.format();
    return result;
  }

  if (relative.protocol && relative.protocol !== result.protocol) {
    // A different, unslashed protocol replaces the source outright. A
    // slashed one without a host takes its host from the first path
    // segment.
    if (!has(slashed, relative.protocol)) {
      Object.assign(result, relative);
      result.href = result.format();
      return result;
    }
    result.protocol = relative.protocol;
    if (!relative.host && relative.protocol !== 'file' && relative.protocol !== 'file:' &&
        !has(hostless, relative.protocol)) {
      const relPath = (relative.pathname || '').split('/');
      while (relPath.length && !(relative.host = relPath.shift()));
      if (!relative.host) relative.host = '';
      if (!relative.hostname) relative.hostname = '';
      if (relPath[0] !== '') relPath.unshift('');
      if (relPath.length < 2) relPath.unshift('');
      result.pathname = relPath.join('/');
    } else {
      result.pathname = relative.pathname;
    }
    result.search = relative.search;
    result.query = relative.query;
    result.host = relative.host || '';
    result.auth = relative.auth;
    result.hostname = relative.hostname || relative.host;
    result.port = relative.port;
    if (result.pathname || result.search) {
      result.path = (result.pathname || '') + (result.search || '');
    }
    result.slashes = result.slashes || relative.slashes;
    result.href = result.format();
    return result;
  }

  const isSourceAbs = result.pathname && result.pathname.charAt(0) === '/';
  const isRelAbs = relative.host || (relative.pathname && relative.pathname.charAt(0) === '/');
  let mustEndAbs = isRelAbs || isSourceAbs || (result.host && relative.pathname);
  const removeAllDots = mustEndAbs;
  let srcPath = (result.pathname && result.pathname.split('/')) || [];
  const relPath = (relative.pathname && relative.pathname.split('/')) || [];
  const noLeadingSlashes = result.protocol && !has(slashed, result.protocol);

  // An unslashed protocol (mailto:, urn:) keeps its host as the first
  // path segment while the paths are merged, and takes it back after.
  if (noLeadingSlashes) {
    result.hostname = '';
    result.port = null;
    if (result.host) {
      if (srcPath[0] === '') srcPath[0] = result.host;
      else srcPath.unshift(result.host);
    }
    result.host = '';
    if (relative.protocol) {
      relative.hostname = null;
      relative.port = null;
      result.auth = null;
      if (relative.host) {
        if (relPath[0] === '') relPath[0] = relative.host;
        else relPath.unshift(relative.host);
      }
      relative.host = null;
    }
    mustEndAbs = mustEndAbs && (relPath[0] === '' || srcPath[0] === '');
  }

  if (isRelAbs) {
    if (relative.host || relative.host === '') {
      if (result.host !== relative.host) result.auth = null;
      result.host = relative.host;
      result.port = relative.port;
    }
    if (relative.hostname || relative.hostname === '') {
      if (result.hostname !== relative.hostname) result.auth = null;
      result.hostname = relative.hostname;
    }
    result.search = relative.search;
    result.query = relative.query;
    srcPath = relPath;
  } else if (relPath.length) {
    if (!srcPath) srcPath = [];
    srcPath.pop();
    srcPath = srcPath.concat(relPath);
    result.search = relative.search;
    result.query = relative.query;
  } else if (relative.search !== null && relative.search !== undefined) {
    if (noLeadingSlashes) {
      result.hostname = result.host = srcPath.shift();
      const authInHost = result.host && result.host.indexOf('@') > 0 && result.host.split('@');
      if (authInHost) {
        result.auth = authInHost.shift();
        result.host = result.hostname = authInHost.shift();
      }
    }
    result.search = relative.search;
    result.query = relative.query;
    if (result.pathname !== null || result.search !== null) {
      result.path = (result.pathname ? result.pathname : '') + (result.search ? result.search : '');
    }
    result.href = result.format();
    return result;
  }

  if (!srcPath.length) {
    result.pathname = null;
    result.path = result.search ? '/' + result.search : null;
    result.href = result.format();
    return result;
  }

  // Collapse `.` and `..`, keeping a trailing slash where the last segment
  // was one of them or empty.
  let last = srcPath.slice(-1)[0];
  const hasTrailingSlash =
    ((result.host || relative.host || srcPath.length > 1) && (last === '.' || last === '..')) || last === '';

  let up = 0;
  for (let i = srcPath.length - 1; i >= 0; i--) {
    last = srcPath[i];
    if (last === '.') {
      srcPath.splice(i, 1);
    } else if (last === '..') {
      srcPath.splice(i, 1);
      up++;
    } else if (up) {
      srcPath.splice(i, 1);
      up--;
    }
  }

  if (!mustEndAbs && !removeAllDots) {
    while (up--) srcPath.unshift('..');
  }

  if (mustEndAbs && srcPath[0] !== '' && (!srcPath[0] || srcPath[0].charAt(0) !== '/')) {
    srcPath.unshift('');
  }

  if (hasTrailingSlash && srcPath.join('/').slice(-1) !== '/') srcPath.push('');

  const isAbsolute = srcPath[0] === '' || (srcPath[0] && srcPath[0].charAt(0) === '/');

  if (noLeadingSlashes) {
    result.hostname = result.host = isAbsolute ? '' : srcPath.length ? srcPath.shift() : '';
    const authInHost = result.host && result.host.indexOf('@') > 0 ? result.host.split('@') : false;
    if (authInHost) {
      result.auth = authInHost.shift();
      result.host = result.hostname = authInHost.shift();
    }
  }

  mustEndAbs = mustEndAbs || (result.host && srcPath.length);

  if (mustEndAbs && !isAbsolute) srcPath.unshift('');

  if (!srcPath.length) {
    result.pathname = null;
    result.path = null;
  } else {
    result.pathname = srcPath.join('/');
  }

  if (result.pathname !== null || result.search !== null) {
    result.path = (result.pathname ? result.pathname : '') + (result.search ? result.search : '');
  }
  result.auth = relative.auth || result.auth;
  result.slashes = result.slashes || relative.slashes;
  result.href = result.format();
  return result;
};

function urlParse(url, parseQueryString, slashesDenoteHost) {
  if (url instanceof Url) return url;
  const u = new Url();
  u.parse(url, parseQueryString, slashesDenoteHost);
  return u;
}

function urlResolve(source, relative) {
  return urlParse(source, false, true).resolve(relative);
}

function urlResolveObject(source, relative) {
  if (!source) return relative;
  return urlParse(source, false, true).resolveObject(relative);
}

// A WHATWG URL formats to its href with the optional parts switched off;
// anything else is a legacy object, or a string parsed into one.
function urlFormat(urlObject, options) {
  if (typeof urlObject === 'string') {
    urlObject = urlParse(urlObject);
  } else if (typeof urlObject !== 'object' || urlObject === null) {
    throw argTypeError('urlObject', ['Object', 'string'], urlObject);
  } else if (urlObject instanceof URL) {
    let fragment = true, unicode = false, search = true, auth = true;
    if (options) {
      if (typeof options !== 'object') throw argTypeError('options', ['Object'], options);
      if (options.fragment != null) fragment = Boolean(options.fragment);
      if (options.unicode != null) unicode = Boolean(options.unicode);
      if (options.search != null) search = Boolean(options.search);
      if (options.auth != null) auth = Boolean(options.auth);
    }
    const u = new URL(urlObject.href);
    if (!fragment) u.hash = '';
    if (!search) u.search = '';
    if (!auth) { u.username = ''; u.password = ''; }
    let out = u.href;
    if (unicode && u.hostname) {
      const uni = domainToUnicode(u.hostname);
      if (uni !== u.hostname) {
        const at = out.indexOf('//');
        const from = at >= 0 ? at + 2 : 0;
        const idx = out.indexOf(u.hostname, from);
        if (idx >= 0) out = out.slice(0, idx) + uni + out.slice(idx + u.hostname.length);
      }
    }
    return out;
  }
  return Url.prototype.format.call(urlObject);
}

function domainToASCII(domain) {
  if (arguments.length < 1) throw codedTypeError('ERR_MISSING_ARGS', 'The ' + Q + 'domain' + Q + ' argument must be specified');
  const d = String(domain);
  if (d === '' || hasForbiddenHostChar(d, false)) return '';
  // A label that claims to be punycode already has to be exactly that.
  for (const label of d.split('.')) {
    if (label.slice(0, 4).toLowerCase() === 'xn--') {
      for (let i = 0; i < label.length; i++) if (label.charCodeAt(i) > 127) return '';
      try { punycode.decode(label.slice(4)); } catch (e) { return ''; }
    }
  }
  let a;
  try { a = punycode.toASCII(d); } catch (e) { return ''; }
  try { return new URL('ws://' + a + '/').hostname; } catch (e) { return ''; }
}

function domainToUnicode(domain) {
  if (arguments.length < 1) throw codedTypeError('ERR_MISSING_ARGS', 'The ' + Q + 'domain' + Q + ' argument must be specified');
  const a = domainToASCII(domain);
  if (a === '') return '';
  try { return punycode.toUnicode(a); } catch (e) { return ''; }
}

// A URL as the options object http.request takes.
function urlToHttpOptions(url) {
  const options = {
    __proto__: null,
    ...url,
    protocol: url.protocol,
    hostname: url.hostname && url.hostname[0] === '[' ? url.hostname.slice(1, -1) : url.hostname,
    hash: url.hash,
    search: url.search,
    pathname: url.pathname,
    path: (url.pathname || '') + (url.search || ''),
    href: url.href,
  };
  if (url.port !== '') options.port = Number(url.port);
  if (url.username || url.password) {
    options.auth = decodeURIComponent(url.username) + ':' + decodeURIComponent(url.password);
  }
  return options;
}

function isURL(v) {
  return v !== null && typeof v === 'object' && typeof v.href === 'string' && typeof v.protocol === 'string';
}

// An encoded slash (or backslash, on Windows) in a file URL would change
// which file it names once decoded, so it is refused.
function hasEncodedSep(pathname, windows) {
  for (let n = 0; n < pathname.length; n++) {
    if (pathname[n] === '%') {
      const third = pathname.charCodeAt(n + 2) | 0x20;
      if (pathname[n + 1] === '2' && third === 102) return true;
      if (windows && pathname[n + 1] === '5' && third === 99) return true;
    }
  }
  return false;
}

function fileURLToPath(p, options) {
  const windows = options && options.windows != null ? Boolean(options.windows) : isWindows;
  if (typeof p === 'string') p = new URL(p);
  else if (!isURL(p)) throw argTypeError('path', ['string', 'URL'], p);
  if (p.protocol !== 'file:') throw codedTypeError('ERR_INVALID_URL_SCHEME', 'The URL must be of scheme file');
  let pathname = p.pathname;
  // `localhost` names no host in a file URL.
  const hostname = p.hostname === 'localhost' ? '' : p.hostname;
  if (windows) {
    if (hasEncodedSep(pathname, true)) {
      throw codedTypeError('ERR_INVALID_FILE_URL_PATH', 'File URL path must not include encoded ' + BS + ' or / characters');
    }
    pathname = decodeURIComponent(pathname.split('/').join(BS));
    if (hostname !== '') return BS + BS + domainToUnicode(hostname) + pathname;
    const letter = pathname.charCodeAt(1) | 0x20;
    if (letter < 97 || letter > 122 || pathname.charAt(2) !== ':') {
      throw codedTypeError('ERR_INVALID_FILE_URL_PATH', 'File URL path must be absolute');
    }
    return pathname.slice(1);
  }
  if (hostname !== '') {
    throw codedTypeError('ERR_INVALID_FILE_URL_HOST', 'File URL host must be ' + Q + 'localhost' + Q + ' or empty on ' + process.platform);
  }
  if (hasEncodedSep(pathname, false)) {
    throw codedTypeError('ERR_INVALID_FILE_URL_PATH', 'File URL path must not include encoded / characters');
  }
  return decodeURIComponent(pathname);
}

// Characters that the URL path setter would not encode, or would read as
// a delimiter, are encoded here first; the setter does the rest.
function encodePathChars(fp, windows) {
  fp = fp.split('%').join('%25');
  if (!windows) fp = fp.split(BS).join('%5C');
  fp = fp.split(String.fromCharCode(10)).join('%0A');
  fp = fp.split(String.fromCharCode(13)).join('%0D');
  fp = fp.split(String.fromCharCode(9)).join('%09');
  if (windows) fp = fp.split(BS).join('/');
  return fp;
}

function pathToFileURL(filepath, options) {
  validateString(filepath, 'path');
  const windows = options && options.windows != null ? Boolean(options.windows) : isWindows;
  const isUNC = windows && filepath.slice(0, 2) === BS + BS;
  let resolved = isUNC ? filepath : (windows ? path.win32.resolve(filepath) : path.posix.resolve(filepath));
  const out = new URL('file://');
  if (isUNC || (windows && resolved.slice(0, 2) === BS + BS)) {
    const isExtendedUNC = resolved.slice(0, 8) === BS + BS + '?' + BS + 'UNC' + BS;
    const prefixLength = isExtendedUNC ? 8 : 2;
    const hostnameEndIndex = resolved.indexOf(BS, prefixLength);
    if (hostnameEndIndex === -1) {
      throw codedTypeError('ERR_INVALID_ARG_VALUE', 'The argument ' + SQ + 'path' + SQ + ' Missing UNC resource path. Received ' + require('util').inspect(resolved));
    }
    if (hostnameEndIndex === 2) {
      throw codedTypeError('ERR_INVALID_ARG_VALUE', 'The argument ' + SQ + 'path' + SQ + ' Empty UNC servername. Received ' + require('util').inspect(resolved));
    }
    out.hostname = domainToASCII(resolved.slice(prefixLength, hostnameEndIndex));
    out.pathname = encodePathChars(resolved.slice(hostnameEndIndex), true);
    return out;
  }
  // A trailing separator is kept. The comparison is against the running
  // platform's separator whichever flavour was asked for, as in the
  // reference runtime.
  const lastCode = filepath.charCodeAt(filepath.length - 1);
  if ((lastCode === 47 || (windows && lastCode === 92)) && resolved[resolved.length - 1] !== path.sep) resolved += '/';
  out.pathname = encodePathChars(resolved, windows);
  return out;
}

module.exports = {
  Url: Url,
  parse: urlParse,
  resolve: urlResolve,
  resolveObject: urlResolveObject,
  format: urlFormat,
  URL: URL,
  URLSearchParams: URLSearchParams,
  domainToASCII: domainToASCII,
  domainToUnicode: domainToUnicode,
  pathToFileURL: pathToFileURL,
  fileURLToPath: fileURLToPath,
  urlToHttpOptions: urlToHttpOptions,
};
";
}

// node_webapi.mc -- the WHATWG fetch data types: Headers, Request, Response.
//
// Internal module (require('_webapi')) behind the lazy `Headers` / `Request` /
// `Response` globals. Deliberately depends on nothing: these are plain data
// types, so a script that touches them does not drag in the http/net stack the
// way `fetch` does. `_fetch` requires this module and returns these same
// classes, so a fetched Response really is `instanceof Response`.
//
// Embedded JS: no backslash escapes (minc processes them in string literals)
// and no double quotes.

str node_webapi_source() {
    return "'use strict';

// Header names are case-insensitive and iterate in sorted order; repeated
// appends of one name join with a comma and a space.
class Headers {
  constructor(init) {
    this._m = new Map();
    if (init === undefined || init === null) return;
    if (init instanceof Headers) {
      init.forEach((v, k) => { this._m.set(k, v); });
    } else if (Array.isArray(init)) {
      for (const pair of init) this.append(pair[0], pair[1]);
    } else if (typeof init === 'object') {
      for (const k of Object.keys(init)) this.append(k, init[k]);
    }
  }
  _k(name) { return String(name).toLowerCase(); }
  get(name) { const v = this._m.get(this._k(name)); return v === undefined ? null : v; }
  has(name) { return this._m.has(this._k(name)); }
  set(name, value) { this._m.set(this._k(name), String(value)); }
  delete(name) { this._m.delete(this._k(name)); }
  append(name, value) {
    const k = this._k(name);
    const cur = this._m.get(k);
    this._m.set(k, cur === undefined ? String(value) : cur + ', ' + String(value));
  }
  _sorted() {
    const ks = [];
    this._m.forEach((v, k) => { ks.push(k); });
    ks.sort();
    return ks;
  }
  forEach(cb, thisArg) {
    for (const k of this._sorted()) cb.call(thisArg, this._m.get(k), k, this);
  }
  keys() { return this._sorted()[Symbol.iterator](); }
  values() { const o = []; for (const k of this._sorted()) o.push(this._m.get(k)); return o[Symbol.iterator](); }
  entries() { const o = []; for (const k of this._sorted()) o.push([k, this._m.get(k)]); return o[Symbol.iterator](); }
  [Symbol.iterator]() { return this.entries(); }
}

function bodyToBuffer(body) {
  if (body === undefined || body === null) return Buffer.alloc(0);
  if (Buffer.isBuffer(body)) return body;
  if (body instanceof ArrayBuffer) return Buffer.from(new Uint8Array(body));
  if (ArrayBuffer.isView(body)) return Buffer.from(new Uint8Array(body.buffer, body.byteOffset, body.byteLength));
  return Buffer.from(String(body), 'utf8');
}

class Body {
  _initBody(body) { this._buf = bodyToBuffer(body); this.bodyUsed = false; }
  text() { this.bodyUsed = true; return Promise.resolve(this._buf.toString('utf8')); }
  json() { return this.text().then(t => JSON.parse(t)); }
  arrayBuffer() {
    this.bodyUsed = true;
    const b = this._buf;
    const ab = new ArrayBuffer(b.length);
    const v = new Uint8Array(ab);
    for (let i = 0; i < b.length; i++) v[i] = b[i];
    return Promise.resolve(ab);
  }
  bytes() { this.bodyUsed = true; return Promise.resolve(new Uint8Array(this._buf)); }
}

class Response extends Body {
  constructor(body, init) {
    super();
    init = init || {};
    const status = init.status === undefined ? 200 : init.status;
    this.status = status;
    this.statusText = init.statusText === undefined ? '' : String(init.statusText);
    this.ok = status >= 200 && status < 300;
    this.redirected = false;
    this.type = 'basic';
    this.url = init.url === undefined ? '' : String(init.url);
    this.headers = init.headers instanceof Headers ? init.headers : new Headers(init.headers);
    this._initBody(body);
  }
  clone() {
    const r = new Response(this._buf, {
      status: this.status, statusText: this.statusText,
      headers: this.headers, url: this.url,
    });
    return r;
  }
}

class Request extends Body {
  constructor(input, init) {
    super();
    init = init || {};
    if (input instanceof Request) {
      this.url = input.url;
      this.method = init.method === undefined ? input.method : String(init.method).toUpperCase();
      this.headers = new Headers(init.headers === undefined ? input.headers : init.headers);
      this._initBody(init.body === undefined ? input._buf : init.body);
    } else {
      this.url = String(input);
      this.method = init.method === undefined ? 'GET' : String(init.method).toUpperCase();
      this.headers = new Headers(init.headers);
      this._initBody(init.body);
    }
    this.redirect = init.redirect === undefined ? 'follow' : init.redirect;
  }
  clone() { return new Request(this); }
}

module.exports = { Headers: Headers, Request: Request, Response: Response };
";
}

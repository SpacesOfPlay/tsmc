// node_fetch.mc -- the WHATWG `fetch` global (plaintext http:).
//
// Internal module (require('_fetch')) that a native `fetch` global
// delegates to lazily, so the impl only loads on first use. Built on the
// `http` client + the global URL. https: is rejected until TLS lands.

str node_fetch_source() {
    return "'use strict';
const http = require('http');

function makeHeaders(obj) {
  return {
    get: function (name) { const v = obj[String(name).toLowerCase()]; return v === undefined ? null : v; },
    has: function (name) { return obj[String(name).toLowerCase()] !== undefined; },
    forEach: function (cb) { for (const k in obj) cb(obj[k], k, this); },
    keys: function () { return Object.keys(obj)[Symbol.iterator](); },
    entries: function () { const e = []; for (const k in obj) e.push([k, obj[k]]); return e[Symbol.iterator](); },
    _raw: obj,
  };
}

class Response {
  constructor(status, statusText, headersObj, bodyBuf, url) {
    this.status = status;
    this.statusText = statusText || '';
    this.ok = status >= 200 && status < 300;
    this.redirected = false;
    this.url = url || '';
    this.headers = makeHeaders(headersObj || {});
    this.bodyUsed = false;
    this._buf = bodyBuf || Buffer.alloc(0);
  }
  text() { this.bodyUsed = true; return Promise.resolve(this._buf.toString('utf8')); }
  json() { return this.text().then(function (t) { return JSON.parse(t); }); }
  arrayBuffer() {
    this.bodyUsed = true;
    const b = this._buf;
    const ab = new ArrayBuffer(b.length);
    const v = new Uint8Array(ab);
    for (let i = 0; i < b.length; i++) v[i] = b[i];
    return Promise.resolve(ab);
  }
}

function fetch(resource, options) {
  options = options || {};
  return new Promise(function (resolve, reject) {
    let urlStr = typeof resource === 'string' ? resource : (resource && resource.url) || String(resource);
    let u;
    try { u = new URL(urlStr); } catch (e) { reject(new TypeError('Failed to parse URL: ' + urlStr)); return; }
    if (u.protocol !== 'http:') {
      reject(new TypeError('fetch: unsupported protocol ' + u.protocol + ' (only http: is supported)'));
      return;
    }
    const headers = {};
    const oh = options.headers || {};
    for (const k in oh) headers[k] = oh[k];
    const req = http.request({
      host: u.hostname,
      port: u.port || 80,
      method: (options.method || 'GET').toUpperCase(),
      path: u.pathname + (u.search || ''),
      headers: headers,
    }, function (res) {
      const chunks = [];
      res.on('data', function (c) { chunks.push(c); });
      res.on('end', function () {
        resolve(new Response(res.statusCode, res.statusMessage, res.headers, Buffer.concat(chunks), urlStr));
      });
      res.on('error', reject);
    });
    req.on('error', reject);
    if (options.body != null) req.write(options.body);
    req.end();
  });
}

module.exports = { fetch: fetch, Response: Response };
";
}

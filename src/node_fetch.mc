// node_fetch.mc -- the WHATWG `fetch` global (plaintext http:).
//
// Internal module (require('_fetch')) that a native `fetch` global
// delegates to lazily, so the impl only loads on first use. Built on the
// `http` client + the global URL. https: is rejected until TLS lands.

str node_fetch_source() {
    return "'use strict';
const http = require('http');
const https = require('https');
// the same classes the Headers / Request / Response globals resolve to, so a
// fetched Response really is `instanceof Response`
const webapi = require('_webapi');
const Headers = webapi.Headers;
const Request = webapi.Request;
const Response = webapi.Response;

function fetch(resource, options) {
  options = options || {};
  if (resource instanceof Request) {
    const merged = {};
    for (const k of Object.keys(options)) merged[k] = options[k];
    if (merged.method === undefined) merged.method = resource.method;
    if (merged.headers === undefined) merged.headers = resource.headers;
    if (merged.body === undefined && resource._buf && resource._buf.length > 0) merged.body = resource._buf;
    options = merged;
  }
  const signal = options.signal;
  return new Promise(function (resolve, reject) {
    // An abort rejects with the signal's own reason, whatever it is
    if (signal && signal.aborted) { reject(signal.reason); return; }
    let urlStr = typeof resource === 'string' ? resource : (resource && resource.url) || String(resource);
    let u;
    try { u = new URL(urlStr); } catch (e) { reject(new TypeError('Failed to parse URL: ' + urlStr)); return; }
    const secure = u.protocol === 'https:';
    if (!secure && u.protocol !== 'http:') {
      reject(new TypeError('fetch: unsupported protocol ' + u.protocol));
      return;
    }
    const mod = secure ? https : http;
    const headers = {};
    const oh = options.headers || {};
    if (oh instanceof Headers) { oh.forEach(function (v, k) { headers[k] = v; }); }
    else { for (const k in oh) headers[k] = oh[k]; }
    const req = mod.request({
      host: u.hostname,
      port: u.port || (secure ? 443 : 80),
      method: (options.method || 'GET').toUpperCase(),
      path: u.pathname + (u.search || ''),
      headers: headers,
      servername: u.hostname,
    }, function (res) {
      const chunks = [];
      res.on('data', function (c) { chunks.push(c); });
      res.on('end', function () {
        if (signal) signal.removeEventListener('abort', onAbort);
        resolve(new Response(Buffer.concat(chunks), {
          status: res.statusCode,
          statusText: res.statusMessage,
          headers: res.headers,
          url: urlStr,
        }));
      });
      res.on('error', reject);
    });
    req.on('error', reject);
    function onAbort() {
      req.destroy();
      reject(signal.reason);
    }
    if (signal) signal.addEventListener('abort', onAbort, { once: true });
    if (options.body != null) req.write(options.body);
    req.end();
  });
}

module.exports = { fetch: fetch, Headers: Headers, Request: Request, Response: Response };
";
}

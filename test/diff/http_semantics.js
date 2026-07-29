// http: what a server sees, what it sends, and what a client reads back.
//
// One server handles every case, keyed by path, and the checks run against it
// in turn. Nothing prints a Date or a port, so the output is stable.
//
// Which framing a response uses -- Content-Length or chunked -- is not
// asserted: both are legal HTTP/1.1 and the choice is an implementation
// matter. node buffers less and chunks; tsmc knows the whole body and sends a
// length. What is checked is that the response IS framed and the body arrives
// whole.

const http = require('http');

const out = [];

function show(v) {
  if (v === undefined) return 'undefined';
  if (v === null) return 'null';
  if (typeof v === 'string') return JSON.stringify(v);
  if (Array.isArray(v)) return '[' + v.map(show).join(', ') + ']';
  if (typeof v === 'object') { try { return JSON.stringify(v); } catch (e) { return String(v); } }
  return String(v);
}

function T(label, v) { out.push(label + ' = ' + show(v)); }

// Headers a server generates on its own (Date, Connection, Keep-Alive) differ
// between runs and engines, so only the ones under test are reported.
const SHOWN = ['content-type', 'etag', 'x-one', 'x-two', 'x-merged', 'set-cookie'];
function shownHeaders(h) {
  return SHOWN.filter((k) => h[k] !== undefined).map((k) => k + '=' + h[k]).join(' ');
}

const server = http.createServer((req, res) => {
  const path = (req.url || '').split('?')[0];

  if (path === '/echo') {
    let body = '';
    req.on('data', (c) => { body += c; });
    req.on('end', () => {
      res.writeHead(200, { 'Content-Type': 'text/plain' });
      res.end(JSON.stringify({
        method: req.method,
        url: req.url,
        httpVersion: req.httpVersion,
        body,
        // header names arrive lower-cased whatever the client sent
        xcase: req.headers['x-mixed-case'],
        host: typeof req.headers.host,
        hasContentLength: req.headers['content-length'] !== undefined,
      }));
    });
    return;
  }
  if (path === '/status') {
    res.statusCode = 418;
    res.statusMessage = 'I am a teapot';
    res.end('teapot');
    return;
  }
  if (path === '/headers') {
    res.setHeader('X-One', 'first');
    res.setHeader('X-Two', 'second');
    // reported rather than assumed: an engine missing one of these should say
    // so, not die inside the request handler
    const probe = ['getHeader', 'hasHeader', 'removeHeader', 'getHeaderNames']
      .map((k) => k + ':' + typeof res[k]).join(',');
    const got = typeof res.getHeader === 'function' ? String(res.getHeader('X-One')) : 'n/a';
    const has = typeof res.hasHeader === 'function'
      ? String(res.hasHeader('x-two')) + '/' + String(res.hasHeader('x-none')) : 'n/a';
    if (typeof res.removeHeader === 'function') res.removeHeader('X-Two');
    res.setHeader('X-Merged', probe + '|' + got + '|' + has);
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end('hdr');
    return;
  }
  if (path === '/chunks') {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.write('one-');
    res.write('two-');
    res.end('three');
    return;
  }
  if (path === '/nobody') {
    res.writeHead(204);
    res.end();
    return;
  }
  if (path === '/setcookie') {
    res.setHeader('Set-Cookie', ['a=1', 'b=2']);
    res.end('cookies');
    return;
  }
  if (path === '/afterend') {
    // node reports a write after end through the response's error event
    // rather than by throwing; either way the extra bytes are not part of
    // the response, and the server keeps running
    res.on('error', () => {});
    res.end('done');
    try { res.write('extra'); } catch (e) { /* engines differ; both fine */ }
    return;
  }
  if (path === '/buffer') {
    res.writeHead(200, { 'Content-Type': 'application/octet-stream' });
    res.end(Buffer.from([1, 2, 255]));
    return;
  }
  res.writeHead(404, { 'Content-Type': 'text/plain' });
  res.end('missing');
});

function hit(port, opts) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port, ...opts }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(Buffer.from(c)));
      res.on('end', () => resolve({
        status: res.statusCode,
        message: res.statusMessage,
        headers: res.headers,
        body: Buffer.concat(chunks),
      }));
    });
    req.on('error', reject);
    req.end(opts && opts.body);
  });
}

async function main() {
  const port = server.address().port;

  // --- what the server sees ---
  const echo = await hit(port, {
    method: 'POST', path: '/echo?q=1&x=a%20b',
    headers: { 'X-Mixed-Case': 'MixedValue' },
    body: 'payload',
  });
  const seen = JSON.parse(echo.body.toString('utf8'));
  T('req-method', seen.method);
  T('req-url-preserved', seen.url);
  T('req-httpVersion', seen.httpVersion);
  T('req-body', seen.body);
  T('req-header-lowercased', seen.xcase);
  T('req-host-present', seen.host);
  T('req-content-length-set-by-client', seen.hasContentLength);

  const get = await hit(port, { method: 'GET', path: '/echo' });
  T('get-no-body', JSON.parse(get.body.toString('utf8')).body);

  // --- status line ---
  const st = await hit(port, { path: '/status' });
  T('status-code', st.status);
  T('status-message', st.message);
  T('status-body', st.body.toString('utf8'));

  const nf = await hit(port, { path: '/nowhere' });
  T('default-404', [nf.status, nf.body.toString('utf8')]);

  // --- response headers ---
  const hd = await hit(port, { path: '/headers' });
  T('header-roundtrip', shownHeaders(hd.headers));
  T('header-getters', hd.headers['x-merged']);
  T('removed-header-absent', hd.headers['x-two'] === undefined);

  // --- bodies ---
  const ch = await hit(port, { path: '/chunks' });
  T('chunked-body', ch.body.toString('utf8'));
  T('chunked-framing', ch.headers['transfer-encoding'] !== undefined
    || ch.headers['content-length'] !== undefined);

  const nb = await hit(port, { path: '/nobody' });
  T('204-no-body', [nb.status, nb.body.length]);

  const hh = await hit(port, { method: 'HEAD', path: '/chunks' });
  T('head-no-body', [hh.status, hh.body.length]);

  const buf = await hit(port, { path: '/buffer' });
  T('buffer-body', [buf.body.length, buf.body.toString('hex')]);
  T('buffer-content-type', buf.headers['content-type']);

  const sc = await hit(port, { path: '/setcookie' });
  T('set-cookie-is-array', Array.isArray(sc.headers['set-cookie']));
  T('set-cookie-values', sc.headers['set-cookie']);

  const ae = await hit(port, { path: '/afterend' });
  T('write-after-end-survives', [ae.status, ae.body.toString('utf8')]);

  // --- the module surface ---
  T('METHODS-includes', ['GET', 'POST', 'DELETE'].every((m) => http.METHODS.includes(m)));
  T('STATUS_CODES', [http.STATUS_CODES[200], http.STATUS_CODES[404], http.STATUS_CODES[418]]);
  T('createServer-is-function', [typeof http.createServer, typeof http.request, typeof http.get]);
  T('server-listening-flag', typeof server.listening);

  console.log(out.join('\n'));
  server.close();
}

server.listen(0, '127.0.0.1', () => { main().catch((e) => { console.log('ERROR: ' + e.message); server.close(); }); });

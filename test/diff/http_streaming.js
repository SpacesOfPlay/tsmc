// http: a response written in pieces reaches the client in pieces.
//
// The handler of /stream writes its second piece only once the client has
// the first: a server that held the body until end() would never get
// there, and the case reports "held" after a second. The raw bytes of a
// streamed HTTP/1.1 reply are chunked; an HTTP/1.0 client gets the body
// unframed and its end with the connection's. A declared Content-Length
// makes the pieces go as they are, HEAD sends none of them, flushHeaders
// lets the client see the head before any body, a large write reports that
// the connection is full and 'drain' follows, and a write after end fails.

const http = require('http');
const net = require('net');

const out = [];
function T(label, v) { out.push(label + ' = ' + (typeof v === 'string' ? JSON.stringify(v) : String(v))); }

let gotFirst = null;       // resolves when the client has /stream's first piece
let gotHead = null;        // resolves when the client has /flush's head

const server = http.createServer((req, res) => {
  const path = (req.url || '').split('?')[0];
  if (path === '/stream') {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.write('one ');
    let held = false;
    const t = setTimeout(() => { held = true; res.end('held'); }, 1000);
    gotFirst.then(() => {
      if (held) return;
      clearTimeout(t);
      res.write('two ');
      res.end('three');
    });
    return;
  }
  if (path === '/length') {
    res.writeHead(200, { 'Content-Length': '11' });
    res.write('hello ');
    res.end('world');
    return;
  }
  if (path === '/head') {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.write('not sent');
    res.end();
    return;
  }
  if (path === '/flush') {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.flushHeaders();
    let held = false;
    const t = setTimeout(() => { held = true; res.end('held'); }, 1000);
    gotHead.then(() => { if (!held) { clearTimeout(t); res.end('after the head'); } });
    return;
  }
  if (path === '/big') {
    const piece = Buffer.alloc(256 * 1024, 97);
    let sent = 0, full = false;
    const more = () => {
      while (sent < 8) {
        sent++;
        if (!res.write(piece)) { full = true; res.once('drain', more); return; }
      }
      res.end();
      T('big: a write reported the connection full', full);
    };
    res.writeHead(200, { 'Content-Type': 'application/octet-stream' });
    more();
    return;
  }
  if (path === '/after') {
    res.on('error', () => {});
    res.end('done');
    res.write('late', (err) => { T('after end: the write fails', err ? err.code : 'no error'); });
    return;
  }
  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end('whole');
});

function get(port, path, method, onResponse) {
  return new Promise((resolve) => {
    const req = http.request({ host: '127.0.0.1', port, path, method: method || 'GET', agent: false }, (res) => {
      if (onResponse) onResponse(res);
      const parts = [];
      res.on('data', (d) => {
        parts.push(Buffer.from(d));
        if (path === '/stream' && gotFirst.resolve && Buffer.concat(parts).toString().startsWith('one ')) {
          const r = gotFirst.resolve; gotFirst.resolve = null; r();
        }
      });
      res.on('end', () => resolve({ status: res.statusCode, body: Buffer.concat(parts) }));
    });
    req.on('error', (e) => resolve({ status: 0, body: Buffer.from('error ' + e.message) }));
    req.end();
  });
}

function raw(port, text) {
  return new Promise((resolve) => {
    const s = net.connect(port, '127.0.0.1', () => s.write(text));
    const parts = [];
    s.on('data', (d) => parts.push(Buffer.from(d)));
    s.on('end', () => resolve(Buffer.concat(parts).toString('latin1')));
    s.on('error', () => resolve('error'));
  });
}

function deferred() {
  let resolve;
  const p = new Promise((r) => { resolve = r; });
  p.resolve = resolve;
  return p;
}

// The body of a chunked message.
function dechunk(s) {
  let body = '', at = 0;
  for (;;) {
    const nl = s.indexOf(String.fromCharCode(13, 10), at);
    if (nl < 0) return body + '(truncated)';
    const n = parseInt(s.slice(at, nl), 16);
    if (n === 0) return body;
    body += s.slice(nl + 2, nl + 2 + n);
    at = nl + 2 + n + 2;
  }
}

async function main() {
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const port = server.address().port;
  const CRLF = String.fromCharCode(13, 10);

  gotFirst = deferred();
  const s = await get(port, '/stream');
  T('stream: the body', s.body.toString());

  // The raw cases look at the framing; the handler goes on at once.
  gotFirst = deferred();
  gotFirst.resolve();
  const r11 = await raw(port, 'GET /stream HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Connection: close' + CRLF + CRLF);
  const head11 = r11.slice(0, r11.indexOf(CRLF + CRLF)).toLowerCase();
  T('1.1 raw: chunked', head11.indexOf('transfer-encoding: chunked') >= 0);
  T('1.1 raw: the body', dechunk(r11.slice(r11.indexOf(CRLF + CRLF) + 4)));

  gotFirst = deferred();
  gotFirst.resolve();
  const r10 = await raw(port, 'GET /stream HTTP/1.0' + CRLF + CRLF);
  const head10 = r10.slice(0, r10.indexOf(CRLF + CRLF)).toLowerCase();
  T('1.0 raw: chunked', head10.indexOf('transfer-encoding: chunked') >= 0);
  T('1.0 raw: the body', r10.slice(r10.indexOf(CRLF + CRLF) + 4));

  const len = await get(port, '/length');
  T('length: the body', len.body.toString());

  const h = await get(port, '/head', 'HEAD');
  T('head: status and body', h.status + ' ' + JSON.stringify(h.body.toString()));

  gotHead = deferred();
  const f = await get(port, '/flush', 'GET', () => gotHead.resolve());
  T('flush: the body', f.body.toString());

  const b = await get(port, '/big');
  T('big: bytes', b.body.length);

  await get(port, '/after');
  const w = await get(port, '/whole');
  T('whole: the body', w.body.toString());

  server.close();
  await new Promise((r) => setTimeout(r, 50));
  for (const line of out.sort()) console.log(line);
}

main();

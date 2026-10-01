// https: responses as they reach the client over TLS, byte for byte. A
// whole small response goes to the session in one call; HEAD, 204, 304,
// a header outside ASCII, a body past a record and a body written in
// pieces take the other path, and both must put the same bytes on the
// wire. Two requests on one kept-alive connection come back in order.

const fs = require('fs');
const path = require('path');
const https = require('https');
const tls = require('tls');
const CRLF = String.fromCharCode(13, 10);

const dir = path.join(__dirname, '..', 'diff');
const opts = {
  cert: fs.readFileSync(path.join(dir, 'https_server.cert.pem'), 'utf8'),
  key: fs.readFileSync(path.join(dir, 'https_server.key.pem'), 'utf8'),
};

const server = https.createServer(opts, (req: any, res: any) => {
  const u = req.url;
  if (u === '/204') { res.statusCode = 204; res.end(); return; }
  if (u === '/304') { res.writeHead(304, { ETag: 'x' }); res.end(); return; }
  if (u === '/cookies') {
    res.setHeader('Set-Cookie', ['a=1', 'b=2']);
    res.setHeader('X-Num', 7);
    res.end('c');
    return;
  }
  if (u === '/close') { res.setHeader('Connection', 'close'); res.end('bye'); return; }
  if (u === '/utf8hdr') { res.setHeader('X-Name', 'caf' + String.fromCharCode(233)); res.end('u'); return; }
  if (u === '/big') { res.end('Z'.repeat(20000)); return; }
  if (u === '/utf8body') { res.end('h' + String.fromCharCode(233) + 'llo'); return; }
  if (u === '/written') { res.write('a'); res.end('b'); return; }
  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end('hello ' + req.method);
});

function exchange(port: number, text: string): Promise<string> {
  return new Promise((resolve) => {
    const s = tls.connect({ port: port, host: '127.0.0.1', rejectUnauthorized: false }, () => s.write(text));
    const got: any[] = [];
    s.on('data', (d: any) => got.push(d));
    s.on('close', () => resolve(Buffer.concat(got).toString('utf8')));
    s.on('error', () => resolve('error'));
  });
}

function req(method: string, url: string, close: boolean) {
  return method + ' ' + url + ' HTTP/1.1' + CRLF + 'Host: x' + CRLF + (close ? 'Connection: close' + CRLF : '') + CRLF;
}

function show(r: string) {
  const at = r.indexOf('Z'.repeat(50));
  if (at >= 0) r = r.slice(0, at) + '<' + (r.length - at) + ' bytes>';
  return r.split(CRLF).join(' | ');
}

async function main() {
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const port = server.address().port;
  for (const [m, u] of [['GET', '/'], ['HEAD', '/'], ['GET', '/204'], ['GET', '/304'], ['GET', '/cookies'],
                        ['GET', '/close'], ['GET', '/utf8hdr'], ['GET', '/big'], ['GET', '/utf8body'], ['GET', '/written']]) {
    console.log('--- ' + m + ' ' + u);
    console.log(show(await exchange(port, req(m, u, true))));
  }
  console.log('--- two on one connection');
  console.log(show(await exchange(port, req('GET', '/', false) + req('GET', '/cookies', true))));
  server.close();
}

main();

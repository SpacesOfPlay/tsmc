// http: responses that have no body. The server adds no Content-Length to
// a 204 or a 304 (one the handler sets on a 304 stays), and the client
// ends a 204, a 304 and the answer to a HEAD at the head, on a connection
// the server keeps open, rather than waiting for a body or the close.

const http = require('http');
const net = require('net');
const CRLF = String.fromCharCode(13, 10);

const server = http.createServer((req: any, res: any) => {
  if (req.url === '/204') { res.statusCode = 204; res.end(); return; }
  if (req.url === '/304') { res.writeHead(304, { ETag: 'x' }); res.end(); return; }
  if (req.url === '/304-length') { res.writeHead(304, { 'Content-Length': 5 }); res.end(); return; }
  res.end('hello');
});

function raw(port: number, method: string, url: string): Promise<string> {
  return new Promise((resolve) => {
    const s = net.connect(port, '127.0.0.1', () => {
      s.write(method + ' ' + url + ' HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Connection: close' + CRLF + CRLF);
    });
    let got = '';
    s.on('data', (d: any) => { got += d.toString('latin1'); });
    s.on('close', () => resolve(got.split(CRLF).join(' | ')));
    s.on('error', () => {});
  });
}

// The client's view, on a connection the server keeps open: 'end' comes
// at the head, or the request is reported as hung after two seconds.
function fetch(port: number, method: string, url: string): Promise<string> {
  return new Promise((resolve) => {
    const req = http.request({ host: '127.0.0.1', port: port, method: method, path: url,
                               headers: { Connection: 'keep-alive' } }, (res: any) => {
      let body = '';
      const timer = setTimeout(() => { resolve(res.statusCode + ' hung'); req.socket.destroy(); }, 2000);
      res.on('data', (c: any) => { body += c; });
      res.on('end', () => {
        clearTimeout(timer);
        resolve(res.statusCode + ' ended, body ' + JSON.stringify(body));
        req.socket.destroy();
      });
    });
    req.end();
  });
}

async function main() {
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const port = server.address().port;
  for (const [m, u] of [['GET', '/204'], ['GET', '/304'], ['GET', '/304-length'], ['HEAD', '/'], ['GET', '/']]) {
    console.log('server ' + m + ' ' + u + ': ' + await raw(port, m, u));
  }
  for (const [m, u] of [['GET', '/204'], ['GET', '/304'], ['HEAD', '/'], ['GET', '/']]) {
    console.log('client ' + m + ' ' + u + ': ' + await fetch(port, m, u));
  }
  server.close();
}

main();

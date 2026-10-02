// https: server.close() while a connection has requests in flight. The
// server stops taking connections, the requests already sent are
// answered, and the server's TLS context stays until the last session made
// from it is freed, after the server has let it go.

const fs = require('fs');
const path = require('path');
const https = require('https');
const tls = require('tls');
const CRLF = String.fromCharCode(13, 10);

const dir = path.join(__dirname, '..', 'diff');
const server = https.createServer({
  cert: fs.readFileSync(path.join(dir, 'https_server.cert.pem'), 'utf8'),
  key: fs.readFileSync(path.join(dir, 'https_server.key.pem'), 'utf8'),
}, (req: any, res: any) => {
  if (req.url === '/one') {
    server.close(() => console.log('server closed'));
    console.log('close called');
  }
  res.end('answer ' + req.url);
});

server.listen(0, '127.0.0.1', () => {
  const port = server.address().port;
  const s = tls.connect({ port: port, host: '127.0.0.1', rejectUnauthorized: false });
  let got = '';
  s.on('data', (d: any) => { got += d.toString('utf8'); });
  s.on('close', () => {
    console.log('first answered:', got.indexOf('answer /one') >= 0);
    console.log('second answered:', got.indexOf('answer /two') >= 0);
    const late = tls.connect({ port: port, host: '127.0.0.1', rejectUnauthorized: false });
    late.on('secureConnect', () => { console.log('new connection accepted'); late.destroy(); });
    late.on('error', () => console.log('new connection refused'));
  });
  s.write('GET /one HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF +
          'GET /two HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Connection: close' + CRLF + CRLF);
});

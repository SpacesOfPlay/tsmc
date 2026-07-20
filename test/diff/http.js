// http: loopback client+server (GET + POST echo). Deterministic output —
// no Date header or ephemeral port is printed.
const http = require('http');

const server = http.createServer((req, res) => {
  let body = '';
  req.on('data', (c) => { body += c.toString(); });
  req.on('end', () => {
    if (req.method === 'POST') {
      res.writeHead(200, { 'Content-Type': 'text/plain', 'X-Echo': 'yes' });
      res.end('echo:' + body);
    } else {
      res.writeHead(404, { 'Content-Type': 'text/plain' });
      res.end('nope ' + req.url);
    }
  });
});

server.listen(0, '127.0.0.1', () => {
  const port = server.address().port;

  // 1) GET -> 404
  http.get({ host: '127.0.0.1', port, path: '/missing' }, (res) => {
    let b = '';
    res.setEncoding('utf8');
    res.on('data', (c) => { b += c; });
    res.on('end', () => {
      console.log('GET', res.statusCode, res.headers['content-type'], JSON.stringify(b));

      // 2) POST -> echo
      const req = http.request(
        { host: '127.0.0.1', port, method: 'POST', path: '/e', headers: { 'Content-Type': 'text/plain' } },
        (res2) => {
          let b2 = '';
          res2.setEncoding('utf8');
          res2.on('data', (c) => { b2 += c; });
          res2.on('end', () => {
            console.log('POST', res2.statusCode, res2.headers['x-echo'], JSON.stringify(b2));
            server.close();
          });
        }
      );
      req.end('payload-123');
    });
  });
});

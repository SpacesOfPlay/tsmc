// fetch: against a loopback http server. Deterministic output.
const http = require('http');

const server = http.createServer((req, res) => {
  let body = '';
  req.on('data', (c) => { body += c.toString(); });
  req.on('end', () => {
    if (req.url === '/json') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ hello: 'world', n: 42 }));
    } else if (req.method === 'POST') {
      res.writeHead(201, { 'Content-Type': 'text/plain' });
      res.end('created:' + body);
    } else {
      res.writeHead(200, { 'Content-Type': 'text/plain' });
      res.end('root');
    }
  });
});

server.listen(0, '127.0.0.1', async () => {
  const base = 'http://127.0.0.1:' + server.address().port;
  try {
    const r1 = await fetch(base + '/');
    console.log('GET', r1.status, r1.ok, r1.headers.get('content-type'), JSON.stringify(await r1.text()));

    const r2 = await fetch(base + '/json');
    const j = await r2.json();
    console.log('JSON', r2.status, j.hello, j.n);

    const r3 = await fetch(base + '/thing', { method: 'POST', body: 'abc' });
    console.log('POST', r3.status, r3.statusText, JSON.stringify(await r3.text()));
  } catch (e) {
    console.log('ERR', e.message);
  }
  server.close();
});

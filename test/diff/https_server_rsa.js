// The loopback HTTPS server, but with an RSA-2048 certificate: the server
// signs each CertificateVerify with RSASSA-PSS (private-key EM^d mod n) and
// the in-process client verifies it. GET, POST with a body, and a large
// multi-record response over three concurrent connections. Sibling of
// https_server.js (ECDSA-P256), kept separate so a failure is attributed to
// the right key type. Compared byte-for-byte against Node.

const fs = require('fs');
const path = require('path');
const https = require('https');

const dir = __dirname;
const opts = {
  cert: fs.readFileSync(path.join(dir, 'https_server_rsa.cert.pem'), 'utf8'),
  key: fs.readFileSync(path.join(dir, 'https_server_rsa.key.pem'), 'utf8'),
};

const big = 'R'.repeat(20000);

const server = https.createServer(opts, (req, res) => {
  let body = '';
  req.on('data', (c) => { body += c; });
  req.on('end', () => {
    if (req.url === '/big') {
      res.writeHead(200, { 'Content-Type': 'text/plain' });
      res.end(big);
      return;
    }
    res.writeHead(200, {
      'Content-Type': 'text/plain',
      'X-Method': req.method,
      'X-Body-Len': String(body.length),
    });
    res.end('echo[' + req.method + ' ' + req.url + ']:' + body);
  });
});

server.listen(0, '127.0.0.1', () => {
  const port = server.address().port;

  function hit(o) {
    return new Promise((resolve, reject) => {
      const req = https.request({
        host: '127.0.0.1', port, method: o.method, path: o.path,
        rejectUnauthorized: false,
      }, (res) => {
        let data = '';
        res.on('data', (c) => { data += c; });
        res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, data }));
      });
      req.on('error', reject);
      req.end(o.body);
    });
  }

  Promise.all([
    hit({ method: 'GET', path: '/hello' }),
    hit({ method: 'POST', path: '/submit', body: 'payload-123' }),
    hit({ method: 'GET', path: '/big' }),
  ]).then(([get, post, big2]) => {
    console.log('GET  status:', get.status, get.headers['x-method'], get.headers['x-body-len']);
    console.log('GET  body:', get.data);
    console.log('POST status:', post.status, post.headers['x-method'], post.headers['x-body-len']);
    console.log('POST body:', post.data);
    console.log('BIG  status:', big2.status, 'len:', big2.data.length, 'ok:', big2.data === big);
    server.close();
  }).catch((e) => {
    console.log('ERROR:', e.message);
    server.close();
  });
});

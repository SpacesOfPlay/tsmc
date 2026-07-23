// A loopback HTTPS server (ECDSA-P256 certificate) served and fetched by the
// same process: GET, POST with a body, and a large multi-record response,
// over three concurrent connections. Exercises the TLS 1.3 server end to end
// -- the server signs each CertificateVerify with its P-256 key and the
// client verifies it. The client uses rejectUnauthorized:false so the test is
// self-contained (no CA wiring); the signature check still runs.
// Compared byte-for-byte against Node.

const fs = require('fs');
const path = require('path');
const https = require('https');

const dir = __dirname;
const opts = {
  cert: fs.readFileSync(path.join(dir, 'https_server.cert.pem'), 'utf8'),
  key: fs.readFileSync(path.join(dir, 'https_server.key.pem'), 'utf8'),
};

const big = 'Z'.repeat(20000);

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

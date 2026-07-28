// A failed handshake must take down one connection, not the server.
//
// A raw socket writes bytes that look like a TLS record but are not, so the
// handshake fails after the server has accepted the connection but before
// anything could attach an 'error' listener to it. That failure is reported as
// 'tlsClientError'; were it emitted as 'error' with no listener, it would throw
// out of the event loop and end the process. The follow-up request is the
// actual assertion: it only prints if the server is still there.

const fs = require('fs');
const path = require('path');
const net = require('net');
const https = require('https');

const dir = __dirname;
const opts = {
  cert: fs.readFileSync(path.join(dir, 'https_server.cert.pem'), 'utf8'),
  key: fs.readFileSync(path.join(dir, 'https_server.key.pem'), 'utf8'),
};

let clientErrors = 0;

const server = https.createServer(opts, (req, res) => {
  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end('still serving ' + req.url);
});
server.on('tlsClientError', () => { clientErrors++; });

function garbage(port) {
  return new Promise((resolve) => {
    const sock = net.connect(port, '127.0.0.1', () => {
      // a complete handshake record whose ClientHello body is malformed, so
      // the failure is a decode error rather than a truncated read
      sock.write(Buffer.from([0x16, 0x03, 0x01, 0x00, 0x08, 0x01, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00]));
    });
    sock.on('error', () => {});
    sock.on('close', () => resolve());
    setTimeout(() => { sock.destroy(); resolve(); }, 2000);
  });
}

function get(port, p) {
  return new Promise((resolve, reject) => {
    const req = https.request(
      { host: '127.0.0.1', port, path: p, rejectUnauthorized: false },
      (res) => {
        let data = '';
        res.on('data', (c) => { data += c; });
        res.on('end', () => resolve({ status: res.statusCode, data }));
      },
    );
    req.on('error', reject);
    req.end();
  });
}

server.listen(0, '127.0.0.1', async () => {
  const port = server.address().port;
  try {
    await get(port, '/before');
    await garbage(port);
    const after = await get(port, '/after');
    console.log('survived:', after.status, after.data);
    console.log('tlsClientError fired:', clientErrors > 0);
  } catch (e) {
    console.log('ERROR:', e.message);
  }
  server.close();
});

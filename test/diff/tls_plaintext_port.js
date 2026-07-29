// A plaintext request arriving on a TLS port must get nothing back.
//
// This is what a browser does when you type http:// at an https:// port. The
// bytes are not a TLS record, so the handshake cannot start. Replying with a
// TLS alert is worse than replying with nothing: the browser is waiting for an
// HTTP response, so it renders the alert bytes as the page -- a screen of
// mojibake instead of an error it can explain. Closing is what node does.
//
// Only the byte count is compared. The reason text differs between engines
// (node reports an OpenSSL code), so the test asserts that the connection was
// reported at all, not how it was described.

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
  res.end('secure');
});
server.on('tlsClientError', () => { clientErrors++; });

// Speaks cleartext HTTP at the TLS port and reports what came back.
function plaintext(port) {
  return new Promise((resolve) => {
    const chunks = [];
    const sock = net.connect(port, '127.0.0.1', () => {
      sock.write('GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n');
    });
    sock.on('data', (c) => chunks.push(c));
    sock.on('error', () => {});
    sock.on('close', () => resolve(Buffer.concat(chunks)));
    setTimeout(() => sock.destroy(), 4000);
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
    const back = await plaintext(port);
    console.log('bytes returned to a plaintext request:', back.length);
    console.log('reported as a client error:', clientErrors > 0);
    // the port still serves TLS afterwards
    const after = await get(port, '/after');
    console.log('still serving:', after.status, after.data);
  } catch (e) {
    console.log('ERROR:', e.message);
  }
  server.close();
});

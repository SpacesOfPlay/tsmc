// The `plaintextResponse` option: what a TLS server hands to a peer that
// turned out not to be speaking TLS.
//
// A tsmc extension, so this is a golden run test rather than a differential
// one -- node has no such option and would ignore it. The behaviour without
// the option (nothing sent, matching node) is covered by
// test/diff/tls_plaintext_port.js.
//
// The reply goes out in the clear, because there is no session to encrypt
// with. That is the whole point: it is the only thing a browser sent to
// http:// on an https:// port can actually read.

const fs = require('fs');
const path = require('path');
const net = require('net');
const https = require('https');

const dir = path.join(__dirname, '..', 'diff');
const REPLY = 'HTTP/1.1 400 Bad Request\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhttps';

function speakPlaintext(port: number): Promise<string> {
  return new Promise((resolve) => {
    const chunks: any[] = [];
    const sock = net.connect(port, '127.0.0.1', () => {
      sock.write('GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n');
    });
    sock.on('data', (c: any) => chunks.push(c));
    sock.on('error', () => {});
    sock.on('close', () => resolve(Buffer.concat(chunks).toString('utf8')));
    setTimeout(() => sock.destroy(), 4000);
  });
}

function fetchSecure(port: number): Promise<string> {
  return new Promise((resolve, reject) => {
    const req = https.request(
      { host: '127.0.0.1', port, path: '/', rejectUnauthorized: false },
      (res: any) => {
        let d = '';
        res.on('data', (c: any) => { d += c; });
        res.on('end', () => resolve(res.statusCode + ' ' + d));
      },
    );
    req.on('error', reject);
    req.end();
  });
}

const codes: string[] = [];
const server = https.createServer(
  {
    cert: fs.readFileSync(path.join(dir, 'https_server.cert.pem'), 'utf8'),
    key: fs.readFileSync(path.join(dir, 'https_server.key.pem'), 'utf8'),
    plaintextResponse: REPLY,
  },
  (req: any, res: any) => { res.writeHead(200); res.end('secure'); },
);
server.on('tlsClientError', (e: any) => { codes.push(String(e.code)); });

server.listen(0, '127.0.0.1', async () => {
  const port = server.address().port;
  const got = await speakPlaintext(port);
  console.log('reply status: ' + got.split('\r\n')[0]);
  console.log('reply body: ' + got.split('\r\n\r\n')[1]);
  console.log('error code: ' + codes.join(','));
  // the same port still serves TLS to a client that speaks it
  console.log('then over TLS: ' + await fetchSecure(port));
  server.close();
});

// A TLSSocket writing a few MB to a peer that stops reading for a while:
// write() turns false, 'drain' follows once the peer reads again, every
// byte arrives in order, and nothing is left queued at the end. The socket
// comes from an https 'upgrade', so it is the one a WebSocket server gets.
const https = require('https');
const fs = require('fs');
const path = require('path');

const CRLF = '\r\n';
const HEAD_101 = 'HTTP/1.1 101 Switching Protocols' + CRLF + 'Upgrade: raw' + CRLF + 'Connection: Upgrade' + CRLF + CRLF;
const CHUNK = 32768;
const TOTAL = 96 * CHUNK;   // 3 MB

const dir = __dirname;
const server = https.createServer({
  cert: fs.readFileSync(path.join(dir, 'https_server.cert.pem'), 'utf8'),
  key: fs.readFileSync(path.join(dir, 'https_server.key.pem'), 'utf8'),
}, (req, res) => { res.writeHead(500); res.end(); });

let serverReport = null;
let clientReport = null;
function finish() {
  if (!serverReport || !clientReport) return;
  console.log(serverReport);
  console.log(clientReport);
  server.close();
}

server.on('upgrade', (req, socket, head) => {
  socket.on('error', (e) => { serverReport = 'server: error ' + e.message; finish(); });
  socket.write(HEAD_101);
  let sent = 0;
  let sawFalse = false;
  let drains = 0;
  // chunk n is filled with the byte n, so the receiver can check the order
  function pump() {
    while (sent < TOTAL) {
      const b = Buffer.alloc(CHUNK, (sent / CHUNK) & 0xff);
      sent += CHUNK;
      if (!socket.write(b)) {
        sawFalse = true;
        socket.once('drain', () => { drains++; pump(); });
        return;
      }
    }
    socket.end();
  }
  pump();
  socket.on('close', () => {
    serverReport = 'server: wrote ' + sent + ' bytes, write returned false: ' + sawFalse +
      ', drained: ' + (drains > 0) + ', queued at close: ' + socket.writableLength;
    finish();
  });
});

server.listen(0, '127.0.0.1', () => {
  const req = https.request({
    host: '127.0.0.1', port: server.address().port, path: '/stream', rejectUnauthorized: false,
    headers: { Connection: 'Upgrade', Upgrade: 'raw' },
  });
  req.on('upgrade', (res, socket, head) => {
    let got = 0;
    let inOrder = true;
    function take(d) {
      for (let i = 0; i < d.length; i++) {
        if (d[i] !== (((got + i) / CHUNK) & 0xff)) inOrder = false;
      }
      got += d.length;
    }
    take(head);
    socket.on('data', take);
    // the peer keeps writing into a socket nobody reads: that is the test
    socket.pause();
    setTimeout(() => socket.resume(), 400);
    socket.on('error', (e) => { clientReport = 'client: error ' + e.message; finish(); });
    socket.on('close', () => {
      clientReport = 'client: got ' + got + ' bytes, complete: ' + (got === TOTAL) + ', in order: ' + inOrder;
      finish();
    });
  });
  req.on('error', (e) => { clientReport = 'client: request error ' + e.message; finish(); });
  req.end();
});

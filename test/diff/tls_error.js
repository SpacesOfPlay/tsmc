// tls: a TLSSocket against a server that speaks garbage must fail
// gracefully (emit 'error', not crash). Deterministic — a loopback net
// server sends a non-TLS response, so no cert/network is involved. The
// happy https path is covered by the manual test/tls/https_fetch.js (a
// gated success test needs picotls server mode).
const net = require('net');
const tls = require('tls');

const server = net.createServer((sock) => {
  // Answer the first record and nothing after it. A peer may reply to the
  // garbage with an alert, and that arrives as another data event: end()
  // half-closes, so this socket is still readable.
  let answered = false;
  sock.on('data', () => {
    if (answered) return;
    answered = true;
    sock.write('NOT-A-TLS-RECORD garbage garbage garbage');
    sock.end();
  });
});

server.listen(0, '127.0.0.1', () => {
  const port = server.address().port;
  const s = tls.connect({ port, host: '127.0.0.1' });
  s.on('secureConnect', () => { console.log('UNEXPECTED secure'); s.destroy(); server.close(); });
  s.on('error', () => { console.log('tls error caught'); server.close(); });
});

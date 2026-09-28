// A TLS connection that the peer resets during the handshake fails on the
// client: 'error' and then 'close'. Taken for "nothing to read yet", a reset
// would leave the socket silent forever.
//
// The reset is a real one: a plain TCP server stops reading, so the
// ClientHello stays unread in its socket, and closing a socket with unread
// data resets the connection. A reset after data is test/run/
// tls_reset_after_data.ts: node's server side does not reset there.
//
// Only the order of events is printed: the message and code of a reset differ
// between platforms and runtimes.
const net = require('net');
const tls = require('tls');

function client(port, name, onData, done) {
  const events = [];
  const s = tls.connect({ port: port, host: '127.0.0.1', rejectUnauthorized: false });
  s.on('data', (d) => { events.push('data ' + d.toString()); if (onData) onData(s); });
  s.on('error', () => events.push('error'));
  s.on('close', () => {
    events.push('close');
    console.log(name + ': ' + events.join(', '));
    done();
  });
}

// 1. A reset during the handshake.
function duringHandshake(next) {
  const server = net.createServer((sock) => {
    sock.on('error', () => {});
    sock.pause();
    setTimeout(() => sock.destroy(), 200);
  });
  server.listen(0, '127.0.0.1', () => {
    client(server.address().port, 'reset in the handshake', null, () => { server.close(); next(); });
  });
}

duringHandshake(() => {});

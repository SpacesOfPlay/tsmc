// A TLS connection reset after data: the client delivers what arrived before
// the reset, then fails with a read error and closes.
//
// Taken for "nothing to read yet", a reset leaves the socket silent: no data,
// no 'error', no 'close', and an HTTPS response that neither completes nor
// fails. On Windows the reset also discards what the socket had not yet
// handed over.
//
// The reset is a real one. A TLS server behind a plain TCP relay says hello;
// at that moment the relay stops reading from the client, and 300 ms later it
// closes the client's connection, whose answer to the hello is then unread; a
// close with unread data resets the connection. A golden test rather than a
// differential one: node's relay reads on while paused and closes cleanly.
// The reset during the handshake is test/diff/tls_reset.js.

const fs = require('fs');
const path = require('path');
const net = require('net');
const tls = require('tls');

const dir = path.join(__dirname, '..', 'diff');
let front: any = null;
let relay: any = null;

const server = tls.createServer({
  cert: fs.readFileSync(path.join(dir, 'https_server.cert.pem'), 'utf8'),
  key: fs.readFileSync(path.join(dir, 'https_server.key.pem'), 'utf8'),
}, (sock: any) => {
  sock.on('error', () => {});
  front.pause();
  sock.write('hello');
  setTimeout(() => { front.destroy(); sock.destroy(); }, 300);
});

server.listen(0, '127.0.0.1', () => {
  relay = net.createServer((c: any) => {
    front = c;
    c.on('error', () => {});
    const back = net.connect(server.address().port, '127.0.0.1');
    back.on('error', () => {});
    c.on('data', (d: any) => back.write(d));
    back.on('data', (d: any) => c.write(d));
  });
  relay.listen(0, '127.0.0.1', () => {
    const events: string[] = [];
    const s = tls.connect({ port: relay.address().port, host: '127.0.0.1', rejectUnauthorized: false });
    s.on('data', (d: any) => { events.push('data ' + d.toString()); s.write('unread by the relay'); });
    s.on('error', (e: any) => events.push('error ' + e.message + ' (' + e.code + ')'));
    s.on('close', () => {
      events.push('close');
      console.log(events.join('\n'));
      relay.close();
      server.close();
    });
  });
});

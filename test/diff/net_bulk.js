// Bulk echo over net and over tls: the client writes far more than the
// socket buffers hold and ends right after its last write; the server echoes
// and ends when the client does. Every byte must come back, in order — the
// server's queue must drain before its socket closes on the client's EOF.
const net = require('net');
const tls = require('tls');
const fs = require('fs');
const path = require('path');

const CHUNK = 65536;

function run(label, TOTAL, makeServer, connect, done) {
  const server = makeServer((s) => {
    s.on('data', (d) => { s.write(d); });
    s.on('end', () => { s.end(); });
    s.on('error', () => {});
  });
  server.listen(0, '127.0.0.1', () => {
    const c = connect(server.address().port);
    let sent = 0;
    let got = 0;
    let inOrder = true;
    function pump() {
      while (sent < TOTAL) {
        const b = Buffer.alloc(CHUNK, (sent / CHUNK) & 0xff);
        sent += CHUNK;
        if (!c.write(b)) { c.once('drain', pump); return; }
      }
      c.end();
    }
    c.on('connect', pump);
    c.on('data', (d) => {
      for (let i = 0; i < d.length; i++) if (d[i] !== (((got + i) / CHUNK) & 0xff)) inOrder = false;
      got += d.length;
    });
    c.on('close', () => {
      console.log(label + ': echoed ' + got + ' of ' + TOTAL + ' bytes, complete: ' + (got === TOTAL) + ', in order: ' + inOrder);
      server.close();
      done();
    });
    c.on('error', (e) => { console.log(label + ': error ' + e.message); });
  });
}

const dir = __dirname;
const opts = {
  cert: fs.readFileSync(path.join(dir, 'https_server.cert.pem'), 'utf8'),
  key: fs.readFileSync(path.join(dir, 'https_server.key.pem'), 'utf8'),
};

// the encrypted run is smaller: it is the same queue logic, at cipher speed
run('net', 12 * 1048576, (h) => net.createServer(h), (port) => net.connect(port, '127.0.0.1'), () => {
  run('tls', 3 * 1048576, (h) => tls.createServer(opts, h),
    (port) => tls.connect({ port, host: '127.0.0.1', rejectUnauthorized: false }), () => {});
});

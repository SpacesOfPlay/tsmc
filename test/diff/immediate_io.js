// Sockets are served between the links of a setImmediate chain: work split
// into short pieces that follow each other with setImmediate does not keep
// a connection waiting until the chain ends. Node polls for I/O once per
// turn of its loop, between the immediates.

const net = require('net');

const server = net.createServer((s) => {
  s.on('data', () => s.end('pong'));
});

server.listen(0, '127.0.0.1', () => {
  const port = server.address().port;
  const t0 = Date.now();
  let chainDone = false;
  let links = 0;
  function link() {
    links++;
    const t = Date.now();
    while (Date.now() - t < 5) { }
    if (Date.now() - t0 < 300) setImmediate(link);
    else chainDone = true;
  }
  const c = net.connect(port, '127.0.0.1', () => c.write('ping'));
  c.on('data', (d) => {
    console.log('answered', String(d), 'while the chain ran:', !chainDone);
    c.destroy();
    server.close();
  });
  setImmediate(link);
});

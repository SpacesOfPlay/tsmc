// net: loopback TCP echo (client + server) — output must be deterministic
// (no ephemeral port printed).
const net = require('net');

const server = net.createServer((sock) => {
  sock.on('data', (d) => { sock.write(d); });   // echo
  sock.on('end', () => { sock.end(); });
});

server.listen(0, '127.0.0.1', () => {
  const port = server.address().port;
  let got = '';
  const client = net.connect(port, '127.0.0.1', () => {
    client.write('hello ');
    client.write('world');
  });
  client.on('data', (d) => {
    got += d.toString();
    if (got.length >= 11) client.end();
  });
  client.on('close', () => {
    console.log('echo:', JSON.stringify(got));
    server.close();
  });
});

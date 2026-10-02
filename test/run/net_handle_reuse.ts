// net: a closed socket's slot is taken by the next connection, and the
// closed socket, written to or destroyed again, does not reach it. A
// thousand connections, opened and closed one after another, leave the
// server answering as quickly as at the start.

const net = require('net');

const server = net.createServer((c: any) => {
  c.on('data', (d: any) => c.write(d));
  c.on('error', () => {});
});

function open(port: number): Promise<any> {
  return new Promise((resolve) => {
    const s = net.connect(port, '127.0.0.1', () => resolve(s));
    s.on('error', () => {});
  });
}

function echo(s: any, text: string): Promise<string> {
  return new Promise((resolve) => {
    s.once('data', (d: any) => resolve(d.toString()));
    s.write(text);
  });
}

async function main() {
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const port = server.address().port;

  const a = await open(port);
  console.log('a:', await echo(a, 'one'));
  a.destroy();
  await new Promise((r) => setTimeout(r, 20));
  const b = await open(port);
  // the closed socket is used again; none of it may reach b
  let wrote = true;
  try { wrote = a.write('stray'); } catch (e) { wrote = false; }
  a.destroy();
  a.end();
  console.log('b:', await echo(b, 'two'), '| b still writable:', b.writable, '| a destroyed:', a.destroyed);

  for (let i = 0; i < 1000; i++) {
    const s = await open(port);
    s.destroy();
  }
  console.log('b after 1000 more:', await echo(b, 'three'));
  b.destroy();
  server.close();
}

main();

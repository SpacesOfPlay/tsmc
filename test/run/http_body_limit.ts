// http: a server's ceiling on a request body (maxBodySize). None by
// default, as in node: a 2 MB body is served. With one of 1 MB, a declared
// length past it is refused before a byte is kept, a chunked body is
// refused when it grows past it, and one under it is served.

const http = require('http');
const net = require('net');
const CRLF = String.fromCharCode(13, 10);

function counting(req: any, res: any) {
  let n = 0;
  req.on('data', (c: any) => { n += c.length; });
  req.on('end', () => res.end('got ' + n));
}
const open = http.createServer(counting);
const server = http.createServer(counting);
server.maxBodySize = 1024 * 1024;

function raw(port: number, head: string, body: (s: any) => void): Promise<string> {
  return new Promise((resolve) => {
    const s = net.connect(port, '127.0.0.1', () => { s.write(head); body(s); });
    let got = '';
    s.on('data', (d: any) => { got += d.toString('latin1'); });
    s.on('close', () => resolve(got.split(CRLF)[0]));
    s.on('error', () => {});
  });
}

// Chunks of 64 KB, `count` of them, then the last chunk.
function chunks(count: number) {
  return (s: any) => {
    const piece = 'x'.repeat(65536);
    for (let i = 0; i < count; i++) s.write('10000' + CRLF + piece + CRLF);
    s.write('0' + CRLF + CRLF);
  };
}

async function main() {
  const post = (extra: string) => 'POST / HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Connection: close' + CRLF + extra + CRLF;
  await new Promise((r) => open.listen(0, '127.0.0.1', r));
  console.log('no limit, chunked 2 MB:', await raw(open.address().port, post('Transfer-Encoding: chunked' + CRLF), chunks(32)));
  open.close();
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const port = server.address().port;
  console.log('declared 2 MB:', await raw(port, post('Content-Length: 2097152' + CRLF), () => {}));
  console.log('chunked 2 MB:', await raw(port, post('Transfer-Encoding: chunked' + CRLF), chunks(32)));
  console.log('chunked 512 KB:', await raw(port, post('Transfer-Encoding: chunked' + CRLF), chunks(8)));
  server.close();
}

main();

// http: a handler that answers before the request's body has been read.
// The body is still the body, up to its declared end, and only what
// follows it is the next request: a body that holds the text of a request
// is not served as one, whether it has a length, is chunked, or arrives
// after the answer. Requests sent back to back are served in order, and
// a request answered early still ends.

const http = require('http');
const net = require('net');
const CRLF = String.fromCharCode(13, 10);

const server = http.createServer((req: any, res: any) => {
  let n = 0;
  req.on('data', (c: any) => { n += c.length; });
  req.on('end', () => console.log('  end of', req.method, req.url, n, 'bytes'));
  console.log('  request', req.method, req.url);
  res.end('answer ' + req.url);
});

function send(port: number, pieces: string[]): Promise<string> {
  return new Promise((resolve) => {
    const s = net.connect(port, '127.0.0.1', async () => {
      for (const p of pieces) {
        s.write(p);
        await new Promise((r) => setTimeout(r, 50));
      }
    });
    let got = '';
    s.on('data', (d: any) => { got += d.toString('latin1'); });
    s.on('close', () => {
      const answers = got.split(CRLF).filter((l: string) => l.indexOf('answer ') >= 0 || l.indexOf('HTTP/1.1') === 0);
      resolve(answers.join(' | '));
    });
    s.on('error', () => {});
  });
}

const inner = 'GET /smuggled HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF;
const last = 'GET /last HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Connection: close' + CRLF + CRLF;

async function main() {
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const port = server.address().port;
  console.log('a body holding a request, with a length:');
  console.log('  ' + await send(port, ['POST /form HTTP/1.1' + CRLF + 'Host: x' + CRLF +
    'Content-Length: ' + inner.length + CRLF + CRLF + inner + last]));
  console.log('the same, chunked:');
  console.log('  ' + await send(port, ['POST /form HTTP/1.1' + CRLF + 'Host: x' + CRLF +
    'Transfer-Encoding: chunked' + CRLF + CRLF + inner.length.toString(16) + CRLF + inner + CRLF +
    '0' + CRLF + CRLF + last]));
  console.log('the body after the answer:');
  console.log('  ' + await send(port, ['POST /form HTTP/1.1' + CRLF + 'Host: x' + CRLF +
    'Content-Length: ' + inner.length + CRLF + CRLF, inner, last]));
  console.log('two at once:');
  console.log('  ' + await send(port, ['GET /one HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF + last]));
  server.close();
}

main();

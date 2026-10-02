// http: request heads as the server reads them, and the response head it
// writes. Repeated headers fold, Set-Cookie stays a list, names are trimmed
// and lowercased, the version comes from the request line; a head that
// arrives a byte at a time reads the same; a name or value outside ASCII
// comes through as UTF-8.

const http = require('http');
const net = require('net');
const CRLF = String.fromCharCode(13, 10);

const server = http.createServer((req: any, res: any) => {
  const seen = { method: req.method, url: req.url, version: req.httpVersion, headers: req.headers };
  res.setHeader('Set-Cookie', ['a=1', 'b=2']);
  res.setHeader('X-Count', 42);
  res.setHeader('x-multi-part-name', 'v');
  if (req.headers['x-reply'] !== undefined) res.setHeader('X-Reply', req.headers['x-reply']);
  res.writeHead(201, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(seen));
});

function send(port: number, pieces: string[]): Promise<string> {
  return new Promise((resolve) => {
    const s = net.connect(port, '127.0.0.1', async () => {
      for (const p of pieces) {
        s.write(Buffer.from(p, 'utf8'));
        if (pieces.length > 1) await new Promise((r) => setTimeout(r, 1));
      }
    });
    const got: any[] = [];
    s.on('data', (d: any) => { got.push(d); });
    s.on('close', () => resolve(Buffer.concat(got).toString('utf8')));
    s.on('error', () => {});
  });
}

function head(lines: string[]) {
  return lines.join(CRLF) + CRLF + 'Connection: close' + CRLF + CRLF;
}

async function main() {
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const port = server.address().port;
  const cases: [string, string[]][] = [
    ['folding', [head(['GET /a?b=1 HTTP/1.1', 'Host: x', 'X-Dup: 1', 'x-dup:2', 'Set-Cookie: c=1',
                       'set-cookie: d=2', '  Spaced Name  :   v  ', 'NoColon', ':empty', 'Tab:' + String.fromCharCode(9) + 'x'])]],
    ['http/1.0', [head(['GET / HTTP/1.0'])]],
    ['no version', [head(['GET /x'])]],
    ['odd line', [head(['GET  /two HTTP/2/x'])]],
    ['utf-8', [head(['GET / HTTP/1.1', 'X-Reply: caf' + String.fromCharCode(233)])]],
    ['proto', [head(['GET / HTTP/1.1', '__proto__: x', 'X-After: y'])]],
  ];
  const slow = head(['POST /slow HTTP/1.1', 'Host: y', 'Content-Length: 0']);
  cases.push(['a byte at a time', slow.split('')]);
  for (const [name, pieces] of cases) {
    const r = await send(port, pieces);
    console.log('--- ' + name);
    console.log(r.split(CRLF).join(' | '));
  }
  server.close();
}

main();

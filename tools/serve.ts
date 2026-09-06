// A static file server for the playground, run by tsmc itself:
//
//   tsmc tools/serve.ts [dir] [port]      default: build/web on 8080
//
// A browser will not load a wasm module from a file: URL, so the page
// needs an origin. Nothing is cached, to keep a rebuild visible on reload.

import http from 'http';
import fs from 'fs';
import path from 'path';

const root = path.resolve(process.argv[2] ?? 'build/web');
const port = Number(process.argv[3] ?? 8080);

const types: Record<string, string> = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.wasm': 'application/wasm',
  '.json': 'application/json',
  '.ts': 'text/plain; charset=utf-8',
  '.md': 'text/markdown; charset=utf-8',
  '.svg': 'image/svg+xml',
};

const server = http.createServer((req, res) => {
  let urlPath = (req.url ?? '/').split('?')[0];
  try {
    urlPath = decodeURIComponent(urlPath);
  } catch (e) {
    res.writeHead(400);
    res.end();
    return;
  }
  if (urlPath.endsWith('/')) urlPath += 'index.html';
  const file = path.resolve(root, '.' + urlPath);
  if (file !== root && !file.startsWith(root + path.sep)) {
    res.writeHead(403);
    res.end();
    return;
  }
  let body: Buffer;
  try {
    body = fs.readFileSync(file);
  } catch (e) {
    res.writeHead(404, { 'content-type': 'text/plain' });
    res.end('not found\n');
    return;
  }
  res.writeHead(200, {
    'content-type': types[path.extname(file)] ?? 'application/octet-stream',
    'content-length': String(body.length),
    'cache-control': 'no-cache',
  });
  res.end(body);
});

server.listen(port, '127.0.0.1', () => {
  console.log(`serving ${root} at http://127.0.0.1:${port}/`);
});

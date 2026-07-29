// An HTTPS content server, in TypeScript, on tsmc.
//
//   tsmc serve.cts [--root DIR] [--port N] [--host H] [--http]
//
// Markdown renders to HTML; anything else is served as-is. Responses carry a
// SHA-256 entity tag and answer conditional requests with 304, and text is
// gzipped when the client asks for it.

const fs = require('fs');
const path = require('path');
const http = require('http');
const https = require('https');
const { Outcome } = require('./types.cts');
const router = require('./router.cts');
const render = require('./render.cts');
const mime = require('./mime.cts');
const respond = require('./respond.cts');

interface ServeOptions {
  root: string;
  port: number;
  host: string;
  tls: boolean;
  certFile: string;
  keyFile: string;
}

interface Prepared {
  status: number;
  headers: Record<string, string>;
  body: Buffer;
  outcome: string;
}

function parseArgs(argv: string[]): ServeOptions {
  const here = __dirname;
  const opts: ServeOptions = {
    root: path.join(here, 'content'),
    port: 8443,
    host: '127.0.0.1',
    tls: true,
    certFile: path.join(here, 'serve.cert.pem'),
    keyFile: path.join(here, 'serve.key.pem'),
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--http') opts.tls = false;
    else if (a === '--root') opts.root = path.resolve(argv[++i]);
    else if (a === '--port') opts.port = Number(argv[++i]);
    else if (a === '--host') opts.host = argv[++i];
    else if (a === '--cert') opts.certFile = argv[++i];
    else if (a === '--key') opts.keyFile = argv[++i];
  }
  return opts;
}

function textResponse(status: number, text: string, outcome: string): Prepared {
  return {
    status,
    headers: { 'Content-Type': 'text/plain; charset=utf-8' },
    body: Buffer.from(text, 'utf8'),
    outcome,
  };
}

function prepare(opts: ServeOptions, req: any): Prepared {
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    return textResponse(405, 'method not allowed\n', Outcome.Rejected);
  }

  const found = router.resolve(opts.root, req.url || '/');
  if (found.kind === 'rejected') return textResponse(400, 'bad request\n', Outcome.Rejected);
  if (found.kind === 'missing') return textResponse(404, 'not found\n', Outcome.NotFound);

  let filePath = found.path;
  let outcome = Outcome.File;

  if (found.kind === 'dir') {
    const idx = router.indexOf(found.path);
    if (idx === null) {
      return {
        status: 200,
        headers: { 'Content-Type': 'text/html; charset=utf-8' },
        body: Buffer.from(render.renderIndex(found.path, found.urlPath), 'utf8'),
        outcome: Outcome.Index,
      };
    }
    filePath = idx;
  }

  const stat = fs.statSync(filePath);
  if (stat.size > respond.MAX_BYTES) {
    return textResponse(413, 'file too large for this demo server\n', Outcome.Rejected);
  }

  const ext = path.extname(filePath);
  let body: Buffer;
  let contentType: string;
  if (ext === '.md') {
    const src = fs.readFileSync(filePath, 'utf8');
    body = Buffer.from(render.renderMarkdown(src, path.basename(filePath, '.md')), 'utf8');
    contentType = 'text/html; charset=utf-8';
    outcome = Outcome.Markdown;
  } else {
    body = fs.readFileSync(filePath);
    contentType = mime.contentTypeFor(ext);
  }

  return {
    status: 200,
    headers: {
      'Content-Type': contentType,
      'Last-Modified': new Date(stat.mtimeMs).toUTCString(),
    },
    body,
    outcome,
  };
}

function log(req: any, status: number, bytes: number, outcome: string): void {
  process.stdout.write([req.method, req.url, status, bytes, outcome].join(' ') + '\n');
}

function handle(opts: ServeOptions, req: any, res: any): void {
  let out: Prepared;
  try {
    out = prepare(opts, req);
  } catch (e) {
    out = textResponse(500, 'internal error\n', Outcome.Failed);
    process.stderr.write('error: ' + ((e && e.message) || String(e)) + '\n');
  }

  const headers: Record<string, string> = {};
  for (const k of Object.keys(out.headers)) headers[k] = out.headers[k];

  if (out.status === 200) {
    const etag = respond.etagFor(out.body);
    headers['ETag'] = etag;
    headers['Cache-Control'] = 'no-cache';
    if (respond.matchesEtag(req.headers['if-none-match'], etag)) {
      res.writeHead(304, { ETag: etag, 'Cache-Control': 'no-cache' });
      res.end();
      log(req, 304, 0, Outcome.NotModified);
      return;
    }
  }

  const enc = respond.encode(
    out.body,
    headers['Content-Type'] || 'application/octet-stream',
    respond.acceptsGzip(req.headers['accept-encoding']),
  );
  if (enc.encoding) {
    headers['Content-Encoding'] = enc.encoding;
    headers['Vary'] = 'Accept-Encoding';
  }
  headers['Content-Length'] = String(enc.bytes.length);

  res.writeHead(out.status, headers);
  if (req.method === 'HEAD') res.end();
  else res.end(enc.bytes);
  log(req, out.status, enc.bytes.length, out.outcome);
}

/**
 * What to send someone who spoke plain HTTP to the TLS port — typing
 * http://host:8443 instead of https://. There is no session to encrypt with,
 * so this goes out in the clear; without it the browser gets nothing and shows
 * a blank error, which does not hint at the one-character fix.
 */
function plaintextRedirect(opts: ServeOptions): string {
  const url = 'https://' + opts.host + ':' + opts.port + '/';
  const body =
    '<!doctype html><meta charset="utf-8"><title>Use HTTPS</title>' +
    '<h1>This port speaks HTTPS</h1>' +
    '<p>You asked for it over plain HTTP. Try <a href="' + url + '">' + url + '</a>.</p>\n';
  return [
    'HTTP/1.1 400 Bad Request',
    'Content-Type: text/html; charset=utf-8',
    'Content-Length: ' + Buffer.byteLength(body, 'utf8'),
    'Connection: close',
    '',
    body,
  ].join('\r\n');
}

function main(): void {
  const opts = parseArgs(process.argv.slice(2));
  if (!fs.existsSync(opts.root)) {
    process.stderr.write('no such content root: ' + opts.root + '\n');
    process.exit(2);
  }

  const listener = (req: any, res: any) => handle(opts, req, res);
  const server = opts.tls
    ? https.createServer(
        {
          cert: fs.readFileSync(opts.certFile, 'utf8'),
          key: fs.readFileSync(opts.keyFile, 'utf8'),
          plaintextResponse: plaintextRedirect(opts),
        },
        listener,
      )
    : http.createServer(listener);

  // A handshake the client walks away from is one connection's problem, not
  // the server's. Browsers do exactly this with the self-signed demo
  // certificate until you accept it, so say so rather than fail silently.
  server.on('tlsClientError', (err: any) => {
    process.stderr.write('tls: ' + ((err && err.message) || String(err)) + '\n');
  });
  server.on('clientError', (err: any) => {
    process.stderr.write('connection: ' + ((err && err.message) || String(err)) + '\n');
  });

  server.listen(opts.port, opts.host, () => {
    const scheme = opts.tls ? 'https' : 'http';
    const addr = server.address();
    const port = addr && typeof addr === 'object' ? addr.port : opts.port;
    process.stdout.write('serving ' + opts.root + ' on ' + scheme + '://' + opts.host + ':' + port + '\n');
  });
}

main();

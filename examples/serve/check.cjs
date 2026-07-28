// Drives a running server through a fixed request list and prints a normalised
// transcript. Run it against tsmc and against node and diff the two: the app
// should behave identically on both.
//
//   node check.cjs 8099            # or: tsmc check.cjs 8099
//
// Only headers the server controls are printed, and bodies are reduced to a
// length plus a hash, so the transcript is stable.

const http = require('http');
const https = require('https');
const crypto = require('crypto');
const zlib = require('zlib');

const port = Number(process.argv[2] || 8099);
const useTls = process.argv.indexOf('--tls') >= 0;
const SHOW = ['content-type', 'content-encoding', 'content-length', 'vary', 'cache-control'];

function once(pathname, headers, method) {
  return new Promise((resolve) => {
    const mod = useTls ? https : http;
    const opts = {
      host: '127.0.0.1', port, path: pathname, method: method || 'GET',
      headers: headers || {}, rejectUnauthorized: false,
    };
    const req = mod.request(opts, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        let body = Buffer.concat(chunks);
        const enc = res.headers['content-encoding'];
        let note = '';
        if (enc === 'gzip') {
          const plain = zlib.gunzipSync(body);
          note = ' gunzip=' + plain.length;
          body = plain;
        }
        const shown = SHOW
          .filter((h) => res.headers[h] !== undefined)
          .map((h) => h + '=' + res.headers[h])
          .join(' ');
        const digest = crypto.createHash('sha256').update(body).digest('hex').slice(0, 12);
        resolve({
          line: [method || 'GET', pathname, res.statusCode, shown, 'body=' + body.length,
                 'sha=' + digest + note].join(' '),
          etag: res.headers['etag'],
        });
      });
    });
    req.on('error', (e) => resolve({ line: (method || 'GET') + ' ' + pathname + ' ERROR ' + e.message, etag: null }));
    req.end();
  });
}

async function main() {
  const out = [];
  const plain = await once('/');
  out.push(plain.line);

  // conditional request with the tag we were just given
  out.push((await once('/', { 'If-None-Match': plain.etag })).line);
  out.push((await once('/', { 'If-None-Match': '"nope"' })).line);
  out.push((await once('/', { 'If-None-Match': '*' })).line);

  // compression
  out.push((await once('/', { 'Accept-Encoding': 'gzip' })).line);
  out.push((await once('/', { 'Accept-Encoding': 'br' })).line);

  // markdown, nested markdown, directory index, static asset
  out.push((await once('/notes/')).line);
  out.push((await once('/notes/regex.md')).line);
  out.push((await once('/style.css')).line);

  // HEAD, and a method that is not allowed
  out.push((await once('/', null, 'HEAD')).line);
  out.push((await once('/', null, 'DELETE')).line);

  // misses and traversal attempts
  out.push((await once('/nope.md')).line);
  out.push((await once('/../package.json')).line);
  out.push((await once('/..%2Fpackage.json')).line);
  out.push((await once('/%2e%2e/%2e%2e/package.json')).line);
  out.push((await once('/notes/../index.md')).line);

  console.log(out.join('\n'));
}

main();

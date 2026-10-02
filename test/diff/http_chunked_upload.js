// http: request bodies sent chunked.
//
// The raw cases write the bytes themselves, split across chunk-size lines
// and chunk data, so the framing is exact. The server hands the body on as
// it arrives: the handler of /first answers the first piece before the
// client sends the rest. Extensions and trailers are read past, and the
// connection serves the next request after them. A request with both a
// length and a coding, a coding that does not end in chunked, a size that
// is not hex and a chunk without its CRLF are refused with 400. Last, the
// runtime's own client uploads in pieces without a length.

const http = require('http');
const net = require('net');

const out = [];
function T(label, v) { out.push(label + ' = ' + (typeof v === 'string' ? JSON.stringify(v) : String(v))); }
const CRLF = String.fromCharCode(13, 10);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const server = http.createServer((req, res) => {
  const path = (req.url || '').split('?')[0];
  if (path === '/first') {
    let body = '';
    let answered = false;
    req.on('data', (c) => {
      body += c;
      if (!answered) { answered = true; res.writeHead(200, { 'Content-Type': 'text/plain' }); res.write('got ' + body + ';'); }
    });
    req.on('end', () => res.end(' all ' + body));
    return;
  }
  let body = '';
  req.on('data', (c) => { body += c; });
  req.on('end', () => {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end(req.method + ' ' + path + ' ' + body.length + ' ' + body);
  });
});
server.on('clientError', (e, socket) => {
  // node's default answer for a request it cannot parse, written here so
  // both runtimes close the same way.
  if (socket.writable) socket.end('HTTP/1.1 400 Bad Request' + CRLF + 'Connection: close' + CRLF + CRLF);
});

// Writes `pieces` (strings, or numbers: a pause in ms) to a new
// connection and resolves with all it gets back.
function raw(port, pieces, until) {
  return new Promise((resolve) => {
    const s = net.connect(port, '127.0.0.1', async () => {
      for (const p of pieces) {
        if (typeof p === 'number') await sleep(p);
        else if (typeof p === 'function') await p(got);
        else s.write(p);
      }
    });
    let got = '';
    const waiters = [];
    got = { text: '', wait(sub) { return new Promise((r) => { if (this.text.indexOf(sub) >= 0) r(); else waiters.push([sub, r]); }); } };
    s.on('data', (d) => {
      got.text += d.toString('latin1');
      for (let i = waiters.length - 1; i >= 0; i--) if (got.text.indexOf(waiters[i][0]) >= 0) { waiters[i][1](); waiters.splice(i, 1); }
    });
    s.on('end', () => resolve(got.text));
    s.on('error', () => resolve(got.text + '(error)'));
    s.on('close', () => resolve(got.text));
  });
}

// The status and the decoded body of each response in `text`.
function responses(text) {
  const list = [];
  let at = 0;
  while (at < text.length) {
    const he = text.indexOf(CRLF + CRLF, at);
    if (he < 0) break;
    const head = text.slice(at, he);
    const status = head.split(' ')[1];
    const lower = head.toLowerCase();
    let body = '';
    at = he + 4;
    const m = lower.indexOf('content-length:');
    if (lower.indexOf('transfer-encoding: chunked') >= 0) {
      for (;;) {
        const nl = text.indexOf(CRLF, at);
        const n = parseInt(text.slice(at, nl), 16);
        at = nl + 2;
        if (!(n > 0)) { at += 2; break; }
        body += text.slice(at, at + n);
        at += n + 2;
      }
    } else if (m >= 0) {
      const n = parseInt(lower.slice(m + 15), 10);
      body = text.slice(at, at + n);
      at += n;
    } else {
      body = text.slice(at);
      at = text.length;
    }
    list.push(status + ' ' + JSON.stringify(body));
  }
  return list.join(' | ');
}

const H = (path, extra) => 'POST ' + path + ' HTTP/1.1' + CRLF + 'Host: x' + CRLF + (extra || '') + CRLF;

async function main() {
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const port = server.address().port;
  const TE = 'Transfer-Encoding: chunked' + CRLF;
  const CLOSE = 'Connection: close' + CRLF;

  T('pieces', responses(await raw(port, [
    H('/echo', TE + CLOSE), '5', 20, CRLF + 'he', 20, 'llo' + CRLF + '1', 20, '0' + CRLF + 'abcdef',
    20, 'ghijklmnop' + CRLF, '0' + CRLF + CRLF])));

  T('first piece before the rest', responses(await raw(port, [
    H('/first', TE + CLOSE), '3' + CRLF + 'one' + CRLF,
    (got) => Promise.race([got.wait('got one;'), sleep(1000)]),
    '3' + CRLF + 'two' + CRLF + '0' + CRLF + CRLF])));

  T('extensions, trailers, then another request', responses(await raw(port, [
    H('/a', TE), '4;name=value' + CRLF + 'abcd' + CRLF + '0' + CRLF + 'X-Trailer: 1' + CRLF + 'X-Other: 2' + CRLF + CRLF,
    H('/b', 'Content-Length: 2' + CRLF + CLOSE) + 'ok'])));

  T('length and coding together', responses(await raw(port, [
    H('/echo', TE + 'Content-Length: 5' + CRLF), '5' + CRLF + 'hello' + CRLF + '0' + CRLF + CRLF])).split(' ')[0]);

  T('a coding that does not end in chunked', responses(await raw(port, [
    H('/echo', 'Transfer-Encoding: chunked, gzip' + CRLF), '5' + CRLF + 'hello' + CRLF + '0' + CRLF + CRLF])).split(' ')[0]);

  T('a size that is not hex', responses(await raw(port, [
    H('/echo', TE), 'zz' + CRLF + 'hello' + CRLF + '0' + CRLF + CRLF])).split(' ')[0]);

  T('a chunk without its CRLF', responses(await raw(port, [
    H('/echo', TE), '5' + CRLF + 'helloXX0' + CRLF + CRLF])).split(' ')[0]);

  const viaClient = await new Promise((resolve) => {
    const req = http.request({ host: '127.0.0.1', port, path: '/client', method: 'POST', agent: false }, (res) => {
      let s = '';
      res.on('data', (d) => { s += d; });
      res.on('end', () => resolve(res.statusCode + ' ' + s));
    });
    req.on('error', (e) => resolve('error ' + e.message));
    req.write('part one, ');
    req.write('part two, ');
    req.end('part three');
  });
  T('the client, in pieces without a length', viaClient);

  // The client reading a chunked reply with trailers, from a server that
  // writes the bytes itself.
  const rawServer = net.createServer((sock) => {
    sock.once('data', () => {
      sock.end('HTTP/1.1 200 OK' + CRLF + 'Transfer-Encoding: chunked' + CRLF + 'Connection: close' + CRLF + CRLF +
               '3' + CRLF + 'abc' + CRLF + '2;x=y' + CRLF + 'de' + CRLF + '0' + CRLF + 'X-T: 1' + CRLF + CRLF);
    });
  });
  await new Promise((r) => rawServer.listen(0, '127.0.0.1', r));
  const trailed = await new Promise((resolve) => {
    http.get({ host: '127.0.0.1', port: rawServer.address().port, path: '/', agent: false }, (res) => {
      let s = '';
      res.on('data', (d) => { s += d; });
      res.on('end', () => resolve(res.statusCode + ' ' + s));
    }).on('error', (e) => resolve('error ' + e.message));
  });
  T('the client, a chunked reply with trailers', trailed);
  rawServer.close();

  server.close();
  await sleep(50);
  for (const line of out) console.log(line);
}

main();

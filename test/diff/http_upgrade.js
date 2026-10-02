// http 'upgrade': the parser hands the socket over, on the server and on the
// client, with whatever followed the head. Plain http first, then the same
// exchange over https, where the socket handed over is a TLSSocket. Every
// step waits for the previous one, so the output order is fixed; no port is
// printed.
const http = require('http');
const https = require('https');
const net = require('net');
const fs = require('fs');
const path = require('path');

const CRLF = '\r\n';
const HEAD_101 = 'HTTP/1.1 101 Switching Protocols' + CRLF + 'Upgrade: echo' + CRLF + 'Connection: Upgrade' + CRLF + CRLF;

function upgradeHeaders() { return { Connection: 'Upgrade', Upgrade: 'echo' }; }

// A server that takes upgrades: answers 101 and then echoes upper-cased
// until the peer ends. The path picks a variation.
function attachUpgrade(server, tag) {
  server.on('upgrade', (req, socket, head) => {
    console.log(tag, 'upgrade:', req.method, req.url, 'flag', req.upgrade, 'hdr', req.headers.upgrade, 'head', JSON.stringify(head.toString()));
    socket.on('error', () => {});
    if (req.url === '/early') {
      socket.write(HEAD_101 + 'EARLY');
    } else {
      socket.write(HEAD_101);
    }
    if (req.url === '/unshift') {
      // the head goes back in front of the stream and comes out as data
      socket.unshift(head);
    }
    if (req.url === '/pause') {
      socket.pause();
      setTimeout(() => socket.resume(), 60);
    }
    let got = '';
    socket.on('data', (d) => {
      got += d.toString();
      socket.write(d.toString().toUpperCase());
    });
    socket.on('end', () => { console.log(tag, 'server saw:', JSON.stringify(got)); socket.end(); });
    socket.on('close', () => { if (req.url === '/dropped') console.log(tag, 'server socket closed'); });
  });
}

// One client upgrade exchange through the http client: sends the given
// messages, prints what comes back, ends.
function clientExchange(mod, tag, port, urlPath, messages, extra) {
  return new Promise((resolve) => {
    const req = mod.request(Object.assign({ host: '127.0.0.1', port, path: urlPath, headers: upgradeHeaders() }, extra || {}));
    let responded = false;
    req.on('response', () => { responded = true; });
    req.on('upgrade', (res, socket, head) => {
      console.log(tag, 'client upgrade:', res.statusCode, res.statusMessage, res.headers.upgrade, 'flag', res.upgrade, 'head', JSON.stringify(head.toString()),
        'encrypted', socket.encrypted === true);
      console.log(tag, 'socket shape:', typeof socket.unshift, typeof socket.cork, typeof socket.uncork, typeof socket.pause, typeof socket.resume,
        socket.writableLength, socket._writableState.length);
      let got = '';
      socket.on('data', (d) => {
        got += d.toString();
        if (got.length >= messages.join('').length) socket.end();
      });
      socket.on('close', () => { console.log(tag, 'client saw:', JSON.stringify(got), 'response event:', responded); resolve(); });
      for (const m of messages) socket.write(m);
    });
    req.end();
  });
}

// A raw client that sends the request head and a payload in one write, so
// the server's head is non-empty; then a second message.
function rawExchange(tag, port, urlPath, payload, more) {
  return new Promise((resolve) => {
    const c = net.connect(port, '127.0.0.1', () => {
      c.write('GET ' + urlPath + ' HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Connection: Upgrade' + CRLF + 'Upgrade: echo' + CRLF + CRLF + payload);
      setTimeout(() => { c.write(more); c.end(); }, 30);
    });
    let got = '';
    c.on('data', (d) => { got += d.toString(); });
    c.on('close', () => {
      const he = got.indexOf(CRLF + CRLF);
      console.log(tag, 'raw client saw:', JSON.stringify(got.slice(0, he)), JSON.stringify(got.slice(he + 4)));
      resolve();
    });
  });
}

// A request with the upgrade headers to a server that has no 'upgrade'
// listener is an ordinary request.
function plainRequest(port) {
  return new Promise((resolve) => {
    const req = http.request({ host: '127.0.0.1', port, path: '/plain', headers: upgradeHeaders() }, (res) => {
      let b = '';
      res.on('data', (d) => { b += d; });
      res.on('end', () => { console.log('plain: response', res.statusCode, res.headers['x-plain'], JSON.stringify(b)); resolve(); });
    });
    req.on('upgrade', () => console.log('plain: upgrade?!'));
    req.end();
  });
}

// A client with no 'upgrade' listener has its socket dropped on a 101: no
// 'response', just 'close'.
function droppedClient(port) {
  return new Promise((resolve) => {
    const req = http.request({ host: '127.0.0.1', port, path: '/dropped', headers: upgradeHeaders() });
    let responded = false;
    req.on('response', () => { responded = true; });
    req.on('error', (e) => console.log('dropped: error', e.code));
    req.on('close', () => { console.log('dropped: client close, response event:', responded); resolve(); });
    req.end();
  });
}

function listen(server) {
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve(server.address().port)));
}

function closeServer(server) {
  return new Promise((resolve) => server.close(() => resolve()));
}

async function main() {
  const plain = http.createServer((req, res) => {
    console.log('plain: request', req.method, req.url, 'flag', req.upgrade, 'hdr', req.headers.upgrade);
    res.writeHead(200, { 'X-Plain': '1' });
    res.end('served');
  });
  const pport = await listen(plain);
  await plainRequest(pport);
  await closeServer(plain);

  const up = http.createServer((req, res) => { res.writeHead(500); res.end('not here'); });
  attachUpgrade(up, 'http');
  const port = await listen(up);
  await clientExchange(http, 'http', port, '/echo', ['ping-1', 'ping-2']);
  await clientExchange(http, 'http', port, '/early', ['x']);
  await rawExchange('http', port, '/head', 'PAYLOAD-WITH-HEAD', 'MORE');
  await rawExchange('http', port, '/unshift', 'AFTER-HEAD', 'MORE');
  await clientExchange(http, 'http', port, '/pause', ['a', 'b', 'c']);
  await droppedClient(port);
  await new Promise((r) => setTimeout(r, 50));
  await closeServer(up);

  const dir = __dirname;
  const sup = https.createServer({
    cert: fs.readFileSync(path.join(dir, 'https_server.cert.pem'), 'utf8'),
    key: fs.readFileSync(path.join(dir, 'https_server.key.pem'), 'utf8'),
  }, (req, res) => { res.writeHead(500); res.end('not here'); });
  attachUpgrade(sup, 'https');
  const sport = await listen(sup);
  await clientExchange(https, 'https', sport, '/echo', ['tls-1', 'tls-2'], { rejectUnauthorized: false });
  await clientExchange(https, 'https', sport, '/early', ['y'], { rejectUnauthorized: false });
  await clientExchange(https, 'https', sport, '/pause', ['d', 'e', 'f'], { rejectUnauthorized: false });
  await closeServer(sup);
  console.log('done');
}

main();

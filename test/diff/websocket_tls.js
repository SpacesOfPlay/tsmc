// The WebSocket global over wss:, both ends in one process: an https server
// with an 'upgrade' listener running a small frame server over the
// TLSSocket it is handed, and the global as the client. The certificate is
// the self-signed fixture, so verification is switched off by the
// environment variable both runtimes read at connect time; node announces
// that switch with a warning on stderr, which is silenced here since the
// harness compares stderr too.
process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';
if (typeof process.removeAllListeners === 'function') process.removeAllListeners('warning');

const https = require('https');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
const CRLF = '\r\n';
const log = (...a) => console.log(...a);

function serverFrame(op, payload, fin) {
  const len = payload.length;
  let hdr;
  if (len >= 65536) { hdr = Buffer.alloc(10); hdr[1] = 127; hdr.writeUInt32BE(0, 2); hdr.writeUInt32BE(len, 6); }
  else if (len >= 126) { hdr = Buffer.alloc(4); hdr[1] = 126; hdr.writeUInt16BE(len, 2); }
  else { hdr = Buffer.alloc(2); hdr[1] = len; }
  hdr[0] = (fin === false ? 0 : 0x80) | op;
  return Buffer.concat([hdr, payload]);
}

function makeParser(onFrame) {
  let buf = Buffer.alloc(0);
  return (chunk) => {
    buf = Buffer.concat([buf, chunk]);
    for (;;) {
      if (buf.length < 2) return;
      const fin = (buf[0] & 0x80) !== 0;
      const op = buf[0] & 0x0f;
      const masked = (buf[1] & 0x80) !== 0;
      let len = buf[1] & 0x7f;
      let hdr = 2;
      if (len === 126) { if (buf.length < 4) return; len = buf.readUInt16BE(2); hdr = 4; }
      else if (len === 127) { if (buf.length < 10) return; len = buf.readUInt32BE(6); hdr = 10; }
      if (masked) hdr += 4;
      if (buf.length < hdr + len) return;
      const payload = Buffer.from(buf.subarray(hdr, hdr + len));
      if (masked) {
        const m = buf.subarray(hdr - 4, hdr);
        for (let i = 0; i < len; i++) payload[i] ^= m[i & 3];
      }
      buf = buf.subarray(hdr + len);
      onFrame({ fin, op, masked, payload });
    }
  };
}

const dir = __dirname;
const server = https.createServer({
  cert: fs.readFileSync(path.join(dir, 'https_server.cert.pem'), 'utf8'),
  key: fs.readFileSync(path.join(dir, 'https_server.key.pem'), 'utf8'),
}, (req, res) => { res.writeHead(404); res.end(); });

server.on('upgrade', (req, socket, head) => {
  log('S handshake:', req.url, 'encrypted', socket.encrypted === true, 'key ok', Buffer.from(req.headers['sec-websocket-key'] || '', 'base64').length === 16);
  socket.on('error', () => {});
  socket.write('HTTP/1.1 101 Switching Protocols' + CRLF + 'Upgrade: websocket' + CRLF + 'Connection: Upgrade' + CRLF +
    'Sec-WebSocket-Accept: ' + crypto.createHash('sha1').update(req.headers['sec-websocket-key'] + GUID).digest('base64') + CRLF + CRLF);
  const parse = makeParser((f) => {
    if (f.op === 1 || f.op === 2) {
      log('S frame:', f.op === 1 ? 'text' : 'binary', f.payload.length <= 40 ? JSON.stringify(f.payload.toString('utf8')) : f.payload.length + ' bytes');
      socket.write(serverFrame(f.op, f.payload));
    } else if (f.op === 8) {
      log('S close frame:', f.payload.readUInt16BE(0), JSON.stringify(f.payload.toString('utf8', 2)));
      socket.write(serverFrame(8, f.payload.subarray(0, 2)));
      socket.end();
    }
  });
  socket.on('data', parse);
  if (head.length) parse(head);
  // a fragmented greeting first
  socket.write(serverFrame(1, Buffer.from('over-'), false));
  socket.write(serverFrame(0, Buffer.from('tls'), true));
});

const nextMessage = (ws) => new Promise((r) => ws.addEventListener('message', r, { once: true }));

server.listen(0, '127.0.0.1', async () => {
  const ws = new WebSocket('wss://127.0.0.1:' + server.address().port + '/secure');
  log('url scheme', ws.url.slice(0, 6), 'state', ws.readyState);
  ws.addEventListener('error', (e) => log('C error:', e.type));
  const closed = new Promise((r) => ws.addEventListener('close', (e) => { log('C close:', e.code, JSON.stringify(e.reason), 'clean', e.wasClean, 'state', ws.readyState); r(); }));
  const first = nextMessage(ws);
  await new Promise((r) => ws.addEventListener('open', r));
  log('C open: state', ws.readyState);
  let e = await first;
  log('C message:', JSON.stringify(e.data));
  let p = nextMessage(ws);
  ws.send('hello over tls');
  e = await p;
  log('C echo:', JSON.stringify(e.data));
  ws.binaryType = 'arraybuffer';
  p = nextMessage(ws);
  const big = new Uint8Array(70000);
  big[69999] = 3;
  ws.send(big);
  e = await p;
  log('C 70000 binary:', e.data instanceof ArrayBuffer, e.data.byteLength, new Uint8Array(e.data)[69999]);
  p = nextMessage(ws);
  ws.send('z'.repeat(200000));
  e = await p;
  log('C 200000 text:', e.data.length, e.data[0]);
  ws.close(1000, 'done');
  await closed;
  server.close();
  log('done');
});

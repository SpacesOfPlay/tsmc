// The WebSocket global. Node core has no server, so this test carries a
// small frame server on an http 'upgrade' listener and runs the same script
// on both runtimes: handshake, text and binary in both binaryType modes,
// 16-bit and 64-bit lengths, fragmentation, ping/pong, both directions of
// the close handshake, and the failure paths (bad accept key, non-101,
// invalid UTF-8, a dropped connection, a subprotocol not offered). Every
// step waits for the previous one; nothing prints a port.
//
// Not asserted, because node 22 differs from the standard there and this
// runtime follows the standard: after a failed handshake node fires 'error'
// and leaves the socket CONNECTING with no 'close'; here 'close' follows
// with 1006 and the state is CLOSED. So a handshake failure is checked by
// its 'error' event alone, and the readyState is not printed from inside an
// 'error' handler.
const http = require('http');
const crypto = require('crypto');

const GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
const CRLF = '\r\n';
const log = (...a) => console.log(...a);

// --- the frame server -------------------------------------------------------

function serverFrame(op, payload, fin) {
  const len = payload.length;
  let hdr;
  if (len >= 65536) { hdr = Buffer.alloc(10); hdr[1] = 127; hdr.writeUInt32BE(0, 2); hdr.writeUInt32BE(len, 6); }
  else if (len >= 126) { hdr = Buffer.alloc(4); hdr[1] = 126; hdr.writeUInt16BE(len, 2); }
  else { hdr = Buffer.alloc(2); hdr[1] = len; }
  hdr[0] = (fin === false ? 0 : 0x80) | op;
  return Buffer.concat([hdr, payload]);
}

function closeFrame(code, reason) {
  const r = Buffer.from(reason || '', 'utf8');
  const b = Buffer.alloc(2 + r.length);
  b.writeUInt16BE(code, 0);
  r.copy(b, 2);
  return serverFrame(8, b);
}

// Parses masked client frames out of a running byte stream.
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

function acceptKey(key) {
  return crypto.createHash('sha1').update(key + GUID).digest('base64');
}

function handshakeReply(req, extra) {
  return 'HTTP/1.1 101 Switching Protocols' + CRLF + 'Upgrade: websocket' + CRLF + 'Connection: Upgrade' + CRLF +
    'Sec-WebSocket-Accept: ' + acceptKey(req.headers['sec-websocket-key']) + CRLF + (extra || '') + CRLF;
}

const server = http.createServer((req, res) => { res.writeHead(404); res.end(); });
server.on('upgrade', (req, socket, head) => {
  const h = req.headers;
  const key = h['sec-websocket-key'] || '';
  const mode = req.url;
  socket.on('error', () => {});
  // a client that gives up while connecting may or may not have sent its
  // request by then, so that one is not logged
  if (mode === '/early') { socket.destroy(); return; }
  log('S handshake:', mode, String(h.upgrade).toLowerCase(), String(h.connection).toLowerCase().indexOf('upgrade') >= 0,
    h['sec-websocket-version'], 'key ok:', Buffer.from(key, 'base64').length === 16, 'protocol:', JSON.stringify(h['sec-websocket-protocol']));
  const send = (b) => socket.write(b);
  const failing = mode === '/badutf8' || mode === '/badframe';

  // the handshake failures: the reply is wrong, and the socket goes away
  // shortly after, since not every client closes it
  const dropSoon = () => setTimeout(() => socket.destroy(), 60);
  if (mode === '/deny') { socket.write('HTTP/1.1 200 OK' + CRLF + 'Content-Length: 2' + CRLF + 'Connection: close' + CRLF + CRLF + 'no'); socket.end(); return; }
  if (mode === '/badaccept') { socket.write(handshakeReply({ headers: { 'sec-websocket-key': 'AAAAAAAAAAAAAAAAAAAAAA==' } })); dropSoon(); return; }
  if (mode === '/proto-bad') { socket.write(handshakeReply(req, 'Sec-WebSocket-Protocol: nope' + CRLF)); dropSoon(); return; }
  if (mode === '/proto-none') { socket.write(handshakeReply(req)); dropSoon(); return; }

  socket.write(handshakeReply(req, mode === '/proto' ? 'Sec-WebSocket-Protocol: chat' + CRLF : ''));
  let closedByUs = false;
  const parse = makeParser((f) => {
    if (f.op === 1 || f.op === 2) {
      const shown = f.payload.length <= 40 ? (f.op === 1 ? JSON.stringify(f.payload.toString('utf8')) : Array.from(f.payload).join(',')) : f.payload.length + ' bytes';
      log('S frame:', f.op === 1 ? 'text' : 'binary', 'fin', f.fin, 'masked', f.masked, shown);
      send(serverFrame(f.op, f.payload));
    } else if (f.op === 10) {
      log('S pong:', JSON.stringify(f.payload.toString('utf8')));
      // the client answered the ping: now the server says goodbye
      send(closeFrame(4000, 'srv'));
      closedByUs = true;
    } else if (f.op === 8) {
      const code = f.payload.length >= 2 ? f.payload.readUInt16BE(0) : 1005;
      // whether a client announces a protocol error with a close frame
      // before leaving is its own business, so those are not logged
      if (!failing) log('S close frame:', code, JSON.stringify(f.payload.toString('utf8', 2)));
      if (!closedByUs) send(closeFrame(code === 1005 ? 1000 : code, f.payload.toString('utf8', 2)));
      socket.end();
    }
  });
  socket.on('data', parse);
  if (head.length) parse(head);

  if (mode === '/frag') {
    send(serverFrame(1, Buffer.from('frag-'), false));
    send(serverFrame(0, Buffer.from('ment-'), false));
    send(serverFrame(0, Buffer.from('ed'), true));
    send(serverFrame(9, Buffer.from('hi')));
  } else if (mode === '/drop') {
    send(serverFrame(1, Buffer.from('bye')));
    setTimeout(() => socket.destroy(), 30);
  } else if (mode === '/badutf8') {
    send(serverFrame(1, Buffer.from([0x68, 0xff, 0xfe])));
  } else if (mode === '/badframe') {
    send(Buffer.from([0x80 | 0x40 | 1, 1, 65]));   // a reserved bit set
  }
});

// --- the client side ----------------------------------------------------------

function watch(ws, tag, handshakeOnly) {
  const seen = [];
  for (const t of handshakeOnly ? ['open', 'error'] : ['open', 'error', 'close']) {
    ws.addEventListener(t, (e) => {
      seen.push(t);
      if (t === 'close') log(tag, 'close:', e.code, JSON.stringify(e.reason), 'clean', e.wasClean, 'ctor', e.constructor.name, 'state', ws.readyState, 'events', seen.join('>'));
      else if (t === 'error') log(tag, 'error:', e.type, 'ctor', e.constructor.name, 'message is string', typeof e.message === 'string');
      else log(tag, 'open: state', ws.readyState, 'protocol', JSON.stringify(ws.protocol), 'extensions', JSON.stringify(ws.extensions));
    }, { once: true });
  }
  return seen;
}
const errored = (ws) => new Promise((r) => ws.addEventListener('error', r, { once: true }));

const closed = (ws) => new Promise((r) => ws.addEventListener('close', r));
const opened = (ws) => new Promise((r) => ws.addEventListener('open', r));
const nextMessage = (ws) => new Promise((r) => ws.addEventListener('message', r, { once: true }));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function main() {
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const port = server.address().port;
  const base = 'ws://127.0.0.1:' + port;

  log('--- statics');
  log(WebSocket.CONNECTING, WebSocket.OPEN, WebSocket.CLOSING, WebSocket.CLOSED, WebSocket.prototype.OPEN, Object.prototype.toString.call(WebSocket.prototype));
  log('MessageEvent', typeof MessageEvent, 'Blob', typeof Blob, 'CloseEvent global', typeof CloseEvent);

  log('--- constructor errors');
  for (const [u, p] of [['nope', undefined], ['ftp://x/', undefined], [base + '/x#frag', undefined], [base + '/x', ['a', 'a']], [base + '/x', ['bad token']]]) {
    try { const w = new WebSocket(u, p); w.close(); log('no error?!'); } catch (e) { log(e.name, e.constructor.name); }
  }

  log('--- echo');
  {
    const ws = new WebSocket('http://127.0.0.1:' + port + '/echo');
    log('url scheme', ws.url.slice(0, 5), 'state', ws.readyState, 'binaryType', ws.binaryType, 'bufferedAmount', ws.bufferedAmount);
    try { ws.send('early'); } catch (e) { log('send while connecting:', e.name); }
    watch(ws, 'C');
    await opened(ws);
    let p = nextMessage(ws);
    ws.send('hello');
    let e = await p;
    log('C message:', e.type, e.constructor.name, typeof e.data, JSON.stringify(e.data), 'origin scheme', e.origin.slice(0, 5), 'target ok', e.target === ws);
    p = nextMessage(ws);
    ws.send(new Uint8Array([1, 2, 3]));
    e = await p;
    log('C binary as blob:', e.data instanceof Blob, e.data.size, JSON.stringify(e.data.type), Array.from(new Uint8Array(await e.data.arrayBuffer())).join(','), await e.data.slice(1).text() === String.fromCharCode(2, 3));
    ws.binaryType = 'nonsense';
    ws.binaryType = 'arraybuffer';
    log('binaryType now', ws.binaryType);
    p = nextMessage(ws);
    ws.send(Buffer.from([4, 5]));
    e = await p;
    log('C binary as arraybuffer:', e.data instanceof ArrayBuffer, e.data.byteLength, Array.from(new Uint8Array(e.data)).join(','));
    p = nextMessage(ws);
    ws.send('x'.repeat(70000));
    e = await p;
    log('C 70000 text:', e.data.length, e.data[69999]);
    p = nextMessage(ws);
    const big = new Uint8Array(200000);
    big[199999] = 9;
    ws.send(big.buffer);
    e = await p;
    log('C 200000 binary:', e.data.byteLength, new Uint8Array(e.data)[199999]);
    p = nextMessage(ws);
    ws.send(new Blob(['from-', 'blob']));
    e = await p;
    log('C blob sent as binary:', e.data instanceof ArrayBuffer, Buffer.from(e.data).toString());
    p = nextMessage(ws);
    ws.send(12345);
    e = await p;
    log('C number sent as text:', typeof e.data, e.data);
    await sleep(30);
    log('bufferedAmount after flush', ws.bufferedAmount);
    for (const [code, reason] of [[1234, undefined], [1000, 'x'.repeat(124)], [undefined, 'reason without code']]) {
      try { ws.close(code, reason); log('no error?!'); } catch (err) { log('close arg error:', err.name); }
    }
    const done = closed(ws);
    ws.close(1000, 'bye');
    log('after close(): state', ws.readyState);
    ws.send('late');
    log('bufferedAmount after a late send', ws.bufferedAmount);
    await done;
    ws.close();
    log('state', ws.readyState);
  }

  log('--- fragments, ping, server-initiated close, subprotocol');
  {
    const ws = new WebSocket(base + '/frag');
    watch(ws, 'C');
    const m = nextMessage(ws);
    await opened(ws);
    const e = await m;
    log('C fragmented message:', JSON.stringify(e.data));
    await closed(ws);
  }
  {
    const ws = new WebSocket(base + '/proto', ['chat', 'other']);
    watch(ws, 'C');
    await opened(ws);
    log('C protocol', JSON.stringify(ws.protocol));
    const done = closed(ws);
    ws.close();
    await done;
  }

  log('--- handshake failures');
  for (const path of ['/proto-bad', '/proto-none', '/badaccept', '/deny']) {
    const ws = new WebSocket(base + path, path === '/proto-bad' || path === '/proto-none' ? ['chat'] : undefined);
    watch(ws, 'C' + path, true);
    await errored(ws);
    await sleep(80);
  }
  {
    const ws = new WebSocket(base + '/early');
    watch(ws, 'C early-close', true);
    ws.close();
    await errored(ws);
    await sleep(80);
  }

  log('--- failures after the handshake');
  for (const path of ['/badutf8', '/badframe', '/drop']) {
    const ws = new WebSocket(base + path);
    ws.addEventListener('message', (e) => log('C message before failure:', JSON.stringify(e.data)));
    watch(ws, 'C' + path);
    await closed(ws);
  }

  log('--- handler properties');
  {
    const ws = new WebSocket(base + '/echo');
    let calls = 0;
    const f1 = () => { calls += 1; };
    ws.onopen = f1;
    ws.onopen = f1;
    log('onopen is', ws.onopen === f1, 'onmessage', ws.onmessage);
    ws.onopen = () => { calls += 10; ws.onmessage = (e) => { log('onmessage data', e.data, 'calls', calls); ws.close(1000); }; ws.send('via handler'); };
    ws.onclose = (e) => log('onclose', e.code, e.wasClean);
    await closed(ws);
  }

  server.close();
  log('done');
}

main();

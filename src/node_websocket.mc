// node_websocket.mc -- the `WebSocket` global: the WHATWG client.
//
// Internal module (require('_websocket')) behind the lazy `WebSocket`
// global, so a script that never names it pays nothing. The handshake is an
// `http`/`https` request that ends in 'upgrade'; from there the socket
// carries RFC 6455 frames. Masking and UTF-8 checks are the two natives that
// `bufferutil` and `utf-8-validate` wrap, so no byte is walked in JS.
//
// Kept lean on purpose: one Buffer per outgoing frame, one write; incoming
// chunks are consumed by slicing, joined only when a frame straddles them.
//
// Embedded JS: no backslash escapes (minc processes them in string literals)
// and no double quotes.

str node_websocket_source() {
    return "'use strict';
const webevents = require('_webevents');
const EventTarget = webevents.EventTarget;
const Event = webevents.Event;
const MessageEvent = webevents.MessageEvent;
const CloseEvent = webevents.CloseEvent;
const ErrorEvent = webevents.ErrorEvent;
const DOMException = webevents.DOMException;
const Blob = require('_webapi').Blob;
const crypto = require('crypto');

const GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
const CONNECTING = 0;
const OPEN = 1;
const CLOSING = 2;
const CLOSED = 3;
const OP_CONT = 0;
const OP_TEXT = 1;
const OP_BIN = 2;
const OP_CLOSE = 8;
const OP_PING = 9;
const OP_PONG = 10;
const EMPTY = Buffer.alloc(0);

function hidden(obj, key, value) {
  Object.defineProperty(obj, key, { value: value, writable: true, enumerable: false, configurable: true });
}

// A subprotocol name is an HTTP token: visible ASCII minus the separators.
function isToken(s) {
  if (s.length === 0) return false;
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c <= 32 || c >= 127) return false;
    if (c === 40 || c === 41 || c === 60 || c === 62 || c === 64 || c === 44 || c === 59 ||
        c === 58 || c === 92 || c === 34 || c === 47 || c === 91 || c === 93 || c === 63 ||
        c === 61 || c === 123 || c === 125) return false;
  }
  return true;
}

// One outgoing frame: header, mask key and masked payload in a single
// Buffer, so a message is one write.
function frame(opcode, payload) {
  const len = payload.length;
  let hdr = 2;
  if (len >= 65536) hdr += 8;
  else if (len >= 126) hdr += 2;
  const out = Buffer.allocUnsafe(hdr + 4 + len);
  out[0] = 0x80 | opcode;
  if (len >= 65536) {
    out[1] = 0x80 | 127;
    out.writeUInt32BE(0, 2);
    out.writeUInt32BE(len, 6);
  } else if (len >= 126) {
    out[1] = 0x80 | 126;
    out.writeUInt16BE(len, 2);
  } else {
    out[1] = 0x80 | len;
  }
  __buf_mask_frame(payload, out, hdr, len);
  return out;
}

// Everything received and not yet parsed, as one chunk: what a frame that
// straddles chunks needs. Rare with small frames; once per message with
// large ones.
function join(ws) {
  if (ws._off > 0) ws._chunks[0] = ws._chunks[0].subarray(ws._off);
  const c = ws._chunks.length === 1 ? ws._chunks[0] : Buffer.concat(ws._chunks, ws._avail);
  ws._chunks = [c];
  ws._off = 0;
  return c;
}

function validCloseCode(code) {
  if (code >= 3000 && code <= 4999) return true;
  return code === 1000 || code === 1001 || code === 1002 || code === 1003 ||
    (code >= 1007 && code <= 1011);
}

class WebSocket extends EventTarget {
  constructor(url, protocols) {
    super();
    let u;
    try { u = new URL(String(url)); } catch (e) { u = null; }
    if (u === null) throw new DOMException('The URL ' + String(url) + ' is invalid.', 'SyntaxError');
    // http and https name the same endpoints
    if (u.protocol === 'http:' || u.protocol === 'https:') u = new URL('ws' + u.href.slice(4));
    if (u.protocol !== 'ws:' && u.protocol !== 'wss:') {
      throw new DOMException('Expected a ws: or wss: protocol, got ' + u.protocol, 'SyntaxError');
    }
    if (u.hash !== '' || u.href.charCodeAt(u.href.length - 1) === 35) {
      throw new DOMException('Got fragment', 'SyntaxError');
    }
    let list = [];
    if (protocols !== undefined) {
      if (typeof protocols === 'string') list = [protocols];
      else if (Array.isArray(protocols)) list = protocols.map(String);
      else list = [String(protocols)];
      for (let i = 0; i < list.length; i++) {
        if (!isToken(list[i]) || list.indexOf(list[i]) !== i) {
          throw new DOMException('Invalid Sec-WebSocket-Protocol value', 'SyntaxError');
        }
      }
    }
    hidden(this, '_url', u.href);
    hidden(this, '_origin', u.origin);
    hidden(this, '_protocols', list);
    hidden(this, '_readyState', CONNECTING);
    hidden(this, '_binaryType', 'blob');
    hidden(this, '_bufferedAmount', 0);
    hidden(this, '_protocol', '');
    hidden(this, '_extensions', '');
    hidden(this, '_socket', null);
    hidden(this, '_req', null);
    hidden(this, '_chunks', []);
    hidden(this, '_off', 0);
    hidden(this, '_avail', 0);
    hidden(this, '_frags', []);
    hidden(this, '_fragLen', 0);
    hidden(this, '_fragOp', -1);
    hidden(this, '_sentClose', false);
    hidden(this, '_receivedClose', false);
    hidden(this, '_closeCode', 1005);
    hidden(this, '_closeReason', '');
    hidden(this, '_failed', false);
    hidden(this, '_failMessage', '');
    hidden(this, '_finished', false);
    hidden(this, '_h', { open: null, message: null, error: null, close: null });
    connect(this, u);
  }

  get url() { return this._url; }
  get readyState() { return this._readyState; }
  get bufferedAmount() {
    const queued = this._socket !== null && this._readyState === OPEN ? this._socket.writableLength : 0;
    return queued + this._bufferedAmount;
  }
  get extensions() { return this._extensions; }
  get protocol() { return this._protocol; }
  get binaryType() { return this._binaryType; }
  set binaryType(v) { if (v === 'blob' || v === 'arraybuffer') this._binaryType = v; }

  get onopen() { return this._h.open; }
  set onopen(f) { setHandler(this, 'open', f); }
  get onmessage() { return this._h.message; }
  set onmessage(f) { setHandler(this, 'message', f); }
  get onerror() { return this._h.error; }
  set onerror(f) { setHandler(this, 'error', f); }
  get onclose() { return this._h.close; }
  set onclose(f) { setHandler(this, 'close', f); }

  send(data) {
    if (this._readyState === CONNECTING) {
      throw new DOMException('Failed to execute ' + q('send') + ' on ' + q('WebSocket') + ': Still in CONNECTING state.', 'InvalidStateError');
    }
    if (data instanceof Blob) {
      const size = data.size;
      this._bufferedAmount += size;
      data.arrayBuffer().then((ab) => {
        this._bufferedAmount -= size;
        if (this._readyState === OPEN) sendFrame(this, OP_BIN, Buffer.from(ab));
      });
      return;
    }
    let op = OP_TEXT;
    let buf;
    if (typeof data === 'string') buf = Buffer.from(data, 'utf8');
    else if (data instanceof Uint8Array) { buf = data; op = OP_BIN; }
    else if (data instanceof ArrayBuffer) { buf = Buffer.from(data); op = OP_BIN; }
    else if (ArrayBuffer.isView(data)) { buf = Buffer.from(data.buffer, data.byteOffset, data.byteLength); op = OP_BIN; }
    else buf = Buffer.from(String(data), 'utf8');
    // closing or closed: nothing to send it on
    if (this._readyState !== OPEN) return;
    sendFrame(this, op, buf);
  }

  close(code, reason) {
    let body = EMPTY;
    if (code !== undefined) {
      code = Number(code);
      if (code !== 1000 && !(code >= 3000 && code <= 4999)) {
        throw new DOMException('invalid code', 'InvalidAccessError');
      }
    }
    if (reason !== undefined) {
      const rb = Buffer.from(String(reason), 'utf8');
      if (rb.length > 123) throw new DOMException('Reason must be less than 123 bytes; received ' + rb.length, 'SyntaxError');
      // a reason travels only with a code; without one the frame is empty
      if (code !== undefined) {
        body = Buffer.allocUnsafe(2 + rb.length);
        body.writeUInt16BE(code, 0);
        rb.copy(body, 2);
      }
    } else if (code !== undefined) {
      body = Buffer.allocUnsafe(2);
      body.writeUInt16BE(code, 0);
    }
    if (this._readyState === CLOSING || this._readyState === CLOSED) return;
    if (this._readyState === CONNECTING) {
      // the connection is failed: no handshake to finish
      this._readyState = CLOSING;
      this._failed = true;
      this._failMessage = 'WebSocket was closed before the connection was established';
      if (this._req) this._req.destroy();
      // events never fire from inside the call that causes them
      queueMicrotask(() => finish(this));
      return;
    }
    this._readyState = CLOSING;
    this._sentClose = true;
    this._socket.write(frame(OP_CLOSE, body));
    // the peer answers with its own close frame and then closes; the socket
    // ending is what fires 'close' here
  }
}

const q = (s) => String.fromCharCode(39) + s + String.fromCharCode(39);

function setHandler(ws, type, f) {
  const old = ws._h[type];
  if (old) ws.removeEventListener(type, old);
  ws._h[type] = typeof f === 'function' ? f : null;
  if (ws._h[type]) ws.addEventListener(type, ws._h[type]);
}

for (const k of ['CONNECTING', 'OPEN', 'CLOSING', 'CLOSED']) {
  const v = k === 'CONNECTING' ? 0 : k === 'OPEN' ? 1 : k === 'CLOSING' ? 2 : 3;
  Object.defineProperty(WebSocket, k, { value: v, enumerable: true });
  Object.defineProperty(WebSocket.prototype, k, { value: v, enumerable: true });
}
Object.defineProperty(WebSocket.prototype, Symbol.toStringTag, { value: 'WebSocket', configurable: true });

function sendFrame(ws, op, buf) {
  ws._socket.write(frame(op, buf));
}

// The handshake: a GET that asks to upgrade, whose 101 hands the socket over.
function connect(ws, u) {
  const secure = u.protocol === 'wss:';
  const mod = secure ? require('https') : require('http');
  const key = crypto.randomBytes(16).toString('base64');
  const headers = {
    Upgrade: 'websocket',
    Connection: 'Upgrade',
    'Sec-WebSocket-Key': key,
    'Sec-WebSocket-Version': '13',
  };
  if (ws._protocols.length > 0) headers['Sec-WebSocket-Protocol'] = ws._protocols.join(', ');
  let host = u.hostname;
  if (host.charCodeAt(0) === 91) host = host.slice(1, -1);
  const req = mod.request({
    host: host, port: u.port === '' ? (secure ? 443 : 80) : Number(u.port),
    path: u.pathname + u.search, method: 'GET', headers: headers,
    servername: u.hostname,
  });
  ws._req = req;
  req.on('upgrade', (res, socket, head) => {
    ws._req = null;
    const why = checkHandshake(ws, key, res);
    if (why !== null) {
      socket.destroy();
      fail(ws, why);
      return;
    }
    attach(ws, socket, head);
  });
  req.on('response', (res) => {
    ws._req = null;
    res.resume();
    req.destroy();
    fail(ws, 'Received network error or non-101 status code.');
  });
  req.on('error', () => {
    if (ws._req === null) return;
    ws._req = null;
    fail(ws, 'Received network error or non-101 status code.');
  });
  req.end();
}

function checkHandshake(ws, key, res) {
  if (res.statusCode !== 101) return 'Received network error or non-101 status code.';
  if (String(res.headers['upgrade'] || '').toLowerCase() !== 'websocket') return 'Expected Upgrade: websocket';
  if (String(res.headers['connection'] || '').toLowerCase().indexOf('upgrade') < 0) return 'Expected Connection: Upgrade';
  const expect = crypto.createHash('sha1').update(key + GUID).digest('base64');
  if (res.headers['sec-websocket-accept'] !== expect) return 'Invalid Sec-WebSocket-Accept header';
  if (res.headers['sec-websocket-extensions'] !== undefined) return 'Received unexpected Sec-WebSocket-Extensions';
  const proto = res.headers['sec-websocket-protocol'];
  if (proto !== undefined) {
    if (ws._protocols.indexOf(proto) < 0) return 'Server selected a subprotocol that was not offered';
    ws._protocol = proto;
  } else if (ws._protocols.length > 0) {
    return 'Server did not select a subprotocol';
  }
  return null;
}

function attach(ws, socket, head) {
  ws._socket = socket;
  socket.setNoDelay(true);
  socket.on('error', () => {});
  socket.on('data', (d) => { ws._chunks.push(d); ws._avail += d.length; parse(ws); });
  socket.on('close', () => finish(ws));
  ws._readyState = OPEN;
  ws.dispatchEvent(new Event('open'));
  if (head.length > 0) { ws._chunks.push(head); ws._avail += head.length; parse(ws); }
}

// A protocol violation fails the connection: a close frame with the reason
// goes out, the socket is shut once it has left, and 'error' precedes
// 'close'.
function fail(ws, message, code) {
  if (ws._failed || ws._readyState === CLOSED) return;
  ws._failed = true;
  ws._failMessage = message;
  ws._readyState = CLOSING;
  const s = ws._socket;
  if (s === null) { finish(ws); return; }
  if (!ws._sentClose && code !== undefined) {
    ws._sentClose = true;
    const body = Buffer.allocUnsafe(2);
    body.writeUInt16BE(code, 0);
    s.write(frame(OP_CLOSE, body));
  }
  s.once('finish', () => s.destroy());
  s.end();
}

function finish(ws) {
  if (ws._finished) return;
  ws._finished = true;
  ws._readyState = CLOSED;
  const clean = ws._sentClose && ws._receivedClose && !ws._failed;
  if (ws._failed) {
    ws.dispatchEvent(new ErrorEvent('error', { message: ws._failMessage, error: new Error(ws._failMessage) }));
  }
  ws.dispatchEvent(new CloseEvent('close', {
    wasClean: clean,
    code: ws._receivedClose ? ws._closeCode : 1006,
    reason: ws._receivedClose ? ws._closeReason : '',
  }));
}

function parse(ws) {
  while (!ws._failed && ws._readyState !== CLOSED && ws._avail >= 2) {
    let c = ws._chunks[0];
    let off = ws._off;
    // the header, decoded and checked natively: a packed number, or a
    // negative code (see __ws_head)
    let code = __ws_head(c, off, ws._fragOp);
    if (code < 0 && code > -100) {
      // the header straddles chunks
      if (ws._avail < -code) return;
      c = join(ws);
      off = 0;
      code = __ws_head(c, off, ws._fragOp);
    }
    if (code < 0) { failHead(ws, code); return; }
    const meta = code & 255;
    const op = meta & 15;
    const hcode = meta >> 5;
    const hdr = hcode === 0 ? 2 : (hcode === 1 ? 4 : 10);
    const len = (code - meta) / 256;
    if (ws._avail < hdr + len) return;
    if (c.length - off < hdr + len) { c = join(ws); off = 0; }
    const start = off + hdr;
    const end = start + len;
    ws._avail -= hdr + len;
    if (end === c.length) { ws._chunks.shift(); ws._off = 0; }
    else ws._off = end;
    if (op >= 8) control(ws, op, c.subarray(start, end));
    else if ((code & 16) !== 0 && ws._fragOp === -1) message(ws, op, c, start, end);
    else fragment(ws, op, (code & 16) !== 0, c.subarray(start, end));
  }
}

function failHead(ws, code) {
  if (code === -100) fail(ws, 'Received a frame with reserved bits set', 1002);
  else if (code === -101) fail(ws, 'Received a masked frame from the server', 1002);
  else if (code === -103) fail(ws, 'Received a frame that is too large', 1009);
  else if (code === -104) fail(ws, 'Received a continuation frame with no message', 1002);
  else if (code === -105) fail(ws, 'Received a new message inside a fragmented one', 1002);
  else fail(ws, 'Received an invalid frame', 1002);
}

// A whole message, delivered straight out of the chunk it arrived in: text
// is checked and decoded in place, binary is copied once into what the
// binaryType asks for.
function message(ws, op, c, start, end) {
  if (ws._receivedClose) return;
  let value;
  if (op === OP_TEXT) {
    if (!__utf8_valid(c, start, end)) { fail(ws, 'Received invalid UTF-8 in a text frame', 1007); return; }
    value = c.toString('utf8', start, end);
  } else if (ws._binaryType === 'arraybuffer') {
    const ab = new ArrayBuffer(end - start);
    if (end > start) c.copy(new Uint8Array(ab), 0, start, end);
    value = ab;
  } else {
    value = new Blob([c.subarray(start, end)]);
  }
  const ev = new MessageEvent('message');
  ev.data = value;
  ev.origin = ws._origin;
  ws.dispatchEvent(ev);
}

function fragment(ws, op, fin, payload) {
  if (op !== OP_CONT) ws._fragOp = op;
  ws._frags.push(payload);
  ws._fragLen += payload.length;
  if (!fin) return;
  const whole = ws._frags.length === 1 ? ws._frags[0] : Buffer.concat(ws._frags, ws._fragLen);
  const mop = ws._fragOp;
  ws._frags = [];
  ws._fragLen = 0;
  ws._fragOp = -1;
  message(ws, mop, whole, 0, whole.length);
}

function control(ws, op, payload) {
  if (op === OP_PING) {
    if (ws._readyState === OPEN) ws._socket.write(frame(OP_PONG, payload));
    return;
  }
  if (op === OP_PONG) return;
  // a close frame: code and reason, then ours in return, then the socket
  let code = 1005;
  let reason = '';
  if (payload.length === 1) { fail(ws, 'Received a close frame with a one-byte body', 1002); return; }
  if (payload.length >= 2) {
    code = payload.readUInt16BE(0);
    if (!validCloseCode(code)) { fail(ws, 'Received an invalid close code', 1002); return; }
    const rb = payload.subarray(2);
    if (!__utf8_valid(rb)) { fail(ws, 'Received an invalid close reason', 1007); return; }
    reason = rb.toString('utf8');
  }
  ws._receivedClose = true;
  ws._closeCode = code;
  ws._closeReason = reason;
  ws._readyState = CLOSING;
  if (!ws._sentClose) {
    ws._sentClose = true;
    ws._socket.write(frame(OP_CLOSE, payload.length >= 2 ? payload.subarray(0, 2) : EMPTY));
  }
  ws._socket.end();
}

module.exports = { WebSocket: WebSocket };
";
}

// node_http.mc -- the `http` built-in module (HTTP/1.1, plaintext).
//
// Client + server on top of `net` + EventEmitter. Pure JS. The embedded
// source avoids backslash escapes (minc processes them in string
// literals), so CR/LF come from String.fromCharCode. See
// doc/PLAN_M33_http.md.

str node_http_source() {
    return "'use strict';
const net = require('net');
const EventEmitter = require('events');

const CR = 13;
const LF = 10;
const CRLF = String.fromCharCode(CR, LF);

const STATUS = {
  100: 'Continue', 101: 'Switching Protocols', 102: 'Processing',
  103: 'Early Hints',
  200: 'OK', 201: 'Created', 202: 'Accepted',
  203: 'Non-Authoritative Information', 204: 'No Content',
  205: 'Reset Content', 206: 'Partial Content', 207: 'Multi-Status',
  208: 'Already Reported', 226: 'IM Used',
  300: 'Multiple Choices', 301: 'Moved Permanently', 302: 'Found',
  303: 'See Other', 304: 'Not Modified', 305: 'Use Proxy',
  307: 'Temporary Redirect', 308: 'Permanent Redirect',
  400: 'Bad Request', 401: 'Unauthorized', 402: 'Payment Required',
  403: 'Forbidden', 404: 'Not Found', 405: 'Method Not Allowed',
  406: 'Not Acceptable', 407: 'Proxy Authentication Required',
  408: 'Request Timeout', 409: 'Conflict', 410: 'Gone',
  411: 'Length Required', 412: 'Precondition Failed',
  413: 'Payload Too Large', 414: 'URI Too Long',
  415: 'Unsupported Media Type', 416: 'Range Not Satisfiable',
  417: 'Expectation Failed', 421: 'Misdirected Request',
  422: 'Unprocessable Entity', 423: 'Locked', 424: 'Failed Dependency',
  425: 'Too Early', 426: 'Upgrade Required', 428: 'Precondition Required',
  429: 'Too Many Requests', 431: 'Request Header Fields Too Large',
  451: 'Unavailable For Legal Reasons',
  500: 'Internal Server Error', 501: 'Not Implemented',
  502: 'Bad Gateway', 503: 'Service Unavailable', 504: 'Gateway Timeout',
  505: 'HTTP Version Not Supported', 506: 'Variant Also Negotiates',
  507: 'Insufficient Storage', 508: 'Loop Detected',
  509: 'Bandwidth Limit Exceeded', 510: 'Not Extended',
  511: 'Network Authentication Required',
};

// Set apart from the table above: the reason phrase carries an apostrophe,
// and this source is embedded in a minc string literal that takes neither a
// double quote nor a backslash escape.
STATUS[418] = 'I' + String.fromCharCode(39) + 'm a Teapot';

function statusText(code) { return STATUS[code] || 'Unknown'; }

function canon(name) {
  const parts = name.split('-');
  for (let i = 0; i < parts.length; i++) {
    const p = parts[i];
    if (p.length) parts[i] = p[0].toUpperCase() + p.slice(1);
  }
  return parts.join('-');
}

function findHeaderEnd(buf) {
  for (let i = 0; i + 3 < buf.length; i++) {
    if (buf[i] === CR && buf[i + 1] === LF && buf[i + 2] === CR && buf[i + 3] === LF) return i;
  }
  return -1;
}

function findLine(buf) {
  for (let i = 0; i + 1 < buf.length; i++) {
    if (buf[i] === CR && buf[i + 1] === LF) return i;
  }
  return -1;
}

function parseHeaders(text) {
  const headers = {};
  const lines = text.split(CRLF);
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (!line) continue;
    const idx = line.indexOf(':');
    if (idx < 0) continue;
    const k = line.slice(0, idx).trim().toLowerCase();
    const v = line.slice(idx + 1).trim();
    // Set-Cookie is the one header that must not be folded: each cookie is a
    // separate value, and joining them with a comma makes them unparseable,
    // since a cookie may carry a comma of its own in an Expires date.
    if (k === 'set-cookie') {
      if (headers[k] === undefined) headers[k] = [v];
      else headers[k].push(v);
    } else if (headers[k] !== undefined) headers[k] = headers[k] + ', ' + v;
    else headers[k] = v;
  }
  return headers;
}

function toBuf(chunk, enc) {
  if (chunk == null) return Buffer.alloc(0);
  if (typeof chunk === 'string') return Buffer.from(chunk, enc || 'utf8');
  return chunk;
}

class IncomingMessage extends EventEmitter {
  constructor() {
    super();
    this.headers = {};
    this.method = null;
    this.url = null;
    this.statusCode = 0;
    this.statusMessage = '';
    this.httpVersion = '1.1';
    this.complete = false;
    this.upgrade = false;
    this._encoding = null;
  }
  setEncoding(enc) { this._encoding = enc; return this; }
  pause() { return this; }
  resume() { return this; }
  _data(buf) {
    if (buf.length === 0) return;
    this.emit('data', this._encoding ? buf.toString(this._encoding) : buf);
  }
  _end() {
    if (this.complete) return;
    this.complete = true;
    this.emit('end');
  }
}

class ServerResponse extends EventEmitter {
  constructor(socket, method) {
    super();
    this.socket = socket;
    // the request method decides whether a body may be sent at all
    this._method = method || 'GET';
    this.statusCode = 200;
    this.statusMessage = '';
    this.headersSent = false;
    this.finished = false;
    this.writableEnded = false;
    this._headers = {};
    // Set by the server for a request whose connection may be reused. A
    // response built any other way closes, which is what this did before
    // there was a choice.
    this._keepAlive = false;
    // An HTTP/1.0 request: a body of unknown length cannot be chunked.
    this._http10 = false;
    this._chunked = false;
    this._onDone = null;
  }
  setHeader(k, v) { this._headers[k.toLowerCase()] = v; return this; }
  getHeader(k) { return this._headers[k.toLowerCase()]; }
  hasHeader(k) { return this._headers[k.toLowerCase()] !== undefined; }
  removeHeader(k) { delete this._headers[k.toLowerCase()]; }
  getHeaderNames() { return Object.keys(this._headers); }
  getHeaders() {
    const copy = {};
    for (const k in this._headers) copy[k] = this._headers[k];
    return copy;
  }
  writeHead(status, reason, headers) {
    this.statusCode = status;
    if (typeof reason === 'string') this.statusMessage = reason;
    else headers = reason;
    if (headers) for (const k in headers) this.setHeader(k, headers[k]);
    return this;
  }
  // A response to HEAD, and a 204 or 304, carry no body -- the headers
  // still describe what a GET would return. Sending one anyway leaves the
  // client reading it as the start of the next response.
  _bodyAllowed() {
    return this._method !== 'HEAD' && this.statusCode !== 204 && this.statusCode !== 304;
  }
  // The head, which also settles how the body is framed. `whole` is the
  // length of a body that end() sends in one piece, or -1 when writes
  // send it as it comes. A body of unknown length is chunked; an HTTP/1.0
  // client knows no chunks, so its body ends with the connection.
  _head(whole) {
    const h = this._headers;
    const te = String(h['transfer-encoding'] || '').toLowerCase();
    if (te.indexOf('chunked') >= 0) {
      this._chunked = this._bodyAllowed();
    } else if (h['content-length'] === undefined) {
      if (whole >= 0) h['content-length'] = whole;
      else if (this._bodyAllowed()) {
        if (this._http10) this._keepAlive = false;
        else { h['transfer-encoding'] = 'chunked'; this._chunked = true; }
      }
    }
    if (h['connection'] === undefined) h['connection'] = this._keepAlive ? 'keep-alive' : 'close';
    // A handler that asked to close outranks the server's willingness to
    // keep going, and what goes on the wire has to be what happens.
    const connHdr = String(h['connection']).toLowerCase();
    this._keepAlive = this._keepAlive && connHdr.indexOf('close') < 0;
    const reason = this.statusMessage || statusText(this.statusCode);
    let head = 'HTTP/1.1 ' + this.statusCode + ' ' + reason + CRLF;
    // An array value means one header line per element, not one line holding a
    // comma-joined list: that is how Set-Cookie sends several cookies, and
    // folding them produces a single cookie no client can take apart.
    for (const k in h) {
      const v = h[k];
      if (Array.isArray(v)) {
        for (let i = 0; i < v.length; i++) head += canon(k) + ': ' + v[i] + CRLF;
      } else {
        head += canon(k) + ': ' + v + CRLF;
      }
    }
    head += CRLF;
    this.headersSent = true;
    return Buffer.from(head, 'utf8');
  }
  // `data` as it goes on the wire: as a chunk when chunked, nothing when
  // this response has no body.
  _framed(data, out) {
    if (data.length === 0 || !this._bodyAllowed()) return;
    if (this._chunked) out.push(Buffer.from(data.length.toString(16) + CRLF, 'latin1'), data, Buffer.from(CRLF, 'latin1'));
    else out.push(data);
  }
  // Writes the pieces. Small ones go in one write: over TLS each write is
  // a record and a segment of its own, and a reply in two segments is
  // twice as likely to lose one. A large one is not copied.
  _send(parts) {
    if (parts.length === 0) return true;
    let n = 0;
    for (let i = 0; i < parts.length; i++) n += parts[i].length;
    if (parts.length === 1) return this.socket.write(parts[0]);
    if (n <= 16384) return this.socket.write(Buffer.concat(parts));
    let ok = true;
    for (let i = 0; i < parts.length; i++) ok = this.socket.write(parts[i]);
    return ok;
  }
  // Sends the head now, before any of the body.
  flushHeaders() {
    if (!this.headersSent && !this.finished) this._send([this._head(-1)]);
  }
  // Sends `chunk` now, the head first if it has not gone. Returns false
  // when the connection holds more than it wants to (wait for 'drain').
  write(chunk, enc, cb) {
    if (typeof enc === 'function') { cb = enc; enc = undefined; }
    if (this.finished) {
      const e = new Error('write after end');
      e.code = 'ERR_STREAM_WRITE_AFTER_END';
      if (typeof cb === 'function') queueMicrotask(() => cb(e));
      if (this.listenerCount('error') > 0) queueMicrotask(() => this.emit('error', e));
      return false;
    }
    const out = [];
    if (!this.headersSent) out.push(this._head(-1));
    this._framed(toBuf(chunk, enc), out);
    const ok = this._send(out);
    if (typeof cb === 'function') queueMicrotask(cb);
    return ok;
  }
  end(chunk, enc, cb) {
    if (typeof chunk === 'function') { cb = chunk; chunk = null; }
    else if (typeof enc === 'function') { cb = enc; enc = undefined; }
    if (this.finished) return this;
    if (typeof cb === 'function') this.once('finish', cb);
    const data = toBuf(chunk, enc);
    const out = [];
    // Nothing written yet: the whole body is here, and its length known.
    if (!this.headersSent) out.push(this._head(data.length));
    this._framed(data, out);
    if (this._chunked) out.push(Buffer.from('0' + CRLF + CRLF, 'latin1'));
    this._send(out);
    this.finished = true;
    this.writableEnded = true;
    if (!this._keepAlive) this.socket.end();
    this.emit('finish');
    this.emit('close');
    if (this._onDone) this._onDone();
    return this;
  }
}

// What a client may send before it has said anything we agreed to. The
// head is buffered whole because it cannot be understood in pieces, so
// without a ceiling a client that opens a connection and never sends the
// blank line grows that buffer until the machine has no memory left. It
// costs the attacker one socket and no cleverness.
//
// 16 KB is more than any real request line and header block, and well
// under what a body is allowed. Node's own default is 16 KB for the same
// reason.
const MAX_HEAD = 16 * 1024;

// A body is refused on the length the client declares, before any of it
// is buffered. Nothing gets around that by lying: this server reads a
// body only when Content-Length gives one, so a request that withholds
// the length arrives as a request with no body rather than as an
// unbounded one.
const MAX_BODY = 1024 * 1024;

// A connection that is answered and kept costs one slot for as long as it
// is held, and the machine has a small fixed number of them. Closing every
// answer instead costs one slot per request for a full TIME_WAIT, which is
// far worse for a page that polls: the slots go to connections that are
// already over. So the connection stays, and a deadline takes it back.
//
// A deadline and not an inactivity timer, because a timer that any byte
// resets is defeated by one byte every so often: sixteen kilobytes of
// header, one byte at a time, held a slot for days. What a client is
// given is a fixed time to deliver a complete request head -- from the
// connection opening, or from the end of the previous answer -- and then
// a fixed time to deliver the body it declared. nginx calls the same two
// numbers client_header_timeout and client_body_timeout.
const HEAD_MS = 15000;
const BODY_MS = 30000;

function serveConnection(server, socket) {
  let buf = Buffer.alloc(0);
  let msg = null;
  let res = null;
  let state = 'head';
  let remaining = 0;
  let timer = null;

  function clearDeadline() {
    if (timer) { clearTimeout(timer); timer = null; }
  }

  // The client's time is up. While an answer is being written there is
  // no deadline at all: that is the server's turn, and a long answer must
  // not be cut off for being slow to write.
  function onDeadline() {
    timer = null;
    if (state === 'done' || state === 'reply') return;
    state = 'done';
    socket.end();
    socket.destroy();
  }

  function deadline(ms) {
    clearDeadline();
    timer = setTimeout(onDeadline, ms);
  }

  // The request is read, answered, and only then is the next one looked
  // at: two responses interleaved on one socket is not a response at all.
  function onDone() {
    if (state === 'done') { clearDeadline(); return; }
    if (res === null || !res._keepAlive) {
      state = 'done';
      clearDeadline();
      return;
    }
    msg = null;
    res = null;
    state = 'head';
    deadline(HEAD_MS);
    pump();
  }

  function wantsKeepAlive(m) {
    const c = String(m.headers['connection'] || '').toLowerCase();
    if (c.indexOf('close') >= 0) return false;
    // HTTP/1.1 keeps the connection unless told otherwise; 1.0 is the
    // other way round and has to ask.
    if (m.httpVersion === '1.0') return c.indexOf('keep-alive') >= 0;
    return true;
  }

  // Answer, then hang up. A client that has already gone past a limit is
  // not going to be talked out of it, and leaving the socket open leaves
  // the thing being defended against in place.
  function refuse(code, reason) {
    try {
      const body = reason + String.fromCharCode(10);
      socket.write(Buffer.from(
        'HTTP/1.1 ' + code + ' ' + statusText(code) + CRLF +
        'Content-Type: text/plain' + CRLF +
        'Content-Length: ' + Buffer.byteLength(body) + CRLF +
        'Connection: close' + CRLF + CRLF + body, 'utf8'));
    } catch (e) { /* the peer may already be gone */ }
    state = 'done';
    clearDeadline();
    socket.end();
    socket.destroy();
  }

  deadline(HEAD_MS);
  const onData = (chunk) => { buf = Buffer.concat([buf, chunk]); pump(); };
  const onEnd = () => { if (msg && state !== 'done') { msg._end(); state = 'done'; } };
  // A connection that breaks mid-request is that connection's problem: report
  // it as 'clientError' and drop the socket. Left unhandled, 'error' would
  // throw out of the event loop and end the server.
  const onError = (e) => { clearDeadline(); server.emit('clientError', e, socket); socket.destroy(); };
  // A response that has not ended hears that its connection is gone, so a
  // handler writing as things happen can stop; one waiting to write more
  // hears that it may.
  const onClose = () => {
    clearDeadline();
    state = 'done';
    if (res !== null && !res.finished) res.emit('close');
  };
  const onDrain = () => { if (res !== null) res.emit('drain'); };
  socket.on('data', onData);
  socket.on('drain', onDrain);
  socket.on('end', onEnd);
  socket.on('error', onError);
  socket.on('close', onClose);

  // The protocol is changing under the request: the parser steps aside and
  // whoever listens gets the socket as it is, with whatever followed the
  // head. Nothing here touches the socket again.
  function handOver() {
    clearDeadline();
    socket.removeListener('data', onData);
    socket.removeListener('end', onEnd);
    socket.removeListener('error', onError);
    socket.removeListener('close', onClose);
    socket.removeListener('drain', onDrain);
    state = 'done';
    const head = buf;
    buf = Buffer.alloc(0);
    msg.upgrade = true;
    server.emit('upgrade', msg, socket, head);
  }

  function pump() {
    if (state === 'done') { buf = Buffer.alloc(0); return; }
    // Answering: anything already here belongs to the next request and
    // waits in the buffer, which MAX_HEAD still bounds.
    if (state === 'reply') { return; }
    if (state === 'head') {
      const he = findHeaderEnd(buf);
      if (he < 0) {
        if (buf.length > MAX_HEAD) {
          refuse(431, 'Request header too large');
        }
        return;
      }
      if (he > MAX_HEAD) { refuse(431, 'Request header too large'); return; }
      const text = buf.slice(0, he).toString('utf8');
      buf = buf.slice(he + 4);
      const lines = text.split(CRLF);
      const first = lines.shift().split(' ');
      msg = new IncomingMessage();
      msg.method = first[0];
      msg.url = first[1];
      msg.httpVersion = (first[2] || 'HTTP/1.1').split('/')[1] || '1.1';
      msg.headers = parseHeaders(lines.join(CRLF));
      const cl = msg.headers['content-length'];
      remaining = cl !== undefined ? parseInt(cl, 10) : 0;
      // A length that is absent, negative or not a number is none. A
      // declared one past the ceiling is refused before a byte of it is
      // kept, which is the point of it being declared.
      if (!(remaining > 0)) remaining = 0;
      if (remaining > MAX_BODY) { refuse(413, 'Payload too large'); return; }
      // An upgrade is only one when somebody is there to take it; otherwise
      // the request is served like any other.
      if (msg.headers['upgrade'] !== undefined &&
          String(msg.headers['connection'] || '').toLowerCase().indexOf('upgrade') >= 0 &&
          server.listenerCount('upgrade') > 0) {
        handOver();
        return;
      }
      // The head arrived in time. A body gets its own budget; none
      // expected means it is the server's turn and the clock stops.
      if (remaining > 0) deadline(BODY_MS); else clearDeadline();
      state = 'body';
      res = new ServerResponse(socket, msg.method);
      res._keepAlive = wantsKeepAlive(msg);
      res._http10 = msg.httpVersion === '1.0';
      res._onDone = onDone;
      server.emit('request', msg, res);
    }
    if (state === 'body') {
      if (remaining > 0 && buf.length > 0) {
        const take = Math.min(remaining, buf.length);
        msg._data(buf.slice(0, take));
        buf = buf.slice(take);
        remaining -= take;
      }
      if (remaining <= 0) { clearDeadline(); state = 'reply'; msg._end(); }
    }
  }
}

class Server extends EventEmitter {
  constructor(handler, connFactory) {
    super();
    if (typeof handler === 'function') this.on('request', handler);
    // connFactory(onConn) yields a listen/address/close server whose
    // connections are handed to onConn. Plain net by default; https injects a
    // TLS one so the HTTP protocol runs unchanged over a TLSSocket.
    const make = connFactory || ((onConn) => net.createServer(onConn));
    this._net = make((sock) => serveConnection(this, sock));
    this._net.on('error', (e) => this.emit('error', e));
    this.listening = false;
    this._net.on('listening', () => { this.listening = true; this.emit('listening'); });
    this._net.on('close', () => { this.listening = false; });
    // Node's https.Server is a tls.Server, so a handshake failure surfaces on
    // the server the caller holds. Here the TLS server is wrapped, so forward
    // it; a plain net server never emits this.
    this._net.on('tlsClientError', (e, sock) => this.emit('tlsClientError', e, sock));
  }
  listen(port, host, cb) {
    if (typeof port === 'function') { cb = port; port = 0; host = undefined; }
    else if (typeof host === 'function') { cb = host; host = undefined; }
    if (typeof cb === 'function') this.on('listening', cb);
    this._net.listen(port, host);
    return this;
  }
  address() { return this._net.address(); }
  close(cb) { if (typeof cb === 'function') this.on('close', cb); this._net.close(() => this.emit('close')); return this; }
  ref() { this._net.ref(); return this; }
  unref() { this._net.unref(); return this; }
}

class ClientRequest extends EventEmitter {
  constructor(options, cb) {
    super();
    if (typeof options === 'string') options = parseUrl(options);
    this.method = (options.method || 'GET').toUpperCase();
    this.path = options.path || '/';
    this.host = options.hostname || options.host || '127.0.0.1';
    this.port = options.port || 80;
    this._headers = {};
    const h = options.headers || {};
    for (const k in h) this._headers[k.toLowerCase()] = h[k];
    if (this._headers['host'] === undefined) this._headers['host'] = this.host + ':' + this.port;
    this._body = [];
    this._ended = false;
    this._sent = false;
    if (typeof cb === 'function') this.on('response', cb);
    if (options._tls) {
      const tls = require('tls');
      this.socket = tls.connect({ port: this.port, host: this.host,
        servername: options.servername || this.host,
        rejectUnauthorized: options.rejectUnauthorized });
    } else {
      this.socket = net.connect(this.port, this.host);
    }
    this.socket.on('connect', () => this._trySend());
    this.socket.on('error', (e) => this.emit('error', e));
    this.socket.on('close', () => this.emit('close'));
    this._parse();
  }
  setHeader(k, v) { this._headers[k.toLowerCase()] = v; return this; }
  // Tears the connection down without waiting for the response. An error is
  // only emitted when one is given, since a plain destroy is not a failure.
  destroy(err) {
    this._destroyed = true;
    if (this.socket && typeof this.socket.destroy === 'function') this.socket.destroy();
    if (err) this.emit('error', err);
    return this;
  }
  abort() { return this.destroy(); }
  write(chunk, enc) { this._body.push(toBuf(chunk, enc)); return true; }
  end(chunk, enc) {
    if (chunk != null) this.write(chunk, enc);
    this._ended = true;
    this._trySend();
    return this;
  }
  _trySend() {
    if (this._sent || !this._ended || this.socket._connecting) return;
    this._sent = true;
    const body = Buffer.concat(this._body);
    if (body.length && this._headers['content-length'] === undefined) this._headers['content-length'] = body.length;
    if (this._headers['connection'] === undefined) this._headers['connection'] = 'close';
    let head = this.method + ' ' + this.path + ' HTTP/1.1' + CRLF;
    for (const k in this._headers) head += canon(k) + ': ' + this._headers[k] + CRLF;
    head += CRLF;
    this.socket.write(Buffer.from(head, 'utf8'));
    if (body.length) this.socket.write(body);
  }
  _parse() {
    const self = this;
    let buf = Buffer.alloc(0);
    let res = null;
    let state = 'head';
    let remaining = -1;
    let chunked = false;
    let cstate = 'size';
    let cn = 0;
    const onData = (chunk) => { buf = Buffer.concat([buf, chunk]); pump(); };
    const onClose = () => {
      if (res && state !== 'done') {
        if (remaining < 0 && !chunked && buf.length) { res._data(buf); buf = Buffer.alloc(0); }
        res._end();
        state = 'done';
      }
    };
    this.socket.on('data', onData);
    this.socket.on('close', onClose);
    // The server agreed to change protocols. With an 'upgrade' listener the
    // socket is handed over with whatever followed the head, and no
    // 'response' is emitted; without one the socket is dropped.
    function handOver() {
      self.socket.removeListener('data', onData);
      self.socket.removeListener('close', onClose);
      state = 'done';
      const head = buf;
      buf = Buffer.alloc(0);
      if (self.listenerCount('upgrade') === 0) { self.socket.destroy(); return; }
      res.upgrade = true;
      self.emit('upgrade', res, self.socket, head);
    }
    function pump() {
      if (state === 'head') {
        const he = findHeaderEnd(buf);
        if (he < 0) return;
        const text = buf.slice(0, he).toString('utf8');
        buf = buf.slice(he + 4);
        const lines = text.split(CRLF);
        const first = lines.shift().split(' ');
        res = new IncomingMessage();
        res.httpVersion = (first[0] || 'HTTP/1.1').split('/')[1] || '1.1';
        res.statusCode = parseInt(first[1], 10) || 0;
        res.statusMessage = first.slice(2).join(' ');
        res.headers = parseHeaders(lines.join(CRLF));
        if (res.statusCode === 101 || (res.headers['upgrade'] !== undefined &&
            String(res.headers['connection'] || '').toLowerCase().indexOf('upgrade') >= 0)) {
          handOver();
          return;
        }
        const te = res.headers['transfer-encoding'];
        const cl = res.headers['content-length'];
        if (te && te.toLowerCase().indexOf('chunked') >= 0) chunked = true;
        else if (cl !== undefined) remaining = parseInt(cl, 10);
        else remaining = -1;
        state = 'body';
        self.emit('response', res);
      }
      if (state === 'body') {
        if (chunked) { pumpChunked(); return; }
        if (remaining >= 0) {
          if (remaining > 0 && buf.length > 0) {
            const take = Math.min(remaining, buf.length);
            res._data(buf.slice(0, take));
            buf = buf.slice(take);
            remaining -= take;
          }
          if (remaining === 0) { state = 'done'; res._end(); }
        } else if (buf.length > 0) {
          res._data(buf);
          buf = Buffer.alloc(0);
        }
      }
    }
    function pumpChunked() {
      while (true) {
        if (cstate === 'size') {
          const ln = findLine(buf);
          if (ln < 0) return;
          cn = parseInt(buf.slice(0, ln).toString('utf8').trim(), 16) || 0;
          buf = buf.slice(ln + 2);
          cstate = cn === 0 ? 'end' : 'data';
        } else if (cstate === 'data') {
          if (buf.length < cn) return;
          res._data(buf.slice(0, cn));
          buf = buf.slice(cn);
          cn = 0;
          cstate = 'crlf';
        } else if (cstate === 'crlf') {
          if (buf.length < 2) return;
          buf = buf.slice(2);
          cstate = 'size';
        } else {
          const ln = findLine(buf);
          if (ln < 0) return;
          buf = buf.slice(ln + 2);
          state = 'done';
          res._end();
          return;
        }
      }
    }
  }
}

function parseUrl(u) {
  const out = { method: 'GET', path: '/', port: 80, host: '127.0.0.1' };
  let s = u;
  const scheme = s.indexOf('://');
  if (scheme >= 0) s = s.slice(scheme + 3);
  let slash = s.indexOf('/');
  let hostport = slash >= 0 ? s.slice(0, slash) : s;
  out.path = slash >= 0 ? s.slice(slash) : '/';
  const colon = hostport.indexOf(':');
  if (colon >= 0) { out.host = hostport.slice(0, colon); out.port = parseInt(hostport.slice(colon + 1), 10) || 80; }
  else out.host = hostport;
  return out;
}

function request(options, cb) { return new ClientRequest(options, cb); }
function get(options, cb) {
  const req = new ClientRequest(options, cb);
  req.end();
  return req;
}

module.exports = {
  Server: Server,
  ServerResponse: ServerResponse,
  IncomingMessage: IncomingMessage,
  ClientRequest: ClientRequest,
  createServer: function (handler) { return new Server(handler); },
  request: request,
  get: get,
  STATUS_CODES: STATUS,
  METHODS: ['GET', 'POST', 'PUT', 'DELETE', 'HEAD', 'PATCH', 'OPTIONS'],
};
";
}

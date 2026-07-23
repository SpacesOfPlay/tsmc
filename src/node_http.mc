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
  200: 'OK', 201: 'Created', 202: 'Accepted', 204: 'No Content',
  301: 'Moved Permanently', 302: 'Found', 303: 'See Other',
  304: 'Not Modified', 307: 'Temporary Redirect', 308: 'Permanent Redirect',
  400: 'Bad Request', 401: 'Unauthorized', 403: 'Forbidden',
  404: 'Not Found', 405: 'Method Not Allowed', 409: 'Conflict',
  413: 'Payload Too Large', 418: 'I am a teapot', 429: 'Too Many Requests',
  500: 'Internal Server Error', 501: 'Not Implemented',
  502: 'Bad Gateway', 503: 'Service Unavailable',
};

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
    if (headers[k] !== undefined) headers[k] = headers[k] + ', ' + v;
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
    this._encoding = null;
  }
  setEncoding(enc) { this._encoding = enc; return this; }
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
  constructor(socket) {
    super();
    this.socket = socket;
    this.statusCode = 200;
    this.statusMessage = '';
    this.headersSent = false;
    this.finished = false;
    this._headers = {};
    this._body = [];
  }
  setHeader(k, v) { this._headers[k.toLowerCase()] = v; return this; }
  getHeader(k) { return this._headers[k.toLowerCase()]; }
  removeHeader(k) { delete this._headers[k.toLowerCase()]; }
  writeHead(status, reason, headers) {
    this.statusCode = status;
    if (typeof reason === 'string') this.statusMessage = reason;
    else headers = reason;
    if (headers) for (const k in headers) this.setHeader(k, headers[k]);
    return this;
  }
  write(chunk, enc) { this._body.push(toBuf(chunk, enc)); return true; }
  end(chunk, enc) {
    if (this.finished) return this;
    if (chunk != null) this.write(chunk, enc);
    const body = Buffer.concat(this._body);
    const reason = this.statusMessage || statusText(this.statusCode);
    if (this._headers['content-length'] === undefined) this._headers['content-length'] = body.length;
    if (this._headers['connection'] === undefined) this._headers['connection'] = 'close';
    let head = 'HTTP/1.1 ' + this.statusCode + ' ' + reason + CRLF;
    for (const k in this._headers) head += canon(k) + ': ' + this._headers[k] + CRLF;
    head += CRLF;
    this.headersSent = true;
    this.finished = true;
    this.socket.write(Buffer.from(head, 'utf8'));
    if (body.length) this.socket.write(body);
    this.socket.end();
    this.emit('finish');
    return this;
  }
}

function serveConnection(server, socket) {
  let buf = Buffer.alloc(0);
  let msg = null;
  let state = 'head';
  let remaining = 0;

  socket.on('data', (chunk) => { buf = Buffer.concat([buf, chunk]); pump(); });
  socket.on('end', () => { if (msg && state !== 'done') { msg._end(); state = 'done'; } });

  function pump() {
    if (state === 'head') {
      const he = findHeaderEnd(buf);
      if (he < 0) return;
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
      state = 'body';
      const res = new ServerResponse(socket);
      server.emit('request', msg, res);
    }
    if (state === 'body') {
      if (remaining > 0 && buf.length > 0) {
        const take = Math.min(remaining, buf.length);
        msg._data(buf.slice(0, take));
        buf = buf.slice(take);
        remaining -= take;
      }
      if (remaining <= 0) { state = 'done'; msg._end(); }
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
    this._net.on('listening', () => this.emit('listening'));
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
    this._parse();
  }
  setHeader(k, v) { this._headers[k.toLowerCase()] = v; return this; }
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
    this.socket.on('data', (chunk) => { buf = Buffer.concat([buf, chunk]); pump(); });
    this.socket.on('close', () => {
      if (res && state !== 'done') {
        if (remaining < 0 && !chunked && buf.length) { res._data(buf); buf = Buffer.alloc(0); }
        res._end();
        state = 'done';
      }
    });
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

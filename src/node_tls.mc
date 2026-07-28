// node_tls.mc -- the `tls` built-in: TLSSocket + tls.connect over the
// native TLS session pump (src/tls_native.mc). Shaped like net.Socket so
// http can run over it unchanged. See doc/PLAN_M34_tls.md.

str node_tls_source() {
    return "'use strict';
const EventEmitter = require('events');

const HS_DONE = 1;
const HAS_DATA = 2;
const T_EOF = 4;
const T_ERR = 8;
const T_WANT_WRITE = 16;

function asBuffer(data, enc) {
  if (typeof data === 'string') return Buffer.from(data, enc || 'utf8');
  return data;
}

class TLSSocket extends EventEmitter {
  constructor() {
    super();
    this._id = -1;
    this._connecting = true;
    this._pending = [];
    this._ending = false;
    this.destroyed = false;
    this.encrypted = true;
  }
  __onReady(revents) {
    if (this.destroyed) return;
    const st = __tls_pump(this._id);
    if (st & T_ERR) {
      const why = __tls_verify_error(this._id);
      if (why) this._fail('certificate verify failed: ' + why);
      else {
        const what = __tls_error_text(this._id);
        this._fail(what ? 'TLS error: ' + what : 'TLS error');
      }
      return;
    }
    if (this._connecting && __tls_established(this._id)) {
      this._connecting = false;
      this.emit('secureConnect');
      this.emit('connect');
      const q = this._pending;
      this._pending = [];
      for (let i = 0; i < q.length; i++) this._sendBuf(q[i]);
    }
    if (st & HAS_DATA) {
      let b;
      while ((b = __tls_read(this._id)) !== null) {
        this.emit('data', b);
        if (this.destroyed) return;
      }
    }
    if (st & T_EOF) { this.emit('end'); this._finish(); return; }
    // an end()ed socket closes once its outbound ciphertext has drained, so the
    // peer sees EOF (a Connection: close response would otherwise hang)
    this._maybeFinish();
  }
  _maybeFinish() {
    if (this._ending && !this.destroyed && !this._connecting && !__tls_wants_write(this._id)) {
      this._finish();
    }
  }
  _sendBuf(buf) {
    let off = 0;
    while (off < buf.length) {
      const n = __tls_write(this._id, buf, off);
      if (n <= 0) break;
      off += n;
    }
  }
  write(data, enc, cb) {
    if (typeof enc === 'function') { cb = enc; enc = undefined; }
    if (!this.destroyed) {
      const buf = asBuffer(data, enc);
      if (this._connecting) this._pending.push(buf);
      else this._sendBuf(buf);
    }
    if (typeof cb === 'function') queueMicrotask(cb);
    return true;
  }
  end(data, enc) {
    if (data != null) this.write(data, enc);
    this._ending = true;
    // close once the queued ciphertext has flushed; if it already has (the
    // common small-response case, no reactor event pending) close now
    if (!this._connecting) queueMicrotask(() => this._maybeFinish());
    return this;
  }
  _finish() {
    if (this.destroyed) return;
    this.destroyed = true;
    __tls_close(this._id);
    this.emit('close');
  }
  destroy() { this._finish(); return this; }
  _fail(msg) { const e = new Error(msg); this.emit('error', e); this._finish(); }
  ref() { __net_ref(this._id, true); return this; }
  unref() { __net_ref(this._id, false); return this; }
  setNoDelay() { return this; }
  setKeepAlive() { return this; }
  setEncoding() { return this; }
  setTimeout() { return this; }
}

// First PEM block of `pem` -> DER Buffer (a Buffer is passed through as-is).
function pemToDer(pem) {
  if (Buffer.isBuffer(pem)) return pem;
  const parts = String(pem).split('-----');
  const b64 = (parts[2] || '').replace(/[^A-Za-z0-9+/=]/g, '');
  return Buffer.from(b64, 'base64');
}

// A TLS 1.3 server presenting an ECDSA-P256 certificate. Shaped like
// net.createServer: `onSecure` (and the 'secureConnection' event) receive a
// TLSSocket once its handshake completes. listen/address/close proxy to an
// underlying net server; the shared context is freed on close.
function createServer(opts, onSecure) {
  if (typeof opts === 'function') { onSecure = opts; opts = {}; }
  opts = opts || {};
  const server = new EventEmitter();
  const ctxId = __tls_server_ctx(pemToDer(opts.cert), pemToDer(opts.key));
  if (ctxId < 0) {
    server.listen = function () {
      queueMicrotask(() => server.emit('error', new Error('tls.createServer: invalid certificate or key (ECDSA-P256 required)')));
      return server;
    };
    server.address = () => null;
    server.close = function (cb) { if (typeof cb === 'function') queueMicrotask(cb); return server; };
    return server;
  }
  if (typeof onSecure === 'function') server.on('secureConnection', onSecure);
  const net = require('net');
  const raw = net.createServer((sock) => {
    if (__tls_server_wrap(sock._id, ctxId) !== 0) { sock.destroy(); return; }
    const tsock = new TLSSocket();
    tsock._id = sock._id;
    tsock._connecting = true;
    __net_set_owner(sock._id, tsock);
    tsock.on('secureConnect', () => server.emit('secureConnection', tsock));
    // A handshake that fails must take down one connection, not the server.
    // 'error' with no listener throws, and nothing has had the chance to
    // attach one yet, so the failure is reported as 'tlsClientError' — an
    // ordinary event, safely ignorable — the way Node reports it.
    tsock.on('error', (e) => server.emit('tlsClientError', e, tsock));
  });
  raw.on('error', (e) => server.emit('error', e));
  raw.on('listening', () => server.emit('listening'));
  server.listen = function (port, host, cb) { raw.listen(port, host, cb); return server; };
  server.address = () => raw.address();
  server.close = function (cb) {
    raw.close(() => { __tls_server_ctx_free(ctxId); server.emit('close'); });
    if (typeof cb === 'function') server.on('close', cb);
    return server;
  };
  return server;
}

function connect(opts, cb) {
  if (typeof opts === 'number') opts = { port: opts };
  const s = new TLSSocket();
  const host = opts.host || opts.hostname || '127.0.0.1';
  const sni = opts.servername || host;
  // Secure by default: the chain is validated against the bundled roots and
  // the SNI hostname. rejectUnauthorized:false (or the Node env switch)
  // skips that but still verifies the handshake signature.
  const envOff = typeof process !== 'undefined' && process.env &&
    process.env.NODE_TLS_REJECT_UNAUTHORIZED === '0';
  const insecure = opts.rejectUnauthorized === false || envOff;
  if (typeof cb === 'function') s.on('secureConnect', cb);
  s._id = __tls_connect(host, opts.port || 443, sni, insecure);
  if (s._id < 0) {
    queueMicrotask(() => s._fail('TLS connect failed'));
    return s;
  }
  __net_set_owner(s._id, s);
  return s;
}

module.exports = {
  TLSSocket: TLSSocket,
  connect: connect,
  createServer: createServer,
  // SPKI-pin trust (ECDSA-P256): replaces CA validation with a key pin
  setEcdsaPin: function (hex) { __tls_pin_ecdsa(hex); },
};
";
}

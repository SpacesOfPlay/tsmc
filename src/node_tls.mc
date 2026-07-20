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
    if (st & T_ERR) { this._fail('TLS error'); return; }
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
    if (st & T_EOF) { this.emit('end'); this._finish(); }
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
    this._ending = true;   // wait for the peer's close_notify (EOF) to finish
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

function connect(opts, cb) {
  if (typeof opts === 'number') opts = { port: opts };
  const s = new TLSSocket();
  const host = opts.host || opts.hostname || '127.0.0.1';
  const sni = opts.servername || host;
  if (typeof cb === 'function') s.on('secureConnect', cb);
  s._id = __tls_connect(host, opts.port || 443, sni);
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
  // stopgap SPKI-pin trust (ECDSA-P256) until general cert validation
  setEcdsaPin: function (hex) { __tls_pin_ecdsa(hex); },
};
";
}

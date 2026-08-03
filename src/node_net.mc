// node_net.mc -- the `net` built-in module implementation.
//
// net.Socket / net.Server on EventEmitter. All protocol logic lives here
// in JS; the native __net_* primitives (src/builtins.mc) do socket I/O,
// and the reactor calls each owner's __onReady(revents). See
// doc/PLAN_M32_net_client.md.

str node_net_source() {
    return "'use strict';
const EventEmitter = require('events');

const POLLIN = 0x0001;
const POLLOUT = 0x0004;
const POLLBAD = 0x0018;   // POLLERR | POLLHUP

function asBuffer(data, enc) {
  if (typeof data === 'string') return Buffer.from(data, enc || 'utf8');
  return data;
}

class Socket extends EventEmitter {
  constructor() {
    super();
    this._id = -1;
    this._wq = [];
    this._connecting = false;
    this._reading = false;
    this._ending = false;
    this._sentFin = false;
    this._encoding = null;
    this.destroyed = false;
  }
  __onReady(revents) {
    // A finished connect is writable, but a refused one is only reported
    // that way on some platforms; elsewhere it arrives as POLLHUP with no
    // POLLOUT. Either way the verdict comes from the socket error, so both
    // are taken as the connect having completed.
    if (this._connecting && (revents & (POLLOUT | POLLBAD))) {
      const code = __net_connect_result(this._id);
      if (code === 0) {
        this._connecting = false;
        this._reading = true;
        __net_want_write(this._id, false);
        this.emit('connect');
        this._flush();
      } else {
        this._fail('connect ECONNREFUSED', 'ECONNREFUSED');
        return;
      }
    }
    if (this._reading && (revents & POLLIN)) {
      this._read();
      if (this.destroyed) return;
    }
    if (!this._connecting && (revents & POLLOUT)) {
      this._flush();
    }
    if ((revents & POLLBAD) && this._reading) {
      this._read();
    }
  }
  _read() {
    while (true) {
      const r = __net_recv(this._id);
      if (r === null) return;
      if (r === 0) { this.emit('end'); this._finish(); return; }
      if (r === -1) { this._fail('read EIO'); return; }
      this.emit('data', this._encoding ? r.toString(this._encoding) : r);
      if (this.destroyed) return;
    }
  }
  _flush() {
    if (this._wq.length === 0) return;
    while (this._wq.length > 0) {
      const it = this._wq[0];
      const n = __net_send(this._id, it.buf, it.off);
      if (n < 0) {
        if (n === -1) { __net_want_write(this._id, true); return; }
        this._fail('write EIO');
        return;
      }
      it.off += n;
      if (it.off >= it.buf.length) { this._wq.shift(); }
      else { __net_want_write(this._id, true); return; }
    }
    __net_want_write(this._id, false);
    this.emit('drain');
    if (this._ending) this._shutdownSend();
  }
  write(data, enc, cb) {
    if (typeof enc === 'function') { cb = enc; enc = undefined; }
    // Once end() has sent the FIN the send direction is closed, so there is
    // nowhere for this to go. Queueing it anyway meant a later flush tried
    // to send on a half-closed socket and reported the failure as an error.
    if (!this.destroyed && !this._ending) {
      this._wq.push({ buf: asBuffer(data, enc), off: 0 });
      this._flush();
    }
    if (typeof cb === 'function') queueMicrotask(cb);
    return this._wq.length === 0;
  }
  end(data, enc) {
    if (data != null) this.write(data, enc);
    this._ending = true;
    if (this._wq.length === 0) this._shutdownSend();
    return this;
  }
  _shutdownSend() {
    if (this.destroyed || this._sentFin) return;
    this._sentFin = true;
    __net_shutdown(this._id);
    this.emit('finish');
  }
  _finish() {
    if (this.destroyed) return;
    this.destroyed = true;
    __net_close(this._id);
    this.emit('close');
  }
  destroy() { this._finish(); return this; }
  _fail(msg, code) {
    const e = new Error(msg);
    if (code) e.code = code;
    this.emit('error', e);
    this._finish();
  }
  ref() { __net_ref(this._id, true); return this; }
  unref() { __net_ref(this._id, false); return this; }
  setNoDelay() { return this; }
  setKeepAlive() { return this; }
  setEncoding(enc) { this._encoding = enc || 'utf8'; return this; }
  setTimeout() { return this; }
}

class Server extends EventEmitter {
  constructor(onConn) {
    super();
    this._id = -1;
    this._closed = false;
    this.listening = false;
    if (typeof onConn === 'function') this.on('connection', onConn);
  }
  __onReady(revents) {
    if (revents & POLLIN) {
      while (!this._closed) {
        const cid = __net_accept(this._id);
        if (cid < 0) break;
        const s = new Socket();
        s._id = cid;
        s._reading = true;
        __net_set_owner(cid, s);
        this.emit('connection', s);
      }
    }
  }
  listen(port, host, cb) {
    if (typeof port === 'object' && port !== null) {
      const o = port; cb = host; port = o.port; host = o.host;
    }
    if (typeof host === 'function') { cb = host; host = undefined; }
    this._id = __net_listen(port | 0, host || '');
    if (this._id < 0) {
      const e = new Error('listen EADDRINUSE');
      queueMicrotask(() => this.emit('error', e));
      return this;
    }
    __net_set_owner(this._id, this);
    if (typeof cb === 'function') this.on('listening', cb);
    this.listening = true;
    queueMicrotask(() => this.emit('listening'));
    return this;
  }
  address() {
    return { port: __net_port(this._id), family: 'IPv4', address: '127.0.0.1' };
  }
  close(cb) {
    if (typeof cb === 'function') this.on('close', cb);
    if (!this._closed) {
      this._closed = true;
      this.listening = false;
      __net_close(this._id);
      queueMicrotask(() => this.emit('close'));
    }
    return this;
  }
  ref() { __net_ref(this._id, true); return this; }
  unref() { __net_ref(this._id, false); return this; }
}

function connect(port, host, cb) {
  let opts;
  if (typeof port === 'object' && port !== null) { opts = port; cb = host; }
  else { opts = { port: port, host: host }; }
  if (typeof opts.host === 'function') { cb = opts.host; opts.host = undefined; }
  if (typeof host === 'function') { cb = host; }
  const s = new Socket();
  s._connecting = true;
  s._id = __net_connect(opts.host || '127.0.0.1', opts.port | 0);
  if (s._id < 0) {
    queueMicrotask(() => s._fail('connect ENOTFOUND'));
    return s;
  }
  __net_set_owner(s._id, s);
  if (typeof cb === 'function') s.on('connect', cb);
  return s;
}

module.exports = {
  Socket: Socket,
  Server: Server,
  connect: connect,
  createConnection: connect,
  createServer: function (onConn) { return new Server(onConn); },
  isIP: function () { return 0; },
  isIPv4: function () { return false; },
  isIPv6: function () { return false; },
};
";
}

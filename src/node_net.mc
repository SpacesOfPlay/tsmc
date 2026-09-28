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

// Bytes a write() may leave queued before it answers false and a 'drain'
// is owed.
const HWM = 16384;
// Small queued pieces are joined up to this many bytes before a send.
const GATHER = 65536;

function asBuffer(data, enc) {
  if (typeof data === 'string') return Buffer.from(data, enc || 'utf8');
  return data;
}

class Socket extends EventEmitter {
  constructor() {
    super();
    this._id = -1;
    this._wq = [];
    this._wqBytes = 0;
    this._needDrain = false;
    this._corked = 0;
    this._connecting = false;
    this._reading = false;
    this._paused = false;
    this._pushback = [];
    this._ending = false;
    this._sentFin = false;
    this._peerEnded = false;
    this._encoding = null;
    this.destroyed = false;
    this.readable = false;
    this.writable = true;
    // What a stream reports about its two sides: the bytes accepted by
    // write() and not yet handed to the socket, whether the FIN went out,
    // and whether 'end' has been seen.
    const self = this;
    this._writableState = { get length() { return self._wqBytes; }, get finished() { return self._sentFin; } };
    this._readableState = { endEmitted: false, get ended() { return this.endEmitted; } };
  }
  get writableLength() { return this._wqBytes; }
  get writableHighWaterMark() { return HWM; }
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
        this.readable = true;
        __net_want_read(this._id, !this._paused);
        __net_want_write(this._id, false);
        this.emit('connect');
        this._flush();
      } else {
        this._fail('connect ECONNREFUSED', 'ECONNREFUSED');
        return;
      }
    }
    if (this._reading && !this._paused && (revents & POLLIN)) {
      this._read();
      if (this.destroyed) return;
    }
    if (!this._connecting && (revents & POLLOUT)) {
      this._flush();
    }
    // A hang-up is read whether paused or not: it is the end, and leaving
    // it unread would only have it reported again.
    if ((revents & POLLBAD) && this._reading) {
      this._read();
    }
  }
  _read() {
    while (true) {
      const r = __net_recv(this._id);
      if (r === null) return;
      if (r === 0) { this._onEof(); return; }
      if (r === -1) { this._fail('read EIO'); return; }
      this._emitData(r);
      if (this.destroyed || this._paused) return;
    }
  }
  _emitData(r) {
    this.emit('data', this._encoding ? r.toString(this._encoding) : r);
  }
  // The peer is done sending. What is still queued here goes out first, and
  // the socket closes once it has; anything written after this is dropped,
  // as there is nobody to read it.
  _onEof() {
    if (this._peerEnded) return;
    this.readable = false;
    this._readableState.endEmitted = true;
    this._peerEnded = true;
    // nothing more will arrive, and an EOF stays readable, so stop reading
    this._reading = false;
    if (this._id >= 0) __net_want_read(this._id, false);
    this.emit('end');
    if (this.destroyed) return;
    this._ending = true;
    this.writable = false;
    if (this._wq.length === 0) { this._shutdownSend(); this._finish(); }
  }
  // Bytes put back by unshift() go out ahead of anything still on the wire.
  _drainPushback() {
    while (this._pushback.length > 0 && !this._paused && !this.destroyed) {
      this._emitData(this._pushback.shift());
    }
  }
  unshift(chunk) {
    if (chunk == null || chunk.length === 0) return;
    this._pushback.push(asBuffer(chunk));
    queueMicrotask(() => this._drainPushback());
  }
  // What a pull would find: the bytes put back by unshift(), or nothing.
  // Everything else has already gone out as 'data'.
  read() {
    if (this._pushback.length === 0) return null;
    const out = Buffer.concat(this._pushback);
    this._pushback = [];
    return out;
  }
  // Paused, the socket is not read at all, so the peer's writes back up
  // onto the peer: that is the backpressure.
  pause() {
    this._paused = true;
    if (this._id >= 0 && !this._connecting && !this.destroyed) __net_want_read(this._id, false);
    return this;
  }
  resume() {
    if (!this._paused) return this;
    this._paused = false;
    queueMicrotask(() => {
      if (this.destroyed || this._paused) return;
      this._drainPushback();
      if (this.destroyed || this._paused || this._connecting) return;
      __net_want_read(this._id, true);
      if (this._reading) this._read();
    });
    return this;
  }
  // Several small pieces at the head of the queue go out as one: a frame is
  // often written as its header and its payload, and each send is a system
  // call. Up to GATHER bytes are joined before sending.
  _coalesce() {
    if (this._wq.length < 2) return;
    let n = 0;
    let k = 0;
    while (k < this._wq.length && n < GATHER) {
      const it = this._wq[k];
      n += it.buf.length - it.off;
      k++;
    }
    if (k < 2) return;
    const parts = [];
    for (let i = 0; i < k; i++) {
      const it = this._wq[i];
      parts.push(it.off > 0 ? it.buf.subarray(it.off) : it.buf);
    }
    this._wq.splice(0, k, { buf: Buffer.concat(parts, n), off: 0 });
  }
  // Two pieces — a header and its payload, the shape of a framed protocol
  // between cork() and uncork() — go out in one send without being joined
  // first. Returns false when the socket did not take them whole.
  _sendPair() {
    const a = this._wq[0];
    const b = this._wq[1];
    if (b.off !== 0) return false;
    const n = __net_send2(this._id, a.buf, a.off, b.buf);
    if (n === -3) return false;
    if (n < 0) {
      if (n === -1) { __net_want_write(this._id, true); return true; }
      this._fail('write EIO');
      return true;
    }
    const arest = a.buf.length - a.off;
    if (n >= arest + b.buf.length) {
      this._wq.splice(0, 2);
      this._wqBytes -= arest + b.buf.length;
      return true;
    }
    // part of it went: advance through the two pieces
    if (n >= arest) { this._wq.shift(); this._wqBytes -= arest; b.off = n - arest; this._wqBytes -= b.off; }
    else { a.off += n; this._wqBytes -= n; }
    __net_want_write(this._id, true);
    return true;
  }
  _flush() {
    if (this._wq.length === 0 || this._corked > 0) return;
    while (this._wq.length > 0) {
      if (this._wq.length === 2 && this._sendPair()) {
        if (this._wq.length > 0 || this.destroyed) return;
        break;
      }
      this._coalesce();
      const it = this._wq[0];
      const n = __net_send(this._id, it.buf, it.off);
      if (n < 0) {
        if (n === -1) { __net_want_write(this._id, true); return; }
        this._fail('write EIO');
        return;
      }
      it.off += n;
      this._wqBytes -= n;
      if (it.off >= it.buf.length) { this._wq.shift(); }
      else { __net_want_write(this._id, true); return; }
    }
    __net_want_write(this._id, false);
    if (this._needDrain) {
      this._needDrain = false;
      queueMicrotask(() => { if (!this.destroyed) this.emit('drain'); });
    }
    if (this._ending) this._shutdownSend();
    if (this._peerEnded) this._finish();
  }
  write(data, enc, cb) {
    if (typeof enc === 'function') { cb = enc; enc = undefined; }
    if (typeof cb === 'function') queueMicrotask(cb);
    // Once end() has sent the FIN the send direction is closed, so there is
    // nowhere for this to go. Queueing it anyway meant a later flush tried
    // to send on a half-closed socket and reported the failure as an error.
    if (this.destroyed || this._ending) return this._wqBytes < HWM;
    const buf = asBuffer(data, enc);
    // The common case: nothing queued, not corked, and the socket takes the
    // whole write at once, so there is nothing to queue.
    if (this._wq.length === 0 && this._corked === 0 && !this._connecting) {
      const n = __net_send(this._id, buf, 0);
      if (n === buf.length) {
        // the answer is about size, not about what the socket took: a large
        // write is false even when it goes out whole, and 'drain' follows
        if (buf.length < HWM) return true;
        this._needDrain = true;
        queueMicrotask(() => this._drainIfIdle());
        return false;
      }
      if (n < -1) { this._fail('write EIO'); return false; }
      const sent = n > 0 ? n : 0;
      this._wq.push({ buf: buf, off: sent });
      this._wqBytes += buf.length - sent;
      __net_want_write(this._id, true);
      const ok = this._wqBytes < HWM;
      if (!ok) this._needDrain = true;
      return ok;
    }
    this._wq.push({ buf: buf, off: 0 });
    this._wqBytes += buf.length;
    const ok = this._wqBytes < HWM;
    if (!ok) this._needDrain = true;
    if (!this._connecting) this._flush();
    return ok;
  }
  _drainIfIdle() {
    if (!this.destroyed && this._wq.length === 0 && this._needDrain) {
      this._needDrain = false;
      this.emit('drain');
    }
  }
  end(data, enc, cb) {
    if (typeof data === 'function') { cb = data; data = null; }
    else if (typeof enc === 'function') { cb = enc; enc = undefined; }
    if (data != null) this.write(data, enc);
    if (typeof cb === 'function') this.once('finish', cb);
    this._ending = true;
    this.writable = false;
    this._corked = 0;
    if (this._wq.length === 0 && !this._connecting) this._shutdownSend();
    else this._flush();
    return this;
  }
  // Writes between cork() and uncork() are held and go out together.
  cork() { this._corked++; }
  uncork() {
    if (this._corked === 0) return;
    this._corked--;
    if (this._corked === 0 && !this._connecting) this._flush();
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
    this.readable = false;
    this.writable = false;
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
        s.readable = true;
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

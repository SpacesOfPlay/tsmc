// node_stream.mc -- the `stream` built-in module implementation.
//
// Readable / Writable / Transform / PassThrough on EventEmitter,
// microtask-scheduled. Embedded JS source, compiled+run once when
// `stream` is first required/imported. See doc/PLAN_M24_stream.md.

// The JS source, one string literal per line (adjacent literals
// concatenate).
str node_stream_source() {
    return
        "'use strict';
"
        "const EventEmitter = require('events');
"
        "
"
        "function scheduleFlow(r) {
"
        "  const s = r._rs;
"
        "  if (s.scheduled) return;
"
        "  s.scheduled = true;
"
        "  queueMicrotask(function () { s.scheduled = false; flow(r); });
"
        "}
"
        "function flow(r) {
"
        "  const s = r._rs;
"
        "  if (s.destroyed) return;
"
        "  while (s.flowing && s.buffer.length > 0) {
"
        "    r.emit('data', s.buffer.shift());
"
        "  }
"
        "  if (s.buffer.length === 0) {
"
        "    if (s.ended) {
"
        "      if (!s.endEmitted) { s.endEmitted = true; r.readable = false; r.emit('end'); }
"
        "    } else if (s.flowing && !s.reading) {
"
        "      s.reading = true;
"
        "      r._read();
"
        "    }
"
        "  }
"
        "}
"
        "class Readable extends EventEmitter {
"
        "  constructor(opts) {
"
        "    super();
"
        "    opts = opts || {};
"
        "    this._rs = { buffer: [], flowing: false, ended: false, endEmitted: false, reading: false, scheduled: false, destroyed: false };
"
        "    if (typeof opts.read === 'function') this._read = opts.read;
"
        "    this.readable = true;
"
        "  }
"
        "  _read() {}
"
        "  push(chunk) {
"
        "    const s = this._rs;
"
        "    if (chunk === null) { s.ended = true; } else { s.buffer.push(chunk); }
"
        "    s.reading = false;
"
        "    scheduleFlow(this);
"
        "    return !s.ended;
"
        "  }
"
        "  read() {
"
        "    const s = this._rs;
"
        "    if (s.buffer.length > 0) return s.buffer.shift();
"
        "    if (!s.reading && !s.ended) { s.reading = true; this._read(); }
"
        "    return null;
"
        "  }
"
        "  resume() { const s = this._rs; if (!s.flowing) { s.flowing = true; scheduleFlow(this); } return this; }
"
        "  pause() { this._rs.flowing = false; return this; }
"
        "  on(event, listener) { super.on(event, listener); if (event === 'data') this.resume(); return this; }
"
        "  pipe(dest) {
"
        "    const src = this;
"
        "    src.on('data', function (chunk) { const ok = dest.write(chunk); if (ok === false && src.pause) src.pause(); });
"
        "    if (dest.on) dest.on('drain', function () { src.resume(); });
"
        "    src.on('end', function () { if (dest.end) dest.end(); });
"
        "    if (dest.emit) dest.emit('pipe', src);
"
        "    return dest;
"
        "  }
"
        "  destroy(err) { const s = this._rs; if (s.destroyed) return this; s.destroyed = true; if (err) this.emit('error', err); this.emit('close'); return this; }
"
        "  static from(iterable, opts) {
"
        "    const r = new Readable(opts);
"
        "    let items = [];
"
        "    if (Array.isArray(iterable)) items = iterable.slice();
"
        "    else for (const x of iterable) items.push(x);
"
        "    let i = 0;
"
        "    r._read = function () { if (i < items.length) r.push(items[i++]); else r.push(null); };
"
        "    return r;
"
        "  }
"
        "}
"
        "
"
        "function processWrite(w) {
"
        "  const s = w._ws;
"
        "  if (s.writing) return;
"
        "  if (s.buffer.length === 0) { maybeFinish(w); return; }
"
        "  s.writing = true;
"
        "  const item = s.buffer.shift();
"
        "  w._write(item.chunk, item.enc, function (err) {
"
        "    s.writing = false;
"
        "    if (item.cb) item.cb(err);
"
        "    if (err) { w.emit('error', err); return; }
"
        "    if (s.buffer.length > 0) processWrite(w); else { w.emit('drain'); maybeFinish(w); }
"
        "  });
"
        "}
"
        "function maybeFinish(w) {
"
        "  const s = w._ws;
"
        "  if (s.ended && !s.writing && s.buffer.length === 0 && !s.finished) {
"
        "    s.finished = true;
"
        "    const done = function () { w.writable = false; w.emit('finish'); };
"
        "    if (w._final) w._final(function (err) { if (err) w.emit('error', err); else done(); }); else queueMicrotask(done);
"
        "  }
"
        "}
"
        "class Writable extends EventEmitter {
"
        "  constructor(opts) {
"
        "    super();
"
        "    opts = opts || {};
"
        "    this._ws = { buffer: [], writing: false, ended: false, finished: false, destroyed: false };
"
        "    if (typeof opts.write === 'function') this._write = opts.write;
"
        "    if (typeof opts.final === 'function') this._final = opts.final;
"
        "    this.writable = true;
"
        "  }
"
        "  _write(chunk, enc, cb) { cb(); }
"
        "  write(chunk, enc, cb) {
"
        "    if (typeof enc === 'function') { cb = enc; enc = undefined; }
"
        "    const s = this._ws;
"
        "    if (s.ended) { const e = new Error('write after end'); if (cb) cb(e); this.emit('error', e); return false; }
"
        "    s.buffer.push({ chunk: chunk, enc: enc || 'utf8', cb: cb });
"
        "    processWrite(this);
"
        "    return s.buffer.length <= 1;
"
        "  }
"
        "  end(chunk, enc, cb) {
"
        "    if (typeof chunk === 'function') { cb = chunk; chunk = undefined; enc = undefined; }
"
        "    else if (typeof enc === 'function') { cb = enc; enc = undefined; }
"
        "    const s = this._ws;
"
        "    if (chunk !== undefined && chunk !== null) this.write(chunk, enc);
"
        "    s.ended = true;
"
        "    if (typeof cb === 'function') this.once('finish', cb);
"
        "    processWrite(this);
"
        "    return this;
"
        "  }
"
        "  destroy(err) { const s = this._ws; if (s.destroyed) return this; s.destroyed = true; if (err) this.emit('error', err); this.emit('close'); return this; }
"
        "}
"
        "
"
        "function processTransform(t) {
"
        "  const s = t._ts;
"
        "  if (s.writing) return;
"
        "  if (s.buffer.length === 0) { maybeFinishTransform(t); return; }
"
        "  s.writing = true;
"
        "  const item = s.buffer.shift();
"
        "  t._transform(item.chunk, item.enc, function (err, data) {
"
        "    s.writing = false;
"
        "    if (data !== undefined && data !== null) t.push(data);
"
        "    if (item.cb) item.cb(err);
"
        "    if (err) { t.emit('error', err); return; }
"
        "    if (s.buffer.length > 0) processTransform(t); else { t.emit('drain'); maybeFinishTransform(t); }
"
        "  });
"
        "}
"
        "function maybeFinishTransform(t) {
"
        "  const s = t._ts;
"
        "  if (s.ended && !s.writing && s.buffer.length === 0 && !s.finished) {
"
        "    s.finished = true;
"
        "    t._flush(function (err, data) {
"
        "      if (data !== undefined && data !== null) t.push(data);
"
        "      if (err) { t.emit('error', err); return; }
"
        "      t.push(null);
"
        "      t.emit('finish');
"
        "    });
"
        "  }
"
        "}
"
        "class Transform extends Readable {
"
        "  constructor(opts) {
"
        "    super(opts);
"
        "    opts = opts || {};
"
        "    this._ts = { buffer: [], writing: false, ended: false, finished: false };
"
        "    if (typeof opts.transform === 'function') this._transform = opts.transform;
"
        "    if (typeof opts.flush === 'function') this._flush = opts.flush;
"
        "    this.writable = true;
"
        "  }
"
        "  _transform(chunk, enc, cb) { cb(null, chunk); }
"
        "  _flush(cb) { cb(); }
"
        "  write(chunk, enc, cb) {
"
        "    if (typeof enc === 'function') { cb = enc; enc = undefined; }
"
        "    const s = this._ts;
"
        "    if (s.ended) { const e = new Error('write after end'); if (cb) cb(e); return false; }
"
        "    s.buffer.push({ chunk: chunk, enc: enc || 'utf8', cb: cb });
"
        "    processTransform(this);
"
        "    return true;
"
        "  }
"
        "  end(chunk, enc, cb) {
"
        "    if (typeof chunk === 'function') { cb = chunk; chunk = undefined; enc = undefined; }
"
        "    else if (typeof enc === 'function') { cb = enc; enc = undefined; }
"
        "    const s = this._ts;
"
        "    if (chunk !== undefined && chunk !== null) this.write(chunk, enc);
"
        "    s.ended = true;
"
        "    if (typeof cb === 'function') this.once('finish', cb);
"
        "    processTransform(this);
"
        "    return this;
"
        "  }
"
        "}
"
        "class PassThrough extends Transform {
"
        "  _transform(chunk, enc, cb) { cb(null, chunk); }
"
        "}
"
        "
"
        "function finished(stream, cb) {
"
        "  let done = false;
"
        "  const finish = function (err) { if (done) return; done = true; cb(err); };
"
        "  stream.on('end', function () { finish(); });
"
        "  stream.on('finish', function () { finish(); });
"
        "  stream.on('error', function (err) { finish(err); });
"
        "}
"
        "function pipeline(...args) {
"
        "  const cb = typeof args[args.length - 1] === 'function' ? args.pop() : null;
"
        "  for (let i = 0; i < args.length - 1; i++) args[i].pipe(args[i + 1]);
"
        "  const last = args[args.length - 1];
"
        "  if (cb) finished(last, cb);
"
        "  return last;
"
        "}
"
        "
"
        "function Stream() { EventEmitter.call(this); }
"
        "Stream.prototype = Object.create(EventEmitter.prototype);
"
        "Stream.Readable = Readable;
"
        "Stream.Writable = Writable;
"
        "Stream.Transform = Transform;
"
        "Stream.PassThrough = PassThrough;
"
        "Stream.Duplex = Transform;
"
        "Stream.Stream = Stream;
"
        "Stream.finished = finished;
"
        "Stream.pipeline = pipeline;
"
        "module.exports = Stream;
"
        "
"
        ;
}

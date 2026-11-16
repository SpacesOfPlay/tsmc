// node_stdin.mc -- process.stdin.
//
// A readable stream on EventEmitter over three native primitives
// (src/builtins.mc): __tty_read() gives the bytes that wait on standard
// input (a Buffer; null for none now, 0 at the end of input) and never
// waits, __tty_raw(on) asks the terminal for the keys' bytes as they
// come, __tty_isatty(fd) says whether a descriptor is a terminal. While
// the stream flows a timer looks for input every ten milliseconds: the
// loop stays alive for it as for any timer, and a paused or unref'd
// stream does not hold the program.

str node_stdin_source() {
    return "'use strict';
const EventEmitter = require('events');

const TICK_MS = 10;

class ReadStream extends EventEmitter {
  constructor() {
    super();
    this.fd = 0;
    this.readable = true;
    this.isRaw = false;
    this.destroyed = false;
    this._flowing = false;
    this._ended = false;
    this._reffed = true;
    this._timer = null;
    this._dec = null;
    if (__tty_isatty(0)) this.isTTY = true;
  }

  setEncoding(enc) {
    const StringDecoder = require('string_decoder').StringDecoder;
    this._dec = new StringDecoder(enc || 'utf8');
    return this;
  }

  setRawMode(on) {
    if (__tty_raw(!!on)) this.isRaw = !!on;
    return this;
  }

  on(name, fn) {
    super.on(name, fn);
    if (name === 'data') this.resume();
    return this;
  }
  addListener(name, fn) { return this.on(name, fn); }
  once(name, fn) {
    super.once(name, fn);
    if (name === 'data') this.resume();
    return this;
  }

  resume() {
    if (this._ended || this.destroyed) return this;
    this._flowing = true;
    if (this._timer === null) {
      this._timer = setInterval(() => this._look(), TICK_MS);
      if (!this._reffed) this._timer.unref();
    }
    return this;
  }

  pause() {
    this._flowing = false;
    if (this._timer !== null) { clearInterval(this._timer); this._timer = null; }
    return this;
  }

  isPaused() { return !this._flowing; }

  ref() { this._reffed = true; if (this._timer !== null) this._timer.ref(); return this; }
  unref() { this._reffed = false; if (this._timer !== null) this._timer.unref(); return this; }

  // What waits now, or null: for a caller that polls.
  read() {
    if (this._ended) return null;
    const r = __tty_read();
    if (r === null) return null;
    if (r === 0) { this._end(); return null; }
    return this._dec ? this._dec.write(r) : r;
  }

  _look() {
    while (this._flowing) {
      const r = __tty_read();
      if (r === null) return;
      if (r === 0) { this._end(); return; }
      const chunk = this._dec ? this._dec.write(r) : r;
      if (chunk.length > 0) this.emit('data', chunk);
    }
  }

  _end() {
    if (this._ended) return;
    this._ended = true;
    this.readable = false;
    this.pause();
    if (this._dec) {
      const rest = this._dec.end();
      if (rest && rest.length > 0) this.emit('data', rest);
    }
    this.emit('end');
    this.emit('close');
  }

  pipe(dest) {
    this.on('data', (chunk) => { dest.write(chunk); });
    this.on('end', () => { if (typeof dest.end === 'function' && dest !== process.stdout && dest !== process.stderr) dest.end(); });
    return dest;
  }

  destroy() {
    this.pause();
    this.destroyed = true;
    this.readable = false;
    return this;
  }
}

module.exports = new ReadStream();
";
}

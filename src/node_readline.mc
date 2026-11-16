// node_readline.mc -- the `readline` built-in module.
//
// An Interface on EventEmitter over an input and an output stream. On a
// terminal it sets raw mode and edits the line itself from 'keypress'
// events (emitKeypressEvents, which reads the keys out of the input's
// 'data'): insert, Backspace and Delete, the arrows, Home and End,
// Ctrl+A E U K W, the history on the up and down arrows, Enter for
// 'line', Ctrl+C for 'SIGINT' (close without a listener), Ctrl+D on an
// empty line for close. Not on a terminal it splits the input into
// lines. The line is drawn on one row: a line wider than the terminal
// wraps and is not followed.
//
// The source has no backslash and no double quote (it is a minc string
// literal): control characters come from String.fromCharCode.

str node_readline_source() {
    return "'use strict';
const EventEmitter = require('events');

const chr = String.fromCharCode;
const ESC = chr(27);
const CR = chr(13);
const LF = chr(10);
const CSI = ESC + '[';

// --- keys -------------------------------------------------------------------

const FINAL_NAMES = { A: 'up', B: 'down', C: 'right', D: 'left', H: 'home', F: 'end', Z: 'tab' };
const TILDE_NAMES = { 1: 'home', 2: 'insert', 3: 'delete', 4: 'end', 5: 'pageup', 6: 'pagedown', 7: 'home', 8: 'end' };

function isDigit(c) { return c >= 48 && c <= 57; }

// Calls each(str, key) for every key in s. str is the text the key
// types, undefined for a key that types none.
function parseKeys(s, each) {
  let i = 0;
  while (i < s.length) {
    const code = s.charCodeAt(i);
    const key = { sequence: s[i], name: undefined, ctrl: false, meta: false, shift: false };
    let text;
    if (code === 27 && i + 1 < s.length && (s[i + 1] === '[' || s[i + 1] === 'O')) {
      let j = i + 2;
      while (j < s.length && (isDigit(s.charCodeAt(j)) || s[j] === ';')) j++;
      if (j >= s.length) j = s.length - 1;
      const fin = s[j];
      const params = s.slice(i + 2, j).split(';');
      key.sequence = s.slice(i, j + 1);
      key.code = key.sequence.slice(1);
      if (fin === '~') key.name = TILDE_NAMES[params[0] | 0];
      else key.name = FINAL_NAMES[fin];
      if (fin === 'Z') key.shift = true;
      const mod = params.length > 1 ? (params[1] | 0) - 1 : 0;
      if (mod > 0) { key.shift = key.shift || (mod & 1) !== 0; key.meta = (mod & 2) !== 0; key.ctrl = (mod & 4) !== 0; }
      i = j + 1;
    } else if (code === 27 && i + 1 < s.length) {
      key.meta = true;
      key.sequence = s.slice(i, i + 2);
      const c2 = s.charCodeAt(i + 1);
      if (c2 === 127 || c2 === 8) key.name = 'backspace';
      else key.name = s[i + 1].toLowerCase();
      i += 2;
    } else if (code === 27) {
      key.name = 'escape';
      i++;
    } else if (code === 13) { key.name = 'return'; text = CR; i++; }
    else if (code === 10) { key.name = 'enter'; text = LF; i++; }
    else if (code === 9) { key.name = 'tab'; text = s[i]; i++; }
    else if (code === 127 || code === 8) { key.name = 'backspace'; i++; }
    else if (code < 27) { key.name = chr(code + 96); key.ctrl = true; i++; }
    else {
      // a character, both halves of one outside the first plane
      let n = 1;
      if (code >= 0xD800 && code <= 0xDBFF && i + 1 < s.length) n = 2;
      text = s.slice(i, i + n);
      key.sequence = text;
      if (code === 32) key.name = 'space';
      else if (code >= 97 && code <= 122) key.name = text;
      else if (code >= 65 && code <= 90) { key.name = text.toLowerCase(); key.shift = true; }
      else if (isDigit(code)) key.name = text;
      i += n;
    }
    each(text, key);
  }
}

function emitKeypressEvents(stream) {
  if (!stream || stream._keypressDecoder) return;
  const StringDecoder = require('string_decoder').StringDecoder;
  stream._keypressDecoder = new StringDecoder('utf8');
  stream.on('data', (chunk) => {
    if (stream.listenerCount('keypress') === 0) return;
    const s = typeof chunk === 'string' ? chunk : stream._keypressDecoder.write(chunk);
    parseKeys(s, (text, key) => { stream.emit('keypress', text, key); });
  });
}

// --- the cursor ---------------------------------------------------------------

function done(cb) { if (typeof cb === 'function') cb(); return true; }

function clearLine(stream, dir, cb) {
  if (stream) stream.write(CSI + (dir < 0 ? '1K' : dir > 0 ? '0K' : '2K'));
  return done(cb);
}
function clearScreenDown(stream, cb) {
  if (stream) stream.write(CSI + '0J');
  return done(cb);
}
function cursorTo(stream, x, y, cb) {
  if (typeof y === 'function') { cb = y; y = undefined; }
  if (stream) stream.write(typeof y === 'number' ? CSI + (y + 1) + ';' + (x + 1) + 'H' : CSI + (x + 1) + 'G');
  return done(cb);
}
function moveCursor(stream, dx, dy, cb) {
  let s = '';
  if (dx < 0) s += CSI + (-dx) + 'D'; else if (dx > 0) s += CSI + dx + 'C';
  if (dy < 0) s += CSI + (-dy) + 'A'; else if (dy > 0) s += CSI + dy + 'B';
  if (stream && s.length > 0) stream.write(s);
  return done(cb);
}

// --- the interface --------------------------------------------------------------

class Interface extends EventEmitter {
  constructor(input, output, completer, terminal) {
    super();
    let opts = input;
    if (!opts || typeof opts.on === 'function') opts = { input: input, output: output, completer: completer, terminal: terminal };
    this.input = opts.input;
    this.output = opts.output;
    this.terminal = opts.terminal !== undefined ? !!opts.terminal : !!(this.output && this.output.isTTY);
    this.line = '';
    this.cursor = 0;
    this.closed = false;
    this.history = Array.isArray(opts.history) ? opts.history.slice() : [];
    this.historySize = typeof opts.historySize === 'number' ? opts.historySize : 30;
    this._historyAt = -1;
    this._prompt = typeof opts.prompt === 'string' ? opts.prompt : '> ';
    this._question = null;
    this._savedPrompt = null;
    this._partial = '';
    this._sawCR = false;
    this._waiters = [];
    this._lines = [];
    this._onEnd = () => {
      if (!this.terminal && this._partial.length > 0) { const rest = this._partial; this._partial = ''; this._line(rest); }
      this.close();
    };
    if (this.terminal) {
      emitKeypressEvents(this.input);
      this._onKey = (text, key) => { this._key(text, key); };
      this.input.on('keypress', this._onKey);
      if (typeof this.input.setRawMode === 'function') this.input.setRawMode(true);
    } else {
      const StringDecoder = require('string_decoder').StringDecoder;
      this._decoder = new StringDecoder('utf8');
      this._onData = (chunk) => { this._data(typeof chunk === 'string' ? chunk : this._decoder.write(chunk)); };
      this.input.on('data', this._onData);
    }
    this.input.on('end', this._onEnd);
    if (typeof this.input.resume === 'function') this.input.resume();
  }

  getPrompt() { return this._prompt; }
  setPrompt(p) { this._prompt = String(p); }

  _out(s) { if (this.output && s.length > 0) this.output.write(s); }

  prompt(preserveCursor) {
    if (this.closed) return;
    if (!this.terminal) { this._out(this._prompt); return; }
    if (!preserveCursor) this.cursor = this.line.length;
    this._refresh();
  }

  question(query, options, cb) {
    if (typeof options === 'function') cb = options;
    if (this.closed) throw new Error('readline was closed');
    if (this._question) { this.prompt(); return; }
    this._savedPrompt = this._prompt;
    this._prompt = String(query);
    this._question = typeof cb === 'function' ? cb : () => {};
    this.prompt();
  }

  // A line is whole: the question's answer, or a 'line'.
  _line(text) {
    if (this._question) {
      const cb = this._question;
      this._question = null;
      this._prompt = this._savedPrompt;
      cb(text);
      return;
    }
    if (this._waiters.length > 0) { const w = this._waiters.shift(); w({ value: text, done: false }); }
    else if (this._iterating) this._lines.push(text);
    this.emit('line', text);
  }

  // Not a terminal: the input is split at line feeds, a carriage return
  // before one dropped.
  _data(s) {
    let from = 0;
    for (let i = 0; i < s.length && !this.closed; i++) {
      const c = s.charCodeAt(i);
      if (c !== 10 && c !== 13) { this._sawCR = false; continue; }
      if (c === 10 && this._sawCR) { this._sawCR = false; from = i + 1; continue; }
      this._sawCR = c === 13;
      const text = this._partial + s.slice(from, i);
      this._partial = '';
      from = i + 1;
      this._line(text);
    }
    if (from < s.length) this._partial += s.slice(from);
  }

  // The prompt and the line on the cursor's row, the cursor where it is
  // in the line.
  _refresh() {
    let s = CR + this._prompt + this.line + CSI + 'K';
    const back = this.line.length - this.cursor;
    if (back > 0) s += CSI + back + 'D';
    this._out(s);
  }

  _insert(text) {
    this.line = this.line.slice(0, this.cursor) + text + this.line.slice(this.cursor);
    this.cursor += text.length;
    if (this.cursor === this.line.length) this._out(text); else this._refresh();
  }

  _historyTo(at) {
    if (at < -1 || at >= this.history.length) return;
    this._historyAt = at;
    this.line = at < 0 ? '' : this.history[at];
    this.cursor = this.line.length;
    this._refresh();
  }

  _enter() {
    const text = this.line;
    this._out(CR + LF);
    this.line = '';
    this.cursor = 0;
    this._historyAt = -1;
    if (text.length > 0 && this.historySize > 0 && this.history[0] !== text) {
      this.history.unshift(text);
      if (this.history.length > this.historySize) this.history.pop();
    }
    this._line(text);
  }

  _key(text, key) {
    if (this.closed || this._paused) return;
    const name = key.name;
    if (key.ctrl) {
      if (name === 'c') {
        if (this.listenerCount('SIGINT') > 0) this.emit('SIGINT'); else this.close();
      } else if (name === 'd') {
        if (this.line.length === 0) this.close();
        else if (this.cursor < this.line.length) { this.line = this.line.slice(0, this.cursor) + this.line.slice(this.cursor + 1); this._refresh(); }
      } else if (name === 'a') { this.cursor = 0; this._refresh(); }
      else if (name === 'e') { this.cursor = this.line.length; this._refresh(); }
      else if (name === 'u') { this.line = this.line.slice(this.cursor); this.cursor = 0; this._refresh(); }
      else if (name === 'k') { this.line = this.line.slice(0, this.cursor); this._refresh(); }
      else if (name === 'w') {
        let at = this.cursor;
        while (at > 0 && this.line[at - 1] === ' ') at--;
        while (at > 0 && this.line[at - 1] !== ' ') at--;
        this.line = this.line.slice(0, at) + this.line.slice(this.cursor);
        this.cursor = at;
        this._refresh();
      } else if (name === 'l') { this._out(CSI + '2J' + CSI + 'H'); this._refresh(); }
      else if (name === 'left' || name === 'right') { /* by words: not followed */ }
      return;
    }
    if (name === 'return' || name === 'enter') { this._enter(); return; }
    if (name === 'backspace') {
      if (this.cursor > 0) {
        this.line = this.line.slice(0, this.cursor - 1) + this.line.slice(this.cursor);
        this.cursor--;
        this._refresh();
      }
      return;
    }
    if (name === 'delete') {
      if (this.cursor < this.line.length) { this.line = this.line.slice(0, this.cursor) + this.line.slice(this.cursor + 1); this._refresh(); }
      return;
    }
    if (name === 'left') { if (this.cursor > 0) { this.cursor--; this._out(CSI + '1D'); } return; }
    if (name === 'right') { if (this.cursor < this.line.length) { this.cursor++; this._out(CSI + '1C'); } return; }
    if (name === 'home') { this.cursor = 0; this._refresh(); return; }
    if (name === 'end') { this.cursor = this.line.length; this._refresh(); return; }
    if (name === 'up') { this._historyTo(this._historyAt + 1); return; }
    if (name === 'down') { this._historyTo(this._historyAt - 1); return; }
    if (key.meta || name === 'escape' || name === 'tab') return;
    if (typeof text === 'string' && text.length > 0) this._insert(text);
  }

  // As if typed.
  write(data, key) {
    if (this.closed) return;
    if (!this.terminal) { if (typeof data === 'string') this._data(data); return; }
    if (key && typeof key === 'object') { this._key(data, { sequence: key.sequence, name: key.name, ctrl: !!key.ctrl, meta: !!key.meta, shift: !!key.shift }); return; }
    if (typeof data === 'string') parseKeys(data, (text, k) => { this._key(text, k); });
  }

  pause() {
    if (this._paused) return this;
    this._paused = true;
    if (typeof this.input.pause === 'function') this.input.pause();
    this.emit('pause');
    return this;
  }
  resume() {
    if (!this._paused) return this;
    this._paused = false;
    if (typeof this.input.resume === 'function') this.input.resume();
    this.emit('resume');
    return this;
  }

  close() {
    if (this.closed) return;
    this.closed = true;
    if (this._onKey) this.input.removeListener('keypress', this._onKey);
    if (this._onData) this.input.removeListener('data', this._onData);
    this.input.removeListener('end', this._onEnd);
    if (this.terminal && typeof this.input.setRawMode === 'function') this.input.setRawMode(false);
    if (typeof this.input.pause === 'function') this.input.pause();
    while (this._waiters.length > 0) { const w = this._waiters.shift(); w({ value: undefined, done: true }); }
    this.emit('close');
  }

  [Symbol.asyncIterator]() {
    this._iterating = true;
    const rl = this;
    return {
      next() {
        if (rl._lines.length > 0) return Promise.resolve({ value: rl._lines.shift(), done: false });
        if (rl.closed) return Promise.resolve({ value: undefined, done: true });
        return new Promise((resolve) => { rl._waiters.push(resolve); });
      },
      return() { rl.close(); return Promise.resolve({ value: undefined, done: true }); },
      [Symbol.asyncIterator]() { return this; },
    };
  }
}

function createInterface(input, output, completer, terminal) {
  return new Interface(input, output, completer, terminal);
}

// readline/promises: question() gives a promise of the answer.
class PromiseInterface extends Interface {
  question(query, options) {
    return new Promise((resolve, reject) => {
      if (this.closed) { reject(new Error('readline was closed')); return; }
      super.question(query, resolve);
    });
  }
}

exports.Interface = Interface;
exports.createInterface = createInterface;
exports.emitKeypressEvents = emitKeypressEvents;
exports.clearLine = clearLine;
exports.clearScreenDown = clearScreenDown;
exports.cursorTo = cursorTo;
exports.moveCursor = moveCursor;
exports.promises = {
  Interface: PromiseInterface,
  createInterface: function (input, output, completer, terminal) { return new PromiseInterface(input, output, completer, terminal); },
};
";
}

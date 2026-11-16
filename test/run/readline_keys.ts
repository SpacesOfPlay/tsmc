const readline = require('readline');
const { EventEmitter } = require('events');
// a stand-in terminal: keys written to it come out as 'data'
class Fake extends EventEmitter { constructor() { super(); this.isTTY = true; this.raw = null; } setRawMode(on) { this.raw = on; } resume() {} pause() {} }
const input = new Fake();
let drawn = '';
const output = { isTTY: true, write(s) { drawn += s; return true; } };
const rl = readline.createInterface({ input, output, prompt: '$ ' });
const lines = [];
rl.on('line', (l) => lines.push(l));
rl.prompt();
const ESC = String.fromCharCode(27);
input.emit('data', Buffer.from('helo'));
input.emit('data', Buffer.from(ESC + '[D'));          // left
input.emit('data', Buffer.from('l'));                  // hel|o -> hell|o
input.emit('data', Buffer.from(String.fromCharCode(5) + '!' + String.fromCharCode(13)));   // End, !, Enter
input.emit('data', Buffer.from('abc' + String.fromCharCode(127) + String.fromCharCode(1) + 'x' + String.fromCharCode(13)));  // ab, Home, x
input.emit('data', Buffer.from(ESC + '[A' + ESC + '[A' + String.fromCharCode(13)));  // history: twice up, Enter
const keys = [];
input.on('keypress', (s, k) => keys.push((k.ctrl ? 'C-' : '') + k.name));
input.emit('data', Buffer.from(ESC + '[3~' + ESC + '[1;5C' + String.fromCharCode(3)));
console.log(JSON.stringify(lines), 'raw', input.raw, 'closed', rl.closed, keys.join(','));

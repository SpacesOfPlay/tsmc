// Extra globals / builtins added for npm-package compatibility. All output is
// deterministic and compared byte-for-byte against Node.

// EvalError / URIError as real Error subclasses
for (const C of [EvalError, URIError]) {
  const e = new C('boom');
  console.log(C.name, e instanceof C, e instanceof Error, e.name, e.message, e.toString());
}
console.log(typeof EvalError, typeof URIError);

// Symbol.for / Symbol.keyFor registry
const s1 = Symbol.for('tsmc.demo');
const s2 = Symbol.for('tsmc.demo');
console.log(s1 === s2, typeof s1, Symbol.keyFor(s1));
console.log(Symbol.keyFor(Symbol('local')));   // unregistered -> undefined
console.log(Symbol.for(42) === Symbol.for('42'));   // key is stringified

// Object.getOwnPropertyDescriptors
const src = { a: 1 };
Object.defineProperty(src, 'b', { value: 2, enumerable: false, writable: true, configurable: false });
const d = Object.getOwnPropertyDescriptors(src);
console.log(JSON.stringify(d.a), JSON.stringify(d.b));
console.log(Object.keys(Object.getOwnPropertyDescriptors({})).length);

// free identifiers resolve against the global object's inherited
// Object.prototype (bare reads and `typeof` alike)
console.log(typeof toString, typeof hasOwnProperty);
console.log(typeof someUndefinedThing);   // still undefined, not a method

// crypto.randomFillSync fills in place and returns the same object
const crypto = require('crypto');
const buf = Buffer.alloc(16);
const ret = crypto.randomFillSync(buf);
console.log(ret === buf, ret.length, buf.every(x => x >= 0 && x <= 255));
const u = new Uint8Array(4);
console.log(crypto.randomFillSync(u) === u, u.length);
console.log(typeof crypto.randomFillSync);

// tty stub: never a terminal (matches piped stdio)
const tty = require('tty');
console.log(tty.isatty(1), typeof tty.isatty);

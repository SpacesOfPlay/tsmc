// The Function constructor compiles at runtime; the 64-bit BigInt views.
const add = new Function('a', 'b', 'return a + b');
console.log(add(2, 3), add.length, add.name);
const k = Function('return typeof this')();
console.log(k);
try { new Function('return )'); } catch (e) { console.log(e instanceof SyntaxError); }
const buf = new ArrayBuffer(16);
const u = new BigUint64Array(buf);
u[0] = 18446744073709551615n;
u[1] = 5n;
const s = new BigInt64Array(buf);
console.log(u[0], s[0], u[1], typeof u[1], u.length, BigUint64Array.BYTES_PER_ELEMENT);
console.log(new Uint8Array(buf)[8]);

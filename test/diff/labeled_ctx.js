// A label may be a contextual keyword (e.g. `out`, the TS variance modifier,
// which is a valid identifier outside type positions). bignumber.js/decimal.js
// use `out:` as a label. Compared byte-for-byte against Node.

// labeled if with break to the label
function f(c) {
  let r = 'x';
  out: if (c) {
    if (c === 1) { r = 'one'; break out; }
    r = 'other';
  }
  return r;
}
console.log(f(0), f(1), f(2));

// labeled loop with continue/break using a contextual-keyword label
let acc = '';
out: for (let i = 0; i < 4; i++) {
  for (let j = 0; j < 4; j++) {
    if (j === 2) continue out;
    if (i === 3) break out;
    acc += i + '' + j + ' ';
  }
}
console.log(acc.trim());

// other contextual keywords work as labels too
type: while (true) { break type; }
of: for (;;) { break of; }
console.log('ctx labels ok');

// `out` remains usable as an identifier, property, and for-of binding
const out = 5;
const obj = { out: 7 };
let sum = 0;
for (const out of [1, 2, 3]) sum += out;
console.log(out, obj.out, sum);

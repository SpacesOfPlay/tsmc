// Strings built by concatenation: += loops, template pieces, branches that
// extend the same prefix, and everything read back through indexing,
// slicing, equality and JSON. Concatenation results may share bytes with
// the strings they extend, so a prefix must keep its own length and
// contents whatever is appended after it.

let s = '';
for (let i = 0; i < 20000; i++) s += 'ab';
console.log(s.length, s.slice(0, 6), s.slice(-4), s === 'ab'.repeat(20000));

let u = '';
for (let i = 0; i < 3000; i++) u += i % 3 === 0 ? 'é' : i % 3 === 1 ? '😀' : 'z';
console.log(u.length, u.charCodeAt(1), u.charCodeAt(2), u.codePointAt(1), u.slice(0, 5), [...u].length);

// a prefix extended two ways stays itself
const base = 'x'.repeat(200) + 'END';
const a = base + '-a';
const b = base + '-b';
const c = a + '-c';
console.log(base.length, base.endsWith('END'), a.endsWith('END-a'), b.endsWith('END-b'), c.endsWith('END-a-c'), a === b, a.slice(0, -2) === b.slice(0, -2));

// extending the same string repeatedly from a loop variable
let acc = 'seed';
const snapshots = [];
for (let i = 0; i < 300; i++) { acc = acc + i.toString(36); if (i % 100 === 0) snapshots.push(acc); }
console.log(snapshots.map((x) => x.length).join(','), snapshots[0], snapshots[1].slice(-5), acc.length, acc.startsWith(snapshots[2]));

// templates concatenate the same way
let t = '';
for (let i = 0; i < 500; i++) t += `${i}:${i * i};`;
console.log(t.length, t.slice(0, 20), t.split(';').length, t.indexOf('499:249001'));

// pieces that are themselves large
let big = 'q'.repeat(1000);
for (let i = 0; i < 50; i++) big = big + big.slice(0, 100);
console.log(big.length, big[999], big[1000], big.lastIndexOf('q') === big.length - 1);

// self-append and the halves of an astral pair meeting across a join
let d = 'ab';
for (let i = 0; i < 12; i++) d = d + d;
console.log(d.length, d === 'ab'.repeat(4096));
const hi = '😀'.slice(0, 1), lo = '😀'.slice(1);
let e = 'p'.repeat(150) + hi;
e = e + lo;
console.log(e.length, e.endsWith('😀'), e.codePointAt(150));

// keys, JSON and comparison over built strings
const o = {};
o[s.slice(0, 10)] = 1;
console.log(Object.keys(o), JSON.stringify(t.slice(0, 12)), s < u, s.localeCompare(s.slice(0, 100)) > 0);

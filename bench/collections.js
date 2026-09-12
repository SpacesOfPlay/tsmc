// Map and Set: insert, look up, iterate, delete. Keys of both kinds, since a
// string key hashes and an object key is identity.
const keys = [];
for (let i = 0; i < 2000; i++) keys.push({ i });
let acc = 0;
for (let iter = 0; iter < 9; iter++) {
  const m = new Map();
  const s = new Set();
  for (let i = 0; i < 2000; i++) {
    m.set('k' + i, i);
    m.set(keys[i], i);
    s.add(i & 1023);
  }
  for (let i = 0; i < 2000; i++) acc = (acc + m.get('k' + i) + m.get(keys[i])) | 0;
  for (const [, v] of m) acc = (acc + v) | 0;
  for (const v of s) acc = (acc + v) | 0;
  for (let i = 0; i < 2000; i += 2) m.delete('k' + i);
  acc = (acc + m.size + s.size) | 0;
}
console.log(acc);

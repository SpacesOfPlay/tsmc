// Map and Set under churn: entries deleted and added in turn, as a game's
// map of who stands where sees, keep their order and their count, and the
// storage drops what was deleted. Iterators and forEach that are walking
// while entries go and come see what the language says they see: an entry
// deleted before the walk reaches it is skipped, one added during the walk
// is visited, and nothing is seen twice.

function order(m: Map<any, any> | Set<any>) {
  const out: any[] = [];
  for (const k of m.keys()) out.push(k);
  return out.join(',');
}

// a moving crowd: each step deletes a key and adds another
const occ = new Map<number, number>();
for (let i = 0; i < 50; i++) occ.set(i, i);
for (let step = 0; step < 200000; step++) {
  const k = step % 50;
  occ.delete(k + 1000 * Math.floor(step / 50));
  occ.set(k + 1000 * (Math.floor(step / 50) + 1), step);
}
console.log('crowd size', occ.size, 'first', occ.keys().next().value, 'last', [...occ.keys()].pop());

// an iterator that runs across many compactions
const m = new Map<number, string>();
for (let i = 0; i < 100; i++) m.set(i, 'v' + i);
const seen: number[] = [];
let added = 100;
for (const [k] of m) {
  seen.push(k);
  if (k < 100) {
    m.delete(k + 1);             // ahead of the walk: never seen
    m.delete(k - 1);             // behind it: already seen
    if (k % 10 === 0) m.set(added++, 'new');
  }
  if (seen.length > 1000) break;
}
console.log('walk', seen.length, seen.slice(0, 12).join(','), '...', seen.slice(-6).join(','));
console.log('after walk', m.size, order(m));

// forEach deleting and adding
const f = new Map<number, number>();
for (let i = 0; i < 64; i++) f.set(i, i);
const fe: number[] = [];
f.forEach((v, k) => {
  fe.push(k);
  if (k % 2 === 0) { f.delete(k + 1); f.delete(k); }
  if (k === 10) f.set(100, 100);
});
console.log('forEach', fe.length, fe.slice(0, 8).join(','), fe.slice(-3).join(','), 'size', f.size);

// a Set, the same way
const s = new Set<string>();
for (let i = 0; i < 40; i++) s.add('k' + i);
const ss: string[] = [];
for (const k of s) {
  ss.push(k);
  for (let j = 0; j < 40; j += 2) s.delete('k' + j);
  if (k === 'k1') s.add('late');
}
console.log('set walk', ss.join(','), 'size', s.size);

// clear during a walk: the walk goes on with what is added after
const c = new Map<number, number>();
for (let i = 0; i < 30; i++) c.set(i, i);
const cs: number[] = [];
for (const [k] of c) {
  cs.push(k);
  if (k === 3) { c.clear(); for (let i = 50; i < 54; i++) c.set(i, i); }
}
console.log('clear walk', cs.join(','));

// an iterator left half way, resumed after churn
const h = new Map<number, number>();
for (let i = 0; i < 40; i++) h.set(i, i);
const it = h.keys();
const firstFive = [it.next().value, it.next().value, it.next().value, it.next().value, it.next().value];
for (let i = 0; i < 35; i++) h.delete(i);
for (let r = 0; r < 100; r++) { h.set(1000 + r, r); h.delete(1000 + r - 1); }
const rest: number[] = [];
for (let r = it.next(); !r.done; r = it.next()) rest.push(r.value);
console.log('resumed', firstFive.join(','), '|', rest.join(','));

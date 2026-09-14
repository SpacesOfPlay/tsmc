// object literals: fresh records with fixed keys, kept in an array and read
// back, which is what parsing and mapping do -- and what stops an engine from
// eliding the allocation. `objprop` covers the other spelling, where the keys
// are computed at run time.
let n = 0;
for (let round = 0; round < 900; round++) {
  const rows = [];
  for (let i = 0; i < 1000; i++) {
    rows.push({ id: i, name: 'n', kind: 'k', price: 1.5, ok: (i & 3) !== 0, meta: null });
  }
  for (let i = 0; i < rows.length; i++) {
    const r = rows[i];
    n = (n + r.id + (r.ok ? 1 : 0)) | 0;
  }
}
console.log(n);

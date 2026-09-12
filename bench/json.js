// JSON round-trip over a nested structure: the shape a config file or an API
// response has. Both directions walk every value.
const row = (i) => ({
  id: i, name: 'row ' + i, on: (i & 1) === 0, score: i / 7,
  tags: ['a', 'b', 'c'].map((t) => t + i), nested: { depth: { value: i, note: null } },
});
const data = { rows: [], total: 0 };
for (let i = 0; i < 2000; i++) data.rows.push(row(i));
let acc = 0;
for (let iter = 0; iter < 17; iter++) {
  const text = JSON.stringify(data);
  const back = JSON.parse(text);
  acc = (acc + text.length + back.rows.length + back.rows[iter].nested.depth.value) | 0;
}
console.log(acc);

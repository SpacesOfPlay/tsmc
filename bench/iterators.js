// Generators and the protocol around them: for-of, spread and destructuring
// all step an iterator one call at a time.
function* range(n) { for (let i = 0; i < n; i++) yield i; }
function* pairs(n) { for (let i = 0; i < n; i++) yield [i, i * 2]; }
let acc = 0;
for (let iter = 0; iter < 2200; iter++) {
  for (const v of range(200)) acc = (acc + v) | 0;
  for (const [k, v] of pairs(100)) acc = (acc + k + v) | 0;
  const spread = [...range(100)];
  acc = (acc + spread.length + spread[50]) | 0;
  const [first, second, ...rest] = range(50);
  acc = (acc + first + second + rest.length) | 0;
}
console.log(acc);

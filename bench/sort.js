// Array#sort with a comparator: every comparison is a call back into the
// interpreter, so this measures call overhead as much as the sort.
function mk(n, seed) {
  const a = [];
  let x = seed;
  for (let i = 0; i < n; i++) { x = (x * 1103515245 + 12345) & 0x3fffffff; a.push(x); }
  return a;
}
let acc = 0;
for (let iter = 0; iter < 6; iter++) {
  const nums = mk(2000, iter + 1);
  nums.sort((p, q) => p - q);
  const strs = nums.map(String);
  strs.sort();
  const objs = nums.map((v) => ({ v }));
  objs.sort((p, q) => q.v - p.v);
  acc = (acc + nums[0] + strs[0].length + objs[0].v) | 0;
}
console.log(acc);

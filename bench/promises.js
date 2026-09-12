// Promise and await churn: each step is a microtask, so this measures the job
// queue as much as the promise objects.
async function step(i) { return (await i) + 1; }
async function chain(n) {
  let v = 0;
  for (let i = 0; i < n; i++) v = await step(v);
  return v;
}
async function main() {
  let acc = 0;
  for (let iter = 0; iter < 1300; iter++) {
    acc = (acc + (await chain(200))) | 0;
    const all = await Promise.all([chain(20), chain(20), chain(20)]);
    acc = (acc + all[0] + all[1] + all[2]) | 0;
    acc = (acc + (await Promise.resolve(1).then((x) => x + 1).then((x) => x * 2))) | 0;
  }
  console.log(acc);
}
main();

// performance.eventLoopUtilization: zero before the loop runs, then the
// share of the loop's time spent running rather than waiting. A callback
// that busies the loop for 100 ms between two 100 ms waits reads as about
// half, alone and as the difference of two readings. Only relations are
// printed, so the output does not depend on the machine's speed.

const { performance } = require('perf_hooks');
const a = performance.eventLoopUtilization();
console.log(Object.keys(a).join(','), a.utilization, a.idle, a.active);
let spin = 0;
setTimeout(() => {
  const t = Date.now();
  while (Date.now() - t < 100) spin++;
  setTimeout(() => {
    const b = performance.eventLoopUtilization();
    const d = performance.eventLoopUtilization(b, a);
    const e = performance.eventLoopUtilization(b);
    console.log('in range', b.utilization > 0 && b.utilization < 1);
    console.log('busy counted', d.active > 90);
    console.log('wait counted', d.idle > 90);
    console.log('about half', Math.abs(d.utilization - 0.5) < 0.2);
    console.log('since a reading', e.idle >= 0 && e.active >= 0 && e.utilization >= 0 && e.utilization <= 1);
  }, 100);
}, 1);

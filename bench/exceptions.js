// throw and catch in a loop, and a try block that does not throw: the cost of
// entering a protected region against the cost of unwinding one.
function risky(i) { if ((i & 15) === 0) { throw new RangeError('at ' + i); } return i; }
let caught = 0;
let acc = 0;
for (let i = 0; i < 120000; i++) {
  try { acc = (acc + risky(i)) | 0; }
  catch (e) { caught++; acc = (acc + e.message.length) | 0; }
  finally { acc = (acc + 1) | 0; }
}
console.log(caught, acc);

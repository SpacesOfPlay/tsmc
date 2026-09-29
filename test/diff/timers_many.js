// Many timers set and cleared: the runtime drops dead timers from its list
// and finds a timer by id without a scan, so the survivors must keep their
// order, and clear, refresh and ref must still find the right one, after
// thousands have come and gone around them. Nothing here depends on how
// fast the script runs: the check timer is set first and so is due first,
// and the report waits for the last event it counts.

const out = [];
const kept = [];
let ticks = 0;
let fired = 0;

function report() {
  if (fired !== 29 || ticks !== 3) return;
  console.log('fired ' + fired);
  console.log(out.join('\n'));
  console.log(out.includes('kept 300') ? 'cleared late: still fired' : 'cleared late: gone');
  console.log(out.includes('kept 700') ? 'refreshed: fired' : 'refreshed: missing');
}

// Due before any of the timers below, whenever they are set. It runs
// after the first turn of the loop, once the cleared timers are gone.
setTimeout(() => {
  clearTimeout(kept[3]);
  clearTimeout(kept[3]);
  out.push('hasRef ' + kept[5].hasRef());
  kept[5].unref();
  out.push('after unref ' + kept[5].hasRef());
  kept[5].ref();
  kept[7].refresh();
}, 0);

// 3000 timeouts; all but every hundredth are cleared at once.
for (let i = 0; i < 3000; i++) {
  const t = setTimeout(() => { fired++; out.push('kept ' + i); report(); }, 30);
  if (i % 100 === 0) kept.push(t); else clearTimeout(t);
}

// Churn in later turns: set and clear, as a server does per request.
let turns = 0;
function churn() {
  for (let k = 0; k < 500; k++) clearTimeout(setTimeout(() => out.push('never'), 1));
  if (++turns < 6) setImmediate(churn);
}
setImmediate(churn);

// An interval that stops itself amid the churn.
const iv = setInterval(() => {
  ticks++;
  for (let k = 0; k < 200; k++) clearTimeout(setTimeout(() => out.push('never'), 1000));
  if (ticks === 3) { clearInterval(iv); report(); }
}, 2);

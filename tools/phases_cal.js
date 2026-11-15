// A known composition for the phase accounting (tsmc --phases): each section
// is one kind of time, and prints its own wall clock so the report can be
// checked against it. Run one section with `-- <name>`, or all.
//
//   loop       a counted loop, nothing but the interpreter
//   natives    a cheap builtin called many times: the switch cost per call,
//              and the native's own time, which should be near nothing
//   callbacks  a builtin calling back into JS: the callback's time is the
//              interpreter's, the builtin's own time stays small
//   garbage    allocation that the collector has to run for
//
// The lazy, compile and cache phases wrap the same code as the engine's
// own counters for them, which a trace prints beside the report; they are
// checked against those.
const args = typeof process !== "undefined" ? process.argv.slice(2).filter((a) => a !== "--") : [];
const which = args.length > 0 ? args : ["loop", "natives", "callbacks", "garbage"];

function loop(n) { let s = 0; for (let i = 0; i < n; i++) { s = (s + i) | 0; } return s; }
function natives(n) { let s = 0; const abs = Math.abs; for (let i = 0; i < n; i++) { s += abs(-i); } return s; }
function callbacks(n) {
  const a = new Array(1000).fill(1);
  let s = 0;
  for (let i = 0; i < n / 1000; i++) { s += a.reduce((x, y) => x + y, 0); }
  return s;
}
function garbage(n) {
  let keep = [];
  for (let i = 0; i < n; i++) { keep.push({ a: i, b: [i, i + 1] }); if (keep.length > 20000) { keep = []; } }
  return keep.length;
}

const sizes = { loop: 60000000, natives: 4000000, callbacks: 4000000, garbage: 1500000 };
const fns = { loop, natives, callbacks, garbage };
for (const name of which) {
  const t0 = Date.now();
  const r = fns[name](sizes[name]);
  console.log(name + ": " + (Date.now() - t0) + " ms (" + r + ")");
}

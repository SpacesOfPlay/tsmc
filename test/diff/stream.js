// stream: Readable / Writable / Transform / PassThrough / pipeline.
// Scenarios are SEQUENCED (each starts when the prior finishes) so the
// output order is deterministic; the per-scenario aggregate results match
// Node's native streams even though internal scheduling differs.
const stream = require("stream");
const { Readable, Writable, Transform, PassThrough } = stream;

function readableFrom(next) {
  const got = [];
  const r = Readable.from(["a", "b", "c"]);
  r.on("data", (c) => got.push(c));
  r.on("end", () => { console.log("readable:", got.join(",")); next(); });
}

function writable(next) {
  const chunks = [];
  const w = new Writable({ write(chunk, enc, cb) { chunks.push(chunk); cb(); } });
  w.on("finish", () => { console.log("writable:", chunks.join("")); next(); });
  w.write("x"); w.write("y"); w.end("z");
}

function transformPipe(next) {
  const up = new Transform({ transform(chunk, enc, cb) { cb(null, String(chunk).toUpperCase()); } });
  const out = [];
  const sink = new Writable({ write(c, e, cb) { out.push(c); cb(); } });
  sink.on("finish", () => { console.log("transform:", out.join("")); next(); });
  Readable.from(["hello", " ", "world"]).pipe(up).pipe(sink);
}

function passthrough(next) {
  const pt = new PassThrough();
  const out = [];
  pt.on("data", (c) => out.push(c));
  pt.on("end", () => { console.log("passthrough:", out.join("")); next(); });
  pt.write("1"); pt.write("2"); pt.end("3");
}

function transformFlush(next) {
  const t = new Transform({
    transform(c, e, cb) { cb(null, c + "-"); },
    flush(cb) { cb(null, "END"); },
  });
  const out = [];
  t.on("data", (c) => out.push(c));
  t.on("end", () => { console.log("flush:", out.join("")); next(); });
  t.write("a"); t.write("b"); t.end();
}

function pipelineScenario(next) {
  const acc = [];
  stream.pipeline(
    Readable.from(["p", "q"]),
    new Transform({ transform(c, e, cb) { cb(null, c + "!"); } }),
    new Writable({ write(c, e, cb) { acc.push(c); cb(); } }),
    (err) => { console.log("pipeline:", err ? "err" : acc.join(",")); next(); }
  );
}

function objectMode(next) {
  const r = Readable.from([{ n: 1 }, { n: 2 }]);
  const sums = [];
  const w = new Writable({ objectMode: true, write(obj, e, cb) { sums.push(obj.n); cb(); } });
  w.on("finish", () => { console.log("object:", sums.reduce((a, b) => a + b, 0)); next(); });
  r.pipe(w);
}

// run all scenarios in sequence
const scenarios = [readableFrom, writable, transformPipe, passthrough, transformFlush, pipelineScenario, objectMode];
let i = 0;
function next() { if (i < scenarios.length) scenarios[i++](next); }
next();

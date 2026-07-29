// stream: reading, writing, piping, transforming, and how failure travels.
//
// Each case runs to completion before the next starts and reports one line, so
// the output is ordered even though the work is not synchronous.

const stream = require('stream');

const out = [];

function show(v) {
  if (v === undefined) return 'undefined';
  if (v === null) return 'null';
  if (typeof v === 'string') return JSON.stringify(v);
  if (Array.isArray(v)) return '[' + v.map(show).join(', ') + ']';
  if (typeof v === 'object') { try { return JSON.stringify(v); } catch (e) { return String(v); } }
  return String(v);
}

function T(label, v) { out.push(label + ' = ' + show(v)); }

const settle = (fn) => new Promise((resolve) => {
  let done = false;
  const finish = (v) => { if (!done) { done = true; resolve(v); } };
  try { fn(finish); } catch (e) { finish('THROW:' + (e && e.constructor ? e.constructor.name : String(e))); }
  setTimeout(() => finish('TIMEOUT'), 3000);
});

// A readable that yields the given chunks and ends.
function readableOf(chunks, opts) {
  const r = new stream.Readable(Object.assign({ read() {} }, opts || {}));
  for (const c of chunks) r.push(c);
  r.push(null);
  return r;
}

// A writable that records what it is given.
function collector(opts) {
  const seen = [];
  const w = new stream.Writable(Object.assign({
    write(chunk, enc, cb) { seen.push(chunk); cb(); },
  }, opts || {}));
  w.seen = seen;
  return w;
}

async function main() {
  T('module-exports', ['Readable', 'Writable', 'Duplex', 'Transform', 'PassThrough',
                       'pipeline', 'finished']
    .map((k) => k + ':' + typeof stream[k]).join(' '));

  // --- reading --------------------------------------------------------------

  T('read-data-events', await settle((done) => {
    const seen = [];
    const r = readableOf(['a', 'b', 'c']);
    r.on('data', (c) => seen.push(c.toString()));
    r.on('end', () => done(seen.join('')));
  }));

  T('read-end-fires-once', await settle((done) => {
    let ends = 0;
    const r = readableOf(['x']);
    r.on('data', () => {});
    r.on('end', () => { ends++; setTimeout(() => done(ends), 20); });
  }));

  T('read-chunks-are-buffers', await settle((done) => {
    const r = readableOf(['ab']);
    r.on('data', (c) => done([Buffer.isBuffer(c), c.length]));
  }));

  T('read-objectMode-keeps-values', await settle((done) => {
    const seen = [];
    const r = readableOf([{ n: 1 }, { n: 2 }], { objectMode: true });
    r.on('data', (o) => seen.push(o.n));
    r.on('end', () => done(seen));
  }));

  T('read-empty-stream', await settle((done) => {
    const r = readableOf([]);
    let any = false;
    r.on('data', () => { any = true; });
    r.on('end', () => done(['ended', any]));
  }));

  T('readable-from', await settle((done) => {
    if (typeof stream.Readable.from !== 'function') { done('missing'); return; }
    const seen = [];
    const r = stream.Readable.from(['p', 'q']);
    r.on('data', (c) => seen.push(c.toString()));
    r.on('end', () => done(seen.join('')));
  }));

  T('async-iteration', await settle(async (done) => {
    const r = readableOf(['1', '2', '3']);
    if (typeof r[Symbol.asyncIterator] !== 'function') { done('missing'); return; }
    const seen = [];
    for await (const c of r) seen.push(c.toString());
    done(seen.join(''));
  }));

  // --- writing --------------------------------------------------------------

  T('write-and-finish', await settle((done) => {
    const w = collector();
    w.on('finish', () => done(w.seen.map((b) => b.toString()).join('')));
    w.write('one');
    w.write('two');
    w.end();
  }));

  T('write-end-with-chunk', await settle((done) => {
    const w = collector();
    w.on('finish', () => done(w.seen.map((b) => b.toString()).join('')));
    w.end('last');
  }));

  T('write-returns-boolean', await settle((done) => {
    const w = collector();
    const r = w.write('x');
    w.end();
    done(typeof r);
  }));

  T('write-objectMode', await settle((done) => {
    const w = collector({ objectMode: true });
    w.on('finish', () => done(w.seen.map((o) => o.n)));
    w.write({ n: 7 });
    w.end();
  }));

  // --- piping ---------------------------------------------------------------

  T('pipe-moves-everything', await settle((done) => {
    const w = collector();
    w.on('finish', () => done(w.seen.map((b) => b.toString()).join('')));
    readableOf(['pi', 'pe']).pipe(w);
  }));

  T('pipe-returns-destination', await settle((done) => {
    const w = collector();
    const r = readableOf(['x']);
    done(r.pipe(w) === w);
  }));

  T('pipe-through-passthrough', await settle((done) => {
    const w = collector();
    w.on('finish', () => done(w.seen.map((b) => b.toString()).join('')));
    readableOf(['a', 'b']).pipe(new stream.PassThrough()).pipe(w);
  }));

  T('transform-maps-chunks', await settle((done) => {
    const upper = new stream.Transform({
      transform(chunk, enc, cb) { cb(null, chunk.toString().toUpperCase()); },
    });
    const w = collector();
    w.on('finish', () => done(w.seen.map((b) => b.toString()).join('')));
    readableOf(['ab', 'cd']).pipe(upper).pipe(w);
  }));

  T('transform-can-drop', await settle((done) => {
    const evens = new stream.Transform({
      objectMode: true,
      transform(n, enc, cb) { if (n % 2 === 0) cb(null, n); else cb(); },
    });
    const w = collector({ objectMode: true });
    w.on('finish', () => done(w.seen));
    readableOf([1, 2, 3, 4], { objectMode: true }).pipe(evens).pipe(w);
  }));

  // --- completion and failure ----------------------------------------------

  T('pipeline-success', await settle((done) => {
    if (typeof stream.pipeline !== 'function') { done('missing'); return; }
    const w = collector();
    stream.pipeline(readableOf(['x', 'y']), new stream.PassThrough(), w, (err) => {
      done([err ? 'err' : 'ok', w.seen.map((b) => b.toString()).join('')]);
    });
  }));

  T('pipeline-reports-failure', await settle((done) => {
    if (typeof stream.pipeline !== 'function') { done('missing'); return; }
    const bad = new stream.Transform({
      transform(chunk, enc, cb) { cb(new Error('nope')); },
    });
    stream.pipeline(readableOf(['x']), bad, collector(), (err) => {
      done(err ? err.message : 'no-error');
    });
  }));

  T('finished-callback', await settle((done) => {
    if (typeof stream.finished !== 'function') { done('missing'); return; }
    const r = readableOf(['z']);
    stream.finished(r, (err) => done(err ? 'err' : 'done'));
    r.on('data', () => {});
  }));

  T('error-event-on-readable', await settle((done) => {
    const r = new stream.Readable({ read() {} });
    r.on('error', (e) => done(e.message));
    r.destroy(new Error('broke'));
  }));

  T('destroy-marks-destroyed', await settle((done) => {
    const r = new stream.Readable({ read() {} });
    r.on('error', () => {});
    r.destroy();
    setTimeout(() => done(r.destroyed === true), 10);
  }));

  // --- interop with the modules built on streams ----------------------------

  T('http-response-is-writable', (() => {
    const http = require('http');
    return typeof http.ServerResponse === 'function' || 'not-exported';
  })());

  console.log(out.join('\n'));
}

main();

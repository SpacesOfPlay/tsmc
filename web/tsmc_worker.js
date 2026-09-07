// tsmc_worker.js — one run per message. A run holds the worker until the
// script finishes, so the page ends a runaway script by terminating the
// worker and starting another. Packages a script imports are fetched
// before the run and kept for the worker's lifetime.
//
// in:  { type: 'init', module } or { type: 'init', url }
//      { type: 'run', files, args }
// out: { type: 'status', text }
//      { type: 'out', fd, text }
//      { type: 'exit', code, ms, fetchMs, packages, requests, bytes }

importScripts('tsmc_host.js', 'cdn_fs.js');

let ready = null;
let cdn = null;

self.onmessage = async (e) => {
  const m = e.data;
  if (m.type === 'init') {
    ready = m.module
      ? Promise.resolve(m.module)
      : fetch(m.url).then((r) => r.arrayBuffer()).then((b) => WebAssembly.compile(b));
    cdn = TsmcCdnFs.create({ onProgress: (text) => postMessage({ type: 'status', text }) });
    return;
  }
  if (m.type !== 'run') return;
  const write = (fd, text) => postMessage({ type: 'out', fd, text });
  try {
    const module = await ready;
    const before = cdn.stats();
    const t0 = performance.now();
    await cdn.prefetch(TsmcCdnFs.scan(Object.values(m.files).join('\n')));
    const fetchMs = performance.now() - t0;
    const base = TsmcHost.memoryFs(m.files);
    // the packages this run read from, not everything the worker has loaded
    const used = new Set();
    const view = {
      read: (p) => {
        const r = base.read(p) || cdn.read(p);
        if (r && p.startsWith('/node_modules/')) used.add(TsmcCdnFs.packageName(p.slice('/node_modules/'.length)));
        return r;
      },
      stat: (p) => base.stat(p) || cdn.stat(p),
    };
    const r = await TsmcHost.run(module, { fs: view, args: m.args, write });
    const after = cdn.stats();
    postMessage({
      type: 'exit', code: r.code, ms: r.ms, fetchMs,
      packages: cdn.packages().filter((p) => used.has(p.key)),
      requests: after.requests - before.requests, bytes: after.bytes - before.bytes,
    });
  } catch (e) {
    // a failure to load or instantiate, not a script error
    write(2, 'tsmc host: ' + ((e && e.message) || String(e)) + '\n');
    postMessage({ type: 'exit', code: 134, ms: 0, fetchMs: 0, packages: [], requests: 0, bytes: 0 });
  }
};

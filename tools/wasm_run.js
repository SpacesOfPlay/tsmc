// node tools/wasm_run.js build/tsmc.wasm [--cdn] <script.ts> [args...]
//
// Runs the wasm build with the current directory mounted as "/", so a
// script path is given the way it would be to the native binary. Output
// and the exit code pass straight through. With --cdn, bare imports are
// served from npm the way the playground serves them; the blocking
// fallback goes through curl.
'use strict';
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const TsmcHost = require('../web/tsmc_host.js');
const TsmcCdnFs = require('../web/cdn_fs.js');

let args = process.argv.slice(2);
const wasmPath = args.shift();
const cdn = args[0] === '--cdn';
if (cdn) args.shift();
if (!wasmPath || !args[0]) {
  process.stderr.write('usage: node tools/wasm_run.js <tsmc.wasm> [--cdn] <script> [args...]\n');
  process.exit(2);
}

const root = process.cwd();
const real = (p) => path.join(root, p);
const disk = {
  read: (p) => { try { return fs.readFileSync(real(p)); } catch (e) { return null; } },
  stat: (p) => {
    try { const s = fs.statSync(real(p)); return { dir: s.isDirectory(), size: s.size }; }
    catch (e) { return null; }
  },
};
const write = (fd, text) => (fd === 2 ? process.stderr : process.stdout).write(text);

function curlSync(url) {
  try {
    const out = execFileSync('curl', ['-sSL', '--max-time', '60', '-w', '\n%{http_code}', url], { maxBuffer: 256 << 20 });
    const nl = out.lastIndexOf(10);
    return { status: Number(out.subarray(nl + 1).toString().trim()), body: out.subarray(0, nl) };
  } catch (e) {
    return { status: 0, body: null };
  }
}

(async () => {
  let view = disk;
  if (cdn) {
    const packages = TsmcCdnFs.create({ fetchSync: curlSync, onProgress: (t) => process.stderr.write(t + '\n') });
    let source = '';
    try { source = fs.readFileSync(args[0], 'utf8'); } catch (e) {}
    await packages.prefetch(TsmcCdnFs.scan(source));
    view = {
      read: (p) => disk.read(p) || packages.read(p),
      stat: (p) => disk.stat(p) || packages.stat(p),
    };
  }
  if (process.env.WASM_TRACE) {
    // every probe the interpreter makes, for resolver debugging
    const inner = view;
    const show = (r) => (r ? (r.dir === undefined ? r.length + ' bytes' : JSON.stringify(r)) : 'null');
    view = {
      read: (p) => { const r = inner.read(p); process.stderr.write('read ' + p + ' -> ' + show(r) + '\n'); return r; },
      stat: (p) => { const r = inner.stat(p); process.stderr.write('stat ' + p + ' -> ' + show(r) + '\n'); return r; },
    };
  }
  const r = await TsmcHost.run(fs.readFileSync(wasmPath), { fs: view, args, write });
  process.exitCode = r.code;
})();

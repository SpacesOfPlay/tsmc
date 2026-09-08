// Runs the playground's example scripts through the wasm build under node.
//
//   node tools/examples_check.js <tsmc.wasm> [--cdn]
//
// Each example block in web/index.html carries data-expect, a line its
// output must contain, and may carry data-exit (default 0) and data-skip.
// Without --cdn only the examples with no bare import run, so the check
// needs no network; with it every example runs, and the packages come from
// the live registry the way they do in the page.
'use strict';
const fs = require('fs');
const path = require('path');
const cp = require('child_process');

const root = path.join(__dirname, '..');
let args = process.argv.slice(2);
const cdn = args.includes('--cdn');
args = args.filter((a) => a !== '--cdn');
const wasm = path.resolve(args[0] || path.join(root, 'build', 'tsmc.wasm'));
const html = fs.readFileSync(path.join(root, 'web', 'index.html'), 'utf8');

const unescape = (s) => s.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"')
  .replace(/&#39;/g, "'").replace(/&amp;/g, '&');
const attr = (attrs, name) => {
  const m = new RegExp(name + '="([^"]*)"').exec(attrs);
  return m ? unescape(m[1]) : null;
};
const blocks = /<script type="text\/plain" id="(ex-[a-z-]+)"([^>]*)>\n?([\s\S]*?)<\/script>/g;
const outDir = path.join(root, 'build', 'examples');
let ran = 0, fails = 0, skipped = 0;

for (const m of html.matchAll(blocks)) {
  const [, id, attrs, src] = m;
  const label = id.padEnd(12);
  const skip = attr(attrs, 'data-skip');
  if (skip !== null) { console.log('skip  ' + label + ' (' + skip + ')'); skipped++; continue; }
  const bare = /^\s*import\b[^;]*from\s+["'](?![./])/m.test(src);
  if (bare && !cdn) { console.log('skip  ' + label + ' (needs npm; run with --cdn)'); skipped++; continue; }
  const expect = attr(attrs, 'data-expect');
  if (expect === null) { console.log('FAIL  ' + label + ' has no data-expect'); fails++; continue; }
  const wantExit = Number(attr(attrs, 'data-exit') || 0);

  const dir = path.join(outDir, id);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'main.ts'), src);
  const runArgs = [path.join(root, 'tools', 'wasm_run.js'), wasm];
  if (bare) runArgs.push('--cdn');
  runArgs.push('main.ts');
  const t0 = Date.now();
  const r = cp.spawnSync(process.execPath, runArgs, { cwd: dir, encoding: 'utf8', timeout: 120000 });
  const ms = Date.now() - t0;
  const out = (r.stdout || '') + (r.stderr || '');
  const ok = r.status === wantExit && out.includes(expect);
  ran++;
  if (!ok) fails++;
  console.log((ok ? 'ok    ' : 'FAIL  ') + label + ' exit ' + r.status + '  ' + ms + ' ms');
  if (!ok) {
    console.log('      expected exit ' + wantExit + ' and a line containing: ' + expect);
    console.log('      ' + out.trim().split('\n').slice(-4).join('\n      '));
  }
}
console.log(ran + ' ran, ' + fails + ' failed, ' + skipped + ' skipped');
process.exit(fails ? 1 : 0);

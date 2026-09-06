// node tools/cdn_fs_check.js build/tsmc.wasm
//
// Checks the package view without a network: a fake registry made of
// tarballs built here serves an ESM package with an exports map, a CJS
// dependency it declares a range for, a scoped package with a file whose
// path needs a pax header, and a package that only the blocking fallback
// can see. The checks end with a script run through the wasm build that
// imports all four. Exits 0 when everything holds.
'use strict';
const fs = require('fs');
const zlib = require('zlib');
const TsmcHost = require('../web/tsmc_host.js');
const CdnFs = require('../web/cdn_fs.js');

const wasmPath = process.argv[2];
let failed = 0;
const check = (cond, what) => { if (!cond) { failed++; console.log('FAIL ' + what); } };
const eq = (a, b, what) => check(JSON.stringify(a) === JSON.stringify(b), what + ': got ' + JSON.stringify(a) + ', want ' + JSON.stringify(b));

// --- a tar writer, enough for npm-shaped archives -----------------------

function entry(name, body, type) {
  const h = Buffer.alloc(512);
  h.write(name, 0, 100, 'utf8');
  h.write('0000644\0', 100); h.write('0000000\0', 108); h.write('0000000\0', 116);
  h.write(body.length.toString(8).padStart(11, '0') + '\0', 124);
  h.write('00000000000\0', 136);
  h.write('        ', 148);
  h.write(type, 156);
  h.write('ustar\0', 257); h.write('00', 263);
  let sum = 0;
  for (const b of h) sum += b;
  h.write(sum.toString(8).padStart(6, '0') + '\0 ', 148);
  return Buffer.concat([h, body, Buffer.alloc((512 - (body.length % 512)) % 512)]);
}
function pax(path) {
  const rec = ' path=' + path + '\n';
  let len = rec.length + 2;
  while ((String(len) + rec).length !== len) len++;
  return entry('./PaxHeader', Buffer.from(String(len) + rec), 'x');
}
function tarball(files) {
  const parts = [];
  for (const [name, content] of Object.entries(files)) {
    const full = 'package/' + name;
    if (full.length > 100) { parts.push(pax(full)); parts.push(entry('package/long', Buffer.from(content), '0')); }
    else parts.push(entry(full, Buffer.from(content), '0'));
  }
  parts.push(Buffer.alloc(1024));
  return zlib.gzipSync(Buffer.concat(parts));
}

// --- the fake registry ---------------------------------------------------

const LONG = 'lib/' + 'x'.repeat(120) + '.js';
const registry = {
  'alpha': { version: '1.2.0', files: {
    'package.json': JSON.stringify({ name: 'alpha', version: '1.2.0', type: 'module',
      exports: { import: './esm/index.js', require: './cjs/index.cjs' }, dependencies: { beta: '^2.0.0' } }),
    'esm/index.js': "import beta from 'beta';\nexport const greet = (n) => 'hello ' + n + ' from alpha ' + beta.twice(2);\n",
    'cjs/index.cjs': "module.exports = { greet: () => 'cjs' };\n",
  } },
  'beta': { version: '2.3.1', files: {
    'package.json': JSON.stringify({ name: 'beta', version: '2.3.1', main: 'lib/main.js' }),
    'lib/main.js': "module.exports = { twice: (x) => x * 2, name: 'beta' };\n",
  } },
  '@acme/gamma': { version: '0.1.0', files: {
    'package.json': JSON.stringify({ name: '@acme/gamma', version: '0.1.0', main: 'index.js' }),
    'index.js': "module.exports = { label: 'gamma', long: require('./" + LONG + "') };\n",
    [LONG]: "module.exports = 'from a long path';\n",
  } },
  'delta': { version: '3.0.0', files: {
    'package.json': JSON.stringify({ name: 'delta', version: '3.0.0', main: 'delta.js' }),
    'delta.js': "module.exports = { value: 'delta-3' };\n",
  } },
};
const specifiers = [];
const asyncUrls = [];
const syncUrls = [];

function answer(url) {
  let m = url.match(/^https:\/\/data\.jsdelivr\.com\/v1\/packages\/npm\/(.+)\/resolved\?specifier=(.+)$/);
  if (m) {
    const name = decodeURIComponent(m[1]);
    specifiers.push(name + ' ' + decodeURIComponent(m[2]));
    const p = registry[name];
    return p ? { status: 200, body: Buffer.from(JSON.stringify({ version: p.version })) } : { status: 404, body: null };
  }
  m = url.match(/^https:\/\/registry\.npmjs\.org\/(.+)\/-\/([^/]+)-([\d.]+)\.tgz$/);
  if (m) {
    const p = registry[m[1]];
    if (!p || p.version !== m[3] || m[2] !== m[1].split('/').pop()) return { status: 404, body: null };
    if (m[1] === 'delta') return { status: 404, body: null };   // only the fallback serves delta
    return { status: 200, body: tarball(p.files) };
  }
  m = url.match(/^https:\/\/data\.jsdelivr\.com\/v1\/packages\/npm\/(.+)@([\d.]+)\?structure=flat$/);
  if (m) {
    const p = registry[m[1]];
    if (!p) return { status: 404, body: null };
    const files = Object.entries(p.files).map(([n, c]) => ({ name: '/' + n, size: Buffer.byteLength(c) }));
    return { status: 200, body: Buffer.from(JSON.stringify({ files })) };
  }
  m = url.match(/^https:\/\/cdn\.jsdelivr\.net\/npm\/(.+)@([\d.]+)(\/.+)$/);
  if (m) {
    const p = registry[m[1]];
    const c = p && p.files[m[3].slice(1)];
    return c !== undefined ? { status: 200, body: Buffer.from(c) } : { status: 404, body: null };
  }
  return { status: 404, body: null };
}
const fetchAsync = async (url) => { asyncUrls.push(url); return answer(url); };
const fetchSync = (url) => { syncUrls.push(url); return answer(url); };

// --- the checks ----------------------------------------------------------

(async () => {
  eq(CdnFs.scan("import a from 'alpha';\nimport fs from 'fs';\nimport { x } from '@acme/gamma/sub';\nconst y = require('./local');\nimport('beta/deep/path');\nimport 'node:path';\n"),
    ['alpha', '@acme/gamma', 'beta'], 'scan');
  eq(CdnFs.packageName('@acme'), null, 'a bare scope is not a package');

  const files = CdnFs.untar(zlib.gunzipSync(tarball(registry['@acme/gamma'].files)));
  eq([...files.keys()], ['/package.json', '/index.js', '/' + LONG], 'untar paths, pax name included');
  eq(Buffer.from(files.get('/' + LONG)).toString(), registry['@acme/gamma'].files[LONG], 'untar content');

  const view = CdnFs.create({ fetchAsync, fetchSync });
  await view.prefetch(['alpha', '@acme/gamma', 'fs']);
  eq(specifiers, ['alpha latest', '@acme/gamma latest', 'beta ^2.0.0'], 'versions asked with the declared ranges');
  eq(view.packages().map((p) => p.name + '@' + p.version), ['alpha@1.2.0', '@acme/gamma@0.1.0', 'beta@2.3.1'], 'closure loaded');
  eq(syncUrls.length, 0, 'prefetch made no blocking request');

  eq(view.stat('/node_modules'), { dir: true, size: 0 }, 'node_modules is a directory');
  eq(view.stat('/node_modules/alpha'), { dir: true, size: 0 }, 'package root is a directory');
  eq(view.stat('/node_modules/alpha/esm'), { dir: true, size: 0 }, 'package subdirectory');
  eq(view.stat('/node_modules/alpha/esm/index.js').dir, false, 'package file');
  eq(view.stat('/node_modules/alpha/node_modules/beta'), null, 'nested node_modules is not found');
  eq(view.stat('/node_modules/alpha/nope.js'), null, 'missing file');
  eq(view.read('/node_modules/alpha'), null, 'reading a directory');
  eq(Buffer.from(view.read('/node_modules/beta/lib/main.js')).toString().includes('twice'), true, 'read a dependency file');

  const before = specifiers.length;
  eq(view.stat('/node_modules/nope'), null, 'unknown package');
  eq(view.stat('/node_modules/nope/index.js'), null, 'unknown package, again');
  eq(specifiers.length - before, 1, 'an unknown package is asked for once');

  eq(view.stat('/node_modules/delta').dir, true, 'fallback package appears through the listing');
  eq(Buffer.from(view.read('/node_modules/delta/delta.js')).toString().includes('delta-3'), true, 'fallback file fetched on read');
  check(syncUrls.some((u) => u.includes('cdn.jsdelivr.net/npm/delta@3.0.0/delta.js')), 'fallback read went to the CDN');

  eq(view.stat('/node_modules/beta@^2.0.0').dir, true, 'a range in the directory name loads the package');
  eq(specifiers[specifiers.length - 1], 'beta ^2.0.0', 'the range in the name is what gets resolved');
  eq(view.packages().filter((p) => p.name === 'beta').length, 2, 'the pinned copy is its own record');

  if (!wasmPath) { console.log(failed ? 'FAILED ' + failed : 'ok (no wasm run)'); process.exit(failed ? 1 : 0); }

  // --- through the interpreter --------------------------------------------
  const main = "import { greet } from 'alpha';\nimport { greet as pinned } from 'alpha@^1.0.0';\nimport gamma from '@acme/gamma';\nconsole.log(greet('world'));\nconsole.log(pinned('again'));\nconsole.log(gamma.label, gamma.long);\nconst name = 'del' + 'ta';\nconst d = await import(name);\nconsole.log(d.default.value);\n";
  const packages = CdnFs.create({ fetchAsync, fetchSync });
  await packages.prefetch(CdnFs.scan(main));
  const base = TsmcHost.memoryFs({ '/main.ts': main });
  const trace = process.env.CDN_TRACE ? (what, p, r) => console.log('  ' + what + ' ' + p + ' -> ' + (r ? (r.dir === undefined ? r.length + ' bytes' : JSON.stringify(r)) : 'null')) : () => {};
  const layered = {
    read: (p) => { const r = base.read(p) || packages.read(p); trace('read', p, r); return r; },
    stat: (p) => { const r = base.stat(p) || packages.stat(p); trace('stat', p, r); return r; },
  };
  let out = '';
  const r = await TsmcHost.run(fs.readFileSync(wasmPath), { fs: layered, args: ['main.ts'], write: (fd, t) => { out += t; } });
  eq(r.code, 0, 'exit code');
  eq(out, 'hello world from alpha 4\nhello again from alpha 4\ngamma from a long path\ndelta-3\n', 'output');
  eq(packages.packages().map((p) => p.name).sort(), ['@acme/gamma', 'alpha', 'alpha', 'beta', 'delta'], 'packages used by the run');

  console.log(failed ? 'FAILED ' + failed : 'ok');
  process.exit(failed ? 1 : 0);
})();

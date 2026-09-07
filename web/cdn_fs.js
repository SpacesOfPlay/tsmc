// cdn_fs.js — npm packages for the playground, served into the file view
// the way an installed tree would be. Before a run, the bare specifiers in
// the script are fetched as tarballs from the npm registry, in parallel,
// with versions resolved by the jsdelivr data API and dependencies taken
// from each package.json; the run then reads them from memory. A package
// the scan could not see is fetched during the run, file by file and
// synchronously, from the jsdelivr CDN. The first version of a package to
// load wins; a later request with another range gets the loaded one.
//
// create({ fetchAsync, fetchSync, onProgress }) ->
//   { prefetch(names), read(path), stat(path), packages(), stats() }
//   fetchAsync(url) -> Promise<{ status, body }>, body a Uint8Array
//   fetchSync(url)  -> { status, body }; pass null when nothing can block
//                      for a request, and the fallback is off
// Also exported: scan(source) -> package names, packageName(specifier),
// untar(bytes) -> Map(path -> Uint8Array), gunzip(bytes).

(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  root.TsmcCdnFs = api;
})(typeof self !== 'undefined' ? self : globalThis, function () {
  'use strict';

  const DATA = 'https://data.jsdelivr.com/v1/packages/npm/';
  const CDN = 'https://cdn.jsdelivr.net/npm/';
  const REGISTRY = 'https://registry.npmjs.org/';
  const dec = new TextDecoder();
  const enc = new TextEncoder();

  // the modules the runtime provides itself; never looked up on npm
  const BUILTINS = new Set(('assert async_hooks buffer child_process cluster console constants crypto ' +
    'dgram diagnostics_channel dns domain events fs http http2 https inspector module net os path ' +
    'perf_hooks process punycode querystring readline repl stream string_decoder sys timers tls ' +
    'trace_events tty url util v8 vm wasi worker_threads zlib test').split(' '));

  // "@scope/name/sub" -> "@scope/name"; "name/sub" -> "name"; null for a
  // relative or absolute path, a URL, a node: name, or a runtime module.
  function packageName(spec) {
    if (!spec || spec[0] === '.' || spec[0] === '/' || spec.includes(':')) return null;
    const segs = spec.split('/');
    if (segs[0][0] === '@') {
      if (segs.length < 2 || !segs[1]) return null;
      return segs[0] + '/' + segs[1];
    }
    return BUILTINS.has(segs[0]) ? null : segs[0];
  }

  // "name@^1.2" pins a range in the specifier itself; the package then
  // lives under that directory name, so the resolver needs no help.
  function versioned(name) {
    const at = name.indexOf('@', 1);
    if (at < 0) return { name, range: 'latest' };
    return { name: name.slice(0, at), range: name.slice(at + 1) || 'latest' };
  }

  const SPEC = /(?:\bfrom\s*|\bimport\s*\(?\s*|\brequire\s*\(\s*)(['"])([^'"\n]+)\1/g;
  function scan(source) {
    const names = new Set();
    for (const m of String(source).matchAll(SPEC)) {
      const n = packageName(m[2]);
      if (n) names.add(n);
    }
    return [...names];
  }

  // --- tar ------------------------------------------------------------

  function octal(bytes, off, len) {
    let s = '';
    for (let i = off; i < off + len; i++) {
      const c = bytes[i];
      if (c === 0 || c === 32) { if (s) break; continue; }
      s += String.fromCharCode(c);
    }
    return parseInt(s, 8) || 0;
  }
  function text(bytes, off, len) {
    let end = off;
    while (end < off + len && bytes[end] !== 0) end++;
    return dec.decode(bytes.subarray(off, end));
  }

  // The regular files of an npm tarball, keyed by path with the leading
  // "package/" segment replaced by "/". Reads ustar prefixes, pax and GNU
  // long names; skips directories and everything else.
  function untar(bytes) {
    const files = new Map();
    let longName = null;
    let i = 0;
    while (i + 512 <= bytes.length && bytes[i] !== 0) {
      const size = octal(bytes, i + 124, 12);
      const type = bytes[i + 156];
      let name = text(bytes, i, 100);
      const prefix = text(bytes, i + 345, 155);
      if (prefix && text(bytes, i + 257, 6).startsWith('ustar')) name = prefix + '/' + name;
      const data = bytes.subarray(i + 512, i + 512 + size);
      i += 512 + Math.ceil(size / 512) * 512;
      if (type === 76) { longName = text(data, 0, size); continue; }   // 'L'
      if (type === 120) {                                               // 'x'
        for (const line of dec.decode(data).split('\n')) {
          const eq = line.indexOf('=');
          if (eq > 0 && line.slice(line.indexOf(' ') + 1, eq) === 'path') longName = line.slice(eq + 1);
        }
        continue;
      }
      if (longName) { name = longName; longName = null; }
      if (type !== 48 && type !== 0) continue;                          // '0' or NUL
      const slash = name.indexOf('/');
      files.set(slash < 0 ? '/' + name : name.slice(slash), data);
    }
    return files;
  }

  async function gunzip(bytes) {
    const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream('gzip'));
    return new Uint8Array(await new Response(stream).arrayBuffer());
  }

  // --- transports -----------------------------------------------------

  async function fetchAsync(url) {
    try {
      const r = await fetch(url);
      return { status: r.status, body: r.ok ? new Uint8Array(await r.arrayBuffer()) : null };
    } catch (e) {
      return { status: 0, body: null };
    }
  }

  // A blocking request. Only a worker may make one, which is where runs
  // happen; the response type is honoured there, and text is re-encoded
  // where it is not.
  function xhrSync(url) {
    const x = new XMLHttpRequest();
    x.open('GET', url, false);
    try { x.responseType = 'arraybuffer'; } catch (e) {}
    try { x.send(); } catch (e) { return { status: 0, body: null }; }
    if (x.status !== 200) return { status: x.status, body: null };
    const body = x.response instanceof ArrayBuffer ? new Uint8Array(x.response) : enc.encode(String(x.responseText));
    return { status: 200, body };
  }

  // --- the view -------------------------------------------------------

  // "/node_modules/@scope/name/lib/x.js" -> { name: "@scope/name", rest: "/lib/x.js" }.
  // null off the top-level node_modules. A nested node_modules stays part
  // of the enclosing package's rest, where it is simply not found.
  function split(path) {
    path = path.replace(/\/{2,}/g, '/');
    if (!path.startsWith('/node_modules/')) return null;
    const segs = path.slice('/node_modules/'.length).split('/');
    const n = segs[0] && segs[0][0] === '@' ? 2 : 1;
    if (segs.length < n || segs.slice(0, n).some((s) => !s)) return null;
    // the walk from /node_modules itself asks for /node_modules/node_modules
    if (segs[0] === 'node_modules') return null;
    return { name: segs.slice(0, n).join('/'), rest: segs.length > n ? '/' + segs.slice(n).join('/') : '' };
  }

  function create(opts) {
    opts = opts || {};
    const getAsync = opts.fetchAsync || fetchAsync;
    const getSync = opts.fetchSync !== undefined ? opts.fetchSync
      : (typeof XMLHttpRequest === 'function' ? xhrSync : null);
    const progress = opts.onProgress || (() => {});
    const pkgs = new Map();      // name -> record; null while loading or when missing
    const order = [];
    const stats = { requests: 0, bytes: 0 };
    let current = null;          // package whose file was read last

    const tarballUrl = (name, version) => REGISTRY + name + '/-/' + name.split('/').pop() + '-' + version + '.tgz';
    const count = (r) => { stats.requests++; if (r && r.body) stats.bytes += r.body.length; return r; };
    const parseJson = (r) => {
      if (!r || r.status !== 200 || !r.body) return null;
      try { return JSON.parse(dec.decode(r.body)); } catch (e) { return null; }
    };

    // files: Map(path -> { size, body }), body null until read
    function record(key, version, files) {
      const name = versioned(key).name;
      const dirs = new Set(['']);
      for (const path of files.keys()) {
        let d = path;
        for (;;) {
          d = d.slice(0, d.lastIndexOf('/'));
          if (!d) break;
          dirs.add(d);
        }
      }
      const p = { key, name, version, files, dirs, deps: {}, peers: {}, touched: new Set(), bytes: 0 };
      pkgs.set(key, p);
      order.push(key);
      const pj = readEntry(p, '/package.json');
      if (pj) {
        try {
          const meta = JSON.parse(dec.decode(pj));
          p.deps = meta.dependencies || {};
          p.peers = meta.peerDependencies || {};
        } catch (e) {}
      }
      return p;
    }

    function readEntry(p, path) {
      const f = p.files.get(path);
      if (!f) return null;
      if (!f.body) {
        if (!getSync) return null;
        const r = count(getSync(CDN + p.name + '@' + p.version + path));
        if (r.status !== 200 || !r.body) return null;
        f.body = r.body;
      }
      if (!p.touched.has(path)) { p.touched.add(path); p.bytes += f.size; }
      return f.body;
    }

    // The range a loaded package declares for name, the one read most
    // recently first; "latest" when none does.
    function rangeFor(name) {
      const names = current ? [current].concat(order) : order;
      for (const n of names) {
        const p = pkgs.get(n);
        const r = p && (p.deps[name] || p.peers[name]);
        if (r) return r;
      }
      return 'latest';
    }

    // key: the directory name under node_modules, "name" or "name@range"
    async function loadAsync(key, range) {
      const name = versioned(key).name;
      const resolved = parseJson(count(await getAsync(DATA + name + '/resolved?specifier=' + encodeURIComponent(range))));
      const version = resolved && resolved.version;
      if (!version) return null;
      progress('fetching ' + name + '@' + version);
      const tgz = count(await getAsync(tarballUrl(name, version)));
      if (!tgz.body) return null;
      let raw;
      try { raw = untar(await gunzip(tgz.body)); } catch (e) { return null; }
      const files = new Map();
      for (const [path, body] of raw) files.set(path, { size: body.length, body });
      return record(key, version, files);
    }

    // Loads names and everything they depend on, a dependency level at a
    // time, each level in parallel.
    async function prefetch(names) {
      let queue = names.filter((n) => !BUILTINS.has(n)).map((n) => ({ key: n, range: versioned(n).range }));
      while (queue.length) {
        const batch = queue;
        queue = [];
        await Promise.all(batch.map(async ({ key, range }) => {
          if (pkgs.has(key)) return;
          pkgs.set(key, null);
          const p = await loadAsync(key, range);
          if (!p) return;
          for (const [dep, r] of Object.entries(p.deps)) {
            if (!pkgs.has(dep) && !BUILTINS.has(dep)) queue.push({ key: dep, range: r });
          }
        }));
      }
    }

    // The loaded record, or a lazy one from the CDN's file listing.
    function loadSync(key) {
      if (pkgs.has(key)) return pkgs.get(key);
      pkgs.set(key, null);
      if (!getSync) return null;
      const v = versioned(key);
      const range = v.range !== 'latest' ? v.range : rangeFor(key);
      const resolved = parseJson(count(getSync(DATA + v.name + '/resolved?specifier=' + encodeURIComponent(range))));
      const version = resolved && resolved.version;
      if (!version) return null;
      progress('fetching ' + v.name + '@' + version);
      const listing = parseJson(count(getSync(DATA + v.name + '@' + version + '?structure=flat')));
      if (!listing || !listing.files) return null;
      const files = new Map();
      for (const f of listing.files) files.set(f.name, { size: f.size, body: null });
      return record(key, version, files);
    }

    return {
      prefetch,
      read(path) {
        const s = split(path);
        if (!s || !s.rest) return null;
        const p = loadSync(s.name);
        if (!p) return null;
        current = s.name;
        return readEntry(p, s.rest);
      },
      stat(path) {
        if (path === '/node_modules') return { dir: true, size: 0 };
        const s = split(path);
        if (!s) return null;
        const p = loadSync(s.name);
        if (!p) return null;
        const f = p.files.get(s.rest);
        if (f) return { dir: false, size: f.size };
        return p.dirs.has(s.rest) ? { dir: true, size: 0 } : null;
      },
      packages: () => order.map((k) => {
        const p = pkgs.get(k);
        return { key: k, name: p.name, version: p.version, files: p.touched.size, bytes: p.bytes };
      }),
      stats: () => ({ requests: stats.requests, bytes: stats.bytes }),
    };
  }

  return { create, scan, packageName, untar, gunzip, fetchAsync, BUILTINS };
});

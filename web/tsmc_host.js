// tsmc_host.js — runs the wasm build of tsmc against a file view the host
// supplies. Loads as a classic script (a page, or a worker through
// importScripts) and as a CommonJS module (node).
//
// What the module imports, and what this file answers with:
//   env.write(fd, ptr, len)       console output on fd 1 and 2
//   env.clock()                   nanoseconds since the Unix epoch
//   env.open/read/close           read-only file access
//   env.__minc_file_size(path)    byte count, -1 when unknown
//   env.file_exists(path)         1 for a file or a directory
//   env.get_argc/get_arg(i)       argv; get_arg returns a pointer
//   env.__sys_exit(code)          process.exit
//   tsmc.is_dir(path)             1 for a directory
//   tsmc.random_bytes(ptr, n)     fills n bytes from the CSPRNG, 1 on success
// Pointers, counts and results cross the boundary as i64, so as BigInt.
//
// A file view is { read(path) -> Uint8Array | null,
//                  stat(path) -> { dir, size } | null }
// with absolute, "/"-separated paths. memoryFs builds one from an object
// or Map of path -> string | Uint8Array; every ancestor of a file is a
// directory. The sandbox's working directory is "/".

(function (root, factory) {
  const api = factory(root);
  if (typeof module === 'object' && module.exports) module.exports = api;
  root.TsmcHost = api;
})(typeof self !== 'undefined' ? self : globalThis, function (root) {
  'use strict';

  const enc = new TextEncoder();

  function normalizePath(p) {
    const out = [];
    for (const seg of String(p).split('/')) {
      if (seg === '' || seg === '.') continue;
      if (seg === '..') { out.pop(); continue; }
      out.push(seg);
    }
    return '/' + out.join('/');
  }

  function memoryFs(files) {
    const map = new Map();
    const dirs = new Set(['/']);
    const entries = files instanceof Map ? files.entries() : Object.entries(files || {});
    for (const [name, content] of entries) {
      const p = normalizePath(name);
      map.set(p, typeof content === 'string' ? enc.encode(content) : content);
      let d = p;
      while (d !== '/') {
        d = d.slice(0, d.lastIndexOf('/')) || '/';
        dirs.add(d);
      }
    }
    return {
      read: (p) => map.get(normalizePath(p)) || null,
      stat: (p) => {
        const n = normalizePath(p);
        if (map.has(n)) return { dir: false, size: map.get(n).length };
        return dirs.has(n) ? { dir: true, size: 0 } : null;
      },
    };
  }

  class ExitSignal {
    constructor(code) { this.code = code; }
  }

  const now = () => (typeof performance !== 'undefined' ? performance.now() : Date.now());

  function epochNs() {
    if (typeof performance !== 'undefined' && performance.timeOrigin) {
      return BigInt(Math.round((performance.timeOrigin + performance.now()) * 1e6));
    }
    return BigInt(Date.now()) * 1000000n;
  }

  function cryptoSource() {
    if (root.crypto && root.crypto.getRandomValues) return root.crypto;
    if (typeof require === 'function') {
      try { return require('crypto').webcrypto; } catch (e) { return null; }
    }
    return null;
  }

  // Unknown imports become no-ops that report themselves once, so a build
  // that asks for something new fails loudly at the call, not at link time.
  function withStubs(table, name, report) {
    const seen = new Set();
    return new Proxy(table, {
      get: (t, k) => {
        if (k in t) return t[k];
        return () => {
          if (!seen.has(k)) { seen.add(k); report(2, 'tsmc host: no import ' + name + '.' + String(k) + '\n'); }
          return 0n;
        };
      },
    });
  }

  // source: a WebAssembly.Module, or the module bytes.
  // opts: { fs | files, args, write(fd, text) }
  // Resolves to { code, ms }. Each call instantiates afresh: a run leaves
  // the heap behind it, so an instance is never reused.
  async function run(source, opts) {
    opts = opts || {};
    const view = opts.fs || memoryFs(opts.files || {});
    const args = ['tsmc'].concat(opts.args || []);
    const write = opts.write || (() => {});
    const decoders = { 1: new TextDecoder(), 2: new TextDecoder() };
    const rng = cryptoSource();

    let memory = null;
    const bytes = () => new Uint8Array(memory.buffer);
    const cstr = (ptr) => {
      const m = bytes();
      const start = Number(ptr);
      let end = start;
      while (m[end] !== 0) end++;
      return decoders[1].decode(m.subarray(start, end));
    };

    const fds = new Map();
    let nextFd = 3;
    let argPtrs = [];

    const env = {
      write: (fd, ptr, len) => {
        const n = Number(len);
        const which = Number(fd) === 2 ? 2 : 1;
        const s = decoders[which].decode(bytes().subarray(Number(ptr), Number(ptr) + n), { stream: true });
        if (s) write(which, s);
        return BigInt(n);
      },
      clock: epochNs,
      open: (pathPtr, flags) => {
        if (Number(flags) !== 0) return -1n;
        const data = view.read(cstr(pathPtr));
        if (!data) return -1n;
        const fd = nextFd++;
        fds.set(fd, { data, pos: 0 });
        return BigInt(fd);
      },
      read: (fd, ptr, len) => {
        const f = fds.get(Number(fd));
        if (!f) return 0n;
        const n = Math.min(f.data.length - f.pos, Number(len));
        if (n <= 0) return 0n;
        bytes().set(f.data.subarray(f.pos, f.pos + n), Number(ptr));
        f.pos += n;
        return BigInt(n);
      },
      close: (fd) => { fds.delete(Number(fd)); return 0n; },
      __minc_file_size: (pathPtr) => {
        const st = view.stat(cstr(pathPtr));
        return st && !st.dir ? BigInt(st.size) : -1n;
      },
      file_exists: (pathPtr) => (view.stat(cstr(pathPtr)) ? 1n : 0n),
      get_argc: () => BigInt(args.length),
      get_arg: (i) => argPtrs[Number(i)] || 0n,
      __sys_exit: (code) => { throw new ExitSignal(Number(code)); },
      __wasm_abort: () => { throw new Error('abort'); },
    };
    const tsmc = {
      is_dir: (pathPtr) => {
        const st = view.stat(cstr(pathPtr));
        return st && st.dir ? 1n : 0n;
      },
      random_bytes: (ptr, n) => {
        if (!rng) return 0n;
        let at = Number(ptr);
        let left = Number(n);
        while (left > 0) {
          const k = Math.min(left, 65536);
          rng.getRandomValues(bytes().subarray(at, at + k));
          at += k;
          left -= k;
        }
        return 1n;
      },
    };
    const imports = {
      env: withStubs(env, 'env', write),
      tsmc: withStubs(tsmc, 'tsmc', write),
    };

    const result = await WebAssembly.instantiate(source, imports);
    const instance = result.instance || result;
    memory = instance.exports.memory;

    // argv lives in the module's own heap, allocated before main runs.
    const alloc = instance.exports.__wasm_alloc;
    argPtrs = args.map((a) => {
      const b = enc.encode(a + '\0');
      const p = Number(alloc(BigInt(b.length)));
      bytes().set(b, p);
      return BigInt(p);
    });

    const t0 = now();
    let code = 0;
    try {
      code = Number(instance.exports.main());
    } catch (e) {
      if (e instanceof ExitSignal) code = e.code;
      else { write(2, 'tsmc: ' + ((e && e.message) || String(e)) + '\n'); code = 134; }
    }
    const ms = now() - t0;
    for (const fd of [1, 2]) {
      const tail = decoders[fd].decode();
      if (tail) write(fd, tail);
    }
    return { code, ms };
  }

  return { run, memoryFs, normalizePath };
});

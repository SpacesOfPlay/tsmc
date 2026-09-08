# ts-minc

A TypeScript runtime written in [minc](https://minc.dev).

Live demo: https://spacesofplay.github.io/tsmc/

`tsmc script.ts` runs TypeScript the way Bun and Deno do: type
annotations are parsed and erased, nothing is type-checked, and the TS
constructs with runtime semantics (`enum`, `namespace`, constructor
parameter properties) are lowered and executed. It is a bytecode
interpreter with a precise mark-sweep GC, written in minc. `.js` files
run as well, and both `require` and `import` walk `node_modules`, taking a
package's CommonJS or ESM entry to suit, so many pure-JavaScript npm
packages run unmodified.

## What runs

The language: classes, generators, async/await, async generators and
`for await`, top-level await, modules (CommonJS and ESM, including
dynamic `import()`), Proxy and Reflect, BigInt, typed arrays,
`Map`/`Set`/`WeakMap`/`WeakSet` with the set operations, the iterator
helpers, `arguments`, and regular expressions with Unicode property
escapes and the `v` flag's set notation. A script is sloppy-mode code
unless it opts in with `"use strict"`; modules and class bodies are
strict. The mode decides what a plain call sees as `this`: the global
object in sloppy code, undefined in strict code. A primitive `this` is
not boxed.

A subset of the Node standard library: `fs` (with `fs/promises`),
`path`, `os`, `events`, `stream`, `util`, `buffer`, `zlib`, `assert`,
`process`, `timers` (with `timers/promises`), `tty`, `querystring`,
`string_decoder`, `punycode` and `perf_hooks`. `crypto` has
MD5, SHA-1, SHA-224, SHA-256, SHA-384 and SHA-512, HMAC, `pbkdf2Sync`,
`timingSafeEqual`, and the `random*` functions. The globals include
`fetch`, `URL`, `URLSearchParams`, `TextEncoder`/`TextDecoder`,
`structuredClone`, `atob`/`btoa`, `console`, `performance`,
`EventTarget`/`Event`, `AbortController`/`AbortSignal`, `DOMException`,
and `crypto` with `randomUUID`, `getRandomValues` and `subtle.digest`.

`process` is an event emitter: `exit`, `beforeExit`, `uncaughtException`,
`unhandledRejection` and `warning` all fire, and `process.exitCode` is
what the process leaves with.

Networking is `net`, `http`, `https` and `tls` — clients and servers, on
a non-blocking event loop. The TLS 1.3 stack is the project's own. The
client validates the server certificate against a bundled root store.
The server presents an ECDSA-P256 or RSA certificate and sends the
issuer chain with it.

Not supported: `eval` and `new Function`, since there is no runtime code
generation. Node's native addons do not load; native code is written in
minc instead, described below. No `Intl`, and no `child_process`,
`worker_threads` or `dns`. `Buffer` is backed by an array rather than a
`Uint8Array`, so it fails an `instanceof` check and copies where node
shares memory (`doc/PLAN_M42_buffer_uint8array.md`). There is no
`fs.createReadStream`, so a file is read whole.

`doc/npm-compatibility.md` lists the npm packages that have been run
against the interpreter. `doc/META_PLAN.md` holds the design decisions
and architecture.

## An example server

`examples/serve` is an HTTPS content server written in TypeScript and
run directly: Markdown through `markdown-it`, front matter through
`js-yaml`, SHA-256 entity tags, conditional requests, gzip, a directory
index, and TLS terminated by tsmc itself.

## Native modules

A `.mc` file can be required like any other module:

```
const demo = require('./demo.mc');
```

tsmc compiles it with the embeddable minc compiler, loads it in process,
and its exported functions run as native code. The contract is
`src/tsmc_plugin_abi.mc`, imported by both sides: a plugin is built as
its own program and shares no symbols with the interpreter, so it works
through a table of services handed to it at registration — values,
arguments, properties, throwing, and the GC root stack. A version word
is checked before any of its exports are called.

Plugins need their own binary — the `plugins` build target — because the
compiler library binds at load time, so that binary needs the library
beside it and the target copies it there. The default build stays a
single file and reports that it has no plugin support when a `.mc` file
is required. A loaded plugin is never released, since a native's code
pointer travels into the GC heap and unloading would leave those cells
pointing at unmapped pages. `examples/plugin` has a worked example and
the rooting rule a plugin has to follow.

## In the browser

The interpreter also compiles to WebAssembly, and `web/` is a playground
around it, live at https://spacesofplay.github.io/tsmc/: a page where a
script runs in a worker. A bare import
resolves against npm: the packages a script names, and what they depend
on, are fetched from the registry on first use and unpacked in memory,
where the module resolver walks them like an installed tree. Nothing
else leaves the page. `minc wasm` builds the module, assembles the page into
`build/web/`, and serves it with the native binary through
`tools/serve.ts`. The workflow in `.github/workflows/pages.yml` publishes
the same directory to GitHub Pages.

The wasm build is the whole interpreter with a sandbox in place of the
operating system: a read-only file view supplied by the page, a clock,
console output, and a CSPRNG. No sockets, no writes, no environment. The
host side is `web/tsmc_host.js`, which also runs under node
(`tools/wasm_run.js`) so the golden tests can run through the module.
`doc/PLAN_M45_wasm_playground.md` has the host contract and the numbers.

## Install minc

```
# Windows
powershell -c "irm minc.dev/install.ps1 | iex"

# macOS / Linux
curl -fsSL https://minc.dev/install | bash
```

## Build

Requires the minc compiler, see above. The `MINC` environment variable 
overrides the install dir.

```
minc build      # -> build/tsmc[.exe]
minc test       # build + run the full test suite (incl. GC stress)
minc bench      # time bench/*.ts
minc wasm       # -> build/web: the wasm build and the playground, served locally
minc clean      # remove build/
```

The remaining targets have no minc verb, so run the build script
directly:

```
minc build.mc -o build/build.exe   # once
build/build.exe plugins            # -> build/tsmc-plugins[.exe]
build/build.exe diff               # differential test vs a reference node
build/build.exe t262               # ECMAScript conformance (test262), see below
```

## Tests

27 unit tests in minc exercise the interpreter from the inside. 33
scripts are checked against golden output. 177 differential scripts run
under both tsmc and a reference node, and the two outputs are compared
byte for byte — that suite is the guard against quiet divergence, and
most of it was written by sweeping one area at a time against node. All
209 scripts then run again under `--gc-stress`, which collects on every
allocation and poisons what it sweeps, and must print what they printed
without it. The wasm build is cross-compiled on every run, and the golden
tests run through it under node when node is present, followed by the
playground's examples that need no package. `build/build.exe examples`
runs every example, fetching its packages from the live registry the way
the page does.

## Conformance (test262)

tsmc strips types and runs the resulting ECMAScript, so conformance is
measured against the official ECMAScript suite,
[tc39/test262](https://github.com/tc39/test262) — not the TypeScript
type-checker tests, which don't apply to a type-stripping runtime.

The suite is **not vendored**. On first use it is fetched at a pinned
commit into `vendor/test262/` (gitignored), so any clone reproduces the
same tests:

```
build/build.exe t262                            # default: test/language
build/build.exe t262 test/built-ins/Array
build/build.exe t262 test/language --limit 500   # sample the first N
```

On Windows the runner is a portable bash script (`tools/test262.sh`)
run through Git Bash. It assembles each test with its harness includes,
runs the strict and sloppy variants, and honours the `negative`
frontmatter. Tests that need a feature the interpreter doesn't implement
(Temporal, Intl, SharedArrayBuffer and Atomics, WeakRef, `eval`, …) are
**skipped**, not failed — the honest metric is the pass rate over the
tests that ran, so the skip list at the top of the script is worth
reading before the number below. Failing test paths are written to
`build/test262-fails.txt`. The run is split into shards (`--jobs`,
default half the cores). Pin a different revision with the
`T262_COMMIT` environment variable.

The default `test/language` run, at the pinned revision:

| | 2026-08-28 | 2026-09-08 |
|---|---|---|
| ran | 21,037 | 21,037 |
| passed | 16,888 (80%) | 18,817 (89%) |
| failed | 4,149 | 2,220 |
| skipped as unsupported | 2,677 | 2,677 |

Where the 2,220 remaining failures are, each counted once:

| | tests |
|---|---|
| early errors: programs the parser should refuse | 831 |
| class elements and definitions | 305 |
| generators and async iteration | 148 |
| the `with` statement, not implemented | 134 |
| destructuring, remaining scenarios | 80 |
| dynamic import and module instantiation | 77 |
| `eval` and `new Function`, refused by design | 52 |
| parameter and `arguments` rules | 49 |
| everything else | 544 |

This is a snapshot and changes as the interpreter does; the failing
paths of the last run are the list to diff a new run against.

## Layout

```
src/       interpreter source (modern minc)
doc/       design documents and milestone plans
test/      unit tests (minc), golden run tests, and differential (.js) tests
examples/  a TypeScript HTTPS server, and a native module in minc
web/       the browser playground: page, worker, and the wasm host
tools/     test262 conformance runner, wasm node runner, static server
minc/      local minc deploy: compiler + lib/ + docs (gitignored)
build/     build artifacts (gitignored)
vendor/    fetched test262 checkout (gitignored)
```

## License

MIT, See LICENSE.md

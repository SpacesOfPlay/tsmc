# ts-minc

A TypeScript runtime written in [minc](https://minc.dev).

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
helpers, `arguments`, and regular expressions with
Unicode property escapes.

A subset of the Node standard library: `fs` (with `fs/promises`),
`path`, `os`, `events`, `stream`, `util`, `buffer`, `zlib`, `assert`,
`process`, `timers` (with `timers/promises`), `tty`, `querystring`,
`string_decoder`, `punycode` and `perf_hooks`. `crypto` has
MD5, SHA-1, SHA-224, SHA-256, SHA-384 and SHA-512, HMAC, `pbkdf2Sync`,
`timingSafeEqual`, and the `random*` functions. The globals include
`fetch`, `URL`, `URLSearchParams`, `TextEncoder`/`TextDecoder`,
`structuredClone`, `atob`/`btoa`, `console`, `performance`,
`EventTarget`/`Event`, `AbortController`/`AbortSignal` and
`DOMException`.

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
./build.ps1 build      # Windows      -> build/tsmc.exe
./build.sh build       # Linux/macOS  -> build/tsmc
./build.ps1 plugins    # Windows      -> build/tsmc-plugins.exe
./build.sh plugins     # Linux/macOS  -> build/tsmc-plugins
./build.ps1 test       # build + run the full test suite (incl. GC stress)
./build.ps1 diff       # differential test vs a reference node
./build.ps1 bench      # time bench/*.ts
./build.ps1 t262       # ECMAScript conformance (test262) — see below
./build.ps1 clean      # remove build/
```

## Tests

27 unit tests in minc exercise the interpreter from the inside. 31
scripts are checked against golden output. 155 differential scripts run
under both tsmc and a reference node, and the two outputs are compared
byte for byte — that suite is the guard against quiet divergence, and
most of it was written by sweeping one area at a time against node. All
186 scripts then run again under `--gc-stress`, which collects on every
allocation.

## Conformance (test262)

tsmc strips types and runs the resulting ECMAScript, so conformance is
measured against the official ECMAScript suite,
[tc39/test262](https://github.com/tc39/test262) — not the TypeScript
type-checker tests, which don't apply to a type-stripping runtime.

The suite is **not vendored**. On first use it is fetched at a pinned
commit into `vendor/test262/` (gitignored), so any clone reproduces the
same tests:

```
./build.ps1 t262                                 # default: test/language
./build.sh  t262 test/built-ins/Array
./build.sh  t262 test/language --limit 500       # sample the first N
```

On Windows the runner is a portable bash script (`tools/test262.sh`)
run through Git Bash. It assembles each test with its harness includes,
runs the strict and sloppy variants, and honours the `negative`
frontmatter. Tests that need a feature the interpreter doesn't implement
(TypedArrays, Proxy/Reflect, Intl, `eval`, …) are **skipped**, not
failed — the honest metric is the pass rate over the tests that ran.
Failing test paths are written to `build/test262-fails.txt`. Pin a
different revision with the `T262_COMMIT` environment variable.

On the default `test/language` run, 12,679 of the 16,235 tests that ran
pass (about 78%); 7,478 more are skipped as unsupported. This is a
current snapshot and will change as the interpreter does.

## Layout

```
src/       interpreter source (modern minc)
doc/       design documents and milestone plans
test/      unit tests (minc), golden run tests, and differential (.js) tests
examples/  a TypeScript HTTPS server, and a native module in minc
tools/     test262 conformance runner
minc/      local minc deploy: compiler + lib/ + docs (gitignored)
build/     build artifacts (gitignored)
vendor/    fetched test262 checkout (gitignored)
```

## License

MIT, See LICENSE.md

# M45 — the wasm build and a browser playground

Status: build, host and page in place; the Pages deploy is wired but has
not run yet.

## Why

The shortest demonstration of tsmc is a page where a visitor types
TypeScript and runs it. The interpreter already had a wasm target with
sandbox arms for the host surface, but nothing built it, nothing ran it,
and it had rotted: at the start of this milestone the cross-compile
stopped on a dozen errors, all in the TLS stub arm and the libc shim.

Run in a browser, the interpreter needs no server, no sandboxing beyond
the tab, and no operations. A static host serves it.

## The wasm build

`minc wasm` cross-compiles `src/main.mc` with `--target wasm` to
`build/tsmc.wasm`, assembles `build/web/` from `web/` and the module, and
serves it with the native binary through `tools/serve.ts`.
`build/build.exe wasm --no-serve` stops after assembling, which is what
the Pages workflow runs. `minc test` cross-compiles the module on every
run and, when node is present, pushes the golden tests through it.

Measured on the reference machine:

| | wasm under node | native |
|---|---|---|
| module | 1.4 MB, 480 KB gzipped | 2.1 MB exe |
| instantiate | 3 ms | |
| `bench/fib.ts` | 940 ms | 241 ms |
| `bench/arrays.ts` | 203 ms | 105 ms |
| `bench/objprop.ts` | 193 ms | 121 ms |

30 of the 32 golden tests pass through the wasm build. The two that do
not are the ones the sandbox cannot serve: `process` reads the
environment, `tls_plaintext_reply` opens a socket.

## The host contract

The module imports eleven functions. Nine are what the standard library
asks any wasm host for: console output, the clock, read-only file access
(open, read, close, size, exists), argv and exit. Two are tsmc's own,
declared in `src/wasm_host.mc` under the `tsmc` import module:

- `is_dir(path)` — the module resolver needs to tell a package directory
  from a file, and the library's file view has no notion of directories.
- `random_bytes(ptr, n)` — `crypto` over the host's CSPRNG. Without it
  `randomUUID`, `getRandomValues` and `randomBytes` throw.

Pointers, counts and results cross the boundary as i64. The clock is
nanoseconds since the Unix epoch, so `Date` is absolute.

`web/tsmc_host.js` implements the contract over a file view, an object
with `read(path)` and `stat(path)`. `memoryFs` builds a view from a map
of path to contents, with every ancestor of a file counted as a
directory; `tools/wasm_run.js` builds one over the real filesystem with
the working directory mounted as `/`. Each run instantiates a fresh
instance: a run leaves its heap behind.

## The page

`web/index.html` is self-contained: an editor, an output pane, a few
examples, no dependencies. The editor is a textarea with transparent
text over a `pre` that shows the same text coloured by
`web/highlight.js`, a scanner that knows strings, templates with nested
expressions, comments, regex literals, numbers, keywords, types,
functions and properties, in the token colours of VS Code's Dark+ theme.
The page chrome uses the Dark Modern palette around it. Line numbers sit
in a gutter that scrolls with the text; Enter keeps the indent and opens
a block after a bracket; Tab inserts two spaces.

The page compiles the module once and hands it to a worker; a run is one
message, and Stop is `worker.terminate()` followed by a fresh worker. That is the only way to end a script that
does not end itself, since the event loop runs to completion inside
`main`, and it is enough: memory is bounded by the browser and nothing
of the page is reachable from the worker.

Share turns the script into a link: the text goes into the URL hash,
deflated and base64url-encoded, and the link is copied. Opening it loads
the script, and the first edit drops the hash so the address does not
claim to be something it no longer is.

The script becomes `/main.ts` in an in-memory file view. Timers work.
`setTimeout` with a long delay spins, because the sandbox has no way to
block; the page does not notice, the worker's CPU does.

## What the sandbox does not have

- Sockets: `net`, `http`, `https`, `tls` and `fetch` fail on connect.
- Writes: `fs` mutations fail with the usual errors; listings are empty.
  The host view could grow a `readdir` import when something needs it.
- An environment, a cwd other than `/`, a pid, or stdin.

## Packages

A bare import in the page resolves against npm. `web/cdn_fs.js` is a
file view for `/node_modules` that the worker layers under the script's
own files, and the resolver walks it the way it walks an installed tree:
`package.json`, exports maps, `main`, index files, one package requiring
another. The golden test for that walk passes through the wasm build.

Before a run, the worker scans the script for bare specifiers. Each
package's version comes from the jsdelivr data API, which resolves a
semver range; the package itself comes from the npm registry as a
tarball, which the worker gunzips with `DecompressionStream` and unpacks
in memory. Dependencies follow from each `package.json`, a level at a
time, each level in parallel. The registry and the CDN both allow
cross-origin requests, and a tarball is one request per package, so a
package like markdown-it with six dependencies is ready in about a
second. Packages stay loaded for the worker's lifetime, and Stop starts
a fresh worker.

A package the scan cannot see, such as a dynamic import of a computed
name, is fetched during the run. The module's file imports block, so
this path uses a synchronous request in the worker, one for the file
listing and one per file read, from the jsdelivr CDN.

The first version of a package to load wins. A nested dependency that
wants another version gets the loaded one, which is the flat-install
compromise and is rare among the packages a demo reaches for. A range
after the name, as in `import yaml from 'js-yaml@4'`, pins a package:
it lives under that directory name in the view, so the resolver needs no
help. A package fails here for the reasons it fails natively, plus the
sandbox's: no sockets, no writes.

Measured in the page against the live registry: markdown-it with its
six dependencies is 14 requests and 733 KB, ready in 1.3 s; js-yaml and
ramda are 2 requests each, under half a second. A second run of a loaded
package makes no request.

The first markdown-it runs took 1.8 s in the page even with the packages
loaded, and a per-module breakdown of the native build put 914 of its
1,022 ms in one generated file of `entities`: a base64 decoder reading a
24,000-byte string with `charCodeAt`. Parsing and compiling the whole
245 KB graph was 116 ms. Every unit lookup on a non-ASCII string walked
from byte zero, and `charCodeAt` had no ASCII fast path at all, so such
loops were quadratic. The string cell now carries a cursor that lookups
resume from (`doc/DESIGN_string.md`); the same loop costs 2 ms instead
of 294, and the graph loads in 145 ms natively and about 260 ms through
the wasm build. `test/diff/string_index_cursor.js` pins the semantics
against node and `bench/strindex.ts` the cost.

The page carries eleven package examples. Measured in headless Edge
against the live registry, the run itself and the first fetch:

| package | run | first fetch |
|---|---|---|
| markdown-it, 7 packages | 89 ms | 733 KB, 0.3 s |
| js-yaml | 11 ms | 223 KB, 0.05 s |
| ramda | 31 ms | 218 KB, 0.2 s |
| immer | 5 ms | 252 KB, 0.6 s |
| decimal.js | 8 ms | 69 KB, 0.6 s |
| mustache | 2 ms | 34 KB, 0.4 s |
| dayjs with two plugins | 6 ms | 145 KB, 0.4 s |
| uuid | 5 ms | 15 KB, 0.4 s |
| lodash-es, 640 modules | 51 ms | 147 KB, 0.4 s |
| date-fns, 305 modules loaded | 120 ms | 1.5 MB, 0.5 s |
| zod 4 | 58 ms | 1.0 MB, 1.1 s |

date-fns first measured at 618 ms, and the reason was outside this
repository: the wasm target's allocator, which the linux target shares,
keeps one first-fit free list with no splitting or coalescing, so freed
memory is never reused for a different size and every allocation scans
the blocks that did not fit. A probe that frees 50,000 blocks of 64
bytes and then asks for 25,000 of 128 reuses none of them and takes
1.5 s; a block regrown from 100 bytes to 200 KB in 2,000 steps leaves
199 MB of memory for 4 MB of live data. The report is filed with the
compiler. Two things in this repository took most of the sting out:
concatenation extends a shared buffer (`doc/DESIGN_string.md`), which
also took the native cost of 100,000 appends from 1.1 s to 12 ms, and
dead cells are kept on size-class free lists inside the heap
(`doc/DESIGN_gc.md`), which is what brought date-fns to 120 ms. What
the allocator still sees from us is property maps, vectors and string
buffers, which call it by name; a loop of 3,000 `new RegExp` takes a
second in the page for that reason, and 5 ms natively.

zod took three compiler fixes. Its current versions compile TypeScript
namespaces to `export var util; (function (util) { … })(util || (util = {}))`,
and the loader bound an export once at its declaration, so the importer
saw `undefined`. Exports are now live bindings: every store to an
exported binding also writes the namespace object
(`doc/PLAN_M10_modules.md`). Its index uses `export * as util from`,
which was compiled as a plain `export *`; it now stores the dependency
namespace under the name. And a method named like a module function,
`int(params) { return this.check(int(params)); }`, called itself: a
method's name is its key, not a binding in its body, and only a named
function expression sees its own name. `test/diff/esm_live_bindings.mjs`
and `test/diff/method_name_scope.js` hold the three against node. zod 3
and zod 4 run natively and in the page, where zod 4 is an example.

A review of the other examples found two more general costs. Compiling
was quadratic in file size, because every recorded source position
counted newlines from the start of the file; a line table built once per
file made it linear, and js-yaml's bundle compiles in 2 ms instead of
75. The ES module loader did a canonical path, a package.json walk and a
read for every import edge, even to a module already loaded; ramda's
1,029 edges now cost a map lookup each, and it imports in 165 ms
instead of 355. `bench/BASELINE.md` has the numbers.

The package view exposed a resolver habit: a bare specifier used to be
tried as a sibling file before the `node_modules` walk, so a script named
`ramda.ts` that imported `ramda` imported itself and saw an empty
namespace. The ESM loader now sends only path specifiers to the file
lookup, the way `require` always did; `test/run/bare_shadow.ts` keeps it
that way.

`tools/cdn_fs_check.js` runs the view against a registry it fakes with
tarballs it builds, ending with a script run through the wasm build that
imports an ESM package with an exports map, its CJS dependency, a scoped
package with a pax-header path, and a package only the fallback can see.
`minc test` runs it. `tools/wasm_run.js --cdn` gives the same view under
node for debugging, with `WASM_TRACE=1` printing every probe.

## Follow-ups

1. Turn Pages on in the repository settings and let the workflow run.
2. Editor niceties the overlay does not give: bracket matching, find,
   and multi-line indent. Past that point an editor component is the
   honest answer, at the cost of a CDN dependency.
3. A multi-file view in the page.
4. Blocking timers, if the page ever runs with shared memory.

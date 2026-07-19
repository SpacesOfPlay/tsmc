# M24 — `stream`

The `stream` built-in — the backbone of Node I/O. First module implemented
as **embedded JavaScript** rather than native code: streams are a state
machine over EventEmitter + the microtask loop, and that is far clearer
(and closer to Node) written in JS, exactly as Node itself does.

## Delivery: JS-source built-in modules

A new module category alongside the natively-built namespaces. The stream
source lives in `src/node_stream.mc` as a compiled-in string
(`node_stream_source()`, one adjacent literal per JS line). On first
`require('stream')` / `import ... from 'stream'`, it is compiled+run once
as a CJS module — its own `require('events')` reaches the native events
module — and cached by `builtin:stream`. Wired into both `module_require`
(CJS, returns `module.exports`) and the ESM loader (wraps exports as a
namespace: `default` + each export named, so `import { Readable }` works).

## Shipped

- **`Readable`** — `push`, `read`, flowing mode (starts on a `data`
  listener or `resume`), `pause`/`resume`, `pipe` (with basic
  backpressure), `on('data'|'end'|'error'|'close')`, `destroy`,
  `Readable.from(iterable)`.
- **`Writable`** — `write(chunk, enc?, cb?)`, `end(chunk?, enc?, cb?)`,
  `_write` / `_final`, `on('finish'|'drain'|'error'|'close')`, `destroy`.
- **`Transform`** — `_transform(chunk, enc, cb)` + `_flush(cb)`; both
  readable and writable.
- **`PassThrough`** — identity Transform.
- **`pipeline(...streams, cb?)`** and **`finished(stream, cb)`**.
- **`Stream`** (base, with the classes attached) is the module's default
  export, so `require('stream')`, `const { Readable } = require('stream')`,
  and `import Readable, { Transform }` all work. Object mode supported.

Scheduling uses `queueMicrotask` throughout, so ordering is
self-consistent across engines. Aggregate results (piped/transformed
output) are byte-identical to Node's native streams; verified in
`test/diff/stream.js` (scenarios sequenced so ordering is deterministic).

## Not doing (documented)

- **True `Duplex`** — exported as an alias of `Transform` (independent
  readable/writable sides via mixin are not modeled).
- **HighWaterMark / precise backpressure & `'readable'` event / `.read(n)`
  sizing** — flowing mode and a simplified backpressure signal are
  implemented; the paused-mode `read(n)` byte accounting is not.
- **Internal scheduling parity** — uses microtasks, not Node's
  `process.nextTick` phases, so the *interleaving* of independent
  pipelines can differ from native Node (each pipeline's result does not).
- **`Readable`/`Writable` async iteration** (`for await…of`), `compose`,
  `Duplex.from`, `stream/promises`, `stream/web`.

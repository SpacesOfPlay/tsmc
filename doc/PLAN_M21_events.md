# M21 — `events` / `EventEmitter`

A near-universal Node dependency: the `events` built-in module whose
export **is** the `EventEmitter` class (with `EventEmitter.EventEmitter`
self-reference), so `require('events')`, `const { EventEmitter } =
require('events')`, `import EventEmitter from 'events'`, and
`class Server extends EventEmitter` all work (extending a native
constructor is already supported — cf. `class X extends Error`).

## API

Instance state is a lazily-created hidden `%events` object mapping each
event name (string) to an ordered array of listeners, plus a
`%maxListeners`.

- **register**: `on` / `addListener`, `once`, `prependListener`,
  `prependOnceListener` — all return `this` for chaining.
- **remove**: `off` / `removeListener` (first match; a `once` listener is
  matched by its original function), `removeAllListeners([event])`.
- **emit**: `emit(event, ...args)` — calls listeners synchronously in
  registration order with `this` = the emitter, over a snapshot (so a
  `once` listener removing itself mid-emit is safe); returns whether any
  ran. `emit('error', e)` with no listener throws `e` (or a generic
  error).
- **introspect**: `listeners` (originals, `once` unwrapped),
  `rawListeners` (wrappers as stored), `listenerCount`, `eventNames`.
- **max listeners**: `setMaxListeners` / `getMaxListeners` (stored;
  `defaultMaxListeners` = 10). No warning is emitted past the threshold.

`once` stores a self-removing wrapper native that fires the original once
then detaches; `off` and `listeners` see through it to the original.

## Not doing (documented)

- **Symbol event names** — event keys are coerced to strings (covers the
  overwhelming majority; a symbol event becomes its `String(sym)` form).
- **`newListener` / `removeListener` meta-events** — not emitted on
  register/remove.
- **`captureRejections`**, `errorMonitor`, `EventEmitter.once(ee, name)`
  (the promise helper), `EventEmitter.on` (async iterator), and the
  max-listeners warning.

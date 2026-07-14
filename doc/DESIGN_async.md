# Generators, async, and the event loop

Decision: **heap-suspended VM frames** — no OS fibers, no separate
stacks. A generator owns a buffer holding its frame image; suspension
copies the live frame out of the VM stack, resumption copies it back.

## Suspendable frames

A generator object (`GC_GENERATOR`) carries the closure, `this`, a
resume ip, a saved image of the frame (slots plus operand stack at
the suspension point), any try-handlers the frame had open (saved
with stack offsets relative to the frame base), and a state:
suspended-start / suspended / running / done.

`OP_YIELD` is a return that remembers: it copies `stack[base..sp-1)`
into the generator, records the ip and rebased handlers, marks the
generator suspended, and unwinds exactly like `OP_RETURN` with the
yielded value as the call's result. Resumption rebuilds the frame at
the current stack top, re-pushes rebased handlers, pushes the resume
value (the `yield` expression's result — or sets a pending exception
for `throw()`), and re-enters the dispatch loop, whose pending-check
now runs at loop top so an injected exception unwinds before the
first opcode. Yields can only occur in the generator's own frame, so
the saved image is always a single frame — nested calls cannot
suspend across it.

Calling a function whose template is flagged generator builds the
generator object from the normalized arguments instead of a frame.
`next`/`return`/`throw` are natives on `Generator.prototype`;
`return()` skips open `finally` blocks (documented deviation).

## Iterator protocol and symbols

Symbols are cells (`GC_SYMBOL`) with a unique id in a reserved key
space (high bit set), so symbol-keyed properties reuse the ordinary
property tables and never collide with atoms. Enumeration filters
symbol keys and `%`-hidden atoms everywhere keys are surfaced.

`for-of` compiles to the real protocol: `OP_GET_ITER` invokes the
well-known `Symbol.iterator` method (arrays, strings, and generators
get natives; user objects work via computed keys), `OP_ITER_NEXT`
calls `next()` and pushes `value` and `done`. Spread over non-arrays
walks the same protocol. `yield*` compiles to an inline
iterate-and-yield loop. Array destructuring stays index-based
(documented).

## Async functions and promises

An async function is generator machinery plus a driver: the call
creates the generator state and a result promise, then steps
synchronously until the first `await` (compiled as `OP_YIELD`).
Each awaited value either has our promise shape — the driver
registers step-continuation natives carrying the generator and
result promise in their env slots — or is scheduled as a microtask
step. Completion resolves the promise; a throw rejects it; `throw()`
resumption makes rejected awaits raise inside the async body, so
try/catch around `await` works.

Promises are plain objects with hidden `%state`/`%value`/`%cbs`
fields and their core (create/settle/then, thenable adoption of our
own promises) in the VM, where the async driver can reach it; the
`Promise` constructor surface lives in builtins on top.

## Event loop

One FIFO microtask queue (promise reactions, async steps) plus a
timer list ordered by (delay, sequence). After the main script, the
loop drains microtasks, then fires the next timer, until both are
empty — **virtual time**: timers order by delay but nothing sleeps.
An uncaught exception in a job prints and exits 1, like an uncaught
synchronous throw.

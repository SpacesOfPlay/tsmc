# M8 — async

Design context: `DESIGN_async.md`.

## Deliverables

- `OP_YIELD`, `OP_GET_ITER`, `OP_ITER_NEXT`; templates flagged
  generator/async; frame suspension/resumption (`vm_gen_resume`),
  promise core and job/timer queues in the VM; event loop wired into
  `vm_run_source`.
- Compiler: `yield`, `yield*` (inline protocol loop), `await` in
  async functions/arrows/methods, for-of via the iterator protocol.
- Builtins: `Symbol` (unique values, `Symbol.iterator`),
  `Array.prototype`/`String.prototype`/generator `[Symbol.iterator]`,
  `Generator.prototype.next/return/throw`, `Promise` (constructor,
  resolve, reject, all, race, then/catch/finally), `setTimeout`/
  `clearTimeout`.

## Known deviations (documented, revisit with conformance work)

- `generator.return()` skips open finally blocks; `yield*` does not
  forward `next()` arguments to the inner iterator.
- Timers use virtual time; no wall-clock sleeping.
- Symbol coercions don't throw (`String(sym)` gives "Symbol(desc)");
  no symbol boxing, `description`, or `Symbol.for`.
- Array destructuring reads by index rather than the protocol;
  `for await` and top-level `await` stay unsupported with
  diagnostics; unhandled promise rejections are not reported.

## Incidental fix

A latent M6 crash surfaced here: `console.log(NaN)` / `Infinity`
segfaulted because `js_num_format` returned `string(<literal>)` and
the caller freed it. No earlier test printed a non-finite number
through `js_to_string_value`. Special values now format from borrowed
`str` constants with no owned-string round trip.

## Tests

Probe suites: generator basics (args, state machine, for-of, spread,
`yield*`, `throw`/`return`), symbols as keys and custom iterables,
promise chaining and microtask ordering vs synchronous code,
`Promise.all/race`, async/await with values, promises, rejections
and try/catch, timer ordering. Golden runs: generators.ts, async.ts.
GC stress across suspension/resumption.

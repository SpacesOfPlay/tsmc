# M43 — async generators

Status: complete. All 40 checks in `test/diff/async_iteration.js` match node,
including the seven below. One gap is left, noted at the end.

## Why

`async function*` parses, and a body that only yields works. A body that
awaits does not. From `test/diff/async_iteration.js` plus the checks left out
of it, 7 divergences, all from one place:

| behaviour | node | tsmc today |
|---|---|---|
| `g().next() instanceof Promise` | `true` | `false` |
| `g()[Symbol.asyncIterator]` | function | absent |
| `g()[Symbol.iterator]` | absent | function |
| `toString.call(g())` | `[object AsyncGenerator]` | `[object Generator]` |
| `async function* g(){ await t(); yield 1; }` | `[1]` | `[undefined, 1]` |
| `const v = await p; yield v * 2` | `[14]` | `[7, NaN]` |

The last two are the ones that matter. An await inside an async generator
does not suspend privately, it hands its value to the consumer. Every await
leaks an extra element into the sequence, and the variable it should have
bound comes back undefined. Silent wrong answers, not a crash.

## Cause

Two lines.

`compile_expr` emits `OP_YIELD` for `N_AWAIT` (`src/compiler.mc`, the
`k == N_AWAIT` arm) and the same opcode for `N_YIELD`. For a plain async
function that is fine, since every suspend is an await. An async generator
has both kinds and cannot tell them apart.

`vm_run`'s call path checks `ft.is_gen` before `ft.is_async`
(`src/vm.mc`, the `OP_CALL` arm), so an async generator builds a plain
generator object. That is where the shape comes from: sync `next`,
`Symbol.iterator`, the `Generator` tag.

## Shape of the fix

1. An `OP_AWAIT` opcode, emitted for `N_AWAIT`. It suspends like `OP_YIELD`
   and records the reason on the generator. `vm_run` frame slots are tight,
   so the arm must not add locals. `test_hardening` is the canary: it fails
   when the interpreter frame grows.
2. An async generator object: the same `JsGenerator` with a flag, routed to
   its own prototype. `next`, `return` and `throw` return promises,
   `Symbol.asyncIterator` returns this, no `Symbol.iterator`, tag
   `AsyncGenerator`.
3. A driver next to `vm_async_step`, which already resumes, assimilates a
   thenable and chains onto a promise. The loop differs in one place: an
   await suspend resumes internally, a yield suspend settles the consumer's
   promise with `{value, done}`. A yielded value is awaited before it
   settles.
4. A request queue, so overlapping `next()` calls run in order rather than
   re-entering a running generator.

## Acceptance

`test/diff/async_iteration.js` grows the checks its header lists as not
covered, and they match node:

- `next-returns-promise`, `has-asyncIterator`, `asyncIterator-returns-self`,
  `no-sync-iterator`, `toStringTag`
- `await-then-yield` is `[1, 2]`
- `await-value-used` is `[14]`
- a body that awaits between yields, under `for await`, in the right order
- `return()` and `throw()` while suspended in an await still run `finally`

test262 cannot check this today, which the plan got wrong. The runner skips
any test whose frontmatter carries `flags: [async]`, because it does not
implement the `$DONE` harness mode, and 632 of the 1040 files under the two
async-generator directories are flagged that way. What runs there is mostly
destructuring in parameter position, so the numbers before and after this
work are identical: 130 failures under expressions, 60 under statements, 52
of those 60 being `dstr` cases that have nothing to do with async.

Teaching the runner `flags: [async]` would make this measurable, and would
uncover 4,875 currently invisible tests across `test/language`. That is its
own change: it moves the headline pass rate and needs a re-measure.

## What landed

As sketched, with one addition the sketch missed. `yield*` walked the
delegate with the sync protocol, which stopped working the moment an async
generator lost `Symbol.iterator`. Inside an async generator it now takes
`OP_GET_AITER` and awaits each `next()`, so a sync iterable still delegates
(the opcode falls back to `Symbol.iterator`, and awaiting a plain result is
a no-op).

Still open: closing a delegate does not await its `return()`. `OP_ITER_CLOSE`
calls the method and drops the promise, so when a throw unwinds out of a
`yield*` over an async generator, the delegate's `finally` runs late rather
than before the throw continues. Nothing in the suite sees it.

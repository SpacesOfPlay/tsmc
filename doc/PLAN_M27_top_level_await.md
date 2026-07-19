# M27 — top-level `await`

`await` (and `for await…of`) at the top level of an ES module — supported
by Node ESM, previously a compile error in tsmc ("await outside an async
function").

## Approach

A module whose top level contains an `await` compiles as an **async
function template**: the async machinery already lives in the VM
(`make_async_from_call` runs a template as a coroutine that suspends at
`await`), so the change is small.

- **Detection** (`compile_module`): `node_has_tla` walks the module body
  but does not descend into nested functions/arrows/methods (those carry
  their own async context); it reports an `await` or a `for await` at
  module scope. When found, the module's `FScope.is_async` is set and the
  template is finished with `is_async = true`, which makes the compiler
  accept `await` and emit the coroutine form.
- **Evaluation** (`eval_module`): an async module's function returns a
  completion promise and its body suspends at the first `await`. After
  invoking it, the evaluator drains the event loop so the module's body
  (and therefore its exports) finishes **before** dependents evaluate —
  giving a module's top-level await the ES "async dependency" ordering for
  the common cases. The entry module is drained by the existing
  post-eval loop.

Works for the entry module and imported dependencies, `for await…of`,
`await` in expressions/loops, and awaiting `fs/promises` etc. Golden test
`test/run/tla.ts`; verified byte-identical to Node.

## Not doing (documented)

- **CommonJS / plain scripts** — top-level await stays a compile error on
  the non-module path (matching Node CJS). Only files with `import`/
  `export` take the module path; a `.mjs` with top-level await but no
  import is treated as a script (tsmc keys off syntax, not the `.mjs`
  extension).
- **Rejected top-level await → non-zero exit** — tsmc does not yet report
  **unhandled promise rejections** at all (a plain `Promise.reject(...)`
  also exits 0), so a rejected TLA does not set exit 1 as in Node. That is
  a separate, pre-existing gap (unhandled-rejection tracking), not TLA.
- **Full ES async-dependency concurrency** — dependencies are drained
  one at a time (post-order), not evaluated concurrently; results are
  correct, but the interleaving of independent async deps can differ from
  Node.

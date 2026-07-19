# M25 — `assert`

The `assert` built-in — ubiquitous in tests and libraries. A JS-source
module (the second, after `stream`) that `require('util')` for
`isDeepStrictEqual`.

## Shipped

- The callable `assert(value, msg)` plus `ok`, `equal`/`notEqual` (loose),
  `strictEqual`/`notStrictEqual` (`Object.is`), `deepEqual`/`notDeepEqual`
  (loose recursive), `deepStrictEqual`/`notDeepStrictEqual`
  (`util.isDeepStrictEqual`).
- `throws(fn, expected?, msg?)` / `doesNotThrow` with an error matcher that
  accepts an Error constructor (`instanceof`), a RegExp (against the error
  string), a validation predicate, or a properties object.
- `rejects(promiseOrFn, expected?, msg?)` / `doesNotReject` — the async
  forms (return a Promise).
- `match` / `doesNotMatch`, `ifError`, `fail`.
- `AssertionError` (name `AssertionError`, `code 'ERR_ASSERTION'`,
  `actual`/`expected`/`operator`).
- `assert.strict` — the strict variant where `equal`/`deepEqual` route to
  their strict counterparts; `assert.strict.strict === assert.strict`.

Failures throw an `AssertionError` with `code 'ERR_ASSERTION'`, matching
Node's behavior; verified in `test/diff/assert.js` (pass/throw outcomes +
codes; async rejects/doesNotReject) and clean under `--gc-stress`.

## Not doing (documented)

- **Message-text parity** — Node's `AssertionError` messages include a
  colored, formatted actual-vs-expected diff. tsmc's messages are plain
  and not byte-compatible (the `code` and behavior are). The diff suite
  compares outcomes/codes, not message text.
- **`assert.CallTracker`** (deprecated in Node) and `assert.snapshot`.
- **Loose `deepEqual` full spec** — the loose recursive compare covers the
  common cases, not every `+0`/`-0`/boxed-primitive/`NaN` coercion nuance
  of Node's legacy algorithm (`deepStrictEqual` is exact via `util`).

# M9 — collections & regex

Design context: `DESIGN_regex.md`.

## Deliverables

- `src/regex.mc` — standalone backtracking engine (parse → tree →
  instructions → matcher). No VM dependency; own unit test.
- VM integration: `OP_REGEX`, RegExp objects backed by compiled progs
  owned by the VM (`vm.regexps`, freed at teardown); `js_same_value_zero`
  for Map/Set keys; `vm_now_millis` (platform clock behind `when os`).
- `GC_MAP` cell kind: insertion-ordered parallel arrays with tombstone
  deletion; serves both Map and Set. `value_is_reference` so a
  constructor returning a Map/Set/etc. is kept by `new`.
- Builtins: `Map`, `Set` (add/get/has/delete/clear/forEach/keys/values/
  entries/size, `[Symbol.iterator]`), `Date` (millisecond timestamp +
  UTC decomposition, `now`, getters, `toISOString`), `RegExp`
  (test/exec/toString, source/flags/global/lastIndex), and the String
  regex methods (match with `g`, matchAll-style, search, split, replace
  with `$1`/`$&`/`$$` substitution and function replacers).

## Known deviations (documented)

- Map/Set lookup is linear scan (order-preserving, small-object
  philosophy) — O(n) per operation; a hash index is a later
  performance item.
- Regex is byte-oriented (see `DESIGN_regex.md`); named groups,
  lookbehind, `\p{}`, and full `u`/`y` semantics are deferred.
- Date is UTC-only (no timezone / locale); `toISOString` is the
  canonical format. `new Date(string)` parsing is not implemented.
- `String.prototype.matchAll` returns an array (not a lazy iterator).

## Incidental

Fixed a GC rooting bug surfaced by the stress test: index-iterator
construction allocated before rooting its source array, so a
collection between the two freed live entries. Also broadened the
`new` return-value rule (`value_is_reference`) so map/set/date/regexp
constructors work.

## Tests

`test_regex.mc` (standalone, ~60 cases: classes, quantifiers greedy/
lazy, alternation, captures, nested captures, backreferences,
lookahead, boundaries, flags, escapes, realistic patterns). Probe
suites for Map/Set/Date/regex; golden runs `regex.ts`, `collections.ts`.
GC stress across all three.

# M11 — hardening & performance

Functional coverage is complete through M10. This milestone measures,
then optimizes the hot paths that measurement exposes, and hardens the
runtime against pathological inputs. No new language surface.

## Benchmark harness

`bench/*.ts` — workloads that run long enough to time from the shell:
recursive fib, string building, array map/filter/reduce/sort, object
property churn, JSON round trips, a small interpreter-in-the-
interpreter. `./build.ps1 bench` runs each with the built `tsmc` and
reports wall time. Not a CI gate — a tracking tool.

## Optimization targets (confirm by measurement first)

- **Property access.** Own property tables are a linear scan — fine
  and cache-friendly for small objects, O(n) for dictionary-pattern
  objects. Add a hash index above a size threshold; small objects stay
  linear.
- **Global access.** `OP_GETGLOBAL` hashes the name each time. Cache
  the resolved slot per instruction site if it profiles hot.
- **Dispatch / arithmetic.** Verify the interpreter loop is a jump
  table and the integer fast paths stay unboxed.

Only land changes with a measured win; record before/after in the
commit.

## Hardening

- **Deep recursion** must raise `RangeError`, never segfault — the
  frame-count guard has to trip before the native C stack overflows,
  including through native re-entry (`vm_call_value`).
- **Sustained allocation** under the real (non-stress) collector: a
  long-running allocator loop stays bounded and correct.
- **Pathological inputs**: huge literals, deeply nested structures,
  long strings, wide objects — bounded behavior or a clean error, no
  crash.
- Uncaught errors print name + message and exit 1; compile errors
  print with spans and exit 2 (already true — add regression coverage).

## Results

Landed, each with a measured win or a fixed hazard:

- **Property hash index** above 16 entries: a 500-key dictionary
  object doing 1M lookups went 0.53 s → 0.37 s (~30%); small objects
  and `fib` unchanged. Deletion rebuilds the index; enumeration order
  preserved.
- **Integer fast paths** on `-`, `*`, and the ordered comparisons
  (matching `+`), skipping the f64 round trip when both operands are
  small integers. `fib(34)` 1.29 s → 1.21 s.
- **Recursion limits split.** Direct JS recursion grows the frame
  array, not the C stack, so `VM_FRAMES_MAX` rose to 8000 — `sum(2000)`
  now succeeds where 256 used to throw. Native re-entry
  (`vm_call_value` → `vm_execute`) grows the real C stack, so a
  separate `exec_depth` cap (180) trips first there. Both runaway
  cases raise `RangeError`; neither segfaults.

## Tests

`test/unit/test_hardening.mc` — deep recursion → RangeError, sustained
allocation, deep nesting, wide objects. Benchmark scripts double as
smoke tests (must exit 0 with expected output). Large-object property
correctness under the new hash index.

# Performance baseline

Reference numbers for spotting regressions and measuring optimizations.
Update when the interpreter's performance characteristics change
materially; keep the methodology fixed so runs stay comparable.

## Environment

| | |
|---|---|
| Date | 2026-07-17 |
| CPU | AMD Ryzen 9 5900X |
| OS | Windows 11 x64 |
| minc | 0.9.8 |
| Node (reference) | v22.16.0 |

## Method

Wall-clock of the whole process, `min` of N runs (least interference).
`tsmc` is the release build (`build.ps1 build`). "Work" columns subtract
each engine's own startup floor, isolating interpreter throughput from
process/VM init.

## Startup floor (empty script, min of 6)

| tsmc | node |
|---|---|
| **8 ms** | 38 ms |

tsmc cold-starts ~5x faster than Node — an advantage for short CLI runs.
Startup is stable at ~8 ms even after adding Buffer, process, and the
text codecs (all installed at startup).

## Committed benchmarks (min of 5, total wall-clock incl. startup)

Sizes as in `bench/*.ts`; run with `build.ps1 bench`.

| bench | tsmc | node | note |
|---|---|---|---|
| `fib` (fib(30)) | 219 ms | 36 ms | numeric recursion, ~2.7M calls |
| `arrays` | 60 ms | 38 ms | map/filter/reduce + closures + alloc |
| `objprop` | 73 ms | 37 ms | dynamic string-keyed property churn |

At these sizes Node is startup-dominated (~38 ms floor), so the totals
understate the compute gap. See the compute-bound numbers below.

## Compute-bound throughput (heavier variants, startup-subtracted)

Same shapes scaled up so both engines are compute-bound; "work" =
total − startup floor.

| workload | tsmc work | node work | ratio |
|---|---|---|---|
| `fib(35)` (~30M calls) | 2,323 ms | 76 ms | **31x** |
| `arrays x20` (60k iters) | 1,043 ms | 28 ms | **38x** |
| `objprop x20` (40k iters) | 1,246 ms | 205 ms | **6x** |

`fib(35)` ≈ **78 ns per call** (dispatch + frame setup + boxed arithmetic).

## Reading the numbers

- **Hot monomorphic loops (`fib`, `arrays`): ~30–40x off V8.** Expected
  for a NaN-boxed bytecode interpreter with no JIT; V8 compiles these to
  native code. Not a regression — it's the architecture.
- **Dynamic object churn (`objprop`): only ~6x.** Computed `"k"+i` keys
  put V8 into dictionary mode too, so its own fast paths don't apply and
  the gap collapses. Real dynamic JS runs relatively closer to Node than
  the `fib` ratio implies.
- **Startup is a genuine strength** and did not regress with the M14–M16
  feature work.

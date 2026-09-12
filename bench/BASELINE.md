# Performance baseline

Reference numbers for spotting regressions and measuring optimizations.
Update when the interpreter's performance characteristics change
materially; keep the methodology fixed so runs stay comparable.

## Environment

| | |
|---|---|
| Date | 2026-09-12 |
| CPU | AMD Ryzen 9 5900X |
| OS | Windows 11 x64 |
| minc | 0.9.14 |
| Node (reference) | v22.16.0 |

## Method

`minc bench` times every `bench/*.js` under both engines: the wall clock of
the whole process, one warm-up run discarded, then the least of three. The
least, not the mean — anything slower is the machine interfering.

Each engine's own startup floor (an empty script, least of seven) is
subtracted to get the work, and the ratio is of the work. The scripts are
plain JavaScript so both engines run the same file, and the runner compares
what they print: a benchmark that prints different results is measuring
different work and says so.

Sizes are chosen so Node does tens of milliseconds of real work. Node's floor
is three times tsmc's, and on the benchmarks where it finishes inside the
noise of that floor the ratio is reported as the lower bound 10 ms of work
gives (`>`).

## Startup floor (empty script)

| tsmc | node |
|---|---|
| **14 ms** | 45 ms |

tsmc cold-starts ~3x faster than Node, which is what short CLI runs are made
of. Every table below takes that difference out.

## Benchmarks

| bench | tsmc | node | work ratio | what it measures |
|---|---|---|---|---|
| `exceptions` | 61 ms | 91 ms | **1.0x** | throw, catch and finally in a loop |
| `strbuild` | 154 ms | 107 ms | 2.2x | a string built by `+=` and templates |
| `sort` | 45 ms | 46 ms | >3.1x | `Array#sort` with a comparator |
| `objprop` | 184 ms | 92 ms | 3.6x | computed string keys on fresh objects |
| `regexloop` | 199 ms | 91 ms | 4.0x | `new RegExp`, `test`, `replace` with a function |
| `json` | 306 ms | 106 ms | 4.7x | `JSON.stringify` and `parse` of nested data |
| `collections` | 93 ms | 61 ms | 4.9x | `Map` and `Set` insert, look up, iterate |
| `promises` | 387 ms | 77 ms | 12x | `await` chains and `Promise.all` |
| `iterators` | 632 ms | 77 ms | 19x | generators, `for-of`, spread, destructuring |
| `fib` | 1,230 ms | 92 ms | 26x | recursive calls and arithmetic (fib(34)) |
| `strindex` | 437 ms | 60 ms | 28x | `charCodeAt` and indexing over 420k units |
| `arrays` | 496 ms | 60 ms | 32x | `map`/`filter`/`reduce` with closures |
| `bytes` | 588 ms | 61 ms | 36x | typed-array element loops |
| `classes` | 895 ms | 61 ms | 55x | instantiation and dispatch through inheritance |
| `proto_chain` | 604 ms | 45 ms | >59x | reads down a four-deep prototype chain |

## What changed on 2026-09-12

Two algorithms and three interpreter costs, in that order of size.

`Array#sort` was an insertion sort and `Map`/`Set` looked a key up by scanning
every entry, so filling either cost O(n^2):

| n | `sort(n)` before | after | `Map` of n keys before | after |
|---|---|---|---|---|
| 500 | 3 ms | 0 ms | 3 ms | 0 ms |
| 1,000 | 12 ms | 1 ms | 13 ms | 1.5 ms |
| 2,000 | 49 ms | 1 ms | 47 ms | 1.5 ms |
| 4,000 | 202 ms | 2.5 ms | 196 ms | 3.9 ms |

A merge sort and a hash index took those two benchmarks from 94x and 77x to 3x
and 4.9x.

Then the interpreter itself, measured with `minc profile` rather than guessed
at: the arithmetic and relational opcodes asked whether both operands were
primitive before trying the integer path, the two helpers on the call and return
path were called only to test two flags each, and `i++` in statement position
was six opcodes. A tight loop went from 51 to 23 ns an iteration and a
call-heavy one from 113 to 71.

What is left is the dispatch loop, where 8-15% of the time is calls to
four-line value predicates that are not inlined -- 15% of a property-heavy
benchmark, 7.6% of `fib`. That is a compiler matter, written up for minc.

## Reading the numbers

- **Startup is a genuine strength**, and `exceptions` is the one workload where
  tsmc matches V8 outright -- a throw costs the same on both, and the process
  starts sooner.
- **The runtime-bound band is 2-5x** (`strbuild`, `sort`, `objprop`,
  `regexloop`, `json`, `collections`): the work happens in C-like code either
  way, and V8's compiler has little to add. Real dynamic JavaScript lives closer
  to this band than to `fib`.
- **What the interpreter walks one bytecode at a time is 19-36x.** That is the
  architecture: V8 compiles `fib`, array callbacks and typed-array loops to
  native code with unboxed values.
- **A shape-heavy read is the worst of it** (`proto_chain`, `classes`): V8's
  inline caches turn a property read into a slot load, and a property table per
  object pays a lookup every time. This is where the next real work is.

## Loading packages (2026-09-06, minc 0.9.14, same machine)

Loading a real package was dominated by three costs that were not the
interpreter's throughput. Native wall clock, `min` of 3, whole process:

| workload | before | after | what changed |
|---|---|---|---|
| `charCodeAt` loop over 15,000 chars | 294 ms | 2 ms | lookups resume from a per-string cursor; ASCII reads the byte |
| compile 12,000 plain statements | 753 ms | 4 ms | a line table per file instead of a scan per recorded position |
| `import 'markdown-it'` (7 packages, 245 KB) | 1,022 ms | 90 ms | both of the above |
| `import 'js-yaml'` (107 KB bundle) | 135 ms | 60 ms | line table |
| `import * as R from 'ramda'` (368 files, 1,029 edges) | 355 ms | 165 ms | module table consulted per edge; package type cached per directory; one read per module |
| ten `setTimeout(1)` in sequence | ~160 ms | 19 ms | `timeBeginPeriod(1)` on the first wait (Windows) |
| `s += 'ab'` 100,000 times | 1,099 ms | 67 ms | concatenation results share a growing buffer; each piece copied once |

`bench/strbuild.ts` (100,000 lines by `+=`, 20,000 template pieces)
runs in about 120 ms.

Allocating less, same day, native wall clock:

| workload | before | after | what changed |
|---|---|---|---|
| 3,000 `new RegExp` of 9 patterns | 8.6 ms | 4.6 ms | one compiled program per pattern and flags, shared by every object |
| 200,000 `String(i)` | 56 ms | 47 ms | an integer is spelled into a stack buffer, no intermediate heap string |
| `bench/regexloop.ts` | 155 ms | 118 ms | both, plus one-byte strings from a shared table |
| lodash-es loaded through wasm | 50.6 MB | 17.5 MB | a module's parse arena starts at a size drawn from its source |

Through the wasm build the regex loop went from 7.7 s to 1.0 s; what
remains there is the allocator behind every `new RegExp` object.

Dead cells are now kept on per-size-class free lists inside the heap
and reused before the program allocator is asked (`doc/DESIGN_gc.md`).
Where that allocator scans one first-fit list per request this is the
difference between usable and not:

| `import 'date-fns'` (305 modules) | before | after |
|---|---|---|
| Windows | 180 ms | 180 ms |
| Linux, local filesystem (WSL) | 617 ms | 98 ms |
| wasm under node | 683 ms | 214 ms |

The Windows numbers are unchanged, as expected: its allocator already
has size classes. `bench/regexloop.ts` on Linux went from 85 to 67 ms. Through the wasm build the same loop went from
seconds and an out-of-bounds trap to 46 ms, since it no longer asks the
allocator for a bigger block at every step.

What remains in the ramda number: the ~55 ms process floor, 368 file
reads (~34 ms), a realpath per new module (~26 ms) and one existence
check per import edge (~40 ms). `bench/strindex.ts` tracks the string
cost; the loader and compiler have no dedicated benchmark yet, the
package examples in `web/` are the practical one.

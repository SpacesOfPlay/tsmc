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
| `exceptions` | 61 ms | 92 ms | **0.9x** | throw, catch and finally in a loop |
| `strbuild` | 139 ms | 110 ms | 1.9x | a string built by `+=` and templates |
| `sort` | 46 ms | 61 ms | 1.9x | `Array#sort` with a comparator |
| `objprop` | 171 ms | 91 ms | 3.3x | computed string keys on fresh objects |
| `json` | 263 ms | 109 ms | 3.8x | `JSON.stringify` and `parse` of nested data |
| `collections` | 91 ms | 60 ms | 5.0x | `Map` and `Set` insert, look up, iterate |
| `regexloop` | 188 ms | 78 ms | 5.2x | `new RegExp`, `test`, `replace` with a function |
| `promises` | 341 ms | 78 ms | 9.8x | `await` chains and `Promise.all` |
| `iterators` | 590 ms | 77 ms | 18x | generators, `for-of`, spread, destructuring |
| `fib` | 1,137 ms | 91 ms | 24x | recursive calls and arithmetic (fib(34)) |
| `arrays` | 448 ms | 62 ms | 25x | `map`/`filter`/`reduce` with closures |
| `strindex` | 435 ms | 60 ms | 28x | `charCodeAt` and indexing over 420k units |
| `bytes` | 495 ms | 61 ms | 30x | typed-array element loops |
| `classes` | 864 ms | 62 ms | 50x | instantiation and dispatch through inheritance |
| `proto_chain` | 532 ms | 47 ms | >52x | reads down a four-deep prototype chain |

## What five rounds of 2026-09-12 changed

| bench | before | after |
|---|---|---|
| `sort` | 94x | 1.9x |
| `collections` | 77x | 5.0x |
| `bytes` | 44x | 30x |
| `proto_chain` | >65x | >52x |
| `classes` | 52x | 50x |
| `arrays` | 29x | 25x |
| `fib` | 27x | 24x |
| a tight loop | 51 ns/iteration | 20 ns |

**Two algorithms.** `Array#sort` was an insertion sort and `Map`/`Set` looked a
key up by scanning every entry, so filling either cost O(n^2): 500, 1k, 2k and
4k keys took 3, 12, 49 and 202 ms where node takes none of them longer than a
millisecond. A merge sort and a hash index made those 0, 1, 1 and 2.5 ms.

**Three costs in the interpreter,** found with `minc profile` rather than
guessed at: the arithmetic and relational opcodes asked whether both operands
were primitive -- two calls that each make three more -- before trying the
integer path; two helpers ran on every call and every return only to test two
flags; and `i++` in statement position on a plain local was six opcodes.

**Two more in what the opcodes call.** A property read went through four nested
calls per level of the prototype chain, and one function does it now. A typed
array looked its own layout up in its property table three times per element,
and it is fields now. The garbage collector walked every cell in the heap
looking for weak collections, twice per collection, for programs that have none.

**And one pair of opcodes became one.** A comparison whose result the next
instruction consumes -- a loop test, an `if`, a ternary -- is a single
instruction, with the boolean never reaching the stack.

## Reading the numbers

- **Startup is a genuine strength**, and `exceptions` is the one workload where
  tsmc beats V8 outright: a throw costs about the same on both, and the process
  starts sooner.
- **The runtime-bound band is 2-5x** (`strbuild`, `sort`, `objprop`, `json`,
  `collections`, `regexloop`): the work happens in C-like code either way, and
  V8's compiler has little to add. Real dynamic JavaScript lives closer to this
  band than to `fib`.
- **What the interpreter walks one bytecode at a time is 18-30x.** That is the
  architecture: V8 compiles `fib`, array callbacks and typed-array loops to
  native code with unboxed values.
- **A shape-heavy read is the worst of it** (`proto_chain` >52x, `classes` 50x).
  V8's inline caches turn a property read into a slot load; a property table per
  object pays a lookup every time. This is where the next work is.
- **8-15% of the remaining time is calls the compiler does not inline** -- the
  tag predicates a NaN-boxed interpreter asks several times per bytecode. Written
  up for minc, which fixed it in the inliner's round 2; tsmc gets it on the next
  release.

## Measuring on this machine

Two numbers from the same binary twenty minutes apart differed by 8% (`fib`
1,160 then 1,252 ms). Anything under about 10% has to be measured back to back,
one variant after the other in the same minute, or it is drift rather than a
result. `minc bench` running both engines in one pass is exactly that, and the
A/B of two builds wants the same treatment.

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

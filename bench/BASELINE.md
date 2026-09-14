# Performance baseline

Reference numbers for spotting regressions and measuring optimizations.
Update when the interpreter's performance characteristics change
materially; keep the methodology fixed so runs stay comparable.

## Environment

| | |
|---|---|
| Date | 2026-09-13 |
| CPU | AMD Ryzen 9 5900X |
| OS | Windows 11 x64 |
| minc | 0.9.14 |
| Node (reference) | v22.16.0 |

## Method

`minc bench` times every `bench/*.js` under both engines: the wall clock of
the whole process, one warm-up run discarded, then the least of three. The
least, not the mean — anything slower is the machine interfering.

Each engine's own startup floor (an empty script, least of nine after four
warm-up launches) is
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
| `exceptions` | 61 ms | 90 ms | **1.0x** | throw, catch and finally in a loop |
| `strbuild` | 138 ms | 109 ms | 1.9x | a string built by `+=` and templates |
| `sort` | 46 ms | 47-61 ms | 2-3x | `Array#sort` with a comparator |
| `collections` | 60 ms | 62 ms | 2.6x | `Map` and `Set` insert, look up, iterate |
| `objprop` | 170 ms | 93 ms | 3.2x | computed string keys on fresh objects |
| `regexloop` | 190 ms | 92 ms | 3.7x | `new RegExp`, `test`, `replace` with a function |
| `json` | 266 ms | 108 ms | 3.9x | `JSON.stringify` and `parse` of nested data |
| `promises` | 344 ms | 77 ms | 10x | `await` chains and `Promise.all` |
| `iterators` | 511 ms | 76 ms | 16x | generators, `for-of`, spread, destructuring |
| `objlit` | 420 ms | 61 ms | 25x | fresh records with fixed keys, kept and read back |
| `fib` | 1,200 ms | 90 ms | 26x | recursive calls and arithmetic (fib(34)) |
| `arrays` | 438 ms | 61 ms | 26x | `map`/`filter`/`reduce` with closures |
| `strindex` | 451 ms | 61 ms | 27x | `charCodeAt` and indexing over 420k units |
| `bytes` | 488 ms | 61 ms | 29x | typed-array element loops |
| `proto_chain` | 533 ms | 47-61 ms | 32-53x | reads down a four-deep prototype chain |
| `classes` | 821 ms | 60 ms | 54x | instantiation and dispatch through inheritance |

`sort` and `proto_chain` finish inside the noise of node's own startup floor, so
their ratios swing between passes on node's variance alone (`proto_chain` read
32x and >53x in two passes minutes apart). The tsmc column is the stable half of
this table.

## What the allocation round of 2026-09-13 changed

Before and after are the two commits built with the same compiler and timed
interleaved -- not two bench passes, which drift by more than this on workloads
nothing touched:

| bench | before | after | |
|---|---|---|---|
| `objlit` (new) | 576 ms | 440 ms | -24% |
| `collections` | 71 ms | 62 ms | -12% |
| the other thirteen | | | see below |

| workload | before | after | |
|---|---|---|---|
| 400k six-key object literals | 200 ms | 115 ms | -42% |
| iterating 2k-entry `Map`s and `Set`s, 300 times | 927 ms | 460 ms | -50% |
| copying 50k-element arrays | 127 ms | 120 ms | -5% |
| `filter`/`map`/`slice` over 2k elements | 195 ms | 192 ms | - |
| markdown render, data plumbing, `JSON.parse` | | | within 3% |

Three paths stopped allocating what they did not need: a literal's plain keys go
onto a table sized once, without the three lookups a general define makes; an
array whose size is known before it is filled is allocated once instead of
doubling from eight; and a `Map` or `Set` iterator hands over its entry without a
result object. `doc/DESIGN_allocation.md`.

`objprop` and `iterators` not moving is the fast paths' guards working as
intended: `objprop` writes computed keys, and `iterators` is generators and array
`for-of`, which the previous round already handled.

## What the round of 2026-09-14 changed

Profiled first, three of the four items came straight off the profile, and the
fourth was a mistake the next profile caught.

| bench | before | after | |
|---|---|---|---|
| `bytes` | 453 ms | 423 ms | -6.6% |
| string-keyed comparisons (a micro) | 434 ms | 414 ms | -4.6% |
| `arrays` | 401 ms | 387 ms | -3.5% |
| data plumbing | 386 ms | 374 ms | -3.1% |
| `iterators` | 509 ms | 496 ms | -2.6% |
| `sort` | 35 ms | 34 ms | -2.5% |
| `classes` | 786 ms | 768 ms | -2.3% |
| `collections`, `json`, `objprop`, `fib` | | | -1.4 to -1.7% |
| the rest | | | flat, none worse |

**ToNumber asked whether its argument was a Symbol first**, which is a question
about a heap cell, before any tag test -- and nearly every coercion is handed a
number. Two tag tests first. Typed-array writes coerce on every element, which is
where the 6% comes from.

**The three equality predicates asked up to four kind questions each** (string?
string? BigInt? BigInt?). Only two kinds compare by content rather than by cell,
and both sides must be that same kind, so one read of each answers all of it. It
also fixed `Object.is(10n, 10n)`, which was false because SameValue had no BigInt
branch where the other two did.

**`toFixed` called `pow` for ten to a small integer**, 2.2% of the data workload
by itself; it is a table up to 22, which is as far as a double counts powers of
ten exactly.

**Tried and reverted: folding the four relational operators into a mask.**
`cmp_rel` ends in four compares of the opcode against a constant, so a
branchless `(x>y)-(x<y)` plus a table lookup looked strictly better. It measured
worse everywhere -- `strindex` +2.7%, markdown +0.9%, `fib` +0.7%, and it gave up
1.6% of the `bytes` win -- because the operator is the same on every iteration of
a loop, so those four compares are perfectly predicted, while the three-way
compare does real work on both sides. The next profile showed `cmp_rel` had grown
its share while the program got faster, which is what gave it away.

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
- **8-15% of the remaining time is in the value predicates themselves** -- the
  tag tests a NaN-boxed interpreter asks several times per bytecode, each one a
  call. Keeping them small and free of anything cold is what makes that share
  shrink; `doc/DESIGN_property_access.md` has the measurements.

## Measuring on this machine

Three ways to get a number that is not about the change being measured:

- **What built the binary.** `bench` and `diff` build tsmc themselves, so the
  binary under measurement can be replaced between two timings without anything
  being said about it. Build every binary in a comparison the same way, from its
  own commit, and check the line the build prints; a toolchain of a different
  version is a different measurement, not a data point in the same set.
- **Drift between passes.** Two `minc bench` passes minutes apart put `fib` at
  1,108 and 1,200 ms and `classes` at 761 and 821 -- 9% on workloads nothing in
  between touched. `minc bench` is a snapshot against node, not an A/B between
  builds; for that, time the binaries interleaved.
- **Position inside a round.** The binary timed second read up to 6% faster than
  the same binary timed first. Reverse the order on every other run, and keep a
  control of one binary in both positions.

What is not a source of noise: the build is deterministic (the same source gives
a byte-identical binary), a comment edit leaves `.text` byte-identical, and moving
a private function changes 261 bytes of it.

With the order alternated and the least of eight taken, the same comparison
repeated minutes later moves by about 2% on the steady workloads and 5% on the
short allocation-heavy ones. Below that, rely on the mechanism rather than the
clock.

`minc bench`'s own startup floor is measured on a binary that was just written,
so it takes four warm-up launches before counting: it read 29 ms against a true
15 once, and an overstated floor is subtracted from every total and flatters
every ratio.

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

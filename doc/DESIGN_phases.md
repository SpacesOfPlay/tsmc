# Phase accounting: where a run's time goes, measured

`tsmc --phases script.js` prints, at exit, how the run's time divided
between the interpreter, the natives, the collector, the compiles and the
cache, and the natives by their own time. An embedder turns the same on
with `vm_phases_on(vm, level)` and reads `vm_phase_report`; brmc does so
under `BRMC_PHASES=1|2` and prints it with the trace's summary.

## Why

The engine's timers before this measured the parts that are easy to
wrap (the compiles, the collector) and left the interpreter as the
remainder of a wall clock; the natives had been timed once in an
instrumented build. Nothing checked the parts against each other, and
the inferences went wrong in the ways one expects: a timer around a
native counted the JavaScript it called back into, a per-op clock cost
more than the op, a sampler saw every thread and the idle. The
accounting here is exclusive and closed by construction, cheap enough
to run on a page load, and states its own cost.

## How

At any moment between `vm_phase_begin` and `vm_phase_end` one phase owns
the clock (`PH_*` in object.mc): the interpreter, a builtin, an
embedder's native, the collector, a lazy compile, a script's compile, a
cache read, the event loop's wait. A change of phase reads the counter
once (`qpc`, raw ticks; the report converts) and charges the elapsed
ticks to the phase leaving. The boundaries are:

- the three native call sites (`vm_native_begin` / `vm_native_end`),
  switching to the native's own phase (`JsNative.phase`: PH_NATIVE,
  or PH_HOST for one the embedder made) and back;
- the loop's entry, `vm_execute`, which pushes the phase it was entered
  under and switches to the interpreter, and pops on return: a native's
  callback is the interpreter's time, not the native's;
- `vm_lazy_compile`, `vm_load_templates`, the compile in
  `vm_run_source`, `vm_compile_source` and the module loader's;
- the reactor's waits (PH_IDLE, outside the sum).

The collector has no boundary of its own: it runs inside an allocation
inside whatever phase that was. Its time is taken from gc.mc's own
counters (`gc_stat_ticks` and the two sweep counters) at every switch,
noted beside the phase it interrupted and reported as one phase, so
that a native that allocated into a collection is not charged for it.

Nothing happens per op. The interpreter's figure is what remains when
every other phase has been charged: measured at its boundaries, not
inferred from a sum.

At level 2 each native's own time is kept by name (`NativeStats`, a
`StrMap` from the native's name): what the native phases gained during
the call, less what the natives under it (through its callbacks) took
for themselves. A `JsNative`'s name is a stable view, so the report at
the end can print it.

## What the report says, and how it is checked

```
tsmc: phases: interp 1284, natives 322, host 205, gc 189, lazy 60, compile 12, cache 20, idle 0;
      wall 2095 ms, residual 0 us; 7500418 switches at 19 ns, about 143 ms where the phases met;
      0 outside a span, depth 0
tsmc: natives by own time less the switch cost of their calls, 25 of 210: geometry 75.9 ms/1847, ...
```

- **residual** is the wall of the spans less the phases' sum. It is zero
  by construction when every entry into the runtime lies inside a span;
  **outside a span** counts the changes that did not, and **depth** must
  be 0 at the end. These check the plumbing, not the clock.
- **switches at N ns** is one switch's cost, measured when the
  accounting was turned on (4096 switches, the least of eight rounds),
  and **about M ms where the phases met** is what the switches came to
  in all; half of each landed on either side of the boundary. The
  natives' table has its calls times that cost taken out already, since
  the cost sits inside the call's span; the phases line does not.
- The lazy, compile, cache and collector phases wrap the same code as
  the engine's own counters for them, which a trace prints beside the
  report: brmc's bsky.app gives lazy 60 against 28 ms of lazy compiles
  and 33 taken ahead, cache 20 against 20, compile 12 against 12, gc 189
  against 152 marking and 36 sweeping.
- `tools/phases_cal.js` is a composition known in advance, one kind of
  time per section with its own wall clock: a counted loop is all
  interpreter (897 of 898 ms); 4 million `Math.abs` calls cost 80 ms
  without the accounting and 254 with, which is the switch cost (8
  million switches at 19 ns), and the native's own time after the
  correction is 13 ms; `reduce` over 4 million elements charges the
  callbacks to the interpreter; a garbage loop shows the collector.

## What it costs

A switch is about 19 ns on this machine: a `QueryPerformanceCounter`
read and a few adds. The count is the natives' calls times two plus the
loop's re-entries times two. Measured, the flag on against off on the
same binary: the 13-bench suite 3137 to 3797 ms (21%; the benches that
live in natives most, arrays 257 to 465), brmc's bsky.app busy 1834 to
1870 against 2003 to 2063 (9%, about 170 ms for 7.5 million switches
where the report estimated 143). So the figures a run reports are read
with the switches in mind: the phases line carries them where the
phases met, the natives' table has them taken out.

The flag off, the native call sites keep their old shape behind one
load and one branch, the loop's entry one more, and nothing per op: the
bench suite 3023 against 3027 ms against the build before it. bsky.app
busy 1761 to 1811 against 1823 to 1852 with one more major collection
in the window (marking 119 to 165 ms, the longest 26 to 59): the
`JsNative` grew by its phase field, the collector's thresholds fell
differently, and a major collection moved into the measured span. That
is a caution for every A/B on the page, not a cost of this: a build
that differs by a struct's size can move 40 ms of collection in or out
of busy, and the trace's collection counts say when it has.

## Below the phases: the loop by case, sampled

The phases do not divide the interpreter's time by opcode, and no
clock in the loop could without costing more than an op. What can is a
sample of the thread's instruction pointer from outside, mapped back
to the case it is in. `tools/ripsample.mc` (Windows x64) starts the
program and every `interval_us` suspends its main thread, reads RIP
and resumes it, into a histogram of addresses as the image sees them;
`tools/ripmap.py` maps the histogram to functions (the header lines of
`minc-dbg --disasm --all` on the same `-g` binary), to files, and
inside `vm_execute` to the case each instruction belongs to, walking
`minc-dbg --disasm <exe> vm_execute` in address order with the
source's `case` lines; a tag from an inlined callee keeps the case it
is in, the code before the first case is `loop head`, after the switch
`loop tail`. `--lines CASE` lists a case's source lines by sample.

```
minc -g src/main.mc -o tsmc_g.exe
minc-dbg --disasm --all tsmc_g.exe | grep -E '^\S.*  \S+:[0-9]+  0x' > fns.txt
minc-dbg --disasm tsmc_g.exe vm_execute > loop.asm
ripsample hist.txt 250 tsmc_g.exe bench/fib.js
python tools/ripmap.py --fns fns.txt --loop loop.asm --src src/vm.mc hist.txt
```

A sample is a suspend and a resume, about 10 us of the program's time
at 250 us apart, 4% spread evenly; `-g` changes no code. Checked on
fib: 99.8% of the samples in `vm_execute`, CALL and RETURN first. Two
things the mapping has to work around until the sampler does this
itself: the function table of `--disasm --all` omits every function
whose line info has no file (`str_find <unknown>:78`; in brmc 2.1 MB
of the 5.6 MB of text), so those are looked up by name
(`fill_fns.py`), and an inlined callee's tag names the caller's file
with the callee's line, so the mapping goes by case, not by line, for
anything outside `vm_execute`'s own lines. Both are asked of the lang
project in its `doc/REPORT_codegen_vm_loop.md`.

## What it does not do

It does not see other threads: the loader's compiles ahead are their
own report. A native's name is what the table keys on, so two natives
of one name are one row.

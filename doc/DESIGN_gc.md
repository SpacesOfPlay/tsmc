# Garbage collector

Decision: **precise, non-moving mark-sweep**, designed in from M1.

## Goals

- Correct collection of arbitrary object graphs, including cycles.
- Stable addresses: a cell never moves, so native code can hold raw
  pointers across allocations as long as the cell is rooted.
- Minimal destructors: cells prefer one inline allocation, but kinds
  with dynamic parts (property tables, element arrays) register a
  finalizer hook that frees them at sweep and teardown.
- All state hangs off `GcHeap` (inside the runtime struct); no
  globals. Runtime kinds plug in via tracer/finalizer/mark-roots
  hooks so the heap stays generic.

Non-goals for now: moving/compacting, generations, incremental marking.
The design leaves room (cell header has spare bits; allocation is
behind one function) but none of it is built until profiling asks.

## Cells

A cell is one heap allocation starting with a `GcCell` header:

```
struct GcCell { GcCell* next; i64 size; i32 kind; i32 mark; }
```

- `next` links every cell into the heap's all-cells list (sweep walks
  it). Replaced by size-class pages if allocation ever profiles hot.
- `kind` selects the trace function and payload layout. Kind-specific
  structs embed the header as their first field (`GcString`, `GcPair`,
  later `GcObject`, …). Variable-size payloads (string bytes) follow
  the struct inline — one allocation, no out-of-band buffers.
- Payloads are zeroed at allocation; zero bits must be a safe state
  for every kind.

## Collection

Mark: walk the root set, push reachable cells onto an explicit
worklist (no recursion — JS graphs can be arbitrarily deep), trace by
`kind`. Tracing a kind the collector does not know is a hard error,
not a silent leak of children.

Sweep: walk the all-cells list; free unmarked cells, clear marks on
survivors, recompute live bytes.

Trigger: `bytes_live >= next_gc` at allocation time, with
`next_gc = max(2 × live_after_sweep, 256 KiB)`. A `stress` flag
collects on every allocation — tests run with it on to surface
missing roots immediately.

## Roots

- An explicit root stack (`Vec<Value>`) with push/mark/reset — the
  handle mechanism for native code and, later, the embedding API.
- The VM adds its own precise roots in M5: value stack, call frames,
  globals, module registry.
- Atom table strings live outside the GC (see PLAN_M1); they are not
  roots.

**Contract: any `gc_alloc` may collect.** Native code roots every
intermediate Value it needs across a subsequent allocation. The stress
mode exists to make violations fail fast in tests.

## Shutdown

`gc_destroy` frees every cell on the all-list unconditionally — the
runtime owns all cells, so teardown needs no marking.

## Tests

`test/unit/test_gc.mc`: unrooted garbage collected; rooted cells
survive with contents intact; nested graphs fully traced; unrooted
cycles collected; a rooted 100-node list built under stress mode
survives with every node checked.

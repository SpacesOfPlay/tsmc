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

Non-goals: moving/compacting and incremental marking. Generations came
with profiling (below); the cells still never move.

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
missing roots immediately. Under stress the sweep keeps a dead cell's
memory instead of freeing it, fills it with `0xAB` and sets its kind to
-1, so a reference that outlived its root reads an invalid kind at once
rather than whatever the allocator put there next; `value_is_kind`
reports the first such touch on stderr. The test runner holds each
stress run's output against a plain run, since a stale read can also
corrupt output without failing.

## Cell memory

Cells come in a few dozen sizes and turn over constantly. The sweep
does not hand a dead cell back to the program allocator; it keeps it on
a free list for its size class, and `gc_alloc` takes from that list
before asking for fresh memory. Classes step by 16 bytes up to 1 KB and
by a quarter of each doubling up to 128 KB; a larger cell, a big string
or buffer, is allocated and freed directly. A cell's recorded size is
its class size, so accounting and the stress poison cover the whole
block. This keeps the heap's churn away from the program allocator,
which on the wasm and linux targets scans a single first-fit list for
every request; measured there, loading date-fns fell from 680 to about
200 ms and from 620 to under 100 ms, while Windows, whose allocator has
size classes of its own, was unchanged. Memory held on the lists is
returned at `gc_destroy`.

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

## Generations

A cell keeps its mark once set: a cell that survived a collection is
old, and the marks are the generation. A **minor collection** marks from
the roots and from the old cells written since the last collection,
traces only the young cells it reaches (`gc_mark_cell` stops at a set
mark), and sweeps only where young cells can be. A **major collection**
clears every mark first and does the whole heap as before. Minors come
every `minor_threshold` bytes of allocation; a collection is a major
instead when the minors' survivors have grown the old past the
threshold the last major set from its live bytes. The young garbage
never brings a major on its own: a benchmark with a tiny live set used
to run a full collection every 256 KB (the floor of that threshold),
and now runs minors only. The young size is small, 1 MB (ts-minc
`GC_MINOR_THRESHOLD`, brmc `BRMC_GC_MINOR_KB`): the young live in a
few chunks that stay in the cache when they are recycled every
megabyte, and bsky.app ran slower with each doubling of it, 8 MB
costing 10% more and 32 MB a third.

**The write barrier.** A store of a young cell into an old one goes
through `gc_barrier(holder, v)`, or `props_barrier` for a property
table, which puts the holder on a remembered list; the next collection
traces the remembered cells and tables before it drains its mark
stack. The barrier is needed on every store into a cell's slots, the
ones made right after the cell's allocation included: an allocation in
between (the child's own, say) can run a collection that ages the
holder. The stores are few places: the property-table primitives in
`object.mc`, `js_array_set`, the box writes of `OP_SETCELL` and
`OP_SETUPVAL`, the accessor halves, a map's entries, a generator's
saved stack and queue, a prototype change, and the natives' `env`
slots. A property table's generation rides in the top bits of its
`cap` (`PROPS_OLD`, `PROPS_REMEMBERED`), set when the table is traced,
so the table needs neither its owner nor the heap to decide.

The remembered lists are the thread's, shared by every heap on it
(brmc has a heap per tab), since the barrier knows neither: every
collection on the thread drains both lists, tracing an entry into
whichever heap collects first. A foreign entry marks its young
referents old a little early and nothing else; an entry never outlives
its cell, because a cell dies only in a collection of its own heap,
and a heap being destroyed takes its entries off the lists.

**Where the young go.** A chunk keeps its own free list, and a class
fills one chunk at a time (`bump[cls]`): its free cells, then its
unused tail, then the next chunk on the class's list of chunks with
free cells (`avail`), which a major's sweep orders emptiest first.
A chunk less than half free is passed over for a new chunk until the
chunks' memory reaches the major's threshold: the young filling the
holes of a nearly full chunk lay a cell here and a cell there, and
each cost a cache miss to sweep and to mark (38 ns a cell against 10
in a stream, on bsky.app). The chunks a minor empties go to the front
of their class's list, so the next young fill the same chunks: a
nursery, with no space set aside for one.

**The sweep.** A minor sweeps at once, and only the chunks allocated
into since the last collection (`young_chunks`), each over the range
of cells handed out (`lo..hi`, kept by the allocator, the index by a
multiply with `inv` rather than a division); an old cell in the range
is marked and passed by. A major's sweep is lazy as before, every
chunk, and a cell allocated where it has yet to reach is `GC_FRESH`:
young, but the sweep passes it by instead of freeing it, and the chunk
stays young for the next minor. Large cells made since the last
collection sit on `young_large`, apart from the old ones on `all`.
Template constants, which never change after a compile, are marked by
a minor only for the templates compiled since the last collection
(`fresh_tmpls`).

**Checking the barriers.** Under `--gc-stress` every allocation runs a
minor collection, every 64th a major, and after each one `gc_verify`
walks the whole graph from the roots again, with its own visited bit,
and stops the program naming the kinds of holder and cell when a live
cell is unmarked: a store that went without its barrier. The embedder
can run the same walk without the stress (brmc: `BRMC_GC_VERIFY=1`),
which is how the barriers were found on a page that allocates too much
for stress to be practical.

## Shutdown

`gc_destroy` frees every cell on the all-list unconditionally — the
runtime owns all cells, so teardown needs no marking.

## Tests

`test/unit/test_gc.mc`: unrooted garbage collected; rooted cells
survive with contents intact; nested graphs fully traced; unrooted
cycles collected; a rooted 100-node list built under stress mode
survives with every node checked.

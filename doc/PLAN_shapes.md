# Plan: shapes

Status: phase 0 measured 2026-11-08, the gate not met: shapes would cut
the property reads' deeper misses by a quarter or more, the allocations'
lines by 23% and the marking's not at all, for an estimated 5% of
bsky.app's busy time and a quarter of its heap. The plan stops here
unless that memory is wanted for its own sake ("Phase 0, measured"
below). The accessor test alone measured worse and is not kept.

## Why

The interpreter's instruction paths are no longer where bsky.app's time
goes. After the register bytecode's phases 3 and 4 and the return's
reload (PLAN_register_bytecode.md), the sampler on the saved page (three
runs, 250 us) puts the loop at 686 ms a run, and in it:

- property reads about 190 ms (GETPRL 80, RGETPROP 45, GETPROP 43,
  GETMETHOD 25), and within the inline cache's hit nearly all of it on
  two loads: the property's entry (the key compare, which brings in the
  entry's line: 292 samples) and the header of the value's own cell (the
  test that the property is not an accessor: 196);
- allocation 106 ms (`gc_alloc_zeroing`, the first touch of a free cell
  and its zeroing) and marking about 130 (`gc_mark_cell`, `js_trace`,
  `mark_props`).

What was tried on these and measured: removing dispatches is free
(phase 5's register call); a cached code pointer in the function object
flat; an index stack for a chunk's free cells flat to worse, the miss
moving to the zeroing; a per-entry accessor flag slower, the value's
cell being read soon after anyway. What is left is memory: lines touched
for the first time. The lever on that is fewer bytes per object.

An entry today is 16 bytes (`Prop`: a u32 key, a u8 of flags, an 8-byte
value), and an object's first entry starts 80 bytes into its cell
(`JsObject`: the cell header, flags, prototype, the table's header, the
array part's three fields). With shapes, the keys and flags move to a
shape the objects built the same way share, and an object is its shape
and its values, 8 bytes each: a 20-field object goes from 400 bytes over
seven lines to 216 over four (a 56-byte header: the cell's, the flags,
the prototype, the shape, the value array's pointer), and an object's
first value sits on its header's line. Every cold read, every allocation's zeroing and
every mark of the object touch fewer lines, and the accessor test reads
the shape, which is shared and so likely in cache, instead of the
value's cell.

`DESIGN_property_access.md` (2026-09) sketched shapes for a different
reason, the inline caches; those exist now (`prop_get_ic_fast`, the
own-slot code in the instruction, the prototype and aux entries). This
plan is about density and the accessor test, and keeps the caches'
design, changing what they compare.

## What it cannot win, and the cost it adds

- A single cold read of a single property still misses on the value's
  line. Shapes win where an object's reads, its allocation and its
  marking span lines that the denser form does not: phase 0 measures how
  often that is.
- Per-object state costs about 1% globally before it buys anything
  (DESIGN_property_access.md, the two reverted attempts). A shape
  pointer replaces the table's 24-byte header, so the object does not
  grow; the shapes themselves are new memory and new misses.
- Objects used as dictionaries (keys added and deleted at will) make a
  shape per key set. They need a dictionary mode, which is the table of
  today, and a rule for when an object goes to it.

## The design

**A shape** is an immutable, shared node: its parent, the key it added,
that key's flags (writable, enumerable, configurable, accessor), its
slot number, the slot count, and a transition table from (key, flags)
to the child that adds it. The empty shape is the root. Objects built by
the same steps reach the same shape. A shape answers "where is key k"
by walking to the root for a small slot count and from a key-to-slot
table it builds on first use above that; the table is the shape's, so
its cost is paid once per shape, not per object.

**An object** holds its shape and a value array: inline in its cell for
the room it was made with (`js_new_object_room`'s count, as today), then
in the pool. The prototype stays in the object, not the shape, so
`Object.create(p)` for many p does not multiply shapes, and the
prototype caches keep their epoch.

**Dictionary mode.** `delete` of a property not last, a `defineProperty`
that changes an existing property's flags, more than 64 properties, or
a shape whose transitions pass 32 children (phase 0: far too few), and the object takes a
private table of today's form (`PropList` with its index). Such objects
are rare on the pages measured; phase 0 counts them.

**The caches.** An own-slot hit today compares the key in the object's
entry; with shapes it compares the object's shape id with the one the
site saw and loads the value at the slot. The instruction's u16 cache
field cannot hold a shape id and a slot, so the field widens to u32 (a
20-bit shape id, a 12-bit slot) for the own case, and the prototype and
aux cases keep their codes above it. The accessor test is a bit of the
shape the site recorded, so a hit loads no value cell.

**The API stays.** Everything outside object.mc goes through
`props_get`, `props_set_desc`, `props_entry`, `props_order`,
`props_remove` and a few others (some 340 call sites, 189 of them
`props_set_desc` in the builtins' setup). They keep their signatures and
dispatch on shape or dictionary, so the builtins and brmc's bindings do
not change. The code that reads the entries directly, under 80 lines in
object.mc, vm.mc and builtins.mc, is what gets rewritten.

## What stays the same, and has to be checked to

- Enumeration order: integer keys ascending, then strings and symbols in
  insertion order (`props_order`). A shape's insertion order is its
  chain from the root.
- Property attributes and their errors in strict and sloppy code:
  frozen, sealed, non-extensible, read-only, accessors.
- The generational barrier: the table's PROPS_OLD and PROPS_REMEMBERED
  bits ride in `cap` today; they move to the value array's header.
- Prototype marking (PROPS_IS_PROTO, `g_proto_epoch`), which the absent
  and prototype caches depend on.
- Functions' and natives' own properties (`JsFunction.props`,
  `JsNative.props`) and the synthesized name and length.
- The global object and module namespaces, proxies, typed arrays and
  arrays' named properties, which keep their own paths.
- The code cache (a version bump: the cache field widens).

## The checks every phase passes

1. **Behaviour.** ts-minc's `minc test` (404 checks, the goldens, the
   282 scripts under `--gc-stress`), `--code-cache-verify` and
   `--code-cache-ahead`, the 417 scripts the same at head and at the
   change (the comparison `tools/reg_check.sh` runs, with two binaries);
   `build/build.exe diff` against node; brmc's 35 test modules and the
   bsky.app shot's checksum.
2. **A probe per phase** of what it touches, the same at head, at the
   change and in node: enumeration order with integer, string and symbol
   keys mixed and deleted; defineProperty on every flag; freeze, seal,
   preventExtensions; accessors added, replaced, deleted; objects that
   cross into dictionary mode in every way listed above; prototypes
   changed under a cached site.
3. **Memory.** bsky.app's heap at the end and its marking and sweeping
   (BRMC_TRACE), the shapes' count and bytes, the objects in dictionary
   mode.
4. **Time.** Head built from the same tree after the last pull, five
   interleaved runs, the least of each: the bench suite and bsky.app's
   busy, first run and first frame; the sampler on bsky for the
   property cases and the allocator.

A phase whose numbers do not justify it is reverted.

## Phases

**0. The premise, measured three ways, before anything is built.**

- *A trace and a cache model.* A profiling build logs each own-slot read
  and write that the cache serves, and each allocation, as (object,
  slot) and (cell, size), for bsky.app's load. A small simulator replays
  the log through a model of the L1 and L2 (32 KB and 1 MB, 64-byte
  lines, LRU) under today's layout and under the shape layout (the
  object's values at 8 bytes from its header's end, the header 56
  bytes). Output: the misses each layout takes on the reads, the
  allocations and the marking's walk of the same objects. This is the
  number the plan rests on.
- *The accessor test alone.* An object flag set when an accessor is
  defined on the object, and the cache's hit skipping the value cell's
  header when the flag is clear: the one part of the shapes' gain that
  can be had without them. Measured on bsky and the benches; if it pays,
  it is kept on its own whatever the rest decides.
- *The shapes a page makes.* From the same trace, the key sequences
  objects are built by, replayed into a transition tree: the shape
  count, the largest fan-out, the objects that would go to dictionary
  mode under the rules above, the bytes of property storage now and
  under shapes.

Gate: the model says shapes remove at least a quarter of the property
reads' misses and of the allocations' and marking's lines, the shapes
are a few tens of thousands at most, and dictionary mode is a few
percent of objects. Otherwise the plan stops with the numbers.

**1. Shapes behind the API, no cache change.** The shape tree, objects
holding shape and values, dictionary mode, every `props_*` function on
both forms, the entries' direct users rewritten, the GC tracing the
value arrays and keeping shapes (shapes are never freed in this phase;
their count is checked 3). The caches keep their current form, reading
the slot from the shape where they read the entry. Expected: memory and
marking down by what phase 0's storage figure said; reads about level;
the benches within noise.

**2. The caches on shape ids.** The u32 cache field, the own hit as a
shape id compare and a slot load, the accessor bit from the shape.
Expected: the property cases' samples down by what the model said for
reads.

**3. Writes.** An existing data property's store on a shape compare; an
add that the site has seen as a transition (old shape to new, the slot,
the prototype epoch under which no setter or read-only property above
intercepts it) without the chain walk. Expected: SETPROP, SETPRPOP and
the constructors' `this.x = x`.

**4. Shapes freed.** Shapes no object and no cache reaches are
collected, if phase 1's count says it matters on a long-running page;
otherwise recorded as not needed.

**5. Cleanup.** The old entry form kept only for dictionary mode;
`DESIGN_property_access.md` rewritten for shapes; this plan records what
each phase measured.

## Phase 0, measured (2026-11-08)

**The trace.** `src/memtrace.mc` and its hooks in gc.mc, object.mc and
vm.mc, compiled in only with TSMC_MEMTRACE (a default build is byte for
byte the same binary), log the allocations, the frees, the tables'
growth, additions, removals and flag changes, the cache's own-slot and
prototype hits, reads and writes, and the marker's visits.
`tools/memsim.mc` replays the log into four copies of the heap (the real
addresses, and a model of the allocator and the pool under today's
layout, shapes with a 56-byte header, and with a 64-byte one that keeps
the elements' fields) through an L1, L2 and L3 of the machine measured
on (32 KB, 512 KB, 32 MB; 64-byte lines, LRU). bsky.app's saved page,
one load: 38.7 million events, 1.43 million objects. The allocator's
model against the real addresses: within 2% on reads and marking, 11% on
the allocations' L3 misses.

**Misses, today against shapes56:**

| | L1 | L2 | L3 | lines touched |
|---|---|---|---|---|
| own-slot reads | 10.52M to 8.61M, -18% | 2.74M to 1.98M, -28% | 503k to 318k, -37% | -5% |
| prototype reads | 523k to 337k | 109k to 63k | 14k to 5k | -28% |
| allocation (the zeroing) | 4.66M to 3.82M, -18% | 4.56M to 3.67M, -19% | 2.50M to 2.02M, -19% | 6.25M to 4.79M, -23% |
| marking | 7.20M to 6.18M, -14% | 6.56M to 5.47M, -17% | 1.89M to 1.31M, -31% | +4.5% (a shape line per object) |
| additions | 354k to 1.16M | 336k to 477k | 164k to 129k | +71% (the transitions) |
| all | -14% | -19% | -26% | +0.5% |

Weighted by latency (3 ns an L2 hit, 10 an L3 hit, 80 a miss), the
three areas the plan is about fall by 23%, reads 28%, marking 26%,
allocation 19%. The sampler puts those areas at about 430 ms of a
1790 ms busy load, so the estimate is about 100 ms, some 5%. The model
leaves out every other access (the stack, the code, strings, the DOM),
and measured on the accessor test below it took a removed read for a
gain that the hardware did not show; it is an upper bound.

**The shapes a page makes.** 29,500 shapes (1.6 MB), 22,800 of them
with one child; the root and one depth-1 shape reach the 1,536-child cap
that stands in for a transition limit, with 1,220 objects (0.08%) sent
to a dictionary, 716 of them by that cap, 418 by a removal, 65 past 64
properties, 21 by a change of flags. A cap of 32 children, as first
written above, sent 770,000 objects to dictionaries: the root's
children are the first keys of every object literal and constructor,
so the cap has to be per shape and far larger, or the root exempt.

**Memory.** The live objects and their tables at the end: 90.2 MB today,
56.3 MB with shapes; every cell and table, 125.7 MB to 91.9 MB, 27% less.
That is the plain win: the entries' keys and flags move out of 521,000
objects into 29,500 shapes.

**The accessor test alone.** A table bit set when an accessor is
stored, and the cache's hits on a table without it not reading the
value's cell: no script differs from head (417, plainly and under
`--gc-stress`), a build that checks the bit at every hit never fired,
and the probe matched node. The bench suite 2734 to 2750 ms; bsky.app
busy 1790 to 1802 (median 1801 to 1822), the shot the same. The model
had said 12% fewer read misses: the value's cell is read soon after by
whoever uses the value, and the miss moves there, as the per-entry flag
found before. Not kept.

**The gate.** Reads' misses: a quarter or more at L2 and L3, 18% at L1.
Allocation's lines 23%, marking's lines up, their deeper misses down
17 to 31%. Shapes within a few tens of thousands, dictionaries well
under a few percent. Two of the three conditions on misses are not met
as written, and the time they would buy, about 5% at most, is less
than the weeks of phase 1 and the risk in it. The memory is a
different case: a quarter of the heap on a page this size. If memory
becomes the goal, phase 1 alone (shapes behind the API, the caches as
they are) is where it comes from, and its own check 3 measures it.

## Risks, and where each is caught

- **The 1% per-object cost.** Caught by the bench suite in phase 1,
  against phase 0's storage figure: if the denser objects do not pay for
  the shape lookups before the caches change, phase 2 has to.
- **Shape explosion** on pages that use objects as maps. Caught by
  phase 0's count and the dictionary rules; a cap on transitions per
  shape is the backstop.
- **Enumeration order and attributes**, the places a shape system most
  often goes wrong. Caught by the probe, test262's subset and node's
  diff.
- **A missed root** in a value array or a shape's key. Caught by
  `--gc-stress` and the stale-slot clearing build.
- **The frame-size rule**: new cases in `vm_execute` declare no locals
  and delegate.
- **brmc.** Ported each phase with the same patch; brmc's bindings only
  use the API, which phase 1 keeps.

## Cost

Phase 0 is two or three days. Phase 1 is the bulk: a week or two, most
of it in object.mc and the entries' direct users. Phases 2 and 3 are days
each; 4 and 5 days together.

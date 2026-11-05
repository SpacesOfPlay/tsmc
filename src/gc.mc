// gc.mc — GC heap: cell allocator and precise mark-sweep collector.
//
// Cells are single variable-size allocations with a GcCell header
// first. Non-moving: addresses stay valid for a cell's lifetime.
// Any gc_alloc may collect — root intermediate values first.
// See doc/DESIGN_gc.md.

import vec;
import value;
import ustr;

// Kinds 0..1 are built in; higher kinds belong to the runtime layer,
// which registers tracer/finalizer hooks for them.
enum GcKind {
    GC_STRING,
    GC_PAIR,
}

struct GcCell {
    GcCell* next;
    i32 size;
    i32 chunk;      // the chunk a small cell lies in, plus one; 0 for a large cell on the heap's list
    i32 kind;
    i32 mark;       // 0 young; GC_OLD, GC_REMEMBERED, GC_FRESH below
}

// A free small cell, on its class's list: the sweep passes it by.
const i32 GC_FREE = -2;

// Small cells (1 KB and less) lie in chunks of their size class, one after
// another, and the sweep walks a chunk in address order: the list of every
// cell it followed before took a cache miss a cell, live or dead, and that
// was most of a collection. A large cell is its own allocation, on a list.
const i64 GC_CHUNK_BYTES = 65536;

struct GcChunk {
    u8* mem;
    i32 cls;
    i32 cell;       // the cell size
    i32 cap;        // cells it holds
    i32 used;       // cells handed out so far, from the start
    bool young;     // a cell was handed out of it since its last sweep: a minor collection sweeps it
    i32 lo;         // the cells handed out since its last sweep lie in lo..hi: what a minor's sweep walks
    i32 hi;
    u32 inv;        // ceil(2^32 / cell): a cell's index is (offset * inv) >> 32, exact for a 64 KB chunk, without the division
    // its dead cells, handed out again before any other chunk's: new cells
    // fill one chunk at a time, the emptiest first, so the young lie close
    // together and a minor's sweep streams through them instead of taking a
    // cache miss on each (one in five cells, 38 ns a cell against 10)
    GcCell* free;
    i32 n_free;
    i32 next_avail;  // the next chunk of its class with free cells, -1 at the end
    bool avail;      // on its class's list of chunks with free cells
}

type CellPtr = GcCell*;
type GcTraceFn = fn(GcHeap*, GcCell*): void;
type GcFinalizeFn = fn(GcCell*): void;
type GcMarkRootsFn = fn(GcHeap*, void*): void;
// Ephemeron support: mark the values of weak entries whose key is live,
// returning true if it marked anything new (looped to a fixpoint). The
// sweep hook drops entries with dead keys, run while marks are still set.
type GcWeakMarkFn = fn(GcHeap*, void*): bool;
type GcWeakSweepFn = fn(GcHeap*, void*): void;
// A remembered property table traced (object.mc, which knows its layout).
type GcPropsTraceFn = fn(GcHeap*, void*): void;
type VoidPtr = void*;

const i64 GC_MIN_THRESHOLD = 262144;

// cell size classes: 64 of 16 bytes up to 1 KB, then 4 per doubling to 128 KB
const i32 GC_CLASS_SMALL = 64;
const i32 GC_CLASS_COUNT = 92;
const i64 GC_CLASS_MAX = 131072;

struct GcHeap {
    GcCell* all;
    // The last collection's cells not swept yet (gc_sweep_some), apart
    // from `all`, which takes the survivors and what is allocated meanwhile.
    GcCell* sweep_list;
    i64 marked_bytes;     // counted while marking: the live bytes
    i64 marked_cells;
    i64 bytes_live;
    i64 next_gc;
    bool stress;          // collect on every allocation (tests)
    bool verify;          // the whole graph checked after every collection (gc_verify), without the stress
    bool trace;           // a line per collection on stderr: its kind, what it marked, what it took
    i64 n_cells;
    i64 n_collections;
    Vec<Value> roots;
    Vec<CellPtr> mark_stack;
    GcTraceFn tracer;         // child marking for runtime kinds
    GcFinalizeFn finalizer;   // frees a cell's non-GC allocations
    GcMarkRootsFn mark_roots; // extra roots (VM stack, globals, …)
    GcWeakMarkFn weak_mark;   // ephemeron marking (WeakMap/WeakSet)
    GcWeakSweepFn weak_sweep; // drops dead-keyed weak entries
    GcPropsTraceFn props_trace;
    void* mark_ctx;
    // generations: the large cells made since the last collection, apart
    // from `all`, which holds the old ones; what the old cells amount to;
    // the young bytes a minor collection waits for; which kind of
    // collection is under way, and whether its sweep takes every chunk
    GcCell* young_large;
    i64 old_bytes;
    i64 old_cells;
    i64 minor_threshold;
    bool minor_pass;
    bool minor_sweep;     // the sweep counted in sw_ticks was a minor's, for the trace
    Vec<i32> young_chunks; // the chunks allocated into since the last collection: what a minor sweeps
    i64 n_minor;
    i64 sw_ticks;         // the sweep under way: its time, cells visited and chunks entered, for the trace
    i64 sw_cells;
    i64 sw_chunks;
    i32 stress_count;
    // the verifier (gc_verify, under stress): a walk of the whole graph
    // with GC_SEEN as its visited set, the cell it is tracing, the cells
    // it has seen
    bool verifying;
    GcCell* verify_parent;
    str verify_slot;      // which of the parent's slots is being traced, named by the tracer
    i32 verify_key;       // the property key being traced, and the table's cap word with its generation bits
    i32 verify_cap;
    Vec<CellPtr> verify_seen;
    GcCell*[GC_CLASS_COUNT] free_cells;   // dead cells by size class, reused first
    i64 alloc_total;      // bytes allocated since the heap began: a clock
    Vec<GcChunk> chunks;
    i32[GC_CLASS_SMALL] bump;    // per small class, the chunk new cells come from (its free cells, then its unused tail), -1 for none
    i32[GC_CLASS_SMALL] avail;   // per small class, the chunks with free cells, the emptiest first
    i64 chunk_bytes;             // the chunks' memory: the heap's footprint apart from the large cells
    // the lazy sweep of the chunks: the next cell to look at, and the chunks
    // the collection found (those made since have nothing to sweep)
    bool chunk_sweep;
    i32 sw_chunk;
    i32 sw_cell;
    i32 sw_end;
    // A byte per property key, set during marking for each key a live
    // property list holds (the embedder sizes it, and reads it after);
    // keys at or past key_marks_len are not recorded.
    u8* key_marks;
    i32 key_marks_len;
}

// --- cell allocator ------------------------------------------------
//
// Cells come in a few dozen sizes and turn over constantly, and the
// program allocator on some targets scans one first-fit free list for
// every request. Dead cells are kept here instead, on a free list per
// size class, and reused before the program allocator is asked again.
// Classes step by 16 bytes to 1 KB, then by a quarter of each doubling
// up to 128 KB; a larger cell goes straight to the program allocator.

// The class of a cell size, or -1 when it is above the largest class.
private i32 gc_class_of(i64 size) {
    if size <= 1024 { return cast(i32, (size + 15) / 16) - 1; }
    if size > GC_CLASS_MAX { return -1; }
    i64 base = 1024;
    i32 d = 0;
    while size > base * 2 {
        base = base * 2;
        d++;
    }
    i64 step = base / 4;
    i32 q = cast(i32, (size - base + step - 1) / step) - 1;
    return GC_CLASS_SMALL + d * 4 + q;
}

// The block size a class allocates; a class size maps back to itself.
private i64 gc_class_size(i32 cls) {
    if cls < GC_CLASS_SMALL { return cast(i64, cls + 1) * 16; }
    i32 d = (cls - GC_CLASS_SMALL) / 4;
    i32 q = (cls - GC_CLASS_SMALL) % 4;
    i64 base = 1024;
    for i32 i = 0; i < d; i++ { base = base * 2; }
    return base + base / 4 * cast(i64, q + 1);
}

// A dead cell's memory goes back on its class list, or to the program
// allocator when it has no class. A small cell stays in its chunk, marked free.
// The class of a size, with the common small sizes computed in place: the
// function has a loop, which keeps the inliner away from it.
private void gc_cell_release(GcHeap* h, GcCell* c) {
    if c.chunk > 0 {
        c.kind = GC_FREE;
        GcChunk* ch = &h.chunks.data[c.chunk - 1];
        c.next = ch.free;
        ch.free = c;
        ch.n_free++;
        return;
    }
    i32 cls = c.size <= 1024 ? cast(i32, (c.size + 15) / 16) - 1 : gc_class_of(c.size);
    if cls < 0 {
        gc_stat_frees = gc_stat_frees + 1;
        free(c);
        return;
    }
    c.next = h.free_cells[cls];
    h.free_cells[cls] = c;
}

// --- raw blocks ------------------------------------------------------
//
// The arrays behind an object's properties and elements, a map's slots
// and a closure's upvalues: small, made and freed as constantly as the
// cells, and the program allocator's free list stands between every pair.
// They come from free lists by the cells' size classes instead; a block
// above the largest class is the program allocator's as before. A caller
// frees with the byte count it asked for, which names the class.
private threadlocal u8*[GC_CLASS_COUNT] g_pool_free;

void* pool_alloc(i64 bytes) {
    i32 cls = bytes <= 1024 ? cast(i32, (bytes + 15) / 16) - 1 : gc_class_of(bytes);
    if cls < 0 { return alloc(bytes); }
    u8* p = g_pool_free[cls];
    if p != null {
        g_pool_free[cls] = *(cast(u8**, p));
        return cast(void*, p);
    }
    return alloc(cls < GC_CLASS_SMALL ? cast(i64, cls + 1) * 16 : gc_class_size(cls));
}

void pool_free(void* p, i64 bytes) {
    if p == null { return; }
    i32 cls = bytes <= 1024 ? cast(i32, (bytes + 15) / 16) - 1 : gc_class_of(bytes);
    if cls < 0 { free(p); return; }
    *(cast(u8**, p)) = g_pool_free[cls];
    g_pool_free[cls] = cast(u8*, p);
}

// When the next collection comes, from what the last one found live: at
// twice that for a small heap; later for a large one, whose every full
// mark and sweep costs more than the memory it would give back sooner.
private i64 gc_next_threshold(i64 live) {
    i64 next = live * 2;
    if live > 134217728 { next = live * 3; }
    else if live > 33554432 { next = live * 5 / 2; }
    return next < GC_MIN_THRESHOLD ? GC_MIN_THRESHOLD : next;
}

void gc_init(GcHeap* h) {
    h.all = null;
    h.sweep_list = null;
    h.marked_bytes = 0;
    h.marked_cells = 0;
    h.bytes_live = 0;
    h.next_gc = GC_MIN_THRESHOLD;
    h.stress = false;
    h.verify = false;
    h.trace = false;
    h.n_cells = 0;
    h.n_collections = 0;
    vec_init<Value>(&h.roots, 16);
    vec_init<CellPtr>(&h.mark_stack, 64);
    h.tracer = null;
    h.finalizer = null;
    h.mark_roots = null;
    h.weak_mark = null;
    h.weak_sweep = null;
    h.mark_ctx = null;
    for i32 i = 0; i < GC_CLASS_COUNT; i++ { h.free_cells[i] = null; }
    h.alloc_total = 0;
    h.key_marks = null;
    h.key_marks_len = 0;
    vec_init<GcChunk>(&h.chunks, 16);
    for i32 i = 0; i < GC_CLASS_SMALL; i++ { h.bump[i] = -1; h.avail[i] = -1; }
    h.chunk_bytes = 0;
    h.chunk_sweep = false;
    h.sw_chunk = 0;
    h.sw_cell = 0;
    h.sw_end = 0;
    h.props_trace = null;
    h.young_large = null;
    h.old_bytes = 0;
    h.old_cells = 0;
    h.minor_threshold = GC_MINOR_THRESHOLD;
    h.minor_pass = false;
    h.minor_sweep = false;
    vec_init<i32>(&h.young_chunks, 64);
    h.n_minor = 0;
    h.stress_count = 0;
    h.verifying = false;
    h.verify_parent = null;
    vec_init<CellPtr>(&h.verify_seen, 16);
}

void gc_destroy(GcHeap* h) {
    gc_sweep_finish(h);
    gc_report_poison();
    gc_forget_remembered(h);
    gc_free_list(h, h.all);
    gc_free_list(h, h.young_large);
    h.all = null;
    h.young_large = null;
    for i32 k = 0; k < h.chunks.len; k++ {
        GcChunk* ch = &h.chunks.data[k];
        for i32 i = 0; i < ch.used; i++ {
            GcCell* sc = cast(GcCell*, ch.mem + cast(i64, i) * ch.cell);
            if sc.kind >= 0 && h.finalizer != null { h.finalizer(sc); }
        }
        free(ch.mem);
    }
    vec_free(&h.chunks);
    vec_free(&h.young_chunks);
    h.bytes_live = 0;
    h.n_cells = 0;
    for i32 i = 0; i < GC_CLASS_COUNT; i++ {
        GcCell* f = h.free_cells[i];
        // a small class's free cells are its chunks' memory, freed above
        while f != null && i >= GC_CLASS_SMALL {
            GcCell* n = f.next;
            free(f);
            f = n;
        }
        h.free_cells[i] = null;
    }
    vec_free(&h.roots);
    vec_free(&h.mark_stack);
    vec_free(&h.verify_seen);
    if h.key_marks != null { free(h.key_marks); h.key_marks = null; }
}

private void gc_free_list(GcHeap* h, GcCell* c) {
    while c != null {
        GcCell* n = c.next;
        if h.finalizer != null { h.finalizer(c); }
        free(c);
        c = n;
    }
}

// --- generations --------------------------------------------------------
//
// A cell keeps its mark once set: one that survived a collection is old.
// A minor collection marks from the roots and from the old cells written
// since the last collection, traces only the young cells it reaches, and
// sweeps only the chunks allocated into since; a major clears every mark
// first and does the whole heap. A store of a young cell into an old one
// goes through gc_barrier, or props_barrier for a property table, which
// puts the holder on a remembered list. The lists are the thread's, shared
// by the heaps on it, and every collection on the thread drains them: an
// entry is traced into whichever heap collects first, which marks its
// young referents old a little early, and never outlives its cell, since a
// cell dies only in a collection of its own heap.
const i32 GC_OLD = 1;
const i32 GC_REMEMBERED = 2;    // old, and on the remembered list
const i32 GC_FRESH = 4;         // young, made where a pending sweep has yet to reach, which passes it by
const i32 GC_SEEN = 256;        // the verifier's visited bit, over the others
// The young bytes a minor collection waits for. Small: the young fill a
// few chunks that stay in the cache when they are recycled every megabyte,
// and bsky.app ran slower with each doubling, 8 MB costing a tenth more.
const i64 GC_MINOR_THRESHOLD = 1048576;

private threadlocal Vec<CellPtr> g_remembered_cells;
private threadlocal Vec<VoidPtr> g_remembered_props;
private threadlocal bool g_remembered_ready = false;

private void remembered_ready() {
    if g_remembered_ready { return; }
    vec_init<CellPtr>(&g_remembered_cells, 64);
    vec_init<VoidPtr>(&g_remembered_props, 64);
    g_remembered_ready = true;
}

// Whether v is a cell no collection has marked yet.
bool gc_young(Value v) {
    if !value_is_cell(v) { return false; }
    i32 m = value_as_cell(v).mark;
    return m == 0 || m == GC_FRESH;
}

// An old cell about to hold a young one: traced by the next collection.
void gc_remember_cell(GcCell* c) {
    if c.mark != GC_OLD { return; }
    remembered_ready();
    c.mark = GC_REMEMBERED;
    vec_push(&g_remembered_cells, c);
}

// Before a store of v into a slot of c.
void gc_barrier(GcCell* c, Value v) {
    if c.mark == GC_OLD && gc_young(v) { gc_remember_cell(c); }
}

// A property table (object.mc) about to hold a young cell; traced through
// the heap's props_trace hook, which also takes it off its list.
void gc_remember_props(void* p) {
    remembered_ready();
    vec_push(&g_remembered_props, p);
}

// The remembered cells and tables traced, as a collection's marking does.
private void gc_drain_remembered(GcHeap* h) {
    if !g_remembered_ready { return; }
    for i32 i = 0; i < g_remembered_cells.len; i++ {
        GcCell* c = g_remembered_cells.data[i];
        if c.mark == GC_REMEMBERED { c.mark = GC_OLD; }
        gc_trace(h, c);
    }
    g_remembered_cells.len = 0;
    for i32 i = 0; i < g_remembered_props.len; i++ {
        if h.props_trace != null { h.props_trace(h, g_remembered_props.data[i]); }
    }
    g_remembered_props.len = 0;
}

// Whether the address lies in one of the heap's cells.
private bool gc_owns(GcHeap* h, u8* p) {
    for i32 k = 0; k < h.chunks.len; k++ {
        GcChunk* ch = &h.chunks.data[k];
        if p >= ch.mem && p < ch.mem + cast(i64, ch.cap) * ch.cell { return true; }
    }
    GcCell* c = h.all;
    while c != null { if p >= cast(u8*, c) && p < cast(u8*, c) + c.size { return true; } c = c.next; }
    c = h.young_large;
    while c != null { if p >= cast(u8*, c) && p < cast(u8*, c) + c.size { return true; } c = c.next; }
    return false;
}

// A heap going away takes its entries off the thread's lists.
private void gc_forget_remembered(GcHeap* h) {
    if !g_remembered_ready { return; }
    i32 k = 0;
    for i32 i = 0; i < g_remembered_cells.len; i++ {
        GcCell* c = g_remembered_cells.data[i];
        if !gc_owns(h, cast(u8*, c)) { g_remembered_cells.data[k] = c; k++; }
    }
    g_remembered_cells.len = k;
    k = 0;
    for i32 i = 0; i < g_remembered_props.len; i++ {
        void* p = g_remembered_props.data[i];
        if !gc_owns(h, cast(u8*, p)) { g_remembered_props.data[k] = p; k++; }
    }
    g_remembered_props.len = k;
}

// Every mark cleared, for a major collection.
private void gc_clear_marks(GcHeap* h) {
    for i32 k = 0; k < h.chunks.len; k++ {
        GcChunk* ch = &h.chunks.data[k];
        for i32 i = 0; i < ch.used; i++ {
            GcCell* c = cast(GcCell*, ch.mem + cast(i64, i) * ch.cell);
            if c.kind >= 0 { c.mark = 0; }
        }
    }
    GcCell* c = h.all;
    while c != null { c.mark = 0; c = c.next; }
    c = h.young_large;
    while c != null { c.mark = 0; c = c.next; }
}

// Under stress, after a collection's marking: the whole graph walked from
// the roots again, and a live cell found unmarked is a store that went
// without its barrier. It names the cell's kind and the holder's.
private void gc_verify(GcHeap* h, bool minor) {
    h.verifying = true;
    if h.mark_roots != null { h.mark_roots(h, h.mark_ctx); }
    for i32 i = 0; i < h.roots.len; i++ { gc_mark_value(h, vec_get(&h.roots, i)); }
    while h.mark_stack.len > 0 {
        CellPtr c = vec_pop(&h.mark_stack);
        h.verify_parent = c;
        h.verify_slot = "";
        gc_trace(h, c);
    }
    h.verify_parent = null;
    h.verifying = false;
    for i32 i = 0; i < h.verify_seen.len; i++ { h.verify_seen.data[i].mark = h.verify_seen.data[i].mark & ~GC_SEEN; }
    h.verify_seen.len = 0;
}

// --- roots ---------------------------------------------------------

void gc_root(GcHeap* h, Value v) {
    vec_push(&h.roots, v);
}

i32 gc_root_mark(GcHeap* h) {
    return h.roots.len;
}

void gc_root_reset(GcHeap* h, i32 mark) {
    h.roots.len = mark;
}

// --- mark ----------------------------------------------------------

void gc_mark_cell(GcHeap* h, GcCell* c) {
    if c == null { return; }
    if h.verifying {
        if (c.mark & GC_SEEN) != 0 { return; }
        if (c.mark & 255) == 0 {
            eprint("gc: a live cell of kind {} is unmarked after a {} collection, held by a cell of kind {} in its {}: a store without its barrier\n",
                c.kind, h.minor_pass ? "minor" : "major", h.verify_parent != null ? h.verify_parent.kind : -1, h.verify_slot);
            eprint("gc: the holder's mark {}, the cell's mark {}, its chunk {} (young {}), key {}, table cap {} (old {}, remembered {}), collection {}\n", h.verify_parent != null ? h.verify_parent.mark : -1, c.mark, c.chunk, c.chunk > 0 ? h.chunks.data[c.chunk - 1].young : false, h.verify_key, h.verify_cap & 0x0FFFFFFF, (h.verify_cap & 0x40000000) != 0, (h.verify_cap & 0x20000000) != 0, h.n_collections);
            exit(70);
        }
        c.mark = c.mark | GC_SEEN;
        vec_push(&h.verify_seen, c);
        vec_push(&h.mark_stack, c);
        return;
    }
    if c.mark != 0 { return; }
    c.mark = GC_OLD;
    h.marked_bytes += c.size;
    h.marked_cells++;
    vec_push(&h.mark_stack, c);
}

void gc_mark_value(GcHeap* h, Value v) {
    if value_is_cell(v) {
        gc_mark_cell(h, value_as_cell(v));
    }
}

private void gc_trace(GcHeap* h, GcCell* c) {
    switch c.kind {
        case GC_STRING: { }
        case GC_PAIR: {
            GcPair* p = cast(GcPair*, c);
            gc_mark_value(h, p.a);
            gc_mark_value(h, p.b);
        }
        default: {
            if h.tracer != null {
                h.tracer(h, c);
            } else {
                eprint("gc: cell kind {} has no trace\n", c.kind);
                exit(70);
            }
        }
    }
}

// --- collect -------------------------------------------------------

// How many collections, and how long they took, for the embedder to
// report: a pause here is a pause in everything the runtime serves.
i64 gc_stat_collections = 0;
i64 gc_stat_ticks = 0;
i64 gc_stat_sweep_ticks = 0;     // sweeping left to the start of the next collection
i64 gc_stat_max_ticks = 0;       // the longest collection
i64 gc_stat_step_ticks = 0;      // sweeping in the steps between allocations
i64 gc_stat_mallocs = 0;         // cells the free lists could not supply
i64 gc_stat_frees = 0;           // cells released to the program allocator
// allocations by kind, counted only while a profile is being taken, in a
// profiling build
bool gc_stat_on = false;
i64[16] gc_stat_allocs;
// the same counts for the function running, 16 slots the profiler points
// here when it enters one: null between profiles
i64* gc_stat_allocs_at = null;

// Cells swept for each allocation while a collection's sweep is under
// way. The sweep ends long before the next collection is due: that comes
// after about as many bytes as are live, and so after many times as many
// allocations as there are cells.
const i32 GC_SWEEP_STEP = 64;

// Sweeps up to `n` of the last collection's cells: a survivor goes back
// to the heap's list with its mark cleared, a dead cell is finalized and
// released. A collection marks and leaves the sweep to the allocations
// that follow, which used to be the larger part of its pause: with
// 10,000 connections open, 611 of 1,000 ms over 14 collections.
void gc_sweep_some(GcHeap* h, i32 n) {
    if h.sweep_list == null && !h.chunk_sweep { return; }
    i64 t0 = qpc();
    i32 n0 = n;
    // the chunks, a cell after another: a survivor's mark is cleared, a dead
    // cell is finalized and goes on its chunk's free list
    while n > 0 && h.chunk_sweep {
        if h.sw_chunk >= h.sw_end { h.chunk_sweep = false; break; }
        GcChunk* ch = &h.chunks.data[h.sw_chunk];
        // young again if a cell was made in it ahead of the sweep (fresh)
        // or, by the allocator, behind it
        if h.sw_cell == 0 { h.sw_chunks++; ch.young = false; ch.lo = ch.cap; ch.hi = -1; }
        bool was_young = ch.young;
        i32 i = gc_sweep_every(h, ch, h.sw_cell, &n, false);
        if ch.young && !was_young { vec_push(&h.young_chunks, h.sw_chunk); }
        if i >= ch.used {
            gc_chunk_avail(h, h.sw_chunk);
            h.sw_chunk++;
            h.sw_cell = 0;
        } else {
            h.sw_cell = i;
        }
    }
    if !h.chunk_sweep { gc_rank_chunks(h); }
    while n > 0 && h.sweep_list != null {
        GcCell* c = h.sweep_list;
        h.sweep_list = c.next;
        if c.mark != 0 {
            c.next = h.all;
            h.all = c;
        } else {
            if h.finalizer != null { h.finalizer(c); }
            gc_cell_release(h, c);
        }
        n--;
    }
    i64 dt = qpc() - t0;
    gc_stat_step_ticks = gc_stat_step_ticks + dt;
    h.sw_ticks += dt;
    h.sw_cells += n0 - n;
}

// A dead cell's memory given back, or under stress kept and poisoned, so a
// reference that outlived its root reads an invalid kind and fails at once
// rather than whenever the memory is reused.
private void gc_cell_dead(GcHeap* h, GcCell* c, bool poison) {
    if h.finalizer != null { h.finalizer(c); }
    if !poison { gc_cell_release(h, c); return; }
    i32 keep_chunk = c.chunk;
    i32 keep_size = c.size;
    memset(cast(u8*, c), 0xAB, keep_size);
    c.chunk = keep_chunk;
    c.size = keep_size;
    c.kind = -1;
}

// A chunk's young cells swept: the cells of lo..hi, every one looked at,
// since the young fill a chunk together, and an old one (marked) passed
// by. A minor's sweep, which has no pending lazy sweep to make a cell
// fresh. The cells visited.
private i32 gc_sweep_young(GcHeap* h, GcChunk* ch, bool poison) {
    i32 end = ch.hi < ch.used ? ch.hi : ch.used - 1;
    for i32 i = ch.lo; i <= end; i++ {
        GcCell* c = cast(GcCell*, ch.mem + cast(i64, i) * ch.cell);
        if c.kind >= 0 && c.mark == 0 { gc_cell_dead(h, c, poison); }
    }
    i32 visited = end - ch.lo + 1;
    ch.lo = ch.cap;
    ch.hi = -1;
    return visited < 0 ? 0 : visited;
}

// Every cell of a chunk swept, from `start`, up to *n of them; a fresh
// cell is made young and sets the chunk young, for the next minor. The
// cell reached.
private i32 gc_sweep_every(GcHeap* h, GcChunk* ch, i32 start, i32* n, bool poison) {
    i32 i = start;
    while i < ch.used && *n > 0 {
        GcCell* c = cast(GcCell*, ch.mem + cast(i64, i) * ch.cell);
        if c.kind >= 0 {
            if c.mark == 0 { gc_cell_dead(h, c, poison); }
            else if c.mark == GC_FRESH {
                c.mark = 0;
                ch.young = true;
                if i < ch.lo { ch.lo = i; }
                if i > ch.hi { ch.hi = i; }
            }
        }
        i++;
        *n = *n - 1;
    }
    return i;
}

// A chunk the sweep has been through joins its class's list when it has
// free cells and is not the one being allocated from.
private void gc_chunk_avail(GcHeap* h, i32 k) {
    GcChunk* ch = &h.chunks.data[k];
    if ch.avail || ch.n_free == 0 || h.bump[ch.cls] == k { return; }
    ch.avail = true;
    ch.next_avail = h.avail[ch.cls];
    h.avail[ch.cls] = k;
}

// When a sweep has ended: each class's chunks with free cells listed again,
// the emptiest first, in eight bands of how much of the chunk is free. The
// chunks the young filled last time are mostly free again, and come first:
// a nursery, without a space set aside for one.
private void gc_rank_chunks(GcHeap* h) {
    i32[GC_CLASS_SMALL * 8] head;
    i32[GC_CLASS_SMALL * 8] tail;
    for i32 i = 0; i < GC_CLASS_SMALL * 8; i++ { head[i] = -1; tail[i] = -1; }
    for i32 k = 0; k < h.chunks.len; k++ {
        GcChunk* ch = &h.chunks.data[k];
        ch.avail = false;
        ch.next_avail = -1;
        if ch.n_free == 0 || h.bump[ch.cls] == k { continue; }
        i32 b = ch.cls * 8 + cast(i32, cast(i64, ch.n_free) * 8 / (ch.cap + 1));
        ch.avail = true;
        if head[b] < 0 { head[b] = k; } else { h.chunks.data[tail[b]].next_avail = k; }
        tail[b] = k;
    }
    for i32 cls = 0; cls < GC_CLASS_SMALL; cls++ {
        i32 list = -1;
        for i32 b = 0; b < 8; b++ {
            i32 i = cls * 8 + b;
            if head[i] < 0 { continue; }
            h.chunks.data[tail[i]].next_avail = list;
            list = head[i];
        }
        h.avail[cls] = list;
    }
}


// Sweeps what is left of the last collection's cells.
void gc_sweep_finish(GcHeap* h) {
    if h.sweep_list == null && !h.chunk_sweep { return; }
    i64 t0 = qpc();
    gc_sweep_some(h, 2147483647);
    gc_stat_sweep_ticks = gc_stat_sweep_ticks + (qpc() - t0);
}

// A major collection: every mark cleared, the whole heap marked and swept.
void gc_collect(GcHeap* h) { gc_collect_pass(h, false); }

// A minor collection: the young cells reachable from the roots and from
// the remembered old ones survive, as old; the rest of the young go.
void gc_collect_minor(GcHeap* h) { gc_collect_pass(h, true); }

private void gc_collect_pass(GcHeap* h, bool minor) {
    // The previous sweep ends first: marking needs every young cell unmarked,
    // and the weak passes walk `all`.
    gc_sweep_finish(h);
    if h.trace && h.n_collections > 0 {
        eprint("gc: the {} sweep before: {} cells in {} chunks, {} ms\n", h.minor_sweep ? "minor" : "major", h.sw_cells, h.sw_chunks, h.sw_ticks * 1000 / qpf());
    }
    h.sw_ticks = 0;
    h.sw_cells = 0;
    h.sw_chunks = 0;
    i64 gc_t0 = qpc();
    h.minor_pass = minor;
    if !minor { gc_clear_marks(h); }
    h.marked_bytes = 0;
    h.marked_cells = 0;
    i32 n_rem_cells = g_remembered_ready ? g_remembered_cells.len : 0;
    i32 n_rem_props = g_remembered_ready ? g_remembered_props.len : 0;
    if h.mark_roots != null { h.mark_roots(h, h.mark_ctx); }
    for i32 i = 0; i < h.roots.len; i++ {
        gc_mark_value(h, vec_get(&h.roots, i));
    }
    i64 gc_tr = qpc();
    gc_drain_remembered(h);
    i64 gc_td = qpc();
    while h.mark_stack.len > 0 {
        CellPtr c = vec_pop(&h.mark_stack);
        gc_trace(h, c);
    }

    // Ephemerons: repeatedly mark values reachable only through a live
    // weak-map key, tracing each new wave, until nothing new is marked.
    if h.weak_mark != null {
        while h.weak_mark(h, h.mark_ctx) {
            while h.mark_stack.len > 0 {
                CellPtr c = vec_pop(&h.mark_stack);
                gc_trace(h, c);
            }
        }
    }
    // Drop weak entries whose key did not survive (marks still valid).
    if h.weak_sweep != null { h.weak_sweep(h, h.mark_ctx); }
    if h.stress || h.verify { gc_verify(h, minor); }

    i64 gc_t1 = qpc();
    if h.trace {
        i64 f = qpf();
        eprint("gc: {} collection {}: marked {} cells {} KB in {} ms (roots {}, remembered {} cells and {} tables {}); young {} KB of {} KB live, {} chunks {} KB\n",
            minor ? "minor" : "major", h.n_collections + 1, h.marked_cells, h.marked_bytes / 1024, (gc_t1 - gc_t0) * 1000 / f,
            (gc_tr - gc_t0) * 1000 / f, n_rem_cells, n_rem_props, (gc_td - gc_tr) * 1000 / f, (h.bytes_live - h.old_bytes) / 1024, h.bytes_live / 1024, h.chunks.len, h.chunk_bytes / 1024);
    }
    if !h.stress && !minor {
        // A major's sweep, the whole heap, is left to the allocations that
        // follow. A cell made in a chunk the sweep has yet to reach is made
        // GC_FRESH, so it survives it.
        h.sweep_list = h.all;
        if h.young_large != null {
            GcCell* tail = h.young_large;
            while tail.next != null { tail = tail.next; }
            tail.next = h.sweep_list;
            h.sweep_list = h.young_large;
        }
        h.all = null;
        h.young_large = null;
        h.young_chunks.len = 0;
        h.chunk_sweep = h.chunks.len > 0;
        h.minor_sweep = false;
        h.sw_chunk = 0;
        h.sw_cell = 0;
        h.sw_end = h.chunks.len;
        gc_account(h, minor, h.marked_bytes, h.marked_cells);
        gc_stat_ticks = gc_stat_ticks + (gc_t1 - gc_t0);
        if gc_t1 - gc_t0 > gc_stat_max_ticks { gc_stat_max_ticks = gc_t1 - gc_t0; }
        return;
    }
    // A minor's sweep, the chunks allocated into and the young large cells,
    // is done at once: a few milliseconds, and the chunks it empties are the
    // ones the allocations that follow should fill, which the lazy sweep's
    // order would hand out last; they go to the front of their class's
    // list, the ranking of the rest untouched, so a minor's cost is its
    // young chunks' and not the heap's. Stress mode sweeps everything at
    // once and poisons each dead cell as it goes, so a reference that
    // outlived its root reads an invalid kind and fails at once rather than
    // whenever the memory is reused.
    bool poison = h.stress;
    i64 live_bytes = 0;
    i64 live_cells = 0;
    h.minor_sweep = minor;
    if !minor { h.young_chunks.len = 0; }
    i32 n_young = h.young_chunks.len;
    i32 n_sweep = minor ? n_young : h.chunks.len;
    for i32 j = 0; j < n_sweep; j++ {
        i32 k = minor ? h.young_chunks.data[j] : j;
        GcChunk* ch = &h.chunks.data[k];
        i32 budget = 2147483647;
        ch.young = false;
        if minor {
            h.sw_cells += gc_sweep_young(h, ch, poison);
        } else {
            ch.lo = ch.cap;
            ch.hi = -1;
            ignore gc_sweep_every(h, ch, 0, &budget, poison);
            h.sw_cells += 2147483647 - budget;
        }
        h.sw_chunks++;
        if ch.young { vec_push(&h.young_chunks, k); }
        if minor { gc_chunk_avail(h, k); }
        if !poison { continue; }
        for i32 i = 0; i < ch.used; i++ {
            GcCell* c = cast(GcCell*, ch.mem + cast(i64, i) * ch.cell);
            if c.kind >= 0 && c.mark != 0 { live_bytes += c.size; live_cells++; }
        }
    }
    // the chunks still young were pushed again, after the ones swept
    i32 kept = h.young_chunks.len - n_young;
    for i32 j = 0; j < kept; j++ { h.young_chunks.data[j] = h.young_chunks.data[n_young + j]; }
    h.young_chunks.len = kept;
    if !minor { gc_rank_chunks(h); }
    // the young large cells, and for a major the old ones too: the
    // survivors go on (or stay on) `all`
    GcCell* list = h.young_large;
    h.young_large = null;
    if !minor {
        GcCell* tail = list;
        if tail == null { list = h.all; } else { while tail.next != null { tail = tail.next; } tail.next = h.all; }
        h.all = null;
    }
    while list != null {
        GcCell* c = list;
        list = c.next;
        if c.mark != 0 {
            live_bytes += c.size;
            live_cells++;
            c.next = h.all;
            h.all = c;
        } else {
            gc_cell_dead(h, c, poison);
        }
    }
    if poison {
        gc_report_poison();
        gc_account(h, minor, live_bytes, live_cells);
    } else {
        gc_account(h, minor, h.marked_bytes, h.marked_cells);
    }
    i64 gc_t2 = qpc();
    h.sw_ticks += gc_t2 - gc_t1;
    gc_stat_ticks = gc_stat_ticks + (gc_t1 - gc_t0);
    gc_stat_sweep_ticks = gc_stat_sweep_ticks + (gc_t2 - gc_t1);
    if gc_t2 - gc_t0 > gc_stat_max_ticks { gc_stat_max_ticks = gc_t2 - gc_t0; }
}

// What a collection found: a minor's survivors join the old; a major's are
// the old, and set when the next major comes.
private void gc_account(GcHeap* h, bool minor, i64 marked_bytes, i64 marked_cells) {
    if minor {
        h.old_bytes += marked_bytes;
        h.old_cells += marked_cells;
        h.n_minor++;
    } else {
        h.old_bytes = marked_bytes;
        h.old_cells = marked_cells;
        h.next_gc = gc_next_threshold(marked_bytes);
    }
    h.bytes_live = h.old_bytes;
    h.n_cells = h.old_cells;
    h.n_collections++;
    gc_stat_collections = gc_stat_collections + 1;
}

// A cell swept in stress mode keeps its memory and reads as kind -1, which
// `value_is_kind` notices. That predicate runs several times per bytecode, so it
// records the hit here instead of reporting it, and the collector reports what
// has accumulated -- which in stress mode is the next allocation.
threadlocal i32 gc_poison_hits = 0;
threadlocal i32 gc_poison_last_kind = 0;

void gc_report_poison() {
    if gc_poison_hits == 0 { return; }
    eprint("gc: {} reference(s) to a freed cell were reached, last asked for kind {}
",
        gc_poison_hits, gc_poison_last_kind);
    gc_poison_hits = 0;
}

GcCell* gc_alloc(GcHeap* h, i32 kind, i64 size) {
    return gc_alloc_zeroing(h, kind, size, -1);
}

// gc_alloc with only the first `zero` bytes cleared (-1: the whole
// block): for a cell whose rest the caller writes in full before anything
// reads it, such as the bytes of a Buffer a socket read fills.
GcCell* gc_alloc_zeroing(GcHeap* h, i32 kind, i64 size, i64 zero) {
    when defined(TSMC_PROF) {
        if gc_stat_on {
            i32 k = kind >= 0 && kind < 16 ? kind : 15;
            gc_stat_allocs[k]++;
            if gc_stat_allocs_at != null { *(gc_stat_allocs_at + k) += 1; }
        }
    }
    if h.sweep_list != null || h.chunk_sweep { gc_sweep_some(h, GC_SWEEP_STEP); }
    if h.stress {
        // every allocation collects: mostly minors, so the barriers are
        // exercised, a major now and then
        h.stress_count++;
        if h.stress_count % 64 == 0 { gc_collect(h); } else { gc_collect_minor(h); }
    } else if h.bytes_live - h.old_bytes >= h.minor_threshold {
        // a major when the minors' survivors have grown the old past the
        // threshold the last major set, else a minor: the young garbage is
        // the minors' business, and never brings a major on its own
        if h.old_bytes >= h.next_gc { gc_collect(h); } else { gc_collect_minor(h); }
    }
    h.alloc_total += size;
    i32 cls = size <= 1024 ? cast(i32, (size + 15) / 16) - 1 : gc_class_of(size);
    i64 block = size;
    if cls >= 0 { block = cls < GC_CLASS_SMALL ? cast(i64, cls + 1) * 16 : gc_class_size(cls); }
    GcCell* c = null;
    i32 chunk = 0;
    if cls >= 0 && cls < GC_CLASS_SMALL {
        // a free cell of the chunk the class is filling, in place: the
        // common case, and the rest is a call
        chunk = h.bump[cls] + 1;
        if chunk > 0 {
            GcChunk* ch = &h.chunks.data[chunk - 1];
            c = ch.free;
            if c != null { ch.free = c.next; ch.n_free--; }
        }
        if c == null { c = gc_chunk_cell(h, cls, cast(i32, block), &chunk); }
    } else if cls >= 0 && h.free_cells[cls] != null {
        c = h.free_cells[cls];
        h.free_cells[cls] = c.next;
    } else {
        gc_stat_mallocs = gc_stat_mallocs + 1;
        c = cast(GcCell*, alloc(block));
    }
    i64 nz = zero < 0 || zero > block ? block : zero;
    if nz <= 256 {
        // a small cell is cleared in place: a word store a time, where the
        // library call would be most of the cost
        u64* w = cast(u64*, c);
        i64 nw = (nz + 7) / 8;
        for i64 i = 0; i < nw; i++ { *(w + i) = 0; }
    } else {
        memset(cast(u8*, c), 0, nz);
    }
    c.size = cast(i32, block);
    c.chunk = chunk;
    c.kind = kind;
    if chunk > 0 {
        // young; made where the pending sweep has yet to reach, it is fresh,
        // which the sweep passes by and makes young
        c.mark = gc_ahead_of_sweep(h, chunk - 1, c) ? GC_FRESH : 0;
        GcChunk* ch = &h.chunks.data[chunk - 1];
        i32 idx = cast(i32, (cast(u64, cast(u8*, c) - ch.mem) * ch.inv) >> 32);
        if idx < ch.lo { ch.lo = idx; }
        if idx > ch.hi { ch.hi = idx; }
        if !ch.young { ch.young = true; vec_push(&h.young_chunks, chunk - 1); }
    } else {
        c.mark = 0;
        c.next = h.young_large;
        h.young_large = c;
    }
    h.bytes_live += block;
    h.n_cells++;
    return c;
}

private bool gc_ahead_of_sweep(GcHeap* h, i32 k, GcCell* c) {
    if !h.chunk_sweep || k >= h.sw_end || k < h.sw_chunk { return false; }
    if k > h.sw_chunk { return true; }
    GcChunk* ch = &h.chunks.data[k];
    return (cast(u8*, c) - ch.mem) / ch.cell >= h.sw_cell;
}

// A cell of a small class from the chunk its class is filling: a free cell
// of it, else its unused tail; when it has neither, the emptiest chunk
// with free cells if that is at least half free, else a new chunk. The
// sparse chunks' holes are left until the heap's footprint reaches the
// next major's threshold: the young filling them would lie a cell here and
// a cell there, and cost a cache miss each to sweep and to mark. *chunk
// takes the chunk's index plus one.
private GcCell* gc_chunk_cell(GcHeap* h, i32 cls, i32 block, i32* chunk) {
    i32 k = h.bump[cls];
    while k >= 0 {
        GcChunk* ch = &h.chunks.data[k];
        if ch.free != null {
            GcCell* c = ch.free;
            ch.free = c.next;
            ch.n_free--;
            *chunk = k + 1;
            return c;
        }
        if ch.used < ch.cap { break; }
        k = h.avail[cls];
        if k >= 0 {
            GcChunk* next = &h.chunks.data[k];
            if next.n_free * 2 < next.cap && h.chunk_bytes + GC_CHUNK_BYTES <= h.next_gc { k = -1; }
            else { h.avail[cls] = next.next_avail; next.avail = false; }
        }
        h.bump[cls] = k;
    }
    if k < 0 {
        h.chunk_bytes += GC_CHUNK_BYTES;
        GcChunk ch = GcChunk{};
        ch.next_avail = -1;
        ch.cls = cls;
        ch.cell = block;
        i64 two32 = cast(i64, 1) << 32;
        ch.inv = cast(u32, (two32 + block - 1) / block);
        ch.lo = cast(i32, GC_CHUNK_BYTES / block);
        ch.hi = -1;
        ch.cap = cast(i32, GC_CHUNK_BYTES / block);
        ch.mem = alloc<u8>(cast(i64, ch.cap) * block);
        ch.used = 0;
        ch.young = true;
        vec_push(&h.chunks, ch);
        k = h.chunks.len - 1;
        vec_push(&h.young_chunks, k);
        h.bump[cls] = k;
        gc_stat_mallocs = gc_stat_mallocs + 1;
    }
    GcChunk* ch = &h.chunks.data[k];
    GcCell* c = cast(GcCell*, ch.mem + cast(i64, ch.used) * block);
    ch.used++;
    *chunk = k + 1;
    return c;
}

// --- cell kinds ----------------------------------------------------

// Bytes that several strings share, each a prefix of them. The result
// of a concatenation owns spare room here, and the next concatenation
// that extends it appends in place instead of copying, so a loop that
// builds a string with += copies each piece once. Freed with the last
// string that refers to it.
struct StrBuffer {
    u8* data;
    i32 used;
    i32 cap;
    i32 refs;
}

// String: immutable, apart from the cursor, which caches where the last
// unit lookup landed so a loop over non-ASCII text does not rescan from
// the start each step. The bytes sit inline after the struct, or in a
// shared buffer.
struct GcString {
    GcCell head;
    i32 len;       // byte length (UTF-8/WTF-8 storage)
    i32 u16len;    // cached UTF-16 code-unit count; == len iff ASCII
    i32 cur_u;     // cursor: a UTF-16 unit index ...
    i32 cur_off;   // ... and the byte offset of the code point there
    u8* data;
    StrBuffer* buf;   // null when the bytes are inline
    u32 atom;         // the atom this string was interned as, while atom_gen
    u32 atom_gen;     // is the atom table's generation (vm_atom_of_string)
}

GcString* gc_new_string(GcHeap* h, str s) {
    // the bytes are written next: only the header needs clearing
    GcCell* c = gc_alloc_zeroing(h, GC_STRING, sizeof(GcString) + s.len, sizeof(GcString));
    GcString* gs = cast(GcString*, c);
    gs.len = s.len;
    gs.cur_u = 0;
    gs.cur_off = 0;
    gs.data = cast(u8*, gs) + sizeof(GcString);
    gs.buf = null;
    if s.len > 0 {
        memcpy(gs.data, s.data, s.len);
    }
    str view;
    view.data = gs.data;
    view.len = s.len;
    // halves of an astral code point that met in this string become the
    // code point; the cell keeps its allocation, the payload shrinks
    if s.len >= 6 && wtf8_has_surrogate(view) {
        gs.len = wtf8_merge_pairs(view.data, s.len);
        view.len = gs.len;
    }
    gs.u16len = u16_count(view);
    return gs;
}

str gc_string_view(GcString* s) {
    str r;
    r.data = s.data;
    r.len = s.len;
    return r;
}

// Drops a string's hold on its shared buffer; the finalizer's part.
void gc_string_release(GcString* g) {
    if g.buf == null { return; }
    g.buf.refs--;
    if g.buf.refs == 0 {
        free(g.buf.data);
        free(g.buf);
    }
    g.buf = null;
}

// Results shorter than this are plain inline copies; a shared buffer
// with room to grow is worth its two allocations only past it.
private const i32 STR_SHARE_MIN = 128;

// a + b. When a is the newest string of its buffer and the buffer has
// room, b's bytes go in right after it and the result shares them;
// every string in a buffer is a prefix of it, so a keeps its meaning.
// Otherwise the result starts a buffer of its own, with room to grow.
// Both operands must be rooted by the caller.
GcString* gc_string_concat(GcHeap* h, GcString* a, GcString* b) {
    // strings are immutable: `s + ""` and `"" + s` are s
    if b.len == 0 { return a; }
    if a.len == 0 { return b; }
    i32 total = a.len + b.len;
    if total < STR_SHARE_MIN {
        GcString* g = cast(GcString*, gc_alloc(h, GC_STRING, sizeof(GcString) + total));
        g.len = total;
        g.u16len = a.u16len + b.u16len;
        g.data = cast(u8*, g) + sizeof(GcString);
        g.buf = null;
        g.atom_gen = 0;
        if a.len > 0 { memcpy(g.data, a.data, a.len); }
        if b.len > 0 { memcpy(g.data + a.len, b.data, b.len); }
        return g;
    }
    StrBuffer* buf = a.buf;
    if buf != null && buf.used == a.len && buf.cap - buf.used >= b.len {
        if b.len > 0 { memcpy(buf.data + buf.used, b.data, b.len); }
        buf.used = total;
    } else {
        buf = new(StrBuffer);
        buf.cap = total * 2;
        buf.data = alloc<u8>(buf.cap);
        if a.len > 0 { memcpy(buf.data, a.data, a.len); }
        if b.len > 0 { memcpy(buf.data + a.len, b.data, b.len); }
        buf.used = total;
        buf.refs = 0;
    }
    GcString* g = cast(GcString*, gc_alloc(h, GC_STRING, sizeof(GcString)));
    g.len = total;
    g.u16len = a.u16len + b.u16len;
    g.data = buf.data;
    g.atom_gen = 0;
    g.buf = buf;
    buf.refs++;
    return g;
}

// Pair: the minimal traceable cell. Real object kinds arrive with
// the VM milestone.
struct GcPair {
    GcCell head;
    Value a;
    Value b;
}

GcPair* gc_new_pair(GcHeap* h, Value a, Value b) {
    GcCell* c = gc_alloc(h, GC_PAIR, sizeof(GcPair));
    GcPair* p = cast(GcPair*, c);
    p.a = a;
    p.b = b;
    return p;
}

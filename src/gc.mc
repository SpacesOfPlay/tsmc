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
    i64 size;
    i32 kind;
    i32 mark;
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

const i64 GC_MIN_THRESHOLD = 262144;

// cell size classes: 64 of 16 bytes up to 1 KB, then 4 per doubling to 128 KB
const i32 GC_CLASS_SMALL = 64;
const i32 GC_CLASS_COUNT = 92;
const i64 GC_CLASS_MAX = 131072;

struct GcHeap {
    GcCell* all;
    i64 bytes_live;
    i64 next_gc;
    bool stress;          // collect on every allocation (tests)
    i64 n_cells;
    i64 n_collections;
    Vec<Value> roots;
    Vec<CellPtr> mark_stack;
    GcTraceFn tracer;         // child marking for runtime kinds
    GcFinalizeFn finalizer;   // frees a cell's non-GC allocations
    GcMarkRootsFn mark_roots; // extra roots (VM stack, globals, …)
    GcWeakMarkFn weak_mark;   // ephemeron marking (WeakMap/WeakSet)
    GcWeakSweepFn weak_sweep; // drops dead-keyed weak entries
    void* mark_ctx;
    GcCell*[GC_CLASS_COUNT] free_cells;   // dead cells by size class, reused first
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
// allocator when it has no class.
private void gc_cell_release(GcHeap* h, GcCell* c) {
    i32 cls = gc_class_of(c.size);
    if cls < 0 {
        free(c);
        return;
    }
    c.next = h.free_cells[cls];
    h.free_cells[cls] = c;
}

void gc_init(GcHeap* h) {
    h.all = null;
    h.bytes_live = 0;
    h.next_gc = GC_MIN_THRESHOLD;
    h.stress = false;
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
}

void gc_destroy(GcHeap* h) {
    GcCell* c = h.all;
    while c != null {
        GcCell* n = c.next;
        if h.finalizer != null { h.finalizer(c); }
        free(c);
        c = n;
    }
    h.all = null;
    h.bytes_live = 0;
    h.n_cells = 0;
    for i32 i = 0; i < GC_CLASS_COUNT; i++ {
        GcCell* f = h.free_cells[i];
        while f != null {
            GcCell* n = f.next;
            free(f);
            f = n;
        }
        h.free_cells[i] = null;
    }
    vec_free(&h.roots);
    vec_free(&h.mark_stack);
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
    if c.mark != 0 { return; }
    c.mark = 1;
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

void gc_collect(GcHeap* h) {
    if h.mark_roots != null { h.mark_roots(h, h.mark_ctx); }
    for i32 i = 0; i < h.roots.len; i++ {
        gc_mark_value(h, vec_get(&h.roots, i));
    }
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

    GcCell** link = &h.all;
    i64 live_bytes = 0;
    i64 live_cells = 0;
    while *link != null {
        GcCell* c = *link;
        if c.mark != 0 {
            c.mark = 0;
            live_bytes += c.size;
            live_cells++;
            link = &c.next;
        } else {
            *link = c.next;
            if h.finalizer != null { h.finalizer(c); }
            if h.stress {
                // Stress mode keeps a dead cell's memory and poisons it, so
                // a reference that outlived its root reads an invalid kind
                // and fails at once rather than whenever the memory is
                // reused.
                memset(cast(u8*, c), 0xAB, c.size);
                c.kind = -1;
            } else {
                gc_cell_release(h, c);
            }
        }
    }
    h.bytes_live = live_bytes;
    h.n_cells = live_cells;
    h.next_gc = live_bytes * 2;
    if h.next_gc < GC_MIN_THRESHOLD { h.next_gc = GC_MIN_THRESHOLD; }
    h.n_collections++;
}

GcCell* gc_alloc(GcHeap* h, i32 kind, i64 size) {
    if h.stress || h.bytes_live >= h.next_gc {
        gc_collect(h);
    }
    i32 cls = gc_class_of(size);
    i64 block = cls >= 0 ? gc_class_size(cls) : size;
    GcCell* c = null;
    if cls >= 0 && h.free_cells[cls] != null {
        c = h.free_cells[cls];
        h.free_cells[cls] = c.next;
    } else {
        c = cast(GcCell*, alloc(block));
    }
    memset(cast(u8*, c), 0, block);
    c.next = h.all;
    h.all = c;
    c.size = block;
    c.kind = kind;
    c.mark = 0;
    h.bytes_live += block;
    h.n_cells++;
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
}

GcString* gc_new_string(GcHeap* h, str s) {
    GcCell* c = gc_alloc(h, GC_STRING, sizeof(GcString) + s.len);
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
    i32 total = a.len + b.len;
    if total < STR_SHARE_MIN {
        GcString* g = cast(GcString*, gc_alloc(h, GC_STRING, sizeof(GcString) + total));
        g.len = total;
        g.u16len = a.u16len + b.u16len;
        g.data = cast(u8*, g) + sizeof(GcString);
        g.buf = null;
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

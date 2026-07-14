// gc.mc — GC heap: cell allocator and precise mark-sweep collector.
//
// Cells are single variable-size allocations with a GcCell header
// first. Non-moving: addresses stay valid for a cell's lifetime.
// Any gc_alloc may collect — root intermediate values first.
// See doc/DESIGN_gc.md.

import vec;
import value;

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

const i64 GC_MIN_THRESHOLD = 262144;

struct GcHeap {
    GcCell* all;
    i64 bytes_live;
    i64 next_gc;
    bool stress;          // collect on every allocation (tests)
    i64 n_cells;
    i64 n_collections;
    Vec<Value> roots;
    Vec<CellPtr> mark_stack;
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
}

void gc_destroy(GcHeap* h) {
    GcCell* c = h.all;
    while c != null {
        GcCell* n = c.next;
        free(c);
        c = n;
    }
    h.all = null;
    h.bytes_live = 0;
    h.n_cells = 0;
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
            eprint("gc: cell kind {} has no trace\n", c.kind);
            exit(70);
        }
    }
}

// --- collect -------------------------------------------------------

void gc_collect(GcHeap* h) {
    for i32 i = 0; i < h.roots.len; i++ {
        gc_mark_value(h, vec_get(&h.roots, i));
    }
    while h.mark_stack.len > 0 {
        CellPtr c = vec_pop(&h.mark_stack);
        gc_trace(h, c);
    }

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
            free(c);
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
    GcCell* c = cast(GcCell*, alloc(size));
    memset(cast(u8*, c), 0, size);
    c.next = h.all;
    h.all = c;
    c.size = size;
    c.kind = kind;
    c.mark = 0;
    h.bytes_live += size;
    h.n_cells++;
    return c;
}

// --- cell kinds ----------------------------------------------------

// String: byte payload follows the struct inline. Immutable.
struct GcString {
    GcCell head;
    i32 len;
}

GcString* gc_new_string(GcHeap* h, str s) {
    GcCell* c = gc_alloc(h, GC_STRING, sizeof(GcString) + s.len);
    GcString* gs = cast(GcString*, c);
    gs.len = s.len;
    if s.len > 0 {
        memcpy(cast(u8*, gs) + sizeof(GcString), s.data, s.len);
    }
    return gs;
}

str gc_string_view(GcString* s) {
    str r;
    r.data = cast(u8*, s) + sizeof(GcString);
    r.len = s.len;
    return r;
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

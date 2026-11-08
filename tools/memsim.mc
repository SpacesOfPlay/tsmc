// memsim.mc -- replays a memtrace log (src/memtrace.mc) through a model of
// the caches, under today's object layout and under shapes.
//
//   minc tools/memsim.mc -o memsim && memsim trace.bin [l1_kb l2_kb l3_kb [max_children]]
//
// Each layout gets its own copy of the heap: the cells the log allocates,
// at addresses a model of the collector's allocator hands out (chunks of a
// size class, a chunk's free cells first), and the property tables' blocks
// from a model of the pool. Every event touches the bytes the layout would
// touch, through an L1, an L2 and an L3 (64-byte lines, LRU), and the misses are
// counted by what touched them. The real addresses the log carries make one
// more copy, today's layout as it ran, which checks the allocator's model.
//
// Layouts: "real" and "today" are the 80-byte object and 16-byte entries;
// "shapes56" and "shapes64" an object of its header (56 or 64 bytes: the
// cell's, the flags and shape id, the prototype, the values' pointer, and
// for 64 the elements' three fields) and 8-byte values, the keys in shared
// shapes. A "-nv" layout does not read the value's cell on a cached read
// (an accessor test that needs no load). The log also replays into a
// transition tree: how many shapes, their fan-out, and which objects would
// take a dictionary instead.

import vec;
import file;

const u32 MT_HEADER = 1;
const u32 MT_ALLOC = 2;
const u32 MT_FREE = 3;
const u32 MT_OBJECT = 4;
const u32 MT_GROW = 5;
const u32 MT_ADD = 6;
const u32 MT_REMOVE = 7;
const u32 MT_FLAGS = 8;
const u32 MT_READ = 9;
const u32 MT_WRITE = 10;
const u32 MT_MARK = 11;
const u32 MT_TRACE = 12;
const u32 MT_PREAD = 13;

struct MtRec {
    u64 a;
    u64 b;
    u64 e;
    u32 c;
    u32 t;
}

const i32 GC_OBJECT = 2;
const i32 GC_FUNCTION = 3;
const i32 GC_NATIVE = 4;

// --- an open-addressed map from a nonzero u64 to an i32 --------------------

struct HMap {
    u64* keys;
    i32* vals;
    i64 cap;
    i64 n;
    i32 bits;
}

void hm_init(HMap* m, i32 bits) {
    m.bits = bits;
    m.cap = cast(i64, 1) << bits;
    m.keys = alloc<u64>(m.cap);
    m.vals = alloc<i32>(m.cap);
    for i64 i = 0; i < m.cap; i++ { *(m.keys + i) = 0; }
    m.n = 0;
}

private i64 hm_slot(HMap* m, u64 k) {
    return cast(i64, (k * 0x9E3779B97F4A7C15) >> cast(u64, 64 - m.bits));
}

i32 hm_get(HMap* m, u64 k) {
    i64 i = hm_slot(m, k);
    while true {
        u64 kk = *(m.keys + i);
        if kk == k { return *(m.vals + i); }
        if kk == 0 { return -1; }
        i = (i + 1) & (m.cap - 1);
    }
    return -1;
}

private void hm_grow(HMap* m) {
    u64* ok = m.keys;
    i32* ov = m.vals;
    i64 oc = m.cap;
    hm_init(m, m.bits + 1);
    for i64 i = 0; i < oc; i++ {
        if *(ok + i) != 0 { hm_put(m, *(ok + i), *(ov + i)); }
    }
    free(ok);
    free(ov);
}

void hm_put(HMap* m, u64 k, i32 v) {
    if m.n * 2 >= m.cap { hm_grow(m); }
    i64 i = hm_slot(m, k);
    while true {
        u64 kk = *(m.keys + i);
        if kk == k { *(m.vals + i) = v; return; }
        if kk == 0 {
            *(m.keys + i) = k;
            *(m.vals + i) = v;
            m.n++;
            return;
        }
        i = (i + 1) & (m.cap - 1);
    }
}


// --- the caches -------------------------------------------------------------

const i32 NCAT = 7;
const i32 CAT_ALLOC = 0;
const i32 CAT_READ = 1;
const i32 CAT_PREAD = 2;
const i32 CAT_WRITE = 3;
const i32 CAT_ADD = 4;
const i32 CAT_TABLE = 5;   // growth, removal, reset
const i32 CAT_MARK = 6;

struct Level {
    u64* tags;     // line + 1, 0 empty
    u64* stamps;
    i32 sets;
    i32 ways;
    u64 clock;
}

void lvl_init(Level* l, i32 kb, i32 ways) {
    l.ways = ways;
    l.sets = kb * 1024 / 64 / ways;
    i64 n = cast(i64, l.sets) * ways;
    l.tags = alloc<u64>(n);
    l.stamps = alloc<u64>(n);
    for i64 i = 0; i < n; i++ { *(l.tags + i) = 0; *(l.stamps + i) = 0; }
    l.clock = 0;
}

// Whether the line was there; it is afterwards, the least recent way out.
bool lvl_access(Level* l, u64 line) {
    l.clock++;
    i64 set = cast(i64, line % cast(u64, l.sets));
    u64* tg = l.tags + set * l.ways;
    u64* st = l.stamps + set * l.ways;
    i32 lru = 0;
    for i32 w = 0; w < l.ways; w++ {
        if *(tg + w) == line + 1 { *(st + w) = l.clock; return true; }
        if *(st + w) < *(st + lru) { lru = w; }
    }
    *(tg + lru) = line + 1;
    *(st + lru) = l.clock;
    return false;
}

struct Cache {
    Level l1;
    Level l2;
    Level l3;
    i64[NCAT] acc;
    i64[NCAT] m1;
    i64[NCAT] m2;
    i64[NCAT] m3;
}

void cache_init(Cache* c, i32 l1kb, i32 l2kb, i32 l3kb) {
    lvl_init(&c.l1, l1kb, 8);
    lvl_init(&c.l2, l2kb, 8);
    lvl_init(&c.l3, l3kb, 16);
    for i32 i = 0; i < NCAT; i++ { c.acc[i] = 0; c.m1[i] = 0; c.m2[i] = 0; c.m3[i] = 0; }
}

void touch(Cache* c, i32 cat, u64 addr, i64 len) {
    if len <= 0 { return; }
    u64 l0 = addr >> 6;
    u64 l1 = (addr + cast(u64, len) - 1) >> 6;
    for u64 l = l0; l <= l1; l++ {
        c.acc[cat]++;
        if !lvl_access(&c.l1, l) {
            c.m1[cat]++;
            if !lvl_access(&c.l2, l) {
                c.m2[cat]++;
                if !lvl_access(&c.l3, l) { c.m3[cat]++; }
            }
        }
    }
}

// --- a model of the collector's allocator and the pool ----------------------

const i32 CLASS_SMALL = 64;
const i32 CLASS_COUNT = 92;
const i64 CHUNK = 65536;
const i32 CHUNK_CELLS = 4096;

i32 class_of(i64 size) {
    if size <= 1024 { return cast(i32, (size + 15) / 16) - 1; }
    if size > 131072 { return -1; }
    i64 base = 1024;
    i32 d = 0;
    while size > base * 2 { base = base * 2; d++; }
    i64 step = base / 4;
    i32 q = cast(i32, (size - base + step - 1) / step) - 1;
    return CLASS_SMALL + d * 4 + q;
}

i64 class_size(i32 cls) {
    if cls < CLASS_SMALL { return cast(i64, cls + 1) * 16; }
    i32 d = (cls - CLASS_SMALL) / 4;
    i32 q = (cls - CLASS_SMALL) % 4;
    i64 base = 1024;
    for i32 i = 0; i < d; i++ { base = base * 2; }
    return base + base / 4 * cast(i64, q + 1);
}

i64 block_of(i64 size) {
    i32 cls = class_of(size);
    return cls < 0 ? size : class_size(cls);
}

struct Chunk {
    u64 base;
    i32 cell;
    i32 cap;
    i32 used;
    i32 n_free;
    i32 free_head;   // a cell index, -1 none; the links in Alloc.link
}

struct Alloc {
    Vec<Chunk> chunks;
    Vec<i32> link;               // per chunk CHUNK_CELLS links
    i32[CLASS_SMALL] cur;
    u64 next_chunk;
    u64 next_big;
    Vec<u64>* big_free;          // CLASS_COUNT lists, the large cells
    Vec<u64>* pool_free;         // CLASS_COUNT lists, the pool's blocks
    i64 live;                    // cell bytes
    i64 pool_live;
}

void alloc_init(Alloc* a, u64 region) {
    a.chunks = vec_new<Chunk>(256);
    a.link = vec_new<i32>(CHUNK_CELLS);
    for i32 i = 0; i < CLASS_SMALL; i++ { a.cur[i] = -1; }
    a.next_chunk = region;
    a.next_big = region + (cast(u64, 1) << 40);
    a.big_free = alloc<Vec<u64>>(CLASS_COUNT);
    a.pool_free = alloc<Vec<u64>>(CLASS_COUNT);
    for i32 i = 0; i < CLASS_COUNT; i++ {
        *(a.big_free + i) = vec_new<u64>(16);
        *(a.pool_free + i) = vec_new<u64>(16);
    }
    a.live = 0;
    a.pool_live = 0;
}

private i32 chunk_new(Alloc* a, i32 cls) {
    Chunk ch = Chunk{};
    ch.base = a.next_chunk;
    a.next_chunk += cast(u64, CHUNK);
    ch.cell = cast(i32, class_size(cls));
    ch.cap = cast(i32, CHUNK / ch.cell);
    ch.used = 0;
    ch.n_free = 0;
    ch.free_head = -1;
    vec_push(&a.chunks, ch);
    for i32 i = 0; i < CHUNK_CELLS; i++ { vec_push(&a.link, -1); }
    return a.chunks.len - 1;
}

// The chunk of the class with the most free cells, or -1.
private i32 chunk_best(Alloc* a, i32 cell) {
    i32 best = -1;
    i32 nb = 0;
    for i32 k = 0; k < a.chunks.len; k++ {
        Chunk* ch = &a.chunks.data[k];
        if ch.cell == cell && ch.n_free > nb { nb = ch.n_free; best = k; }
    }
    return best;
}

u64 alloc_cell(Alloc* a, i64 size) {
    i64 block = block_of(size);
    a.live += block;
    i32 cls = class_of(size);
    if cls >= 0 && cls < CLASS_SMALL {
        i32 k = a.cur[cls];
        while true {
            if k >= 0 {
                Chunk* ch = &a.chunks.data[k];
                if ch.free_head >= 0 {
                    i32 i = ch.free_head;
                    ch.free_head = a.link.data[k * CHUNK_CELLS + i];
                    ch.n_free--;
                    return ch.base + cast(u64, i) * cast(u64, ch.cell);
                }
                if ch.used < ch.cap {
                    i32 i = ch.used;
                    ch.used++;
                    return ch.base + cast(u64, i) * cast(u64, ch.cell);
                }
            }
            // the emptiest chunk if it is at least half free, else a new one
            // while the chunks are under twice the live bytes
            i32 b = chunk_best(a, cast(i32, block));
            i64 footprint = cast(i64, a.chunks.len) * CHUNK;
            if b >= 0 && b != k && (a.chunks.data[b].n_free * 2 >= a.chunks.data[b].cap || footprint >= a.live * 2) {
                k = b;
            } else {
                k = chunk_new(a, cls);
            }
            a.cur[cls] = k;
        }
    }
    if cls >= 0 {
        Vec<u64>* fl = a.big_free + cls;
        if fl.len > 0 { return vec_pop(fl); }
    }
    u64 p = a.next_big;
    a.next_big += cast(u64, (block + 63) / 64 * 64);
    return p;
}

void free_cell(Alloc* a, u64 p, i64 size) {
    i64 block = block_of(size);
    a.live -= block;
    i32 cls = class_of(size);
    if cls >= 0 && cls < CLASS_SMALL {
        i64 k = cast(i64, (p - (a.chunks.data[0].base)) / cast(u64, CHUNK));
        Chunk* ch = &a.chunks.data[k];
        i32 i = cast(i32, (p - ch.base) / cast(u64, ch.cell));
        a.link.data[cast(i32, k) * CHUNK_CELLS + i] = ch.free_head;
        ch.free_head = i;
        ch.n_free++;
        return;
    }
    if cls >= 0 { vec_push(a.big_free + cls, p); }
}

u64 pool_get(Alloc* a, i64 bytes) {
    i32 cls = class_of(bytes);
    i64 block = block_of(bytes);
    a.pool_live += block;
    if cls >= 0 {
        Vec<u64>* fl = a.pool_free + cls;
        if fl.len > 0 { return vec_pop(fl); }
    }
    // the program allocator's blocks, 16 bytes apart past their size
    u64 p = a.next_big;
    a.next_big += cast(u64, (block + 16 + 15) / 16 * 16);
    return p;
}

void pool_put(Alloc* a, u64 p, i64 bytes) {
    if p == 0 { return; }
    a.pool_live -= block_of(bytes);
    i32 cls = class_of(bytes);
    if cls >= 0 { vec_push(a.pool_free + cls, p); }
}

// --- the cells and their tables ---------------------------------------------

// Layouts: 0 real, 1 today, 2 shapes56, 3 shapes64.
const i32 NL = 4;
const i32 L_REAL = 0;
const i32 L_TODAY = 1;
const i32 L_S56 = 2;
const i32 L_S64 = 3;

struct Cell {
    u64 real;
    i32 kind;
    i32 size;          // the real block
    bool live;
    bool shaped;       // an object the shapes would hold (made by js_new_object*)
    bool dict;         // a shaped object gone to a dictionary
    i32 room;          // entries inline
    i32 len;
    i32 cap;           // the table's room: room while inline
    bool[NL] pooled;   // the table's entries are in the pool
    i32 shape;
    u64[NL] base;
    i32[NL] bytes;     // the cell's size in each layout
    u64[NL] items;     // the entries (today), the values or the dictionary (shapes)
}

Vec<Cell> g_cells;
HMap g_by_addr;
Alloc[NL] g_alloc;   // [0] unused: the real addresses are the log's
i64 g_off_obj = 40;
i64 g_off_fn = 48;
i64 g_off_nat = 56;

// --- the transition tree -----------------------------------------------------

struct Shape {
    i32 parent;
    u32 key;
    u8 flags;
    i32 depth;
    i32 kids;
}

Vec<Shape> g_shapes;
HMap g_trans;   // (parent, key, flags) -> child
const i32 SHAPE_MAX_PROPS = 64;
i32 SHAPE_MAX_KIDS = 1536;
const u64 SHAPE_BASE = 0x7000000000000;
i64 g_dict_remove = 0;
i64 g_dict_flags = 0;
i64 g_dict_big = 0;
i64 g_dict_fanout = 0;
i64 g_shaped_objects = 0;
i64 g_other_tables = 0;
i64 g_unknown_tables = 0;
i64 g_events = 0;

u64 shape_addr(i32 s) { return SHAPE_BASE + cast(u64, s) * 64; }

// The child of s that adds key with flags, made if new; -1 when s may not
// take another child.
i32 shape_child(i32 s, u32 key, u8 flags) {
    u64 tk = (cast(u64, cast(u32, s)) << 32) | cast(u64, (key << 3) | cast(u32, flags & 7));
    i32 c = hm_get(&g_trans, tk + 1);
    if c >= 0 { return c; }
    Shape* p = &g_shapes.data[s];
    if p.kids >= SHAPE_MAX_KIDS { return -1; }
    p.kids++;
    Shape n = Shape{};
    n.parent = s;
    n.key = key;
    n.flags = flags;
    n.depth = g_shapes.data[s].depth + 1;
    n.kids = 0;
    vec_push(&g_shapes, n);
    i32 id = g_shapes.len - 1;
    hm_put(&g_trans, tk + 1, id);
    return id;
}

// --- the caches, one per layout and variant ---------------------------------

// 0 real, 1 today, 2 today-nv, 3 shapes56, 4 shapes56-nv, 5 shapes64
const i32 NC = 6;
Cache[NC] g_cache;
i32[NC] g_cache_layout = { 0, 1, 1, 2, 2, 3 };
bool[NC] g_cache_nv = { false, false, true, false, true, false };
str[NC] g_cache_name = { "real", "today", "today-nv", "shapes56", "shapes56-nv", "shapes64" };

i64 hdr_bytes(i32 l) { return l == L_S56 ? 56 : (l == L_S64 ? 64 : 80); }
bool shaped_in(Cell* c, i32 l) { return l >= L_S56 && c.shaped && !c.dict; }
bool dict_in(Cell* c, i32 l) { return l >= L_S56 && c.shaped && c.dict; }

// The bytes of entry or value i in layout l.
u64 slot_addr(Cell* c, i32 l, i32 i) {
    if shaped_in(c, l) { return c.items[l] + cast(u64, i) * 8; }
    return c.items[l] + cast(u64, i) * 16;
}
i64 slot_size(Cell* c, i32 l) { return shaped_in(c, l) ? 8 : 16; }

// The table header's bytes a cached access reads: the kind, the flags, the
// prototype and the table (today) or the shape and the values' pointer.
void touch_head(Cache* k, i32 cat, Cell* c, i32 l) {
    if c.kind != GC_OBJECT {
        i64 off = c.kind == GC_FUNCTION ? g_off_fn : g_off_nat;
        touch(k, cat, c.base[l] + 16, 8);
        touch(k, cat, c.base[l] + cast(u64, off), 16);
        return;
    }
    if shaped_in(c, l) || dict_in(c, l) { touch(k, cat, c.base[l] + 16, 32); return; }
    touch(k, cat, c.base[l] + 16, 40);
}

void touch_value(Cache* k, i32 cat, i32 l, u64 v) {
    if v == 0 { return; }
    i32 id = hm_get(&g_by_addr, v);
    if id < 0 || !g_cells.data[id].live { touch(k, cat, v + 16, 8); return; }
    touch(k, cat, g_cells.data[id].base[l] + 16, 8);
}

Cell* cell_of(i32 id) { return &g_cells.data[id]; }

i32 table_owner(u64 t) {
    i32 id = hm_get(&g_by_addr, t - cast(u64, g_off_obj));
    if id >= 0 && cell_of(id).live && cell_of(id).kind == GC_OBJECT { return id; }
    id = hm_get(&g_by_addr, t - cast(u64, g_off_fn));
    if id >= 0 && cell_of(id).live && cell_of(id).kind == GC_FUNCTION { return id; }
    id = hm_get(&g_by_addr, t - cast(u64, g_off_nat));
    if id >= 0 && cell_of(id).live && cell_of(id).kind == GC_NATIVE { return id; }
    return -1;
}

// The cell's copies made, its zeroing touched.
void place(i32 id) {
    Cell* c = cell_of(id);
    for i32 l = 0; l < NL; l++ {
        i64 bytes = c.size;
        if l >= L_S56 && c.shaped { bytes = block_of(hdr_bytes(l) + cast(i64, c.room) * 8); }
        c.bytes[l] = cast(i32, bytes);
        if l == L_REAL { c.base[l] = c.real; } else { c.base[l] = alloc_cell(&g_alloc[l], bytes); }
        if c.shaped && c.room > 0 { c.items[l] = c.base[l] + cast(u64, hdr_bytes(l)); }
        else { c.items[l] = 0; }
    }
    for i32 k = 0; k < NC; k++ {
        i32 l = g_cache_layout[k];
        touch(&g_cache[k], CAT_ALLOC, c.base[l], c.bytes[l]);
    }
}

i32 g_pending = -1;

void settle_pending() {
    if g_pending < 0 { return; }
    place(g_pending);
    g_pending = -1;
}

// The table's bytes in the pool in layout l, for its room cap.
i64 pool_bytes(Cell* c, i32 l, i32 cap) {
    return cast(i64, cap) * slot_size(c, l);
}

void release_tables(Cell* c) {
    for i32 l = 1; l < NL; l++ {
        if c.pooled[l] { pool_put(&g_alloc[l], c.items[l], pool_bytes(c, l, c.cap)); }
        c.pooled[l] = false;
    }
}

void ev_free(u64 a) {
    i32 id = hm_get(&g_by_addr, a);
    if id < 0 { return; }
    Cell* c = cell_of(id);
    if !c.live { return; }
    if g_pending == id { settle_pending(); }
    release_tables(c);
    c.live = false;
    for i32 l = 1; l < NL; l++ { free_cell(&g_alloc[l], c.base[l], c.bytes[l]); }
}

void ev_alloc(u64 a, i32 size, i32 kind) {
    i32 id = hm_get(&g_by_addr, a);
    if id >= 0 && cell_of(id).live { ev_free(a); }
    if id < 0 {
        vec_push(&g_cells, Cell{});
        id = g_cells.len - 1;
        hm_put(&g_by_addr, a, id);
    }
    Cell* c = cell_of(id);
    *c = Cell{};
    c.real = a;
    c.kind = kind;
    c.size = size;
    c.live = true;
    c.shape = 0;
    if kind == GC_OBJECT { g_pending = id; return; }
    place(id);
}

// A dictionary for a shaped object: its values copied into 16-byte entries.
void to_dict(Cell* c, i64* reason) {
    *reason += 1;
    for i32 l = L_S56; l < NL; l++ {
        if c.cap == 0 { c.items[l] = 0; c.pooled[l] = false; continue; }
        u64 nd = pool_get(&g_alloc[l], cast(i64, c.cap) * 16);
        for i32 k = 0; k < NC; k++ {
            if g_cache_layout[k] != l { continue; }
            touch(&g_cache[k], CAT_TABLE, c.items[l], cast(i64, c.len) * 8);
            touch(&g_cache[k], CAT_TABLE, nd, cast(i64, c.len) * 16);
        }
        if c.pooled[l] { pool_put(&g_alloc[l], c.items[l], cast(i64, c.cap) * 8); }
        c.items[l] = nd;
        c.pooled[l] = true;
    }
    c.dict = true;
}

void ev_grow(u64 t, u64 items, i32 ncap) {
    i32 id = table_owner(t);
    if id < 0 { g_unknown_tables++; return; }
    Cell* c = cell_of(id);
    if items == 0 {
        // the table reset
        release_tables(c);
        c.len = 0;
        c.cap = 0;
        c.shape = 0;
        c.dict = false;
        for i32 l = 0; l < NL; l++ { c.items[l] = 0; }
        return;
    }
    u64[NL] ni;
    ni[L_REAL] = items;
    for i32 l = 1; l < NL; l++ { ni[l] = pool_get(&g_alloc[l], pool_bytes(c, l, ncap)); }
    for i32 k = 0; k < NC; k++ {
        i32 l = g_cache_layout[k];
        i64 n = cast(i64, c.len) * slot_size(c, l);
        touch(&g_cache[k], CAT_TABLE, c.items[l], n);
        touch(&g_cache[k], CAT_TABLE, ni[l], n);
    }
    for i32 l = 1; l < NL; l++ {
        if c.pooled[l] { pool_put(&g_alloc[l], c.items[l], pool_bytes(c, l, c.cap)); }
    }
    for i32 l = 0; l < NL; l++ { c.items[l] = ni[l]; c.pooled[l] = true; }
    c.cap = ncap;
}

void ev_add(u64 t, u32 key, u8 flags) {
    i32 id = table_owner(t);
    if id < 0 { g_unknown_tables++; return; }
    Cell* c = cell_of(id);
    if c.shaped && !c.dict {
        if c.len >= SHAPE_MAX_PROPS { to_dict(c, &g_dict_big); }
        else {
            i32 s = shape_child(c.shape, key, flags);
            if s < 0 { to_dict(c, &g_dict_fanout); }
            else {
                for i32 k = 0; k < NC; k++ {
                    if g_cache_layout[k] < L_S56 { continue; }
                    touch(&g_cache[k], CAT_ADD, shape_addr(c.shape), 64);
                    touch(&g_cache[k], CAT_ADD, shape_addr(s), 64);
                }
                c.shape = s;
            }
        }
    }
    for i32 k = 0; k < NC; k++ {
        i32 l = g_cache_layout[k];
        touch_head(&g_cache[k], CAT_ADD, c, l);
        if c.items[l] != 0 { touch(&g_cache[k], CAT_ADD, slot_addr(c, l, c.len), slot_size(c, l)); }
    }
    c.len++;
}

void ev_remove(u64 t, i32 pos) {
    i32 id = table_owner(t);
    if id < 0 { g_unknown_tables++; return; }
    Cell* c = cell_of(id);
    bool last = pos == c.len - 1;
    if c.shaped && !c.dict {
        if last { c.shape = g_shapes.data[c.shape].parent; }
        else { to_dict(c, &g_dict_remove); }
    }
    for i32 k = 0; k < NC; k++ {
        i32 l = g_cache_layout[k];
        touch_head(&g_cache[k], CAT_TABLE, c, l);
        if !shaped_in(c, l) && c.items[l] != 0 {
            touch(&g_cache[k], CAT_TABLE, slot_addr(c, l, pos), cast(i64, c.len - pos) * 16);
        }
    }
    c.len--;
}

void ev_flags(u64 t) {
    i32 id = table_owner(t);
    if id < 0 { g_unknown_tables++; return; }
    Cell* c = cell_of(id);
    if c.shaped && !c.dict { to_dict(c, &g_dict_flags); }
}

void ev_read(u64 t, u64 v, i32 slot, i32 cat) {
    i32 id = table_owner(t);
    if id < 0 { g_unknown_tables++; return; }
    Cell* c = cell_of(id);
    for i32 k = 0; k < NC; k++ {
        i32 l = g_cache_layout[k];
        touch_head(&g_cache[k], cat, c, l);
        if c.items[l] != 0 { touch(&g_cache[k], cat, slot_addr(c, l, slot), slot_size(c, l)); }
        // today's write tests the old value; a shape knows it is a data property
        bool want_v = cat == CAT_READ ? !g_cache_nv[k] : (l < L_S56 && !g_cache_nv[k]);
        if want_v { touch_value(&g_cache[k], cat, l, v); }
    }
}

void ev_pread(u64 rt, u64 pt, u64 v, i32 slot) {
    i32 rid = rt == 0 ? -1 : table_owner(rt);
    i32 pid = table_owner(pt);
    if pid < 0 { g_unknown_tables++; return; }
    Cell* p = cell_of(pid);
    for i32 k = 0; k < NC; k++ {
        i32 l = g_cache_layout[k];
        if rid >= 0 {
            Cell* r = cell_of(rid);
            touch_head(&g_cache[k], CAT_PREAD, r, l);
            // today the receiver's own entries are scanned for the name; a
            // shape id says it has none of that name
            if !shaped_in(r, l) && r.items[l] != 0 { touch(&g_cache[k], CAT_PREAD, r.items[l], cast(i64, r.len) * 16); }
        }
        touch_head(&g_cache[k], CAT_PREAD, p, l);
        if p.items[l] != 0 { touch(&g_cache[k], CAT_PREAD, slot_addr(p, l, slot), slot_size(p, l)); }
        if !g_cache_nv[k] { touch_value(&g_cache[k], CAT_PREAD, l, v); }
    }
}

void ev_mark(u64 a) {
    i32 id = hm_get(&g_by_addr, a);
    for i32 k = 0; k < NC; k++ {
        i32 l = g_cache_layout[k];
        if id < 0 || !cell_of(id).live { touch(&g_cache[k], CAT_MARK, a + 16, 8); }
        else { touch(&g_cache[k], CAT_MARK, cell_of(id).base[l] + 16, 8); }
    }
}

void ev_trace(u64 t, i32 n) {
    i32 id = table_owner(t);
    if id < 0 { g_unknown_tables++; return; }
    Cell* c = cell_of(id);
    for i32 k = 0; k < NC; k++ {
        i32 l = g_cache_layout[k];
        touch_head(&g_cache[k], CAT_MARK, c, l);
        if c.items[l] != 0 { touch(&g_cache[k], CAT_MARK, c.items[l], cast(i64, n) * slot_size(c, l)); }
        if shaped_in(c, l) { touch(&g_cache[k], CAT_MARK, shape_addr(c.shape), 64); }
    }
}

void ev_object(u64 a, i32 room) {
    if g_pending < 0 || cell_of(g_pending).real != a { settle_pending(); return; }
    Cell* c = cell_of(g_pending);
    c.shaped = true;
    c.room = room;
    c.cap = room;
    g_shaped_objects++;
    place(g_pending);
    g_pending = -1;
}

void pad(str t, i32 w) {
    for i32 i = t.len; i < w; i++ { print(" "); }
    print("{}", t);
}
void padn(i64 v, i32 w) {
    string t = format("{}", v);
    pad(t, w);
    free(t);
}
void padl(str t, i32 w) {
    print("{}", t);
    for i32 i = t.len; i < w; i++ { print(" "); }
}
i32 parse_i32(u8* p) {
    i32 v = 0;
    while *p >= '0' && *p <= '9' { v = v * 10 + cast(i32, *p - '0'); p = p + 1; }
    return v;
}

void report() {
    str[NCAT] cats = { "alloc", "read", "proto read", "write", "add", "table", "mark" };
    print("{} events, {} cells, {} objects shaped, {} tables unknown\n", g_events, g_cells.len, g_shaped_objects, g_unknown_tables);
    print("\nL1 misses by what touched the line (lines touched in brackets, the real layout's):\n");
    padl("", 12);
    for i32 k = 0; k < NC; k++ { pad(g_cache_name[k], 13); }
    print("\n");
    for i32 cat = 0; cat < NCAT; cat++ {
        padl(cats[cat], 12);
        for i32 k = 0; k < NC; k++ { padn(g_cache[k].m1[cat], 13); }
        print("   [{}]\n", g_cache[0].acc[cat]);
    }
    print("\nL2 misses:\n");
    for i32 cat = 0; cat < NCAT; cat++ {
        padl(cats[cat], 12);
        for i32 k = 0; k < NC; k++ { padn(g_cache[k].m2[cat], 13); }
        print("\n");
    }
    print("\nL3 misses:\n");
    for i32 cat = 0; cat < NCAT; cat++ {
        padl(cats[cat], 12);
        for i32 k = 0; k < NC; k++ { padn(g_cache[k].m3[cat], 13); }
        print("\n");
    }
    print("\nlines touched:\n");
    for i32 cat = 0; cat < NCAT; cat++ {
        padl(cats[cat], 12);
        for i32 k = 0; k < NC; k++ { padn(g_cache[k].acc[cat], 13); }
        print("\n");
    }
    // what the live objects hold at the end
    i64[NL] obj_bytes;
    i64[NL] all_bytes;
    i64 n_obj = 0;
    i64 n_dict = 0;
    i64 n_live = 0;
    for i32 l = 0; l < NL; l++ { obj_bytes[l] = 0; all_bytes[l] = 0; }
    for i32 i = 0; i < g_cells.len; i++ {
        Cell* c = cell_of(i);
        if !c.live { continue; }
        n_live++;
        for i32 l = 0; l < NL; l++ {
            i64 tb = c.pooled[l] || (l == L_REAL && c.pooled[L_TODAY]) ? block_of(pool_bytes(c, l, c.cap)) : 0;
            all_bytes[l] += c.bytes[l] + tb;
            if c.shaped { obj_bytes[l] += c.bytes[l] + tb; }
        }
        if c.shaped { n_obj++; if c.dict { n_dict++; } }
    }
    print("\nat the end: {} live cells, {} shaped objects, {} of them dictionaries\n", n_live, n_obj, n_dict);
    print("objects and their tables, KB:   today {}, shapes56 {}, shapes64 {} (real {})\n",
        obj_bytes[L_TODAY] / 1024, obj_bytes[L_S56] / 1024, obj_bytes[L_S64] / 1024, obj_bytes[L_REAL] / 1024);
    print("every cell and table, KB:       today {}, shapes56 {}, shapes64 {}\n",
        all_bytes[L_TODAY] / 1024, all_bytes[L_S56] / 1024, all_bytes[L_S64] / 1024);
    i32 maxk = 0;
    i64[6] hist;
    for i32 i = 0; i < 6; i++ { hist[i] = 0; }
    for i32 i = 0; i < g_shapes.len; i++ {
        i32 kd = g_shapes.data[i].kids;
        if kd > maxk { maxk = kd; }
        if kd == 0 { hist[0]++; } else if kd == 1 { hist[1]++; } else if kd <= 4 { hist[2]++; }
        else if kd <= 16 { hist[3]++; } else if kd < 32 { hist[4]++; } else { hist[5]++; }
    }
    print("shapes: {} ({} KB at 48 bytes and 8 per transition); children per shape: 0 {}, 1 {}, 2-4 {}, 5-16 {}, 17-31 {}, 32 {}; most {}\n",
        g_shapes.len, (cast(i64, g_shapes.len) * 56) / 1024, hist[0], hist[1], hist[2], hist[3], hist[4], hist[5], maxk);
    // the widest shapes
    for i32 r = 0; r < 8; r++ {
        i32 best = -1;
        for i32 i = 0; i < g_shapes.len; i++ {
            Shape* sh = &g_shapes.data[i];
            if sh.kids >= 0 && (best < 0 || sh.kids > g_shapes.data[best].kids) { best = i; }
        }
        if best < 0 { break; }
        print("  shape {} at depth {} (key {}): {} children
", best, g_shapes.data[best].depth, g_shapes.data[best].key, g_shapes.data[best].kids);
        g_shapes.data[best].kids = -1 - g_shapes.data[best].kids;
    }
    print("objects to a dictionary: {} by a removal, {} by a change of flags, {} past {} properties, {} past {} children; of {} shaped objects made\n",
        g_dict_remove, g_dict_flags, g_dict_big, SHAPE_MAX_PROPS, g_dict_fanout, SHAPE_MAX_KIDS, g_shaped_objects);
}

i32 main() {
    if get_argc() < 2 { eprint("usage: memsim trace.bin [l1_kb l2_kb l3_kb [max_children]]\n"); return 2; }
    // a Zen 3 core's: 32 KB, 512 KB, and its 32 MB L3
    i32 l1kb = 32;
    i32 l2kb = 512;
    i32 l3kb = 32768;
    if get_argc() >= 5 {
        l1kb = parse_i32(get_arg(2));
        l2kb = parse_i32(get_arg(3));
        l3kb = parse_i32(get_arg(4));
    }
    if get_argc() >= 6 { SHAPE_MAX_KIDS = parse_i32(get_arg(5)); }
    for i32 k = 0; k < NC; k++ { cache_init(&g_cache[k], l1kb, l2kb, l3kb); }
    g_cells = vec_new<Cell>(1 << 20);
    hm_init(&g_by_addr, 22);
    hm_init(&g_trans, 16);
    g_shapes = vec_new<Shape>(1 << 16);
    vec_push(&g_shapes, Shape{ .parent = 0, .key = 0, .flags = 0, .depth = 0, .kids = 0 });
    for i32 l = 1; l < NL; l++ { alloc_init(&g_alloc[l], cast(u64, l) << 48); }

    i64 fd = open(get_arg(1), 0);
    if fd == -1 { eprint("cannot open the trace\n"); return 1; }
    i32 nb = 65536;
    MtRec* buf = alloc<MtRec>(nb);
    i64 have = 0;
    while true {
        i64 want = cast(i64, nb) * sizeof(MtRec) - have;
        i32 n = read(fd, cast(u8*, buf) + have, cast(i32, want));
        if n > 0 { have += n; }
        i64 recs = have / sizeof(MtRec);
        if n <= 0 && recs == 0 { break; }
        if have < cast(i64, nb) * sizeof(MtRec) && n > 0 { continue; }
        for i64 i = 0; i < recs; i++ {
            MtRec* r = buf + i;
            u32 ty = r.t & 255;
            u32 d = r.t >> 8;
            g_events++;
            if ty != MT_OBJECT && ty != MT_HEADER { settle_pending(); }
            if ty == MT_HEADER {
                g_off_obj = cast(i64, r.a);
                g_off_fn = cast(i64, r.b);
                g_off_nat = cast(i64, r.c);
            } else if ty == MT_ALLOC { ev_alloc(r.a, cast(i32, r.c), cast(i32, d)); }
            else if ty == MT_FREE { ev_free(r.a); }
            else if ty == MT_OBJECT { ev_object(r.a, cast(i32, r.c)); }
            else if ty == MT_GROW { ev_grow(r.a, r.b, cast(i32, r.c)); }
            else if ty == MT_ADD { ev_add(r.a, r.c, cast(u8, d & 255)); }
            else if ty == MT_REMOVE { ev_remove(r.a, cast(i32, d)); }
            else if ty == MT_FLAGS { ev_flags(r.a); }
            else if ty == MT_READ { ev_read(r.a, r.b, cast(i32, r.c), CAT_READ); }
            else if ty == MT_WRITE { ev_read(r.a, r.b, cast(i32, r.c), CAT_WRITE); }
            else if ty == MT_PREAD { ev_pread(r.a, r.b, r.e, cast(i32, r.c)); }
            else if ty == MT_MARK { ev_mark(r.a); }
            else if ty == MT_TRACE { ev_trace(r.a, cast(i32, r.c)); }
        }
        have = 0;
        if n <= 0 { break; }
    }
    close(fd);
    report();
    return 0;
}

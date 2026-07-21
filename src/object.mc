// object.mc — runtime object kinds on the GC heap.
//
// Property tables are insertion-ordered {atom, value} arrays: JS
// enumeration order comes for free and objects stay small until a
// shapes optimization pass. Objects carry a prototype link and an
// optional dense array part. Natives carry three env slots so bound
// functions and similar wrappers need no extra kinds. This module
// registers the heap's tracer and finalizer hooks.

import vec;
import map;
import value;
import gc;
import atom;
import bigint;

// continues GcKind: 0..1 are built into gc.mc
const i32 GC_OBJECT   = 2;
const i32 GC_FUNCTION = 3;
const i32 GC_NATIVE   = 4;
const i32 GC_BOX      = 5;
const i32 GC_ACCESSOR = 6;
const i32 GC_SYMBOL   = 7;
const i32 GC_GENERATOR = 8;
const i32 GC_MAP      = 9;
const i32 GC_BIGINT   = 10;
const i32 GC_BYTES    = 11;   // raw byte buffer (ArrayBuffer backing store)

const i32 GEN_START = 0;
const i32 GEN_SUSPENDED = 1;
const i32 GEN_RUNNING = 2;
const i32 GEN_DONE = 3;

const i32 OBJF_ARRAY = 1;
const i32 OBJF_NONEXT = 2;   // not extensible (Object.preventExtensions)
const i32 OBJF_TYPEDARRAY = 4;   // a TypedArray view (element access reads bytes)
const i32 OBJF_PROXY = 8;    // a Proxy: fundamental ops route through the handler

// Property attribute bits. Ordinary assignment creates PROP_DEFAULT;
// Object.defineProperty can clear any of them.
const u8 PROP_WRITABLE = 1;
const u8 PROP_ENUMERABLE = 2;
const u8 PROP_CONFIGURABLE = 4;
const u8 PROP_DEFAULT = 7;

struct FnTemplate;

struct Prop {
    u32 key;
    u8 flags;
    Value val;
}

// Insertion-ordered {key, value} entries. Small tables scan linearly
// (cache-friendly); once a table grows past PROPS_INDEX_MIN a hash
// index (key -> item position) makes lookups O(1) for dictionary-
// pattern objects. Enumeration always walks `items` in order.
const i32 PROPS_INDEX_MIN = 16;

struct PropList {
    Prop* items;
    i32 len;
    i32 cap;
    IntMap<i32>* idx;   // null below the threshold
}

void props_init(PropList* p) {
    p.items = null;
    p.len = 0;
    p.cap = 0;
    p.idx = null;
}

void props_free(PropList* p) {
    if p.items != null { free(p.items); }
    if p.idx != null {
        intmap_free<i32>(p.idx);
        free(p.idx);
    }
    props_init(p);
}

private void props_build_index(PropList* p) {
    p.idx = new(IntMap<i32>);
    intmap_init<i32>(p.idx);
    for i32 i = 0; i < p.len; i++ {
        intmap_set<i32>(p.idx, (p.items + i).key, i);
    }
}

Value* props_get(PropList* p, u32 key) {
    if p.idx != null {
        i32* pos = intmap_get<i32>(p.idx, key);
        if pos != null { return &(p.items + *pos).val; }
        return null;
    }
    for i32 i = 0; i < p.len; i++ {
        Prop* pr = p.items + i;
        if pr.key == key { return &pr.val; }
    }
    return null;
}

// The full entry (with attribute flags), or null.
Prop* props_entry(PropList* p, u32 key) {
    if p.idx != null {
        i32* pos = intmap_get<i32>(p.idx, key);
        if pos != null { return p.items + *pos; }
        return null;
    }
    for i32 i = 0; i < p.len; i++ {
        Prop* pr = p.items + i;
        if pr.key == key { return pr; }
    }
    return null;
}

// Appends a fresh entry with the given attribute flags. Caller must
// have checked the key is absent.
private Prop* props_append(PropList* p, u32 key, Value v, u8 flags) {
    if p.len >= p.cap {
        i32 ncap = p.cap * 2;
        if ncap < 4 { ncap = 4; }
        Prop* ni = alloc<Prop>(ncap);
        for i32 i = 0; i < p.len; i++ {
            *(ni + i) = *(p.items + i);
        }
        if p.items != null { free(p.items); }
        p.items = ni;
        p.cap = ncap;
    }
    i32 pos = p.len;
    Prop* pr = p.items + pos;
    pr.key = key;
    pr.val = v;
    pr.flags = flags;
    p.len++;
    if p.idx != null {
        intmap_set<i32>(p.idx, key, pos);
    } else if p.len >= PROPS_INDEX_MIN {
        props_build_index(p);
    }
    return p.items + pos;
}

void props_set(PropList* p, u32 key, Value v) {
    Value* ex = props_get(p, key);
    if ex != null {
        *ex = v;
        return;
    }
    ignore props_append(p, key, v, PROP_DEFAULT);
}

// Creates or updates an entry, setting both value and attribute flags.
void props_set_desc(PropList* p, u32 key, Value v, u8 flags) {
    Prop* ex = props_entry(p, key);
    if ex != null {
        ex.val = v;
        ex.flags = flags;
        return;
    }
    ignore props_append(p, key, v, flags);
}

bool props_remove(PropList* p, u32 key) {
    for i32 i = 0; i < p.len; i++ {
        if (p.items + i).key == key {
            for i32 j = i; j + 1 < p.len; j++ {
                *(p.items + j) = *(p.items + j + 1);
            }
            p.len--;
            // positions shifted; rebuild the index
            if p.idx != null {
                intmap_free<i32>(p.idx);
                free(p.idx);
                p.idx = null;
                if p.len >= PROPS_INDEX_MIN { props_build_index(p); }
            }
            return true;
        }
    }
    return false;
}

struct JsObject {
    GcCell head;
    i32 obj_flags;
    JsObject* proto;
    PropList props;
    Value* elems;          // dense array part
    i32 elen;
    i32 ecap;
}

// A Proxy. The leading fields are byte-identical to JsObject so value_is_object
// / value_as_object work unchanged; the kind is GC_OBJECT with OBJF_PROXY set,
// and the fundamental operations detect the flag and route through `handler`.
// `proto` is a snapshot of the target's prototype at construction (untrapped
// proto walks then behave like the target). The props/elems are unused.
struct JsProxy {
    GcCell head;
    i32 obj_flags;
    JsObject* proto;
    PropList props;
    Value* elems;
    i32 elen;
    i32 ecap;
    Value target;
    Value handler;
}

// A raw byte buffer (the backing store of an ArrayBuffer). Bytes live
// inline after the header; no references, so the tracer skips it.
struct GcBytes {
    GcCell head;
    i32 len;
}

u8* gb_data(GcBytes* g) { return cast(u8*, g) + sizeof(GcBytes); }

GcBytes* js_new_bytes(GcHeap* h, i32 len) {
    i32 n = len > 0 ? len : 0;
    GcBytes* g = cast(GcBytes*, gc_alloc(h, GC_BYTES, sizeof(GcBytes) + cast(i64, n)));
    g.len = n;
    memset(gb_data(g), 0, cast(i64, n));
    return g;
}

bool value_is_bytes(Value v) { return value_is_kind(v, GC_BYTES); }
GcBytes* value_as_bytes(Value v) { return cast(GcBytes*, value_as_cell(v)); }

struct JsFunction {
    GcCell head;
    FnTemplate* tmpl;
    Value* upvals;         // boxes, one per template upvalue
    i32 n_upvals;
    PropList props;
    Value fproto;          // [[Prototype]]: parent ctor for derived classes
}

// ctx is the owning VM; typed as void* to keep layering one-way.
type NativeFn = fn(void*, Value, Value, Value*, i32): Value;

struct JsNative {
    GcCell head;
    NativeFn fun;
    str name;              // static or atom-owned view
    PropList props;
    Value env0;            // bound target / wrapper state
    Value env1;
    Value env2;
}

struct JsBox {
    GcCell head;
    Value v;
}

// Map/Set: insertion-ordered entries; deletion tombstones a slot to
// preserve order. Set stores keys and ignores vals.
struct JsMap {
    GcCell head;
    JsObject* proto;
    Value* keys;
    Value* vals;
    bool* live;
    i32 len;      // slots used, including tombstones
    i32 cap;
    i32 count;    // live entries
    bool is_set;
    bool weak;    // WeakMap/WeakSet: keys held weakly, not traced
}

// Arbitrary-precision integer: base-1e9 limbs stored inline after the
// cell (like GcString). Holds no GC references.
struct GcBigInt {
    GcCell head;
    bool neg;
    i32 nlimbs;
}

GcBigInt* js_new_bigint(GcHeap* h, BigNum a) {
    GcCell* c = gc_alloc(h, GC_BIGINT, sizeof(GcBigInt) + cast(i64, a.n) * 4);
    GcBigInt* g = cast(GcBigInt*, c);
    g.neg = a.neg;
    g.nlimbs = a.n;
    u32* dst = cast(u32*, cast(u8*, g) + sizeof(GcBigInt));
    for i32 i = 0; i < a.n; i++ { *(dst + i) = *(a.limbs + i); }
    return g;
}

// A borrowing BigNum over the inline limbs — never bn_free it.
BigNum bigint_view(GcBigInt* g) {
    BigNum r;
    r.neg = g.neg;
    r.n = g.nlimbs;
    r.limbs = cast(u32*, cast(u8*, g) + sizeof(GcBigInt));
    return r;
}

// Accessor property payload; lives as the property's stored value.
struct JsAccessor {
    GcCell head;
    Value get;
    Value set;
}

// Symbols carry a property-key id in a reserved space (high bit set)
// so symbol-keyed properties share the ordinary tables.
struct JsSymbol {
    GcCell head;
    u32 id;
    Value desc;
}

// Suspended frame image of a generator or async function.
struct JsGenerator {
    GcCell head;
    JsFunction* fun;
    Value this_val;
    Value arguments_obj;   // the body's `arguments`, or undefined
    i32 state;           // GEN_*
    i32 resume_ip;
    Value* saved;        // slots + operand stack at suspension
    i32 saved_len;
    i32* handler_data;   // open try handlers: (sp_rel, ip) pairs
    i32 n_handlers;
}

// --- GC hooks ---------------------------------------------------------

private void mark_props(GcHeap* h, PropList* p) {
    for i32 i = 0; i < p.len; i++ {
        gc_mark_value(h, (p.items + i).val);
    }
}

void js_trace(GcHeap* h, GcCell* c) {
    if c.kind == GC_OBJECT {
        JsObject* o = cast(JsObject*, c);
        if o.proto != null { gc_mark_cell(h, &o.proto.head); }
        mark_props(h, &o.props);
        for i32 i = 0; i < o.elen; i++ {
            gc_mark_value(h, *(o.elems + i));
        }
        if (o.obj_flags & OBJF_PROXY) != 0 {
            JsProxy* p = cast(JsProxy*, o);
            gc_mark_value(h, p.target);
            gc_mark_value(h, p.handler);
        }
        return;
    }
    if c.kind == GC_FUNCTION {
        JsFunction* f = cast(JsFunction*, c);
        for i32 i = 0; i < f.n_upvals; i++ {
            gc_mark_value(h, *(f.upvals + i));
        }
        mark_props(h, &f.props);
        gc_mark_value(h, f.fproto);
        return;
    }
    if c.kind == GC_NATIVE {
        JsNative* n = cast(JsNative*, c);
        mark_props(h, &n.props);
        gc_mark_value(h, n.env0);
        gc_mark_value(h, n.env1);
        gc_mark_value(h, n.env2);
        return;
    }
    if c.kind == GC_BOX {
        JsBox* b = cast(JsBox*, c);
        gc_mark_value(h, b.v);
        return;
    }
    if c.kind == GC_ACCESSOR {
        JsAccessor* a = cast(JsAccessor*, c);
        gc_mark_value(h, a.get);
        gc_mark_value(h, a.set);
        return;
    }
    if c.kind == GC_SYMBOL {
        gc_mark_value(h, cast(JsSymbol*, c).desc);
        return;
    }
    if c.kind == GC_GENERATOR {
        JsGenerator* g = cast(JsGenerator*, c);
        if g.fun != null { gc_mark_cell(h, &g.fun.head); }
        gc_mark_value(h, g.this_val);
        gc_mark_value(h, g.arguments_obj);
        for i32 i = 0; i < g.saved_len; i++ {
            gc_mark_value(h, *(g.saved + i));
        }
        return;
    }
    if c.kind == GC_MAP {
        JsMap* mp = cast(JsMap*, c);
        if mp.proto != null { gc_mark_cell(h, &mp.proto.head); }
        // Weak maps hold keys/values weakly; the ephemeron pass marks
        // values whose key is otherwise live (see vm_weak_mark).
        if mp.weak { return; }
        for i32 i = 0; i < mp.len; i++ {
            if *(mp.live + i) {
                gc_mark_value(h, *(mp.keys + i));
                gc_mark_value(h, *(mp.vals + i));
            }
        }
        return;
    }
    if c.kind == GC_BIGINT { return; }   // inline limbs, no references
    if c.kind == GC_BYTES { return; }    // inline bytes, no references
    eprint("gc: unknown runtime cell kind {}\n", c.kind);
    exit(70);
}

void js_finalize(GcCell* c) {
    if c.kind == GC_OBJECT {
        JsObject* o = cast(JsObject*, c);
        props_free(&o.props);
        if o.elems != null { free(o.elems); }
        return;
    }
    if c.kind == GC_FUNCTION {
        JsFunction* f = cast(JsFunction*, c);
        props_free(&f.props);
        if f.upvals != null { free(f.upvals); }
        return;
    }
    if c.kind == GC_NATIVE {
        props_free(&cast(JsNative*, c).props);
        return;
    }
    if c.kind == GC_GENERATOR {
        JsGenerator* g = cast(JsGenerator*, c);
        if g.saved != null { free(g.saved); }
        if g.handler_data != null { free(g.handler_data); }
        return;
    }
    if c.kind == GC_MAP {
        JsMap* mp = cast(JsMap*, c);
        if mp.keys != null { free(mp.keys); }
        if mp.vals != null { free(mp.vals); }
        if mp.live != null { free(mp.live); }
        return;
    }
}

// --- constructors -----------------------------------------------------

JsObject* js_new_object(GcHeap* h, JsObject* proto) {
    JsObject* o = cast(JsObject*, gc_alloc(h, GC_OBJECT, sizeof(JsObject)));
    o.proto = proto;
    props_init(&o.props);
    return o;
}

JsProxy* js_new_proxy(GcHeap* h, JsObject* proto, Value target, Value handler) {
    JsProxy* p = cast(JsProxy*, gc_alloc(h, GC_OBJECT, sizeof(JsProxy)));
    p.obj_flags = OBJF_PROXY;
    p.proto = proto;
    props_init(&p.props);
    p.target = target;
    p.handler = handler;
    return p;
}

JsObject* js_new_array(GcHeap* h, JsObject* proto) {
    JsObject* o = js_new_object(h, proto);
    o.obj_flags |= OBJF_ARRAY;
    return o;
}

JsFunction* js_new_function(GcHeap* h, FnTemplate* t, i32 n_upvals) {
    JsFunction* f = cast(JsFunction*, gc_alloc(h, GC_FUNCTION, sizeof(JsFunction)));
    f.tmpl = t;
    f.n_upvals = n_upvals;
    f.upvals = null;
    if n_upvals > 0 {
        f.upvals = alloc<Value>(n_upvals);
        for i32 i = 0; i < n_upvals; i++ {
            *(f.upvals + i) = value_undefined();
        }
    }
    props_init(&f.props);
    f.fproto = value_undefined();
    return f;
}

JsNative* js_new_native(GcHeap* h, NativeFn fun, str name) {
    JsNative* n = cast(JsNative*, gc_alloc(h, GC_NATIVE, sizeof(JsNative)));
    n.fun = fun;
    n.name = name;
    props_init(&n.props);
    n.env0 = value_undefined();
    n.env1 = value_undefined();
    n.env2 = value_undefined();
    return n;
}

JsBox* js_new_box(GcHeap* h, Value v) {
    JsBox* b = cast(JsBox*, gc_alloc(h, GC_BOX, sizeof(JsBox)));
    b.v = v;
    return b;
}

JsAccessor* js_new_accessor(GcHeap* h) {
    JsAccessor* a = cast(JsAccessor*, gc_alloc(h, GC_ACCESSOR, sizeof(JsAccessor)));
    a.get = value_undefined();
    a.set = value_undefined();
    return a;
}

JsSymbol* js_new_symbol(GcHeap* h, u32 id, Value desc) {
    JsSymbol* s = cast(JsSymbol*, gc_alloc(h, GC_SYMBOL, sizeof(JsSymbol)));
    s.id = id;
    s.desc = desc;
    return s;
}

JsGenerator* js_new_generator(GcHeap* h, JsFunction* fun, Value this_val) {
    JsGenerator* g = cast(JsGenerator*, gc_alloc(h, GC_GENERATOR, sizeof(JsGenerator)));
    g.fun = fun;
    g.this_val = this_val;
    g.arguments_obj = value_undefined();
    g.state = GEN_START;
    return g;
}

JsMap* js_new_map(GcHeap* h, JsObject* proto, bool is_set) {
    JsMap* mp = cast(JsMap*, gc_alloc(h, GC_MAP, sizeof(JsMap)));
    mp.proto = proto;
    mp.is_set = is_set;
    mp.weak = false;
    return mp;
}

// Grows the parallel arrays to hold one more slot.
void map_reserve(JsMap* mp) {
    if mp.len < mp.cap { return; }
    i32 ncap = mp.cap * 2;
    if ncap < 8 { ncap = 8; }
    Value* nk = alloc<Value>(ncap);
    Value* nv = alloc<Value>(ncap);
    bool* nl = alloc<bool>(ncap);
    for i32 i = 0; i < mp.len; i++ {
        *(nk + i) = *(mp.keys + i);
        *(nv + i) = *(mp.vals + i);
        *(nl + i) = *(mp.live + i);
    }
    if mp.keys != null { free(mp.keys); free(mp.vals); free(mp.live); }
    mp.keys = nk;
    mp.vals = nv;
    mp.live = nl;
    mp.cap = ncap;
}

// --- value helpers ------------------------------------------------------

bool value_is_kind(Value v, i32 kind) {
    if !value_is_cell(v) { return false; }
    return value_as_cell(v).kind == kind;
}

bool value_is_string(Value v)  { return value_is_kind(v, GC_STRING); }
bool value_is_object(Value v)  { return value_is_kind(v, GC_OBJECT); }
bool value_is_function(Value v){ return value_is_kind(v, GC_FUNCTION); }
bool value_is_native(Value v)  { return value_is_kind(v, GC_NATIVE); }
bool value_is_callable(Value v){ return value_is_function(v) || value_is_native(v); }

bool value_is_accessor(Value v) { return value_is_kind(v, GC_ACCESSOR); }
bool value_is_symbol(Value v)   { return value_is_kind(v, GC_SYMBOL); }
bool value_is_generator(Value v){ return value_is_kind(v, GC_GENERATOR); }
bool value_is_map(Value v)      { return value_is_kind(v, GC_MAP); }
bool value_is_bigint(Value v)   { return value_is_kind(v, GC_BIGINT); }
GcBigInt* value_as_bigint(Value v) { return cast(GcBigInt*, value_as_cell(v)); }

JsSymbol* value_as_symbol(Value v)       { return cast(JsSymbol*, value_as_cell(v)); }
JsGenerator* value_as_generator(Value v) { return cast(JsGenerator*, value_as_cell(v)); }
JsMap* value_as_map(Value v)             { return cast(JsMap*, value_as_cell(v)); }
JsAccessor* value_as_accessor(Value v) { return cast(JsAccessor*, value_as_cell(v)); }
JsObject* value_as_object(Value v)     { return cast(JsObject*, value_as_cell(v)); }
JsFunction* value_as_function(Value v) { return cast(JsFunction*, value_as_cell(v)); }
JsNative* value_as_native(Value v)     { return cast(JsNative*, value_as_cell(v)); }
JsBox* value_as_box(Value v)           { return cast(JsBox*, value_as_cell(v)); }
GcString* value_as_string(Value v)     { return cast(GcString*, value_as_cell(v)); }

bool value_is_array(Value v) {
    return value_is_object(v) && (value_as_object(v).obj_flags & OBJF_ARRAY) != 0;
}

// Own-property table for any value that carries one: ordinary objects,
// functions, and natives (constructors keep their statics here). Returns
// null for primitives. Lets reflection reach a constructor's own
// properties, which a value_is_object check alone would miss.
PropList* value_props(Value v) {
    if value_is_object(v)   { return &value_as_object(v).props; }
    if value_is_function(v) { return &value_as_function(v).props; }
    if value_is_native(v)   { return &value_as_native(v).props; }
    return null;
}

// A constructor's return value counts as an object (replaces the new
// instance) for anything that isn't a primitive: strings and symbols
// are primitives, everything else on the heap is a reference.
bool value_is_reference(Value v) {
    if !value_is_cell(v) { return false; }
    i32 k = value_as_cell(v).kind;
    return k != GC_STRING && k != GC_SYMBOL;
}

// --- property access ------------------------------------------------------

// Own or inherited; false when absent.
bool js_get_prop(JsObject* o, u32 key, Value* out) {
    JsObject* cur = o;
    while cur != null {
        Value* v = props_get(&cur.props, key);
        if v != null {
            *out = *v;
            return true;
        }
        cur = cur.proto;
    }
    return false;
}

void js_set_prop(JsObject* o, u32 key, Value v) {
    props_set(&o.props, key, v);
}

bool js_has_prop(JsObject* o, u32 key) {
    Value tmp;
    return js_get_prop(o, key, &tmp);
}

bool js_delete_prop(JsObject* o, u32 key) {
    return props_remove(&o.props, key);
}

// --- array elements ---------------------------------------------------------

// Reads an element for a value: an absent slot (past the end or a hole)
// reads as undefined. Use js_array_has / js_array_raw to detect holes.
Value js_array_get(JsObject* o, i32 idx) {
    if idx < 0 || idx >= o.elen { return value_undefined(); }
    Value v = *(o.elems + idx);
    return value_is_hole(v) ? value_undefined() : v;
}

// The raw stored slot, hole and all.
Value js_array_raw(JsObject* o, i32 idx) {
    if idx < 0 || idx >= o.elen { return value_hole(); }
    return *(o.elems + idx);
}

// Whether index idx is a present own element (in range and not a hole).
bool js_array_has(JsObject* o, i32 idx) {
    if idx < 0 || idx >= o.elen { return false; }
    return !value_is_hole(*(o.elems + idx));
}

void js_array_set(JsObject* o, i32 idx, Value v) {
    if idx < 0 { return; }
    if idx >= o.ecap {
        i32 ncap = o.ecap * 2;
        if ncap < 8 { ncap = 8; }
        if ncap <= idx { ncap = idx + 1; }
        Value* ne = alloc<Value>(ncap);
        for i32 i = 0; i < o.elen; i++ {
            *(ne + i) = *(o.elems + i);
        }
        if o.elems != null { free(o.elems); }
        o.elems = ne;
        o.ecap = ncap;
    }
    // gap between old end and idx becomes holes
    for i32 i = o.elen; i < idx; i++ {
        *(o.elems + i) = value_hole();
    }
    *(o.elems + idx) = v;
    if idx >= o.elen { o.elen = idx + 1; }
}

// Truncates or hole-extends the dense part.
void js_array_set_length(JsObject* o, i32 n) {
    if n < 0 { return; }
    if n < o.elen {
        o.elen = n;
        return;
    }
    if n > o.elen {
        // set the last slot to a hole, filling the gap with holes too
        js_array_set(o, n - 1, value_hole());
    }
    o.elen = n;
}

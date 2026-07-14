// object.mc — runtime object kinds on the GC heap.
//
// Objects carry a property table (atom → Value), a prototype link,
// and an optional dense array part. Functions and natives are their
// own kinds with a small property table (fn.prototype). Boxes hold
// captured variables. This module registers the heap's tracer and
// finalizer hooks for these kinds.

import vec;
import map;
import value;
import gc;
import atom;

// continues GcKind: 0..1 are built into gc.mc
const i32 GC_OBJECT   = 2;
const i32 GC_FUNCTION = 3;
const i32 GC_NATIVE   = 4;
const i32 GC_BOX      = 5;

const i32 OBJF_ARRAY = 1;

struct FnTemplate;

struct JsObject {
    GcCell head;
    i32 obj_flags;
    JsObject* proto;
    IntMap<Value> props;   // atom → value
    Value* elems;          // dense array part
    i32 elen;
    i32 ecap;
}

struct JsFunction {
    GcCell head;
    FnTemplate* tmpl;
    Value* upvals;         // boxes, one per template upvalue
    i32 n_upvals;
    IntMap<Value> props;   // fn.prototype and friends
}

// ctx is the owning VM; typed as void* to keep layering one-way.
type NativeFn = fn(void*, Value, Value*, i32): Value;

struct JsNative {
    GcCell head;
    NativeFn fun;
    str name;              // static or atom-owned view
    IntMap<Value> props;
}

struct JsBox {
    GcCell head;
    Value v;
}

// --- GC hooks ---------------------------------------------------------

private void mark_props(GcHeap* h, IntMap<Value>* m) {
    for i32 i = 0; i < m.cap; i++ {
        IntSlot<Value>* sl = m.slots + i;
        if sl.state == SLOT_USED {
            gc_mark_value(h, sl.val);
        }
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
        return;
    }
    if c.kind == GC_FUNCTION {
        JsFunction* f = cast(JsFunction*, c);
        for i32 i = 0; i < f.n_upvals; i++ {
            gc_mark_value(h, *(f.upvals + i));
        }
        mark_props(h, &f.props);
        return;
    }
    if c.kind == GC_NATIVE {
        JsNative* n = cast(JsNative*, c);
        mark_props(h, &n.props);
        return;
    }
    if c.kind == GC_BOX {
        JsBox* b = cast(JsBox*, c);
        gc_mark_value(h, b.v);
        return;
    }
    eprint("gc: unknown runtime cell kind {}\n", c.kind);
    exit(70);
}

void js_finalize(GcCell* c) {
    if c.kind == GC_OBJECT {
        JsObject* o = cast(JsObject*, c);
        intmap_free<Value>(&o.props);
        if o.elems != null { free(o.elems); }
        return;
    }
    if c.kind == GC_FUNCTION {
        JsFunction* f = cast(JsFunction*, c);
        intmap_free<Value>(&f.props);
        if f.upvals != null { free(f.upvals); }
        return;
    }
    if c.kind == GC_NATIVE {
        JsNative* n = cast(JsNative*, c);
        intmap_free<Value>(&n.props);
        return;
    }
}

// --- constructors -----------------------------------------------------

JsObject* js_new_object(GcHeap* h, JsObject* proto) {
    JsObject* o = cast(JsObject*, gc_alloc(h, GC_OBJECT, sizeof(JsObject)));
    o.proto = proto;
    intmap_init<Value>(&o.props);
    return o;
}

JsObject* js_new_array(GcHeap* h) {
    JsObject* o = js_new_object(h, null);
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
    intmap_init<Value>(&f.props);
    return f;
}

JsNative* js_new_native(GcHeap* h, NativeFn fun, str name) {
    JsNative* n = cast(JsNative*, gc_alloc(h, GC_NATIVE, sizeof(JsNative)));
    n.fun = fun;
    n.name = name;
    intmap_init<Value>(&n.props);
    return n;
}

JsBox* js_new_box(GcHeap* h, Value v) {
    JsBox* b = cast(JsBox*, gc_alloc(h, GC_BOX, sizeof(JsBox)));
    b.v = v;
    return b;
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

JsObject* value_as_object(Value v)     { return cast(JsObject*, value_as_cell(v)); }
JsFunction* value_as_function(Value v) { return cast(JsFunction*, value_as_cell(v)); }
JsNative* value_as_native(Value v)     { return cast(JsNative*, value_as_cell(v)); }
JsBox* value_as_box(Value v)           { return cast(JsBox*, value_as_cell(v)); }
GcString* value_as_string(Value v)     { return cast(GcString*, value_as_cell(v)); }

bool value_is_array(Value v) {
    return value_is_object(v) && (value_as_object(v).obj_flags & OBJF_ARRAY) != 0;
}

// --- property access ------------------------------------------------------

// Own or inherited; false when absent.
bool js_get_prop(JsObject* o, u32 key, Value* out) {
    JsObject* cur = o;
    while cur != null {
        Value* v = intmap_get<Value>(&cur.props, key);
        if v != null {
            *out = *v;
            return true;
        }
        cur = cur.proto;
    }
    return false;
}

void js_set_prop(JsObject* o, u32 key, Value v) {
    intmap_set<Value>(&o.props, key, v);
}

bool js_has_prop(JsObject* o, u32 key) {
    Value tmp;
    return js_get_prop(o, key, &tmp);
}

bool js_delete_prop(JsObject* o, u32 key) {
    return intmap_remove<Value>(&o.props, key);
}

// --- array elements ---------------------------------------------------------

Value js_array_get(JsObject* o, i32 idx) {
    if idx < 0 || idx >= o.elen { return value_undefined(); }
    return *(o.elems + idx);
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
    for i32 i = o.elen; i < idx; i++ {
        *(o.elems + i) = value_undefined();
    }
    *(o.elems + idx) = v;
    if idx >= o.elen { o.elen = idx + 1; }
}
